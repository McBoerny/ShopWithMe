import Foundation
import SwiftData

/// Merkt sich einen Bereich-B-Merge-Kandidaten (``Geschaeft``/``Artikel``/
/// ``Einkaufsliste``, generisch über ``SyncEntitaetsArt`` wie
/// ``SyncEntitaetsAlias``), der beim automatischen Hintergrund-Sync weder per
/// ID/Alias noch per strenger Namens-/Orts-Regel eindeutig einem lokalen
/// Objekt zugeordnet werden konnte, aber nach der großzügigeren interaktiven
/// Regel möglicherweise doch derselben realen Entität entspricht — z.B. ein
/// ``Geschaeft`` ohne Koordinaten (GitHub #86 verlangt seither zwingend
/// Koordinaten auf beiden Seiten für den automatischen Merge) oder ein
/// ``Artikel``/eine ``Einkaufsliste`` mit teilweise übereinstimmendem, aber
/// nicht exakt gleichem Namen.
///
/// Ohne diese Tabelle würde `SyncSnapshotImportService` einen solchen
/// Remote-Eintrag beim ersten Sync-Zyklus still als neues, unabhängiges
/// Objekt anlegen (sichtbar, aber unbemerkt eine Dublette). Mit dieser
/// Tabelle bleibt der Remote-Eintrag stattdessen zurückgestellt, bis der
/// Nutzer aktiv entscheidet (`SyncOrdnerSettingsView`, generalisierte
/// Abgleich-Sheet-View) — „gleich" registriert einen ``SyncEntitaetsAlias``
/// und übernimmt den gewählten Namen, „unterschiedlich" legt das lokale
/// Objekt regulär neu an. Beide Auflösungen löschen den Eintrag hier danach.
///
/// Additiv neu (kein bestehendes Feld transformiert) — keine neue
/// `SchemaVN`/`MigrationStage` nötig, siehe `docs/DECISIONS.md`.
@Model
final class SyncAbgleichKandidat {
    var id: UUID
    var entitaetsArt: String
    var peerGeraeteID: String
    var fremdeID: UUID
    var fremderName: String
    var lokaleID: UUID
    var lokalerName: String
    var erkanntAm: Date

    init(
        entitaetsArt: String, peerGeraeteID: String, fremdeID: UUID, fremderName: String,
        lokaleID: UUID, lokalerName: String, erkanntAm: Date = Date()
    ) {
        self.id = UUID()
        self.entitaetsArt = entitaetsArt
        self.peerGeraeteID = peerGeraeteID
        self.fremdeID = fremdeID
        self.fremderName = fremderName
        self.lokaleID = lokaleID
        self.lokalerName = lokalerName
        self.erkanntAm = erkanntAm
    }
}

extension SyncAbgleichKandidat {
    /// `true`, falls für `(entitaetsArt, peerGeraeteID, fremdeID)` bereits ein
    /// Kandidat vorliegt — verhindert, dass derselbe zurückgestellte
    /// Remote-Eintrag bei jedem weiteren Sync-Zyklus erneut angelegt wird,
    /// solange der Nutzer noch nicht entschieden hat.
    static func existiertBereits(entitaetsArt: String, peerGeraeteID: String, fremdeID: UUID, context: ModelContext) -> Bool {
        var deskriptor = FetchDescriptor<SyncAbgleichKandidat>(
            predicate: #Predicate { $0.entitaetsArt == entitaetsArt && $0.peerGeraeteID == peerGeraeteID && $0.fremdeID == fremdeID }
        )
        deskriptor.fetchLimit = 1
        return ((try? context.fetch(deskriptor).first) ?? nil) != nil
    }
}
