import SwiftData

/// Zentrale Definition des SwiftData-Schemas, damit App-Start und
/// ``DatabaseLocationService`` dieselbe Modell-Liste verwenden.
enum SchemaDefinition {
    static let schema = Schema([
        Artikel.self,
        ArtikelKategorie.self,
        Regal.self,
        Geschaeft.self,
        Einkaufsvorgang.self,
        KaufEintrag.self,
        KategorieBesuchsStatistik.self,
    ])
}
