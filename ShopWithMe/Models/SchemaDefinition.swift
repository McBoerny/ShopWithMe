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
    /// Rein SwiftData-interne Versionsnummer dieses Schemas — unabhängig von
    /// der App-Marketing-Version (`MARKETING_VERSION` in `project.yml`,
    /// aktuell z.B. v0.12). Der Wert `(1, 5, 0)` stammt aus der Zeit vor dem
    /// einmaligen Versions-Reset auf v0.1 (siehe `docs/DECISIONS.md`,
    /// Abschnitt „Versionsschema") und wurde beim Reset bewusst nicht
    /// mitgeändert, da er nur innerhalb dieser Datei und für SwiftData selbst
    /// eine Bedeutung hat (GitHub #101).
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
            Preispunkt.self,
            ArtikelAlias.self,
            Einkaufsliste.self,
            EinkaufslistenEintrag.self,
            IgnorierterGeschaeftsVorschlag.self,
            IgnorierterArtikel.self,
            SyncEvent.self,
            SyncEntitaetsAlias.self,
            SyncPeerZaehlerStand.self,
            SyncPeerInfo.self,
            SyncTombstone.self,
            SyncAbgleichKandidat.self,
            WarengruppenDistanzPeerZaehlerStand.self,
            ArtikelGeschaeftVerfuegbarkeit.self,
            GeschaeftBesuch.self,
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

/// Zentrale Definition des SwiftData-Schemas, damit an allen Stellen, die einen
/// `ModelContainer`/`ModelConfiguration` aufbauen, dieselbe Modell-Liste sowie
/// derselbe Migrationsplan verwendet werden.
enum SchemaDefinition {
    static let schema = Schema(versionedSchema: SchemaV1.self)
    static let migrationPlan = ShopWithMeMigrationPlan.self
}
