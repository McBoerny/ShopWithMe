import Foundation
import SwiftData

/// Eingefrorene Kopie des Datenmodell-Stands vor der Produkt/Produktname-
/// Erweiterung (GitHub #47, Schritt 1/5, v0.13) — repräsentiert exakt das
/// Schema, das auf bereits installierten Geräten bis zu diesem Zeitpunkt
/// persistiert wurde.
///
/// **Nur Speicherform, keine Fachlogik:** enthält bewusst nur gespeicherte
/// Attribute/Relationships + einen einfachen Memberwise-Init je Typ — keine
/// Computed Properties, Methoden oder Erweiterungen (die sind für den
/// SwiftData-Schema-Fingerabdruck irrelevant und würden hier nur veraltete
/// Logik duplizieren). Die maßgebliche, dokumentierte Fachlogik bleibt
/// ausschließlich in den aktuellen `Models/*.swift`-Dateien.
///
/// **Nie mehr ändern:** Sobald `SchemaV2` (siehe `SchemaDefinition.swift`)
/// existiert, ist dieser Stand endgültig eingefroren — jede künftige
/// strukturelle Änderung bekommt ihre eigene, neue `SchemaVN`-Kopie, nie eine
/// Änderung hier. Siehe `docs/DECISIONS.md` ("Duplicate version checksums"-
/// Vorfall) für die Begründung, warum zwei Schema-Versionen niemals denselben
/// lebenden Modell-Typ referenzieren dürfen.
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
        ]
    }

    @Model
    final class Artikel {
        @Attribute(.unique) var id: UUID
        var name: String
        var symbolName: String
        var farbeHex: String
        var kategorie: ArtikelKategorie?
        @Relationship(inverse: \ArtikelKategorie.zugeordneteArtikel)
        var kategorienRaw: [ArtikelKategorie] = []
        var erstelltAm: Date
        var notiz: String?
        @Relationship(deleteRule: .cascade, inverse: \EinkaufslistenEintrag.artikel)
        var einkaufslistenEintraege: [EinkaufslistenEintrag] = []
        @Relationship(deleteRule: .nullify, inverse: \KaufEintrag.artikel)
        var kaufEintraege: [KaufEintrag] = []
        @Relationship(deleteRule: .nullify, inverse: \Preispunkt.artikel)
        var preispunkte: [Preispunkt] = []
        var einheitRaw: String?
        var mengenSchrittRaw: Double?

        init(
            id: UUID, name: String, symbolName: String, farbeHex: String, kategorie: ArtikelKategorie?,
            erstelltAm: Date, notiz: String?, einheitRaw: String?, mengenSchrittRaw: Double?
        ) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.farbeHex = farbeHex
            self.kategorie = kategorie
            self.erstelltAm = erstelltAm
            self.notiz = notiz
            self.einheitRaw = einheitRaw
            self.mengenSchrittRaw = mengenSchrittRaw
        }
    }

    @Model
    final class ArtikelKategorie {
        var id: UUID
        var name: String
        var standardSymbol: String
        var standardFarbeHex: String
        var sortIndex: Int
        @Relationship(deleteRule: .nullify, inverse: \Artikel.kategorie)
        var artikel: [Artikel] = []
        var zugeordneteArtikel: [Artikel] = []
        var geschaefte: [Geschaeft] = []
        @Relationship(inverse: \Geschaeft.ausgeschlosseneKategorien)
        var geschaefteMitAusschluss: [Geschaeft] = []
        @Relationship(deleteRule: .nullify, inverse: \KaufEintrag.kategorie)
        var kaufEintraege: [KaufEintrag] = []
        @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.kategorieA)
        var distanzenAlsKategorieA: [WarengruppenDistanz] = []
        @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.kategorieB)
        var distanzenAlsKategorieB: [WarengruppenDistanz] = []
        var geschaeftsTypenRaw: [String]?
        @Relationship(inverse: \GeschaeftTyp.standardKategorien)
        var geschaeftsTypModelle: [GeschaeftTyp] = []

        init(id: UUID, name: String, standardSymbol: String, standardFarbeHex: String, sortIndex: Int, geschaeftsTypenRaw: [String]?) {
            self.id = id
            self.name = name
            self.standardSymbol = standardSymbol
            self.standardFarbeHex = standardFarbeHex
            self.sortIndex = sortIndex
            self.geschaeftsTypenRaw = geschaeftsTypenRaw
        }
    }

    @Model
    final class Geschaeft {
        @Attribute(.unique) var id: UUID
        var name: String
        var typenRaw: [String]?
        @Relationship(inverse: \GeschaeftTyp.geschaefte)
        var typenModelle: [GeschaeftTyp] = []
        var adresse: String?
        var breitengrad: Double?
        var laengengrad: Double?
        var erkennungsradiusRaw: Double?
        @Relationship(inverse: \ArtikelKategorie.geschaefte)
        var kategorien: [ArtikelKategorie] = []
        var ausgeschlosseneKategorien: [ArtikelKategorie] = []
        @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.geschaeft)
        var kaufEintraege: [KaufEintrag] = []
        @Relationship(deleteRule: .cascade, inverse: \Preispunkt.geschaeft)
        var preispunkte: [Preispunkt] = []
        @Relationship(deleteRule: .cascade, inverse: \IgnorierterArtikel.geschaeft)
        var ignorierteArtikel: [IgnorierterArtikel] = []
        @Relationship(deleteRule: .nullify, inverse: \Einkaufsvorgang.geschaeft)
        var einkaufsvorgaenge: [Einkaufsvorgang] = []
        @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.geschaeft)
        var warengruppenDistanzen: [WarengruppenDistanz] = []
        var alternativeNamenRaw: String?
        var anzahlEinkaufsvorgaengeRaw: Int?
        var umbauVerdachtRaw: Bool?
        var unauffaelligeEinkaeufeInFolgeRaw: Int?

        init(
            id: UUID, name: String, typenRaw: [String]?, adresse: String?, breitengrad: Double?, laengengrad: Double?,
            erkennungsradiusRaw: Double?, alternativeNamenRaw: String?, anzahlEinkaufsvorgaengeRaw: Int?,
            umbauVerdachtRaw: Bool?, unauffaelligeEinkaeufeInFolgeRaw: Int?
        ) {
            self.id = id
            self.name = name
            self.typenRaw = typenRaw
            self.adresse = adresse
            self.breitengrad = breitengrad
            self.laengengrad = laengengrad
            self.erkennungsradiusRaw = erkennungsradiusRaw
            self.alternativeNamenRaw = alternativeNamenRaw
            self.anzahlEinkaufsvorgaengeRaw = anzahlEinkaufsvorgaengeRaw
            self.umbauVerdachtRaw = umbauVerdachtRaw
            self.unauffaelligeEinkaeufeInFolgeRaw = unauffaelligeEinkaeufeInFolgeRaw
        }
    }

    @Model
    final class GeschaeftTyp {
        var id: UUID
        var name: String
        var symbolName: String
        var sortIndex: Int
        var geschaefte: [Geschaeft] = []
        var standardKategorien: [ArtikelKategorie] = []
        var farbeHexRaw: String?

        init(id: UUID, name: String, symbolName: String, sortIndex: Int, farbeHexRaw: String?) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.sortIndex = sortIndex
            self.farbeHexRaw = farbeHexRaw
        }
    }

    @Model
    final class Einkaufsvorgang {
        @Attribute(.unique) var id: UUID
        var geschaeft: Geschaeft?
        var einkaufsliste: Einkaufsliste?
        var startZeit: Date
        var endZeit: Date?
        @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.einkaufsvorgang)
        var kaufEintraege: [KaufEintrag] = []

        init(id: UUID, geschaeft: Geschaeft?, einkaufsliste: Einkaufsliste?, startZeit: Date, endZeit: Date?) {
            self.id = id
            self.geschaeft = geschaeft
            self.einkaufsliste = einkaufsliste
            self.startZeit = startZeit
            self.endZeit = endZeit
        }
    }

    @Model
    final class KaufEintrag {
        @Attribute(.unique) var id: UUID
        var artikel: Artikel?
        var einkaufsvorgang: Einkaufsvorgang?
        var geschaeft: Geschaeft?
        var kategorie: ArtikelKategorie?
        var artikelNameSnapshot: String
        var geschaeftNameSnapshot: String
        var produktName: String?
        var alternativerName: String?
        var datum: Date
        var preis: Decimal?
        var menge: Double
        var kategorieBesuchsIndex: Int?
        var ursprungsGeraeteID: String?

        init(
            id: UUID, artikel: Artikel?, einkaufsvorgang: Einkaufsvorgang?, geschaeft: Geschaeft?, kategorie: ArtikelKategorie?,
            artikelNameSnapshot: String, geschaeftNameSnapshot: String, produktName: String?, alternativerName: String?,
            datum: Date, preis: Decimal?, menge: Double, kategorieBesuchsIndex: Int?, ursprungsGeraeteID: String?
        ) {
            self.id = id
            self.artikel = artikel
            self.einkaufsvorgang = einkaufsvorgang
            self.geschaeft = geschaeft
            self.kategorie = kategorie
            self.artikelNameSnapshot = artikelNameSnapshot
            self.geschaeftNameSnapshot = geschaeftNameSnapshot
            self.produktName = produktName
            self.alternativerName = alternativerName
            self.datum = datum
            self.preis = preis
            self.menge = menge
            self.kategorieBesuchsIndex = kategorieBesuchsIndex
            self.ursprungsGeraeteID = ursprungsGeraeteID
        }
    }

    @Model
    final class WarengruppenDistanz {
        var id: UUID
        var geschaeft: Geschaeft?
        var kategorieA: ArtikelKategorie?
        var kategorieB: ArtikelKategorie?
        var distanz: Double
        var beobachtungsAnzahlRaw: Int?

        init(id: UUID, geschaeft: Geschaeft?, kategorieA: ArtikelKategorie?, kategorieB: ArtikelKategorie?, distanz: Double, beobachtungsAnzahlRaw: Int?) {
            self.id = id
            self.geschaeft = geschaeft
            self.kategorieA = kategorieA
            self.kategorieB = kategorieB
            self.distanz = distanz
            self.beobachtungsAnzahlRaw = beobachtungsAnzahlRaw
        }
    }

    @Model
    final class Preispunkt {
        var id: UUID
        var artikel: Artikel?
        var geschaeft: Geschaeft?
        var preis: Decimal
        var datum: Date
        var produktName: String?
        var alternativerName: String?
        var artikelNameSnapshot: String
        var geschaeftNameSnapshot: String

        init(
            id: UUID, artikel: Artikel?, geschaeft: Geschaeft?, preis: Decimal, datum: Date,
            produktName: String?, alternativerName: String?, artikelNameSnapshot: String, geschaeftNameSnapshot: String
        ) {
            self.id = id
            self.artikel = artikel
            self.geschaeft = geschaeft
            self.preis = preis
            self.datum = datum
            self.produktName = produktName
            self.alternativerName = alternativerName
            self.artikelNameSnapshot = artikelNameSnapshot
            self.geschaeftNameSnapshot = geschaeftNameSnapshot
        }
    }

    @Model
    final class ArtikelAlias {
        var id: UUID
        var erkannterName: String
        var alternativerName: String?
        var artikel: Artikel?

        init(id: UUID, erkannterName: String, alternativerName: String?, artikel: Artikel?) {
            self.id = id
            self.erkannterName = erkannterName
            self.alternativerName = alternativerName
            self.artikel = artikel
        }
    }

    @Model
    final class Einkaufsliste {
        @Attribute(.unique) var id: UUID
        var name: String
        var erstelltAm: Date
        @Relationship(deleteRule: .cascade, inverse: \EinkaufslistenEintrag.einkaufsliste)
        var eintraege: [EinkaufslistenEintrag] = []
        @Relationship(deleteRule: .cascade, inverse: \Einkaufsvorgang.einkaufsliste)
        var einkaufsvorgaenge: [Einkaufsvorgang] = []

        init(id: UUID, name: String, erstelltAm: Date) {
            self.id = id
            self.name = name
            self.erstelltAm = erstelltAm
        }
    }

    @Model
    final class EinkaufslistenEintrag {
        var id: UUID
        var einkaufsliste: Einkaufsliste?
        var artikel: Artikel?
        var menge: Double
        var notiz: String?
        var erstelltAm: Date

        init(id: UUID, einkaufsliste: Einkaufsliste?, artikel: Artikel?, menge: Double, notiz: String?, erstelltAm: Date) {
            self.id = id
            self.einkaufsliste = einkaufsliste
            self.artikel = artikel
            self.menge = menge
            self.notiz = notiz
            self.erstelltAm = erstelltAm
        }
    }

    @Model
    final class IgnorierterGeschaeftsVorschlag {
        var name: String
        var breitengrad: Double?
        var laengengrad: Double?
        var ignoriertAm: Date

        init(name: String, breitengrad: Double?, laengengrad: Double?, ignoriertAm: Date) {
            self.name = name
            self.breitengrad = breitengrad
            self.laengengrad = laengengrad
            self.ignoriertAm = ignoriertAm
        }
    }

    @Model
    final class IgnorierterArtikel {
        var erkannterName: String
        var geschaeft: Geschaeft?
        var ignoriertAm: Date

        init(erkannterName: String, geschaeft: Geschaeft?, ignoriertAm: Date) {
            self.erkannterName = erkannterName
            self.geschaeft = geschaeft
            self.ignoriertAm = ignoriertAm
        }
    }

    @Model
    final class SyncEvent {
        var id: UUID
        var artRaw: String
        var nutzlast: Data
        var lamportZaehler: UInt64
        var lamportGeraeteID: String
        var autorGeraeteID: String
        var wallClock: Date
        var hochgeladen: Bool

        init(
            id: UUID, artRaw: String, nutzlast: Data, lamportZaehler: UInt64, lamportGeraeteID: String,
            autorGeraeteID: String, wallClock: Date, hochgeladen: Bool
        ) {
            self.id = id
            self.artRaw = artRaw
            self.nutzlast = nutzlast
            self.lamportZaehler = lamportZaehler
            self.lamportGeraeteID = lamportGeraeteID
            self.autorGeraeteID = autorGeraeteID
            self.wallClock = wallClock
            self.hochgeladen = hochgeladen
        }
    }

    @Model
    final class SyncEntitaetsAlias {
        var id: UUID
        var entitaetsArt: String
        var fremdeID: UUID
        var lokaleID: UUID

        init(id: UUID, entitaetsArt: String, fremdeID: UUID, lokaleID: UUID) {
            self.id = id
            self.entitaetsArt = entitaetsArt
            self.fremdeID = fremdeID
            self.lokaleID = lokaleID
        }
    }

    @Model
    final class SyncPeerZaehlerStand {
        var id: UUID
        var peerGeraeteID: String
        var geschaeftID: UUID
        var zuletztGesehenerWert: Int

        init(id: UUID, peerGeraeteID: String, geschaeftID: UUID, zuletztGesehenerWert: Int) {
            self.id = id
            self.peerGeraeteID = peerGeraeteID
            self.geschaeftID = geschaeftID
            self.zuletztGesehenerWert = zuletztGesehenerWert
        }
    }

    @Model
    final class SyncPeerInfo {
        var id: UUID
        var peerGeraeteID: String
        var geraeteName: String
        var zuletztGesehenRaw: Date?

        init(id: UUID, peerGeraeteID: String, geraeteName: String, zuletztGesehenRaw: Date?) {
            self.id = id
            self.peerGeraeteID = peerGeraeteID
            self.geraeteName = geraeteName
            self.zuletztGesehenRaw = zuletztGesehenRaw
        }
    }

    @Model
    final class SyncTombstone {
        var id: UUID
        var entitaetsArt: String
        var geloeschteID: UUID
        var geloeschtAm: Date

        init(id: UUID, entitaetsArt: String, geloeschteID: UUID, geloeschtAm: Date) {
            self.id = id
            self.entitaetsArt = entitaetsArt
            self.geloeschteID = geloeschteID
            self.geloeschtAm = geloeschtAm
        }
    }

    @Model
    final class SyncAbgleichKandidat {
        var id: UUID
        var entitaetsArt: String
        var peerGeraeteID: String
        var fremdeID: UUID
        var fremderName: String
        var lokaleID: UUID
        var lokalerName: String
        var erkanntAm: Date

        init(
            id: UUID, entitaetsArt: String, peerGeraeteID: String, fremdeID: UUID, fremderName: String,
            lokaleID: UUID, lokalerName: String, erkanntAm: Date
        ) {
            self.id = id
            self.entitaetsArt = entitaetsArt
            self.peerGeraeteID = peerGeraeteID
            self.fremdeID = fremdeID
            self.fremderName = fremderName
            self.lokaleID = lokaleID
            self.lokalerName = lokalerName
            self.erkanntAm = erkanntAm
        }
    }

    @Model
    final class WarengruppenDistanzPeerZaehlerStand {
        var id: UUID
        var peerGeraeteID: String
        var distanzID: UUID
        var zuletztGesehenerWert: Int

        init(id: UUID, peerGeraeteID: String, distanzID: UUID, zuletztGesehenerWert: Int) {
            self.id = id
            self.peerGeraeteID = peerGeraeteID
            self.distanzID = distanzID
            self.zuletztGesehenerWert = zuletztGesehenerWert
        }
    }

    @Model
    final class ArtikelGeschaeftVerfuegbarkeit {
        var id: UUID
        var artikel: Artikel?
        var geschaeft: Geschaeft?

        init(id: UUID, artikel: Artikel?, geschaeft: Geschaeft?) {
            self.id = id
            self.artikel = artikel
            self.geschaeft = geschaeft
        }
    }

    @Model
    final class GeschaeftBesuch {
        var id: UUID
        var geschaeft: Geschaeft?
        var startZeit: Date
        var endZeit: Date
        var anzahlProdukte: Int

        init(id: UUID, geschaeft: Geschaeft?, startZeit: Date, endZeit: Date, anzahlProdukte: Int) {
            self.id = id
            self.geschaeft = geschaeft
            self.startZeit = startZeit
            self.endZeit = endZeit
            self.anzahlProdukte = anzahlProdukte
        }
    }

    @Model
    final class ArtikelListenKauf {
        var id: UUID
        var artikel: Artikel?
        var einkaufsliste: Einkaufsliste?

        init(id: UUID, artikel: Artikel?, einkaufsliste: Einkaufsliste?) {
            self.id = id
            self.artikel = artikel
            self.einkaufsliste = einkaufsliste
        }
    }
}
