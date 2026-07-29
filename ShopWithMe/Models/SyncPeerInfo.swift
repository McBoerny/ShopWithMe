import Foundation
import SwiftData

/// Merkt sich den zuletzt bekannten Anzeigenamen (``DatabaseLeaseService/geraeteName``)
/// eines Peer-Geräts, aktualisiert bei jedem ``SyncSnapshotImportService``-Lauf
/// aus dem jeweiligen `export.json` (siehe ``SyncSnapshot/geraeteName``).
///
/// Einziger Zweck: `SyncEvent.autorGeraeteID` (eine reine UUID) in eine
/// menschenlesbare Form auflösen, z.B. für den Überkauf-Hinweis (GitHub #48,
/// „Bereits von {Gerätename} abgehakt"). Bewusst kein Bereich-B-Stammdatum
/// (nicht Teil von ``SyncSnapshot`` selbst, sondern nebenläufig aus dessen
/// `geraeteID`/`geraeteName`-Feldern abgeleitet) — eine rein lokale,
/// nicht synchronisierte Zwischenablage.
@Model
final class SyncPeerInfo {
    var id: UUID
    var peerGeraeteID: String
    var geraeteName: String
    /// Zeitpunkt des zuletzt erfolgreich importierten Snapshots dieses Peers
    /// (dessen ``SyncSnapshot/erzeugtAm``, nicht der lokale Import-Zeitpunkt) —
    /// Grundlage für ``SyncSnapshotImportService/maximalesSnapshotAlter``:
    /// verwaiste Peer-Ordner aus früheren Testinstallationen (jede
    /// Neuinstallation erzeugt eine neue Geräte-ID) sollen nach hinreichend
    /// langer Inaktivität nicht mehr für immer alte Daten zurückspielen.
    /// Optional, damit vor dieser Ergänzung angelegte Datensätze nicht
    /// abstürzen — `nil` wird wie „schon lange nicht mehr gesehen" behandelt.
    var zuletztGesehenRaw: Date?

    init(peerGeraeteID: String, geraeteName: String, zuletztGesehen: Date = Date()) {
        self.id = UUID()
        self.peerGeraeteID = peerGeraeteID
        self.geraeteName = geraeteName
        self.zuletztGesehenRaw = zuletztGesehen
    }
}

extension SyncPeerInfo {
    var zuletztGesehen: Date {
        zuletztGesehenRaw ?? .distantPast
    }

    /// Merkt sich (oder aktualisiert) Anzeigenamen und Zuletzt-gesehen-Zeitpunkt
    /// von `peerGeraeteID`.
    static func aktualisiere(peerGeraeteID: String, geraeteName: String, zuletztGesehen: Date, context: ModelContext) {
        var deskriptor = FetchDescriptor<SyncPeerInfo>(
            predicate: #Predicate { $0.peerGeraeteID == peerGeraeteID }
        )
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            bestehende.geraeteName = geraeteName
            bestehende.zuletztGesehenRaw = zuletztGesehen
        } else {
            context.insert(SyncPeerInfo(peerGeraeteID: peerGeraeteID, geraeteName: geraeteName, zuletztGesehen: zuletztGesehen))
        }
    }

    /// Der zuletzt bekannte Anzeigename von `peerGeraeteID`, `nil` falls noch
    /// nie ein Snapshot dieses Geräts importiert wurde (z.B. direkt nach dem
    /// Verbinden eines Sync-Ordners, bevor der erste Sync-Zyklus lief) oder
    /// falls die ID dem eigenen Gerät entspricht (kein Eintrag nötig).
    static func geraeteName(fuer peerGeraeteID: String, context: ModelContext) -> String? {
        var deskriptor = FetchDescriptor<SyncPeerInfo>(
            predicate: #Predicate { $0.peerGeraeteID == peerGeraeteID }
        )
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first?.geraeteName
    }
}
