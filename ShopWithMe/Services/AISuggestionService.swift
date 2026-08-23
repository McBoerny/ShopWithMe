import Foundation
import FoundationModels

/// Von der lokalen Apple-KI (FoundationModels) vorgeschlagene Eigenschaften für einen
/// neu angelegten ``Artikel``.
@Generable
struct ArtikelVorschlag {
    @Guide(description: "Name einer passenden Artikelkategorie")
    var kategorieName: String
}

/// Schlägt beim Anlegen eines Artikels automatisch eine Kategorie vor, indem die
/// lokale, on-device Apple-KI (FoundationModels/"Apple Intelligence") befragt wird.
///
/// Ist auf dem Gerät keine Apple Intelligence verfügbar, ist ``istVerfuegbar`` `false`
/// — die aufrufende UI blendet die Funktion dann aus, es gibt keinen Fehlerzustand.
enum AISuggestionService {
    /// Ob auf diesem Gerät ein KI-Vorschlag angefragt werden kann.
    static var istVerfuegbar: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Erzeugt einen ``ArtikelVorschlag`` für den gegebenen Artikelnamen. Bestehende
    /// Kategorienamen werden als Kontext mitgegeben, damit das Modell bevorzugt
    /// vorhandene Werte wiederverwendet statt neue zu erfinden.
    static func vorschlag(
        fuerArtikelName name: String,
        bekannteKategorien: [String]
    ) async throws -> ArtikelVorschlag {
        let anweisungen = """
        Du hilfst in einer Einkaufs-App dabei, neu angelegte Artikel einzuordnen. \
        Schlage für den genannten Artikel eine passende Artikelkategorie vor. Verwende \
        nach Möglichkeit eine dieser bestehenden Kategorien, falls sie passt: \
        \(bekannteKategorien.joined(separator: ", ")).
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: "Artikel: \(name)", generating: ArtikelVorschlag.self)
        return antwort.content
    }

    /// Ermittelt für einen importierten Kategorienamen (z.B. aus einer fremden
    /// Shopping-App) die inhaltlich am besten passende bestehende
    /// ``ArtikelKategorie`` — genutzt vom MilkForUs-Textimport
    /// (``MilkForUsImportService``), um z.B. "Brot" auf "Brot & Backwaren"
    /// abzubilden statt eine Dublette anzulegen.
    static func kategorieMatch(
        fuerName name: String,
        bekannteKategorien: [String]
    ) async throws -> KategorieMatchVorschlag {
        let anweisungen = """
        Du hilfst dabei, Kategorienamen aus dem Export einer anderen Einkaufs-App auf \
        die Kategorien einer Einkaufs-App abzubilden. Wähle aus dieser Liste \
        bestehender Kategorien diejenige, die inhaltlich am besten zum genannten \
        Namen passt: \(bekannteKategorien.joined(separator: ", ")). Antworte mit \
        einem leeren String, falls wirklich keine davon passt — erfinde keine neue \
        Kategorie.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: "Kategorie: \(name)", generating: KategorieMatchVorschlag.self)
        return antwort.content
    }
    /// Ermittelt für einen auf einem Kassenbon erkannten, oft abgekürzten oder
    /// markenspezifischen Artikelnamen (z.B. „COL-ZAH“ oder „Bio Vollmilch 3,5%“)
    /// den inhaltlich am besten passenden bestehenden, generischen ``Artikel`` —
    /// genutzt von ``ArtikelZuordnungsService/zuordnen(erkannterName:bekannteAliase:alleArtikel:geschaeft:bekannteProduktnamen:)``
    /// als letzte Stufe, nur falls einfacherer Textabgleich erfolglos war (siehe
    /// `docs/BELEGSCAN.md`).
    static func artikelMatch(
        fuerName name: String,
        bekannteArtikel: [String]
    ) async throws -> ArtikelMatchVorschlag {
        let anweisungen = """
        Du hilfst dabei, auf einem Kassenbon einer Einkaufs-App erkannte, oft \
        abgekürzte oder markenspezifische Artikelnamen (z.B. „COL-ZAH“ oder „Bio \
        Vollmilch 3,5%“) auf bereits vorhandene, generische Artikel abzubilden. \
        Wähle aus dieser Liste bestehender Artikel denjenigen, der inhaltlich am \
        besten passt: \(bekannteArtikel.joined(separator: ", ")). Antworte mit \
        einem leeren String, falls wirklich keiner davon passt — erfinde keinen \
        neuen Artikel.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: "Artikel: \(name)", generating: ArtikelMatchVorschlag.self)
        return antwort.content
    }

    /// Schlägt für einen auf einem Kassenbon erkannten, oft abgekürzten oder
    /// markenspezifischen Produktnamen (z.B. „SEBAMED UR") einen menschenlesbaren
    /// Klarnamen vor (z.B. „Sebamed Urea 5% Shampoo") — genutzt von
    /// ``BelegScanView`` (GitHub #121). Bestehende Klarnames des Artikels werden als
    /// Kontext mitgegeben, damit das Modell bevorzugt bekannte Namen wiederverwendet.
    static func produktKlarname(
        fuerErkannterName erkannterName: String,
        bekannteKlarnamen: [String]
    ) async throws -> ProduktKlarnameVorschlag {
        let bekannteAufzaehlung = bekannteKlarnamen.isEmpty ? "–" : bekannteKlarnamen.joined(separator: ", ")
        let anweisungen = """
        Du hilfst in einer Einkaufs-App dabei, für auf Kassenbons erkannte, oft \
        abgekürzte Produktbezeichnungen einen menschenlesbaren Klarnamen zu ermitteln. \
        Wähle bevorzugt einen aus dieser Liste bereits bekannter Klarnamen, falls er \
        inhaltlich passt: \(bekannteAufzaehlung). \
        Falls keiner passt, formuliere einen neuen, allgemeinverständlichen Namen \
        (z.B. „Sebamed Urea 5% Shampoo" für „SEBAMED UR"). Bleibe sachlich — \
        erfinde keine Marke, wenn du dir nicht sicher bist.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: "Bon-Text: \(erkannterName)", generating: ProduktKlarnameVorschlag.self)
        return antwort.content
    }

    /// Schlägt für einen ``GeschaeftTyp`` (z.B. Drogerie) typische Abteilungen vor,
    /// genutzt in der Typ-Verwaltung der Einstellungen (GitHub #5), um
    /// ``ArtikelKategorie/geschaeftsTypen`` schneller zu befüllen. Bestehende
    /// Kategorienamen werden als Kontext mitgegeben, damit das Modell bevorzugt
    /// vorhandene wiederverwendet statt Dubletten vorzuschlagen. Nimmt bewusst nur
    /// den Namen (nicht das ``GeschaeftTyp``-Objekt selbst) entgegen — seit GitHub
    /// #25 ein SwiftData-`@Model` und damit kein `Sendable`-Typ, der sich gefahrlos
    /// über die `async`-Grenze dieser Methode reichen ließe.
    static func vorschlag(
        fuerGeschaeftsTypName typName: String,
        bekannteKategorien: [String]
    ) async throws -> AbteilungsVorschlag {
        let anweisungen = """
        Du hilfst in einer Einkaufs-App dabei, für einen Geschäftstyp typische \
        Abteilungen vorzuschlagen. Nenne mehrere passende Abteilungen für den \
        genannten Geschäftstyp. Verwende nach Möglichkeit vorhandene Namen aus \
        dieser Liste, falls sie passen: \(bekannteKategorien.joined(separator: ", ")). \
        Schlage nur dann neue Namen vor, wenn keine passende bestehende Abteilung \
        dabei ist.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: "Geschäftstyp: \(typName)", generating: AbteilungsVorschlag.self)
        return antwort.content
    }

    /// Ermittelt für eine oder mehrere auf einem Kassenbon erkannte Adressen (z.B.
    /// Filiale UND Betreiber-/Zentraladresse desselben Belegs, GitHub #132) die
    /// inhaltlich am besten passende bereits bekannte ``Geschaeft``-Adresse — toleriert
    /// OCR-Erkennungsfehler (Ziffern-/Buchstabenverwechslung, Abkürzungen), analog
    /// ``artikelMatch(fuerName:bekannteArtikel:)``. Genutzt als letzte Stufe von
    /// ``Geschaeft/passendes(fuerErkannterName:erkannteAdressen:unter:)``, nur wenn der
    /// schnelle, KI-freie Teilstring-Abgleich keinen eindeutigen Treffer liefert.
    static func adressMatch(
        fuerAdressen erkannteAdressen: [String],
        bekannteAdressen: [String]
    ) async throws -> AdressMatchVorschlag {
        let anweisungen = """
        Du hilfst dabei, auf einem Kassenbon einer Einkaufs-App erkannte Adressen \
        (oft mit OCR-Erkennungsfehlern wie vertauschten Ziffern/Buchstaben oder \
        abweichenden Abkürzungen) auf bereits bekannte Geschäftsadressen abzubilden. \
        Ein Bon kann mehrere Adressen enthalten (z.B. Filiale und Betreiber-/ \
        Zentraladresse) — jede davon kann zum gesuchten Geschäft gehören. Wähle aus \
        dieser Liste bekannter Adressen diejenige, die zu einer der erkannten \
        Adressen am besten passt: \(bekannteAdressen.joined(separator: " | ")). \
        Antworte mit einem leeren String, falls wirklich keine davon passt — erfinde \
        keine neue Adresse.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(
            to: "Erkannte Adressen: \(erkannteAdressen.joined(separator: " | "))",
            generating: AdressMatchVorschlag.self
        )
        return antwort.content
    }

    /// Erkennt potenzielle Dubletten/Varianten unter `namen` — Grundlage für
    /// ``ArtikelDuplikatVorschlaegeView`` (GitHub #133). Anders als die
    /// übrigen Funktionen dieses Typs (ein Name gegen eine bekannte Liste) ist
    /// dies ein Ganzkatalog-Abgleich: jeder Name wird gegen jeden anderen
    /// verglichen, daher `namen` **vorab vom Aufrufer nach Kategorie
    /// gruppieren** (Dubletten/Varianten liegen praktisch immer in derselben
    /// Kategorie) — ein Aufruf pro Gruppe hält den Kontext klein und die
    /// Trefferqualität hoch, statt den gesamten Artikelbestand in einer
    /// Anfrage zu bündeln.
    static func artikelBeziehungsVorschlaege(
        fuerArtikelNamen namen: [String]
    ) async throws -> [ArtikelBeziehungsVorschlag] {
        guard namen.count > 1 else { return [] }
        let anweisungen = """
        Du hilfst in einer Einkaufs-App dabei, Dubletten und Varianten unter \
        Artikelnamen zu finden, die versehentlich als getrennte Artikel \
        angelegt wurden (z.B. durch Import oder mehrfache manuelle Anlage). \
        Zwei Fälle:
        1. DUPLIKAT: zwei Namen meinen dasselbe generische Ding, nur anders \
        geschrieben (z.B. "Cola" und "Coca Cola", "Zahnpaste" und \
        "Zahncreme").
        2. VARIANTE: ein Name ist eigentlich kein eigener generischer \
        Artikel, sondern ein konkretes Produkt/eine Marke eines anderen \
        Namens (z.B. "Persil" ist eine Marke von "Waschmittel").
        Gib für jedes gefundene Paar den primären Namen (den allgemeineren \
        bzw. den, der bestehen bleiben soll) und den verwandten Namen an, \
        markiere DUPLIKAT-Fälle mit istDuplikat=true und VARIANTE-Fälle mit \
        istDuplikat=false, und begründe kurz. Nenne nur Namen aus dieser \
        Liste, erfinde keine: \(namen.joined(separator: ", ")). Nenne kein \
        Paar, wenn du dir nicht recht sicher bist — lieber wenige, \
        zuverlässige Vorschläge als viele fragwürdige.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(
            to: "Artikel: \(namen.joined(separator: ", "))",
            generating: ArtikelBeziehungsVorschlaege.self
        )
        return antwort.content.vorschlaege
    }
}

/// Von der lokalen Apple-KI vorgeschlagene, typische Abteilungen für einen
/// ``GeschaeftTyp`` — siehe ``AISuggestionService/vorschlag(fuerGeschaeftsTypName:bekannteKategorien:)``.
@Generable
struct AbteilungsVorschlag {
    @Guide(description: "Namen typischer Abteilungen für diesen Geschäftstyp, bevorzugt aus den bekannten Namen")
    var kategorieNamen: [String]
}

/// Von der lokalen Apple-KI vorgeschlagene, am besten passende bestehende
/// ``ArtikelKategorie`` für einen importierten Kategorienamen — siehe
/// ``AISuggestionService/kategorieMatch(fuerName:bekannteKategorien:)``.
@Generable
struct KategorieMatchVorschlag {
    @Guide(description: "Name der am besten passenden bestehenden Kategorie, oder ein leerer String, falls keine davon wirklich passt")
    var passendeKategorie: String
}

/// Von der lokalen Apple-KI vorgeschlagene, am besten passende bestehende
/// ``Artikel``-Zuordnung für einen auf einem Kassenbon erkannten Namen — siehe
/// ``AISuggestionService/artikelMatch(fuerName:bekannteArtikel:)``.
@Generable
struct ArtikelMatchVorschlag {
    @Guide(description: "Name des am besten passenden bestehenden Artikels, oder ein leerer String, falls keiner wirklich passt")
    var passenderArtikel: String
}

/// Von der lokalen Apple-KI vorgeschlagener, menschenlesbarer Klarname für ein auf
/// einem Kassenbon erkanntes Produkt — siehe
/// ``AISuggestionService/produktKlarname(fuerErkannterName:bekannteKlarnamen:)``
/// (GitHub #121).
@Generable
struct ProduktKlarnameVorschlag {
    @Guide(description: "Menschenlesbarer Klarname des Produkts — bevorzugt aus den bekannten Namen, sonst ein neu formulierter allgemeinverständlicher Name")
    var klarname: String
}

/// Von der lokalen Apple-KI vorgeschlagene, am besten passende bereits bekannte
/// ``Geschaeft``-Adresse für eine oder mehrere auf einem Kassenbon erkannte Adressen —
/// siehe ``AISuggestionService/adressMatch(fuerAdressen:bekannteAdressen:)`` (GitHub #132).
@Generable
struct AdressMatchVorschlag {
    @Guide(description: "Die am besten passende bekannte Adresse, oder ein leerer String, falls keine wirklich passt")
    var passendeAdresse: String
}

/// Ein von der lokalen Apple-KI erkanntes Paar potenziell zusammengehöriger
/// Artikelnamen — siehe
/// ``AISuggestionService/artikelBeziehungsVorschlaege(fuerArtikelNamen:)``
/// (GitHub #133).
@Generable
struct ArtikelBeziehungsVorschlag {
    @Guide(description: "Name des primären Artikels, der bestehen bleiben soll")
    var primaerName: String
    @Guide(description: "Name des verwandten Artikels, der aufgelöst werden könnte")
    var verwandterName: String
    @Guide(description: "true, wenn beide Namen dasselbe generische Ding meinen (Duplikat); false, wenn verwandterName eher eine konkrete Marke/Variante des primären Artikels ist")
    var istDuplikat: Bool
    @Guide(description: "Kurze Begründung des Vorschlags")
    var begruendung: String
}

/// Container für die Liste der ``ArtikelBeziehungsVorschlag``e — FoundationModels
/// generiert kein `@Generable`-Array direkt als Top-Level-Ergebnistyp, daher
/// dieselbe Wrapper-Struktur wie ``AbteilungsVorschlag/kategorieNamen``.
@Generable
struct ArtikelBeziehungsVorschlaege {
    var vorschlaege: [ArtikelBeziehungsVorschlag]
}
