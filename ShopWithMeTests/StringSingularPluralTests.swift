import Testing
@testable import ShopWithMe

@Suite("String+SingularPlural")
struct StringSingularPluralTests {
    /// Die 15 Wortpaare, mit denen `NLTagger`s `.lemma`-Schema empirisch
    /// gegengeprüft wurde (siehe Typ-Dokumentation in
    /// `String+SingularPlural.swift`) — die Heuristik muss alle davon
    /// abdecken, sonst wäre sie keine Verbesserung gegenüber NLTagger allein.
    @Test(arguments: [
        ("Apfel", "Äpfel"), ("Haus", "Häuser"), ("Buch", "Bücher"),
        ("Tomate", "Tomaten"), ("Kartoffel", "Kartoffeln"), ("Zwiebel", "Zwiebeln"),
        ("Ei", "Eier"), ("Brot", "Brote"), ("Glas", "Gläser"),
        ("Auto", "Autos"), ("Banane", "Bananen"), ("Nuss", "Nüsse"),
        ("Käse", "Käse"), ("Wurst", "Würste"), ("Joghurt", "Joghurts"),
    ])
    func erkenntSingularUndPluralAlsZusammengehoerig(singular: String, plural: String) {
        #expect(singular.passtAlsSingularPluralZu(plural))
        #expect(plural.passtAlsSingularPluralZu(singular))
    }

    @Test
    func erkenntGleichesWortAlsPassend() {
        #expect("Apfel".passtAlsSingularPluralZu("Apfel"))
    }

    @Test
    func erkenntUnabhaengigeWoerterNichtAlsPassend() {
        #expect("Apfel".passtAlsSingularPluralZu("Banane") == false)
        #expect("Milch".passtAlsSingularPluralZu("Zitrone") == false)
    }
}
