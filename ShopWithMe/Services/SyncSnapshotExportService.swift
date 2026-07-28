import Foundation
import SwiftData

/// Bereich-B/C/D-Export (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`
/// Abschnitt 5.2, Phase 1b): leitet einen vollständigen ``SyncSnapshot`` aus dem
/// aktuellen lokalen Modellzustand ab und schreibt ihn als `export.json` in den
/// eigenen Peer-Ordner. Anders als ``SyncExportService`` (Bereich A) kein
/// inkrementelles Mitschreiben, sondern bei jedem Aufruf ein vollständiger
/// Neuaufbau — welcher Zeitpunkt dafür sinnvoll ist (Konsolidierung/adaptives
/// Polling), entscheidet erst Phase 4; hier wird bei jedem Aufruf unbedingt
/// geschrieben. Reines Schreiben — Lesen fremder Snapshots ist Phase 3.
/// Modelle mit einer stabilen `UUID`-`id` — Voraussetzung für die
/// `sichereID`/`sichereIDs`-Absicherung in ``SyncSnapshotExportService``
/// gegen bereits "baumelnde" Referenzen auf gelöschte Objekte.
private protocol SyncSnapshotIdentifizierbar: PersistentModel {
    var id: UUID { get }
}
extension Geschaeft: SyncSnapshotIdentifizierbar {}
extension GeschaeftTyp: SyncSnapshotIdentifizierbar {}
extension ArtikelKategorie: SyncSnapshotIdentifizierbar {}
extension Artikel: SyncSnapshotIdentifizierbar {}
extension Einkaufsliste: SyncSnapshotIdentifizierbar {}
extension Einkaufsvorgang: SyncSnapshotIdentifizierbar {}

enum SyncSnapshotExportService {
    private static let dateiName = "export.json"

