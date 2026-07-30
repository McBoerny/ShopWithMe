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
///    umgeht das, weil die korrumpierten Zeilen nie wieder geöffnet werden.
///
/// **Neustart-Aufforderung statt nahtlosem Austausch (Korrektur):** Ein
/// erster Entwurf ersetzte den lokalen Store zur Laufzeit (`ModelContainer`
/// wurde austauschbar gemacht, `.id(generation)` erzwang einen View-Baum-
/// Neuaufbau). Auf einem echten Gerät führte das zu einem SQLite-I/O-Fehler
/// und Absturz: `SyncPollingService.stoppen()` fordert Cancellation nur
/// kooperativ an, wartet aber nicht, bis ein bereits laufender Sync-Zyklus
/// tatsächlich beendet ist — lief einer noch, griff er weiter auf die Datei
/// zu, während sie physisch gelöscht wurde. Statt diese eine Wettlaufsituation
/// (und potenziell weitere, nicht ausgeschlossene ähnliche) einzeln zu jagen,
/// verschiebt dieser Mechanismus die eigentliche Ersetzung strukturell an den
/// einzigen Zeitpunkt, an dem garantiert nichts anderes auf den Store
/// zugreift: den Anfang eines frischen Prozesses, bevor überhaupt ein
/// ``ModelContainer`` existiert (siehe ``ShopWithMeApp/init()``).
///
/// Ablauf: `plane…()` sichert (falls nötig) und merkt nur eine ausstehende
/// Aktion vor — der Anwender wird gebeten, die App zu schließen und neu zu
/// öffnen. Beim nächsten Start löscht ``loescheStoreDateiFallsAusstehend(url:)``
/// die Store-Datei, **bevor** `ShopWithMeApp.init()` einen `ModelContainer`
/// dafür öffnet; nach dem Start füllt ``fuehreAusstehendeAktionAus(context:)``
/// den jetzt frischen, leeren Context.
enum SyncErsetzenService {
    enum AusstehendeAktion: String {
        case ersetzenDurchPeer
        case wiederherstellenAusBackup
    }

    private static let ausstehendeAktionSchluessel = "syncErsetzenAusstehendeAktion"
    private static let backupDateiName = "ersetzen-backup.json"

    private static var backupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(backupDateiName)
    }

    /// Die beim nächsten App-Start auszuführende Aktion, `nil` im
    /// Normalfall. Übersteht einen App-Neustart (`UserDefaults`), da genau
    /// das der Zweck ist — siehe Typ-Dokumentation.
    private(set) static var ausstehendeAktion: AusstehendeAktion? {
        get { UserDefaults.standard.string(forKey: ausstehendeAktionSchluessel).flatMap(AusstehendeAktion.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: ausstehendeAktionSchluessel) }
    }

    struct BackupInfo {
        var erstelltAm: Date
        var groesseBytes: Int
    }

    // MARK: - Planen (aktueller Sitzung, vor dem Neustart)

    /// Sichert den aktuellen Datenbestand und merkt „Ersetzen durch Peer" für
    /// den nächsten App-Start vor. Verändert den Datenbestand selbst noch
    /// nicht — dafür muss die App neu gestartet werden.
    @MainActor
    static func planeErsetzenDurchPeer(context: ModelContext) throws {
        try erstelleBackup(context: context)
        ausstehendeAktion = .ersetzenDurchPeer
    }

    /// Merkt „Wiederherstellen aus dem lokalen Backup" für den nächsten
    /// App-Start vor. Wirft, falls kein Backup existiert.
    static func planeWiederherstellenAusBackup() throws {
        guard vorhandenesBackup() != nil else {
            throw SyncErsetzenFehler.keinBackupVorhanden
        }
        ausstehendeAktion = .wiederherstellenAusBackup
    }

    // MARK: - Ausführen (nächster App-Start)

    /// Löscht die Store-Datei (samt `-wal`/`-shm`) physisch, falls eine
    /// Aktion aussteht — **muss** vor dem Öffnen eines ``ModelContainer``
    /// für `url` aufgerufen werden (siehe ``ShopWithMeApp/init()``). Löscht
    /// nichts, falls keine Aktion aussteht (jeder normale App-Start).
    static func loescheStoreDateiFallsAusstehend(url: URL) {
        guard ausstehendeAktion != nil else { return }
        let ordner = url.deletingLastPathComponent()
        let basisname = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: ordner.appendingPathComponent(basisname + suffix))
        }
    }

    /// Füllt den (nach ``loescheStoreDateiFallsAusstehend(url:)`` frischen,
    /// leeren) Context gemäß der ausstehenden Aktion und löscht sie
    /// anschließend — ohne Wirkung, falls keine Aktion aussteht.
    @MainActor
    static func fuehreAusstehendeAktionAus(context: ModelContext) async {
        guard let aktion = ausstehendeAktion else { return }
        ausstehendeAktion = nil

        switch aktion {
        case .ersetzenDurchPeer:
            await SyncSnapshotImportService.importiereSnapshots(context: context)
        case .wiederherstellenAusBackup:
            guard let daten = try? Data(contentsOf: backupURL),
                  let backup = try? JSONDecoder().decode(SyncErsetzenBackup.self, from: daten)
            else { return }
            // Sentinel-Geräte-ID statt der eigenen: verhindert einen
            // Phantom-``SyncPeerInfo``-Eintrag und Kollisionen mit echter
            // Peer-Zähler-Buchhaltung (``SyncPeerZaehlerStand``).
            SyncSnapshotImportService.importiereEinzelnenSnapshot(backup.snapshot, peerGeraeteID: "lokales-backup", context: context)
            for vorschlag in backup.ignorierteGeschaeftsVorschlaege {
                let neuer = IgnorierterGeschaeftsVorschlag(
                    name: vorschlag.name, breitengrad: vorschlag.breitengrad, laengengrad: vorschlag.laengengrad
                )
                neuer.ignoriertAm = vorschlag.ignoriertAm
                context.insert(neuer)
            }
            try? context.save()
        }
    }

    // MARK: - Backup

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
}
