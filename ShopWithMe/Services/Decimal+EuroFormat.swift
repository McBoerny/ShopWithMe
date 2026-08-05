import Foundation

extension Decimal.FormatStyle {
    /// Einzige Stelle, die den Währungscode für alle Preisanzeigen der App
    /// festlegt (GitHub #106) — vorher an vier Stellen einzeln als
    /// `.currency(code: "EUR")` dupliziert.
    ///
    /// **An Aufrufstellen bevorzugt voll qualifiziert verwenden**
    /// (`Decimal.FormatStyle.euro`), nicht die kurze `.euro`-Dot-Syntax: Swifts
    /// Typinferenz für generische `FormatStyle`-Parameter (`Decimal.formatted(_:)`,
    /// `Text(_:format:)`) löst einen bloßen führenden Punkt nicht zuverlässig auf
    /// allen Aufrufwegen auf — insbesondere nicht innerhalb einer
    /// String-Interpolation (`"\(x.formatted(.euro))"` scheitert mit „type
    /// 'FormatStyle' has no member 'euro'", obwohl `Decimal.FormatStyle` das
    /// Symbol korrekt deklariert) und nicht bei `Text(_:format:)` (dort wegen
    /// mehrerer `FormatStyle`-Overloads für unterschiedliche Eingabetypen).
    static var euro: Currency { .currency(code: "EUR") }
}
