import Foundation
import SwiftData

/// Bereich-B/C/D-Import (`docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 5.3, Phase 3): liest Peer-Pakete (seit GitHub #82 mehrere
/// unabhängig fingerabdruck-geprüfte Dateien statt eines `export.json`-
/// Monolithen, siehe `docs/EXPORT_PAKET_UMBAU.md` und
/// ``mergePaket(tombstones:stamm:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``)
/// aus allen fremden Peer-Ordnern und merged Stammdaten (``GeschaeftTyp``,
/// ``ArtikelKategorie``, ``Geschaeft``, ``Artikel``, ``Einkaufsliste``,
/// Bereich B), Historie (``Einkaufsvorgang``, ``KaufEintrag``, Bereich C) und
/// Lernen (``WarengruppenDistanz``, Bereich D) dependency-geordnet in den
/// lokalen Bestand — Matching-Bausteine für Bereich B wiederverwendet aus
/// `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2. Die einzelnen `mergeX`-
/// Funktionen sind unverändert gegenüber dem bisherigen Monolith-Format
/// (sie operieren bereits vorher auf denselben Teil-Arrays) und werden auch
/// vom weiterhin bestehenden lokalen Backup-/Wiederherstellungs-Pfad
/// (``merge(_:peerGeraeteID:context:)``, ``SyncErsetzenService``, GitHub #63)
/// mitgenutzt.
///
/// **Grundprinzip aller Bereich-B-Merge-Regeln: nie destruktiv.** Ein bereits
/// lokal gesetzter Wert wird nie durch einen abweichenden Remote-Wert
/// überschrieben (es gibt keine feldweise Zeitstempel-/Lamport-Ordnung für
/// Bereich B, die entscheiden könnte, welcher Wert "neuer" ist) — stattdessen
/// werden nur fehlende Werte ergänzt (`nil` → Remote-Wert) und Mengen
/// (Kategorien, Typen, ignorierte Artikel, alternative Namen) vereinigt statt
/// ersetzt. Die additiven Zähler auf ``Geschaeft`` (Abschnitt 4.2a) haben eine
/// eigene, dedizierte Regel, siehe ``SyncPeerZaehlerStand``.
///
/// **Bereich C ist Union nach `id`** (jeder Kauf/Einkauf ein unveränderliches
/// historisches Ereignis, nie ein Konflikt) — ``Einkaufsvorgang`` bewusst
/// unter Erhalt seiner ID übernommen (wie ``Einkaufsliste``, siehe dort), damit
/// Bereich-A-Events, die ihn referenzieren, ihn weiterhin auflösen können; ein
/// bereits abgeschlossener lokaler Einkauf wird nie wieder "geöffnet".
/// **Bereich D mittelt** bei bereits vorhandenem Distanz-Eintrag, sonst wird
/// er übernommen (vereinfacht ggü. der im #39-Vorschlag skizzierten
/// besuchsgewichteten Mittelung, da der Snapshot keine Besuchszahl je Eintrag
/// mitführt).
///
/// **Architektur-Revision „Alternative A" (GitHub #52-Nachfolgefund):**
/// Zwei zuvor fehlende Sicherheitsnetze ergänzt, nachdem sich beim Testen
/// zeigte, dass Bereich A (Events) sie nicht bot:
/// 1. ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:context:)``
///    überträgt den vollständigen Einkaufslisten-Inhalt additiv mit — ein Peer,
///    der ein `artikelHinzugefuegt`-Event verpasst hat (oder dessen Liste erst
///    nachträglich per Namensmatching aliasiert wurde), holt sich den
///    fehlenden Stand beim nächsten Snapshot-Import nach, statt für immer
///    einen Rückstand zu behalten.
/// 2. ``mergeTombstones(_:context:)`` verhindert, dass ein gelöschtes
///    ``Geschaeft``/``Artikel``/``ArtikelKategorie``/``Einkaufsliste`` von
///    einem Peer, der es noch in seinem eigenen Snapshot führt, unwissentlich
///    wiederbelebt wird — der bislang rein additive Merge kannte keine
///    Löschsemantik.
enum SyncSnapshotImportService {
    /// Snapshots älter als dieser Wert werden beim Import ignoriert (Peer wird
    /// so behandelt, als wäre er nicht vorhanden) — verhindert, dass verwaiste
    /// Peer-Ordner aus früheren Testinstallationen (jede Neuinstallation
    /// erzeugt eine neue Geräte-ID, siehe ``DatabaseLeaseService/geraeteID``)
    /// für immer alte Daten zurückspielen. `static var` statt `let`, damit
    /// Tests sie auf sehr kurze Werte setzen können.
    @MainActor static var maximalesSnapshotAlter: TimeInterval = 30 * 24 * 60 * 60

    /// Rückgabewert meldet ausschließlich, ob der Ordnerzugriff (Berechtigung)
    /// geklappt hat — die einzige Fehlerart, die für die Person tatsächlich
    /// handlungsrelevant ist (z.B. Ordner erneut auswählen). Alle anderen,
    /// weiter unten bereits einzeln abgefangenen Sonderfälle (fehlender
    /// `peers`-Ordner, defekte einzelne Snapshot-Datei) bleiben bewusst intern
    /// behandelt statt hier als Fehlschlag hochgereicht zu werden, siehe
    /// ``SyncOrdnerSettingsView``.
    @discardableResult
    @MainActor
    static func importiereSnapshots(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }
        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereSnapshots")
            return false
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = try? FileManager.default.contentsOfDirectory(
            at: peersOrdner, includingPropertiesForKeys: nil
        ) else { return true }

        for peerOrdner in peerVerzeichnisse where !PeerOrdnerName.gehoertZu(peerOrdner.lastPathComponent, geraeteID: eigeneGeraeteID) {
            let peerName = peerOrdner.lastPathComponent
            guard let manifest = await ladeManifest(von: SyncSnapshotExportService.manifestURL(fuerPeer: peerName, in: syncOrdner)) else { continue }
            guard Date().timeIntervalSince(manifest.erzeugtAm) <= maximalesSnapshotAlter else {
                SyncDebugLogger.log(.peerVerworfenAltersgrenze, details: "peer=\(peerName.prefix(8))")
                continue
            }
            SyncDebugLogger.protokolliereAlter(.snapshotEmpfangen, erzeugtAm: manifest.erzeugtAm, zusatz: "peer=\(peerName.prefix(8))")

            let tombstones = await ladeTeil(
                [SyncTombstoneSnapshot].self, von: SyncSnapshotExportService.tombstonesURL(fuerPeer: peerName, in: syncOrdner)
            ) ?? []
            let stamm = await ladeTeil(
                SyncStammSnapshot.self, von: SyncSnapshotExportService.stammURL(fuerPeer: peerName, in: syncOrdner)
            ) ?? SyncStammSnapshot(
                geschaeftsTypen: [], artikelKategorien: [], geschaefte: [], artikel: [],
                einkaufslisten: [], artikelAliase: []
            )
            // GitHub #85: aus `stamm.json` herausgelöst — `nil`/leer bedeutet
            // hier zusätzlich „Peer schreibt noch die alte, kombinierte
            // stamm.json" (Übergangszeit bis beide Geräte aktualisiert sind);
            // das Sicherheitsnetz bleibt für diesen einen Zyklus dann leer,
            // ist aber rein additiv und holt sich fehlende Einträge beim
            // nächsten Zyklus nach, sobald der Peer selbst aktualisiert.
            let listen = await ladeTeil(
                SyncListenSnapshot.self, von: SyncSnapshotExportService.listenURL(fuerPeer: peerName, in: syncOrdner)
            ) ?? SyncListenSnapshot(einkaufslistenEintraege: [])
            let lernen = await ladeTeil(
                SyncLernenSnapshot.self, von: SyncSnapshotExportService.lernenURL(fuerPeer: peerName, in: syncOrdner)
            ) ?? SyncLernenSnapshot(warengruppenDistanzen: [])
            let vorgaenge = await ladeTeil(
                SyncVorgaengeSnapshot.self, von: SyncSnapshotExportService.vorgaengeURL(fuerPeer: peerName, in: syncOrdner)
            ) ?? SyncVorgaengeSnapshot(einkaufsvorgaenge: [])
            let preise = await ladeTeil(
                SyncPreisSnapshot.self, von: SyncSnapshotExportService.preiseURL(fuerPeer: peerName, in: syncOrdner)
            ) ?? SyncPreisSnapshot(preispunkte: [])
            let kaeufe = await ladeKaeufe(ausOrdner: SyncSnapshotExportService.kaeufeOrdner(fuerPeer: peerName, in: syncOrdner))

            // `manifest.geraeteID` statt des Ordnernamens (GitHub #81): der
            // Ordnername ist eine reine Lesehilfe (Gerätename + Kurz-Suffix)
            // und keine verlässliche Kennung — die interne Peer-Identität
            // (`SyncPeerInfo.peerGeraeteID`, `SyncPeerZaehlerStand.peerGeraeteID`)
            // muss exakt der `SyncEvent.autorGeraeteID` desselben Geräts
            // entsprechen, sonst bricht u.a. der Cross-Device-Zähler-Abgleich.
            mergePaket(
                tombstones: tombstones, stamm: stamm, listen: listen, lernen: lernen, vorgaenge: vorgaenge, preise: preise, kaeufe: kaeufe,
                geraeteName: manifest.geraeteName, peerGeraeteID: manifest.geraeteID, erzeugtAm: manifest.erzeugtAm, context: context
            )
        }

