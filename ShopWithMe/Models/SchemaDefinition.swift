import SwiftData

/// Version 1 des SwiftData-Schemas.
///
/// **Wichtig (siehe `docs/DECISIONS.md`, "Duplicate version checksums"-Vorfall):**
/// Dieses Projekt pflegt Modelle als flache, einzige Klassen (`Models/*.swift`) statt
/// pro Schema-Version verschachtelter/eingefrorener Typen. Eine zusätzliche
/// ``VersionedSchema`` (`SchemaV2`, …), die dieselben lebenden Modell-Typen
/// referenziert, hat deshalb exakt denselben Prüfsummen-Hash wie ``SchemaV1`` — SwiftData
/// crasht dann beim Öffnen eines bestehenden Stores mit
/// `NSInvalidArgumentException: Duplicate version checksums detected`, weil zwei
/// verschiedene deklarierte Versionen auf ein identisches Schema abbilden.
/// **Für rein additive, optionale neue Attribute bleibt es daher bei dieser einzigen
/// ``SchemaV1`` + der defensiven Regel aus `docs/DECISIONS.md`** (neues Attribut
/// optional deklarieren, ggf. über ein Computed-Property mit sicherem Fallback
/// kapseln wie ``Geschaeft/umbauVerdacht``) — SwiftDatas klassische automatische
/// Lightweight-Migration übernimmt die neue Spalte dann anstandslos. Eine echte neue
/// ``VersionedSchema`` samt ``MigrationStage`` ist erst nötig, wenn bestehende Daten
/// tatsächlich transformiert werden müssen (`.custom`) — und setzt dann voraus, dass
/// die betroffenen Modelltypen pro Version tatsächlich eingefroren/verschachtelt
/// werden, statt (wie hier vermieden) dieselbe lebende Klasse mehrfach zu referenzieren.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 5, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Artikel.self,
            ArtikelKategorie.self,
            Geschaeft.self,
            GeschaeftTyp.self,
            Einkaufsvorgang.self,
            KaufEintrag.self,
            WarengruppenDistanz.self,
            Einkaufsliste.self,
            EinkaufslistenEintrag.self,
            IgnorierterGeschaeftsVorschlag.self,
            IgnorierterArtikel.self,
            SyncEvent.self,
        ]
    }
}

/// Migrationsplan für das SwiftData-Schema. Aktuell ohne Stages, da bislang jede
/// Datenmodell-Änderung additiv und optional war (siehe ``SchemaV1`` für die
/// Begründung, warum das bewusst keine zusätzliche ``VersionedSchema`` erzeugt).
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
