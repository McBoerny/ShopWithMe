import Foundation
import SwiftData

/// Eine Artikelkategorie fasst gleichartige Artikel zusammen, z.B. „Obst & Gemüse“.
///
/// Kategorien sind global und geschäftsunabhängig. Ob eine Kategorie in einem
/// bestimmten Geschäft verfügbar ist, ergibt sich direkt über ``geschaefte``
/// (``Geschaeft/kategorien``) — siehe `docs/DECISIONS.md`.
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
    /// ``Artikel/kategorienRaw``-Seite deklariert (analog ``geschaefte`` unten, die
    /// ebenfalls nur einseitig `inverse:` trägt).
    var zugeordneteArtikel: [Artikel] = []

    /// Geschäfte, in denen diese Kategorie verfügbar ist — siehe
    /// ``Geschaeft/kategorien``.
    var geschaefte: [Geschaeft] = []
    /// Geschäfte, die diese Kategorie individuell ausgeschlossen haben —
    /// inverse zu ``Geschaeft/ausgeschlosseneKategorien``. Ohne diese
    /// `inverse`-Deklaration bliebe der Ausschluss-Eintrag beim Löschen der
    /// Kategorie eine "baumelnde" Referenz (Absturzrisiko wie bei
    /// ``Geschaeft/einkaufsvorgaenge`` beschrieben) statt automatisch aus dem
    /// Array entfernt zu werden.
    @Relationship(inverse: \Geschaeft.ausgeschlosseneKategorien)
    var geschaefteMitAusschluss: [Geschaeft] = []

    /// Kaufeinträge, deren Kategorie-Schnappschuss auf diese Kategorie
    /// verweist — inverse zu ``KaufEintrag/kategorie``. Nullify: die
    /// Kaufhistorie bleibt bestehen, auch wenn die Kategorie später gelöscht
    /// wird (Absturzrisiko ohne diese `inverse`-Deklaration wie bei
    /// ``Geschaeft/einkaufsvorgaenge`` beschrieben).
    @Relationship(deleteRule: .nullify, inverse: \KaufEintrag.kategorie)
    var kaufEintraege: [KaufEintrag] = []
    /// Gelernte Abteilungs-Distanzen, an denen diese Kategorie als "erste"
    /// Seite beteiligt ist — inverse zu ``WarengruppenDistanz/kategorieA``.
    /// Kaskadierend: ohne die Kategorie ist der Distanz-Eintrag bedeutungslos.
    @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.kategorieA)
    var distanzenAlsKategorieA: [WarengruppenDistanz] = []
    /// Wie ``distanzenAlsKategorieA``, für die "zweite" Seite
    /// (``WarengruppenDistanz/kategorieB``) — zwei getrennte Inverse-Arrays,
    /// da es sich um zwei unabhängige Relationship-Kanten handelt.
    @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.kategorieB)
    var distanzenAlsKategorieB: [WarengruppenDistanz] = []

    /// Rohwert für ``geschaeftsTypen`` von vor Einführung von ``GeschaeftTyp`` als
    /// eigenständigem SwiftData-Modell (GitHub #25) — enum-Rohwerte wie
    /// `"drogerie"`. Bleibt nach der einmaligen Migration
    /// (``geschaeftsTypenMigrierenFallsNoetig(context:)``) unverändert im
    /// Datensatz stehen (tote Altlast). Bewusst nicht `private`, damit Tests „alte“
    /// Datensätze simulieren können.
    var geschaeftsTypenRaw: [String]?
    /// Rohspeicher für ``geschaeftsTypen`` — bewusst `internal` (nicht `private`),
    /// damit ``GeschaeftTyp`` per `inverse:`-KeyPath darauf verweisen kann. Nicht
    /// direkt verwenden, stattdessen ``geschaeftsTypen``.
    @Relationship(inverse: \GeschaeftTyp.standardKategorien)
    var geschaeftsTypModelle: [GeschaeftTyp] = []
    /// Geschäftstypen, für die diese Kategorie als typische Abteilung gilt —
    /// unabhängig von einer tatsächlichen Zuordnung zu einem konkreten
    /// ``Geschaeft`` (siehe ``geschaefte``). Grundlage dafür, dass
    /// ``Geschaeft/verfuegbareKategorien(alleKategorien:)`` diese Kategorie für jedes
    /// Geschäft mit passendem Typ automatisch als verfügbar ansieht (GitHub #5),
    /// ohne sie in ``geschaefte`` zu persistieren.
    var geschaeftsTypen: [GeschaeftTyp] {
        get { geschaeftsTypModelle }
        set { geschaeftsTypModelle = newValue }
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

    /// Migriert vor GitHub #25 angelegte Kategorien (deren ``geschaeftsTypen`` noch
    /// leer ist, aber ``geschaeftsTypenRaw`` alte enum-Rohwerte gespeichert hat)
    /// einmalig auf die entsprechenden ``GeschaeftTyp``-Objekte. Wird beim
    /// App-Start für alle Kategorien aufgerufen (siehe ``SeedData``).
    static func geschaeftsTypenMigrierenFallsNoetig(context: ModelContext) {
        let alle = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        for kategorie in alle {
            guard kategorie.geschaeftsTypen.isEmpty,
                  let rohwerte = kategorie.geschaeftsTypenRaw, !rohwerte.isEmpty else { continue }
            let namen = rohwerte.compactMap(GeschaeftTyp.legacyName(fuerRohwert:))
            guard !namen.isEmpty else { continue }
            kategorie.geschaeftsTypen = namen.map { GeschaeftTyp.mitNamen($0, context: context) }
        }
    }
}
