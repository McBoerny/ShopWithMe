import Foundation
import Testing
@testable import ShopWithMe

/// Testet nur `textBasierteZuordnung` (keine KI/FoundationModels nötig) — die volle
/// `zuordnen(...)`-Pipeline mit KI-Fallback ist analog `GeschaeftErkennungService.vorschlag`
/// bewusst nicht unit-getestet, da sie echtes FoundationModels braucht.
struct ArtikelZuordnungsServiceTests {
    @Test
    func textBasierteZuordnungFindetGelerntenAliasZuerst() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let alias = ArtikelAlias(erkannterName: "COL-ZAH", alternativerName: "Colgate", artikel: zahnpasta)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "COL-ZAH",
            bekannteAliase: [alias],
            alleArtikel: [zahnpasta]
        )

        #expect(ergebnis?.alias == "Colgate")
        #expect(ergebnis?.artikel === zahnpasta)
    }

    @Test
    func textBasierteZuordnungFindetTeilstringTrefferOhneGelerntenAlias() {
        let milch = Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA")

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "Bio Vollmilch 3,5%",
            bekannteAliase: [],
            alleArtikel: [milch]
        )

        #expect(ergebnis?.alias == nil)
        #expect(ergebnis?.artikel === milch)
        #expect(ergebnis?.quelle == .artikelSubstring)
    }

    // MARK: - Zuordnungs-Quelle (Folgearbeit zu GitHub #47/#116, automatische
    // Produkt-Neuanlage in `BelegScanView` nur bei Substring-/KI-Treffer)

    @Test
    func textBasierteZuordnungMarkiertAliasTrefferAlsQuelleAlias() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let alias = ArtikelAlias(erkannterName: "COL-ZAH", alternativerName: "Colgate", artikel: zahnpasta)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "COL-ZAH",
            bekannteAliase: [alias],
            alleArtikel: [zahnpasta]
        )

        #expect(ergebnis?.quelle == .alias)
    }

    @Test
    func textBasierteZuordnungMarkiertProduktnameTrefferAlsQuelleProduktname() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            bekannteAliase: [],
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
            bekannteAliase: [],
            alleArtikel: [milch]
        )

        #expect(ergebnis == nil)
    }

    // MARK: - Produktname-Matching (GitHub #47, Schritt 5/5)

    @Test
    func textBasierteZuordnungFindetProduktnameInnerhalbGeschaeft() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            bekannteAliase: [],
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

        // Gescannt bei Aldi, Produktname aber nur für Rewe hinterlegt — kein
        // Produkt-Treffer, fällt auf reinen Artikel-Teilstring-Abgleich zurück
        // (hier ohne Treffer, da "Parad Zahncr" keinen Teilstring von
        // "Zahnpasta" bildet und umgekehrt).
        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            bekannteAliase: [],
            alleArtikel: [zahnpasta],
            geschaeft: aldi,
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis == nil)
    }

    @Test
    func textBasierteZuordnungBevorzugtGelerntenAliasVorProduktname() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let alias = ArtikelAlias(erkannterName: "PARAD ZAHNCR 75ML", alternativerName: "Paradontol (Alias)", artikel: zahnpasta)
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            bekannteAliase: [alias],
            alleArtikel: [zahnpasta],
            geschaeft: rewe,
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis?.alias == "Paradontol (Alias)")
        #expect(ergebnis?.produkt == nil)
    }

    @Test
    func textBasierteZuordnungOhneGeschaeftUeberspringtProduktnameStufe() {
        let zahnpasta = Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")
        let paradontol = Produkt(name: "Paradontol Zahncreme", artikel: zahnpasta)
        let rewe = Geschaeft(name: "Rewe", typen: [])
        let produktname = Produktname(name: "Parad Zahncr", produkt: paradontol, geschaeft: rewe)

        let ergebnis = ArtikelZuordnungsService.textBasierteZuordnung(
            erkannterName: "PARAD ZAHNCR 75ML",
            bekannteAliase: [],
            alleArtikel: [zahnpasta],
            bekannteProduktnamen: [produktname]
        )

        #expect(ergebnis == nil)
    }
}
