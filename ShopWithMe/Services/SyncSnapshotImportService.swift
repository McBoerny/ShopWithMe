import Foundation
import SwiftData

/// Bereich-B/C/D-Import (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`
/// Abschnitt 5.3, Phase 3): liest `export.json`-Snapshots aus allen fremden
/// Peer-Ordnern und merged Stammdaten (``GeschaeftTyp``, ``ArtikelKategorie``,
/// ``Geschaeft``, ``Artikel``, ``Einkaufsliste``, Bereich B), Historie
/// (``Einkaufsvorgang``, ``KaufEintrag``, Bereich C) und Lernen
/// (``WarengruppenDistanz``, Bereich D) dependency-geordnet in den lokalen
/// Bestand — Matching-Bausteine für Bereich B wiederverwendet aus
/// `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` §5.1.
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

    @MainActor
    static func importiereSnapshots(context: ModelContext) async {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereSnapshots")
            return
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = try? FileManager.default.contentsOfDirectory(
            at: peersOrdner, includingPropertiesForKeys: nil
        ) else { return }

        for peerOrdner in peerVerzeichnisse where peerOrdner.lastPathComponent != eigeneGeraeteID {
            let exportURL = SyncSnapshotExportService.exportURL(fuerPeer: peerOrdner.lastPathComponent, in: syncOrdner)
            guard let snapshot = await ladeSnapshot(von: exportURL) else { continue }
            guard Date().timeIntervalSince(snapshot.erzeugtAm) <= maximalesSnapshotAlter else {
                SyncDebugLogger.log(.peerVerworfenAltersgrenze, details: "peer=\(peerOrdner.lastPathComponent.prefix(8))")
                continue
            }
            SyncDebugLogger.protokolliereAlter(.snapshotEmpfangen, erzeugtAm: snapshot.erzeugtAm, zusatz: "peer=\(peerOrdner.lastPathComponent.prefix(8))")
            merge(snapshot, peerGeraeteID: peerOrdner.lastPathComponent, context: context)
        }

        protokolliereEinkaufslistenStand(context: context)
        try? context.save()
    }

    /// Wendet einen einzelnen, bereits vorliegenden Snapshot an (z.B. aus einem
    /// lokalen Backup, ``SyncErsetzenService``) — dieselbe Merge-Pipeline wie
    /// ``importiereSnapshots(context:)``, nur ohne den Peer-Ordner-Scan. Da der
    /// Kontext nach einem vorangegangenen
    /// ``ModelContainerController/ersetzeDurchLeerenContainer()`` leer ist, IST
    /// dieser einzelne Merge-Durchlauf bereits der vollständige Neuaufbau —
    /// jede `mergeX`-Funktion legt bei fehlendem lokalem Treffer frisch an.
    @MainActor
    static func importiereEinzelnenSnapshot(_ snapshot: SyncSnapshot, peerGeraeteID: String, context: ModelContext) {
        merge(snapshot, peerGeraeteID: peerGeraeteID, context: context)
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

    /// Lädt und dekodiert einen fremden Snapshot über einen koordinierten
    /// Lesezugriff (``SyncDateiZugriff``, GitHub #52) — in einem `Task.detached`,
    /// damit ein bei Bedarf ausgelöster Download nicht den `MainActor` blockiert.
    nonisolated private static func ladeSnapshot(von url: URL) async -> SyncSnapshot? {
        await Task.detached(priority: .utility) {
            guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
            return try? JSONDecoder().decode(SyncSnapshot.self, from: daten)
        }.value
    }

    @MainActor
    private static func merge(_ snapshot: SyncSnapshot, peerGeraeteID: String, context: ModelContext) {
        SyncPeerInfo.aktualisiere(
            peerGeraeteID: peerGeraeteID, geraeteName: snapshot.geraeteName, zuletztGesehen: snapshot.erzeugtAm, context: context
        )

        // Läuft bewusst zuerst — siehe Typ-Doku „Architektur-Revision
        // Alternative A": ein frisch gelerntes Tombstone soll die
        // nachfolgenden „create new"-Zweige direkt greifen.
        mergeTombstones(snapshot.tombstones, context: context)

        let typZuordnung = mergeGeschaeftsTypen(snapshot.geschaeftsTypen, context: context)
        let kategorieZuordnung = mergeArtikelKategorien(snapshot.artikelKategorien, typZuordnung: typZuordnung, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            snapshot.geschaefte, typZuordnung: typZuordnung, kategorieZuordnung: kategorieZuordnung,
            peerGeraeteID: peerGeraeteID, context: context
        )
        let artikelZuordnung = mergeArtikel(snapshot.artikel, kategorieZuordnung: kategorieZuordnung, context: context)
        let listeZuordnung = mergeEinkaufslisten(snapshot.einkaufslisten, context: context)
        mergeEinkaufslistenEintraege(
            snapshot.einkaufslistenEintraege, listeZuordnung: listeZuordnung, artikelZuordnung: artikelZuordnung, context: context
        )
        let einkaufsvorgangZuordnung = mergeEinkaufsvorgaenge(
            snapshot.einkaufsvorgaenge, geschaeftZuordnung: geschaeftZuordnung, listeZuordnung: listeZuordnung, context: context
        )
        mergeKaufEintraege(
            snapshot.kaufEintraege, artikelZuordnung: artikelZuordnung, einkaufsvorgangZuordnung: einkaufsvorgangZuordnung,
            geschaeftZuordnung: geschaeftZuordnung, kategorieZuordnung: kategorieZuordnung, context: context
        )
        mergeWarengruppenDistanzen(
            snapshot.warengruppenDistanzen, geschaeftZuordnung: geschaeftZuordnung, kategorieZuordnung: kategorieZuordnung, context: context
        )
    }

    // MARK: - Tombstones (Löschungen)

    /// Übernimmt fremde Tombstones und löscht ein dadurch als entfernt
    /// markiertes, lokal noch vorhandenes Objekt — siehe ``SyncTombstone``.
    @MainActor
    private static func mergeTombstones(_ remote: [SyncTombstoneSnapshot], context: ModelContext) {
        for tombstone in remote {
            let lokaleID = SyncEntitaetsAliasService.aufgeloesteID(
                fuer: tombstone.geloeschteID, art: tombstone.entitaetsArt, context: context
            )
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
        _ remote: [ArtikelKategorieSnapshot], typZuordnung: [UUID: GeschaeftTyp], context: ModelContext
    ) -> [UUID: ArtikelKategorie] {
        var zuordnung: [UUID: ArtikelKategorie] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.artikelKategorie, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(
                fuer: eintrag.id, art: SyncEntitaetsArt.artikelKategorie, context: context
            )
            let lokal: ArtikelKategorie
            if let bekannte = alleLokalen.first(where: { $0.id == aufgeloesteID }) {
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
            lokal.geschaeftsTypen = vereinigtGeordnet(lokal.geschaeftsTypen, eintrag.geschaeftsTypIDs.compactMap { typZuordnung[$0] })
            zuordnung[eintrag.id] = lokal
        }
        return zuordnung
    }

    // MARK: - Geschaeft

    @MainActor
    private static func mergeGeschaefte(
        _ remote: [GeschaeftSnapshot], typZuordnung: [UUID: GeschaeftTyp], kategorieZuordnung: [UUID: ArtikelKategorie],
        peerGeraeteID: String, context: ModelContext
    ) -> [UUID: Geschaeft] {
        var zuordnung: [UUID: Geschaeft] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.geschaeft, context: context)
        for eintrag in remote {
            let remoteKoordinaten: (breitengrad: Double, laengengrad: Double)? = {
                guard let b = eintrag.breitengrad, let l = eintrag.laengengrad else { return nil }
                return (b, l)
            }()
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(
                fuer: eintrag.id, art: SyncEntitaetsArt.geschaeft, context: context
            )

            let lokal: Geschaeft
            if let bekanntes = alleLokalen.first(where: { $0.id == aufgeloesteID }) {
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

            lokal.typen = vereinigtGeordnet(lokal.typen, eintrag.typIDs.compactMap { typZuordnung[$0] })
            lokal.kategorien = vereinigtGeordnet(lokal.kategorien, eintrag.kategorieIDs.compactMap { kategorieZuordnung[$0] })
            lokal.ausgeschlosseneKategorien = vereinigtGeordnet(
                lokal.ausgeschlosseneKategorien, eintrag.ausgeschlosseneKategorieIDs.compactMap { kategorieZuordnung[$0] }
            )
            for name in eintrag.alternativeNamen {
                lokal.alternativenNamenLernen(name)
            }
            let bereitsIgnoriert = Set(lokal.ignorierteArtikel.map { $0.erkannterName.lowercased() })
            for name in eintrag.ignorierteArtikelNamen where !bereitsIgnoriert.contains(name.lowercased()) {
                context.insert(IgnorierterArtikel(erkannterName: name, geschaeft: lokal))
            }

            // Additive Merge-Regel für Zähler (Abschnitt 4.2a) statt Überschreiben.
            let zuwachs = SyncPeerZaehlerStand.zuwachs(
                peerGeraeteID: peerGeraeteID, geschaeftID: eintrag.id,
                remoteWert: eintrag.anzahlEinkaufsvorgaenge, context: context
            )
            lokal.anzahlEinkaufsvorgaenge += zuwachs
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
        _ remote: [ArtikelSnapshot], kategorieZuordnung: [UUID: ArtikelKategorie], context: ModelContext
    ) -> [UUID: Artikel] {
        var zuordnung: [UUID: Artikel] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Artikel>())) ?? []
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.artikel, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(
                fuer: eintrag.id, art: SyncEntitaetsArt.artikel, context: context
            )
            if let bekannter = alleLokalen.first(where: { $0.id == aufgeloesteID }) {
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
        lokal.kategorien = vereinigtGeordnet(lokal.kategorien, eintrag.kategorieIDs.compactMap { kategorieZuordnung[$0] })
        if lokal.notiz == nil { lokal.notiz = eintrag.notiz }
    }

    // MARK: - Einkaufsliste

    /// Namensbasiert gematcht wie ``mergeGeschaefte``/``mergeArtikel`` (Alias
    /// via ``SyncEntitaetsAliasService`` für spätere Bereich-A-``SyncEvent``s,
    /// die weiterhin die fremde ID referenzieren) — **revidiert** gegenüber der
    /// ursprünglichen ID-basierten Entscheidung (siehe `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md`
    /// §5.1): Jedes Gerät legt beim allerersten Start automatisch eine eigene
    /// Standardliste namens „Einkaufsliste" an (``Einkaufsliste/standard(context:)``),
    /// bereits bevor je synchronisiert wurde. Bei ID-basiertem Matching entstand
    /// dadurch beim ersten Beitritt zu einem bestehenden Sync-Ordner IMMER eine
    /// zweite, für den Nutzer unsichtbare Dublette „Einkaufsliste" — die
    /// tatsächlich synchronisierten Artikel landeten darauf, während die UI
    /// weiterhin die eigene (fast leere) Liste zeigte (GitHub #52-Nachfolgefund).
    /// Das war kein Rand-, sondern der Standardfall bei jedem Gerätebeitritt.
    @MainActor
    private static func mergeEinkaufslisten(_ remote: [EinkaufslisteSnapshot], context: ModelContext) -> [UUID: Einkaufsliste] {
        var zuordnung: [UUID: Einkaufsliste] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []
        let geloeschteIDs = SyncTombstoneService.geloeschteIDs(art: SyncEntitaetsArt.einkaufsliste, context: context)
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(
                fuer: eintrag.id, art: SyncEntitaetsArt.einkaufsliste, context: context
            )
            if let bekannte = alleLokalen.first(where: { $0.id == aufgeloesteID }) {
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
        for eintrag in remote {
            guard let liste = listeZuordnung[eintrag.einkaufslisteID],
                  let artikel = artikelZuordnung[eintrag.artikelID],
                  !liste.enthaelt(artikel),
                  !istBereitsAbgehakt(artikel, aufListe: liste, context: context)
            else { continue }
            context.insert(EinkaufslistenEintrag(einkaufsliste: liste, artikel: artikel, menge: eintrag.menge, notiz: eintrag.notiz))
        }
    }

    /// Ob `artikel` in einem lokal noch offenen ``Einkaufsvorgang`` von
    /// `liste` bereits abgehakt ist (siehe Warnung in
    /// ``mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:context:)``).
    @MainActor
    private static func istBereitsAbgehakt(_ artikel: Artikel, aufListe liste: Einkaufsliste, context: ModelContext) -> Bool {
        let deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.endZeit == nil })
        let offeneVorgaenge = (try? context.fetch(deskriptor)) ?? []
        return offeneVorgaenge.contains {
            $0.einkaufsliste == liste && $0.kaufEintraege.contains { $0.artikel == artikel }
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
    @MainActor
    private static func mergeEinkaufsvorgaenge(
        _ remote: [EinkaufsvorgangSnapshot], geschaeftZuordnung: [UUID: Geschaeft], listeZuordnung: [UUID: Einkaufsliste],
        context: ModelContext
    ) -> [UUID: Einkaufsvorgang] {
        var zuordnung: [UUID: Einkaufsvorgang] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        for eintrag in remote {
            let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(
                fuer: eintrag.id, art: SyncEntitaetsArt.einkaufsvorgang, context: context
            )
            let remoteGeschaeft = eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] }
            let remoteListe = eintrag.einkaufslisteID.flatMap { listeZuordnung[$0] }

            let vorhandener: Einkaufsvorgang
            if let bekannter = alleLokalen.first(where: { $0.id == aufgeloesteID }) {
                vorhandener = bekannter
            } else if let offenerTreffer = alleLokalen.first(where: {
                $0.endZeit == nil && $0.geschaeft == remoteGeschaeft && $0.einkaufsliste == remoteListe
            }) {
                if offenerTreffer.id != eintrag.id {
                    SyncEntitaetsAliasService.registriere(
                        entitaetsArt: SyncEntitaetsArt.einkaufsvorgang, fremdeID: eintrag.id, lokaleID: offenerTreffer.id, context: context
                    )
                }
                vorhandener = offenerTreffer
            } else {
                // Bewusst kein `abschliessen()` (würde zusätzlich
                // `Geschaeft.anzahlEinkaufsvorgaenge` erhöhen — das übernimmt
                // bereits die additive Zähler-Merge-Regel in
                // ``mergeGeschaefte``, ein zweites Mal hier wäre Doppelzählung).
                let neuer = Einkaufsvorgang(geschaeft: remoteGeschaeft, einkaufsliste: remoteListe, startZeit: eintrag.startZeit)
                neuer.id = eintrag.id
                context.insert(neuer)
                vorhandener = neuer
            }

            if vorhandener.endZeit == nil, let remoteEndZeit = eintrag.endZeit {
                vorhandener.endZeit = remoteEndZeit
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
    @MainActor
    private static func mergeKaufEintraege(
        _ remote: [KaufEintragSnapshot], artikelZuordnung: [UUID: Artikel], einkaufsvorgangZuordnung: [UUID: Einkaufsvorgang],
        geschaeftZuordnung: [UUID: Geschaeft], kategorieZuordnung: [UUID: ArtikelKategorie], context: ModelContext
    ) {
        let alleLokalen = (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []
        for eintrag in remote {
            guard alleLokalen.first(where: { $0.id == eintrag.id }) == nil else { continue }
            let neuer = KaufEintrag(
                artikel: eintrag.artikelID.flatMap { artikelZuordnung[$0] },
                geschaeft: eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] },
                kategorie: eintrag.kategorieID.flatMap { kategorieZuordnung[$0] },
                preis: eintrag.preis,
                menge: eintrag.menge,
                datum: eintrag.datum,
                kategorieBesuchsIndex: eintrag.kategorieBesuchsIndex
            )
            neuer.id = eintrag.id
            neuer.einkaufsvorgang = eintrag.einkaufsvorgangID.flatMap { einkaufsvorgangZuordnung[$0] }
            // Original-Schnappschuss-Namen erhalten statt aus den (ggf. seither
            // umbenannten) gemergten Objekten neu abzuleiten.
            neuer.artikelNameSnapshot = eintrag.artikelNameSnapshot
            neuer.geschaeftNameSnapshot = eintrag.geschaeftNameSnapshot
            neuer.produktName = eintrag.produktName
            neuer.alternativerName = eintrag.alternativerName
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
}
