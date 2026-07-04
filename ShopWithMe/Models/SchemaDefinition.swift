import SwiftData

/// Version 1 des SwiftData-Schemas — der Modellstand ab v1.5 (nach dem Absturz-Fix
/// für ``Geschaeft/regalSortierModus``, siehe `docs/DECISIONS.md`). Jede künftige
/// Datenmodell-Änderung braucht eine neue ``VersionedSchema`` (`SchemaV2`, …) und eine
/// passende ``MigrationStage`` in ``ShopWithMeMigrationPlan`` — siehe dort.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 5, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Artikel.self,
            ArtikelKategorie.self,
            Regal.self,
            Geschaeft.self,
            Einkaufsvorgang.self,
            KaufEintrag.self,
            KategorieBesuchsStatistik.self,
        ]
    }
}

/// Migrationsplan für das SwiftData-Schema.
///
/// **Regel: Sobald sich das Datenmodell ändert** (neues gespeichertes Attribut, neues
/// Modell, geänderter Typ, Umbenennung, …), **muss hier eine neue ``VersionedSchema``
/// samt ``MigrationStage`` ergänzt werden** — auch für scheinbar harmlose additive
/// Änderungen. Grund: SwiftDatas automatische Lightweight-Migration hat sich als
/// nicht zuverlässig erwiesen (siehe v1.4→v1.5-Vorfall in `docs/DECISIONS.md`: ein
/// neues nicht-optionales Attribut auf ``Geschaeft`` crashte beim Zugriff auf bereits
/// bestehende Datensätze, weil die Spalte dort keinen Wert erhielt).
///
/// **Vorgehen bei einer Datenmodell-Änderung:**
/// 1. Neue `SchemaVN` anlegen (`versionIdentifier` hochzählen, i.d.R. auf die neue
///    `MARKETING_VERSION`), mit der vollständigen, neuen Modell-Liste.
/// 2. Eine ``MigrationStage`` von der vorherigen zur neuen Version ergänzen:
///    - `.lightweight(fromVersion:toVersion:)` reicht für rein additive Änderungen
///      (neues optionales Attribut, neues Modell) — SwiftData übernimmt die
///      Spaltenanlage automatisch.
///    - `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` ist Pflicht bei
///      allem, was bestehende Daten transformiert, oder ein neues *nicht-optionales*
///      Attribut ohne sinnvollen technischen Default einführt: im `didMigrate`-Block
///      bestehende Datensätze explizit nachziehen (z.B. Default setzen).
/// 3. `schemas` und `stages` unten um die neue Version/Stage ergänzen.
/// 4. Zusätzlich gilt weiterhin die defensive Regel aus `docs/DECISIONS.md`: neue
///    gespeicherte Attribute auf bestehenden Modellen als optionalen Rohwert
///    speichern und über ein Computed-Property mit sicherem Fallback kapseln (siehe
///    ``Geschaeft/regalSortierModus``) — das fängt auch Fälle ab, die die
///    Migrationsstufe selbst nicht abdeckt.
enum ShopWithMeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Zentrale Definition des SwiftData-Schemas, damit App-Start und
/// ``DatabaseLocationService`` dieselbe Modell-Liste sowie denselben Migrationsplan
/// verwenden.
enum SchemaDefinition {
    static let schema = Schema(versionedSchema: SchemaV1.self)
    static let migrationPlan = ShopWithMeMigrationPlan.self
}
