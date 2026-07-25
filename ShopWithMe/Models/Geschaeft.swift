import Foundation
import SwiftData

/// Typische Geschäftskategorien, die die Standardauswahl beim Anlegen eines
/// ``Geschaeft``s vorschlägt.
enum GeschaeftTyp: String, Codable, CaseIterable, Identifiable {
    case lebensmittel
    case drogerie
    case baumarkt
    case apotheke
    case elektronik
    case bekleidung
    case getraenkemarkt
    case tierbedarf
    case buchUndSchreibwaren
    case sonstiges

    var id: String { rawValue }

    /// Anzeigename in der Benutzeroberfläche.
    var anzeigename: String {
        switch self {
        case .lebensmittel: return "Lebensmittel"
        case .drogerie: return "Drogerie"
        case .baumarkt: return "Baumarkt"
        case .apotheke: return "Apotheke"
        case .elektronik: return "Elektronik"
        case .bekleidung: return "Bekleidung"
        case .getraenkemarkt: return "Getränkemarkt"
        case .tierbedarf: return "Tierbedarf"
        case .buchUndSchreibwaren: return "Bücher & Schreibwaren"
        case .sonstiges: return "Sonstiges"
        }
    }

    /// Standard-SF-Symbol für diesen Geschäftstyp.
    var symbolName: String {
        switch self {
        case .lebensmittel: return "cart.fill"
        case .drogerie: return "sparkles"
        case .baumarkt: return "hammer.fill"
        case .apotheke: return "cross.case.fill"
        case .elektronik: return "bolt.fill"
        case .bekleidung: return "tshirt.fill"
        case .getraenkemarkt: return "waterbottle.fill"
        case .tierbedarf: return "pawprint.fill"
        case .buchUndSchreibwaren: return "book.fill"
        case .sonstiges: return "shippingbox.fill"
        }
    }
}

/// Legt fest, ob die Regal-Reihenfolge eines ``Geschaeft``s manuell (``Regal/sortIndex``)
/// oder automatisch anhand der gelernten Einkaufs-Reihenfolge
/// (``ShelfOrderLearningService``) bestimmt wird.
///
/// Der Wechsel zwischen beiden Modi verändert ``Regal/sortIndex`` nicht — die
/// automatische Reihenfolge ist eine Alternative zur manuellen, keine Überschreibung.
enum RegalSortierModus: String, Codable, CaseIterable, Identifiable {
    case manuell
    case automatisch

    var id: String { rawValue }

    var anzeigename: String {
        switch self {
        case .manuell: return "Manuell"
        case .automatisch: return "Automatisch"
        }
    }
}

