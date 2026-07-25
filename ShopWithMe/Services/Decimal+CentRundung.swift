import Foundation

extension Decimal {
    /// Rundet auf zwei Nachkommastellen (Cent-Genauigkeit) — nötig, weil von der
    /// lokalen KI erkannte Beleg-/Preisschild-Preise gelegentlich mit
    /// Gleitkomma-Rundungsfehlern behaftet sind (z.B. `2.4900000000512` statt
    /// `2.49`), siehe GitHub #18.
    var aufCentGerundet: Decimal {
        var ergebnis = Decimal()
        var wert = self
        NSDecimalRound(&ergebnis, &wert, 2, .plain)
        return ergebnis
    }
}
