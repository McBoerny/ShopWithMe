import Foundation
import SwiftData

/// Eine Artikelkategorie fasst gleichartige Artikel zusammen, z.B. „Obst & Gemüse“.
///
/// Kategorien sind global und geschäftsunabhängig. Ob eine Kategorie in einem
/// bestimmten Geschäft verfügbar ist, ergibt sich aus zwei unabhängigen Wegen:
/// direkt über ``geschaefte`` (``Geschaeft/kategorien``) oder indirekt darüber, dass
/// sie einem ``Regal`` dieses Geschäfts zugeordnet ist. Regale sind dabei rein
/// optional — sie dienen nur der Sortierung beim Einkaufen, nicht der
/// Verfügbarkeit (siehe `docs/DECISIONS.md`).
@Model
final class ArtikelKategorie {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename der Kategorie, z.B. "Obst & Gemüse".
    var name: String
    /// Standard-SF-Symbol, das neuen ``Artikel``n dieser Kategorie vorgeschlagen wird.
    var standardSymbol: String
    /// Standardfarbe als Hex-String (z.B. `"#34C759"`), die neuen ``Artikel``n dieser
    /// Kategorie vorgeschlagen wird.
    var standardFarbeHex: String
    /// Reihenfolge für die Anzeige in Auswahllisten.
    var sortIndex: Int

    /// Artikel, die dieser Kategorie über das alte, einzelwertige ``Artikel/kategorie``
    /// zugeordnet sind — Migrations-Fallback, seit Einführung der Mehrfachzuordnung
    /// nicht mehr die maßgebliche Quelle (siehe ``zugeordneteArtikel``).
    @Relationship(deleteRule: .nullify, inverse: \Artikel.kategorie)
    var artikel: [Artikel] = []
    /// Artikel, die dieser Kategorie über ``Artikel/kategorien`` (Mehrfachzuordnung)
    /// zugeordnet sind — die maßgebliche Quelle. Inverse wird auf der
    /// ``Artikel/kategorienRaw``-Seite deklariert (analog ``regale``/``geschaefte``
    /// unten, die ebenfalls nur einseitig `inverse:` tragen).
    var zugeordneteArtikel: [Artikel] = []

    /// Regale (über alle Geschäfte hinweg), denen diese Kategorie zugeordnet ist.
    var regale: [Regal] = []

    /// Geschäfte, in denen diese Kategorie direkt (ohne Regal-Zuordnung) verfügbar
    /// ist — siehe ``Geschaeft/kategorien``.
    var geschaefte: [Geschaeft] = []

    /// Rohwert für ``geschaeftsTypen``. Optional gespeichert, damit vor Einführung
    /// dieses Attributs angelegte Kategorien beim automatischen Laden nicht
    /// abstürzen — ein `nil`-Rohwert fällt auf eine leere Liste zurück.
    private var geschaeftsTypenRaw: [String]?
    /// Geschäftstypen (z.B. ``GeschaeftTyp/drogerie``), für die diese Kategorie als
    /// typische Warengruppe gilt — unabhängig von einer tatsächlichen Zuordnung zu
    /// einem konkreten ``Geschaeft`` (siehe ``geschaefte``). Grundlage dafür, dass
    /// ``Geschaeft/verfuegbareKategorien(alleKategorien:)`` diese Kategorie für jedes
    /// Geschäft mit passendem Typ automatisch als verfügbar ansieht (GitHub #5),
    /// ohne sie in ``geschaefte`` zu persistieren.
    var geschaeftsTypen: [GeschaeftTyp] {
        get { (geschaeftsTypenRaw ?? []).compactMap(GeschaeftTyp.init(rawValue:)) }
        set { geschaeftsTypenRaw = newValue.map(\.rawValue) }
    }

    init(name: String, standardSymbol: String, standardFarbeHex: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.standardSymbol = standardSymbol
        self.standardFarbeHex = standardFarbeHex
        self.sortIndex = sortIndex
    }
}

extension ArtikelKategorie {
    /// Name der Kategorie, in die unkategorisierte Artikel automatisch fallen
    /// (siehe ``Artikel/effektiveKategorie(context:)``).
    static let sonstigesName = "Sonstiges"

    /// Findet die "Sonstiges"-Kategorie (wird normalerweise über
    /// ``SeedData`` angelegt) oder legt sie an, falls sie ausnahmsweise noch nicht
    /// existiert.
    static func sonstige(context: ModelContext) -> ArtikelKategorie {
        let name = sonstigesName
        var deskriptor = FetchDescriptor<ArtikelKategorie>(predicate: #Predicate { $0.name == name })
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            return bestehende
        }
        let naechsterIndex = ((try? context.fetch(FetchDescriptor<ArtikelKategorie>()))?.map(\.sortIndex).max() ?? -1) + 1
        let neue = ArtikelKategorie(name: name, standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93", sortIndex: naechsterIndex)
        context.insert(neue)
        return neue
    }
}
