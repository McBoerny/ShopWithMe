import Testing
@testable import ShopWithMe

@Suite("String+AlphabetischeSortierung")
struct StringAlphabetischeSortierungTests {
    @Test
    func vergleicheAlphabetischSortiertUmlauteBeiIhremBasisbuchstaben() {
        let namen = ["Banane", "Ärger", "Apfel", "Zucker", "Öl"]
        let sortiert = namen.sorted { $0.vergleicheAlphabetisch(mit: $1) == .orderedAscending }
        #expect(sortiert == ["Apfel", "Ärger", "Banane", "Öl", "Zucker"])
    }

    @Test
    func alphabetischerAnfangsbuchstabeBildetUmlauteAufBasisbuchstabenAb() {
        #expect("Ärger".alphabetischerAnfangsbuchstabe == "A")
        #expect("Öl".alphabetischerAnfangsbuchstabe == "O")
        #expect("Übung".alphabetischerAnfangsbuchstabe == "U")
        #expect("Apfel".alphabetischerAnfangsbuchstabe == "A")
    }

    @Test
    func alphabetischerAnfangsbuchstabeFaelltBeiLeeremNamenAufRauteZurueck() {
        #expect("".alphabetischerAnfangsbuchstabe == "#")
    }
}
