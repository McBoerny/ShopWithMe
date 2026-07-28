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
enum SyncSnapshotImportService {
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
            guard let daten = try? Data(contentsOf: exportURL),
                  let snapshot = try? JSONDecoder().decode(SyncSnapshot.self, from: daten)
            else { continue }
            SyncDebugLogger.protokolliereAlter(.snapshotEmpfangen, erzeugtAm: snapshot.erzeugtAm, zusatz: "peer=\(peerOrdner.lastPathComponent.prefix(8))")
            merge(snapshot, peerGeraeteID: peerOrdner.lastPathComponent, context: context)
        }

        try? context.save()
    }

    @MainActor
    private static func merge(_ snapshot: SyncSnapshot, peerGeraeteID: String, context: ModelContext) {
        SyncPeerInfo.aktualisiere(peerGeraeteID: peerGeraeteID, geraeteName: snapshot.geraeteName, context: context)

        let typZuordnung = mergeGeschaeftsTypen(snapshot.geschaeftsTypen, context: context)
        let kategorieZuordnung = mergeArtikelKategorien(snapshot.artikelKategorien, typZuordnung: typZuordnung, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            snapshot.geschaefte, typZuordnung: typZuordnung, kategorieZuordnung: kategorieZuordnung,
            peerGeraeteID: peerGeraeteID, context: context
        )
        let artikelZuordnung = mergeArtikel(snapshot.artikel, kategorieZuordnung: kategorieZuordnung, context: context)
        let listeZuordnung = mergeEinkaufslisten(snapshot.einkaufslisten, context: context)
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
        for eintrag in remote {
            let lokal: ArtikelKategorie
            if let vorhandene = alleLokalen.first(where: { $0.name.localizedCaseInsensitiveCompare(eintrag.name) == .orderedSame }) {
                lokal = vorhandene
            } else {
                let naechsterIndex = (alleLokalen.map(\.sortIndex).max() ?? -1) + 1
                lokal = ArtikelKategorie(
                    name: eintrag.name, standardSymbol: eintrag.standardSymbol,
                    standardFarbeHex: eintrag.standardFarbeHex, sortIndex: naechsterIndex
                )
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
        for eintrag in remote {
            let remoteKoordinaten: (breitengrad: Double, laengengrad: Double)? = {
                guard let b = eintrag.breitengrad, let l = eintrag.laengengrad else { return nil }
                return (b, l)
            }()

            let lokal: Geschaeft
            if let vorhandenes = alleLokalen.first(where: {
                GeschaeftErkennungService.istGleicherOrt(
                    nameA: $0.name, koordinatenA: koordinatenPaar($0),
                    nameB: eintrag.name, koordinatenB: remoteKoordinaten
                )
            }) {
                lokal = vorhandenes
            } else {
                lokal = Geschaeft(name: eintrag.name, typen: [], adresse: nil)
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

    /// Anders als `GeschaeftTyp`/`ArtikelKategorie`/`Geschaeft`/`Artikel` bewusst
    /// **ID-basiert** statt namensbasiert gematcht: Bereich-A-``SyncEvent``s
    /// referenzieren eine ``Einkaufsliste`` über ihre ID, ein Namensmatching
    /// könnte zwei tatsächlich unterschiedliche Listen (z.B. je Gerät
    /// automatisch angelegte Standardliste, siehe ``Einkaufsliste/standard(context:)``)
    /// fälschlich zusammenführen. Zwei gleichnamige Listen nach dem Sync sind
    /// eine bewusst in Kauf genommene, unkritische Konsequenz (Nutzer benennt
    /// bei Bedarf um) — identisch zur ursprünglichen Bootstrap-Merge-Bewertung
    /// in `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` §5.1.
    @MainActor
    private static func mergeEinkaufslisten(_ remote: [EinkaufslisteSnapshot], context: ModelContext) -> [UUID: Einkaufsliste] {
        var zuordnung: [UUID: Einkaufsliste] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []
        for eintrag in remote {
            if let vorhandene = alleLokalen.first(where: { $0.id == eintrag.id }) {
                zuordnung[eintrag.id] = vorhandene
                continue
            }
            let neue = Einkaufsliste(name: eintrag.name)
            neue.id = eintrag.id
            neue.erstelltAm = eintrag.erstelltAm
            context.insert(neue)
            zuordnung[eintrag.id] = neue
        }
        return zuordnung
    }

    // MARK: - Einkaufsvorgang (Bereich C)

    /// ID-basiert wie ``mergeEinkaufslisten(_:context:)`` und aus demselben
    /// Grund: Bereich-A-Events referenzieren einen ``Einkaufsvorgang`` über
    /// seine ID, außerdem ist ein gemeinsamer Einkaufsvorgang (beide Geräte
    /// kaufen gemeinsam im selben Laden ein) genau der Fall, in dem beide
    /// Geräte über dieselbe Identität sprechen sollen. Ein bereits lokal
    /// abgeschlossener Einkauf wird nie durch einen (älteren) Remote-Stand
    /// wieder geöffnet — nur eine noch fehlende ``Einkaufsvorgang/endZeit``
    /// wird nachgetragen.
    @MainActor
    private static func mergeEinkaufsvorgaenge(
        _ remote: [EinkaufsvorgangSnapshot], geschaeftZuordnung: [UUID: Geschaeft], listeZuordnung: [UUID: Einkaufsliste],
        context: ModelContext
    ) -> [UUID: Einkaufsvorgang] {
        var zuordnung: [UUID: Einkaufsvorgang] = [:]
        let alleLokalen = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        for eintrag in remote {
            if let vorhandener = alleLokalen.first(where: { $0.id == eintrag.id }) {
                if vorhandener.endZeit == nil, let remoteEndZeit = eintrag.endZeit {
                    vorhandener.endZeit = remoteEndZeit
                }
                zuordnung[eintrag.id] = vorhandener
                continue
            }
            // Bewusst kein `abschliessen()` (würde zusätzlich
            // `Geschaeft.anzahlEinkaufsvorgaenge` erhöhen — das übernimmt
            // bereits die additive Zähler-Merge-Regel in ``mergeGeschaefte``,
            // ein zweites Mal hier wäre Doppelzählung).
            let neuer = Einkaufsvorgang(
                geschaeft: eintrag.geschaeftID.flatMap { geschaeftZuordnung[$0] },
                einkaufsliste: eintrag.einkaufslisteID.flatMap { listeZuordnung[$0] },
                startZeit: eintrag.startZeit
            )
            neuer.id = eintrag.id
            neuer.endZeit = eintrag.endZeit
            context.insert(neuer)
            zuordnung[eintrag.id] = neuer
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
