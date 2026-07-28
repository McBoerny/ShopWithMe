import Foundation
import SwiftData

/// Bereich-B-Import (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` Abschnitt
/// 5.3, Phase 3a): liest `export.json`-Snapshots aus allen fremden
/// Peer-Ordnern und merged Stammdaten (``GeschaeftTyp``, ``ArtikelKategorie``,
/// ``Geschaeft``, ``Artikel``, ``Einkaufsliste``) dependency-geordnet in den
/// lokalen Bestand — Matching-Bausteine wiederverwendet aus
/// `docs/DATENBANK_BACKUP_RESTORE_BEWERTUNG.md` §5.1.
///
/// **Grundprinzip aller Merge-Regeln hier: nie destruktiv.** Ein bereits
/// lokal gesetzter Wert wird nie durch einen abweichenden Remote-Wert
/// überschrieben (es gibt keine feldweise Zeitstempel-/Lamport-Ordnung für
/// Bereich B, die entscheiden könnte, welcher Wert "neuer" ist) — stattdessen
/// werden nur fehlende Werte ergänzt (`nil` → Remote-Wert) und Mengen
/// (Kategorien, Typen, ignorierte Artikel, alternative Namen) vereinigt statt
/// ersetzt. Die additiven Zähler auf ``Geschaeft`` (Abschnitt 4.2a) haben eine
/// eigene, dedizierte Regel, siehe ``SyncPeerZaehlerStand``.
///
/// **Historie/Lernen (Bereich C/D: `Einkaufsvorgang`, `KaufEintrag`,
/// `WarengruppenDistanz`) sind Phase 3b, hier noch nicht enthalten.**
enum SyncSnapshotImportService {
    @MainActor
    static func importiereSnapshots(context: ModelContext) async {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        guard syncOrdner.startAccessingSecurityScopedResource() else { return }
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
            merge(snapshot, peerGeraeteID: peerOrdner.lastPathComponent, context: context)
        }

        try? context.save()
    }

    @MainActor
    @discardableResult
    private static func merge(_ snapshot: SyncSnapshot, peerGeraeteID: String, context: ModelContext) -> (
        typen: [UUID: GeschaeftTyp], kategorien: [UUID: ArtikelKategorie], geschaefte: [UUID: Geschaeft],
        artikel: [UUID: Artikel], einkaufslisten: [UUID: Einkaufsliste]
    ) {
        let typZuordnung = mergeGeschaeftsTypen(snapshot.geschaeftsTypen, context: context)
        let kategorieZuordnung = mergeArtikelKategorien(snapshot.artikelKategorien, typZuordnung: typZuordnung, context: context)
        let geschaeftZuordnung = mergeGeschaefte(
            snapshot.geschaefte, typZuordnung: typZuordnung, kategorieZuordnung: kategorieZuordnung,
            peerGeraeteID: peerGeraeteID, context: context
        )
        let artikelZuordnung = mergeArtikel(snapshot.artikel, kategorieZuordnung: kategorieZuordnung, context: context)
        let listeZuordnung = mergeEinkaufslisten(snapshot.einkaufslisten, context: context)
        return (typZuordnung, kategorieZuordnung, geschaeftZuordnung, artikelZuordnung, listeZuordnung)
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
}
