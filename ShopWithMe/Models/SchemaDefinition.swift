import SwiftData

/// Version 2 des SwiftData-Schemas — fügt ``Produkt``/``Produktname`` hinzu
/// und erweitert ``Artikel``/``Preispunkt``/``EinkaufslistenEintrag`` um die
/// dafür nötigen Relationships (GitHub #47, Schritt 1/5, v0.13). Referenziert
/// die aktuellen, lebenden Modell-Typen aus `Models/*.swift` — im Unterschied
/// zu ``SchemaV1`` (`SchemaV1Frozen.swift`), das den eingefrorenen Vorzustand
/// verschachtelt nachbildet. Siehe `docs/ARTIKEL_PRODUKT_MODELL.md`.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

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

/// Migrationsplan für das SwiftData-Schema — erste echte strukturelle
/// Migration dieses Projekts (``SchemaV1`` → ``SchemaV2``, siehe
/// `docs/ARTIKEL_PRODUKT_MODELL.md`). Frühere Änderungen waren additiv-optional
/// und brauchten keine ``MigrationStage`` (siehe `docs/DECISIONS.md`).
enum ShopWithMeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [migrateV1toV2] }

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
}

/// Zentrale Definition des SwiftData-Schemas, damit an allen Stellen, die einen
/// `ModelContainer`/`ModelConfiguration` aufbauen, dieselbe Modell-Liste sowie
/// derselbe Migrationsplan verwendet werden.
enum SchemaDefinition {
    static let schema = Schema(versionedSchema: SchemaV2.self)
    static let migrationPlan = ShopWithMeMigrationPlan.self
}