    /// Die `export.json`-URL eines beliebigen Geräts (eigenes oder fremdes)
    /// innerhalb des Sync-Ordners — siehe ``SyncSnapshotImportService`` für das
    /// Lesen fremder Snapshots.
    static func exportURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(geraeteID, isDirectory: true)
            .appendingPathComponent(dateiName)
    }

    /// Die `export.json`-URL dieses Geräts innerhalb des Sync-Ordners.
    static func eigeneExportURL(in syncOrdner: URL) -> URL {
        exportURL(fuerPeer: DatabaseLeaseService.geraeteID, in: syncOrdner)
    }

    /// Baut den ``SyncSnapshot`` aus dem aktuellen Modellzustand und schreibt ihn
    /// nach `peers/{geraeteID}/export.json`. Ohne hinterlegten Sync-Ordner
    /// (``SyncOrdnerService/gewaehlterOrdner()`` liefert `nil`) ohne Wirkung.
    @MainActor
    static func exportiereSnapshot(context: ModelContext) async {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }

        let snapshot = erstelleSnapshot(context: context)
        guard let daten = try? JSONEncoder().encode(snapshot) else { return }

        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereSnapshot")
            return
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let zielURL = eigeneExportURL(in: syncOrdner)
        guard (try? FileManager.default.createDirectory(
            at: zielURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )) != nil else { return }

        _ = schreibeBlocking(daten, nach: zielURL)
    }

    @MainActor
    static func erstelleSnapshot(context: ModelContext) -> SyncSnapshot {
        let alleGeschaeftsTypen = (try? context.fetch(FetchDescriptor<GeschaeftTyp>())) ?? []
        let gueltigeGeschaeftsTypIDs = Set(alleGeschaeftsTypen.map(\.persistentModelID))
        let geschaeftsTypen = alleGeschaeftsTypen.map {
            GeschaeftTypSnapshot(id: $0.id, name: $0.name, symbolName: $0.symbolName, farbeHex: $0.farbeHex, sortIndex: $0.sortIndex)
        }

        let alleArtikelKategorien = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        let gueltigeKategorieIDs = Set(alleArtikelKategorien.map(\.persistentModelID))
        let artikelKategorien = alleArtikelKategorien.map {
            ArtikelKategorieSnapshot(
                id: $0.id,
                name: $0.name,
                standardSymbol: $0.standardSymbol,
                standardFarbeHex: $0.standardFarbeHex,
                sortIndex: $0.sortIndex,
                geschaeftsTypIDs: sichereIDs($0.geschaeftsTypen, gueltigeIDs: gueltigeGeschaeftsTypIDs)
            )
        }

        let alleGeschaefte = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []
        let gueltigeGeschaeftIDs = Set(alleGeschaefte.map(\.persistentModelID))
        let geschaefte = alleGeschaefte.map { geschaeft in
            GeschaeftSnapshot(
                id: geschaeft.id,
                name: geschaeft.name,
                typIDs: sichereIDs(geschaeft.typen, gueltigeIDs: gueltigeGeschaeftsTypIDs),
                adresse: geschaeft.adresse,
                breitengrad: geschaeft.breitengrad,
                laengengrad: geschaeft.laengengrad,
                erkennungsradius: geschaeft.erkennungsradiusRaw,
                kategorieIDs: sichereIDs(geschaeft.kategorien, gueltigeIDs: gueltigeKategorieIDs),
                ausgeschlosseneKategorieIDs: sichereIDs(geschaeft.ausgeschlosseneKategorien, gueltigeIDs: gueltigeKategorieIDs),
                alternativeNamen: geschaeft.alternativeNamen,
                ignorierteArtikelNamen: geschaeft.ignorierteArtikel.map(\.erkannterName),
                anzahlEinkaufsvorgaenge: geschaeft.anzahlEinkaufsvorgaenge,
                umbauVerdacht: geschaeft.umbauVerdacht,
                unauffaelligeEinkaeufeInFolge: geschaeft.unauffaelligeEinkaeufeInFolge
            )
        }

        let alleArtikel = (try? context.fetch(FetchDescriptor<Artikel>())) ?? []
        let gueltigeArtikelIDs = Set(alleArtikel.map(\.persistentModelID))
        let artikel = alleArtikel.map { artikel -> ArtikelSnapshot in
            let kategorieIDs = artikel.kategorien.isEmpty
                ? sichereIDs(artikel.kategorie.map { [$0] } ?? [], gueltigeIDs: gueltigeKategorieIDs)
                : sichereIDs(artikel.kategorien, gueltigeIDs: gueltigeKategorieIDs)
            return ArtikelSnapshot(
                id: artikel.id,
                name: artikel.name,
                symbolName: artikel.symbolName,
                farbeHex: artikel.farbeHex,
                kategorieIDs: kategorieIDs,
                notiz: artikel.notiz,
                einheit: artikel.einheit.rawValue,
                mengenSchritt: artikel.mengenSchritt,
                erstelltAm: artikel.erstelltAm
            )
        }

        let einkaufslisten = ((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map {
            EinkaufslisteSnapshot(id: $0.id, name: $0.name, erstelltAm: $0.erstelltAm)
        }
        let gueltigeEinkaufslistenIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsliste>()))?.map(\.persistentModelID) ?? [])

        let einkaufsvorgaenge = ((try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []).map {
            EinkaufsvorgangSnapshot(
                id: $0.id,
                geschaeftID: sichereID($0.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                einkaufslisteID: sichereID($0.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs),
                startZeit: $0.startZeit,
                endZeit: $0.endZeit
            )
        }
        let gueltigeEinkaufsvorgangIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsvorgang>()))?.map(\.persistentModelID) ?? [])

        let kaufEintraege = ((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []).map {
            KaufEintragSnapshot(
                id: $0.id,
                artikelID: sichereID($0.artikel, gueltigeIDs: gueltigeArtikelIDs),
                einkaufsvorgangID: sichereID($0.einkaufsvorgang, gueltigeIDs: gueltigeEinkaufsvorgangIDs),
                geschaeftID: sichereID($0.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                kategorieID: sichereID($0.kategorie, gueltigeIDs: gueltigeKategorieIDs),
                artikelNameSnapshot: $0.artikelNameSnapshot,
                geschaeftNameSnapshot: $0.geschaeftNameSnapshot,
                produktName: $0.produktName,
                alternativerName: $0.alternativerName,
                datum: $0.datum,
                preis: $0.preis,
                menge: $0.menge,
                kategorieBesuchsIndex: $0.kategorieBesuchsIndex
            )
        }

        let warengruppenDistanzen = ((try? context.fetch(FetchDescriptor<WarengruppenDistanz>())) ?? [])
            .compactMap { distanz -> WarengruppenDistanzSnapshot? in
                guard let kategorieAID = sichereID(distanz.kategorieA, gueltigeIDs: gueltigeKategorieIDs),
                      let kategorieBID = sichereID(distanz.kategorieB, gueltigeIDs: gueltigeKategorieIDs)
                else { return nil }
                return WarengruppenDistanzSnapshot(
                    id: distanz.id,
                    geschaeftID: sichereID(distanz.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                    kategorieAID: kategorieAID,
                    kategorieBID: kategorieBID,
                    distanz: distanz.distanz
                )
            }

        return SyncSnapshot(
            formatVersion: SyncSnapshot.aktuelleFormatVersion,
            erzeugtAm: Date(),
            geraeteID: DatabaseLeaseService.geraeteID,
            geraeteName: DatabaseLeaseService.geraeteName,
            geschaeftsTypen: geschaeftsTypen,
            artikelKategorien: artikelKategorien,
            geschaefte: geschaefte,
            artikel: artikel,
            einkaufslisten: einkaufslisten,
            einkaufsvorgaenge: einkaufsvorgaenge,
            kaufEintraege: kaufEintraege,
            warengruppenDistanzen: warengruppenDistanzen
        )
    }

    /// Liefert die `id` von `objekt`, aber nur, falls es tatsächlich in
    /// `gueltigeIDs` enthalten ist. Schützt vor bereits (durch fehlende
    /// `inverse`-Deklarationen, siehe ``Geschaeft/einkaufsvorgaenge``)
    /// "baumelnden" Referenzen auf gelöschte Objekte: `persistentModelID` ist
    /// reines Identitäts-Metadatum und daher auch auf einer baumelnden
    /// Referenz sicher lesbar, während der Zugriff auf `id` (oder jede andere
    /// Eigenschaft) in diesem Fall mit einem SwiftData-Fatal-Error abstürzt.
    private static func sichereID<T: SyncSnapshotIdentifizierbar>(_ objekt: T?, gueltigeIDs: Set<PersistentIdentifier>) -> UUID? {
        guard let objekt else { return nil }
        guard gueltigeIDs.contains(objekt.persistentModelID) else {
            SyncDebugLogger.log(.baumelndeReferenzGefunden, details: "typ=\(T.self) referenz=\(objekt.persistentModelID)")
            return nil
        }
        return objekt.id
    }

    /// Wie ``sichereID(_:gueltigeIDs:)``, für Arrays — verwaiste Einträge
    /// werden stillschweigend herausgefiltert statt die App abstürzen zu lassen.
    private static func sichereIDs<T: SyncSnapshotIdentifizierbar>(_ objekte: [T], gueltigeIDs: Set<PersistentIdentifier>) -> [UUID] {
        objekte.compactMap { sichereID($0, gueltigeIDs: gueltigeIDs) }
    }

    /// Schreibt über `NSFileCoordinator`, damit File-Provider-Erweiterungen von
    /// der Änderung erfahren — analog zum bestehenden Muster in
    /// ``DatabaseLeaseService``/``SyncExportService``.
    nonisolated private static func schreibeBlocking(_ daten: Data, nach url: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinatorFehler: NSError?
        var erfolgreich = false
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorFehler) { zielURL in
            do {
                try daten.write(to: zielURL, options: .atomic)
                erfolgreich = true
            } catch {
                erfolgreich = false
            }
        }
        return coordinatorFehler == nil && erfolgreich
    }
}
