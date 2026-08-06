import Foundation
import SwiftData

/// Fehler rund um ``SyncErsetzenService``.
enum SyncErsetzenFehler: LocalizedError {
    case keinBackupVorhanden

    var errorDescription: String? {
        switch self {
        case .keinBackupVorhanden:
            return "Es ist kein lokales Backup vorhanden."
        }
    }
}

/// Ersetzen/Backup/Wiederherstellen für den lokalen Datenbestand (GitHub #63 +
/// Korruptions-Recovery, siehe `docs/DATENSYNCHRONISATION_VERLAUF.md`).
///
/// Zwei Beweggründe, ein Mechanismus:
/// 1. **GitHub #63** — beim erstmaligen Verknüpfen eines Sync-Ordners lokale
///    Daten (insbesondere private Kaufhistorie, Bereich C) durch den Stand
///    eines bestehenden Peers ersetzen statt zu mergen.
/// 2. **Korruptions-Recovery** — ein lokal bereits korrumpierter Datensatz
///    (baumelnde Referenz, siehe `docs/DATABASE_CONCURRENCY.md`) lässt sich
///    über die normale SwiftData-API nicht reparieren; ein vollständiges
///    Zurücksetzen und Neuaufbau aus einem unkorrumpierten Peer-Snapshot
///    umgeht das, weil die korrumpierten Zeilen nie wieder geöffnet werden.
///
/// **Neustart-Aufforderung statt nahtlosem Austausch (Korrektur):** Ein
/// erster Entwurf ersetzte den lokalen Store zur Laufzeit (`ModelContainer`
/// wurde austauschbar gemacht, `.id(generation)` erzwang einen View-Baum-
/// Neuaufbau). Auf einem echten Gerät führte das zu einem SQLite-I/O-Fehler
/// und Absturz: `SyncPollingService.stoppen()` fordert Cancellation nur
/// kooperativ an, wartet aber nicht, bis ein bereits laufender Sync-Zyklus
/// tatsächlich beendet ist — lief einer noch, griff er weiter auf die Datei
/// zu, während sie physisch gelöscht wurde. Statt diese eine Wettlaufsituation
/// (und potenziell weitere, nicht ausgeschlossene ähnliche) einzeln zu jagen,
/// verschiebt dieser Mechanismus die eigentliche Ersetzung strukturell an den
/// einzigen Zeitpunkt, an dem garantiert nichts anderes auf den Store
/// zugreift: den Anfang eines frischen Prozesses, bevor überhaupt ein
/// ``ModelContainer`` existiert (siehe ``ShopWithMeApp/init()``).
///
/// Ablauf: `plane…()` sichert (falls nötig) und merkt nur eine ausstehende
/// Aktion vor — der Anwender wird gebeten, die App zu schließen und neu zu
/// öffnen. Beim nächsten Start löscht ``loescheStoreDateiFallsAusstehend(url:)``
/// die Store-Datei, **bevor** `ShopWithMeApp.init()` einen `ModelContainer`
/// dafür öffnet; nach dem Start füllt ``fuehreAusstehendeAktionAus(context:)``
/// den jetzt frischen, leeren Context.
enum SyncErsetzenService {
    enum AusstehendeAktion: String {
        case ersetzenDurchPeer
        case wiederherstellenAusBackup
    }

    private static let ausstehendeAktionSchluessel = "syncErsetzenAusstehendeAktion"
    private static let backupDateiName = "ersetzen-backup.json"

