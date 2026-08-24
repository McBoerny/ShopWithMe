import Foundation
import SwiftData

/// Merkt sich pro (Peer-Gerät, ``Geschaeft``) den zuletzt von diesem Peer
/// gemeldeten EIGENEN Beitrag zu ``Geschaeft/anzahlEinkaufsvorgaenge``
/// (``Geschaeft/eigeneAnzahlEinkaufsvorgaenge`` DES PEERS, nicht dessen bereits
/// gemergter Gesamtwert) — Baustein des G-Counter-Musters in
/// ``Geschaeft/anzahlEinkaufsvorgaenge``.
///
/// **Architektur-Korrektur (Live-Test-Fund, siehe
/// `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 17):** Ursprünglich
/// eine „Delta seit zuletzt gesehenem Gesamtwert"-Regel — dabei wurde
/// versehentlich derselbe echte Beitrag bei jedem Hin-und-Her zwischen zwei
/// Geräten erneut mitgezählt, weil der gemeldete „Gesamtwert" eines Peers
/// selbst schon Beiträge zurückenthielt, die ursprünglich von HIER kamen
/// (unbegrenztes Aufschaukeln ohne echte neue Einkäufe). Jetzt reines
/// Ablegen des von einem Peer gemeldeten EIGENEN Beitrags — jeder Beitrag
/// zählt dadurch an genau einer Stelle, unabhängig davon, über wie viele
/// Geräte er weitergereicht wird.
///
/// `geschaeftID` ist die BEREITS LOKAL AUFGELÖSTE ``Geschaeft/id`` (nicht die
/// vom Peer gemeldete, ggf. abweichende Fremd-ID) — Zuordnung von
/// unterschiedlichen Fremd-IDs verschiedener Peers auf dasselbe reale
/// Geschäft übernimmt bereits ``SyncEntitaetsAliasService`` vor dem Aufruf
/// hier.
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
    /// `bekannt`: alle Zeilen DIESES `peerGeraeteID` vorab per
    /// `#Predicate { $0.peerGeraeteID == peerGeraeteID }` geladen und nach
    /// `geschaeftID` indiziert — vom Aufrufer EINMAL pro Merge-Lauf gebaut
    /// (z.B. ``SyncSnapshotImportService/mergeGeschaefte``) statt hier pro
    /// Remote-Eintrag einen eigenen Fetch auszulösen (Performance-Fund #155).
    /// Merkt sich (aktualisiert) den zuletzt von `peerGeraeteID` für dieses
    /// (bereits lokal aufgelöste) Geschäft gemeldeten eigenen Beitrag. Reines
    /// Ablegen ohne Arithmetik — ``Geschaeft/anzahlEinkaufsvorgaenge`` bildet
    /// die Summe erst beim Lesen. Schreibt nur bei tatsächlicher Änderung
    /// (sonst würde jeder Sync-Zyklus eine Store-Änderung erzwingen, selbst
    /// ohne neuen echten Einkauf — dieselbe Überlegung wie bei
    /// ``SyncPeerInfo``); Entscheidungslogik dafür geteilt mit
    /// ``WarengruppenDistanzPeerZaehlerStand``, siehe ``GCounterPeerZustandService``.
    static func merkeEigenenZuwachsDesPeers(
        bekannt: inout [UUID: SyncPeerZaehlerStand], peerGeraeteID: String, geschaeftID: UUID, eigenerWertDesPeers: Int, context: ModelContext
    ) {
        GCounterPeerZustandService.merkeEigenenZuwachsDesPeers(
            bestehender: bekannt[geschaeftID], eigenerWertDesPeers: eigenerWertDesPeers, zuletztGesehenerWert: \.zuletztGesehenerWert,
            erzeugeNeuen: {
                let neu = SyncPeerZaehlerStand(peerGeraeteID: peerGeraeteID, geschaeftID: geschaeftID, zuletztGesehenerWert: eigenerWertDesPeers)
                bekannt[geschaeftID] = neu
                return neu
            },
            context: context
        )
    }
}
