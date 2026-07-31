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
}
