import Foundation
import SwiftData

/// Gemeinsame "nur bei tatsächlicher Änderung schreiben"-Entscheidungslogik
/// für die beiden G-Counter-Peer-Zustands-Typen (``SyncPeerZaehlerStand``,
/// ``WarengruppenDistanzPeerZaehlerStand``, GitHub #104) — beide waren vorher
/// wortgleiche Kopien voneinander, unterschieden sich nur im Namen des
/// Fremdschlüsselfelds (`geschaeftID` vs. `distanzID`).
///
/// **Bewusst NICHT der Fetch selbst** (bliebe je Typ mit seinem eigenen,
/// konkreten `#Predicate` bestehen): ein generischer `#Predicate` in einem
/// generischen Kontext über `Self` ist unzuverlässig — siehe
/// ``ModelReference/resolved(in:)`` für den bereits dokumentierten
/// Präzedenzfall. Jeder Typ bleibt deshalb für seinen eigenen,
/// dictionary-artig indizierten Fetch zuständig und übergibt nur dessen
/// Ergebnis (`bestehender`) sowie eine Fabrikfunktion für den Neuanlage-Fall.
enum GCounterPeerZustandService {
    /// `bestehender`: Ergebnis des vom Aufrufer bereits ausgeführten,
    /// konkreten Fetches nach (`peerGeraeteID`, Fremdschlüssel), `nil` falls
    /// noch kein Beitrag dieses Peers bekannt ist. `erzeugeNeuen`: liefert bei
    /// Bedarf ein frisches Objekt mit `eigenerWertDesPeers` — wird nur im
    /// Neuanlage-Fall aufgerufen.
    static func merkeEigenenZuwachsDesPeers<T: PersistentModel>(
        bestehender: T?, eigenerWertDesPeers: Int, zuletztGesehenerWert: ReferenceWritableKeyPath<T, Int>,
        erzeugeNeuen: () -> T, context: ModelContext
    ) {
        if let bestehender {
            guard bestehender[keyPath: zuletztGesehenerWert] != eigenerWertDesPeers else { return }
            bestehender[keyPath: zuletztGesehenerWert] = eigenerWertDesPeers
        } else {
            context.insert(erzeugeNeuen())
        }
    }
}
