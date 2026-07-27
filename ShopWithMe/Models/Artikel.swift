import Foundation
import SwiftData

/// Maßeinheit, in der ``EinkaufslistenEintrag/menge``/``Artikel/mengenSchritt``
/// geführt werden — Gewicht, Volumen oder Stück.
enum Einheit: String, Codable, CaseIterable, Identifiable {
    case stueck
    case kilogramm
    case gramm
    case liter
    case milliliter

    var id: String { rawValue }

    /// Anzeigename in Auswahllisten (z.B. Picker in ``ArtikelEditView``).
    var anzeigename: String {
        switch self {
        case .stueck: return "Stück"
        case .kilogramm: return "Kilogramm"
        case .gramm: return "Gramm"
        case .liter: return "Liter"
        case .milliliter: return "Milliliter"
        }
    }

    /// Kompakte Kurzform für die Anzeige in der Einkaufsliste (z.B. "2 kg").
    var kurzform: String {
        switch self {
        case .stueck: return "Stk."
        case .kilogramm: return "kg"
        case .gramm: return "g"
        case .liter: return "l"
        case .milliliter: return "ml"
        }
    }
}

/// Ein einkaufbarer Artikel (z.B. "Vollmilch").
///
/// Ein Artikel kann mehreren ``ArtikelKategorie``n gleichzeitig angehören (siehe
/// ``kategorien``) — die Kategorien können jederzeit über die
/// Bearbeiten-Bildschirme geändert werden.
@Model
final class Artikel {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename des Artikels.
    var name: String
    /// SF-Symbol-Name — aktuell in keiner UI mehr angezeigt/editierbar, bleibt als
    /// Feld für eine mögliche künftige Wiederverwendung erhalten.
    var symbolName: String
    /// Farbe als Hex-String (z.B. `"#34C759"`) — aktuell in keiner UI mehr
    /// angezeigt/editierbar, bleibt als Feld für eine mögliche künftige
    /// Wiederverwendung erhalten.
    var farbeHex: String
    /// Die (einzelne) Kategorie dieses Artikels — seit Einführung von
    /// ``kategorien`` (Mehrfachzuordnung) nicht mehr direkt von außen gesetzt,
    /// bleibt aber als Migrations-Fallback für vor diesem Zeitpunkt angelegte
    /// Artikel sowie als führende (erste) Kategorie erhalten — von ``kategorien``
    /// synchron gehalten.
    var kategorie: ArtikelKategorie?
    /// Rohspeicher für ``kategorien`` — bewusst `internal` (nicht `private`),
    /// damit ``ArtikelKategorie`` per `inverse:`-KeyPath darauf verweisen kann.
    /// Nicht direkt verwenden, stattdessen ``kategorien``.
    @Relationship(inverse: \ArtikelKategorie.zugeordneteArtikel)
    var kategorienRaw: [ArtikelKategorie] = []
    /// Zeitpunkt der Anlage.
    var erstelltAm: Date
    /// Optionale, dauerhafte Notiz, z.B. bevorzugte Marke.
    var notiz: String?

    /// Die Einkaufslisten-Mitgliedschaften dieses Artikels — je ``Einkaufsliste``,
    /// auf der er aktuell steht, ein Eintrag (siehe ``EinkaufslistenEintrag``). Wird
    /// der Artikel gelöscht, verschwinden auch seine Mitgliedschaften.
    @Relationship(deleteRule: .cascade, inverse: \EinkaufslistenEintrag.artikel)
    var einkaufslistenEintraege: [EinkaufslistenEintrag] = []

    /// Rohwert für ``einheit``. Optional gespeichert, damit vor Einführung dieses
    /// Attributs angelegte Artikel beim automatischen Laden nicht abstürzen — ein
    /// `nil`-Rohwert wird als ``Einheit/stueck`` interpretiert.
    private var einheitRaw: String?
    /// Maßeinheit, in der ``menge``/``mengenSchritt`` geführt werden.
    var einheit: Einheit {
        get { einheitRaw.flatMap(Einheit.init(rawValue:)) ?? .stueck }
        set { einheitRaw = newValue.rawValue }
    }

