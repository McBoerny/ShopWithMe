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
    /// `kaeufe/` noch keine Datei hat.
    ///
    /// **Existenz-Check per EINER Ordner-Auflistung statt N Einzel-`fileExists`-
    /// Aufrufen** (Performance-Fund): eine frühere Fassung prüfte pro lokalem
    /// Eintrag einzeln `FileManager.fileExists` — bei größerer Historie
    /// bedeutete das N Datei-Stat-Aufrufe gegen einen ggf. Cloud-gestützten
    /// Ordner (iCloud Drive/Synology Drive) bei JEDEM Sync-Zyklus (alle 5s
    /// beim aktiven Einkaufen), selbst wenn nichts Neues hinzugekommen war.
    /// Jetzt EIN `contentsOfDirectory`-Aufruf, die vorhandenen Dateinamen als
    /// In-Memory-`Set`, dann ein günstiger Set-Lookup pro Eintrag — dieselbe
    /// Grundidee wie `SyncImportService`/`SyncSnapshotImportService.ladeKaeufe`,
    /// die Peer-Ordner ebenfalls per einmaliger Auflistung statt Einzelzugriffen
    /// lesen.
    ///
    /// **Bewusst KEIN persistiertes `bereitsExportiert`-Flag auf `KaufEintrag`**
    /// (ursprünglich erwogen, siehe `docs/EXPORT_PAKET_UMBAU.md`, „Mögliche
    /// künftige Verfeinerung"): ein reines Flag hätte dieselbe Bug-Klasse
    /// zurückgebracht, die für die übrigen Paket-Teile bereits gefunden und
    /// gefixt wurde (Fingerabdruck/Flag sagt „schon geschrieben", die Datei
    /// existiert aber nach einem Ordnerwechsel/einer Reaktivierung der
    /// Synchronisierung tatsächlich nicht mehr — siehe
    /// `schreibeTeilFallsGeaendert` in ``SyncSnapshotExportService``). Die
    /// Ordner-Auflistung hier prüft dagegen jedes Mal den TATSÄCHLICHEN
    /// Ordnerinhalt, kann also nicht auf demselben Weg veralten.
    /// Ohne hinterlegten Sync-Ordner ohne Wirkung. Rückgabewert meldet
    /// ausschließlich, ob der Ordnerzugriff (Berechtigung) geklappt hat.
    @discardableResult
    @MainActor
    static func exportiereNeueKaeufe(context: ModelContext) async -> Bool {
        guard SyncOrdnerService.gewaehlterOrdner() != nil else { return true }
        let alleLokalen = (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []
        guard !alleLokalen.isEmpty else { return true }

        // GitHub #171: kein eigener Security-Scope mehr — setzt die
        // sitzungsweit bereits offene Sitzung voraus (``SyncOrdnerZugriffsSitzung``).
        guard let syncOrdner = SyncOrdnerZugriffsSitzung.offen else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereNeueKaeufe")
            return false
        }

        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        guard await Task.detached(priority: .utility, operation: {
            SyncDateiZugriff.erstelleVerzeichnisKoordiniert(ordner)
        }).value else {
            return true
        }

        let vorhandeneDateinamen = Set(
            (await Task.detached(priority: .utility, operation: {
                SyncDateiZugriff.listeKoordiniert(ordner)
            }).value)?.map(\.lastPathComponent) ?? []
        )
        let fehlende = alleLokalen.filter { !vorhandeneDateinamen.contains("\($0.id.uuidString).json") }
        guard !fehlende.isEmpty else { return true }

        // Dieselben "gültige-IDs"-Sets wie `SyncSnapshotExportService.erstelleSnapshot`
        // (baumelnde Referenzen sollen genauso stillschweigend als `nil`
        // exportiert werden, nicht die App zum Absturz bringen).
        let gueltigeArtikelIDs = Set((try? context.fetch(FetchDescriptor<Artikel>()))?.map(\.persistentModelID) ?? [])
        let gueltigeGeschaeftIDs = Set((try? context.fetch(FetchDescriptor<Geschaeft>()))?.map(\.persistentModelID) ?? [])
        let gueltigeEinkaufsvorgangIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsvorgang>()))?.map(\.persistentModelID) ?? [])
        let gueltigeAbteilungIDs = Set((try? context.fetch(FetchDescriptor<Abteilung>()))?.map(\.persistentModelID) ?? [])

        for eintrag in fehlende {
            let zielURL = ordner.appendingPathComponent("\(eintrag.id.uuidString).json")
            let snapshot = KaufEintragSnapshot(
                id: eintrag.id,
                artikelID: SyncSnapshotExportService.sichereID(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs),
                einkaufsvorgangID: SyncSnapshotExportService.sichereID(eintrag.einkaufsvorgang, gueltigeIDs: gueltigeEinkaufsvorgangIDs),
                geschaeftID: SyncSnapshotExportService.sichereID(eintrag.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                abteilungID: SyncSnapshotExportService.sichereID(eintrag.abteilung, gueltigeIDs: gueltigeAbteilungIDs),
                artikelNameSnapshot: eintrag.artikelNameSnapshot,
                geschaeftNameSnapshot: eintrag.geschaeftNameSnapshot,
                datum: eintrag.datum,
                menge: eintrag.menge,
                abteilungBesuchsIndex: eintrag.abteilungBesuchsIndex
            )
            guard let daten = try? SyncSnapshotExportService.encoder.encode(snapshot) else { continue }
            _ = SyncSnapshotExportService.schreibeBlocking(daten, nach: zielURL)
        }
        return true
    }

    /// Baut Snapshots für ALLE lokalen `KaufEintrag`e, nicht nur die noch nicht
    /// exportierten wie ``exportiereNeueKaeufe(context:)`` — für den
    /// Multipeer-Catch-up-Kanal (GitHub #125), der beim Verbindungsaufbau den
    /// vollständigen Stand überträgt statt inkrementell einzelne Dateien
    /// nachzuliefern. Reine In-Memory-Berechnung, kein Datei-I/O.
    @MainActor
    static func alleSnapshots(context: ModelContext) -> [KaufEintragSnapshot] {
        let alleLokalen = (try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []
        guard !alleLokalen.isEmpty else { return [] }

        let gueltigeArtikelIDs = Set((try? context.fetch(FetchDescriptor<Artikel>()))?.map(\.persistentModelID) ?? [])
        let gueltigeGeschaeftIDs = Set((try? context.fetch(FetchDescriptor<Geschaeft>()))?.map(\.persistentModelID) ?? [])
        let gueltigeEinkaufsvorgangIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsvorgang>()))?.map(\.persistentModelID) ?? [])
        let gueltigeAbteilungIDs = Set((try? context.fetch(FetchDescriptor<Abteilung>()))?.map(\.persistentModelID) ?? [])

        return alleLokalen.map { eintrag in
            KaufEintragSnapshot(
                id: eintrag.id,
                artikelID: SyncSnapshotExportService.sichereID(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs),
                einkaufsvorgangID: SyncSnapshotExportService.sichereID(eintrag.einkaufsvorgang, gueltigeIDs: gueltigeEinkaufsvorgangIDs),
                geschaeftID: SyncSnapshotExportService.sichereID(eintrag.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                abteilungID: SyncSnapshotExportService.sichereID(eintrag.abteilung, gueltigeIDs: gueltigeAbteilungIDs),
                artikelNameSnapshot: eintrag.artikelNameSnapshot,
                geschaeftNameSnapshot: eintrag.geschaeftNameSnapshot,
                datum: eintrag.datum,
                menge: eintrag.menge,
                abteilungBesuchsIndex: eintrag.abteilungBesuchsIndex
            )
        }
    }

    /// Löscht eigene `kaeufe/`-Dateien, deren UUID keinem lokalen ``KaufEintrag``
    /// mehr entspricht und die älter als
    /// ``KaufEintragBereinigungService/karenzzeit`` sind — Catch-all für den
    /// Fall, dass ``entferneDateien(fuerKaufEintragIDs:)`` beim regulären
    /// Bereinigungslauf fehlschlug. Aufgerufen täglich aus
    /// ``KaufEintragBereinigungService/automatischBereinigenFallsFaellig(context:)``,
    /// das denselben Timer bereits besitzt. Best-effort, ohne Fehler nach außen
    /// zu melden. Ohne hinterlegten Sync-Ordner ohne Wirkung.
    @MainActor
    static func raeumeVerwaisteDateienAuf(context: ModelContext) async {
        guard SyncOrdnerService.gewaehlterOrdner() != nil else { return }

        let lokaleIDs = Set(
            ((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [])
                .map { "\($0.id.uuidString).json" }
        )
        let grenze = Date().addingTimeInterval(-KaufEintragBereinigungService.karenzzeit)

        // GitHub #171: kein eigener Security-Scope mehr — täglicher Timer,
        // kann außerhalb eines laufenden Polling-Zyklus feuern, deshalb
        // ``sicherstellenOffen()``.
        guard SyncOrdnerZugriffsSitzung.sicherstellenOffen(), let syncOrdner = SyncOrdnerZugriffsSitzung.offen else { return }

        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        let anzahl = await Task.detached(priority: .utility) {
            guard let dateien = SyncDateiZugriff.listeKoordiniert(ordner) else { return 0 }
            let verwaiste = dateien.filter { url in
                guard !lokaleIDs.contains(url.lastPathComponent) else { return false }
                guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let modDatum = attr[.modificationDate] as? Date else { return false }
                return modDatum < grenze
            }
            for url in verwaiste {
                SyncDateiZugriff.loescheKoordiniert(url)
            }
            return verwaiste.count
        }.value

        if anzahl > 0, SyncDebugLogger.istAktiv {
            SyncDebugLogger.log(.kaeufeVerwaisteBereinigt, details: "anzahl=\(anzahl)")
        }
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
        // GitHub #171: kein eigener Security-Scope mehr — kann außerhalb
        // eines laufenden Polling-Zyklus aufgerufen werden
        // (``KaufEintragBereinigungService``), deshalb ``sicherstellenOffen()``.
        guard SyncOrdnerZugriffsSitzung.sicherstellenOffen(), let syncOrdner = SyncOrdnerZugriffsSitzung.offen else { return }
        let ordner = SyncSnapshotExportService.eigenerKaeufeOrdner(in: syncOrdner)
        for id in ids {
            SyncDateiZugriff.loescheKoordiniert(ordner.appendingPathComponent("\(id.uuidString).json"))
        }
    }
}
