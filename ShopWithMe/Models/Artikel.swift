import Foundation
import SwiftData

/// Maßeinheit, in der ``Artikel/menge``/``Artikel/mengenSchritt`` geführt werden —
/// Gewicht, Volumen oder Stück.
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
/// Jeder Artikel gehört zu genau einer ``ArtikelKategorie``. Die Kategorie kann jederzeit
/// über die Bearbeiten-Bildschirme geändert werden.
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
    /// Die Kategorie dieses Artikels.
    var kategorie: ArtikelKategorie?
    /// Ob der Artikel aktuell auf der Einkaufsliste steht.
    var istAufEinkaufsliste: Bool
    /// Zeitpunkt der Anlage.
    var erstelltAm: Date
    /// Optionale, dauerhafte Notiz, z.B. bevorzugte Marke.
    var notiz: String?

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
    /// dient als Schrittweite für Erhöhen/Verringern von ``menge`` auf der
    /// Einkaufsliste (siehe ``mengeErhoehen()``/``mengeVerringern()``).
    var mengenSchritt: Double {
        get { mengenSchrittRaw ?? 1 }
        set { mengenSchrittRaw = newValue }
    }

    /// Rohwert für ``menge``. Optional gespeichert (siehe ``einheitRaw``); ein
    /// `nil`-Rohwert fällt auf ``mengenSchritt`` zurück.
    private var mengeRaw: Double?
    /// Aktuell auf der Einkaufsliste gewünschte Menge. Startet bei ``mengenSchritt``
    /// und wird beim Einkaufen in Schritten von ``mengenSchritt`` verändert (siehe
    /// ``aufEinkaufslisteSetzen()``).
    var menge: Double {
        get { mengeRaw ?? mengenSchritt }
        set { mengeRaw = newValue }
    }

    /// Temporäre Notiz für den aktuellen Einkaufslisten-Eintrag (z.B. "diesmal die
    /// große Packung") — anders als ``notiz`` nicht dauerhaft, sondern wird beim
    /// erneuten Hinzufügen zur Einkaufsliste zurückgesetzt (siehe
    /// ``aufEinkaufslisteSetzen()``).
    var einkaufslistenNotiz: String?

    init(
        name: String,
        symbolName: String,
        farbeHex: String,
        kategorie: ArtikelKategorie? = nil,
        istAufEinkaufsliste: Bool = false,
        notiz: String? = nil,
        einheit: Einheit = .stueck,
        mengenSchritt: Double = 1
    ) {
        self.id = UUID()
        self.name = name
        self.symbolName = symbolName
        self.farbeHex = farbeHex
        self.kategorie = kategorie
        self.istAufEinkaufsliste = istAufEinkaufsliste
        self.erstelltAm = Date()
        self.notiz = notiz
        self.einheitRaw = einheit.rawValue
        self.mengenSchrittRaw = mengenSchritt
        self.mengeRaw = mengenSchritt
    }
}

extension Artikel {
    /// Die für Gruppierung, Regal-Zuordnung und Lernalgorithmus tatsächlich
    /// wirksame Kategorie: ``kategorie``, oder — falls keine gesetzt ist —
    /// automatisch "Sonstiges" (siehe ``ArtikelKategorie/sonstige(context:)``).
    func effektiveKategorie(context: ModelContext) -> ArtikelKategorie {
        kategorie ?? ArtikelKategorie.sonstige(context: context)
    }

    /// Erhöht ``menge`` um ``mengenSchritt`` — Reaktion auf einen einfachen Tap in
    /// der Einkaufsliste (siehe ``EinkaufenView``).
    func mengeErhoehen() {
        menge += mengenSchritt
    }

    /// Verringert ``menge`` um ``mengenSchritt``, ohne unter ``mengenSchritt`` zu
    /// fallen — Reaktion auf einen Doppel-Tap in der Einkaufsliste (siehe
    /// ``EinkaufenView``).
    func mengeVerringern() {
        menge = max(mengenSchritt, menge - mengenSchritt)
    }

    /// Setzt diesen Artikel (neu oder erneut) auf die Einkaufsliste: ``menge`` wird
    /// auf ``mengenSchritt`` zurückgesetzt und ``einkaufslistenNotiz`` geleert,
    /// unabhängig vom zuletzt vor dem Abhaken gewählten Wert. Zentrale Stelle für
    /// alle Orte, die einen Artikel (neu oder erneut) auf die Liste setzen (siehe
    /// ``ArtikelHinzufuegenView``, ``Einkaufsvorgang/artikelAbwaehlen(_:context:)``).
    func aufEinkaufslisteSetzen() {
        istAufEinkaufsliste = true
        menge = mengenSchritt
        einkaufslistenNotiz = nil
    }
}
