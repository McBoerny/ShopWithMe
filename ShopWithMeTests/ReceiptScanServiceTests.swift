import Foundation
import Testing
@testable import ShopWithMe

struct ReceiptScanServiceTests {
    @Test
    func erkanntesDatumParstGueltigesISOFormat() {
        let ergebnis = BelegErgebnis(geschaeftName: "", datum: "2026-03-24", positionen: [])
        let erwartet = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 24))
        #expect(ergebnis.erkanntesDatum == erwartet)
    }

    @Test
    func erkanntesDatumIstNilBeiLeeremOderUngueltigemText() {
        #expect(BelegErgebnis(geschaeftName: "", datum: "", positionen: []).erkanntesDatum == nil)
        #expect(BelegErgebnis(geschaeftName: "", datum: "nicht erkennbar", positionen: []).erkanntesDatum == nil)
    }
}
