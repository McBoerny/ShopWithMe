import Foundation

#if DEBUG
/// Rein für lokale Entwicklung/Testen: erlaubt es, den Suchradius der
/// Standort-basierten Ladenerkennung (``GeschaeftErkennungService``) in den
/// Einstellungen testweise zu erhöhen, um sie ohne echte Nähe zu einem
/// Apple-Maps-Laden auszuprobieren. Existiert nur in Debug-Builds (`#if DEBUG`) — in
/// Release-Builds ist dieser Typ nicht einmal Teil des kompilierten Binaries, es gilt
/// dort immer der feste Standardwert. Siehe `docs/GESCHAEFTSERKENNUNG.md`.
enum DebugEinstellungen {
    private static let schluessel = "debug.geschaefteSuchradiusUeberschreibung"

    /// Überschreibt testweise den Suchradius (in Metern) für die Standort-basierte
    /// Ladenerkennung (sowohl den automatischen Einzelvorschlag als auch „Alle
    /// Geschäfte in der Nähe“) — `nil` (Standard), solange nicht in den Einstellungen
    /// aktiviert, verwendet die regulären Radien
    /// (``GeschaeftErkennungService/standardSuchradius``/
    /// ``GeschaeftErkennungService/standardAlleInDerNaeheRadius``).
    static var sucheRadiusUeberschreibung: Double? {
        get {
            let wert = UserDefaults.standard.double(forKey: schluessel)
            return wert > 0 ? wert : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: schluessel)
            } else {
                UserDefaults.standard.removeObject(forKey: schluessel)
            }
        }
    }
}
#endif
