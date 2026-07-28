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
        let geschaeftsTypen = ((try? context.fetch(FetchDescriptor<GeschaeftTyp>())) ?? []).map {
            GeschaeftTypSnapshot(id: $0.id, name: $0.name, symbolName: $0.symbolName, farbeHex: $0.farbeHex, sortIndex: $0.sortIndex)
        }

        let artikelKategorien = ((try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []).map {
            ArtikelKategorieSnapshot(
                id: $0.id,
                name: $0.name,
                standardSymbol: $0.standardSymbol,
                standardFarbeHex: $0.standardFarbeHex,
                sortIndex: $0.sortIndex,
                geschaeftsTypIDs: $0.geschaeftsTypen.map(\.id)
            )
        }

        let geschaefte = ((try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []).map { geschaeft in
            GeschaeftSnapshot(
                id: geschaeft.id,
                name: geschaeft.name,
                typIDs: geschaeft.typen.map(\.id),
                adresse: geschaeft.adresse,
                breitengrad: geschaeft.breitengrad,
                laengengrad: geschaeft.laengengrad,
                erkennungsradius: geschaeft.erkennungsradiusRaw,
                kategorieIDs: geschaeft.kategorien.map(\.id),
                ausgeschlosseneKategorieIDs: geschaeft.ausgeschlosseneKategorien.map(\.id),
                alternativeNamen: geschaeft.alternativeNamen,
                ignorierteArtikelNamen: geschaeft.ignorierteArtikel.map(\.erkannterName),
                anzahlEinkaufsvorgaenge: geschaeft.anzahlEinkaufsvorgaenge,
                umbauVerdacht: geschaeft.umbauVerdacht,
                unauffaelligeEinkaeufeInFolge: geschaeft.unauffaelligeEinkaeufeInFolge
            )
        }

        let artikel = ((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map { artikel in
            let kategorieIDs = artikel.kategorien.isEmpty
                ? (artikel.kategorie.map { [$0.id] } ?? [])
                : artikel.kategorien.map(\.id)
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

        let einkaufsvorgaenge = ((try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []).map {
            EinkaufsvorgangSnapshot(
                id: $0.id,
                geschaeftID: $0.geschaeft?.id,
                einkaufslisteID: $0.einkaufsliste?.id,
                startZeit: $0.startZeit,
                endZeit: $0.endZeit
            )
        }

        let kaufEintraege = ((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []).map {
            KaufEintragSnapshot(
                id: $0.id,
                artikelID: $0.artikel?.id,
                einkaufsvorgangID: $0.einkaufsvorgang?.id,
                geschaeftID: $0.geschaeft?.id,
                kategorieID: $0.kategorie?.id,
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
                guard let kategorieA = distanz.kategorieA, let kategorieB = distanz.kategorieB else { return nil }
                return WarengruppenDistanzSnapshot(
                    id: distanz.id,
                    geschaeftID: distanz.geschaeft?.id,
                    kategorieAID: kategorieA.id,
                    kategorieBID: kategorieB.id,
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
