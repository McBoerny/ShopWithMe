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
extension Abteilung: IdentifizierbaresModell {}
extension Artikel: IdentifizierbaresModell {}
extension Einkaufsliste: IdentifizierbaresModell {}
extension EinkaufslistenEintrag: IdentifizierbaresModell {}
extension Einkaufsvorgang: IdentifizierbaresModell {}
extension KaufEintrag: IdentifizierbaresModell {}
extension WarengruppenDistanz: IdentifizierbaresModell {}
extension Preispunkt: IdentifizierbaresModell {}
extension Produkt: IdentifizierbaresModell {}
extension Produktname: IdentifizierbaresModell {}

extension ModelContext {
    /// `true`, wenn `objekt` noch tatsächlich im Store existiert — `false` bei
    /// einer bereits baumelnden Referenz auf eine gelöschte Zeile (siehe
    /// `docs/DATABASE_CONCURRENCY.md`). Sicher auch auf einer möglicherweise
    /// baumelnden Referenz aufrufbar, da nur `persistentModelID` verglichen
    /// wird — jede andere Eigenschaft (`.name` etc.) würde in diesem Fall mit
    /// einem SwiftData-Fatal-Error abstürzen.
    func existiertNochImStore<T: PersistentModel>(_ objekt: T) -> Bool {
        let alle = (try? fetch(FetchDescriptor<T>())) ?? []
        return alle.contains { $0.persistentModelID == objekt.persistentModelID }
    }
}
