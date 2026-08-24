import Foundation
import SwiftData

/// Merkt sich pro (Peer-Gerät, ``WarengruppenDistanz``-Zeile) den zuletzt von
/// diesem Peer gemeldeten EIGENEN Beobachtungsanteil
/// (``WarengruppenDistanz/eigeneBeobachtungsAnzahl`` DES PEERS, nicht dessen
/// bereits gemergter Gesamtwert) — G-Counter-Baustein für
/// ``WarengruppenDistanz/beobachtungsAnzahl``, exaktes Gegenstück zu
/// ``SyncPeerZaehlerStand`` (siehe dort für die Begründung des Musters,
/// GitHub #87).
///
/// `distanzID` ist die BEREITS LOKAL AUFGELÖSTE ``WarengruppenDistanz/id``
/// (nicht die vom Peer gemeldete, unabhängig entstandene ID — jedes Gerät legt
/// eine ``WarengruppenDistanz``-Zeile für ein Abteilung-Paar unabhängig mit
/// eigener ID an, das Matching läuft über den (Geschäft, AbteilungA,
/// AbteilungB)-Schlüssel, siehe ``SyncSnapshotImportService``).
@Model
final class WarengruppenDistanzPeerZaehlerStand {
    var id: UUID
    var peerGeraeteID: String
    var distanzID: UUID
    var zuletztGesehenerWert: Int

    init(peerGeraeteID: String, distanzID: UUID, zuletztGesehenerWert: Int) {
        self.id = UUID()
        self.peerGeraeteID = peerGeraeteID
        self.distanzID = distanzID
        self.zuletztGesehenerWert = zuletztGesehenerWert
    }
}

extension WarengruppenDistanzPeerZaehlerStand {
    /// Der zuletzt von `peerGeraeteID` für diese Zeile gemeldete eigene
    /// Beobachtungsanteil, `0` falls noch nie ein Beitrag dieses Peers
    /// gemerkt wurde. Grundlage für die Delta-Berechnung beim Wert-Merge in
    /// ``SyncSnapshotImportService`` (siehe dort): anders als der reine
    /// Zähler-G-Counter (``WarengruppenDistanz/beobachtungsAnzahl``, sicher
    /// durch bloßes Summieren) ist die gewichtete Mittelung von
    /// ``WarengruppenDistanz/distanz`` NICHT idempotent, wenn man bei jedem
    /// Sync erneut mit dem VOLLEN aktuellen Peer-Gewicht mischt — nur der
    /// tatsächliche Zuwachs seit dem zuletzt gesehenen Stand darf einfließen,
    /// sonst würde ein unveränderter, wiederholt gesyncter Wert bei jedem
    /// Zyklus erneut Richtung Peer-Wert verschoben.
    /// `bekannt`: alle Zeilen DIESES `peerGeraeteID` vorab per
    /// `#Predicate { $0.peerGeraeteID == peerGeraeteID }` geladen und nach
    /// `distanzID` indiziert — vom Aufrufer EINMAL pro Merge-Lauf gebaut
    /// (``SyncSnapshotImportService/mergeWarengruppenDistanzen``) statt hier
    /// (und in ``merkeEigenenZuwachsDesPeers(bekannt:peerGeraeteID:distanzID:eigenerWertDesPeers:context:)``)
    /// je zwei eigene Fetches pro Remote-Eintrag auszulösen (Performance-Fund #155).
    static func zuletztGesehenerWert(bekannt: [UUID: WarengruppenDistanzPeerZaehlerStand], distanzID: UUID) -> Int {
        bekannt[distanzID]?.zuletztGesehenerWert ?? 0
    }

    /// Merkt sich (aktualisiert) den zuletzt von `peerGeraeteID` für diese
    /// (bereits lokal aufgelöste) ``WarengruppenDistanz``-Zeile gemeldeten
    /// eigenen Beobachtungsanteil. Reines Ablegen ohne Arithmetik —
    /// ``WarengruppenDistanz/beobachtungsAnzahl`` bildet die Summe erst beim
    /// Lesen. Schreibt nur bei tatsächlicher Änderung (sonst würde jeder
    /// Sync-Zyklus eine Store-Änderung erzwingen, selbst ohne neue echte
    /// Beobachtung — dieselbe Überlegung wie bei ``SyncPeerZaehlerStand``);
    /// Entscheidungslogik dafür geteilt mit ``SyncPeerZaehlerStand``, siehe
    /// ``GCounterPeerZustandService``.
    static func merkeEigenenZuwachsDesPeers(
        bekannt: inout [UUID: WarengruppenDistanzPeerZaehlerStand], peerGeraeteID: String, distanzID: UUID, eigenerWertDesPeers: Int,
        context: ModelContext
    ) {
        GCounterPeerZustandService.merkeEigenenZuwachsDesPeers(
            bestehender: bekannt[distanzID], eigenerWertDesPeers: eigenerWertDesPeers, zuletztGesehenerWert: \.zuletztGesehenerWert,
            erzeugeNeuen: {
                let neu = WarengruppenDistanzPeerZaehlerStand(peerGeraeteID: peerGeraeteID, distanzID: distanzID, zuletztGesehenerWert: eigenerWertDesPeers)
                bekannt[distanzID] = neu
                return neu
            },
            context: context
        )
    }
}