    private static var backupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(backupDateiName)
    }

    /// Die beim nächsten App-Start auszuführende Aktion, `nil` im
    /// Normalfall. Übersteht einen App-Neustart (`UserDefaults`), da genau
    /// das der Zweck ist — siehe Typ-Dokumentation.
    private(set) static var ausstehendeAktion: AusstehendeAktion? {
        get { UserDefaults.standard.string(forKey: ausstehendeAktionSchluessel).flatMap(AusstehendeAktion.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: ausstehendeAktionSchluessel) }
    }

    struct BackupInfo {
        var erstelltAm: Date
        var groesseBytes: Int
    }

    /// Vorher-/Nachher-Mengenvergleich eines „Ersetzen durch Peer"-Neuaufbaus
    /// (Live-Test-Nachfolgefund, `docs/DATENSYNCHRONISATION_VERLAUF.md`
    /// Abschnitt 21): ein Neuaufbau, der zum Zeitpunkt der Ausführung weniger
    /// zurückbekommt als vorher vorhanden war (z.B. weil kein erreichbarer
    /// Peer den vollständigen Stand hatte), blieb bisher komplett unbemerkt —
    /// entdeckt wurde ein solcher Fall erst Tage später durch zufälliges
    /// Durchsuchen roher Exportdaten. Wird direkt nach dem Neuaufbau aus dem
    /// ohnehin vorhandenen Vorher-Backup und einem frischen Nachher-Snapshot
    /// berechnet und bis zum expliziten Verwerfen angezeigt (``DebuggingView``).
    struct NeuaufbauZusammenfassung: Codable {
        var zeitpunkt: Date
        var vorher: BereichsZaehler
        var nachher: BereichsZaehler
    }

    /// Anzahl je Bereich eines ``SyncSnapshot`` — Grundlage für
    /// ``NeuaufbauZusammenfassung``.
    struct BereichsZaehler: Codable {
        var geschaeftsTypen: Int
        var artikelKategorien: Int
        var geschaefte: Int
        var artikel: Int
        var einkaufslisten: Int
        var einkaufsvorgaenge: Int
        var kaufEintraege: Int
        var warengruppenDistanzen: Int

        init(snapshot: SyncSnapshot) {
            geschaeftsTypen = snapshot.geschaeftsTypen.count
            artikelKategorien = snapshot.artikelKategorien.count
            geschaefte = snapshot.geschaefte.count
            artikel = snapshot.artikel.count
            einkaufslisten = snapshot.einkaufslisten.count
            einkaufsvorgaenge = snapshot.einkaufsvorgaenge.count
            kaufEintraege = snapshot.kaufEintraege.count
            warengruppenDistanzen = snapshot.warengruppenDistanzen.count
        }

        /// Summe aller Bereiche — genügt für den harten „komplett leer trotz
        /// vorher nicht leer"-Abbruchtest in ``fuehreAusstehendeAktionAus(context:)``,
        /// ohne jeden Bereich einzeln auf Null prüfen zu müssen.
        var gesamt: Int {
            geschaeftsTypen + artikelKategorien + geschaefte + artikel + einkaufslisten
                + einkaufsvorgaenge + kaufEintraege + warengruppenDistanzen
        }
    }

    private static let letzteZusammenfassungSchluessel = "syncErsetzenLetzteZusammenfassung"
    private static let automatischZurueckgerolltSchluessel = "syncErsetzenAutomatischZurueckgerollt"

    /// Zusammenfassung des letzten „Ersetzen durch Peer"-Neuaufbaus, `nil`
    /// falls keiner stattfand oder bereits verworfen wurde (``DebuggingView``).
    static var letzteNeuaufbauZusammenfassung: NeuaufbauZusammenfassung? {
        get {
            guard let daten = UserDefaults.standard.data(forKey: letzteZusammenfassungSchluessel) else { return nil }
            return try? JSONDecoder().decode(NeuaufbauZusammenfassung.self, from: daten)
        }
        set {
            guard let neuerWert = newValue, let daten = try? JSONEncoder().encode(neuerWert) else {
                UserDefaults.standard.removeObject(forKey: letzteZusammenfassungSchluessel)
                return
            }
            UserDefaults.standard.set(daten, forKey: letzteZusammenfassungSchluessel)
        }
    }

    /// `true`, wenn der letzte „Ersetzen durch Peer"-Neuaufbau eindeutig
    /// fehlgeschlagen ist (Ordnerzugriff gescheitert, oder vorher nicht
    /// leerer Bestand komplett verschwunden) und deshalb automatisch auf den
    /// Vorher-Stand zurückgerollt wurde — siehe ``fuehreAusstehendeAktionAus(context:)``.
    private(set) static var letzterNeuaufbauAutomatischZurueckgerollt: Bool {
        get { UserDefaults.standard.bool(forKey: automatischZurueckgerolltSchluessel) }
        set { UserDefaults.standard.set(newValue, forKey: automatischZurueckgerolltSchluessel) }
    }

    static func zusammenfassungVerwerfen() {
        letzteNeuaufbauZusammenfassung = nil
        letzterNeuaufbauAutomatischZurueckgerollt = false
    }

    // MARK: - Planen (aktueller Sitzung, vor dem Neustart)

    /// Sichert den aktuellen Datenbestand und merkt „Ersetzen durch Peer" für
    /// den nächsten App-Start vor. Verändert den Datenbestand selbst noch
    /// nicht — dafür muss die App neu gestartet werden.
    @MainActor
    static func planeErsetzenDurchPeer(context: ModelContext) throws {
        try erstelleBackup(context: context)
        ausstehendeAktion = .ersetzenDurchPeer
    }

    /// Merkt „Wiederherstellen aus dem lokalen Backup" für den nächsten
    /// App-Start vor. Wirft, falls kein Backup existiert.
    static func planeWiederherstellenAusBackup() throws {
        guard vorhandenesBackup() != nil else {
            throw SyncErsetzenFehler.keinBackupVorhanden
        }
        ausstehendeAktion = .wiederherstellenAusBackup
    }

    /// Strategie gegen baumelnde Referenzen (`DatenintegritaetsService`),
    /// OHNE direkten SQLite-Zugriff (siehe Typ-Doku dort, warum eine
    /// Reparatur über die normale SwiftData-API unsicher ist): Ein frischer
    /// Snapshot des AKTUELLEN, ggf. bereits korrumpierten Bestands ist von
    /// Natur aus bereits „repariert" — ``SyncSnapshotExportService/erstelleSnapshot(context:)``
    /// liest jede Relationship über ``SyncSnapshotExportService/sichereID(_:gueltigeIDs:)``,
    /// das eine baumelnde `persistentModelID` still zu `nil` auflöst, statt
    /// sie in den Snapshot zu übernehmen (nur `persistentModelID` selbst ist
    /// auf einer baumelnden Referenz sicher lesbar — genau das nutzt
    /// `sichereID`, nie eine andere Eigenschaft). Ein Wipe-und-Neuaufbau
    /// ausschließlich aus diesem eigenen, frischen Snapshot enthält die
    /// baumelnden Referenzen dadurch strukturell nicht mehr.
    ///
    /// Erstellt deshalb JETZT einen frischen Snapshot (überschreibt ein
    /// eventuell vorhandenes älteres Backup) und merkt dessen
    /// Wiederherstellung für den nächsten Start vor — identischer
    /// Wipe-und-Neuaufbau-Mechanismus wie ``planeWiederherstellenAusBackup()``,
    /// nur mit einem eben erst (nicht irgendwann früher) erstellten Snapshot.
    @MainActor
    static func planeBereinigungBaumelnderReferenzen(context: ModelContext) throws {
        try erstelleBackup(context: context)
        ausstehendeAktion = .wiederherstellenAusBackup
    }

    // MARK: - Ausführen (nächster App-Start)

    /// Löscht die Store-Datei (samt `-wal`/`-shm`) physisch, falls eine
    /// Aktion aussteht — **muss** vor dem Öffnen eines ``ModelContainer``
    /// für `url` aufgerufen werden (siehe ``ShopWithMeApp/init()``). Löscht
    /// nichts, falls keine Aktion aussteht (jeder normale App-Start).
    static func loescheStoreDateiFallsAusstehend(url: URL) {
        guard ausstehendeAktion != nil else { return }
        let ordner = url.deletingLastPathComponent()
        let basisname = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: ordner.appendingPathComponent(basisname + suffix))
        }
    }

    /// Verwirft einen Store, der beim Öffnen bereits nicht mehr migrierbar
    /// war (GitHub #119, siehe ``ShopWithMeApp/oeffneContainer(schema:konfiguration:)``),
    /// und merkt „Ersetzen durch Peer" für den bereits laufenden Start vor —
    /// anders als ``planeErsetzenDurchPeer(context:)`` OHNE Vorher-Backup: der
    /// Store war beim Aufruf bereits ungeöffnet, es gibt nichts zu sichern.
    /// `fuehreAusstehendeAktionAus(context:)` importiert danach normal aus
    /// dem Sync-Ordner, sobald der frisch angelegte Container bereitsteht.
    static func loescheUnlesbarenStoreUndPlaneWiederherstellung(url: URL) {
        let ordner = url.deletingLastPathComponent()
        let basisname = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: ordner.appendingPathComponent(basisname + suffix))
        }
        ausstehendeAktion = .ersetzenDurchPeer
    }

    /// Füllt den (nach ``loescheStoreDateiFallsAusstehend(url:)`` frischen,
    /// leeren) Context gemäß der ausstehenden Aktion und löscht sie
    /// anschließend — ohne Wirkung, falls keine Aktion aussteht.
    @MainActor
    static func fuehreAusstehendeAktionAus(context: ModelContext) async {
        guard let aktion = ausstehendeAktion else { return }
        ausstehendeAktion = nil

        switch aktion {
        case .ersetzenDurchPeer:
            // Vorher-Stand aus dem ohnehin vor dem Neuaufbau erstellten
            // Backup lesen (noch vorhanden, ``fuehreAusstehendeAktionAus``
            // löscht es hier bewusst nicht) — Grundlage für die
            // Vorher-/Nachher-Zusammenfassung unten, den Härtungs-Rollback
            // UND die SyncEvent-Wiederherstellung (GitHub #80, siehe unten).
            let vorherBackup = ladeBackup()
            let ordnerZugriffErfolgreich = await SyncSnapshotImportService.importiereSnapshots(context: context)
            if let vorherBackup {
                let vorherSnapshot = vorherBackup.snapshot
                let nachherSnapshot = SyncSnapshotExportService.erstelleSnapshot(context: context)
                let vorherZaehler = BereichsZaehler(snapshot: vorherSnapshot)
                let nachherZaehler = BereichsZaehler(snapshot: nachherSnapshot)
                letzteNeuaufbauZusammenfassung = NeuaufbauZusammenfassung(
                    zeitpunkt: Date(), vorher: vorherZaehler, nachher: nachherZaehler
                )

                // Härtung (Kategorie-3-Review): ein Neuaufbau, der eindeutig
                // fehlgeschlagen ist — Ordnerzugriff gescheitert, oder ein
                // vorher nicht leerer Bestand ist danach komplett leer (kein
                // erreichbarer Peer hatte irgendetwas) — wird nicht mehr nur
                // in der Vorher-/Nachher-Anzeige gemeldet und dem Nutzer
                // überlassen, sondern automatisch auf den Vorher-Stand
                // zurückgerollt. Ein bloßer TEILWEISER Rückgang (manche
                // Bereiche kleiner, andere unverändert) bleibt bewusst NUR
                // informativ — der kann legitim sein (z.B. echte, vom Peer
                // bereits verarbeitete Löschungen), ein eindeutiger
                // Totalverlust dagegen nie.
                // `nachherZaehler.gesamt == 0` bedeutet: der frische Context
                // ist tatsächlich noch komplett leer (Summe aller Bereiche
                // ist nur dann 0, wenn jeder einzelne Bereich 0 ist) — der
                // Neuaufbau hat buchstäblich nichts eingefügt. Kein
                // zusätzliches Löschen nötig, bevor das Backup importiert wird.
                let eindeutigFehlgeschlagen = !ordnerZugriffErfolgreich || (vorherZaehler.gesamt > 0 && nachherZaehler.gesamt == 0)
                if eindeutigFehlgeschlagen {
                    SyncSnapshotImportService.importiereEinzelnenSnapshot(
                        vorherSnapshot, peerGeraeteID: "lokales-backup", context: context
                    )
                    letzterNeuaufbauAutomatischZurueckgerollt = true
                }

                // GitHub #80: unabhängig davon, ob der Peer-Import geklappt
                // hat oder zurückgerollt wurde — dieses Gerät kannte VOR dem
                // Wipe bereits bestimmte Events, das bleibt so, egal welcher
                // Datenbestand jetzt aktiv ist.
                stelleSyncEventsWiederHer(vorherBackup.bekannteSyncEvents, context: context)
                try? context.save()
            }
        case .wiederherstellenAusBackup:
            guard let daten = try? Data(contentsOf: backupURL),
                  let backup = try? JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
            else { return }
            // Sentinel-Geräte-ID statt der eigenen: verhindert einen
            // Phantom-``SyncPeerInfo``-Eintrag und Kollisionen mit echter
            // Peer-Zähler-Buchhaltung (``SyncPeerZaehlerStand``).
            SyncSnapshotImportService.importiereEinzelnenSnapshot(backup.snapshot, peerGeraeteID: "lokales-backup", context: context)
            for vorschlag in backup.ignorierteGeschaeftsVorschlaege {
                let neuer = IgnorierterGeschaeftsVorschlag(
                    name: vorschlag.name, breitengrad: vorschlag.breitengrad, laengengrad: vorschlag.laengengrad
                )
                neuer.ignoriertAm = vorschlag.ignoriertAm
                context.insert(neuer)
            }
            stelleSyncEventsWiederHer(backup.bekannteSyncEvents, context: context)
            try? context.save()
        }
    }

    /// Stellt die zum Zeitpunkt des Backups lokal bekannten ``SyncEvent``s
    /// wieder her (GitHub #80) — ohne das würde ein Wipe-und-Neuaufbau die
    /// Erinnerung daran verlieren, welche Bereich-A-Events dieses Gerät
    /// bereits gesehen hat, und der nächste Sync-Zyklus würde jede noch
    /// nicht abgelaufene Peer-Event-Datei erneut lesen/auswerten
    /// (``SyncImportService/importiereNeueEvents(context:)``).
    ///
    /// ``SyncEventService/uebernehmen(_:context:)`` übernimmt Einfügen +
    /// Lamport-Abgleich unverändert vom regulären Peer-Empfangspfad — für die
    /// eigenen, bereits vergebenen Lamport-Zähler ist der Abgleich ein
    /// sicherer No-Op, da ``LamportClock`` in `UserDefaults` liegt und einen
    /// Store-Wipe unverändert übersteht (bereits ≥ jedem hier restaurierten
    /// Wert). `hochgeladen` wird danach bewusst auf den ursprünglich
    /// gesicherten Wert zurückgesetzt: `uebernehmen` setzt es sonst pauschal
    /// auf `true` (korrekt für ein tatsächlich von einem Peer empfangenes
    /// Event) — hier würde das ein eigenes, zum Backup-Zeitpunkt noch nicht
    /// exportiertes Event fälschlich als „bereits geteilt" markieren und
    /// dauerhaft von ``SyncExportService/exportiereNeueEvents(context:)``
    /// (Filter `hochgeladen == false`) ausschließen.
    private static func stelleSyncEventsWiederHer(_ eintraege: [SyncEventBackupEintrag]?, context: ModelContext) {
        for eintrag in eintraege ?? [] {
            let event = SyncEventService.uebernehmen(eintrag.event, context: context)
            event.hochgeladen = eintrag.hochgeladen
        }
    }

    // MARK: - Backup

    /// Sichert den aktuellen Datenbestand als lokales, nicht geteiltes Backup
    /// — wiederverwendet ``SyncSnapshotExportService/erstelleSnapshot(context:)``
    /// für den Hauptinhalt. Genau eine Backup-Datei, ein erneuter Aufruf
    /// überschreibt die vorherige (siehe Typ-Doku für die Begründung dieser
    /// Aufbewahrungs-Entscheidung).
    @discardableResult
    @MainActor
    static func erstelleBackup(context: ModelContext) throws -> URL {
        let snapshot = SyncSnapshotExportService.erstelleSnapshot(context: context)
        let ignorierteVorschlaege = ((try? context.fetch(FetchDescriptor<IgnorierterGeschaeftsVorschlag>())) ?? []).map {
            IgnorierterGeschaeftsVorschlagSnapshot(
                name: $0.name, breitengrad: $0.breitengrad, laengengrad: $0.laengengrad, ignoriertAm: $0.ignoriertAm
            )
        }
        // GitHub #80: lokal bekannte SyncEvents mitsichern, damit ein
        // späterer Wipe-und-Neuaufbau nicht die Erinnerung daran verliert,
        // welche Bereich-A-Events dieses Gerät bereits gesehen hat (siehe
        // ``stelleSyncEventsWiederHer(_:context:)``).
        let bekannteSyncEvents = ((try? context.fetch(FetchDescriptor<SyncEvent>())) ?? []).map {
            SyncEventBackupEintrag(event: $0.exportDarstellung, hochgeladen: $0.hochgeladen)
        }
        let backup = SyncErsetzenBackup(
            formatVersion: SyncErsetzenBackup.aktuelleFormatVersion,
            erstelltAm: Date(),
            snapshot: snapshot,
            ignorierteGeschaeftsVorschlaege: ignorierteVorschlaege,
            bekannteSyncEvents: bekannteSyncEvents
        )
        let daten = try JSONEncoder().encode(backup)
        let url = backupURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try daten.write(to: url, options: .atomic)
        return url
    }

    /// Metadaten des vorhandenen Backups für die UI (Datum, Größe) — `nil`,
    /// falls keins existiert oder es nicht lesbar ist.
    static func vorhandenesBackup() -> BackupInfo? {
        let url = backupURL
        guard let attribute = try? FileManager.default.attributesOfItem(atPath: url.path),
              let groesse = attribute[.size] as? Int,
              let backup = ladeBackup()
        else { return nil }
        return BackupInfo(erstelltAm: backup.erstelltAm, groesseBytes: groesse)
    }

    /// Lädt und dekodiert das vorhandene Backup, `nil` falls keins existiert
    /// oder es nicht lesbar ist — gemeinsam genutzt von ``vorhandenesBackup()``
    /// und der Vorher-/Nachher-Zusammenfassung in
    /// ``fuehreAusstehendeAktionAus(context:)``.
    private static func ladeBackup() -> SyncErsetzenBackup? {
        guard let daten = try? Data(contentsOf: backupURL) else { return nil }
        return try? JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
    }

    static func loescheBackup() {
        try? FileManager.default.removeItem(at: backupURL)
    }
}
