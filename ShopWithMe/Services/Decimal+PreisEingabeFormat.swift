import Foundation

/// Lokal-bewusste Umwandlung zwischen ``Decimal``-Preisen und dem Text eines
/// editierbaren Preis-Eingabefelds (Belegscan/Preisschild-Scan) — GitHub #131.
///
/// Anders als ``Decimal/FormatStyle/euro`` (volle Währungsanzeige inkl. Symbol,
/// für reine Anzeige) liefert/liest dies nur die Zahl mit dem
/// Dezimaltrennzeichen des aktuellen Locale (z.B. "3,10" statt "3.10" unter
/// Deutsch) — das Währungssymbol wird an den Aufrufstellen weiterhin separat
/// als eigener `Text` neben dem Eingabefeld angezeigt.
enum PreisEingabeFormat {
    private static var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }

    /// Formatiert einen Preis für die Erstbefüllung eines Eingabefelds, z.B.
    /// `3,10` unter Deutsch statt eines rohen `Decimal`-`description`-Strings
    /// (der immer einen Punkt liefert, unabhängig vom Locale).
    static func text(fuer preis: Decimal) -> String {
        formatter.string(from: preis as NSDecimalNumber) ?? "\(preis)"
    }

    /// Liest den Text eines Preis-Eingabefelds locale-bewusst zurück in ein
    /// ``Decimal`` — akzeptiert sowohl das lokale Dezimaltrennzeichen als auch
    /// (als Fallback) einen Punkt, falls der Nutzer per externer Tastatur oder
    /// Copy-Paste einen Punkt eingegeben hat.
    static func decimal(ausText text: String) -> Decimal? {
        if let zahl = formatter.number(from: text) {
            return zahl.decimalValue
        }
        return Decimal(string: text.replacingOccurrences(of: ",", with: "."))
    }
}
