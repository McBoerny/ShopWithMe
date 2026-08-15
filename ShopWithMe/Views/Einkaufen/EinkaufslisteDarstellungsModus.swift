import Foundation

/// Hauptdarstellungsmodi für die Artikelliste beim Einkaufen.
/// Jeder Modus hat eigene Konfigurationsoptionen — siehe ``DarstellungsKey``.
///
/// Erweiterung: Neuen case ergänzen → Renderer-Sub-View in
/// ``EinkaufslisteDarstellungsView`` anlegen → switch-Fall dort ergänzen →
/// Einstellungs-Section in ``EinkaufslisteDarstellungsSettingsView`` ergänzen.
enum EinkaufslisteDarstellungsModus: String, CaseIterable {
    case liste
    case kacheln

    var bezeichnung: String {
        switch self {
        case .liste:   return "Liste"
        case .kacheln: return "Kacheln"
        }
    }
}

/// Untertyp der Listendarstellung — bestimmt, wie einzelne Artikel
/// innerhalb jeder Kategorie-Sektion dargestellt werden.
/// Gilt für ``EinkaufslisteDarstellungsModus/liste`` und lässt sich
/// unabhängig vom Akkordeon-Toggle wählen.
enum ListenAnzeigeTyp: String, CaseIterable {
    case klassisch
    case chipsGross
    case chipsKlein

    var bezeichnung: String {
        switch self {
        case .klassisch:  return "Klassisch"
        case .chipsGross: return "Chips (groß)"
        case .chipsKlein: return "Chips (klein)"
        }
    }

    var systemImage: String {
        switch self {
        case .klassisch:  return "checklist"
        case .chipsGross: return "rectangle.grid.1x2"
        case .chipsKlein: return "tag"
        }
    }
}

/// Spaltenzahl für den ``EinkaufslisteDarstellungsModus/kacheln``-Modus.
enum KachelSpaltenanzahl: Int, CaseIterable {
    case zwei = 2
    case drei = 3

    var bezeichnung: String {
        switch self {
        case .zwei: return "2 Spalten"
        case .drei: return "3 Spalten"
        }
    }
}

/// Zentrale ``AppStorage``-Schlüssel für alle Darstellungseinstellungen.
/// Werden von ``EinkaufslisteDarstellungsView`` (Lesezugriff)
/// und ``EinkaufslisteDarstellungsSettingsView`` (Schreibzugriff) gemeinsam genutzt.
enum DarstellungsKey {
    static let modus        = "listendarst.modus"
    static let listenTyp    = "listendarst.liste.typ"
    static let akkordeon    = "listendarst.liste.akkordeon"
    static let fortschritt  = "listendarst.liste.fortschritt"
    static let farbstreifen = "listendarst.liste.farbstreifen"
    static let spalten      = "listendarst.kacheln.spalten"
    static let farbig       = "listendarst.kacheln.farbig"
}
