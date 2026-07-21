import Foundation
import CoreGraphics
import Testing
@testable import ShopWithMe

struct ReceiptScanServiceTests {
    @Test
    func erkanntesDatumParstGueltigesISOFormat() {
        let ergebnis = BelegErgebnis(geschaeftName: "", geschaeftAdresse: "", datum: "2026-03-24", positionen: [])
        let erwartet = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 24))
        #expect(ergebnis.erkanntesDatum == erwartet)
    }

    @Test
    func erkanntesDatumIstNilBeiLeeremOderUngueltigemText() {
        #expect(BelegErgebnis(geschaeftName: "", geschaeftAdresse: "", datum: "", positionen: []).erkanntesDatum == nil)
        #expect(BelegErgebnis(geschaeftName: "", geschaeftAdresse: "", datum: "nicht erkennbar", positionen: []).erkanntesDatum == nil)
    }

    // MARK: - ErkannteZeile.boundingBox(fuerArtikelName:)

    @Test
    func boundingBoxFindetBeidseitigenTeilstringTreffer() {
        let zeilen = [
            ErkannteZeile(text: "REWE Muenchen", boundingBox: CGRect(x: 0, y: 0.9, width: 1, height: 0.05)),
            ErkannteZeile(text: "Vollmilch 1,5L", boundingBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.05)),
            ErkannteZeile(text: "Summe", boundingBox: CGRect(x: 0, y: 0.1, width: 1, height: 0.05)),
        ]
        #expect(zeilen.boundingBox(fuerArtikelName: "Vollmilch") == CGRect(x: 0, y: 0.5, width: 1, height: 0.05))
        // Umgekehrte Richtung: der KI-Name ist länger als die OCR-Zeile.
        #expect(zeilen.boundingBox(fuerArtikelName: "Vollmilch 1,5L Bio") == CGRect(x: 0, y: 0.5, width: 1, height: 0.05))
    }

    @Test
    func boundingBoxIstNilOhnePassendeZeile() {
        let zeilen = [ErkannteZeile(text: "Summe", boundingBox: CGRect(x: 0, y: 0.1, width: 1, height: 0.05))]
        #expect(zeilen.boundingBox(fuerArtikelName: "Vollmilch") == nil)
        #expect([ErkannteZeile]().boundingBox(fuerArtikelName: "Vollmilch") == nil)
    }
}
