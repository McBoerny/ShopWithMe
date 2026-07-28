import Foundation
import SwiftData

/// Merkt sich pro (Peer-Gerät, ``Geschaeft``) den zuletzt bei diesem Peer
/// beobachteten Stand von ``Geschaeft/anzahlEinkaufsvorgaenge`` — Grundlage für
/// die additive Merge-Regel aus `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`
/// Abschnitt 4.2a: dieser Zähler wird unabhängig von der eigentlichen
/// Kaufhistorie geführt und ist manuell zurücksetzbar (GitHub #30), ein
/// einfaches Überschreiben beim Sync würde daher Besuche verlieren, die
/// zwischen zwei Sync-Zyklen auf einem Gerät entstanden sind. Stattdessen wird
/// bei jedem Import nur der **Zuwachs** seit dem zuletzt bekannten Stand dieses
/// Peers zum lokalen Zähler addiert (siehe ``SyncSnapshotImportService``).
@Model
final class SyncPeerZaehlerStand {
    var id: UUID
    var peerGeraeteID: String
    var geschaeftID: UUID
    var zuletztGesehenerWert: Int

    init(peerGeraeteID: String, geschaeftID: UUID, zuletztGesehenerWert: Int) {
        self.id = UUID()
        self.peerGeraeteID = peerGeraeteID
        self.geschaeftID = geschaeftID
        self.zuletztGesehenerWert = zuletztGesehenerWert
    }
}

extension SyncPeerZaehlerStand {
    /// Liefert den seit dem letzten bekannten Stand dieses Peers neu
    /// hinzugekommenen Anteil von `remoteWert` und aktualisiert (bzw. legt bei
    /// Bedarf an) den gemerkten Stand. Ein `remoteWert`, der unter dem zuletzt
    /// bekannten liegt (z.B. weil der Peer seinen Zähler manuell zurückgesetzt
    /// hat, GitHub #30), erzeugt bewusst keinen negativen Zuwachs — der lokal
    /// bereits gemergte Anteil vorheriger Besuche bleibt erhalten.
    static func zuwachs(
        peerGeraeteID: String, geschaeftID: UUID, remoteWert: Int, context: ModelContext
    ) -> Int {
        var deskriptor = FetchDescriptor<SyncPeerZaehlerStand>(
            predicate: #Predicate { $0.peerGeraeteID == peerGeraeteID && $0.geschaeftID == geschaeftID }
        )
        deskriptor.fetchLimit = 1
        let bestehender = try? context.fetch(deskriptor).first

        let zuletztGesehen = bestehender?.zuletztGesehenerWert ?? 0
        let zuwachs = max(0, remoteWert - zuletztGesehen)

        if let bestehender {
            bestehender.zuletztGesehenerWert = remoteWert
        } else {
            context.insert(SyncPeerZaehlerStand(peerGeraeteID: peerGeraeteID, geschaeftID: geschaeftID, zuletztGesehenerWert: remoteWert))
        }
        return zuwachs
    }
}
