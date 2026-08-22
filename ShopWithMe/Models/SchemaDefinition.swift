import SwiftData

/// Version 1 des SwiftData-Schemas — frischer Neustart der Schema-Historie
/// (GitHub #128/#129): die App befindet sich noch in der Entwicklungsphase,
/// der lokale Store wurde zurückgesetzt, es existiert kein Altbestand mehr,
/// den eine Migration erhalten müsste. Die gesamte vorherige, mehrstufige
/// `VersionedSchema`-Historie (V1→V4 + die zweiphasige `liveSchema`-
/// Notlösung für additive Felder, siehe `docs/ARTIKEL_PRODUKT_MODELL.md`
/// → „Schritt 6/6") wurde ersatzlos entfernt. Referenziert direkt die
/// aktuellen, lebenden Modell-Typen aus `Models/*.swift`.
///
/// Kein Migrationsplan nötig, solange es keine Vorgängerversion gibt — sobald
/// die erste echte strukturelle Änderung ansteht, entsteht dann `SchemaV2` +
/// ein `SchemaMigrationPlan` nach demselben Muster wie zuvor (siehe
/// `ios-swift-engineering`-Skill, Abschnitt „SwiftData: Migrationsentscheidung
/// additiv vs. strukturell" für die Entscheidung additiv vs. strukturell und
/// die Warnung zu reich vernetzten Hub-Typen wie ``Artikel``/``Produkt``).
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

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

/// Zentrale Definition des SwiftData-Schemas, damit an allen Stellen, die einen
/// `ModelContainer`/`ModelConfiguration` aufbauen, dieselbe Modell-Liste
/// verwendet wird.
enum SchemaDefinition {
    static let schema = Schema(versionedSchema: SchemaV1.self)
}
