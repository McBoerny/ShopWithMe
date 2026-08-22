import Foundation
import Testing
@testable import ShopWithMe

/// Testet nur `textBasierteZuordnung` (keine KI/FoundationModels nötig) — die volle
/// `zuordnen(...)`-Pipeline mit KI-Fallback ist analog `GeschaeftErkennungService.vorschlag`
/// bewusst nicht unit-getestet, da sie echtes FoundationModels braucht.
struct ArtikelZuordnungsServiceTests {
    @Test
    func textBasierteZuordnungFindetGeschaeftsunabhaengigenProduktnameZuerst() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let produkt = Produkt(name: "Colgate", artikel: zahnpasta)
        let produktname = Produktname(name: "COL-ZAH", produkt: produkt, geschaeft: nil)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "COL-ZAH",
            alleArtikel: [zahnpasta],
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis?.produkt === produkt)
        #expect(ergebnis?.artikel === zahnpasta)
        #expect(ergebnis?.quelle == .produktname)
    }

    @Test
    func textBasierteZuordnungFindetTeilstringTrefferOhneProduktname() {
        let milch = Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA")

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "Bio Vollmilch 3,5%",
            alleArtikel: [milch]
        )

        #expect(ergebnis?.produkt == nil)
        #expect(ergebnis?.artikel === milch)
        #expect(ergebnis?.quelle == .artikelSubstring)
    }

    @Test
    func textBasierteZuordnungFindetTreffserUeberArtikelAlternativeNamen() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        zahnpasta.alternativeNamen = ["Zahncreme"]

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "Zahncreme",
            alleArtikel: [zahnpasta]
        )

        #expect(ergebnis?.artikel === zahnpasta)
        #expect(ergebnis?.quelle == .artikelSubstring)
    }

    // MARK: - Zuordnungs-Quelle (Folgearbeit zu GitHub #47/#116, automatische
    // Produkt-Neuanlage in `BelegScanView` nur bei Substring-/KI-Treffer)

    @Test
    func textBasierteZuordnungMarkiertSubstringTrefferAlsQuelleArtikelSubstring() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "Zahnpasta extra frisch",
            alleArtikel: [zahnpasta]
        )

        #expect(ergebnis?.quelle == .artikelSubstring)
    }

    @Test
    func textBasierteZuordnungMarkiertProduktnameTrefferAlsQuelleProduktname() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            alleArtikel: [zahnpasta],
            geschaeft: rewe,
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis?.quelle == .produktname)
    }

    @Test
    func textBasierteZuordnungLiefertNilBeiKomplettUnbekanntemNamen() {
        let milch = Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA")

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "Schokolade",
            alleArtikel: [milch]
        )

        #expect(ergebnis == nil)
    }

    // MARK: - Produktname-Matching (GitHub #47, Schritt 5/5; GitHub #128)

    @Test
    func textBasierteZuordnungFindetProduktnameInnerhalbGeschaeft() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            alleArtikel: [zahnpasta],
            geschaeft: rewe,
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis?.artikel === zahnpasta)
        #expect(ergebnis?.produkt === paradontol)
    }

    @Test
    func textBasierteZuordnungIgnoriertProduktnameAusAnderemGeschaeft() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let aldi = Geschaeft(name: "Aldi", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        // Gescannt bei Aldi, Produktname aber nur für Rewe hinterlegt (nicht
        // geschäftsunabhängig, also `geschaeft != nil`) — kein Produkt-Treffer,
        // fällt auf reinen Artikel-Teilstring-Abgleich zurück (hier ohne
        // Treffer, da "Parad Zahncr" keinen Teilstring von "Zahnpasta" bildet
        // und umgekehrt).
        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            alleArtikel: [zahnpasta],
            geschaeft: aldi,
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis == nil)
    }

    @Test
    func textBasierteZuordnungBevorzugtGeschaeftsspezifischenProduktnameVorGeschaeftsunabhaengigem() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let generisch = Produkt(name: "Zahnpasta (generisch)", artikel: zahnpasta)
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let geschaeftsunabhaengig = Produktname(name: "PARAD ZAHNCR 75ML", produkt: generisch, geschaeft: nil)
        let geschaeftsspezifisch = Produktname(name: "PARAD ZAHNCR 75ML", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            alleArtikel: [zahnpasta],
            geschaeft: rewe,
            bekannteProduktnamen: [geschaeftsunabhaengig, geschaeftsspezifisch]
        )

        #expect(ergebnis?.produkt === paradontol)
    }

    @Test
    func textBasierteZuordnungOhneGeschaeftFindetNurGeschaeftsunabhaengigenProduktname() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            alleArtikel: [zahnpasta],
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis == nil)
    }
}
