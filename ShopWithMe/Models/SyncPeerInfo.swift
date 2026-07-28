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

    init(peerGeraeteID: String, geraeteName: String) {
        self.id = UUID()
        self.peerGeraeteID = peerGeraeteID
        self.geraeteName = geraeteName
    }
}

extension SyncPeerInfo {
    /// Merkt sich (oder aktualisiert) den Anzeigenamen von `peerGeraeteID`.
    static func aktualisiere(peerGeraeteID: String, geraeteName: String, context: ModelContext) {
        var deskriptor = FetchDescriptor<SyncPeerInfo>(
            predicate: #Predicate { $0.peerGeraeteID == peerGeraeteID }
        )
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            bestehende.geraeteName = geraeteName
        } else {
            context.insert(SyncPeerInfo(peerGeraeteID: peerGeraeteID, geraeteName: geraeteName))
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
