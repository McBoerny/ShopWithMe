import Foundation
import CoreGraphics
import Testing
@testable import ShopWithMe

struct ReceiptScanServiceTests {
    @Test
    func erkanntesDatumParstGueltigesISOFormat() {
        let ergebnis = BelegErgebnis(geschaeftName: "", geschaeftAdressen: [], datum: "2026-03-24", positionen: [])
        let erwartet = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 24))
        #expect(ergebnis.erkanntesDatum == erwartet)
    }

    @Test
    func erkanntesDatumIstNilBeiLeeremOderUngueltigemText() {
        #expect(BelegErgebnis(geschaeftName: "", geschaeftAdressen: [], datum: "", positionen: []).erkanntesDatum == nil)
        #expect(BelegErgebnis(geschaeftName: "", geschaeftAdressen: [], datum: "nicht erkennbar", positionen: []).erkanntesDatum == nil)
    }

    // MARK: - Decimal.aufCentGerundet

    @Test
    func aufCentGerundetKorrigiertGleitkommaRundungsfehler() {
        let fehlerhaft = Decimal(string: "2.4900000000512")!
        #expect(fehlerhaft.aufCentGerundet == Decimal(string: "2.49")!)
    }

    @Test
    func aufCentGerundetLaesstBereitsGerundeteWerteUnveraendert() {
        #expect(Decimal(string: "9.99")!.aufCentGerundet == Decimal(string: "9.99")!)
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

    @Test
    func boundingBoxIgnoriertSehrKurzeZeilenBeiUmgekehrterRichtung() {
        // GitHub #17: eine sehr kurze OCR-Zeile (z.B. eine einzelne Trennziffer) darf
        // nicht per umgekehrtem Teilstring-Abgleich fast jeden Artikelnamen treffen —
        // sonst liefert `first` für jede Position dieselbe erste Zeile zurück.
        let zeilen = [
            ErkannteZeile(text: "1", boundingBox: CGRect(x: 0, y: 0.9, width: 1, height: 0.05)),
            ErkannteZeile(text: "Vollmilch 1,5L", boundingBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.05)),
        ]
        #expect(zeilen.boundingBox(fuerArtikelName: "Vollmilch") == CGRect(x: 0, y: 0.5, width: 1, height: 0.05))
        #expect(zeilen.boundingBox(fuerArtikelName: "Butter") == nil)
    }

    // MARK: - [ErkannteZeile].sortiertInLeserichtung

    @Test
    func sortiertInLeserichtungOrdnetVonObenNachUnten() {
        // Vision liefert boundingBox mit Ursprung unten links — ein höherer y-Wert
        // liegt weiter oben im Bild und muss daher zuerst kommen.
        let kopf = ErkannteZeile(text: "REWE", boundingBox: CGRect(x: 0, y: 0.9, width: 1, height: 0.05))
        let position = ErkannteZeile(text: "Milch", boundingBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.05))
        let summe = ErkannteZeile(text: "Summe", boundingBox: CGRect(x: 0, y: 0.1, width: 1, height: 0.05))

        let sortiert = [summe, kopf, position].sortiertInLeserichtung()

        #expect(sortiert.map(\.text) == ["REWE", "Milch", "Summe"])
    }

    @Test
    func sortiertInLeserichtungOrdnetInnerhalbDerselbenZeileLinksNachRechts() {
        let name = ErkannteZeile(text: "Milch", boundingBox: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.05))
        let preis = ErkannteZeile(text: "1,29", boundingBox: CGRect(x: 0.7, y: 0.5, width: 0.3, height: 0.05))

        let sortiert = [preis, name].sortiertInLeserichtung()

        #expect(sortiert.map(\.text) == ["Milch", "1,29"])
    }
}
