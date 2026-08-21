import Foundation
import SwiftData

/// Eingefrorener Stand von Schema-Version 3.0.0 vor der Erweiterung von
/// ``Produktname`` um ``Produktname/barcode`` (V3→V4). Nur ``Produktname``
/// als nested class nötig — alle anderen Typen sind zwischen V3 und V4
/// unverändert und referenzieren daher den lebenden Typ.
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

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

    @Model
    final class Produktname {
        @Attribute(.unique) var id: UUID
        var name: String
        var produkt: Produkt?
        var geschaeft: Geschaeft?

        init(id: UUID = UUID(), name: String, produkt: Produkt?, geschaeft: Geschaeft?) {
            self.id = id
            self.name = name
            self.produkt = produkt
            self.geschaeft = geschaeft
        }
    }
}