    /// Rohwert für ``mengenSchritt``. Optional gespeichert (siehe ``einheitRaw``);
    /// ein `nil`-Rohwert fällt auf `1` zurück.
    private var mengenSchrittRaw: Double?
    /// Vom Nutzer beim Anlegen (und danach jederzeit) festgelegte Standardmenge —
    /// dient als Start- und Schrittwert für ``EinkaufslistenEintrag/menge`` (siehe
    /// ``EinkaufslistenEintrag/mengeErhoehen()``/``EinkaufslistenEintrag/mengeVerringern()``).
    var mengenSchritt: Double {
        get { mengenSchrittRaw ?? 1 }
        set { mengenSchrittRaw = newValue }
    }

    init(
        name: String,
        symbolName: String,
        farbeHex: String,
        kategorien: [ArtikelKategorie] = [],
        notiz: String? = nil,
        einheit: Einheit = .stueck,
        mengenSchritt: Double = 1
    ) {
        self.id = UUID()
        self.name = name
        self.symbolName = symbolName
        self.farbeHex = farbeHex
        self.kategorie = kategorien.first
        self.kategorienRaw = kategorien
        self.erstelltAm = Date()
        self.notiz = notiz
        self.einheitRaw = einheit.rawValue
        self.mengenSchrittRaw = mengenSchritt
    }
}

extension Artikel {
    /// Kategorien, denen dieser Artikel zugeordnet ist — ein Artikel kann mehreren
    /// gleichzeitig angehören (z.B. "Süßigkeiten" und "Geschenke"). Die erste
    /// Kategorie gilt als führend und bleibt automatisch in ``kategorie``
    /// gespiegelt (Migrations-Fallback, Grundlage für
    /// ``fuehrendeKategorie(inGeschaeft:context:)``).
    var kategorien: [ArtikelKategorie] {
        get { kategorienRaw }
        set {
            kategorienRaw = newValue
            kategorie = newValue.first
        }
    }

    /// Die tatsächlich wirksamen Kategorien: ``kategorien``, falls gesetzt; sonst
    /// (Migrations-Fallback für vor der Mehrfachauswahl angelegte Artikel, deren
    /// `kategorienRaw` noch leer ist) das alte, einzelwertige ``kategorie``; sonst
    /// automatisch "Sonstiges" (siehe ``ArtikelKategorie/sonstige(context:)``). Nie
    /// leer.
    func effektiveKategorien(context: ModelContext) -> [ArtikelKategorie] {
        if !kategorien.isEmpty { return kategorien }
        if let kategorie { return [kategorie] }
        return [ArtikelKategorie.sonstige(context: context)]
    }

    /// Die für Gruppierung und Sortierung (``WarengruppenDistanzService``) beim
    /// Einkaufen in `geschaeft` **führende** Kategorie, falls ein Artikel mehreren
    /// Kategorien zugeordnet ist — Nutzer-Entscheidung: pro Geschäft gewinnt genau
    /// eine Kategorie, kein Duplizieren des Artikels über mehrere Abschnitte.
    /// Priorität: eine im Geschäft tatsächlich verfügbare Kategorie > die erste
    /// zugeordnete Kategorie (ohne `geschaeft`, z.B. in der geschäftsunabhängigen
    /// Artikel-Verwaltung).
    func fuehrendeKategorie(inGeschaeft geschaeft: Geschaeft?, context: ModelContext) -> ArtikelKategorie {
        let kandidaten = effektiveKategorien(context: context)
        guard let geschaeft else { return kandidaten[0] }
        let alleKategorien = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        let verfuegbareKategorien = geschaeft.verfuegbareKategorien(alleKategorien: alleKategorien)
        if let verfuegbar = kandidaten.first(where: { verfuegbareKategorien.contains($0) }) {
            return verfuegbar
        }
        return kandidaten[0]
    }
}
