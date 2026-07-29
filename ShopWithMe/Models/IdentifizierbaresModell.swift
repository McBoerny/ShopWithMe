import Foundation
import SwiftData

/// Gemeinsames Protokoll für `@Model`-Typen mit einer stabilen `UUID`-`id` —
/// Voraussetzung für die sichere Re-Auflösung über ``ModelReference`` und für
/// die baumelnde-Referenzen-Absicherung in ``SyncSnapshotExportService``
/// (`sichereID`/`sichereIDs`).
protocol IdentifizierbaresModell: PersistentModel {
    var id: UUID { get }
}

extension Geschaeft: IdentifizierbaresModell {}
extension GeschaeftTyp: IdentifizierbaresModell {}
extension ArtikelKategorie: IdentifizierbaresModell {}
extension Artikel: IdentifizierbaresModell {}
extension Einkaufsliste: IdentifizierbaresModell {}
extension EinkaufslistenEintrag: IdentifizierbaresModell {}
extension Einkaufsvorgang: IdentifizierbaresModell {}
extension KaufEintrag: IdentifizierbaresModell {}
extension WarengruppenDistanz: IdentifizierbaresModell {}
