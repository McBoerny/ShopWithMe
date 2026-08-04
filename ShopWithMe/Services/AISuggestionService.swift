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
    /// genutzt von ``ArtikelZuordnungsService/zuordnen(erkannterName:bekannterVerlauf:alleArtikel:)``
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
