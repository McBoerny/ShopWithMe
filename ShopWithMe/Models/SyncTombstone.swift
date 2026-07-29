import Foundation
import SwiftData

/// Merkt eine absichtliche Löschung einer Bereich-B-Entität vor
/// (Architektur-Revision „Alternative A", Folge aus GitHub #39: gelöschte
/// ``Geschaeft``e/``Artikel``/``ArtikelKategorie``n kamen zurück, weil der
/// additive Bereich-B-Merge nie destruktiv ist — ein Peer, der die Entität
/// noch in seinem eigenen Snapshot führt, legt sie beim nächsten Sync
/// unwissentlich neu an).
///
/// Ein Tombstone wird sowohl bei der eigenen Löschung angelegt (damit sie bei
/// künftigen Exporten weiterhin mitgeteilt wird, auch nachdem das Objekt selbst
/// längst weg ist) als auch beim Empfang eines fremden Tombstones übernommen
/// (damit er weiter an andere Peers propagiert wird, auch wenn das
/// ursprünglich löschende Gerät offline geht). Bewusst generisch über
/// `entitaetsArt` gehalten, analog ``SyncEntitaetsAlias``.
///
/// `geloeschteID` ist immer die **lokale** ID aus Sicht des Geräts, das den
/// Tombstone anlegt bzw. übernimmt (bei einem übernommenen Tombstone also
/// bereits über ``SyncEntitaetsAliasService`` aufgelöst) — nur so kann jedes
/// Gerät seinen eigenen Bestand korrekt dagegen abgleichen.
///
/// **Bewusst keine Bereinigung/Verfallsdatum** in dieser ersten Umsetzung —
/// die Tombstone-Liste wächst unbegrenzt mit, aber langsam (nur tatsächliche
/// Löschungen, keine laufenden Änderungen); eine Kürzung nach hinreichend
/// langer Zeit wäre eine spätere, unabhängige Ergänzung.
@Model
final class SyncTombstone {
    var id: UUID
    var entitaetsArt: String
    var geloeschteID: UUID
    var geloeschtAm: Date

    init(entitaetsArt: String, geloeschteID: UUID, geloeschtAm: Date = Date()) {
        self.id = UUID()
        self.entitaetsArt = entitaetsArt
        self.geloeschteID = geloeschteID
        self.geloeschtAm = geloeschtAm
    }
}

enum SyncTombstoneService {
    /// Merkt eine lokale Löschung vor — **vor** dem eigentlichen
    /// `context.delete(...)` aufzurufen, während `id` noch bekannt ist.
    /// Idempotent: ein bereits bestehender Tombstone für dieselbe
    /// (`art`, `id`)-Kombination wird nicht doppelt angelegt.
    @discardableResult
    static func markiereGeloescht(art: String, id: UUID, context: ModelContext) -> SyncTombstone {
        if let bestehender = tombstone(art: art, id: id, context: context) {
            return bestehender
        }
        let neuer = SyncTombstone(entitaetsArt: art, geloeschteID: id)
        context.insert(neuer)
        return neuer
    }

    private static func tombstone(art: String, id: UUID, context: ModelContext) -> SyncTombstone? {
        var deskriptor = FetchDescriptor<SyncTombstone>(
            predicate: #Predicate { $0.entitaetsArt == art && $0.geloeschteID == id }
        )
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Ob `id` (bereits lokal aufgelöst) als gelöscht gilt.
    static func istGeloescht(art: String, id: UUID, context: ModelContext) -> Bool {
        tombstone(art: art, id: id, context: context) != nil
    }

    /// Alle lokal bekannten gelöschten IDs einer Art — sowohl selbst
    /// gelöschte als auch von einem Peer übernommene Tombstones. Für
    /// wiederholte Prüfungen innerhalb eines Merge-Durchlaufs effizienter als
    /// einzelne ``istGeloescht(art:id:context:)``-Aufrufe.
    static func geloeschteIDs(art: String, context: ModelContext) -> Set<UUID> {
        let deskriptor = FetchDescriptor<SyncTombstone>(predicate: #Predicate { $0.entitaetsArt == art })
        let alle = (try? context.fetch(deskriptor)) ?? []
        return Set(alle.map(\.geloeschteID))
    }

    /// Alle lokal bekannten Tombstones — für den Snapshot-Export.
    static func alle(context: ModelContext) -> [SyncTombstone] {
        (try? context.fetch(FetchDescriptor<SyncTombstone>())) ?? []
    }
}
