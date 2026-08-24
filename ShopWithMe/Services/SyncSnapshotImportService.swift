import Foundation
import SwiftData
import SwiftUI

/// Bereich-B/C/D-Import (`docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 5.3, Phase 3): liest Peer-Pakete (seit GitHub #82 mehrere
/// unabhängig fingerabdruck-geprüfte Dateien statt eines `export.json`-
/// Monolithen, siehe `docs/EXPORT_PAKET_UMBAU.md` und
/// ``mergePaket(tombstones:stamm:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``)
/// aus allen fremden Peer-Ordnern und merged Stammdaten (``GeschaeftTyp``,
/// ``Abteilung``, ``Geschaeft``, ``Artikel``, ``Einkaufsliste``,
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
/// (Abteilungen, Typen, ignorierte Artikel, alternative Namen) vereinigt statt
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
///    ``Geschaeft``/``Artikel``/``Abteilung``/``Einkaufsliste`` von
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

    /// Peer-Lebenszyklus, Baustein C: dynamischer Aufbewahrungs-Wasserstand
    /// für Sync-Events/Tombstones (ersetzt feste Fristen, siehe
    /// `docs/PEER_LEBENSZYKLUS.md`) — „ist ein Ereignis/Tombstone älter als
    /// dieser Wert, hat JEDER aktuell bekannte Peer nachweislich schon einen
    /// vollständigen Sync danach gehabt, hat es für die Gruppe keinen
    /// Mehrwert mehr". Liest live alle aktuell vorhandenen `peers/*/manifest.json`
    /// (kein separat gepflegter Cache — ``SyncPeerInfo`` dient einem anderen
    /// Zweck, siehe dort) und bildet das Minimum ihrer `erzeugtAm`-Zeitstempel.
    /// Baustein C0 (``SyncSnapshotExportService/exportierePaket(context:importErfolgreich:)``)
    /// stellt sicher, dass `erzeugtAm` das auch tatsächlich zertifiziert
    /// (nur bei erfolgreichem Import desselben Zyklus aktualisiert).
    ///
    /// `nil`, wenn (a) der Ordnerzugriff fehlschlägt, (b) aktuell kein
    /// anderer Peer bekannt ist (frisch verbundenes Gerät ohne Partner —
    /// noch keine Grundlage, sicher aufzuräumen), oder (c) sich auch nur
    /// EIN aktuell vorhandener Peer-Ordner nicht lesen lässt — bewusst nicht
    /// einfach übersprungen, sonst könnte der Wasserstand an genau dem Peer
    /// vorbei fortschreiten, der ihn eigentlich noch zurückhalten müsste.
    /// `nil` bedeutet für Aufrufer: in diesem Lauf nichts löschen.
    @MainActor
    static func aktuellerAufraeumWasserstand(in ordner: URL) async -> Date? {
        guard ordner.startAccessingSecurityScopedResource() else { return nil }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let peersOrdner = ordner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }) ?? nil else { return nil }

        let fremdePeerOrdner = peerVerzeichnisse.filter { !PeerOrdnerName.gehoertZu($0.lastPathComponent, geraeteID: eigeneGeraeteID) }
        guard !fremdePeerOrdner.isEmpty else { return nil }

        var wasserstand: Date?
        for peerOrdner in fremdePeerOrdner {
            guard let manifest = await ladeManifest(
                von: SyncSnapshotExportService.manifestURL(fuerPeer: peerOrdner.lastPathComponent, in: ordner)
            ) else { return nil }
            if wasserstand == nil || manifest.erzeugtAm < wasserstand! {
                wasserstand = manifest.erzeugtAm
            }
        }
        return wasserstand
    }

    /// Liefert `true` nur, wenn der Ordnerzugriff/das Listing erfolgreich war
    /// UND aktuell kein anderer Peer-Ordner existiert (nicht bei echten
    /// Fehlern wie fehlgeschlagenem Zugriff) — Grundlage für den manuellen
    /// „Ich bin sicher, dass ich der einzige Peer bin"-Bestätigungs-Button in
    /// `DebuggingView`. `aktuellerAufraeumWasserstand(in:)` liefert in genau
    /// diesem Fall bewusst `nil` (siehe dortige Doku) — dieser Zustand kann
    /// dauerhaft bestehen bleiben, wenn das Gerät nie einen Sync-Partner
    /// hatte oder bekommt, weshalb hier eine explizite, manuelle
    /// Nutzerbestätigung statt automatischen Aufräumens verlangt wird.
    @MainActor
    static func istAktuellEinzigerPeer(in ordner: URL) async -> Bool {
        guard ordner.startAccessingSecurityScopedResource() else { return false }
        defer { ordner.stopAccessingSecurityScopedResource() }

        let peersOrdner = ordner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await SyncDateiZugriff.mitZeitlimit({
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }) ?? nil else { return false }

        let fremdePeerOrdner = peerVerzeichnisse.filter { !PeerOrdnerName.gehoertZu($0.lastPathComponent, geraeteID: eigeneGeraeteID) }
        return fremdePeerOrdner.isEmpty
    }

    /// Peer-Lebenszyklus: entfernt ``SyncPeerInfo``- und zugehörige
    /// G-Counter-Einträge für jeden Peer, dessen Ordner nicht mehr in
    /// `bekannteOrdner` (dem aktuell gelesenen `peers/`-Listing) auftaucht —
    /// ohne Nutzerdialog, weil das Verschwinden des Ordners bereits eine
    /// Gruppen-Entscheidung (von einem anderen Gerät) ist.
    ///
    /// Nur aufgerufen, wenn `peers/` erfolgreich gelesen werden konnte (nicht
    /// `nil`) — ein transienter Zugriffsfehler darf keine DB-Einträge löschen.
    @MainActor
    static func bereinigeFehlendeGruppenPeers(bekannteOrdner: [URL], context: ModelContext) {
        let alle = (try? context.fetch(FetchDescriptor<SyncPeerInfo>())) ?? []
        for peer in alle {
            let hatOrdner = bekannteOrdner.contains {
                PeerOrdnerName.gehoertZu($0.lastPathComponent, geraeteID: peer.peerGeraeteID)
            }
            guard !hatOrdner else { continue }
            let geraeteID = peer.peerGeraeteID
            let zaehlerDeskriptor = FetchDescriptor<SyncPeerZaehlerStand>(
                predicate: #Predicate { $0.peerGeraeteID == geraeteID }
            )
            for zeile in (try? context.fetch(zaehlerDeskriptor)) ?? [] { context.delete(zeile) }
            let distanzDeskriptor = FetchDescriptor<WarengruppenDistanzPeerZaehlerStand>(
                predicate: #Predicate { $0.peerGeraeteID == geraeteID }
            )
            for zeile in (try? context.fetch(distanzDeskriptor)) ?? [] { context.delete(zeile) }
            context.delete(peer)
        }
    }

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
        let zugriffErfolgreich = syncOrdner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(aufrufstelle: "importiereSnapshots", erfolgreich: zugriffErfolgreich)
        guard zugriffErfolgreich else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereSnapshots")
            return false
        }
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "importiereSnapshots")
        }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await Task.detached(priority: .utility, operation: {
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }).value else { return true }

        // Peer-Lebenszyklus: DB-Einträge für nicht mehr vorhandene Peer-Ordner
        // automatisch bereinigen — Ordnerlisting war erfolgreich (nicht nil),
        // also ist das Fehlen eines Ordners eine definitive Gruppen-Entscheidung.
        bereinigeFehlendeGruppenPeers(bekannteOrdner: peerVerzeichnisse, context: context)

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
                geschaeftsTypen: [], abteilungen: [], geschaefte: [], artikel: [],
                einkaufslisten: [], produkte: [], produktnamen: []
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

    // MARK: - Laufender Sync: zurückgestellte Kandidaten (``SyncAbgleichKandidat``)

    /// Löst einen beim laufenden Hintergrund-Sync zurückgestellten
    /// Merge-Kandidaten (siehe Ambiguitäts-Rückstellung in
    /// ``mergeGeschaefte``/``mergeArtikel``/``mergeEinkaufslisten``) als
    /// „gleiche Entität" auf — anders als ``geschaeftsKandidatBestaetigen``
    /// (einmaliger Beitritts-Moment, transientes
    /// ``GeschaeftsAbgleichKandidat``) arbeitet das hier auf dem persistierten
    /// ``SyncAbgleichKandidat`` und deckt alle drei Entitätstypen ab.
    /// Übernimmt den gewählten Namen aufs lokale Objekt, registriert einen
    /// ``SyncEntitaetsAlias`` (damit künftige Bereich-A-``SyncEvent``s
    /// desselben Peers auflösbar bleiben) und entfernt den
    /// Warteschlangen-Eintrag. Wirkungslos auf das lokale Objekt, falls es
    /// zwischenzeitlich gelöscht wurde — der Warteschlangen-Eintrag wird
    /// trotzdem entfernt, sonst bliebe er dauerhaft hängen.
    @MainActor
    static func abgleichKandidatBestaetigen(_ kandidat: SyncAbgleichKandidat, gewaehlterName: String, context: ModelContext) {
        setzeName(gewaehlterName, entitaetsArt: kandidat.entitaetsArt, lokaleID: kandidat.lokaleID, context: context)
        SyncEntitaetsAliasService.registriere(
            entitaetsArt: kandidat.entitaetsArt, fremdeID: kandidat.fremdeID, lokaleID: kandidat.lokaleID, context: context
        )
        context.delete(kandidat)
    }

    /// Löst einen zurückgestellten Kandidaten als „unterschiedliche
    /// Entitäten" auf: legt das bisher zurückgehaltene Remote-Objekt jetzt
    /// regulär neu an — mit `id = fremdeID`, damit der nächste reguläre
    /// Merge-Durchlauf es sofort über den ID-Fast-Path erkennt und übrige
    /// Felder additiv nachträgt, ohne die Ambiguitäts-Prüfung erneut zu
    /// bemühen. Artikel-Symbol/-Farbe bekommen den Standard-Palettenwert
    /// (analog `MilkForUsImportService`/`ArtikelListView` für neu angelegte
    /// Artikel ohne explizite Auswahl) — der Nutzer kann sie danach wie
    /// gewohnt in der Artikel-Verwaltung anpassen.
    @MainActor
    static func abgleichKandidatAlsUnterschiedlichBestaetigen(_ kandidat: SyncAbgleichKandidat, context: ModelContext) {
        switch SyncEntitaetsArt.Kind(rawValue: kandidat.entitaetsArt) {
        case .geschaeft:
            let neu = Geschaeft(name: kandidat.fremderName, typen: [], adresse: nil)
            neu.id = kandidat.fremdeID
            context.insert(neu)
        case .artikel:
            let neu = Artikel(name: kandidat.fremderName, symbolName: SymbolPalette.alle[0], farbeHex: Color.artikelPalette[0])
            neu.id = kandidat.fremdeID
            context.insert(neu)
        case .einkaufsliste:
            let neu = Einkaufsliste(name: kandidat.fremderName)
            neu.id = kandidat.fremdeID
            context.insert(neu)
        case .abteilung, .geschaeftTyp, .einkaufsvorgang, .kaufEintrag, .preispunkt, .produkt, nil:
            // Nur die drei per Ambiguitäts-Rückstellung erzeugbaren
            // Kandidaten-Arten (siehe ``SyncAbgleichKandidat``) sind hier
            // strukturell erreichbar — die übrigen bleiben explizit
            // aufgeführt (GitHub #108), damit ein künftig neu ergänzter Fall
            // bewusst entschieden werden muss statt lautlos in einem
            // `default:` zu verschwinden. `nil` (unbekannter Rohwert eines
            // neueren Peers) verhält sich wie bisher: kein Neuanlegen.
            // `produkt` (GitHub #47, Schritt 2/5) erzeugt bewusst keinen
            // ``SyncAbgleichKandidat``, siehe ``mergeProdukte(_:artikelZuordnung:aliase:context:)``.
            break
        }
        context.delete(kandidat)
    }

    @MainActor
    private static func setzeName(_ name: String, entitaetsArt: String, lokaleID: UUID, context: ModelContext) {
        guard let entitaetsArt = SyncEntitaetsArt.Kind(rawValue: entitaetsArt) else { return }
        switch entitaetsArt {
        case .geschaeft:
            var deskriptor = FetchDescriptor<Geschaeft>(predicate: #Predicate { $0.id == lokaleID })
            deskriptor.fetchLimit = 1
            (try? context.fetch(deskriptor))?.first?.name = name
        case .artikel:
            var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == lokaleID })
            deskriptor.fetchLimit = 1
            (try? context.fetch(deskriptor))?.first?.name = name
        case .einkaufsliste:
            var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == lokaleID })
            deskriptor.fetchLimit = 1
            (try? context.fetch(deskriptor))?.first?.name = name
        case .abteilung, .geschaeftTyp, .einkaufsvorgang, .kaufEintrag, .preispunkt, .produkt:
            // Nur die drei per Ambiguitäts-Rückstellung abgleichbaren
            // Bereich-B-Typen (siehe ``SyncAbgleichKandidat``) können hier
            // ankommen — die übrigen sind strukturell unerreichbar, bleiben
            // aber explizit aufgeführt (GitHub #108), damit ein künftig neu
            // ergänzter Fall bewusst entschieden werden muss statt lautlos in
            // einem `default:` zu verschwinden. `produkt` (GitHub #47,
            // Schritt 2/5) erzeugt bewusst keinen ``SyncAbgleichKandidat`` —
            // siehe ``mergeProdukte(_:artikelZuordnung:aliase:context:)``.
            break
        }
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
            guard let dateien = SyncDateiZugriff.listeKoordiniert(ordner) else { return [] }
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
    /// Stammdaten-Tombstones (Geschäft/Artikel/Abteilung/Einkaufsliste)
    /// — deshalb eine eigene, immer zuerst gelesene Datei statt Bündelung mit
    /// `vorgaenge.json`.
    /// Sichtbarkeit bewusst `static` statt `private static` (GitHub #125):
    /// der Multipeer-Catch-up-Kanal (``MultipeerSyncService``) ruft dies als
    /// dritten Aufrufer neben dem Datei-Import unten und
    /// ``SyncErsetzenService`` direkt mit einem per `MCSession` empfangenen
    /// Paket auf — ohne Umweg über den Dateikanal. Reine Sichtbarkeitsänderung,
    /// keine Verhaltensänderung.
    @MainActor
    static func mergePaket(
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
        let abteilungZuordnung = mergeAbteilungen(stamm.abteilungen, typZuordnung: typZuordnung, aliase: aliase, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            stamm.geschaefte, typZuordnung: typZuordnung, abteilungZuordnung: abteilungZuordnung,
            peerGeraeteID: peerGeraeteID, aliase: aliase, context: context
        )
        let artikelZuordnung = mergeArtikel(stamm.artikel, abteilungZuordnung: abteilungZuordnung, peerGeraeteID: peerGeraeteID, aliase: aliase, context: context)
        let produktZuordnung = mergeProdukte(stamm.produkte, artikelZuordnung: artikelZuordnung, aliase: aliase, context: context)
        let listeZuordnung = mergeEinkaufslisten(stamm.einkaufslisten, peerGeraeteID: peerGeraeteID, aliase: aliase, context: context)
        mergeEinkaufslistenEintraege(
            listen.einkaufslistenEintraege, listeZuordnung: listeZuordnung, artikelZuordnung: artikelZuordnung,
            produktZuordnung: produktZuordnung, context: context
        )
        let einkaufsvorgangZuordnung = mergeEinkaufsvorgaenge(
            vorgaenge.einkaufsvorgaenge, geschaeftZuordnung: geschaeftZuordnung, listeZuordnung: listeZuordnung, aliase: aliase, context: context
        )
        mergeKaufEintraege(
            kaeufe, artikelZuordnung: artikelZuordnung, einkaufsvorgangZuordnung: einkaufsvorgangZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, abteilungZuordnung: abteilungZuordnung, peerGeraeteID: peerGeraeteID, context: context
        )
        mergePreispunkte(
            preise.preispunkte, produktZuordnung: produktZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, context: context
        )
        mergeProduktnamen(stamm.produktnamen, produktZuordnung: produktZuordnung, geschaeftZuordnung: geschaeftZuordnung, context: context)
        mergeWarengruppenDistanzen(
            lernen.warengruppenDistanzen, geschaeftZuordnung: geschaeftZuordnung, abteilungZuordnung: abteilungZuordnung,
            peerGeraeteID: peerGeraeteID, context: context
        )
        mergeArtikelGeschaeftVerfuegbarkeiten(
            lernen.artikelGeschaeftVerfuegbarkeiten, artikelZuordnung: artikelZuordnung, geschaeftZuordnung: geschaeftZuordnung, context: context
        )
        mergeGeschaeftBesuche(lernen.geschaeftBesuche, geschaeftZuordnung: geschaeftZuordnung, context: context)
        mergeArtikelListenKaeufe(lernen.artikelListenKaeufe, artikelZuordnung: artikelZuordnung, listeZuordnung: listeZuordnung, context: context)
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
        let abteilungZuordnung = mergeAbteilungen(snapshot.abteilungen, typZuordnung: typZuordnung, aliase: aliase, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            snapshot.geschaefte, typZuordnung: typZuordnung, abteilungZuordnung: abteilungZuordnung,
            peerGeraeteID: peerGeraeteID, aliase: aliase, context: context
        )
        let artikelZuordnung = mergeArtikel(snapshot.artikel, abteilungZuordnung: abteilungZuordnung, peerGeraeteID: peerGeraeteID, aliase: aliase, context: context)
        let produktZuordnung = mergeProdukte(snapshot.produkte, artikelZuordnung: artikelZuordnung, aliase: aliase, context: context)
        let listeZuordnung = mergeEinkaufslisten(snapshot.einkaufslisten, peerGeraeteID: peerGeraeteID, aliase: aliase, context: context)
        mergeEinkaufslistenEintraege(
            snapshot.einkaufslistenEintraege, listeZuordnung: listeZuordnung, artikelZuordnung: artikelZuordnung,
            produktZuordnung: produktZuordnung, context: context
        )
        let einkaufsvorgangZuordnung = mergeEinkaufsvorgaenge(
            snapshot.einkaufsvorgaenge, geschaeftZuordnung: geschaeftZuordnung, listeZuordnung: listeZuordnung, aliase: aliase, context: context
        )
        mergeKaufEintraege(
            snapshot.kaufEintraege, artikelZuordnung: artikelZuordnung, einkaufsvorgangZuordnung: einkaufsvorgangZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, abteilungZuordnung: abteilungZuordnung, peerGeraeteID: peerGeraeteID, context: context
        )
        mergePreispunkte(
            snapshot.preispunkte, produktZuordnung: produktZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, context: context
        )
        mergeProduktnamen(snapshot.produktnamen, produktZuordnung: produktZuordnung, geschaeftZuordnung: geschaeftZuordnung, context: context)
        mergeWarengruppenDistanzen(
            snapshot.warengruppenDistanzen, geschaeftZuordnung: geschaeftZuordnung, abteilungZuordnung: abteilungZuordnung,
            peerGeraeteID: peerGeraeteID, context: context
        )
        mergeArtikelGeschaeftVerfuegbarkeiten(
            snapshot.artikelGeschaeftVerfuegbarkeiten, artikelZuordnung: artikelZuordnung, geschaeftZuordnung: geschaeftZuordnung, context: context
        )
        mergeGeschaeftBesuche(snapshot.geschaeftBesuche, geschaeftZuordnung: geschaeftZuordnung, context: context)
        mergeArtikelListenKaeufe(
            snapshot.artikelListenKaeufe, artikelZuordnung: artikelZuordnung, listeZuordnung: listeZuordnung, context: context
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
    /// (``mergeTombstones(_:context:)``). Ein unbekannter Rohwert (z.B. von
    /// einem neueren Peer mit einer hier noch unbekannten Art) bleibt
    /// wirkungslos, analog dem bisherigen `default:`-Verhalten (GitHub #108).
    @MainActor
    private static func loescheFallsVorhanden(art: String, id: UUID, context: ModelContext) {
        guard let art = SyncEntitaetsArt.Kind(rawValue: art) else { return }
        switch art {
        case .geschaeft:
            var deskriptor = FetchDescriptor<Geschaeft>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .artikel:
            var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .abteilung:
            var deskriptor = FetchDescriptor<Abteilung>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .einkaufsliste:
            var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .kaufEintrag:
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
        case .preispunkt:
            var deskriptor = FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .produkt:
            var deskriptor = FetchDescriptor<Produkt>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .einkaufsvorgang:
            var deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.id == id })
            deskriptor.fetchLimit = 1
            if let objekt = try? context.fetch(deskriptor).first { context.delete(objekt) }
        case .geschaeftTyp:
            // GeschaeftTyp wird nie per Tombstone gelöscht (fetch-or-create
            // by Name, kein Alias-Register nötig, siehe
            // `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2) — bewusstes No-Op,
            // kein vergessener Fall.
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
    /// die bisherige unbedingte Zuweisung bei ``mergeAbteilungen``/
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

    /// Matcht wie ``GeschaeftTyp/mitNamen(_:symbolName:context:)`` (Name ist
    /// das eindeutige Merkmal), aber inline statt darüber delegiert — sonst
    /// wäre ``GeschaeftTypSnapshot/farbeHex`` beim Merge nicht erreichbar
    /// (``mitNamen`` kennt nur `symbolName`, keinen `farbeHex`-Parameter,
    /// Live-Fund: ein neu über Sync empfangener Geschäftstyp bekam bisher
    /// immer die neutrale Standardfarbe statt der vom Absender gewählten).
    @MainActor
    private static func mergeGeschaeftsTypen(_ remote: [GeschaeftTypSnapshot], context: ModelContext) -> [UUID: GeschaeftTyp] {
        var zuordnung: [UUID: GeschaeftTyp] = [:]
        var cache = LokalerBestandCache<GeschaeftTyp>(context: context)
        for eintrag in remote {
            let lokal: GeschaeftTyp
            if let namensTreffer = cache.alle.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                lokal = namensTreffer
                // Ersetzend statt additiv, siehe ``GeschaeftTyp/lamportZaehler``:
                // nur wenn der Absender einen echten, neueren Stand mitbringt.
                if eintrag.lamportZaehler > lokal.lamportZaehler {
                    lokal.name = eintrag.name
                    lokal.symbolName = eintrag.symbolName
                    lokal.farbeHex = eintrag.farbeHex
                    lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
                }
            } else {
                let naechsterIndex = (cache.alle.map(\.sortIndex).max() ?? -1) + 1
                lokal = GeschaeftTyp(name: eintrag.name, symbolName: eintrag.symbolName, farbeHex: eintrag.farbeHex, sortIndex: naechsterIndex)
                // Zählerstand des Absenders direkt übernehmen, nicht bei `0`
                // belassen — sonst „gewinnt" ein später eintreffender, aber
                // tatsächlich älterer Stand eines dritten Peers fälschlich
                // gegen diese frisch angelegte Kopie.
                lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
                context.insert(lokal)
                cache.nachfuehren(lokal)
            }
            LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
            zuordnung[eintrag.id] = lokal
        }
        return zuordnung
    }

    /// Bündelt den „lokalen Bestand einmal vorab fetchen, bei Neuanlage sofort
    /// nachführen"-Cache, der sich in ``mergeAbteilungen``,
    /// ``mergeGeschaefte``, ``mergeArtikel`` und ``mergeEinkaufslisten``
    /// wortgleich wiederholte (GitHub #105) — ohne das Nachführen nach einer
    /// Neuanlage würde ein zweiter passender Remote-Eintrag im selben Batch
    /// den gerade erst angelegten lokalen Treffer nicht finden und
    /// stattdessen eine Dublette erzeugen (Live-Bericht: „Brot" mehrfach auf
    /// derselben Liste, siehe Commit `7da06ea`).
    ///
    /// Kapselt bewusst NUR den Cache selbst, nicht das Matching — Name vs.
    /// Koordinaten vs. Ambiguitäts-Regel bleibt je Funktion unterschiedlich
    /// und braucht weiterhin einen linearen Scan über ``alle``:
    /// `localizedCaseInsensitiveCompare` ist locale-abhängig und ließe sich
    /// nicht verlustfrei in einen Dictionary-Schlüssel übersetzen, ohne das
    /// Matching-Verhalten in Rand-Locales zu verändern; ein Koordinaten-/
    /// Ambiguitäts-Vergleich (``mergeGeschaefte``) ist ohnehin keine
    /// dictionary-taugliche Gleichheit. Der Fallback-Scan greift zudem nur
    /// für tatsächlich neue, noch nicht per ID/Alias bekannte Einträge.
    ///
    /// **Bewusst nicht für ``mergeEinkaufsvorgaenge`` verwendet**, obwohl dort
    /// dasselbe Muster vorkommt: der dortige `offenerTreffer`-Fallback hat
    /// eine eigene, in einem separaten Live-Test-Fund gehärtete Sonderrolle
    /// (Geschäft+Liste+Status statt Name) — bewusst unangetastet gelassen,
    /// um diesen risikoärmeren Refactor nicht mit der dort dokumentierten,
    /// empfindlicheren Historie zu vermischen.
    private struct LokalerBestandCache<T: IdentifizierbaresModell> {
        private(set) var alle: [T]
        private var nachID: [UUID: T]

        init(context: ModelContext) {
            alle = (try? context.fetch(FetchDescriptor<T>())) ?? []
            nachID = Dictionary(alle.map { ($0.id, $0) }, uniquingKeysWith: { erster, _ in erster })
        }

        /// O(1) ID-Treffer statt linearem Scan (Performance-Fund).
        subscript(id: UUID) -> T? { nachID[id] }

        /// Muss nach jeder Neuanlage aufgerufen werden — siehe Typ-Doku.
        mutating func nachfuehren(_ neu: T) {
            alle.append(neu)
            nachID[neu.id] = neu
        }
    }

    // MARK: - Abteilung

    @MainActor
    private static func mergeAbteilungen(
        _ remote: [AbteilungSnapshot], typZuordnung: [UUID: GeschaeftTyp], aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Abteilung] {
        var zuordnung: [UUID: Abteilung] = [:]
        var cache = LokalerBestandCache<Abteilung>(context: context)
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.abteilung, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.abteilung, in: aliase)
            let lokal: Abteilung
            if let bekannte = cache[aufgeloesteID] {
                lokal = bekannte
            } else if let namensTreffer = cache.alle.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                if namensTreffer.id != eintrag.id {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.abteilung, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                    )
                }
                lokal = namensTreffer
            } else {
                guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
                let naechsterIndex = (cache.alle.map(\.sortIndex).max() ?? -1) + 1
                lokal = Abteilung(
                    name: eintrag.name, standardSymbol: eintrag.standardSymbol,
                    standardFarbeHex: eintrag.standardFarbeHex, sortIndex: naechsterIndex
                )
                lokal.id = eintrag.id
                // Zählerstand direkt übernehmen, siehe
                // ``mergeGeschaeftsTypen(_:context:)`` für die Begründung.
                lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
                context.insert(lokal)
                cache.nachfuehren(lokal)
            }
            vereinigeGeordnetFallsNoetig(&lokal.geschaeftsTypen, mit: eintrag.geschaeftsTypIDs.compactMap { typZuordnung[$0] })
            // Ersetzend statt additiv, siehe ``Abteilung/lamportZaehler``.
            if eintrag.lamportZaehler > lokal.lamportZaehler {
                lokal.name = eintrag.name
                lokal.standardSymbol = eintrag.standardSymbol
                lokal.standardFarbeHex = eintrag.standardFarbeHex
                lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
            }
            LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
            zuordnung[eintrag.id] = lokal
        }
        return zuordnung
    }

    // MARK: - Geschaeft

    @MainActor
    private static func mergeGeschaefte(
        _ remote: [GeschaeftSnapshot], typZuordnung: [UUID: GeschaeftTyp], abteilungZuordnung: [UUID: Abteilung],
        peerGeraeteID: String, aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Geschaeft] {
        var zuordnung: [UUID: Geschaeft] = [:]
        var cache = LokalerBestandCache<Geschaeft>(context: context)
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.geschaeft, context: context)
        for eintrag in remote {
            let remoteKoordinaten: (breitengrad: Double, laengengrad: Double)? = {
                guard let b = eintrag.breitengrad, let l = eintrag.laengengrad else { return nil }
                return (b, l)
            }()
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.geschaeft, in: aliase)

            let lokal: Geschaeft
            if let bekanntes = cache[aufgeloesteID] {
                lokal = bekanntes
            } else if let vorhandenes = cache.alle.first(where: {
                // Strengere Regel als bei der interaktiven Standort-Erkennung
                // (GitHub #86): automatischer Merge ohne Bestätigungsmöglichkeit
                // erfordert exakten Namen UND Distanz innerhalb der strengeren
                // der beiden individuellen ``Geschaeft/erkennungsradius``-Werte
                // — kein Teilstring-, kein reiner Koordinatenvergleich.
                GeschaeftErkennungService.istGleicherOrtFuerSyncMerge(
                    nameA: $0.name, koordinatenA: koordinatenPaar($0), radiusA: $0.erkennungsradius,
                    nameB: eintrag.name, koordinatenB: remoteKoordinaten,
                    radiusB: eintrag.erkennungsradius ?? GeschaeftErkennungService.koordinatenTreffertoleranz
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
                // Aktive Rückstellung statt stiller Dublette: matcht der
                // Eintrag nach der großzügigeren interaktiven Regel (Name
                // ODER Koordinaten, z.B. weil eine Seite gar keine
                // Koordinaten hat), aber nicht nach der strengen Regel oben,
                // wird er dem Nutzer zur Entscheidung vorgelegt
                // (`SyncOrdnerSettingsView`) statt sofort ein zweites,
                // unabhängiges Geschäft anzulegen. Existiert für diesen
                // Remote-Eintrag bereits ein Kandidat, bleibt er einfach
                // zurückgestellt, bis der Nutzer entscheidet.
                if let mehrdeutig = cache.alle.first(where: {
                    GeschaeftErkennungService.istMehrdeutigerBeitrittsKandidat(
                        nameA: $0.name, koordinatenA: koordinatenPaar($0), radiusA: $0.erkennungsradius,
                        nameB: eintrag.name, koordinatenB: remoteKoordinaten,
                        radiusB: eintrag.erkennungsradius ?? GeschaeftErkennungService.koordinatenTreffertoleranz
                    )
                }) {
                    if !SyncAbgleichKandidat.existiertBereits(
                        entitaetsArt: SyncEntitaetsArt.geschaeft, peerGeraeteID: peerGeraeteID, fremdeID: eintrag.id, context: context
                    ) {
                        context.insert(SyncAbgleichKandidat(
                            entitaetsArt: SyncEntitaetsArt.geschaeft, peerGeraeteID: peerGeraeteID, fremdeID: eintrag.id,
                            fremderName: eintrag.name, lokaleID: mehrdeutig.id, lokalerName: mehrdeutig.name
                        ))
                    }
                    continue
                }
                lokal = Geschaeft(name: eintrag.name, typen: [], adresse: nil)
                lokal.id = eintrag.id
                // Zählerstand direkt übernehmen, siehe
                // ``mergeGeschaeftsTypen(_:context:)`` für die Begründung.
                lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
                context.insert(lokal)
                cache.nachfuehren(lokal)
            }

            // Nur fehlende Werte ergänzen, nie überschreiben (siehe Typ-Doku).
            if lokal.adresse == nil { lokal.adresse = eintrag.adresse }
            if lokal.breitengrad == nil, let b = eintrag.breitengrad { lokal.breitengrad = b }
            if lokal.laengengrad == nil, let l = eintrag.laengengrad { lokal.laengengrad = l }
            if lokal.erkennungsradiusRaw == nil, let radius = eintrag.erkennungsradius { lokal.erkennungsradiusRaw = radius }
            if lokal.markenname == nil, let marke = eintrag.markenname { lokal.markenname = marke }

            vereinigeGeordnetFallsNoetig(&lokal.typen, mit: eintrag.typIDs.compactMap { typZuordnung[$0] })
            vereinigeGeordnetFallsNoetig(&lokal.abteilungen, mit: eintrag.abteilungIDs.compactMap { abteilungZuordnung[$0] })
            vereinigeGeordnetFallsNoetig(
                &lokal.ausgeschlosseneAbteilungen, mit: eintrag.ausgeschlosseneAbteilungIDs.compactMap { abteilungZuordnung[$0] }
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

            // Ersetzend statt additiv, siehe ``Geschaeft/lamportZaehler``.
            if eintrag.lamportZaehler > lokal.lamportZaehler {
                lokal.name = eintrag.name
                lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
            }
            LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)

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
        _ remote: [ArtikelSnapshot], abteilungZuordnung: [UUID: Abteilung], peerGeraeteID: String,
        aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Artikel] {
        var zuordnung: [UUID: Artikel] = [:]
        var cache = LokalerBestandCache<Artikel>(context: context)
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.artikel, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.artikel, in: aliase)
            if let bekannter = cache[aufgeloesteID] {
                vervollstaendige(bekannter, mit: eintrag, abteilungZuordnung: abteilungZuordnung)
                zuordnung[eintrag.id] = bekannter
                continue
            }
            if let namensTreffer = cache.alle.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                SyncEntitaetsAliasService.registriere(
                    entitaetsArt: SyncEntitaetsArt.artikel, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                )
                vervollstaendige(namensTreffer, mit: eintrag, abteilungZuordnung: abteilungZuordnung)
                zuordnung[eintrag.id] = namensTreffer
                continue
            }
            guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
            // Aktive Rückstellung statt stiller Dublette bei bloßem
            // Teilstring-Treffer ohne exakte Übereinstimmung (analog
            // ``mergeGeschaefte``, hier ohne zweite Dimension wie Koordinaten
            // — deshalb bewusst nur Teilstring statt echter
            // Ähnlichkeits-Heuristik) — z.B. „Milch" vom Peer trifft lokal
            // „H-Milch". Der Nutzer entscheidet aktiv statt zweier stiller,
            // unabhängiger Artikel.
            if let mehrdeutig = cache.alle.first(where: {
                $0.name.localizedCaseInsensitiveContains(eintrag.name) || eintrag.name.localizedCaseInsensitiveContains($0.name)
            }) {
                if !SyncAbgleichKandidat.existiertBereits(
                    entitaetsArt: SyncEntitaetsArt.artikel, peerGeraeteID: peerGeraeteID, fremdeID: eintrag.id, context: context
                ) {
                    context.insert(SyncAbgleichKandidat(
                        entitaetsArt: SyncEntitaetsArt.artikel, peerGeraeteID: peerGeraeteID, fremdeID: eintrag.id,
                        fremderName: eintrag.name, lokaleID: mehrdeutig.id, lokalerName: mehrdeutig.name
                    ))
                }
                continue
            }
            let neuer = Artikel(
                name: eintrag.name, symbolName: eintrag.symbolName, farbeHex: eintrag.farbeHex,
                abteilungen: eintrag.abteilungIDs.compactMap { abteilungZuordnung[$0] },
                notiz: eintrag.notiz, einheit: Einheit(rawValue: eintrag.einheit) ?? .stueck, mengenSchritt: eintrag.mengenSchritt
            )
            neuer.id = eintrag.id
            neuer.alternativeNamen = eintrag.alternativeNamen
            // Zählerstand direkt übernehmen, siehe
            // ``mergeGeschaeftsTypen(_:context:)`` für die Begründung.
            neuer.uebernehmeLamportZaehler(eintrag.lamportZaehler)
            LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
            context.insert(neuer)
            cache.nachfuehren(neuer)
            zuordnung[eintrag.id] = neuer
        }
        return zuordnung
    }

    private static func vervollstaendige(
        _ lokal: Artikel, mit eintrag: ArtikelSnapshot, abteilungZuordnung: [UUID: Abteilung]
    ) {
        vereinigeGeordnetFallsNoetig(&lokal.abteilungen, mit: eintrag.abteilungIDs.compactMap { abteilungZuordnung[$0] })
        if lokal.notiz == nil { lokal.notiz = eintrag.notiz }
        for name in eintrag.alternativeNamen {
            lokal.alternativenNamenLernen(name)
        }
        // Ersetzend statt additiv, siehe ``Artikel/lamportZaehler``.
        if eintrag.lamportZaehler > lokal.lamportZaehler {
            lokal.name = eintrag.name
            if let einheit = Einheit(rawValue: eintrag.einheit) { lokal.einheit = einheit }
            lokal.mengenSchritt = eintrag.mengenSchritt
            lokal.uebernehmeLamportZaehler(eintrag.lamportZaehler)
        }
        LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
    }

    // MARK: - Produkt (Bereich B, GitHub #47 Schritt 2/5)

    /// Analog ``mergeArtikel(_:abteilungZuordnung:peerGeraeteID:aliase:context:)``
    /// (ID/Alias → exakter Name → Neuanlage), aber der Namensabgleich läuft
    /// **innerhalb desselben, bereits aufgelösten Artikels** statt global —
    /// zwei Produkte mit gleichem Namen unter verschiedenen Artikeln sind
    /// keine Dubletten. Ohne aufgelösten Artikel (``eintrag/artikelID`` zeigt
    /// auf keinen bekannten Artikel) wird der Eintrag übersprungen — ein
    /// Produkt ohne Artikel ist fachlich bedeutungslos (siehe ``Produkt``).
    ///
    /// **Bewusst OHNE die bei ``mergeArtikel``/``mergeGeschaefte`` vorhandene
    /// Ambiguitäts-Rückstellung** (``SyncAbgleichKandidat``): Produkt hat in
    /// diesem Schritt noch keine eigene Verwaltungs-UI (folgt in Schritt
    /// 4/5), ein gelegentlich doppelt angelegtes, ähnlich (aber nicht exakt
    /// gleich) benanntes Produkt ist ein deutlich geringeres Risiko als bei
    /// Artikel/Geschäft — kann bei Bedarf in einem späteren Schritt ergänzt
    /// werden.
    ///
    /// Zweiter Durchlauf für ``Produkt/elternProdukt`` (rekursiv, z.B.
    /// Packungsgrößen): ein Remote-Eintrag kann in der Liste vor seinem
    /// Eltern-Eintrag stehen, die vollständige `zuordnung` steht daher erst
    /// nach dem ersten Durchlauf zur Verfügung.
    @MainActor
    private static func mergeProdukte(
        _ remote: [ProduktSnapshot], artikelZuordnung: [UUID: Artikel], aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Produkt] {
        var zuordnung: [UUID: Produkt] = [:]
        var cache = LokalerBestandCache<Produkt>(context: context)
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.produkt, context: context)
        for eintrag in remote {
            guard let artikel = eintrag.artikelID.flatMap({ artikelZuordnung[$0] }) else { continue }
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.produkt, in: aliase)
            if let bekanntes = cache[aufgeloesteID] {
                for name in eintrag.alternativeKlarnamen { bekanntes.alternativenKlarnamenLernen(name) }
                // Ersetzend statt additiv, siehe ``Produkt/lamportZaehler``.
                if eintrag.lamportZaehler > bekanntes.lamportZaehler {
                    bekanntes.name = eintrag.name
                    bekanntes.uebernehmeLamportZaehler(eintrag.lamportZaehler)
                }
                LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
                zuordnung[eintrag.id] = bekanntes
                continue
            }
            if let namensTreffer = cache.alle.first(where: {
                $0.artikel == artikel && $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame
            }) {
                SyncEntitaetsAliasService.registriere(
                    entitaetsArt: SyncEntitaetsArt.produkt, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                )
                for name in eintrag.alternativeKlarnamen { namensTreffer.alternativenKlarnamenLernen(name) }
                if eintrag.lamportZaehler > namensTreffer.lamportZaehler {
                    namensTreffer.uebernehmeLamportZaehler(eintrag.lamportZaehler)
                }
                LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
                zuordnung[eintrag.id] = namensTreffer
                continue
            }
            guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
            let neues = Produkt(name: eintrag.name, artikel: artikel, istStandard: eintrag.istStandard)
            neues.id = eintrag.id
            neues.alternativeKlarnamen = eintrag.alternativeKlarnamen
            // Zählerstand direkt übernehmen, siehe
            // ``mergeGeschaeftsTypen(_:context:)`` für die Begründung.
            neues.uebernehmeLamportZaehler(eintrag.lamportZaehler)
            LamportClock.beiEmpfang(fremderZaehler: eintrag.lamportZaehler)
            context.insert(neues)
            cache.nachfuehren(neues)
            zuordnung[eintrag.id] = neues
        }
        for eintrag in remote {
            guard let elternID = eintrag.elternProduktID, let lokal = zuordnung[eintrag.id], lokal.elternProdukt == nil else { continue }
            lokal.elternProdukt = zuordnung[elternID]
        }
        return zuordnung
    }

    // MARK: - Produktname (Bereich B, GitHub #47 Schritt 2/5)

    /// Nie destruktiv, Union nach (``Produkt``, ``Geschaeft``, Name). Kein
    /// ``SyncEntitaetsAlias``/Tombstone nötig (siehe ``SyncEntitaetsArt``):
    /// ein Produktname ohne gültige Produkt-/Geschäfts-Auflösung wird
    /// übersprungen.
    @MainActor
    private static func mergeProduktnamen(
        _ remote: [ProduktnameSnapshot], produktZuordnung: [UUID: Produkt], geschaeftZuordnung: [UUID: Geschaeft], context: ModelContext
    ) {
        var alleLokalen = (try? context.fetch(FetchDescriptor<Produktname>())) ?? []
        for eintrag in remote {
            guard let produkt = eintrag.produktID.flatMap({ produktZuordnung[$0] }) else { continue }
            let geschaeft = eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] }
            guard !alleLokalen.contains(where: {
                $0.produkt == produkt && $0.geschaeft == geschaeft
                    && $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame
            }) else { continue }
            let neuer = Produktname(name: eintrag.name, produkt: produkt, geschaeft: geschaeft)
            neuer.id = eintrag.id
            neuer.barcode = eintrag.barcode
            context.insert(neuer)
            alleLokalen.append(neuer)
        }
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
        _ remote: [EinkaufslisteSnapshot], peerGeraeteID: String, aliase: [String: [UUID: UUID]], context: ModelContext
    ) -> [UUID: Einkaufsliste] {
        var zuordnung: [UUID: Einkaufsliste] = [:]
        var cache = LokalerBestandCache<Einkaufsliste>(context: context)
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.einkaufsliste, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: eintrag.id, art: SyncEntitaetsArt.einkaufsliste, in: aliase)
            if let bekannte = cache[aufgeloesteID] {
                zuordnung[eintrag.id] = bekannte
                continue
            }
            if let namensTreffer = cache.alle.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                SyncEntitaetsAliasService.registriere(
                    entitaetsArt: SyncEntitaetsArt.einkaufsliste, fremdeID: eintrag.id, lokaleID: namensTreffer.id, context: context
                )
                zuordnung[eintrag.id] = namensTreffer
                continue
            }
            guard !geloeschteIDs.contains(aufgeloesteID) else { continue }
            // Aktive Rückstellung statt stiller Dublette — analog
            // ``mergeArtikel``, siehe Begründung dort.
            if let mehrdeutig = cache.alle.first(where: {
                $0.name.localizedCaseInsensitiveContains(eintrag.name) || eintrag.name.localizedCaseInsensitiveContains($0.name)
            }) {
                if !SyncAbgleichKandidat.existiertBereits(
                    entitaetsArt: SyncEntitaetsArt.einkaufsliste, peerGeraeteID: peerGeraeteID, fremdeID: eintrag.id, context: context
                ) {
                    context.insert(SyncAbgleichKandidat(
                        entitaetsArt: SyncEntitaetsArt.einkaufsliste, peerGeraeteID: peerGeraeteID, fremdeID: eintrag.id,
                        fremderName: eintrag.name, lokaleID: mehrdeutig.id, lokalerName: mehrdeutig.name
                    ))
                }
                continue
            }
            let neue = Einkaufsliste(name: eintrag.name)
            neue.id = eintrag.id
            neue.erstelltAm = eintrag.erstelltAm
            context.insert(neue)
            cache.nachfuehren(neue)
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
        produktZuordnung: [UUID: Produkt], context: ModelContext
    ) {
        guard !remote.isEmpty else { return }
        // Einmal vor der Schleife geladen statt pro Remote-Eintrag neu gefetcht
        // (Performance-Fund): `mergeEinkaufsvorgaenge` legt neue Vorgänge erst
        // NACH dieser Funktion an (siehe Aufrufreihenfolge in `mergePaket`), der
        // Bestand ist während dieses gesamten Durchlaufs also bereits vollständig.
        let alleVorgaenge = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        // Einmal pro Merge-Durchlauf berechnet statt pro Artikel — siehe
        // Begründung in ``istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``.
        let istAusDerZeitGefallen = SyncAktualitaetsService.istAusDerZeitGefallen(context: context)
        // GitHub #99: dauerhaftes Faktum, siehe ``ArtikelListenKauf``. Spiegelt
        // den Bestand zu Beginn DIESES Durchlaufs — ein im selben Zyklus per
        // ``mergeKaufEintraege(_:artikelZuordnung:einkaufsvorgangZuordnung:geschaeftZuordnung:abteilungZuordnung:peerGeraeteID:context:)``/
        // ``mergeArtikelListenKaeufe(_:artikelZuordnung:listeZuordnung:context:)``
        // (beide bewusst SPÄTER in der Aufrufreihenfolge, siehe dortige
        // Typ-Doku) neu eintreffender Beleg wirkt sich erst im nächsten Zyklus
        // aus — ein sich selbst auflösender Randfall, kein dauerhafter Fehler.
        // `alleEintraege` statt (vormals) `alleZeitstempel`, da dieser Zweig
        // jetzt BEIDE Zeitstempel-Seiten braucht, siehe unten.
        var bekannt = ArtikelListenKaufService.alleEintraege(context: context)
        for eintrag in remote {
            guard let liste = listeZuordnung[eintrag.einkaufslisteID], let artikel = artikelZuordnung[eintrag.artikelID]
            else { continue }
            let produkt = eintrag.produktID.flatMap { produktZuordnung[$0] }
            // ``enthaeltNamensgleich`` statt ``enthaelt`` (Namens-Backstop,
            // siehe dortige Doku): schützt speziell dieses additive
            // Sicherheitsnetz davor, denselben Artikel doppelt anzulegen, wenn
            // Bereich-A (``SyncImportService/importiereNeueEvents(context:)``)
            // im selben Zyklus bereits einen Eintrag für ein noch nicht per
            // Alias zusammengeführtes, aber namensgleiches lokales
            // ``Artikel``-Objekt angelegt hat.
            guard !liste.enthaeltNamensgleich(artikel, produkt: produkt) else { continue }
            // Architektur-Review (2026-08-10, siehe ArtikelListenKauf-Typ-Doku
            // „zuletztHinzugefuegtAm"): die Meldung dieses Peers zuerst
            // DAUERHAFT als robustes, additiv gemergtes Faktum vermerken —
            // sicher/idempotent unabhängig vom Ausgang der Prüfung direkt
            // danach (bewegt sich nur nach vorne), und Grundlage für EINE
            // symmetrische Entscheidung statt eines Vergleichs gegen den
            // unprotected Rohwert nur dieses einen Peers.
            ArtikelListenKaufService.vermerkeHinzugefuegtFallsNoetig(
                artikel: artikel, einkaufsliste: liste, am: eintrag.erstelltAm, bekannt: &bekannt, context: context
            )
            let schluessel = ArtikelListenKaufService.Schluessel(artikelID: artikel.id, einkaufslisteID: liste.id)
            // Diagnose (Nutzerbericht 2026-08-10, Folgefund zu Abschnitt 53):
            // dieser Zweig war bisher komplett stumm — weder „übersprungen,
            // weil bereits abgehakt" noch „übersprungen, weil unauflösbar"
            // hinterließ irgendeine Spur, obwohl genau diese Unterscheidung
            // beim vorherigen Nutzerbericht (fehlender Artikel nach frischem
            // Neuaufbau) den entscheidenden Hinweis geliefert hätte.
            guard !istBereitsAbgehakt(
                artikel, aufListe: liste, alleVorgaenge: alleVorgaenge, istAusDerZeitGefallen: istAusDerZeitGefallen,
                bekannterEintrag: bekannt[schluessel]
            ) else {
                if SyncDebugLogger.istAktiv {
                    SyncDebugLogger.log(
                        .einkaufslistenEintragSicherheitsnetzUebersprungen,
                        details: "artikel=\(artikel.name) liste=\(liste.name) istAusDerZeitGefallen=\(istAusDerZeitGefallen)"
                    )
                }
                continue
            }
            let neu = EinkaufslistenEintrag(
                einkaufsliste: liste, artikel: artikel, produkt: produkt, menge: eintrag.menge, notiz: eintrag.notiz
            )
            // Nutzerbericht (2026-08-10, Folgefund zu Abschnitt 55): OHNE diese
            // Zeile bekommt jede über dieses Sicherheitsnetz neu angelegte Zeile
            // per `EinkaufslistenEintrag.init`-Default `erstelltAm = Date()`
            // („jetzt", der lokale Import-Zeitpunkt) — nicht den tatsächlichen,
            // ursprünglichen Hinzufügungs-Zeitpunkt des sendenden Geräts. Bei
            // JEDEM weiteren Neuaufbau (`SyncErsetzenService`) „altert" ein
            // Artikel dadurch künstlich zurück auf „gerade eben hinzugefügt" —
            // exportiert dieses Gerät seinen Bestand später an ein DRITTES
            // Gerät weiter, sieht ein tatsächlich längst vor einem echten,
            // späteren Kauf hinzugefügter Artikel für die Abschnitt-55-Prüfung
            // fälschlich „neuer" aus als der Kauf, und das Sicherheitsnetz holt
            // ihn dort fälschlich zurück auf die offene Liste — beobachtet als
            // von Backup wiederbelebte, auf Bernhard bereits abgehakte und
            // abgeschlossene Artikel. Fehlt `eintrag.erstelltAm` (Peer auf
            // älterer App-Version), bleibt der Default „jetzt" bewusst stehen
            // — keine Verschlechterung gegenüber dem Vorzustand. Beeinflusst
            // NUR noch die Anzeige/dieses Feld selbst — die Offen/Abgehakt-
            // Entscheidung stützt sich seit obigem Fix auf das robustere
            // ``ArtikelListenKauf/zuletztHinzugefuegtAm``, nicht mehr auf
            // dieses Feld.
            if let eintragErstelltAm = eintrag.erstelltAm {
                neu.erstelltAm = eintragErstelltAm
            }
            context.insert(neu)
        }
    }

    /// Ob `artikel` in einem ``Einkaufsvorgang`` von `liste` bereits abgehakt
    /// ist (siehe Warnung in
    /// ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:context:)``).
    ///
    /// **Live-Test-Fund, dritter Nachtrag (Session 2026-08-03): dauerhafter
    /// Schutz im Regelfall statt „irgendein Vorgang noch offen".** Ein
    /// legitimes Neu-Hinzufügen Wochen nach dem Kauf (der ursprüngliche Grund
    /// für die Ausnahme unten) läuft über das eigene, Lamport-geordnete
    /// `SyncEventArt.artikelHinzugefuegt`-Ereignis — NICHT über dieses
    /// Sicherheitsnetz, das laut eigener Typ-Doku nur verpasste Ereignisse
    /// auffangen soll. Ein normal synchronisierendes Gerät hat ein solches
    /// Neu-Hinzufügen also längst über den direkten Event-Pfad erfahren;
    /// „ich habe irgendwann einen `KaufEintrag` dafür" ist für dieses Gerät
    /// deshalb ein dauerhaft belastbares Faktum, kein Zeitfenster nötig. Erst
    /// seit ein Fix (``EinkaufenView/weitereOffeneVorgaengeDerListe``) auch
    /// den letzten offenen Vorgang einer Liste schließen kann, gab es
    /// überhaupt Momente ohne offenen Vorgang — und genau dann hätte die
    /// alte, rein auf `endZeit == nil` gestützte Prüfung bereits gekaufte
    /// Artikel reihenweise wieder auf die offene Liste zurückgeholt
    /// (bestätigt per Live-Test: `Urlaub`-Listenstand sprang bei beiden
    /// Geräten kurz nach einem „Einkauf abschließen" unabhängig voneinander
    /// hoch und blieb auf unterschiedlichen Endständen stehen).
    ///
    /// Nur ein Gerät, das laut ``SyncAktualitaetsService/istAusDerZeitGefallen(context:)``
    /// tatsächlich lange genug nicht synchronisiert hat, um das direkte
    /// Ereignis verpasst haben zu können, fällt auf die alte, schwächere
    /// Ausnahme zurück: ein geschlossener Vorgang zählt dann ebenfalls als
    /// Schutz, aber NUR solange irgendein Vorgang für dieselbe Liste noch
    /// offen ist — dieselbe Unschärfe wie bisher, jetzt aber nur noch in dem
    /// seltenen Fall, für den sie ursprünglich gedacht war.
    ///
    /// **Vereinfacht seit der Ablösung der Vorgangs-Umleitung (Session
    /// 2026-08-03):** Die frühere Fassung suchte für einen bereits
    /// geschlossenen Treffer-Vorgang explizit dessen offenen Nachfolger
    /// (`Einkaufsvorgang.offenerNachfolger`). Das ist gleichwertig zu „existiert
    /// unter den Vorgängen dieser Liste überhaupt ein offener" — hier
    /// direkt so geprüft, ohne den (jetzt gelöschten) Umweg.
    ///
    /// **Bug (GitHub #99, behoben 2026-08-05): der obige Absatz „dauerhaft
    /// belastbares Faktum" stimmte nicht.** „Ich habe irgendwann einen
    /// `KaufEintrag` dafür" wurde bisher ausschließlich über noch
    /// existierende `KaufEintrag`e unter noch existierenden `Einkaufsvorgang`en
    /// geprüft (`vorgaengeFuerListe` unten) — `KaufEintragBereinigungService`
    /// löscht genau diese aber 48h nach Abschluss ihres Vorgangs, OHNE dass
    /// der Artikel-/Listenbezug in einem Tombstone erhalten bleibt. Ein Gerät
    /// verlor dadurch nach Ablauf der Karenzzeit seine einzige Evidenz, und
    /// ein Peer mit veraltetem `listen.json` konnte den Artikel klaglos
    /// zurückholen (Live-Test-Beleg: oszillierende Mitgliederzahl der Liste
    /// „Urlaub" über mehrere Stunden). ``ArtikelListenKauf``
    /// (`jemalsAbgehakteZeitstempel`) behebt das als dauerhaftes, von der
    /// 48h-Karenzzeit unabhängiges Faktum und wird deshalb VOR dem
    /// `vorgaengeFuerListe`-Scan geprüft; Letzterer bleibt als Fallback für
    /// Altbestand, den die einmalige Bestandsmigration
    /// (``DatenintegritaetsService/migriereArtikelListenKaeufeFallsNoetig(context:)``)
    /// nicht mehr rekonstruieren konnte (bereits vor dieser Migration
    /// bereinigte Käufe).
    ///
    /// **Nachtrag (Nutzerbericht 2026-08-10): das permanente Veto blockte
    /// auch ein legitimes ERNEUTES Hinzufügen.** „Ich habe irgendwann einen
    /// `KaufEintrag` dafür" wurde oben als für ein normal synchronisierendes
    /// Gerät „dauerhaft belastbares Faktum" begründet — mit der impliziten
    /// Annahme, ein solches Gerät habe ein Neu-Hinzufügen längst über den
    /// direkten Event-Pfad erfahren, bevor dieses Sicherheitsnetz überhaupt
    /// zum Zug kommt. Diese Annahme gilt nicht für ein Gerät, das gerade erst
    /// per ``SyncErsetzenService`` komplett neu aufgebaut wurde — es hat in
    /// diesem Moment noch keine eigene Bereich-A-Ereignis-Historie mit dem
    /// betroffenen Peer, UND ``SyncAktualitaetsService/istAusDerZeitGefallen(context:)``
    /// erkennt das nicht (misst nur „wie lange her ist mein letzter
    /// ERFOLGREICHER Zyklus" — ein frisch aktives, gerade erfolgreich
    /// synchronisierendes Gerät ist per Definition NICHT „aus der Zeit
    /// gefallen"). Live bestätigt über das Diagnose-Ereignis
    /// `sync_listeneintrag_sicherheitsnetz_uebersprungen`
    /// (`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 54), das genau
    /// diesen Zweig für mehrere real wiederkehrende Artikel feuern ließ.
    ///
    /// **Fix:** `jemalsAbgehakteZeitstempel` trägt jetzt (additiv-optional,
    /// siehe ``ArtikelListenKauf/zuletztAbgehaktAm``) den Zeitpunkt des
    /// zuletzt bekannten Kaufs statt nur der reinen Existenz. Liegt
    /// `eintragErstelltAm` (wann der Peer den Artikel laut seinem aktuellen
    /// Snapshot auf die Liste gesetzt hat) NACH diesem Zeitpunkt, ist der
    /// Listen-Eintrag nachweislich JÜNGER als der letzte bekannte Kauf — ein
    /// legitimes erneutes Hinzufügen, keine stale Resurrektion einer
    /// veralteten Momentaufnahme, also NICHT blockieren. Fehlt einer der
    /// beiden Zeitpunkte (Altbestand vor diesem Feld, oder ein Peer auf einer
    /// älteren App-Version ohne `erstelltAm` im Snapshot), bleibt es beim
    /// alten, strengeren Verhalten — permanentes Veto, keine Lockerung ohne
    /// echten Vergleichswert auf beiden Seiten.
    ///
    /// **Architektur-Review (2026-08-10), Ablösung des direkten
    /// `eintragErstelltAm`-Vergleichs:** der Vergleich oben stützte sich auf
    /// den ROHEN, ungeschützten Zeitstempel NUR dieses einen Peer-Snapshots —
    /// verpasste ein anderer Peer (oder ein früherer Zyklus desselben Peers)
    /// bereits ein NOCH neueres Hinzufügen, blieb das hier unberücksichtigt.
    /// Jetzt: der Aufrufer vermerkt jede Peer-Meldung zuerst dauerhaft additiv
    /// (``ArtikelListenKaufService/vermerkeHinzugefuegtFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``)
    /// und übergibt hier die resultierende, GERÄTEÜBERGREIFEND robusteste
    /// bekannte Zeile — der eigentliche Vergleich läuft über die einheitliche
    /// ``ArtikelListenKaufService/istOffen(hinzugefuegtAm:abgehaktAm:)``-Regel,
    /// siehe deren Doku für die unveränderten Nil-Fallback-Regeln (permanentes
    /// Veto ohne Vergleichswert auf beiden Seiten, wie im Absatz oben
    /// beschrieben).
    private static func istBereitsAbgehakt(
        _ artikel: Artikel, aufListe liste: Einkaufsliste, alleVorgaenge: [Einkaufsvorgang], istAusDerZeitGefallen: Bool,
        bekannterEintrag: ArtikelListenKauf?
    ) -> Bool {
        // Gate bewusst auf `zuletztAbgehaktAm`, NICHT auf `bekannterEintrag`
        // selbst (Regressionsfund: ``vonSicherheitsnetzGeerbterEintragTaeuschtBeiWeitergabeKeineFrischeVor()``,
        // siehe auch Kommentar am Aufrufer) — der Aufrufer vermerkt VOR diesem
        // Aufruf bereits das `hinzugefügt`-Faktum dieses `eintrag`s (siehe
        // ``ArtikelListenKaufService/vermerkeHinzugefuegtFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``),
        // wodurch für ein Gerät OHNE jedes bekannte Kauf-Faktum trotzdem eine
        // frisch angelegte ``ArtikelListenKauf``-Zeile existiert (nur mit
        // `zuletztHinzugefuegtAm` gefüllt). Ein `if let bekannterEintrag`
        // würde diese Zeile fälschlich wie einen bekannten Kauf behandeln und
        // — mangels `zuletztAbgehaktAm` — über ``ArtikelListenKaufService/istOffen(hinzugefuegtAm:abgehaktAm:)``s
        // konservativen Nil-Fallback blockieren, obwohl NIE ein Kauf bekannt
        // war. Nur ein tatsächlich vorhandenes `zuletztAbgehaktAm` rechtfertigt
        // den robusten Vergleich; sonst (wie zuvor) der ältere Fallback unten.
        if let zuletztAbgehaktAm = bekannterEintrag?.zuletztAbgehaktAm {
            return !ArtikelListenKaufService.istOffen(hinzugefuegtAm: bekannterEintrag?.zuletztHinzugefuegtAm, abgehaktAm: zuletztAbgehaktAm)
        }
        let vorgaengeFuerListe = alleVorgaenge.filter { $0.einkaufsliste == liste }
        guard vorgaengeFuerListe.contains(where: { $0.kaufEintraege.contains { $0.artikel == artikel } }) else { return false }
        guard istAusDerZeitGefallen else { return true }
        return vorgaengeFuerListe.contains { $0.endZeit == nil }
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
    /// stattfinden konnte. Ohne diesen Abgleich (`offenerTreffer` unten)
    /// blieben zwei unabhängige Einkaufsvorgänge für denselben Einkauf
    /// bestehen — sichtbar als doppelt gezählter Besuch
    /// (`Geschaeft.eigeneAnzahlEinkaufsvorgaenge`) und doppelte Zeile im
    /// Besuchsprotokoll. Alias analog ``mergeEinkaufslisten(_:context:)``.
    /// Ein bereits lokal abgeschlossener Einkauf wird nie durch einen
    /// (älteren) Remote-Stand wieder geöffnet — nur eine noch fehlende
    /// ``Einkaufsvorgang/endZeit`` wird nachgetragen.
    ///
    /// **Bewusst NICHT (mehr) Aufgabe dieser Funktion (Session 2026-08-03,
    /// Ablösung der Vorgangs-Umleitung):** Ist der per ID/Alias gefundene
    /// `bekannter`-Vorgang selbst inzwischen abgeschlossen, wird ein per
    /// Snapshot nachgereichter `KaufEintrag` NICHT mehr auf einen offenen
    /// Nachfolger umgeleitet — er bleibt einfach an `bekannter` hängen. Die
    /// Live-Ansicht braucht das nicht mehr: sie zeigt inzwischen alle
    /// Kaufeinträge einer Liste unabhängig vom Vorgang an (siehe
    /// `docs/DATENSYNCHRONISATION.md` Abschnitt 4.3). Nur der eigentliche
    /// Identitäts-Abgleich beim erstmaligen Zusammentreffen (`offenerTreffer`,
    /// s.u.) bleibt bestehen — der dient weiterhin dem Besuchszähler/-protokoll.
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
    /// eines völlig anderen, längst abgeschlossenen Vorgangs. Fix: neu
    /// angelegte Vorgänge werden jetzt sofort in `alleLokalen` nachgetragen,
    /// zusätzlich verwirft eine Plausibilitätsprüfung jede `endZeit`, die vor
    /// dem eigenen `startZeit` läge.
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
            if let bekannter = alleLokalenNachID[aufgeloesteID] {
                vorhandener = bekannter
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
            } else if let offenerTreffer = Einkaufsvorgang.kanonischer(unter: alleLokalen.filter({ kandidat in
                // `kaufEintraege.isEmpty` (Nachtrag): der Zweig soll
                // ausschließlich den Fall abdecken, dass zwei Geräte VOR
                // ihrem ersten Sync unabhängig je einen frischen, leeren
                // Vorgang für dieselbe Kombination angelegt haben — ein
                // solcher Kandidat hat per Definition noch keine eigenen
                // Käufe. Ein alter, lokal offen gebliebener Vorgang MIT
                // bereits vorhandenen `KaufEintrag`en ist nie dieser Fall,
                // sondern typischerweise ein vor einem (Wieder-)Beitritt
                // vergessener Rest (siehe
                // ``EinkaufsvorgangAbschlussService/schliesseAlleOffenenEinkaufsvorgaenge(context:)``,
                // die genau das beim eigentlichen Beitrittsmoment bereits
                // verhindert) — ohne diese Prüfung würden seine eigenen,
                // u.U. längst veralteten Käufe zusätzlich in die listenweite
                // "abgehakt"-Ansicht des zusammengeführten Vorgangs
                // einfließen.
                guard kandidat.endZeit == nil, kandidat.kaufEintraege.isEmpty,
                      kandidat.geschaeft == remoteGeschaeft, kandidat.einkaufsliste == remoteListe
                else { return false }
                // Timing-Plausibilität VOR der Aliasierung (Nutzerbericht
                // 2026-08-09, dann 2026-08-10 — zwei gegensätzliche Live-Test-
                // Funde am selben Zweig): ein bereits abgeschlossener
                // Remote-Eintrag darf nur matchen, wenn seine `endZeit` NICHT
                // vor dem `startZeit` DIESES Kandidaten liegt — dieselbe Regel
                // wie die Plausibilitätsprüfung weiter unten
                // (`remoteEndZeit >= vorhandener.startZeit`), hier aber VOR
                // statt NACH der Aliasierung angewendet.
                //
                // Erster Fund (2026-08-09, frischer Beitritt/„Ersetzen durch
                // Peer"): ein pauschales `eintrag.endZeit == nil`-Gate (nur
                // noch offene Remote-Einträge dürfen matchen) verhinderte
                // zwar zuverlässig, dass ein frisch angelegter eigener
                // Platzhalter mehrere fremde, LÄNGST abgeschlossene Vorgänge
                // gleichzeitig auf sich aliasierte (jeder scheiterte danach an
                // der Prüfung unten, blieb dadurch dauerhaft offen, ihre
                // KaufEintraege erschienen fälschlich als aktuell abgehakt) —
                // war damit aber zu grob.
                //
                // Zweiter Fund (2026-08-10, gemeinsames Live-Einkaufen): das
                // pauschale Gate blockierte auch den eigentlich vorgesehenen
                // Fall — Gerät A schließt seinen Einkauf gerade ab, während
                // Gerät B (noch offen, eigener frischer Vorgang derselben
                // Liste) das erst im NÄCHSTEN Zyklus mitbekommt. Der
                // Remote-Eintrag ist zu diesem Zeitpunkt technisch schon
                // `endZeit != nil`, gehört aber klar zur selben, gerade noch
                // laufenden Sitzung wie Gerät Bs Platzhalter (`startZeit`
                // liegt VOR dieser `endZeit`) — das pauschale Gate verwarf
                // auch das, Gerät Bs eigener Vorgang blieb fälschlich
                // dauerhaft offen hängen, „Einkauf abschließen“ kam nie an.
                //
                // Fix: statt „offen oder nicht“ zählt jetzt derselbe
                // Zeit-Vergleich wie unten — plausibel gleichzeitig (matcht)
                // vs. eindeutig historisch, lange vor Existenz dieses
                // Kandidaten (matcht nicht).
                guard let remoteEndZeit = eintrag.endZeit else { return true }
                return remoteEndZeit >= kandidat.startZeit
            })) {
                if offenerTreffer.id != eintrag.id {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.einkaufsvorgang, fremdeID: eintrag.id, lokaleID: offenerTreffer.id, context: context
                    )
                }
                vorhandener = offenerTreffer
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
                // unerreichbar (``EinkaufenView/aktuellerEinkauf`` verlangt
                // immer eine konkrete Liste). Ein `remoteGeschaeft == nil`
                // bleibt legitim (Einkauf ohne gewähltes Geschäft ist
                // Normalfall).
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
            }

            // Kanonisches `startZeit` auf das früheste bekannte anheben
            // (Nutzerbericht 2026-08-10, Folgefund zu Abschnitt 52): sobald
            // zwei Geräte über `offenerTreffer`/eine bereits registrierte
            // Alias auf denselben Vorgang zusammengeführt sind, spiegelt
            // `vorhandener.startZeit` nur noch, WANN DAS EIGENE Gerät sein
            // Objekt angelegt hat — bei einem Gerät, das erst später (z.B.
            // nach Neustart/Sync-Beitritt) einen eigenen Platzhalter erzeugte,
            // liegt das nach dem tatsächlichen, realen Beginn des gemeinsamen
            // Einkaufs auf der Gegenseite. Die Plausibilitätsprüfung unten
            // verglich bisher gegen dieses zu späte lokale `startZeit` und
            // verwarf dadurch einen legitimen, gerade eben eingetroffenen
            // Abschluss der Gegenseite (`remoteEndZeit` lag vor dem eigenen,
            // erst NACH dem eigentlichen Abschluss angelegten Platzhalter) —
            // „Einkauf abschließen“ kam beim anderen Gerät nie an. Ein
            // `eintrag.startZeit` VOR dem bisherigen `vorhandener.startZeit`
            // beweist, dass der reale gemeinsame Einkauf tatsächlich früher
            // begann, als dieses Gerät wusste — nur nach vorne (früher)
            // korrigiert, nie nach hinten, also ausschließlich permissiver.
            if eintrag.startZeit < vorhandener.startZeit {
                vorhandener.startZeit = eintrag.startZeit
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
            // synchronisiert nicht"): jeder der verbleibenden zwei Gründe, warum
            // eine vorhandene Remote-`endZeit` NICHT übernommen wird, wird hier
            // einzeln protokolliert — Guard-Kaskade unverändert (nur der
            // frühere `umgeleitetAufNachfolger`-Grund entfiel mit der Ablösung
            // der Vorgangs-Umleitung, Session 2026-08-03), nur um die
            // Log-Aufrufe erweitert.
            if let remoteEndZeit = eintrag.endZeit {
                if let lokaleEndZeit = vorhandener.endZeit {
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
                    // Nutzerbericht 2026-08-10 („Backup schließt ab, das kommt
                    // nie auf Bernhard an" — trotz per Log bestätigtem
                    // `endZeit`-Merge): per Diagnose-Logging bestätigt —
                    // `andereOffeneVorgaengeDerListe` bestand aus mehreren
                    // weiterhin offenen Vorgängen derselben Liste. Anders als
                    // der lokale Abschluss-Button
                    // (``EinkaufsvorgangAbschlussService/schliesseAbMitDuplikaten(anker:duplikate:context:)``,
                    // der bewusst ALLE offenen Vorgänge derselben Liste
                    // mitschließt, siehe dessen Typ-Doku) schloss dieser
                    // Merge-Zweig bisher NUR den per ID getroffenen
                    // `vorhandener` — ein zweiter, hier nicht mitgeschlossener
                    // offener Vorgang blieb offen, und genau AN DEM hing i.d.R.
                    // die UI (``EinkaufenView/aktuellerEinkauf``), sodass der
                    // Einkauf dort trotz erfolgreich übernommener `endZeit`
                    // weiterhin als offen mit denselben abgehakten Artikeln
                    // erschien. Mitgeschlossen `mit zaehleAlsBesuch: false`
                    // (analog zu den lokalen Duplikaten) — sie repräsentieren
                    // denselben Ladenbesuch wie `vorhandener`, sollen also nicht
                    // zusätzlich ``Geschaeft/eigeneAnzahlEinkaufsvorgaenge``
                    // erhöhen.
                    //
                    // NUR plausibel gleichzeitige Kandidaten (`startZeit <=
                    // remoteEndZeit`, dieselbe Regel wie beim `offenerTreffer`-
                    // Matching oben) — ohne dieses Gate schloss ein historischer
                    // Catch-up-Import (viele längst abgeschlossene Alt-Vorgänge
                    // eines frisch beigetretenen Geräts) fälschlich einen
                    // brandneuen, danach angelegten lokalen Platzhalter mit
                    // (Regressionsfund: ``mehrereBereitsAbgeschlosseneVorgaengeWerdenNichtAufFrischenLokalenPlatzhalterAliasiert()``).
                    let andereOffene = andereOffeneVorgaengeDerListe(vorhandener, bisZeitpunkt: remoteEndZeit, context: context)
                    for andererVorgang in andereOffene {
                        andererVorgang.abschliessen(am: remoteEndZeit, zaehleAlsBesuch: false)
                    }
                    if SyncDebugLogger.istAktiv {
                        SyncDebugLogger.log(
                            .einkaufsvorgangAbschlussUebernommen,
                            details: "vorgangID=\(eintrag.id) lokaleID=\(vorhandener.id) endZeit=\(remoteEndZeit) "
                                + "andereOffeneVorgaengeDerListeMitgeschlossen=\(andereOffene.count)"
                        )
                    }
                }
            }
            zuordnung[eintrag.id] = vorhandener
        }
        return zuordnung
    }

    /// Findet alle ANDEREN Einkaufsvorgänge für dieselbe Liste wie `vorgang`,
    /// die im Moment des Aufrufs noch offen sind UND plausibel derselben
    /// Sitzung angehören (`startZeit <= bisZeitpunkt` — bereits gestartet,
    /// bevor `vorgang` per `bisZeitpunkt` endete) — siehe Aufrufstelle in
    /// ``mergeEinkaufsvorgaenge(_:geschaeftZuordnung:listeZuordnung:aliase:context:)``
    /// für den Nutzerbericht, der diese Ergänzung ausgelöst hat, und deren
    /// Kommentar dort für die Begründung des Zeit-Gates.
    private static func andereOffeneVorgaengeDerListe(
        _ vorgang: Einkaufsvorgang, bisZeitpunkt: Date, context: ModelContext
    ) -> [Einkaufsvorgang] {
        guard let listeID = vorgang.einkaufsliste?.persistentModelID else { return [] }
        let vorgangID = vorgang.persistentModelID
        let deskriptor = FetchDescriptor<Einkaufsvorgang>(
            predicate: #Predicate<Einkaufsvorgang> { $0.einkaufsliste?.persistentModelID == listeID && $0.endZeit == nil }
        )
        return ((try? context.fetch(deskriptor)) ?? []).filter {
            $0.persistentModelID != vorgangID && $0.startZeit <= bisZeitpunkt
        }
    }

    // MARK: - KaufEintrag (Bereich C)

    /// Union nach `id` — ein ``KaufEintrag`` ist ein unveränderliches
    /// historisches Ereignis, ein bereits lokal bekannter wird nie verändert,
    /// ein fehlender einfach übernommen (Referenzen auf die per Bereich-B
    /// gemergten lokalen Gegenstücke umgebogen).
    ///
    /// **`abteilungBesuchsIndex` wird bewusst NICHT aus dem Snapshot
    /// übernommen** (analog ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:)``
    /// für den entsprechenden Bereich-A-Fall) — durchgesetzt über
    /// ``KaufEintrag/ursprungsGeraeteID`` (`peerGeraeteID`), das
    /// ``KaufEintrag/init(artikel:geschaeft:abteilung:preis:menge:datum:abteilungBesuchsIndex:ursprungsGeraeteID:)``
    /// zentral im Typ selbst nullt (GitHub #68): jeder hier neu hinzukommende
    /// Eintrag stammt per Konstruktion von einem ANDEREN Gerät. Referenziert er
    /// (über ``mergeEinkaufsvorgaenge(_:geschaeftZuordnung:listeZuordnung:context:)``,
    /// z.B. weil zwei Geräte gleichzeitig im selben Geschäft an derselben Liste
    /// einkaufen) einen auch lokal offenen/geteilten ``Einkaufsvorgang``, und
    /// schließt DIESES Gerät ihn später ab, würde der aus dem Snapshot
    /// übernommene, vom anderen Gerät vergebene Index dessen Laufreihenfolge
    /// mit der eigenen vermischen und so die ladenspezifische Distanzmatrix
    /// verfälschen. Der Kauf zählt trotzdem korrekt zur Historie/Preisübersicht
    /// — nur die Reihenfolge-Analyse ignoriert ihn (siehe
    /// ``AbteilungsDistanzService/besuchsreihenfolge(fuer:)``, überspringt
    /// `nil`-Indizes bereits bewusst).
    /// Vorab geladenes `Set<UUID>` statt eines Existenz-Checks pro
    /// Remote-Eintrag (Performance-Fund, analog
    /// ``SyncTombstoneService/geloeschteIDs(art:context:)`` im selben Merge-
    /// Durchlauf) — ursprünglich holten `mergeKaufEintraege`/`mergePreispunkte`
    /// bei jedem Zyklus ALLE lokalen Einträge und verglichen linear gegen
    /// jeden Remote-Eintrag (O(n·m)); ein Zwischenschritt ersetzte das durch
    /// einen indizierten Existenz-Check PRO Remote-Eintrag (`fetchCount` mit
    /// `id`-Prädikat, O(m) einzelne Datenbankzugriffe). Ein einmaliger
    /// Vorab-Fetch ist nochmal günstiger (ein Zugriff statt m), unkritisch für
    /// die Größe des lokalen Bestands: `KaufEintragBereinigungService` hält
    /// die lokale `KaufEintrag`-Tabelle durch die 48h-Karenzzeit + tägliche
    /// Automatik klein, unabhängig davon, ob ein Eintrag lokal oder per Sync
    /// entstanden ist.
    @MainActor
    private static func mergeKaufEintraege(
        _ remote: [KaufEintragSnapshot], artikelZuordnung: [UUID: Artikel], einkaufsvorgangZuordnung: [UUID: Einkaufsvorgang],
        geschaeftZuordnung: [UUID: Geschaeft], abteilungZuordnung: [UUID: Abteilung], peerGeraeteID: String, context: ModelContext
    ) {
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.kaufEintrag, context: context)
        let bekannteIDs = Set(((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []).map(\.id))
        // GitHub #99: dauerhaftes Sicherheitsnetz-Faktum, auch für
        // KaufEintraege, die nicht über das lokale Abhaken
        // (`Einkaufsvorgang.artikelAbhakenOhneEventAufzeichnung`), sondern
        // direkt per Bereich-C-Snapshot-Merge neu entstehen — dieser Zweig
        // legt `KaufEintrag`-Objekte direkt an, ohne über jene Funktion zu
        // laufen, bräuchte also sonst eine eigene Lücke im Sicherheitsnetz.
        var bekannteArtikelListenEintraege = ArtikelListenKaufService.alleEintraege(context: context)
        for eintrag in remote {
            guard !bekannteIDs.contains(eintrag.id) else { continue }
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
                abteilung: eintrag.abteilungID.flatMap { abteilungZuordnung[$0] },
                menge: eintrag.menge,
                datum: eintrag.datum,
                ursprungsGeraeteID: peerGeraeteID
            )
            neuer.id = eintrag.id
            neuer.einkaufsvorgang = eintrag.einkaufsvorgangID.flatMap { einkaufsvorgangZuordnung[$0] }
            // Original-Schnappschuss-Namen erhalten statt aus den (ggf. seither
            // umbenannten) gemergten Objekten neu abzuleiten.
            neuer.artikelNameSnapshot = eintrag.artikelNameSnapshot
            neuer.geschaeftNameSnapshot = eintrag.geschaeftNameSnapshot
            context.insert(neuer)

            if let artikel = neuer.artikel, let einkaufsliste = neuer.einkaufsvorgang?.einkaufsliste {
                // Nutzerbericht (2026-08-10): anders als das lokale Abhaken
                // (``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:abteilung:geschaeft:)``,
                // löscht dort explizit den offenen `EinkaufslistenEintrag``)
                // entfernte dieser Zweig den entsprechenden offenen Listen-
                // Eintrag ursprünglich NIE — ein Gerät, das den Artikel noch
                // offen führt (z.B. aus einem älteren, noch nicht
                // aktualisierten Bereich-B-Snapshot desselben Peers), behielt
                // ihn dauerhaft gleichzeitig als „offen" UND „abgehakt": genau
                // der Zustand, den ``EinkaufenView/offeneArtikel`` seit GitHub
                // #52 zwar in der Anzeige herausfiltert, aber die verwaiste
                // `EinkaufslistenEintrag`-Zeile blieb bestehen und blähte den
                // „X von Y"-Gesamtwert künstlich auf (live bestätigt: Gerät
                // zeigte „2 von 8" statt der tatsächlichen „2 von 6").
                //
                // Folgefund (2026-08-10, „kurzzeitiges Flackern der Liste
                // während eines Mehrgeräte-Syncs"): die daraufhin eingeführte
                // bedingungslose Löschung ging zu weit — sie griff auch, wenn
                // der Artikel NACH diesem (oft längst historischen, gerade
                // erst im Zuge eines großen Nachhol-Merges eintreffenden)
                // Nachzügler-Kauf ERNEUT auf die Liste gesetzt wurde
                // (typischer Fall: wiederkehrender Artikel). Ein direkter
                // Vergleich gegen `listenEintrag.erstelltAm` half nur
                // teilweise: dieses Feld übernimmt beim erneuten Hinzufügen
                // über einen Peer bewusst dessen ORIGINAL-Zeitpunkt (siehe
                // ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:produktZuordnung:context:)``)
                // und kann seinerseits von einem DRITTEN Gerät geerbt,
                // beliebig oft weitergereicht sein — ohne jede monotone
                // Absicherung. Derselbe Nachhol-Merge-Fall schlug dadurch mit
                // anderer Geräte-Verkettung erneut zu (live bestätigt: ein
                // Artikel verschwand trotz bestandener `erstelltAm <=
                // datum`-Prüfung noch einmal).
                //
                // Architektur-Review (2026-08-10): behoben durch das robuste,
                // additiv gemergte Gegenstück ``ArtikelListenKauf/zuletztHinzugefuegtAm``
                // (siehe dessen Typ-Doku für die Begründung) statt des rohen,
                // ungeschützten `erstelltAm`-Feldes dieser einen Zeile — nur
                // löschen, wenn NACHWEISLICH (über alle bekannten Geräte
                // hinweg additiv gemergt) kein NEUERES Hinzufügen als dieser
                // Kauf bekannt ist. Dieselbe Regel wie in
                // ``istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``,
                // hier nur umgekehrt aufgerufen (kein Materialisieren, sondern
                // ein Löschen, wenn NICHT mehr offen).
                let listenEintrag = einkaufsliste.eintrag(fuer: artikel)
                let schluessel = ArtikelListenKaufService.Schluessel(artikelID: artikel.id, einkaufslisteID: einkaufsliste.id)
                let zuletztHinzugefuegtAm = bekannteArtikelListenEintraege[schluessel]?.zuletztHinzugefuegtAm
                let listenEintragPasstZeitlich = !ArtikelListenKaufService.istOffen(
                    hinzugefuegtAm: zuletztHinzugefuegtAm, abgehaktAm: eintrag.datum
                )
                if let listenEintrag, listenEintragPasstZeitlich {
                    context.delete(listenEintrag)
                }
                if SyncDebugLogger.istAktiv {
                    // Diagnose (Nutzerbericht 2026-08-10, „Backup schließt ab,
                    // Artikel bleiben trotzdem auf der Liste", dann Folgefund
                    // „kurzzeitiges Flackern"): zeigt die tatsächlich
                    // verglichenen (robusten) Zeitstempel statt nur des
                    // Ergebnis-Bools — bleibt der Artikel trotzdem sichtbar
                    // offen, obwohl hier `entfernt=true` steht, liegt die
                    // Ursache NICHT in diesem Merge-Zweig, sondern z.B. in
                    // einem danach erneut angelegten Eintrag.
                    SyncDebugLogger.log(
                        .kaufEintragMergeListenEintragEntfernt,
                        details: "artikel=\(artikel.name) liste=\(einkaufsliste.name) listenEintragGefunden=\(listenEintrag != nil) "
                            + "entfernt=\(listenEintrag != nil && listenEintragPasstZeitlich) "
                            + "zuletztHinzugefuegtAm=\(zuletztHinzugefuegtAm.map { "\($0)" } ?? "-") kaufDatum=\(eintrag.datum)"
                    )
                }
                ArtikelListenKaufService.vermerkeAbgehaktFallsNoetig(
                    artikel: artikel, einkaufsliste: einkaufsliste, am: eintrag.datum,
                    bekannt: &bekannteArtikelListenEintraege, context: context
                )
            }
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
        _ remote: [PreispunktSnapshot], produktZuordnung: [UUID: Produkt],
        geschaeftZuordnung: [UUID: Geschaeft], context: ModelContext
    ) {
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.preispunkt, context: context)
        // Vorab geladenes Set statt Existenz-Check pro Remote-Eintrag — siehe
        // Begründung an ``mergeKaufEintraege``.
        let bekannteIDs = Set(((try? context.fetch(FetchDescriptor<Preispunkt>())) ?? []).map(\.id))
        for eintrag in remote {
            guard !bekannteIDs.contains(eintrag.id) else { continue }
            guard !geloeschteIDs.contains(eintrag.id) else { continue }
            // Produkt-Pflicht (siehe ``Preispunkt``-Typ-Doku): ohne auflösbares
            // Produkt gibt es keinen sinnvollen lokalen Preispunkt — der
            // sendende Peer hätte diesen Fall bereits selbst nicht mehr
            // anlegen dürfen, ein älterer/fremder Export ohne `produktID` wird
            // hier trotzdem defensiv übersprungen statt einen produktlosen
            // Preispunkt neu zu erzeugen.
            guard let produkt = eintrag.produktID.flatMap({ produktZuordnung[$0] }) else { continue }
            // Geschäfts-Pflicht bei ``Preispunkt`` (GitHub #128): verweist der
            // sendende Peer auf ein hier nicht auflösbares Geschäft (unbekannt/
            // bereits gelöscht), Fallback auf das Pseudo-Geschäft statt den
            // Preispunkt zu verwerfen — ``geschaeftNameSnapshot`` unten bewahrt
            // trotzdem den ursprünglichen Namen (siehe
            // ``Geschaeft/unbekanntesGeschaeft(context:)``).
            let geschaeft = eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] } ?? Geschaeft.unbekanntesGeschaeft(context: context)
            let neuer = Preispunkt(
                produkt: produkt,
                geschaeft: geschaeft,
                preis: eintrag.preis,
                datum: eintrag.datum,
                produktName: eintrag.produktName,
                alternativerName: eintrag.alternativerName
            )
            neuer.id = eintrag.id
            neuer.geschaeftNameSnapshot = eintrag.geschaeftNameSnapshot
            context.insert(neuer)
        }
    }

    // MARK: - WarengruppenDistanz (Bereich D)

    /// Gewichteter Mittelwert statt naiver 50/50-Mittelung (GitHub #87):
    /// dieselbe G-Counter-Herleitung wie ``mergeGeschaefte(_:typZuordnung:abteilungZuordnung:peerGeraeteID:aliase:context:)``
    /// für ``WarengruppenDistanz/beobachtungsAnzahl`` — merkt sich nur den von
    /// `peerGeraeteID` gemeldeten EIGENEN Beobachtungsanteil
    /// (``WarengruppenDistanzPeerZaehlerStand``), nie dessen bereits gemergten
    /// Gesamtwert, sonst würde derselbe Beitrag bei jedem erneuten
    /// Sync-Zyklus doppelt gezählt (Snapshots exportieren immer den
    /// kompletten aktuellen Bestand, keine Deltas).
    ///
    /// Die eigentliche Wert-Mischung (``WarengruppenDistanz/distanz``) geht
    /// noch einen Schritt weiter als der reine Zähler: anders als eine
    /// Summe ist eine gewichtete Mittelung NICHT idempotent, wenn man bei
    /// jedem Sync erneut mit dem VOLLEN aktuellen Peer-Gewicht mischt — ein
    /// unveränderter, wiederholt gesyncter Peer-Wert würde den lokalen Wert
    /// bei jedem Zyklus erneut in seine Richtung ziehen, obwohl keine
    /// einzige neue Beobachtung dazukam. Es fließt deshalb nur das Gewicht
    /// des tatsächlichen ZUWACHSES seit dem zuletzt bekannten Stand dieses
    /// Peers (``WarengruppenDistanzPeerZaehlerStand/zuletztGesehenerWert(peerGeraeteID:distanzID:context:)``)
    /// in die Mischung ein, gegen das aktuelle (bereits gedeckelte)
    /// Gesamtgewicht der lokalen Seite. Beide Gewichte sind zusätzlich bei
    /// ``WarengruppenDistanz/maximaleMergeGewichtung`` gedeckelt (siehe dort).
    @MainActor
    private static func mergeWarengruppenDistanzen(
        _ remote: [WarengruppenDistanzSnapshot], geschaeftZuordnung: [UUID: Geschaeft], abteilungZuordnung: [UUID: Abteilung],
        peerGeraeteID: String, context: ModelContext
    ) {
        let alleLokalen = (try? context.fetch(FetchDescriptor<WarengruppenDistanz>())) ?? []
        for eintrag in remote {
            guard let abteilungA = abteilungZuordnung[eintrag.abteilungAID],
                  let abteilungB = abteilungZuordnung[eintrag.abteilungBID]
            else { continue }
            let geschaeft = eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] }
            let (kanonA, kanonB) = WarengruppenDistanz.kanonischesPaar(abteilungA, abteilungB)

            let vorhandener: WarengruppenDistanz
            if let treffer = alleLokalen.first(where: {
                $0.geschaeft == geschaeft && $0.abteilungA == kanonA && $0.abteilungB == kanonB
            }) {
                vorhandener = treffer
            } else {
                vorhandener = WarengruppenDistanz(geschaeft: geschaeft, abteilungA: kanonA, abteilungB: kanonB, distanz: WarengruppenDistanz.initialwert)
                vorhandener.eigeneBeobachtungsAnzahl = 0
                context.insert(vorhandener)
            }

            let neuerPeerWert = max(eintrag.eigeneAnzahlBeobachtungen, 0)
            let vorherigerPeerWert = WarengruppenDistanzPeerZaehlerStand.zuletztGesehenerWert(
                peerGeraeteID: peerGeraeteID, distanzID: vorhandener.id, context: context
            )
            let peerZuwachs = min(max(neuerPeerWert - vorherigerPeerWert, 0), WarengruppenDistanz.maximaleMergeGewichtung)
            let lokaleGewichtung = vorhandener.mergeGewichtung
            if peerZuwachs > 0 {
                vorhandener.distanz = (vorhandener.distanz * Double(lokaleGewichtung) + eintrag.distanz * Double(peerZuwachs))
                    / Double(lokaleGewichtung + peerZuwachs)
            }
            WarengruppenDistanzPeerZaehlerStand.merkeEigenenZuwachsDesPeers(
                peerGeraeteID: peerGeraeteID, distanzID: vorhandener.id,
                eigenerWertDesPeers: neuerPeerWert, context: context
            )
        }
    }

    // MARK: - ArtikelGeschaeftVerfuegbarkeit / GeschaeftBesuch (Bereich D, seit Version 6)

    /// Reine Existenz-Tatsache, kein Zähler/Mittelwert wie bei
    /// ``mergeWarengruppenDistanzen`` — Union nach (``Artikel``,
    /// ``Geschaeft``)-Paar, kein Tombstone nötig (wird vom Nutzer nie direkt
    /// gelöscht, siehe ``ArtikelGeschaeftVerfuegbarkeit``-Typ-Doku).
    @MainActor
    private static func mergeArtikelGeschaeftVerfuegbarkeiten(
        _ remote: [ArtikelGeschaeftVerfuegbarkeitSnapshot], artikelZuordnung: [UUID: Artikel], geschaeftZuordnung: [UUID: Geschaeft],
        context: ModelContext
    ) {
        let alleLokalen = (try? context.fetch(FetchDescriptor<ArtikelGeschaeftVerfuegbarkeit>())) ?? []
        for eintrag in remote {
            guard let artikel = artikelZuordnung[eintrag.artikelID], let geschaeft = geschaeftZuordnung[eintrag.geschaeftID] else { continue }
            guard !alleLokalen.contains(where: { $0.artikel == artikel && $0.geschaeft == geschaeft }) else { continue }
            context.insert(ArtikelGeschaeftVerfuegbarkeit(artikel: artikel, geschaeft: geschaeft))
        }
    }

    /// Union nach `id` (= `id` des ursprünglichen ``Einkaufsvorgang``s), analog
    /// ``mergePreispunkte`` — ein ``GeschaeftBesuch`` ist ein unveränderliches
    /// historisches Ereignis, kein Tombstone nötig (siehe Typ-Doku). Vorab
    /// geladenes Set statt Existenz-Check pro Remote-Eintrag — siehe
    /// Begründung an ``mergeKaufEintraege``.
    @MainActor
    private static func mergeGeschaeftBesuche(
        _ remote: [GeschaeftBesuchSnapshot], geschaeftZuordnung: [UUID: Geschaeft], context: ModelContext
    ) {
        let bekannteIDs = Set(((try? context.fetch(FetchDescriptor<GeschaeftBesuch>())) ?? []).map(\.id))
        for eintrag in remote {
            guard !bekannteIDs.contains(eintrag.id) else { continue }
            let neuer = GeschaeftBesuch(
                id: eintrag.id, geschaeft: eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] },
                startZeit: eintrag.startZeit, endZeit: eintrag.endZeit, anzahlProdukte: eintrag.anzahlProdukte
            )
            context.insert(neuer)
        }
    }

    /// Reine Existenz-Tatsache (GitHub #99), kein Zähler/Mittelwert wie bei
    /// ``mergeWarengruppenDistanzen`` — Union nach (``Artikel``,
    /// ``Einkaufsliste``)-Paar, kein Tombstone nötig (wird vom Nutzer nie
    /// direkt gelöscht, siehe ``ArtikelListenKauf``-Typ-Doku). Vorab geladenes
    /// Set statt Existenz-Check pro Remote-Eintrag, mit Nachführen innerhalb
    /// der Schleife (Muster wie ``mergeArtikel``) — verhindert Dubletten,
    /// falls derselbe Peer-Batch mehrere Einträge desselben Paares enthält.
    ///
    /// **Bewusst nach ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:context:)``
    /// in der Aufrufreihenfolge belassen** (nicht vorgezogen, obwohl dieser
    /// Merge dessen Sicherheitsnetz-Prüfung eigentlich zuarbeitet): ein in
    /// DEMSELBEN Zyklus frisch eintreffender Beleg für „schon gekauft" wird
    /// dadurch erst im JEWEILS NÄCHSTEN Zyklus für die Sicherheitsnetz-Prüfung
    /// wirksam, nicht sofort im selben Durchlauf — ein bewusst in Kauf
    /// genommener, sich selbst auflösender Randfall (System konvergiert beim
    /// nächsten Zyklus), um die bestehende, mehrfach live-getestete
    /// Abhängigkeitsreihenfolge (`docs/DATENSYNCHRONISATION.md` Abschnitt 4.2)
    /// nicht anzutasten.
    @MainActor
    private static func mergeArtikelListenKaeufe(
        _ remote: [ArtikelListenKaufSnapshot], artikelZuordnung: [UUID: Artikel], listeZuordnung: [UUID: Einkaufsliste],
        context: ModelContext
    ) {
        var bekannt = ArtikelListenKaufService.alleEintraege(context: context)
        for eintrag in remote {
            guard let artikel = artikelZuordnung[eintrag.artikelID], let einkaufsliste = listeZuordnung[eintrag.einkaufslisteID] else { continue }
            ArtikelListenKaufService.vermerkeAbgehaktFallsNoetig(
                artikel: artikel, einkaufsliste: einkaufsliste, am: eintrag.zuletztAbgehaktAm, bekannt: &bekannt, context: context
            )
            // Symmetrisch zur obigen Zeile (Architektur-Review 2026-08-10,
            // siehe ``ArtikelListenKauf/zuletztHinzugefuegtAm``-Typ-Doku) —
            // ohne diese Zeile würde das robuste "hinzugefügt"-Faktum nur
            // indirekt über ``mergeEinkaufslistenEintraege`` propagieren
            // (nur wenn der Artikel beim Peer GERADE aktuell offen ist),
            // nicht direkt über diesen eigenen, dauerhaften Sync-Kanal.
            ArtikelListenKaufService.vermerkeHinzugefuegtFallsNoetig(
                artikel: artikel, einkaufsliste: einkaufsliste, am: eintrag.zuletztHinzugefuegtAm, bekannt: &bekannt, context: context
            )
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
        let zugriffErfolgreich = syncOrdner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(aufrufstelle: "raeumeVerwaisteFremdeExportsAuf", erfolgreich: zugriffErfolgreich)
        guard zugriffErfolgreich else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "raeumeVerwaisteFremdeExportsAuf")
            return false
        }
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "raeumeVerwaisteFremdeExportsAuf")
        }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = await Task.detached(priority: .utility, operation: {
            SyncDateiZugriff.listeKoordiniert(peersOrdner)
        }).value else { return true }

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
                SyncDateiZugriff.loescheKoordiniert(url)
            }
            // `SyncDateiZugriff.loescheKoordiniert` entfernt via
            // `FileManager.removeItem`, das auch einen kompletten
            // (Unter-)Ordner rekursiv löscht — kein separates
            // Verzeichnis-Löschwerkzeug nötig.
            SyncDateiZugriff.loescheKoordiniert(SyncSnapshotExportService.kaeufeOrdner(fuerPeer: peerName, in: syncOrdner))
        }
        return true
    }
}