        protokolliereEinkaufslistenStand(context: context)
        // Nur speichern, wenn ein Merge tatsächlich etwas verändert hat — ohne
        // diese Prüfung erzwang jeder Poll-Zyklus (5s/60s) eine echte
        // Store-Änderung, selbst wenn kein Peer neue Daten hatte (GitHub
        // #60/#70). ``context.hasChanges`` erfasst sowohl echte
        // Bereich-B/C/D-Änderungen als auch die (jetzt gedrosselte, siehe
        // ``SyncPeerInfo/aktualisiere(peerGeraeteID:geraeteName:zuletztGesehen:context:)``)
        // Peer-Metadaten-Pflege.
        guard context.hasChanges else { return true }
        try? context.save()
        return true
    }

    /// Wendet einen einzelnen, bereits vorliegenden Snapshot an (z.B. aus einem
    /// lokalen Backup, ``SyncErsetzenService``) — dieselbe Merge-Pipeline wie
    /// ``importiereSnapshots(context:)``, nur ohne den Peer-Ordner-Scan. Da der
    /// Kontext nach einem vorangegangenen
    /// ``SyncErsetzenService/loescheStoreDateiFallsAusstehend(url:)`` leer
    /// ist, IST dieser einzelne Merge-Durchlauf bereits der vollständige
    /// Neuaufbau — jede `mergeX`-Funktion legt bei fehlendem lokalem Treffer
    /// frisch an.
    @MainActor
    static func importiereEinzelnenSnapshot(_ snapshot: SyncSnapshot, peerGeraeteID: String, context: ModelContext) {
        merge(snapshot, peerGeraeteID: peerGeraeteID, context: context)
        guard context.hasChanges else { return }
        try? context.save()
    }

    /// Diagnose für Fälle wie GitHub #52-Nachfolgefund (unsichtbare
    /// Einkaufslisten-Dublette): protokolliert nach jedem Merge-Durchlauf den
    /// kompletten lokalen Einkaufslisten-Bestand samt Eintrags-Anzahl, damit
    /// sich Dubletten (zwei Listen mit demselben Namen, aber unterschiedlicher
    /// Eintragszahl) direkt aus dem Protokoll erkennen lassen, ohne dass der
    /// Nutzer manuell durch alle Listen wechseln muss.
    @MainActor
    private static func protokolliereEinkaufslistenStand(context: ModelContext) {
        guard SyncDebugLogger.istAktiv else { return }
        let alle = (try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []
        let beschreibung = alle.map { "\($0.name)=\($0.eintraege.count)" }.joined(separator: ", ")
        SyncDebugLogger.log(.einkaufslistenStand, details: "anzahl=\(alle.count) [\(beschreibung)]")
    }

    /// Lädt und dekodiert das Manifest eines Peer-Pakets (GitHub #82) über
    /// einen koordinierten Lesezugriff (``SyncDateiZugriff``, GitHub #52) — in
    /// einem `Task.detached`, damit ein bei Bedarf ausgelöster Download nicht
    /// den `MainActor` blockiert. `nil` sowohl bei fehlender Datei (Peer hat
    /// noch nie exportiert) als auch bei jedem Decoding-Fehler.
    nonisolated private static func ladeManifest(von url: URL) async -> SyncPeerManifest? {
        await Task.detached(priority: .utility) {
            guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
            return try? JSONDecoder().decode(SyncPeerManifest.self, from: daten)
        }.value
    }

    /// Wie ``ladeManifest(von:)``, generisch für die übrigen Paket-Teile
    /// (``SyncStammSnapshot``, ``SyncLernenSnapshot``, ``SyncVorgaengeSnapshot``,
    /// ``SyncPreisSnapshot``, `[SyncTombstoneSnapshot]`). `nil` bedeutet hier
    /// immer „noch nicht geschrieben, seit dieser Teil zuletzt beim Absender
    /// unverändert war" oder „Peer noch nicht auf das neue Format
    /// aktualisiert" — der Aufrufer setzt in beiden Fällen einen leeren
    /// Standardwert ein, nie einen Fehler.
    nonisolated private static func ladeTeil<T: Decodable & Sendable>(_ typ: T.Type, von url: URL) async -> T? {
        await Task.detached(priority: .utility) {
            guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: daten)
        }.value
    }

    /// Liest alle `<uuid>.json`-Dateien aus dem `kaeufe/`-Ordner eines Peers
    /// (``SyncKaeufeExportService``) — fehlende Datei/leerer Ordner ergibt
    /// bewusst eine leere Liste statt eines Fehlers (ein Peer ohne jeden
    /// `KaufEintrag` hat schlicht (noch) keinen `kaeufe/`-Ordner angelegt).
    nonisolated private static func ladeKaeufe(ausOrdner ordner: URL) async -> [KaufEintragSnapshot] {
        await Task.detached(priority: .utility) {
            guard let dateien = try? FileManager.default.contentsOfDirectory(
                at: ordner, includingPropertiesForKeys: nil
            ) else { return [] }
            return dateien.filter { $0.pathExtension == "json" }.compactMap { url -> KaufEintragSnapshot? in
                guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
                return try? JSONDecoder().decode(KaufEintragSnapshot.self, from: daten)
            }
        }.value
    }

    /// Paket-Pendant zu ``merge(_:peerGeraeteID:context:)`` (GitHub #82) —
    /// identische Reihenfolge/Merge-Logik, nur aus den unabhängig gelesenen
    /// Paket-Teilen zusammengesetzt statt aus einem einzelnen ``SyncSnapshot``
    /// (`listen` seit GitHub #85 ein eigener Teil statt in `stamm` gebündelt,
    /// siehe ``SyncListenSnapshot``). Ruft dieselben, unverändert wiederverwendeten
    /// `mergeX`-Funktionen auf — insbesondere bleibt die Reihenfolge
    /// „Tombstones zuerst" erhalten (siehe Typ-Doku „Architektur-Revision
    /// Alternative A"): `tombstones.json` gilt bewusst nicht nur für Bereich C
    /// (Einkaufsvorgang/KaufEintrag/Preispunkt), sondern auch für
    /// Stammdaten-Tombstones (Geschäft/Artikel/ArtikelKategorie/Einkaufsliste)
    /// — deshalb eine eigene, immer zuerst gelesene Datei statt Bündelung mit
    /// `vorgaenge.json`.
    @MainActor
    private static func mergePaket(
        tombstones: [SyncTombstoneSnapshot], stamm: SyncStammSnapshot, listen: SyncListenSnapshot, lernen: SyncLernenSnapshot,
        vorgaenge: SyncVorgaengeSnapshot, preise: SyncPreisSnapshot, kaeufe: [KaufEintragSnapshot],
        geraeteName: String, peerGeraeteID: String, erzeugtAm: Date, context: ModelContext
    ) {
        SyncPeerInfo.aktualisiere(peerGeraeteID: peerGeraeteID, geraeteName: geraeteName, zuletztGesehen: erzeugtAm, context: context)

        // Einmal für den gesamten Peer-Merge-Durchlauf geladen statt pro
        // Remote-Eintrag einzeln gefetcht (Performance-Fund, Muster wie
        // ``SyncTombstoneService/geloeschteIDs(art:context:)``) — sicher, weil
        // innerhalb eines einzelnen Durchlaufs keine der unten aufgerufenen
        // `mergeX`-Funktionen einen Alias auflöst, den eine ANDERE Funktion
        // (oder ein früherer Schleifendurchlauf derselben Funktion) gerade erst
        // in diesem selben Durchlauf registriert hat (jede Art wird nur von
        // genau einer `mergeX`-Funktion aufgelöst, jeder Eintrag hat eine
        // eigene `fremdeID`). Der nächste Peer in der äußeren Schleife
        // (``importiereSnapshots``) bekommt wieder eine frische Map inklusive
        // aller inzwischen registrierten Aliase.
        let aliase = SyncEntitaetsAliasService.alleAliaseNachArt(context: context)

        mergeTombstones(tombstones, aliase: aliase, context: context)

        let typZuordnung = mergeGeschaeftsTypen(stamm.geschaeftsTypen, context: context)
        let kategorieZuordnung = mergeArtikelKategorien(stamm.artikelKategorien, typZuordnung: typZuordnung, aliase: aliase, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            stamm.geschaefte, typZuordnung: typZuordnung, kategorieZuordnung: kategorieZuordnung,
            peerGeraeteID: peerGeraeteID, aliase: aliase, context: context
        )
        let artikelZuordnung = mergeArtikel(stamm.artikel, kategorieZuordnung: kategorieZuordnung, aliase: aliase, context: context)
        let listeZuordnung = mergeEinkaufslisten(stamm.einkaufslisten, aliase: aliase, context: context)
        mergeEinkaufslistenEintraege(
            listen.einkaufslistenEintraege, listeZuordnung: listeZuordnung, artikelZuordnung: artikelZuordnung, context: context
        )
        let einkaufsvorgangZuordnung = mergeEinkaufsvorgaenge(
            vorgaenge.einkaufsvorgaenge, geschaeftZuordnung: geschaeftZuordnung, listeZuordnung: listeZuordnung, aliase: aliase, context: context
        )
        mergeKaufEintraege(
            kaeufe, artikelZuordnung: artikelZuordnung, einkaufsvorgangZuordnung: einkaufsvorgangZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, kategorieZuordnung: kategorieZuordnung, context: context
        )
        mergePreispunkte(preise.preispunkte, artikelZuordnung: artikelZuordnung, geschaeftZuordnung: geschaeftZuordnung, context: context)
        mergeArtikelAliase(stamm.artikelAliase, artikelZuordnung: artikelZuordnung, context: context)
        mergeWarengruppenDistanzen(
            lernen.warengruppenDistanzen, geschaeftZuordnung: geschaeftZuordnung, kategorieZuordnung: kategorieZuordnung, context: context
        )
    }

    /// **Nur noch für den lokalen Backup-/Wiederherstellungs-Pfad**
    /// (``SyncErsetzenService``, GitHub #63) — der laufende Peer-Sync-Zyklus
    /// nutzt seit GitHub #82 ``mergePaket(tombstones:stamm:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``.
    /// Unverändert, da ein lokales Backup weiterhin sinnvoll ein einzelner,
    /// vollständiger In-Memory-``SyncSnapshot`` ist (kein Datei-Größen-/
    /// Wiederholungsproblem wie beim laufenden Sync-Zyklus).
    @MainActor
    private static func merge(_ snapshot: SyncSnapshot, peerGeraeteID: String, context: ModelContext) {
        SyncPeerInfo.aktualisiere(
            peerGeraeteID: peerGeraeteID, geraeteName: snapshot.geraeteName, zuletztGesehen: snapshot.erzeugtAm, context: context
        )

        // Läuft bewusst zuerst — siehe Typ-Doku „Architektur-Revision
        // Alternative A": ein frisch gelerntes Tombstone soll die
        // nachfolgenden „create new"-Zweige direkt greifen.
        // Alias-Map einmal geladen statt pro Eintrag gefetcht — siehe
        // ausführliche Begründung in ``mergePaket(tombstones:stamm:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``.
        let aliase = SyncEntitaetsAliasService.alleAliaseNachArt(context: context)
        mergeTombstones(snapshot.tombstones, aliase: aliase, context: context)

        let typZuordnung = mergeGeschaeftsTypen(snapshot.geschaeftsTypen, context: context)
        let kategorieZuordnung = mergeArtikelKategorien(snapshot.artikelKategorien, typZuordnung: typZuordnung, aliase: aliase, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            snapshot.geschaefte, typZuordnung: typZuordnung, kategorieZuordnung: kategorieZuordnung,
            peerGeraeteID: peerGeraeteID, aliase: aliase, context: context
        )
        let artikelZuordnung = mergeArtikel(snapshot.artikel, kategorieZuordnung: kategorieZuordnung, aliase: aliase, context: context)
        let listeZuordnung = mergeEinkaufslisten(snapshot.einkaufslisten, aliase: aliase, context: context)
        mergeEinkaufslistenEintraege(
            snapshot.einkaufslistenEintraege, listeZuordnung: listeZuordnung, artikelZuordnung: artikelZuordnung, context: context
        )
        let einkaufsvorgangZuordnung = mergeEinkaufsvorgaenge(
            snapshot.einkaufsvorgaenge, geschaeftZuordnung: geschaeftZuordnung, listeZuordnung: listeZuordnung, aliase: aliase, context: context
        )
        mergeKaufEintraege(
            snapshot.kaufEintraege, artikelZuordnung: artikelZuordnung, einkaufsvorgangZuordnung: einkaufsvorgangZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, kategorieZuordnung: kategorieZuordnung, context: context
        )
        mergePreispunkte(
            snapshot.preispunkte, artikelZuordnung: artikelZuordnung, geschaeftZuordnung: geschaeftZuordnung, context: context
        )
        mergeArtikelAliase(snapshot.artikelAliase, artikelZuordnung: artikelZuordnung, context: context)
        mergeWarengruppenDistanzen(
            snapshot.warengruppenDistanzen, geschaeftZuordnung: geschaeftZuordnung, kategorieZuordnung: kategorieZuordnung, context: context
        )
    }

    // MARK: - Tombstones (Löschungen)

    /// Übernimmt fremde Tombstones und löscht ein dadurch als entfernt
    /// markiertes, lokal noch vorhandenes Objekt — siehe ``SyncTombstone``.
    @MainActor
    private static func mergeTombstones(_ remote: [SyncTombstoneSnapshot], aliase: [String: [UUID: UUID]], context: ModelContext) {
        for tombstone in remote {
            let lokaleID = SyncEntitaetsAliasService.aufgeloesteID(fuer: tombstone.geloeschteID, art: tombstone.entitaetsArt, in: aliase)
            SyncTombstoneService.markiereGeloescht(art: tombstone.entitaetsArt, id: lokaleID, context: context)
            loescheFallsVorhanden(art: tombstone.entitaetsArt, id: lokaleID, context: context)
        }
    }

    /// Löscht das lokale Objekt der passenden Art mit `id`, falls es noch
    /// existiert — der zugehörige Tombstone wurde bereits separat vermerkt
    /// (``mergeTombstones(_:context:)``).
    @MainActor
    private static func loescheFallsVorhanden(art: String, id: UUID, context: ModelContext) {
        switch art {
        case SyncEntitaetsArt.geschaeft:
            var deskriptor = FetchDescriptor<Geschaeft>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case SyncEntitaetsArt.artikel:
            var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case SyncEntitaetsArt.artikelKategorie:
            var deskriptor = FetchDescriptor<ArtikelKategorie>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case SyncEntitaetsArt.einkaufsliste:
            var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case SyncEntitaetsArt.kaufEintrag:
            var deskriptor = FetchDescriptor<KaufEintrag>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
            // Bewusst KEIN `kaeufe/{id}.json`-Aufräumen hier (Live-Test-Fund,
            // GitHub #82): diese Funktion läuft pro Tombstone innerhalb von
            // `mergeTombstones`, das wiederum verschachtelt im bereits offen
            // gehaltenen Security-Scope von `importiereSnapshots` läuft — bei
            // einem realen Peer-Bestand potenziell drei- bis vierstellig oft
            // pro Zyklus. Ein zusätzliches, hier verschachteltes
            // `startAccessingSecurityScopedResource()`/`stop…()` je Aufruf
            // destabilisierte den Zugriff auf echten Geräten binnen Minuten
            // dauerhaft (kompletter Sync-Stillstand). Eine ggf. verwaist
            // liegenbleibende eigene `kaeufe/`-Datei ist rein Platzersparnis —
            // der bereits übernommene Tombstone schützt unabhängig davon vor
            // Wiederbelebung. Siehe ``SyncKaeufeExportService/entferneDateien(fuerKaufEintragIDs:)``
            // für den (gebündelten, unverschachtelten) Aufräumpfad des eigenen,
            // lokal verursachten Löschens.
        case SyncEntitaetsArt.preispunkt:
            var deskriptor = FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case SyncEntitaetsArt.einkaufsvorgang:
            var deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        default:
            break
        }
    }

    /// Vereinigt zwei Listen unter Erhalt der bestehenden Reihenfolge (relevant
    /// z.B. für ``Geschaeft/fuehrenderTyp``) — anders als ein `Set`-basierter
    /// Vereinigungs-Umweg, der die Reihenfolge nicht garantiert.
    private static func vereinigtGeordnet<T: Equatable>(_ bestehende: [T], _ neue: [T]) -> [T] {
        bestehende + neue.filter { !bestehende.contains($0) }
    }

    /// Weist `vereinigtGeordnet(bestehende, neue)` nur zu, falls sich dadurch
    /// tatsächlich etwas ändert (Live-Test-Nachfolgefund, Abschnitt 19): eine
    /// SwiftData-`@Relationship`-Eigenschaft gilt bei JEDER Zuweisung als
    /// verändert, auch wenn der neue Wert inhaltlich identisch zum alten ist —
    /// die bisherige unbedingte Zuweisung bei ``mergeArtikelKategorien``/
    /// ``mergeGeschaefte``/``vervollstaendige`` erzwang dadurch bei praktisch
    /// jedem Sync-Zyklus ein `context.hasChanges == true` und damit einen
    /// echten `context.save()`, selbst wenn kein Peer tatsächlich etwas Neues
    /// beigetragen hatte.
    private static func vereinigeGeordnetFallsNoetig<T: Equatable>(_ bestehende: inout [T], mit neue: [T]) {
        let vereinigt = vereinigtGeordnet(bestehende, neue)
        guard vereinigt != bestehende else { return }
        bestehende = vereinigt
    }

    // MARK: - GeschaeftTyp

    @MainActor
    private static func mergeGeschaeftsTypen(_ remote: [GeschaeftTypSnapshot], context: ModelContext) -> [UUID: GeschaeftTyp] {
        var zuordnung: [UUID: GeschaeftTyp] = [:]
        for eintrag in remote {
            zuordnung[eintrag.id] = GeschaeftTyp.mitNamen(eintrag.name, symbolName: eintrag.symbolName, context: context)
        }
        return zuordnung
    }

    // MARK: - ArtikelKategorie

    @MainActor
    private static func mergeArtikelKategorien(
        _ remote: [ArtikelKategorieSnapshot], typZuordnung: [UUID: GeschaeftTyp], aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: ArtikelKategorie] {
        var zuordnung: [UUID: ArtikelKategorie] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        // O(1) ID-Treffer statt linearem `first(where:)` pro Remote-Eintrag
        // (Performance-Fund) — der Namens-Fallback direkt darunter bleibt ein
        // linearer Scan: `localizedCaseInsensitiveCompare` ist locale-abhängig
        // und ließe sich nicht verlustfrei in einen Dictionary-Schlüssel
        // (z.B. `.lowercased()`) übersetzen, ohne das Matching-Verhalten in
        // Rand-Locales zu verändern — dieser Zweig greift zudem nur für
        // tatsächlich neue, noch nicht per ID/Alias bekannte Einträge.
        let alleLokalenNachID = Dictionary(alleLokalen.map { ($0.id, $0) }, uniquingKeysWith: { erster, _ in erster })
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.artikelKategorie, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.artikelKategorie, in: aliase)
            let lokal: ArtikelKategorie
            if let bekannte = alleLokalenNachID[aufgeloesteID] {
                lokal = bekannte
            } else if let namensTreffer = alleLokalen.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                if namensTreffer.id != eintrag.id {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.artikelKategorie, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                    )
                }
                lokal = namensTreffer
            } else {
                guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
                let naechsterIndex = (alleLokalen.map(\.sortIndex).max() ?? -1) + 1
                lokal = ArtikelKategorie(
                    name: eintrag.name, standardSymbol: eintrag.standardSymbol,
                    standardFarbeHex: eintrag.standardFarbeHex, sortIndex: naechsterIndex
                )
                lokal.id = eintrag.id
                context.insert(lokal)
            }
            vereinigeGeordnetFallsNoetig(&lokal.geschaeftsTypen, mit: eintrag.geschaeftsTypIDs.compactMap { typZuordnung[$0] })
            zuordnung[eintrag.id] = lokal
        }
        return zuordnung
    }

    // MARK: - Geschaeft

    @MainActor
    private static func mergeGeschaefte(
        _ remote: [GeschaeftSnapshot], typZuordnung: [UUID: GeschaeftTyp], kategorieZuordnung: [UUID: ArtikelKategorie],
        peerGeraeteID: String, aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Geschaeft] {
        var zuordnung: [UUID: Geschaeft] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []
        // O(1) ID-Treffer statt linearem Scan — siehe Begründung in
        // ``mergeArtikelKategorien(_:typZuordnung:aliase:context:)`` (der
        // Orts-Fallback direkt darunter bleibt linear, da
        // ``GeschaeftErkennungService/istGleicherOrt(nameA:koordinatenA:nameB:koordinatenB:)``
        // keine dictionary-taugliche Gleichheit ist).
        let alleLokalenNachID = Dictionary(alleLokalen.map { ($0.id, $0) }, uniquingKeysWith: { erster, _ in erster })
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.geschaeft, context: context)
        for eintrag in remote {
            let remoteKoordinaten: (breitengrad: Double, laengengrad: Double)? = {
                guard let b = eintrag.breitengrad, let l = eintrag.laengengrad else { return nil }
                return (b, l)
            }()
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.geschaeft, in: aliase)

            let lokal: Geschaeft
            if let bekanntes = alleLokalenNachID[aufgeloesteID] {
                lokal = bekanntes
            } else if let vorhandenes = alleLokalen.first(where: {
                GeschaeftErkennungService.istGleicherOrt(
                    nameA: $0.name, koordinatenA: koordinatenPaar($0),
                    nameB: eintrag.name, koordinatenB: remoteKoordinaten
                )
            }) {
                if vorhandenes.id != eintrag.id {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.geschaeft, fremdeID: eintrag.id, lokaleID: vorhandenes.id, context: context
                    )
                }
                lokal = vorhandenes
            } else {
                guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
                lokal = Geschaeft(name: eintrag.name, typen: [], adresse: nil)
                lokal.id = eintrag.id
                context.insert(lokal)
            }

            // Nur fehlende Werte ergänzen, nie überschreiben (siehe Typ-Doku).
            if lokal.adresse == nil { lokal.adresse = eintrag.adresse }
            if lokal.breitengrad == nil, let b = eintrag.breitengrad { lokal.breitengrad = b }
            if lokal.laengengrad == nil, let l = eintrag.laengengrad { lokal.laengengrad = l }
            if lokal.erkennungsradiusRaw == nil, let radius = eintrag.erkennungsradius { lokal.erkennungsradiusRaw = radius }

            vereinigeGeordnetFallsNoetig(&lokal.typen, mit: eintrag.typIDs.compactMap { typZuordnung[$0] })
            vereinigeGeordnetFallsNoetig(&lokal.kategorien, mit: eintrag.kategorieIDs.compactMap { kategorieZuordnung[$0] })
            vereinigeGeordnetFallsNoetig(
                &lokal.ausgeschlosseneKategorien, mit: eintrag.ausgeschlosseneKategorieIDs.compactMap { kategorieZuordnung[$0] }
            )
            for name in eintrag.alternativeNamen {
                lokal.alternativenNamenLernen(name)
            }
            let bereitsIgnoriert = Set(lokal.ignorierteArtikel.map { $0.erkannterName.lowercased() })
            for name in eintrag.ignorierteArtikelNamen where !bereitsIgnoriert.contains(name.lowercased()) {
                context.insert(IgnorierterArtikel(erkannterName: name, geschaeft: lokal))
            }

            // G-Counter statt additiver Delta-Regel (Abschnitt 4.2a, korrigiert
            // in Abschnitt 17): merkt sich nur den von diesem Peer gemeldeten
            // EIGENEN Beitrag unter der bereits lokal aufgelösten `lokal.id` —
            // `Geschaeft.anzahlEinkaufsvorgaenge` summiert beim Lesen selbst.
            SyncPeerZaehlerStand.merkeEigenenZuwachsDesPeers(
                peerGeraeteID: peerGeraeteID, geschaeftID: lokal.id,
                eigenerWertDesPeers: eintrag.eigeneAnzahlEinkaufsvorgaenge, context: context
            )
            lokal.umbauVerdacht = lokal.umbauVerdacht || eintrag.umbauVerdacht
            // unauffaelligeEinkaeufeInFolge bewusst NICHT gemergt — Streak-Zähler,
            // siehe Abschnitt 4.2a.

            zuordnung[eintrag.id] = lokal
        }
        return zuordnung
    }

    private static func koordinatenPaar(_ geschaeft: Geschaeft) -> (breitengrad: Double, laengengrad: Double)? {
        guard let b = geschaeft.breitengrad, let l = geschaeft.laengengrad else { return nil }
        return (b, l)
    }

    // MARK: - Artikel

    @MainActor
    private static func mergeArtikel(
        _ remote: [ArtikelSnapshot], kategorieZuordnung: [UUID: ArtikelKategorie], aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Artikel] {
        var zuordnung: [UUID: Artikel] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Artikel>())) ?? []
        // O(1) ID-Treffer statt linearem Scan — siehe Begründung in
        // ``mergeArtikelKategorien(_:typZuordnung:aliase:context:)``.
        let alleLokalenNachID = Dictionary(alleLokalen.map { ($0.id, $0) }, uniquingKeysWith: { erster, _ in erster })
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.artikel, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.artikel, in: aliase)
            if let bekannter = alleLokalenNachID[aufgeloesteID] {
                vervollstaendige(bekannter, mit: eintrag, kategorieZuordnung: kategorieZuordnung)
                zuordnung[eintrag.id] = bekannter
                continue
            }
            if let namensTreffer = alleLokalen.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                SyncEntitaetsAliasService.registriere(
                    entitaetsArt: SyncEntitaetsArt.artikel, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                )
                vervollstaendige(namensTreffer, mit: eintrag, kategorieZuordnung: kategorieZuordnung)
                zuordnung[eintrag.id] = namensTreffer
                continue
            }
            guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
            let neuer = Artikel(
                name: eintrag.name, symbolName: eintrag.symbolName, farbeHex: eintrag.farbeHex,
                kategorien: eintrag.kategorieIDs.compactMap { kategorieZuordnung[$0] },
                notiz: eintrag.notiz, einheit: Einheit(rawValue: eintrag.einheit) ?? .stueck, mengenSchritt: eintrag.mengenSchritt
            )
            neuer.id = eintrag.id
            context.insert(neuer)
            zuordnung[eintrag.id] = neuer
        }
        return zuordnung
    }

    private static func vervollstaendige(
        _ lokal: Artikel, mit eintrag: ArtikelSnapshot, kategorieZuordnung: [UUID: ArtikelKategorie]
    ) {
        vereinigeGeordnetFallsNoetig(&lokal.kategorien, mit: eintrag.kategorieIDs.compactMap { kategorieZuordnung[$0] })
        if lokal.notiz == nil { lokal.notiz = eintrag.notiz }
    }

    // MARK: - Einkaufsliste

    /// Namensbasiert gematcht wie ``mergeGeschaefte``/``mergeArtikel`` (Alias
    /// via ``SyncEntitaetsAliasService`` für spätere Bereich-A-``SyncEvent``s,
    /// die weiterhin die fremde ID referenzieren) — **revidiert** gegenüber der
    /// ursprünglichen ID-basierten Entscheidung (siehe `docs/DATENSYNCHRONISATION.md`
    /// Abschnitt 4.2): Jedes Gerät legt beim allerersten Start automatisch eine eigene
    /// Standardliste namens „Einkaufsliste" an (``Einkaufsliste/standard(context:)``),
    /// bereits bevor je synchronisiert wurde. Bei ID-basiertem Matching entstand
    /// dadurch beim ersten Beitritt zu einem bestehenden Sync-Ordner IMMER eine
    /// zweite, für den Nutzer unsichtbare Dublette „Einkaufsliste" — die
    /// tatsächlich synchronisierten Artikel landeten darauf, während die UI
    /// weiterhin die eigene (fast leere) Liste zeigte (GitHub #52-Nachfolgefund).
    /// Das war kein Rand-, sondern der Standardfall bei jedem Gerätebeitritt.
    @MainActor
    private static func mergeEinkaufslisten(
        _ remote: [EinkaufslisteSnapshot], aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Einkaufsliste] {
        var zuordnung: [UUID: Einkaufsliste] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []
        // O(1) ID-Treffer statt linearem Scan — siehe Begründung in
        // ``mergeArtikelKategorien(_:typZuordnung:aliase:context:)``.
        let alleLokalenNachID = Dictionary(alleLokalen.map { ($0.id, $0) }, uniquingKeysWith: { erster, _ in erster })
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.einkaufsliste, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.einkaufsliste, in: aliase)
            if let bekannte = alleLokalenNachID[aufgeloesteID] {
                zuordnung[eintrag.id] = bekannte
                continue
            }
            if let namensTreffer = alleLokalen.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                SyncEntitaetsAliasService.registriere(
                    entitaetsArt: SyncEntitaetsArt.einkaufsliste, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                )
                zuordnung[eintrag.id] = namensTreffer
                continue
            }
            guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
            let neue = Einkaufsliste(name: eintrag.name)
            neue.id = eintrag.id
            neue.erstelltAm = eintrag.erstelltAm
            context.insert(neue)
            zuordnung[eintrag.id] = neue
        }
        return zuordnung
    }

    // MARK: - EinkaufslistenEintrag (Bereich A, Sicherheitsnetz)

    /// Ergänzt fehlende Einkaufslisten-Mitgliedschaften additiv (siehe Typ-Doku
    /// „Architektur-Revision Alternative A" und ``SyncSnapshot/einkaufslistenEintraege``) —
    /// fängt Bereich-A-`SyncEvent`s auf, die ein Peer verpasst hat oder die
    /// gar nicht erst existierten, weil die Zuordnung zur lokalen Liste erst
    /// durch nachträgliches Namensmatching entstand (GitHub #52-Nachfolgefund).
    /// Entfernen bleibt weiterhin Aufgabe der `artikelEntfernt`-Events — hier
    /// wird nie etwas gelöscht.
    ///
    /// **Bug (GitHub #52-Nachfolgefund, behoben):** Ein Artikel, der lokal
    /// bereits per ``Einkaufsvorgang/artikelAbhaken(_:context:)`` abgehakt
    /// wurde, verliert dabei seinen ``EinkaufslistenEintrag`` als Seiteneffekt
    /// (siehe dort) — OHNE ein eigenes `artikelEntfernt`-Event, das andere
    /// Peers darüber informieren würde. Ein Peer, dessen Snapshot diesen
    /// Zustandswechsel noch nicht kennt, listet den Artikel deshalb weiterhin
    /// in ``SyncSnapshot/einkaufslistenEintraege`` — ohne diese Prüfung hätte
    /// das den bereits abgehakten Artikel hier wieder auf die offene Liste
    /// zurückgeholt (sichtbar als Artikel, der gleichzeitig "offen" und
    /// "abgehakt" erschien, bei aktivierter "alle Artikel zeigen"-Option
    /// sogar doppelt).
    @MainActor
    private static func mergeEinkaufslistenEintraege(
        _ remote: [EinkaufslistenEintragSnapshot], listeZuordnung: [UUID: Einkaufsliste], artikelZuordnung: [UUID: Artikel],
        context: ModelContext
    ) {
        guard !remote.isEmpty else { return }
        // Einmal vor der Schleife geladen statt pro Remote-Eintrag neu gefetcht
        // (Performance-Fund): `mergeEinkaufsvorgaenge` legt neue Vorgänge erst
        // NACH dieser Funktion an (siehe Aufrufreihenfolge in `mergePaket`), der
        // Bestand ist während dieses gesamten Durchlaufs also bereits vollständig.
        let alleVorgaenge = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        for eintrag in remote {
            guard let liste = listeZuordnung[eintrag.einkaufslisteID],
                  let artikel = artikelZuordnung[eintrag.artikelID],
                  !liste.enthaelt(artikel),
                  !istBereitsAbgehakt(artikel, aufListe: liste, alleVorgaenge: alleVorgaenge, context: context)
            else { continue }
            context.insert(EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: eintrag.menge, notiz: eintrag.notiz))
        }
    }

    /// Ob `artikel` in einem ``Einkaufsvorgang`` von `liste` bereits abgehakt
    /// ist (siehe Warnung in
    /// ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:context:)``).
    ///
    /// **Dieselbe „dangling Einkaufsvorgang"-Ursachen-Familie wie
    /// `SyncImportService.aufOffenenNachfolgerUmgeleitet` /
    /// `mergeEinkaufsvorgaenge` (siehe dort), hier im Bereich-A-Sicherheitsnetz:**
    /// Ein rein auf offene Vorgänge beschränkter Check verliert den bereits
    /// abgehakten Artikel genau in dem Moment, in dem „Einkauf abschließen"
    /// den Vorgang mit seinem `KaufEintrag` schließt — das Sicherheitsnetz
    /// hätte ihn dann beim nächsten (noch nicht aktuellen) Peer-Snapshot
    /// fälschlich wieder auf die offene Liste geholt. Ein geschlossener
    /// Vorgang zählt deshalb ebenfalls, aber NUR solange es für dieselbe
    /// Liste aktuell einen offenen Nachfolger gibt (über den gemeinsamen
    /// ``Einkaufsvorgang/offenerNachfolger(fuerListe:bevorzugtesGeschaeft:context:)``-Helfer)
    /// — sonst könnte ein Artikel, der vor Wochen einmal gekauft und später
    /// legitim neu zur Liste hinzugefügt wurde, nie wieder über dieses
    /// Sicherheitsnetz zurückkommen.
    @MainActor
    private static func istBereitsAbgehakt(
        _ artikel: Artikel, aufListe liste: Einkaufsliste, alleVorgaenge: [Einkaufsvorgang], context: ModelContext
    ) -> Bool {
        let vorgaengeFuerListe = alleVorgaenge.filter { $0.einkaufsliste == liste }
        return vorgaengeFuerListe.contains { vorgang in
            guard vorgang.kaufEintraege.contains(where: { $0.artikel == artikel }) else { return false }
            guard vorgang.endZeit != nil else { return true }
            return Einkaufsvorgang.offenerNachfolger(fuerListe: liste, bevorzugtesGeschaeft: vorgang.geschaeft, context: context) != nil
        }
    }

    // MARK: - Einkaufsvorgang (Bereich C)

    /// Zusätzlich zum ID-/Alias-Abgleich: ein lokal noch **offener**
    /// Einkaufsvorgang für dasselbe (`Geschaeft`, `Einkaufsliste`)-Paar gilt
    /// als derselbe realweltliche Einkauf wie ein zeitgleich von einem Peer
    /// begonnener — **Architektur-Revision, GitHub #52-Nachfolgefund:** Die
    /// ursprüngliche Annahme, beide Geräte würden beim gemeinsamen Einkaufen
    /// "automatisch über dieselbe Identität sprechen", war falsch. Jedes
    /// Gerät legt lokal (``EinkaufenView/einkaufSicherstellen()``) einen
    /// eigenen, zufällig-IDten Einkaufsvorgang an, sobald es selbst keinen
    /// offenen für das gewählte Geschäft/Liste kennt — noch bevor ein Sync
    /// stattfinden konnte. Ohne diesen Abgleich blieben zwei unabhängige
    /// Einkaufsvorgänge für denselben Einkauf bestehen: Abhaken auf Gerät A
    /// landete auf einem für Gerät B unsichtbaren Einkaufsvorgang, während
    /// parallel auf B eigene ``KaufEintrag``e für dieselben Artikel entstanden
    /// — die sich dann als Dubletten summierten. Alias analog
    /// ``mergeEinkaufslisten(_:context:)``. Ein bereits lokal abgeschlossener
    /// Einkauf wird nie durch einen (älteren) Remote-Stand wieder geöffnet —
    /// nur eine noch fehlende ``Einkaufsvorgang/endZeit`` wird nachgetragen.
    ///
    /// **Dieselbe „dangling Einkaufsvorgang"-Ursachen-Familie wie die
    /// Bereich-A-Umleitung in `SyncImportService`:** Ist der per ID/Alias
    /// gefundene `bekannter`-Vorgang selbst inzwischen abgeschlossen (dieses
    /// Gerät hat zwischenzeitlich "Einkauf abschließen" getippt), würde ein
    /// per Snapshot nachgereichter `KaufEintrag` sonst auf diesem
    /// geschlossenen, für die Einkaufsansicht unsichtbaren Vorgang landen —
    /// wird stattdessen per ``Einkaufsvorgang/offenerNachfolger(fuerListe:bevorzugtesGeschaeft:context:)``
    /// auf den aktuell offenen Nachfolger umgeleitet. Die `endZeit`-Nachtrag-
    /// Regel unten gilt in diesem Fall bewusst NICHT (das wäre die `endZeit`
    /// des ALTEN Vorgangs, fälschlich auf den neuen, offenen Nachfolger
    /// übertragen).
    ///
    /// **Bug (Live-Test-Fund, 2026-07-31): mehrfach eigenständig offene
    /// Vorgänge für dieselbe Liste innerhalb eines einzigen Merge-Durchlaufs.**
    /// `alleLokalen` wurde einmalig zu Beginn gefetcht — enthielt ein
    /// einzelner Peer-Snapshot mehrere `remote`-Einträge, die eigentlich
    /// alle denselben (bereits während dieses Durchlaufs frisch angelegten)
    /// offenen Vorgang meinen, "sah" der `offenerTreffer`-Zweig den gerade
    /// erst eingefügten Vorgang aus einem früheren Schleifendurchlauf nicht
    /// — jeder weitere Eintrag legte dadurch einen zusätzlichen,
    /// eigenständig offenen Vorgang für dieselbe Liste an, statt ihn
    /// wiederzuverwenden. Beobachtete Folge: mehrere lokale Vorgänge mit
    /// identischer `endZeit`, obwohl ihr `startZeit` klar danach lag — ein
    /// später verarbeiteter Eintrag traf per `offenerTreffer` auf einen
    /// dieser überzähligen offenen Duplikate und übertrug ihm die `endZeit`
    /// eines völlig anderen, längst abgeschlossenen Vorgangs. Für den
    /// Anwender sichtbar als: ein Artikel erscheint kurz als korrekt
    /// abgehakt/synchronisiert, verschwindet dann aber wieder von der
    /// abgehakten Liste (das Sicherheitsnetz in
    /// ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:context:)``
    /// verlangt für einen bereits geschlossenen Vorgang einen aktuell
    /// offenen Nachfolger — ein Vorgang mit fälschlich übernommener, längst
    /// vergangener `endZeit` erfüllt diese Bedingung nicht mehr). Fix: neu
    /// angelegte Vorgänge werden jetzt sofort in `alleLokalen` nachgetragen,
    /// zusätzlich verwirft eine neue Plausibilitätsprüfung jede `endZeit`,
    /// die vor dem eigenen `startZeit` läge.
    @MainActor
    private static func mergeEinkaufsvorgaenge(
        _ remote: [EinkaufsvorgangSnapshot], geschaeftZuordnung: [UUID: Geschaeft], listeZuordnung: [UUID: Einkaufsliste],
        aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Einkaufsvorgang] {
        var zuordnung: [UUID: Einkaufsvorgang] = [:]
        // `var` statt `let`: neu angelegte Vorgänge werden unten sofort
        // angehängt (siehe Bugfund unten) — bei den bereits enthaltenen
        // Referenzen (Klassentyp) liest jede Prädikat-Auswertung ohnehin den
        // aktuellen Live-Zustand, nur neu eingefügte Objekte fehlen der
        // beim Funktionsstart einmalig gefetchten Liste sonst.
        var alleLokalen = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        // O(1) ID-Treffer statt linearem Scan (Performance-Fund) — muss analog
        // zu `alleLokalen` bei jeder Neuanlage unten mitgeführt werden, sonst
        // fände ein späterer `eintrag` derselben Schleife einen gerade erst
        // angelegten Vorgang über den `bekannter`-Zweig nicht (der
        // `offenerTreffer`-Zweig bleibt bewusst ein linearer Scan über
        // `alleLokalen`, da er einen zusammengesetzten, nicht dictionary-
        // tauglichen Schlüssel aus `endZeit`/`geschaeft`/`einkaufsliste` prüft).
        var alleLokalenNachID = Dictionary(alleLokalen.map { ($0.id, $0) }, uniquingKeysWith: { erster, _ in erster })
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.einkaufsvorgang, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.einkaufsvorgang, in: aliase)
            let remoteGeschaeft = eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] }
            let remoteListe = eintrag.einkaufslisteID.flatMap { listeZuordnung[$0] }

            let vorhandener: Einkaufsvorgang
            let umgeleitetAufNachfolger: Bool
            if let bekannter = alleLokalenNachID[aufgeloesteID] {
                if bekannter.istAbgeschlossen, let liste = bekannter.einkaufsliste,
                   let offenerNachfolger = Einkaufsvorgang.offenerNachfolger(
                       fuerListe: liste, bevorzugtesGeschaeft: bekannter.geschaeft, context: context
                   ) {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.einkaufsvorgang, fremdeID: eintrag.id, lokaleID: offenerNachfolger.id, context: context
                    )
                    vorhandener = offenerNachfolger
                    umgeleitetAufNachfolger = true
                } else {
                    vorhandener = bekannter
                    umgeleitetAufNachfolger = false
                }
            } else if remoteListe == nil {
                // Audit-Fund (Abschnitt 25): OHNE bereits bekannten ID-/Alias-
                // Treffer darf ein Eintrag mit unauflösbarer `remoteListe` (auf
                // dem sendenden Gerät baumelnd) weder gematcht noch angelegt
                // werden — vorher griff der Guard nur im "else"-Zweig
                // (Neuanlage), aber der `offenerTreffer`-Zweig darunter
                // verglich `$0.einkaufsliste == remoteListe` OHNE zu prüfen, ob
                // `remoteListe` überhaupt ein echter Wert ist. Da `nil ==
                // nil` in Swift `true` ist, konnte das JEDEN lokal noch
                // offenen, selbst bereits kaputten (`einkaufsliste == nil`)
                // Vorgang als "Treffer" für einen völlig unabhängigen,
                // ebenfalls baumelnden Fremd-Eintrag matchen — zwei zufällig
                // gleichzeitig baumelnde Referenzen wurden dadurch fälschlich
                // als "derselbe reale Einkauf" aliasiert. Ohne bereits
                // bekannten ID-Treffer ist ein Eintrag ohne Liste hier
                // grundsätzlich nicht sinnvoll verarbeitbar — überspringen,
                // bevor überhaupt ein Matching-Versuch stattfindet.
                if SyncDebugLogger.istAktiv {
                    SyncDebugLogger.log(.einkaufsvorgangEintragUebersprungen, details: "vorgangID=\(eintrag.id) grund=unaufloesbareListe")
                }
                continue
            } else if let offenerTreffer = alleLokalen.first(where: {
                $0.endZeit == nil && $0.geschaeft == remoteGeschaeft && $0.einkaufsliste == remoteListe
            }) {
                if offenerTreffer.id != eintrag.id {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.einkaufsvorgang, fremdeID: eintrag.id, lokaleID: offenerTreffer.id, context: context
                    )
                }
                vorhandener = offenerTreffer
                umgeleitetAufNachfolger = false
            } else if geloeschteIDs.contains(aufgeloesteID) {
                // Retention-gelöschter (oder anderweitig entfernter) Vorgang
                // eines Peers, der ihn selbst noch führt — Tombstone
                // verhindert die sonst destruktionslose Wiederbelebung
                // (analog ``mergeGeschaefte``/``mergeArtikel``).
                if SyncDebugLogger.istAktiv {
                    SyncDebugLogger.log(.einkaufsvorgangEintragUebersprungen, details: "vorgangID=\(eintrag.id) grund=tombstone")
                }
                continue
            } else {
                // Live-Test-Fund (Abschnitt 20): `remoteListe` ist an dieser
                // Stelle bereits durch den Guard oben als nicht-nil
                // garantiert — ein neu angelegter Vorgang braucht immer eine
                // konkrete Liste, sonst wäre er für die gesamte App
                // unerreichbar (``EinkaufenView/aktuellerEinkauf`` und
                // ``offenerNachfolger(fuerListe:...)`` verlangen beide immer
                // eine konkrete Liste). Ein `remoteGeschaeft == nil` bleibt
                // legitim (Einkauf ohne gewähltes Geschäft ist Normalfall).
                let remoteListe = remoteListe!
                // Bewusst kein `abschliessen()` (würde zusätzlich
                // `Geschaeft.anzahlEinkaufsvorgaenge` erhöhen — das übernimmt
                // bereits die additive Zähler-Merge-Regel in
                // ``mergeGeschaefte``, ein zweites Mal hier wäre Doppelzählung).
                let neuer = Einkaufsvorgang(geschaeft: remoteGeschaeft, einkaufsliste: remoteListe, startZeit: eintrag.startZeit)
                neuer.id = eintrag.id
                context.insert(neuer)
                // Sofort anhängen (siehe Kommentar an ``alleLokalen``) — sonst
                // "sieht" ein späterer `eintrag` derselben Schleife diesen
                // gerade erst angelegten Vorgang nicht über den
                // `offenerTreffer`-Zweig und legt für dieselbe Liste
                // fälschlich einen weiteren, eigenständig offenen Vorgang an.
                alleLokalen.append(neuer)
                alleLokalenNachID[neuer.id] = neuer
                vorhandener = neuer
                umgeleitetAufNachfolger = false
            }

            // `remoteEndZeit >= vorhandener.startZeit`: defensive Plausibilitätsprüfung
            // (Live-Test-Fund, siehe Typ-Doku) — verwirft eine `endZeit`, die vor dem
            // eigenen `startZeit` läge. Ohne den Fix an ``alleLokalen`` oben konnte ein
            // per `offenerTreffer` fälschlich getroffener, in Wahrheit fremder Vorgang
            // die `endZeit` eines völlig anderen, bereits abgeschlossenen Vorgangs
            // übernehmen — beobachtet als mehrere lokale Vorgänge mit identischer
            // `endZeit`, obwohl ihr `startZeit` klar danach lag.
            //
            // Diagnose (2026-08-02, Nutzerbericht „Einkauf abschließen
            // synchronisiert nicht"): jeder der drei möglichen Gründe, warum
            // eine vorhandene Remote-`endZeit` NICHT übernommen wird, wird
            // hier einzeln protokolliert — Guard-Kaskade unverändert, nur um
            // die Log-Aufrufe erweitert.
            if let remoteEndZeit = eintrag.endZeit {
                if umgeleitetAufNachfolger {
                    if SyncDebugLogger.istAktiv {
                        SyncDebugLogger.log(
                            .einkaufsvorgangAbschlussNichtUebernommen,
                            details: "vorgangID=\(eintrag.id) grund=umgeleitetAufNachfolger"
                        )
                    }
                } else if let lokaleEndZeit = vorhandener.endZeit {
                    if SyncDebugLogger.istAktiv {
                        SyncDebugLogger.log(
                            .einkaufsvorgangAbschlussNichtUebernommen,
                            details: "vorgangID=\(eintrag.id) grund=bereitsAbgeschlossen lokaleEndZeit=\(lokaleEndZeit)"
                        )
                    }
                } else if remoteEndZeit < vorhandener.startZeit {
                    if SyncDebugLogger.istAktiv {
                        SyncDebugLogger.log(
                            .einkaufsvorgangAbschlussNichtUebernommen,
                            details: "vorgangID=\(eintrag.id) grund=endZeitVorStartZeit remoteEndZeit=\(remoteEndZeit) startZeit=\(vorhandener.startZeit)"
                        )
                    }
                } else {
                    vorhandener.endZeit = remoteEndZeit
                    if SyncDebugLogger.istAktiv {
                        SyncDebugLogger.log(
                            .einkaufsvorgangAbschlussUebernommen,
                            details: "vorgangID=\(eintrag.id) lokaleID=\(vorhandener.id) endZeit=\(remoteEndZeit)"
                        )
                    }
                }
            }
            zuordnung[eintrag.id] = vorhandener
        }
        return zuordnung
    }

    // MARK: - KaufEintrag (Bereich C)

    /// Union nach `id` — ein ``KaufEintrag`` ist ein unveränderliches
    /// historisches Ereignis, ein bereits lokal bekannter wird nie verändert,
    /// ein fehlender einfach übernommen (Referenzen auf die per Bereich-B
    /// gemergten lokalen Gegenstücke umgebogen).
    ///
    /// **`kategorieBesuchsIndex` wird bewusst NICHT aus dem Snapshot
    /// übernommen** (analog ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:indexFuerDistanzlernen:)``
    /// für den entsprechenden Bereich-A-Fall): jeder hier neu hinzukommende
    /// Eintrag stammt per Konstruktion von einem ANDEREN Gerät. Referenziert er
    /// (über ``mergeEinkaufsvorgaenge(_:geschaeftZuordnung:listeZuordnung:context:)``,
    /// z.B. weil zwei Geräte gleichzeitig im selben Geschäft an derselben Liste
    /// einkaufen) einen auch lokal offenen/geteilten ``Einkaufsvorgang``, und
    /// schließt DIESES Gerät ihn später ab, würde der aus dem Snapshot
    /// übernommene, vom anderen Gerät vergebene Index dessen Laufreihenfolge
    /// mit der eigenen vermischen und so die ladenspezifische Distanzmatrix
    /// verfälschen. Der Kauf zählt trotzdem korrekt zur Historie/Preisübersicht
    /// — nur die Reihenfolge-Analyse ignoriert ihn (siehe
    /// ``WarengruppenDistanzService/besuchsreihenfolge(fuer:)``, überspringt
    /// `nil`-Indizes bereits bewusst).
    /// Indexierter Existenz-Check statt vollem Fetch + linearem Scan (Analyse-
    /// Fund: `mergeKaufEintraege`/`mergePreispunkte` holten bisher bei jedem
    /// Zyklus ALLE lokalen Einträge und verglichen linear gegen jeden
    /// Remote-Eintrag — O(n·m), wächst mit der Gesamthistorie statt nur mit
    /// tatsächlich neuen Einträgen). Muster wie
    /// ``SyncEventService/istBereitsBekannt(_:context:)``.
    @MainActor
    private static func kaufEintragExistiertLokal(id: UUID, context: ModelContext) -> Bool {
        var deskriptor = FetchDescriptor<KaufEintrag>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }

    /// Wie ``kaufEintragExistiertLokal(id:context:)``, für ``Preispunkt``.
    @MainActor
    private static func preispunktExistiertLokal(id: UUID, context: ModelContext) -> Bool {
        var deskriptor = FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }

    @MainActor
    private static func mergeKaufEintraege(
        _ remote: [KaufEintragSnapshot], artikelZuordnung: [UUID: Artikel], einkaufsvorgangZuordnung: [UUID: Einkaufsvorgang],
        geschaeftZuordnung: [UUID: Geschaeft], kategorieZuordnung: [UUID: ArtikelKategorie], context: ModelContext
    ) {
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.kaufEintrag, context: context)
        for eintrag in remote {
            guard !kaufEintragExistiertLokal(id: eintrag.id, context: context) else { continue }
            // Retention- oder manuell gelöschter Eintrag eines Peers, der ihn
            // selbst noch führt — Tombstone verhindert die Wiederbelebung
            // (analog Bereich-B-Merges).
            guard !geloeschteIDs.contains(eintrag.id) else { continue }
            // Referenziert der Remote-Eintrag einen Einkaufsvorgang, der hier
            // nicht auflösbar ist (z.B. weil dieser Vorgang lokal bereits per
            // Tombstone gelöscht wurde, siehe `mergeEinkaufsvorgaenge` oben —
            // ein `nil` in `einkaufsvorgangZuordnung` bedeutet hier immer
            // "unauflösbar", nie "Vorgang absichtlich leer", da `remote`
            // ausschließlich echte, nicht-optionale Fremd-IDs enthält), würde
            // der `KaufEintrag` sonst verwaist (`einkaufsvorgang == nil`)
            // angelegt — und wäre danach dauerhaft unlöschbar, da
            // `KaufEintragBereinigungService.bereinigen` verwaiste Einträge nie
            // erfasst (Analyse-Fund: 53–59% aller `KaufEintrag`e in einem
            // Live-Export waren genau auf diesem Weg verwaist). Stattdessen wie
            // seinen Vorgang überspringen statt orphaned anzulegen.
            if let einkaufsvorgangID = eintrag.einkaufsvorgangID, einkaufsvorgangZuordnung[einkaufsvorgangID] == nil {
                continue
            }
            let neuer = KaufEintrag(
                artikel: eintrag.artikelID.flatMap { artikelZuordnung[$0] },
                geschaeft: eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] },
                kategorie: eintrag.kategorieID.flatMap { kategorieZuordnung[$0] },
                menge: eintrag.menge,
                datum: eintrag.datum,
                kategorieBesuchsIndex: nil
            )
            neuer.id = eintrag.id
            neuer.einkaufsvorgang = eintrag.einkaufsvorgangID.flatMap { einkaufsvorgangZuordnung[$0] }
            // Original-Schnappschuss-Namen erhalten statt aus den (ggf. seither
            // umbenannten) gemergten Objekten neu abzuleiten.
            neuer.artikelNameSnapshot = eintrag.artikelNameSnapshot
            neuer.geschaeftNameSnapshot = eintrag.geschaeftNameSnapshot
            context.insert(neuer)
        }
    }

    // MARK: - Preispunkt (Bereich C, GitHub #76)

    /// Union nach `id`, analog ``mergeKaufEintraege``: der Absender hat die
    /// Slowly-Changing-Dimension-Kompression bereits selbst vorgenommen
    /// (``PreispunktService``), ein empfangener ``Preispunkt`` ist deshalb ein
    /// unveränderliches historisches Ereignis — ein bereits lokal bekannter
    /// wird nie verändert, ein fehlender einfach übernommen.
    @MainActor
    private static func mergePreispunkte(
        _ remote: [PreispunktSnapshot], artikelZuordnung: [UUID: Artikel], geschaeftZuordnung: [UUID: Geschaeft], context: ModelContext
    ) {
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.preispunkt, context: context)
        for eintrag in remote {
            guard !preispunktExistiertLokal(id: eintrag.id, context: context) else { continue }
            guard !geloeschteIDs.contains(eintrag.id) else { continue }
            let neuer = Preispunkt(
                artikel: eintrag.artikelID.flatMap { artikelZuordnung[$0] },
                geschaeft: eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] },
                preis: eintrag.preis,
                datum: eintrag.datum,
                produktName: eintrag.produktName,
                alternativerName: eintrag.alternativerName
            )
            neuer.id = eintrag.id
            neuer.artikelNameSnapshot = eintrag.artikelNameSnapshot
            neuer.geschaeftNameSnapshot = eintrag.geschaeftNameSnapshot
            context.insert(neuer)
        }
    }

    // MARK: - ArtikelAlias (Bereich B, GitHub #76)

    /// **Nie destruktiv, analog allen Bereich-B-Regeln:** ein bereits lokal
    /// vorhandener Alias für denselben ``ArtikelAlias/erkannterName`` (case-
    /// insensitiv) wird nie durch den Remote-Wert überschrieben — nur ein
    /// bislang unbekannter Rohname wird ergänzt.
    @MainActor
    private static func mergeArtikelAliase(_ remote: [ArtikelAliasSnapshot], artikelZuordnung: [UUID: Artikel], context: ModelContext) {
        let alleLokalen = (try? context.fetch(FetchDescriptor<ArtikelAlias>())) ?? []
        for eintrag in remote {
            guard eintrag.alternativerName != nil || eintrag.artikelID != nil else { continue }
            guard !alleLokalen.contains(where: { $0.erkannterName.localizedCaseInsensitiveCompare(eintrag.erkannterName) == .orderedSame })
            else { continue }
            let neuer = ArtikelAlias(
                erkannterName: eintrag.erkannterName, alternativerName: eintrag.alternativerName,
                artikel: eintrag.artikelID.flatMap { artikelZuordnung[$0] }
            )
            neuer.id = eintrag.id
            context.insert(neuer)
        }
    }

    // MARK: - WarengruppenDistanz (Bereich D)

    @MainActor
    private static func mergeWarengruppenDistanzen(
        _ remote: [WarengruppenDistanzSnapshot], geschaeftZuordnung: [UUID: Geschaeft], kategorieZuordnung: [UUID: ArtikelKategorie],
        context: ModelContext
    ) {
        let alleLokalen = (try? context.fetch(FetchDescriptor<WarengruppenDistanz>())) ?? []
        for eintrag in remote {
            guard let kategorieA = kategorieZuordnung[eintrag.kategorieAID],
                  let kategorieB = kategorieZuordnung[eintrag.kategorieBID]
            else { continue }
            let geschaeft = eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] }
            let (kanonA, kanonB) = WarengruppenDistanz.kanonischesPaar(kategorieA, kategorieB)

            if let vorhandener = alleLokalen.first(where: {
                $0.geschaeft == geschaeft && $0.kategorieA == kanonA && $0.kategorieB == kanonB
            }) {
                vorhandener.distanz = (vorhandener.distanz + eintrag.distanz) / 2
            } else {
                let neuer = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kanonA, kategorieB: kanonB, distanz: eintrag.distanz)
                context.insert(neuer)
            }
        }
    }

    // MARK: - Debug: verwaiste fremde Exports aufräumen

    /// Debug-Werkzeug für manuelle Statuskonsolidierung
    /// (``SyncOrdnerSettingsView``): löscht alle Paket-Dateien (GitHub #82:
    /// `manifest.json`, `tombstones.json`, `stamm.json`, `lernen.json`,
    /// `vorgaenge.json`, `preise.json`; GitHub #85: `listen.json`; den
    /// kompletten `kaeufe/`-Ordner) fremder Peer-Ordner, deren
    /// `manifest.erzeugtAm` bereits über
    /// ``maximalesSnapshotAlter`` hinaus ist — dieselbe Schwelle, die
    /// ``importiereSnapshots(context:)`` ohnehin verwendet, um solche Peers
    /// beim Import zu ignorieren (siehe dort); hier werden die verwaisten
    /// Dateien zusätzlich sichtbar aus dem geteilten Ordner entfernt, statt
    /// nur beim Import stillschweigend übersprungen zu werden. Rührt weder
    /// den eigenen Export noch fremde Event-Ordner an. Rückgabewert meldet
    /// ausschließlich, ob der Ordnerzugriff (Berechtigung) geklappt hat.
    @discardableResult
    @MainActor
    static func raeumeVerwaisteFremdeExportsAuf() async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }
        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "raeumeVerwaisteFremdeExportsAuf")
            return false
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = try? FileManager.default.contentsOfDirectory(
            at: peersOrdner, includingPropertiesForKeys: nil
        ) else { return true }

        for peerOrdner in peerVerzeichnisse where !PeerOrdnerName.gehoertZu(peerOrdner.lastPathComponent, geraeteID: eigeneGeraeteID) {
            let peerName = peerOrdner.lastPathComponent
            guard let manifest = await ladeManifest(von: SyncSnapshotExportService.manifestURL(fuerPeer: peerName, in: syncOrdner)) else { continue }
            guard Date().timeIntervalSince(manifest.erzeugtAm) > maximalesSnapshotAlter else { continue }
            for url in [
                SyncSnapshotExportService.manifestURL(fuerPeer: peerName, in: syncOrdner),
                SyncSnapshotExportService.tombstonesURL(fuerPeer: peerName, in: syncOrdner),
                SyncSnapshotExportService.stammURL(fuerPeer: peerName, in: syncOrdner),
                SyncSnapshotExportService.listenURL(fuerPeer: peerName, in: syncOrdner),
                SyncSnapshotExportService.lernenURL(fuerPeer: peerName, in: syncOrdner),
                SyncSnapshotExportService.vorgaengeURL(fuerPeer: peerName, in: syncOrdner),
                SyncSnapshotExportService.preiseURL(fuerPeer: peerName, in: syncOrdner),
            ] {
                loescheKoordiniert(url)
            }
            // `loescheKoordiniert` entfernt via `FileManager.removeItem`, das
            // auch einen kompletten (Unter-)Ordner rekursiv löscht — kein
            // separates Verzeichnis-Löschwerkzeug nötig.
            loescheKoordiniert(SyncSnapshotExportService.kaeufeOrdner(fuerPeer: peerName, in: syncOrdner))
        }
        return true
    }

    /// Löscht über `NSFileCoordinator`, damit File-Provider-Erweiterungen
    /// (iCloud Drive/Synology Drive/…) von der Änderung erfahren — analog zum
    /// bestehenden Schreib-Muster in ``SyncSnapshotExportService``.
    nonisolated private static func loescheKoordiniert(_ url: URL) {
        let coordinator = NSFileCoordinator()
        var coordinatorFehler: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorFehler) { zielURL in
            try? FileManager.default.removeItem(at: zielURL)
        }
    }
}
