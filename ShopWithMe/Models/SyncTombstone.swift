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
/// **Bereinigung seit Peer-Lebenszyklus Baustein C** (vorher bewusst
/// unbegrenzt, siehe `docs/PEER_LEBENSZYKLUS.md`):
/// ``SyncTombstoneService/raeumeAlteTombstonesAufFallsFaellig(context:)``
/// löscht Tombstones, die älter als der aktuelle dynamische
/// Aufbewahrungs-Wasserstand sind — dominiert vorher von einem Tombstone pro
/// `KaufEintrag`, automatisch 48h nach jedem Einkauf erzeugt.
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

    private static let letzteBereinigungSchluessel = "syncTombstoneBereinigungLetzteBereinigung"

    /// Mindestabstand zwischen zwei automatischen Aufräumläufen, analog
    /// `SyncExportService.automatischesBereinigungsintervall`.
    static let automatischesBereinigungsintervall: TimeInterval = 60 * 60 * 24

    static var letzteBereinigung: Date? {
        get { UserDefaults.standard.object(forKey: letzteBereinigungSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: letzteBereinigungSchluessel) }
    }

    /// Peer-Lebenszyklus, Baustein C: löscht Tombstones, deren `geloeschtAm`
    /// vor dem aktuellen dynamischen Aufbewahrungs-Wasserstand liegt (siehe
    /// ``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)``) —
    /// ersetzt die vorherige „nie bereinigt"-Politik. Höchstens einmal pro
    /// ``automatischesBereinigungsintervall`` tatsächlich ausgeführt. Kein
    /// Löschversuch, wenn der Wasserstand `nil` liefert (kein anderer Peer
    /// bekannt, oder ein aktuell vorhandener Peer-Ordner nicht lesbar).
    /// - Parameter erzwungenerWasserstand: Wird nur vom manuellen „Ich bin
    ///   sicher, dass ich der einzige Peer bin"-Bestätigungs-Button in
    ///   `DebuggingView` übergeben, siehe
    ///   ``SyncExportService/raeumeAlteEigeneEventDateienAufFallsFaellig(erzwungenerWasserstand:)``.
    @MainActor
    static func raeumeAlteTombstonesAufFallsFaellig(context: ModelContext, erzwungenerWasserstand: Date? = nil) async {
        if let letzte = letzteBereinigung, Date().timeIntervalSince(letzte) < automatischesBereinigungsintervall {
            return
        }
        letzteBereinigung = Date()

        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        let berechneterWasserstand = erzwungenerWasserstand == nil
            ? await SyncSnapshotImportService.aktuellerAufraeumWasserstand(in: syncOrdner)
            : erzwungenerWasserstand
        guard let wasserstand = berechneterWasserstand else { return }

        let alle = (try? context.fetch(FetchDescriptor<SyncTombstone>())) ?? []
        let zuLoeschende = alle.filter { $0.geloeschtAm < wasserstand }
        guard !zuLoeschende.isEmpty else { return }
        for tombstone in zuLoeschende {
            context.delete(tombstone)
        }
        try? context.save()
        if SyncDebugLogger.istAktiv {
            SyncDebugLogger.log(.tombstonesBereinigt, details: "anzahl=\(zuLoeschende.count)")
        }
    }
}
