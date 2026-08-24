import CoreData
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
    private static let ausstehendeAktionBackupDateinameSchluessel = "syncErsetzenAusstehendeAktionBackupDateiname"

    /// Obergrenze gleichzeitig aufbewahrter Backups (Nutzer-Entscheidung) —
    /// beim Überschreiten wird nach jedem ``erstelleBackup(context:grund:)``
    /// automatisch das älteste entfernt (siehe ``wendeAufbewahrungsLimitAn()``).
    private static let maximaleAnzahlBackups = 10

    private static var backupsVerzeichnis: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// Dateiname für ein neu zu erstellendes Backup — Zeitstempel (für
    /// chronologische Sortierbarkeit schon am Dateinamen) plus kurzer
    /// UUID-Suffix, damit zwei Backups in derselben Sekunde nie kollidieren.
    private static func neueBackupURL() -> URL {
        let zeitstempel = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        return backupsVerzeichnis.appendingPathComponent("backup-\(zeitstempel)-\(suffix).json")
    }

    /// Die beim nächsten App-Start auszuführende Aktion, `nil` im
    /// Normalfall. Übersteht einen App-Neustart (`UserDefaults`), da genau
    /// das der Zweck ist — siehe Typ-Dokumentation.
    private(set) static var ausstehendeAktion: AusstehendeAktion? {
        get { UserDefaults.standard.string(forKey: ausstehendeAktionSchluessel).flatMap(AusstehendeAktion.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: ausstehendeAktionSchluessel) }
    }

    /// Dateiname (nicht vollständige URL, da ``backupsVerzeichnis`` sich
    /// zwischen App-Starts nicht ändert) des Backups, auf das sich
    /// ``ausstehendeAktion`` bezieht — bei `.ersetzenDurchPeer` das direkt
    /// zuvor als Sicherheitsnetz erstellte Backup (für die Vorher-/
    /// Nachher-Zusammenfassung), bei `.wiederherstellenAusBackup` das
    /// tatsächlich wiederherzustellende Backup. Übersteht den Neustart
    /// genau wie ``ausstehendeAktion`` selbst.
    private(set) static var ausstehendeAktionBackupDateiname: String? {
        get { UserDefaults.standard.string(forKey: ausstehendeAktionBackupDateinameSchluessel) }
        set { UserDefaults.standard.set(newValue, forKey: ausstehendeAktionBackupDateinameSchluessel) }
    }

    struct BackupInfo: Identifiable {
        var url: URL
        var erstelltAm: Date
        var groesseBytes: Int
        var grund: String

        var id: URL { url }
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
        var abteilungen: Int
        var geschaefte: Int
        var artikel: Int
        var einkaufslisten: Int
        var einkaufsvorgaenge: Int
        var kaufEintraege: Int
        var warengruppenDistanzen: Int

        init(snapshot: SyncSnapshot) {
            geschaeftsTypen = snapshot.geschaeftsTypen.count
            abteilungen = snapshot.abteilungen.count
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
            geschaeftsTypen + abteilungen + geschaefte + artikel + einkaufslisten
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

    // MARK: - Planen (aktueller Sitzung, vor dem Neustart — Fallback)

    /// Sichert den aktuellen Datenbestand und merkt „Ersetzen durch Peer" für
    /// den nächsten App-Start vor. Verändert den Datenbestand selbst noch
    /// nicht — dafür muss die App neu gestartet werden.
    ///
    /// **Nur noch Fallback:** der reguläre Weg aus der laufenden App heraus
    /// ist seit dem zweiten Live-Anlauf ``fuehreErsetzenDurchPeerLive()``
    /// (kein Neustart nötig). Diese Methode bleibt für den Fall, dass
    /// ``ModelContainerController/aktuell`` `nil` ist (z.B. In-Memory-Store
    /// in Unit-Tests ohne echten `ModelContainerController`).
    @MainActor
    static func planeErsetzenDurchPeer(context: ModelContext) throws {
        let url = try erstelleBackup(context: context, grund: "Vor Ersetzen durch Peer")
        ausstehendeAktionBackupDateiname = url.lastPathComponent
        ausstehendeAktion = .ersetzenDurchPeer
    }

    /// Merkt „Wiederherstellen aus dem lokalen Backup" für den nächsten
    /// App-Start vor. `url` wählt ein bestimmtes Backup aus der Liste
    /// (``alleBackups()``); `nil` (Vorgabe) wählt das zuletzt erstellte —
    /// deckt den alten Einzel-Backup-Aufrufstil ab. Wirft, falls das
    /// gewählte bzw. (bei `nil`) irgendein Backup existiert. Nur noch
    /// Fallback, siehe ``planeErsetzenDurchPeer(context:)``.
    static func planeWiederherstellenAusBackup(url: URL? = nil) throws {
        guard let ziel = url ?? alleBackups().first?.url else {
            throw SyncErsetzenFehler.keinBackupVorhanden
        }
        guard FileManager.default.fileExists(atPath: ziel.path) else {
            throw SyncErsetzenFehler.keinBackupVorhanden
        }
        ausstehendeAktionBackupDateiname = ziel.lastPathComponent
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
        let url = try erstelleBackup(context: context, grund: "Bereinigung baumelnder Referenzen")
        ausstehendeAktionBackupDateiname = url.lastPathComponent
        ausstehendeAktion = .wiederherstellenAusBackup
    }

    // MARK: - Live ausführen (ohne Neustart, zweiter Anlauf)

    /// Ersetzt den lokalen Datenbestand SOFORT durch den Stand eines Peers —
    /// ohne App-Neustart. Sichert vorher den aktuellen Stand (für die
    /// Vorher-/Nachher-Zusammenfassung und einen möglichen Härtungs-Rollback,
    /// siehe ``fuehreLiveAus(context:befuellen:)``).
    @MainActor
    static func fuehreErsetzenDurchPeerLive(controller: ModelContainerController) async throws {
        let vorherKontext = controller.modelContainer.mainContext
        let vorherBackupURL = try erstelleBackup(context: vorherKontext, grund: "Vor Ersetzen durch Peer")
        try await fuehreLiveAus(controller: controller) { neuerContext in
            await fuehreErsetzenDurchPeerAus(context: neuerContext, vorherBackupURL: vorherBackupURL)
        }
    }

    /// Stellt SOFORT den gewählten lokalen Stand wieder her — ohne
    /// App-Neustart. `url` wählt ein bestimmtes Backup aus der Liste
    /// (``alleBackups()``); `nil` (Vorgabe) wählt das zuletzt erstellte.
    /// Wirft, falls das gewählte bzw. (bei `nil`) irgendein Backup existiert.
    @MainActor
    static func fuehreWiederherstellenAusBackupLive(controller: ModelContainerController, url: URL? = nil) async throws {
        guard let ziel = url ?? alleBackups().first?.url, FileManager.default.fileExists(atPath: ziel.path) else {
            throw SyncErsetzenFehler.keinBackupVorhanden
        }
        try await fuehreLiveAus(controller: controller) { neuerContext in
            fuehreWiederherstellenAusBackupAus(context: neuerContext, url: ziel)
        }
    }

    /// Live-Variante von ``planeBereinigungBaumelnderReferenzen(context:)``:
    /// erstellt jetzt einen frischen (bereits „reparierten", siehe Doku dort)
    /// Snapshot des aktuellen Bestands und baut den Store sofort daraus neu
    /// auf.
    @MainActor
    static func fuehreBereinigungBaumelnderReferenzenLive(controller: ModelContainerController) async throws {
        let url = try erstelleBackup(context: controller.modelContainer.mainContext, grund: "Bereinigung baumelnder Referenzen")
        try await fuehreLiveAus(controller: controller) { neuerContext in
            fuehreWiederherstellenAusBackupAus(context: neuerContext, url: url)
        }
    }

    /// Gemeinsame Klammer für alle drei Live-Pfade oben: ruft
    /// ``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)`` auf
    /// und startet Hintergrund-Sync/Multipeer über `ausfuehren` auf dem neuen
    /// Context neu — Aufrufer (``SyncOrdnerSettingsView``) muss den
    /// Hintergrund-Sync NICHT mehr vorher stoppen: das Umhängen von
    /// `.modelContainer(_:)` und der `.task(id: generation)`-Neustart in
    /// `ShopWithMeApp` übernehmen das strukturell — der alte Context wird nach
    /// dem Umhängen von keinem neuen Sync-Zyklus mehr verwendet, ein zum
    /// Umhäng-Zeitpunkt bereits laufender Zyklus läuft dank
    /// ``ModelContainerController/vergangeneContainer`` gefahrlos auf dem
    /// alten Context zu Ende (schreibt in die jetzt verwaiste, aber weiterhin
    /// gültige alte Datei).
    @MainActor
    private static func fuehreLiveAus(controller: ModelContainerController, ausfuehren: @MainActor @escaping (ModelContext) async -> Void) async throws {
        try await controller.ersetzeLiveMitNeuemStore { neuerContext in
            neuerContext.autosaveEnabled = false
            await ausfuehren(neuerContext)
        }
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
    ///
    /// **`destroyPersistentStore` statt reiner `FileManager`-Löschung
    /// (GitHub #119, Live-Test-Nachtrag):** Ein erster Entwurf löschte nur
    /// `default.store`/`-wal`/`-shm` per `FileManager.removeItem` — auf
    /// einem echten Gerät blieb der exakt gleiche „unknown model
    /// version"-Fehler danach bestehen, auch nach einem echten
    /// Prozess-Neustart. `NSPersistentStoreCoordinator.destroyPersistentStore`
    /// ist Core Datas eigene, dafür vorgesehene API („It is not possible to
    /// unlink a database file safely out from underneath another thread or
    /// process, so this API performs a truncation" — SDK-Header
    /// `NSPersistentStoreCoordinator.h`) und behandelt Journal-/WAL-Dateien
    /// sowie Store-Metadaten vollständiger als ein manuelles Raten der
    /// Begleitdateinamen. Die manuelle `FileManager`-Löschung bleibt zusätzlich
    /// als Fallback bestehen, falls `destroyPersistentStore` selbst (z.B. bei
    /// bereits korrumpierten Metadaten) fehlschlägt.
    static func loescheUnlesbarenStoreUndPlaneWiederherstellung(url: URL) {
        let koordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
        try? koordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)

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
    ///
    /// **Hinweis zur Rückkehrer-Erkennung:** Ob direkt danach
    /// `SyncPollingService`s Rückkehrer-Erkennung übersprungen werden muss
    /// (der eigene Peer-Unterordner existiert nach einem frischen
    /// Wipe-und-Neuaufbau noch nicht), wird NICHT über den Rückgabewert
    /// dieser Funktion gesteuert — ein früherer Versuch dazu verlor eine
    /// Race Condition gegen `.onChange(of: scenePhase)` in `ShopWithMeApp`
    /// praktisch immer (Live-Fund, `docs/DATENSYNCHRONISATION_VERLAUF.md`
    /// Abschnitt 49). Siehe stattdessen
    /// ``SyncPollingService/ueberspringeRueckkehrerErkennungBeimNaechstenStart``,
    /// synchron in `ShopWithMeApp.init()` gesetzt.
    @MainActor
    static func fuehreAusstehendeAktionAus(context: ModelContext) async {
        guard let aktion = ausstehendeAktion else { return }
        ausstehendeAktion = nil
        // Fällt auf das zuletzt erstellte Backup zurück, falls kein
        // Dateiname hinterlegt ist (defensiv — sollte bei jedem Aufrufer
        // oben stets gesetzt sein).
        let backupURL = ausstehendeAktionBackupDateiname.map { backupsVerzeichnis.appendingPathComponent($0) } ?? alleBackups().first?.url
        ausstehendeAktionBackupDateiname = nil

        switch aktion {
        case .ersetzenDurchPeer:
            await fuehreErsetzenDurchPeerAus(context: context, vorherBackupURL: backupURL)
        case .wiederherstellenAusBackup:
            guard let backupURL else { return }
            fuehreWiederherstellenAusBackupAus(context: context, url: backupURL)
        }
    }

    /// Kern von „Ersetzen durch Peer" — gemeinsam genutzt vom Neustart-
    /// Fallback (``fuehreAusstehendeAktionAus(context:)``) und dem Live-Pfad
    /// (``fuehreErsetzenDurchPeerLive(controller:)``). `context` ist in
    /// beiden Fällen ein frischer, leerer Context (nach `loescheStoreDateiFallsAusstehend`
    /// bzw. nach ``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)``).
    @MainActor
    private static func fuehreErsetzenDurchPeerAus(context: ModelContext, vorherBackupURL: URL?) async {
        // Vorher-Stand aus dem ohnehin vor dem Neuaufbau erstellten
        // Backup lesen (noch vorhanden, wird hier bewusst nicht gelöscht) —
        // Grundlage für die Vorher-/Nachher-Zusammenfassung unten, den
        // Härtungs-Rollback UND die SyncEvent-Wiederherstellung (GitHub #80,
        // siehe unten).
        let vorherBackup = vorherBackupURL.flatMap(ladeBackup(url:))
        let ordnerZugriffErfolgreich = await SyncSnapshotImportService.importiereSnapshots(context: context)
        if let vorherBackup {
            let vorherSnapshot = vorherBackup.snapshot
            let nachherSnapshot = SyncSnapshotExportService.erstelleSnapshot(context: context)
            let vorherZaehler = BereichsZaehler(snapshot: vorherSnapshot)
            let nachherZaehler = BereichsZaehler(snapshot: nachherSnapshot)
            letzteNeuaufbauZusammenfassung = NeuaufbauZusammenfassung(
                zeitpunkt: Date(), vorher: vorherZaehler, nachher: nachherZaehler
            )

            // Härtung (Abteilung-3-Review): ein Neuaufbau, der eindeutig
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
            // Analog zu den SyncEvents oben: rein gerätelokal, nie Teil
            // des Peer-``SyncSnapshot`` — ohne diese Wiederherstellung
            // bot der ``GeschaeftVorschlagBanner`` bereits ignorierte
            // Vorschläge nach jedem „Ersetzen" erneut an (Korrektur,
            // vorher nur im ``.wiederherstellenAusBackup``-Zweig unten
            // behandelt).
            stelleIgnorierteGeschaeftsVorschlaegeWiederHer(vorherBackup.ignorierteGeschaeftsVorschlaege, context: context)
            try? context.save()
        }
    }

    /// Kern von „Wiederherstellen aus dem lokalen Backup" — gemeinsam genutzt
    /// vom Neustart-Fallback und dem Live-Pfad (``fuehreWiederherstellenAusBackupLive(controller:)``,
    /// ``fuehreBereinigungBaumelnderReferenzenLive(controller:)``).
    @MainActor
    private static func fuehreWiederherstellenAusBackupAus(context: ModelContext, url: URL) {
        guard let backup = ladeBackup(url: url) else { return }
        // Sentinel-Geräte-ID statt der eigenen: verhindert einen
        // Phantom-``SyncPeerInfo``-Eintrag und Kollisionen mit echter
        // Peer-Zähler-Buchhaltung (``SyncPeerZaehlerStand``).
        SyncSnapshotImportService.importiereEinzelnenSnapshot(backup.snapshot, peerGeraeteID: "lokales-backup", context: context)
        stelleIgnorierteGeschaeftsVorschlaegeWiederHer(backup.ignorierteGeschaeftsVorschlaege, context: context)
        stelleSyncEventsWiederHer(backup.bekannteSyncEvents, context: context)
        // Das eigene Backup kann einen zum Sicherungszeitpunkt noch
        // offenen Einkaufsvorgang enthalten — bei weiterhin verknüpftem
        // Sync-Ordner (``SyncOrdnerSettingsView/backupWiederherstellenGetappt()``,
        // Korruptions-Recovery ohne Austritt) würde der sonst vom
        // nächsten Sync-Zyklus blind mit einem tatsächlich aktiven
        // Vorgang eines Peers zusammengeführt (siehe
        // ``EinkaufsvorgangAbschlussService/schliesseAlleOffenenEinkaufsvorgaenge(context:)``).
        EinkaufsvorgangAbschlussService.schliesseAlleOffenenEinkaufsvorgaenge(context: context)
        try? context.save()
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

    /// Stellt die zum Zeitpunkt des Backups ignorierten Ladenvorschläge
    /// (``IgnorierterGeschaeftsVorschlag``) wieder her — analog
    /// ``stelleSyncEventsWiederHer(_:context:)`` rein gerätelokaler Zustand,
    /// nie Teil des Peer-``SyncSnapshot`` (siehe Typ-Doku dort), der beim
    /// Store-Wipe sonst kommentarlos verloren ginge.
    private static func stelleIgnorierteGeschaeftsVorschlaegeWiederHer(
        _ vorschlaege: [IgnorierterGeschaeftsVorschlagSnapshot], context: ModelContext
    ) {
        for vorschlag in vorschlaege {
            let neuer = IgnorierterGeschaeftsVorschlag(
                name: vorschlag.name, breitengrad: vorschlag.breitengrad, laengengrad: vorschlag.laengengrad
            )
            neuer.ignoriertAm = vorschlag.ignoriertAm
            context.insert(neuer)
        }
    }

    // MARK: - Backup

    /// Sichert den aktuellen Datenbestand als eine neue, lokale, nicht
    /// geteilte Backup-Datei — wiederverwendet
    /// ``SyncSnapshotExportService/erstelleSnapshot(context:)`` für den
    /// Hauptinhalt. Jeder Aufruf legt eine zusätzliche Datei an (siehe
    /// ``alleBackups()``); überschreitet die Gesamtzahl danach
    /// ``maximaleAnzahlBackups``, wird automatisch das älteste Backup
    /// entfernt (``wendeAufbewahrungsLimitAn()``).
    @discardableResult
    @MainActor
    static func erstelleBackup(context: ModelContext, grund: String = "Manuell") throws -> URL {
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
            bekannteSyncEvents: bekannteSyncEvents,
            grund: grund
        )
        let daten = try JSONEncoder().encode(backup)
        let url = neueBackupURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try daten.write(to: url, options: .atomic)
        wendeAufbewahrungsLimitAn()
        return url
    }

    /// Entfernt überzählige Backups (älteste zuerst), bis höchstens
    /// ``maximaleAnzahlBackups`` übrig sind — nach jedem
    /// ``erstelleBackup(context:grund:)`` aufgerufen. Das Backup, auf das
    /// sich eine noch ausstehende Aktion bezieht (``ausstehendeAktionBackupDateiname``),
    /// wird dabei nie entfernt, auch nicht wenn es zufällig das älteste ist.
    private static func wendeAufbewahrungsLimitAn() {
        let backups = alleBackups()
        guard backups.count > maximaleAnzahlBackups else { return }
        let geschuetzterDateiname = ausstehendeAktionBackupDateiname
        for veraltet in backups.dropFirst(maximaleAnzahlBackups) where veraltet.url.lastPathComponent != geschuetzterDateiname {
            try? FileManager.default.removeItem(at: veraltet.url)
        }
    }

    /// Metadaten des zuletzt erstellten Backups, `nil` falls keins existiert
    /// — Convenience für Aufrufer, die (wie der alte Einzel-Backup-Ablauf)
    /// nur wissen wollen, ob überhaupt eines existiert. Für die vollständige
    /// Liste siehe ``alleBackups()``.
    static func vorhandenesBackup() -> BackupInfo? {
        alleBackups().first
    }

    /// Alle vorhandenen Backups, neuestes zuerst — Grundlage für die
    /// Backup-Liste in ``SyncOrdnerSettingsView``.
    static func alleBackups() -> [BackupInfo] {
        guard let dateien = try? FileManager.default.contentsOfDirectory(at: backupsVerzeichnis, includingPropertiesForKeys: nil)
        else { return [] }
        return dateien
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> BackupInfo? in
                guard let groesse = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
                      let backup = ladeBackup(url: url)
                else { return nil }
                return BackupInfo(url: url, erstelltAm: backup.erstelltAm, groesseBytes: groesse, grund: backup.grund ?? "Backup")
            }
            .sorted { $0.erstelltAm > $1.erstelltAm }
    }

    /// Lädt und dekodiert ein Backup an `url`, `nil` falls es nicht existiert
    /// oder nicht lesbar ist.
    private static func ladeBackup(url: URL) -> SyncErsetzenBackup? {
        guard let daten = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
    }

    /// Löscht ein bestimmtes Backup.
    static func loescheBackup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Löscht alle vorhandenen Backups (Test-Aufräumen, siehe
    /// `SyncErsetzenServiceTests`).
    static func loescheBackup() {
        for backup in alleBackups() {
            loescheBackup(url: backup.url)
        }
    }

    /// Importiert eine extern gewählte Backup-Datei (Dateien-App, iCloud
    /// Drive, …) als zusätzliches Backup in ``backupsVerzeichnis`` — validiert
    /// dabei, dass es sich tatsächlich um ein dekodierbares
    /// ``SyncErsetzenBackup`` handelt, statt eine beliebige Datei blind zu
    /// kopieren. Wirft, falls die Datei nicht lesbar/dekodierbar ist.
    static func importiereBackup(von quelle: URL) throws -> URL {
        var backup = try JSONDecoder().decode(SyncErsetzenBackup.self, from: try Data(contentsOf: quelle))
        backup.grund = "Importiert (\(backup.grund ?? "Backup"))"
        let daten = try JSONEncoder().encode(backup)
        let ziel = neueBackupURL()
        try FileManager.default.createDirectory(at: ziel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try daten.write(to: ziel, options: .atomic)
        wendeAufbewahrungsLimitAn()
        return ziel
    }
}
