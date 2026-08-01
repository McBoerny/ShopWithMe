import Foundation
import SwiftData

/// Bereich C, Kaufhistorie (GitHub #82) — Append-Log für `KaufEintrag`,
/// analog dem bestehenden Bereich-A-Eventlog (``SyncExportService``,
/// `events/`), aber ohne Zähler-Präfix im Dateinamen (siehe Typ-Doku an
/// `SyncSnapshot.swift`, Abschnitt „Paket-Format für den laufenden
/// Peer-Sync-Zyklus"): anders als `SyncEvent` (Konfliktauflösung braucht
/// Lamport-Reihenfolge) ist `KaufEintrag`-Merge bereits heute reine Union
/// nach `id`, ohne Reihenfolgeabhängigkeit. Schreibt EIN `<uuid>.json` pro
/// `KaufEintrag` nach `peers/{peer}/kaeufe/` — nur für Einträge, die dort
/// noch keine Datei haben, statt bei jedem Zyklus die komplette, wachsende
/// Historie neu zu kodieren (Analyse-Fund: `kaufEintraege` machte 56% der
/// Größe einer realen `export.json` aus, war aber nie einzeln fingerabdruck-
/// geprüft — jeder Zyklus kodierte die komplette Historie neu, nur der finale
/// Datei-Schreibvorgang wurde übersprungen).
enum SyncKaeufeExportService {
    /// Schreibt eine Datei für jeden lokalen `KaufEintrag`, der unter
    /// `kaeufe/` noch keine Datei hat. **Existenz-Check per Datei statt eines
    /// persistierten `bereitsExportiert`-Flags auf `KaufEintrag`** — bewusste
    /// Vereinfachung, um für dieses Issue keine SwiftData-Modell-Migration
    /// einzuführen. Bei sehr großen lokalen Historien (deutlich über den in
    /// dieser App typischen wenigen hundert Einträgen) wäre ein Flag
    /// (analog `SyncEvent.hochgeladen`) die schnellere Lösung — siehe
    /// `docs/EXPORT_PAKET_UMBAU.md`, „Mögliche künftige Verfeinerung".
    /// Ohne hinterlegten Sync-Ordner ohne Wirkung. Rückgabewert meldet
    /// ausschließlich, ob der Ordnerzugriff (Berechtigung) geklappt hat.
    @discardableResult
    @MainActor
    static func exportiereNeueKaeufe(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }
        let alleLokalen = (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []
        guard !alleLokalen.isEmpty else { return true }

        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereNeueKaeufe")
            return false
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        guard (try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)) != nil else {
            return true
        }

        // Dieselben "gültige-IDs"-Sets wie `SyncSnapshotExportService.erstelleSnapshot`
        // (baumelnde Referenzen sollen genauso stillschweigend als `nil`
        // exportiert werden, nicht die App zum Absturz bringen).
        let gueltigeArtikelIDs = Set((try? context.fetch(FetchDescriptor<Artikel>()))?.map(\.persistentModelID) ?? [])
        let gueltigeGeschaeftIDs = Set((try? context.fetch(FetchDescriptor<Geschaeft>()))?.map(\.persistentModelID) ?? [])
        let gueltigeEinkaufsvorgangIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsvorgang>()))?.map(\.persistentModelID) ?? [])
        let gueltigeKategorieIDs = Set((try? context.fetch(FetchDescriptor<ArtikelKategorie>()))?.map(\.persistentModelID) ?? [])

        for eintrag in alleLokalen {
            let zielURL = ordner.appendingPathComponent("\(eintrag.id.uuidString).json")
            guard !FileManager.default.fileExists(atPath: zielURL.path) else { continue }
            let snapshot = KaufEintragSnapshot(
                id: eintrag.id,
                artikelID: SyncSnapshotExportService.sichereID(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs),
                einkaufsvorgangID: SyncSnapshotExportService.sichereID(eintrag.einkaufsvorgang, gueltigeIDs: gueltigeEinkaufsvorgangIDs),
                geschaeftID: SyncSnapshotExportService.sichereID(eintrag.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                kategorieID: SyncSnapshotExportService.sichereID(eintrag.kategorie, gueltigeIDs: gueltigeKategorieIDs),
                artikelNameSnapshot: eintrag.artikelNameSnapshot,
                geschaeftNameSnapshot: eintrag.geschaeftNameSnapshot,
                datum: eintrag.datum,
                menge: eintrag.menge,
                kategorieBesuchsIndex: eintrag.kategorieBesuchsIndex
            )
            guard let daten = try? SyncSnapshotExportService.encoder.encode(snapshot) else { continue }
            _ = SyncSnapshotExportService.schreibeBlocking(daten, nach: zielURL)
        }
        return true
    }

    /// Löscht die `kaeufe/`-Dateien mehrerer `KaufEintrag`e im EIGENEN
    /// Peer-Ordner in einem einzigen Zugriff, falls vorhanden — aufgerufen,
    /// sobald die lokalen Einträge selbst gelöscht werden
    /// (``KaufEintragBereinigungService``). Rein Platzersparnis: der bereits
    /// gesetzte ``SyncTombstone`` schützt unabhängig davon vor Wiederbelebung
    /// durch einen Peer, der die Datei noch führt — deshalb best-effort, ohne
    /// Fehler nach außen zu melden. Ohne hinterlegten Sync-Ordner ohne Wirkung.
    ///
    /// **Bewusst EIN `startAccessingSecurityScopedResource()`-Aufruf für die
    /// gesamte Liste, nicht einer pro Datei** (Live-Test-Fund): eine frühere
    /// Fassung öffnete/schloss den Sicherheits-Scope einzeln pro gelöschtem
    /// Eintrag — bei ``SyncSnapshotImportService/loescheFallsVorhanden(art:id:context:)``
    /// zusätzlich VERSCHACHTELT innerhalb des bereits von
    /// ``SyncSnapshotImportService/importiereSnapshots(context:)`` offen
    /// gehaltenen Scopes (dort einmal pro empfangenem Tombstone, bei einem
    /// realen Peer-Bestand schnell drei- bis vierstellig). Wiederholtes/
    /// verschachteltes Öffnen und Schließen desselben Security-Scoped-
    /// Bookmarks destabilisierte den Zugriff auf echten Geräten binnen
    /// Minuten dauerhaft (`startAccessingSecurityScopedResource` lieferte
    /// danach für JEDEN weiteren Sync-Schritt `false`, protokolliert als
    /// `sync_ordner_zugriff_fehlgeschlagen`) — beobachtet als kompletter,
    /// bleibender Sync-Stillstand in beide Richtungen. Deshalb erstens hier
    /// als Batch statt Einzelaufruf, und zweitens NICHT mehr aus
    /// `loescheFallsVorhanden` aufgerufen (das liefe verschachtelt in einer
    /// potenziell sehr langen Tombstone-Schleife) — nur noch aus
    /// ``KaufEintragBereinigungService``, das den eigenen, lokal verursachten
    /// Löschvorgang bereits ohnehin bündelt.
    @MainActor
    static func entferneDateien(fuerKaufEintragIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        guard syncOrdner.startAccessingSecurityScopedResource() else { return }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }
        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        for id in ids {
            try? FileManager.default.removeItem(at: ordner.appendingPathComponent("\(id.uuidString).json"))
        }
    }
}
