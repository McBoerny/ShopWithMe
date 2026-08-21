import SwiftData

/// Version 4 des SwiftData-Schemas — erweitert ``Produktname`` um
/// ``Produktname/barcode`` zur Anzeige bekannter Barcodes je Geschäft in
/// ``ProduktEditView``. Referenziert die aktuellen, lebenden Modell-Typen aus
/// `Models/*.swift` — im Unterschied zu ``SchemaV1`` (`SchemaV1Frozen.swift`),
/// ``SchemaV2`` (`SchemaV2Frozen.swift`) und ``SchemaV3`` (`SchemaV3Frozen.swift`),
/// die eingefrorene Vorzustände verschachtelt nachbilden.
enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

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
            ArtikelListenKauf.self,
            Produkt.self,
            Produktname.self,
        ]
    }
}

/// Migrationsplan für das SwiftData-Schema.
/// - ``SchemaV1`` → ``SchemaV2``: fügt ``Produkt``/``Produktname`` hinzu und
///   verknüpft bestehende ``Preispunkt``/``EinkaufslistenEintrag``-Einträge per
///   Custom-Stage (GitHub #47, v0.13, siehe `docs/ARTIKEL_PRODUKT_MODELL.md`).
/// - ``SchemaV2`` → ``SchemaV3``: fügt ``Geschaeft/markenname`` additiv-optional
///   hinzu (v0.16) — Lightweight-Migration, keine Datentransformation nötig.
/// - ``SchemaV3`` → ``SchemaV4``: fügt ``Produktname/barcode`` additiv-optional
///   hinzu — Lightweight-Migration, keine Datentransformation nötig.
enum ShopWithMeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self] }
    static var stages: [MigrationStage] { [migrateV1toV2, migrateV2toV3, migrateV3toV4] }

    /// Verknüpft jeden ``Preispunkt``/``EinkaufslistenEintrag`` mit bereits
    /// gesetztem ``Artikel``, aber noch ohne ``Produkt`` (zwangsläufig JEDER
    /// bereits bestehende, da ``Produkt`` vor dieser Migration nicht
    /// existierte), mit dem Platzhalter-Produkt seines Artikels — siehe
    /// ``Produkt/standardProdukt(fuer:context:)``. Läuft nach der
    /// automatischen Lightweight-Migration der neuen, additiv-optionalen
    /// Relationships (``Artikel/produkte``, ``Preispunkt/produkt``,
    /// ``EinkaufslistenEintrag/produkt``), bevor die App diese Daten zum
    /// ersten Mal liest.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let preispunkte = (try? context.fetch(FetchDescriptor<Preispunkt>())) ?? []
            for punkt in preispunkte {
                guard punkt.produkt == nil, let artikel = punkt.artikel else { continue }
                punkt.produkt = Produkt.standardProdukt(fuer: artikel, context: context)
            }
            let eintraege = (try? context.fetch(FetchDescriptor<EinkaufslistenEintrag>())) ?? []
            for eintrag in eintraege {
                guard eintrag.produkt == nil, let artikel = eintrag.artikel else { continue }
                eintrag.produkt = Produkt.standardProdukt(fuer: artikel, context: context)
            }
            try? context.save()
        }
    )

    /// Lightweight-Migration: fügt ``Geschaeft/markenname`` als optionale Spalte
    /// hinzu — bestehende Datensätze erhalten automatisch `nil`.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self
    )

    /// Lightweight-Migration: fügt ``Produktname/barcode`` als optionale Spalte
    /// hinzu — bestehende Datensätze erhalten automatisch `nil`.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self
    )
}

/// Zentrale Definition des SwiftData-Schemas, damit an allen Stellen, die einen
/// `ModelContainer`/`ModelConfiguration` aufbauen, dieselbe Modell-Liste sowie
/// derselbe Migrationsplan verwendet werden.
enum SchemaDefinition {
    static let schema = Schema(versionedSchema: SchemaV4.self)
    static let migrationPlan = ShopWithMeMigrationPlan.self
}
