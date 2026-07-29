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
/// Korruptions-Recovery, siehe `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`).
///
/// Zwei Beweggründe, ein Mechanismus:
/// 1. **GitHub #63** — beim erstmaligen Verknüpfen eines Sync-Ordners lokale
///    Daten (insbesondere private Kaufhistorie, Bereich C) durch den Stand
///    eines bestehenden Peers ersetzen statt zu mergen.
/// 2. **Korruptions-Recovery** — ein lokal bereits korrumpierter Datensatz
///    (baumelnde Referenz, siehe `docs/DATABASE_CONCURRENCY.md`) lässt sich
///    über die normale SwiftData-API nicht reparieren; ein vollständiges
///    Zurücksetzen und Neuaufbau aus einem unkorrumpierten Peer-Snapshot
///    umgeht das, weil die korrumpierten Zeilen nie wieder geöffnet werden
///    (siehe ``ModelContainerController``).
///
/// Alle drei Operationen sind destruktiv/schwer rückgängig zu machen — jeder
/// Aufrufer muss vorher explizit bestätigen lassen (kein stilles Ausführen)
/// und `SyncPollingService` für die Dauer der Operation pausieren, damit
/// dessen Hintergrund-Timer nicht mitten in den Container-Austausch schreibt.
enum SyncErsetzenService {
    private static let backupDateiName = "ersetzen-backup.json"

    private static var backupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(backupDateiName)
    }

    struct BackupInfo {
        var erstelltAm: Date
        var groesseBytes: Int
    }

    /// Sichert den aktuellen Datenbestand als lokales, nicht geteiltes Backup
    /// — wiederverwendet ``SyncSnapshotExportService/erstelleSnapshot(context:)``
    /// für den Hauptinhalt. Genau eine Backup-Datei, ein erneuter Aufruf
    /// überschreibt die vorherige (siehe Typ-Doku für die Begründung dieser
    /// Aufbewahrungs-Entscheidung).
    @discardableResult
    @MainActor
    static func erstelleBackup(context: ModelContext) throws -> URL {
        let snapshot = SyncSnapshotExportService.erstelleSnapshot(context: context)
        let ignorierteVorschlaege = ((try? context.fetch(FetchDescriptor<IgnorierterGeschaeftsVorschlag>())) ?? []).map {
            IgnorierterGeschaeftsVorschlagSnapshot(
                name: $0.name, breitengrad: $0.breitengrad, laengengrad: $0.laengengrad, ignoriertAm: $0.ignoriertAm
            )
        }
        let backup = SyncErsetzenBackup(
            formatVersion: SyncErsetzenBackup.aktuelleFormatVersion,
            erstelltAm: Date(),
            snapshot: snapshot,
            ignorierteGeschaeftsVorschlaege: ignorierteVorschlaege
        )
        let daten = try JSONEncoder().encode(backup)
        let url = backupURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try daten.write(to: url, options: .atomic)
        return url
    }

    /// Metadaten des vorhandenen Backups für die UI (Datum, Größe) — `nil`,
    /// falls keins existiert oder es nicht lesbar ist.
    static func vorhandenesBackup() -> BackupInfo? {
        let url = backupURL
        guard let attribute = try? FileManager.default.attributesOfItem(atPath: url.path),
              let groesse = attribute[.size] as? Int,
              let daten = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
        else { return nil }
        return BackupInfo(erstelltAm: backup.erstelltAm, groesseBytes: groesse)
    }

    static func loescheBackup() {
        try? FileManager.default.removeItem(at: backupURL)
    }

    /// Sichert den aktuellen Stand (``erstelleBackup(context:)``), ersetzt den
    /// lokalen Store durch einen leeren
    /// (``ModelContainerController/ersetzeDurchLeerenContainer()``) und baut
    /// ihn ausschließlich aus den aktuell erreichbaren Peer-Snapshots neu auf.
    /// Liefert den neuen Context, damit der Aufrufer `SyncPollingService`
    /// darauf neu starten kann.
    @discardableResult
    @MainActor
    static func ersetzenDurchPeer(containerController: ModelContainerController) async throws -> ModelContext {
        try erstelleBackup(context: containerController.modelContainer.mainContext)
        let neuerContext = try containerController.ersetzeDurchLeerenContainer()
        await SyncSnapshotImportService.importiereSnapshots(context: neuerContext)
        return neuerContext
    }

    /// Wie ``ersetzenDurchPeer(containerController:)``, aber Neuaufbau aus dem
    /// eigenen lokalen Backup statt aus Peer-Snapshots (kein vorheriges
    /// Backup nötig — das aktuelle wird ja gerade wiederhergestellt, nicht
    /// überschrieben).
    @discardableResult
    @MainActor
    static func wiederherstellenAusBackup(containerController: ModelContainerController) throws -> ModelContext {
        guard let daten = try? Data(contentsOf: backupURL),
              let backup = try? JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
        else {
            throw SyncErsetzenFehler.keinBackupVorhanden
        }
        let neuerContext = try containerController.ersetzeDurchLeerenContainer()
        // Sentinel-Geräte-ID statt der eigenen: verhindert einen
        // Phantom-``SyncPeerInfo``-Eintrag und Kollisionen mit echter
        // Peer-Zähler-Buchhaltung (``SyncPeerZaehlerStand``).
        SyncSnapshotImportService.importiereEinzelnenSnapshot(backup.snapshot, peerGeraeteID: "lokales-backup", context: neuerContext)
        for vorschlag in backup.ignorierteGeschaeftsVorschlaege {
            let neuer = IgnorierterGeschaeftsVorschlag(
                name: vorschlag.name, breitengrad: vorschlag.breitengrad, laengengrad: vorschlag.laengengrad
            )
            neuer.ignoriertAm = vorschlag.ignoriertAm
            neuerContext.insert(neuer)
        }
        try? neuerContext.save()
        return neuerContext
    }
}