/// Ein Geschäft, das der Anwender zum Einkaufen aufsucht.
///
/// Kategorien sind wichtiger als Regale: Ein Geschäft kann ``ArtikelKategorie``n
/// direkt zugeordnet bekommen (``kategorien``), ganz ohne ein Regal anzulegen. Regale
/// sind rein optional und dienen ausschließlich dazu, die bereits verfügbaren
/// Kategorien für die Reihenfolge beim Einkaufen in Gruppen zu organisieren — siehe
/// ``verfuegbareKategorien``, die Vereinigung aus beiden Wegen.
@Model
final class Geschaeft {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename des Geschäfts, z.B. "Rewe am Markt".
    var name: String
    /// Geschäftstyp (Lebensmittel, Drogerie, …) — seit Einführung von ``typen``
    /// (Mehrfachauswahl) nicht mehr direkt von außen gesetzt, bleibt aber als
    /// Migrations-Fallback für vor diesem Zeitpunkt angelegte Geschäfte sowie als
    /// führender (erster) Typ erhalten — von ``typen`` synchron gehalten.
    var typ: GeschaeftTyp
    /// Rohwert für ``typen``. Optional gespeichert, damit vor Einführung der
    /// Mehrfachauswahl angelegte Geschäfte (deren Datensatz diese Spalte noch nicht
    /// kennt) beim automatischen Laden nicht abstürzen — ein `nil`/leerer Rohwert
    /// fällt auf `[typ]` zurück.
    private var typenRaw: [String]?
    /// Geschäftstypen (Lebensmittel, Drogerie, …) — ein Geschäft kann mehrere
    /// gleichzeitig haben (z.B. Drogerie + Lebensmittel). Der erste Wert gilt als
    /// führender Typ und bleibt zusätzlich in ``typ`` gespiegelt (Icon-Anzeige,
    /// Migrations-Fallback).
    var typen: [GeschaeftTyp] {
        get {
            guard let typenRaw, !typenRaw.isEmpty else { return [typ] }
            let ergebnis = typenRaw.compactMap(GeschaeftTyp.init(rawValue:))
            return ergebnis.isEmpty ? [typ] : ergebnis
        }
        set {
            typenRaw = newValue.map(\.rawValue)
            typ = newValue.first ?? .sonstiges
        }
    }
    /// Optionale Adresse.
    var adresse: String?
    /// Breitengrad — für die zukünftige, standortbasierte Ladenerkennung vorbereitet,
    /// aktuell ungenutzt.
    var breitengrad: Double?
    /// Längengrad — für die zukünftige, standortbasierte Ladenerkennung vorbereitet,
    /// aktuell ungenutzt.
    var laengengrad: Double?
    /// Rohwert für ``regalSortierModus``. Optional gespeichert, damit vor v1.4
    /// angelegte Geschäfte (deren Datensatz diese Spalte noch nicht kennt) beim
    /// automatischen Laden nicht abstürzen — ein `nil`-Rohwert wird als `.manuell`
    /// interpretiert.
    private var regalSortierModusRaw: String?
    /// Ob die Regal-Reihenfolge manuell oder automatisch (``ShelfOrderLearningService``)
    /// bestimmt wird.
    var regalSortierModus: RegalSortierModus {
        get { regalSortierModusRaw.flatMap(RegalSortierModus.init(rawValue:)) ?? .manuell }
        set { regalSortierModusRaw = newValue.rawValue }
    }
    /// Regale dieses Geschäfts. Wird ein Geschäft gelöscht, werden auch seine Regale
    /// gelöscht.
    @Relationship(deleteRule: .cascade, inverse: \Regal.geschaeft)
    var regale: [Regal] = []
    /// Artikelkategorien, die diesem Geschäft direkt zugeordnet sind — unabhängig
    /// davon, ob sie zusätzlich einem ``Regal`` zugeordnet sind. Das ist der primäre
    /// Weg, eine Kategorie in einem Geschäft verfügbar zu machen; ein Regal ist dafür
    /// nicht erforderlich (siehe ``verfuegbareKategorien``).
    @Relationship(inverse: \ArtikelKategorie.geschaefte)
    var kategorien: [ArtikelKategorie] = []
    /// Preishistorie (``KaufEintrag``), die in diesem Geschäft erfasst wurde. Wird das
    /// Geschäft gelöscht, wird auch seine gesamte Preishistorie gelöscht — siehe
    /// `docs/GESCHAEFTSERKENNUNG.md`.
    @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.geschaeft)
    var kaufEintraege: [KaufEintrag] = []
    /// Beim Belegscan dauerhaft ignorierte Artikelnamen für dieses Geschäft (siehe
    /// ``IgnorierterArtikel``). Wird das Geschäft gelöscht, verschwinden auch seine
    /// Ignorier-Einträge.
    @Relationship(deleteRule: .cascade, inverse: \IgnorierterArtikel.geschaeft)
    var ignorierteArtikel: [IgnorierterArtikel] = []
    /// Rohwert für ``alternativeNamen`` — durch `\n` getrennt gespeichert. Optional,
    /// damit vor Einführung dieses Attributs angelegte Geschäfte beim automatischen
    /// Laden nicht abstürzen (siehe `docs/BELEGSCAN.md`).
    private var alternativeNamenRaw: String?
    /// Zusätzliche Namen, unter denen dieses Geschäft auf einem Kassenbon erkannt
    /// werden kann (z.B. Kurzform oder Filial-Zusatz wie „REWE Center Musterstadt“
    /// für „Rewe“) — gelernt beim automatischen Geschäfts-Abgleich in
    /// ``BelegScanView``, siehe ``alternativenNamenLernen(_:)`` und
    /// `docs/BELEGSCAN.md`.
    var alternativeNamen: [String] {
        get { (alternativeNamenRaw ?? "").split(separator: "\n").map(String.init) }
        set { alternativeNamenRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }

    init(name: String, typen: [GeschaeftTyp], adresse: String? = nil) {
        self.id = UUID()
        self.name = name
        self.typ = typen.first ?? .sonstiges
        self.typenRaw = typen.map(\.rawValue)
        self.adresse = adresse
    }

    /// Merkt sich `name` als zusätzlichen ``alternativeNamen``-Eintrag dieses
    /// Geschäfts, falls er weder dem eigentlichen ``name`` noch einem bereits
    /// bekannten Alias entspricht (kein Duplikat). Grundlage für das automatische
    /// Wiedererkennen desselben Geschäfts bei künftigen Scans — siehe
    /// ``passendes(fuerErkannterName:unter:)``.
    func alternativenNamenLernen(_ name: String) {
        let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !getrimmt.isEmpty,
              getrimmt.localizedCaseInsensitiveCompare(self.name) != .orderedSame,
              !alternativeNamen.contains(where: { $0.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame })
        else { return }
        alternativeNamen.append(getrimmt)
    }

    /// Sucht unter `geschaefte` dasjenige, dessen ``name`` oder ``alternativeNamen``
    /// zum per KI erkannten `erkannterName` eines Kassenbons passt (beidseitiger
    /// `localizedCaseInsensitiveContains`-Abgleich, analog
    /// ``KaufEintrag/gelernteZuordnung(fuerErkannterName:in:)``). `nil`, falls
    /// `erkannterName` leer ist oder kein Treffer existiert — dann fragt die
    /// aufrufende Scan-Ansicht über `GeschaeftWahlSheet` nach.
    ///
    /// Gibt es zum Namen **mehrere** Kandidaten (z.B. zwei Filialen derselben
    /// Kette), wird die ebenfalls vom Kassenbon erkannte `erkannteAdresse` als
    /// automatischer Tie-Breaker genutzt (beidseitiger Teilstring-Abgleich gegen
    /// ``adresse``) — bewusst ohne Rückfrage. Bleibt danach mehr als ein oder gar
    /// kein Kandidat übrig (keine/nicht passende Adresse erkannt), fällt die
    /// Funktion auf den ersten Namens-Kandidaten zurück (unverändertes
    /// Vorher-Verhalten), statt den Anwender zu unterbrechen.
    static func passendes(
        fuerErkannterName erkannterName: String,
        erkannteAdresse: String = "",
        unter geschaefte: [Geschaeft]
    ) -> Geschaeft? {
        let erkannterName = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !erkannterName.isEmpty else { return nil }
        func nameTrifftZu(_ bekannterName: String) -> Bool {
            guard !bekannterName.isEmpty else { return false }
            return bekannterName.localizedCaseInsensitiveContains(erkannterName)
                || erkannterName.localizedCaseInsensitiveContains(bekannterName)
        }
        let kandidaten = geschaefte.filter { nameTrifftZu($0.name) || $0.alternativeNamen.contains(where: nameTrifftZu) }
        guard kandidaten.count > 1 else { return kandidaten.first }

        let getrimmteAdresse = erkannteAdresse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !getrimmteAdresse.isEmpty else { return kandidaten.first }
        let anhandAdresse = kandidaten.filter { kandidat in
            guard let adresse = kandidat.adresse, !adresse.isEmpty else { return false }
            return adresse.localizedCaseInsensitiveContains(getrimmteAdresse)
                || getrimmteAdresse.localizedCaseInsensitiveContains(adresse)
        }
        return anhandAdresse.count == 1 ? anhandAdresse.first : kandidaten.first
    }

    /// Kurzform von ``adresse`` (Straße + Ort, ohne Postleitzahl) — z.B. „Marktstraße
    /// 1, Musterstadt“ aus „Marktstraße 1, 12345 Musterstadt“. Dient zur
    /// Unterscheidung namensgleicher Geschäfte in `GeschaeftWahlSheet`/
    /// `GeschaeftListView` (siehe ``namenMitDuplikaten(unter:)``). `nil` ohne
    /// hinterlegte ``adresse``; enthält die Adresse kein Komma, wird sie
    /// unverändert zurückgegeben (kein erkennbares Straße/Ort-Format).
    var kurzeAdresse: String? {
        guard let adresse, !adresse.isEmpty else { return nil }
        let teile = adresse.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard teile.count == 2 else { return adresse }
        let ort = teile[1].replacingOccurrences(of: #"^\d{4,5}\s*"#, with: "", options: .regularExpression)
        return "\(teile[0]), \(ort)"
    }

    /// Liefert die (kleingeschriebenen) Namen aller Geschäfte, die mehrfach unter
    /// `geschaefte` vorkommen — Grundlage dafür, ob ``kurzeAdresse`` zur
    /// Unterscheidung angezeigt werden soll. `GeschaeftWahlSheet`/`GeschaeftListView`
    /// nutzen diese eine gemeinsame Funktion statt eigener Duplikat-Erkennung.
    static func namenMitDuplikaten(unter geschaefte: [Geschaeft]) -> Set<String> {
        let namenLower = geschaefte.map { $0.name.lowercased() }
        let anzahl = Dictionary(namenLower.map { ($0, 1) }, uniquingKeysWith: +)
        return Set(anzahl.filter { $0.value > 1 }.keys)
    }

    /// Alle Artikelkategorien, die in diesem Geschäft verfügbar sind.
    ///
    /// Leitet sich aus der Vereinigung zweier Wege ab: direkt diesem Geschäft
    /// zugeordnete Kategorien (``kategorien``) sowie Kategorien, die einem seiner
    /// Regale zugeordnet sind (dedupliziert, sortiert nach
    /// ``ArtikelKategorie/sortIndex``). Beim Einkaufen werden für dieses Geschäft nur
    /// diese Kategorien angezeigt.
    var verfuegbareKategorien: [ArtikelKategorie] {
        var gesehen = Set<PersistentIdentifier>()
        return (kategorien + regale.flatMap(\.kategorien))
            .filter { gesehen.insert($0.persistentModelID).inserted }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Das Regal dieses Geschäfts, dem die übergebene Kategorie zugeordnet ist —
    /// `nil`, wenn die Kategorie keinem Regal zugeordnet ist. Das bedeutet nicht
    /// zwangsläufig, dass sie nicht verfügbar ist: sie kann stattdessen direkt über
    /// ``kategorien`` verfügbar sein.
    func regal(fuer kategorie: ArtikelKategorie) -> Regal? {
        regale.first { $0.kategorien.contains(kategorie) }
    }
}
