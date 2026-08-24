import SwiftUI

/// Hex-Farb-Konvertierung, da ``Artikel`` und ``Abteilung`` Farben als
/// Hex-String (z.B. `"#34C759"`) speichern, um sie unabhängig vom Farbraum/Schema
/// persistieren zu können.
extension Color {
    /// Erzeugt eine Farbe aus einem Hex-String der Form `"#RRGGBB"`. Ungültige Strings
    /// ergeben Grau.
    init(hex: String) {
        var bereinigt = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        bereinigt.removeAll { $0 == "#" }

        var wert: UInt64 = 0
        Scanner(string: bereinigt).scanHexInt64(&wert)

        guard bereinigt.count == 6 else {
            self = .gray
            return
        }

        let r = Double((wert & 0xFF0000) >> 16) / 255
        let g = Double((wert & 0x00FF00) >> 8) / 255
        let b = Double(wert & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Standard-Farbpalette zur Auswahl für Artikel/Abteilungen.
    static let artikelPalette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE",
        "#30B0C7", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55",
        "#A2845E", "#8E8E93",
    ]
}
