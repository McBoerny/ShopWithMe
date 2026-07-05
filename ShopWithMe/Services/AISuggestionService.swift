import Foundation
import FoundationModels

/// Von der lokalen Apple-KI (FoundationModels) vorgeschlagene Eigenschaften für einen
/// neu angelegten ``Artikel``.
///
/// `regalName` ist rein informativ: Ein Artikel selbst ist keinem Regal zugeordnet
/// (das geschieht pro Geschäft, siehe ``Regal``) — der Hinweis hilft dem Anwender nur,
/// die Kategorie später im passenden Regal einzusortieren.
@Generable
struct ArtikelVorschlag {
    @Guide(description: "Name einer passenden Artikelkategorie")
    var kategorieName: String
    @Guide(description: "Name eines Regals, in dem diese Kategorie typischerweise zu finden ist, oder ein leerer String, falls nicht ableitbar")
    var regalName: String
}

/// Schlägt beim Anlegen eines Artikels automatisch eine Kategorie und (informativ)
/// ein Regal vor, indem die lokale, on-device Apple-KI (FoundationModels/"Apple
/// Intelligence") befragt wird.
///
/// Ist auf dem Gerät keine Apple Intelligence verfügbar, ist ``istVerfuegbar`` `false`
/// — die aufrufende UI blendet die Funktion dann aus, es gibt keinen Fehlerzustand.
enum AISuggestionService {
    /// Ob auf diesem Gerät ein KI-Vorschlag angefragt werden kann.
    static var istVerfuegbar: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Erzeugt einen ``ArtikelVorschlag`` für den gegebenen Artikelnamen. Bestehende
    /// Kategorie-/Regalnamen werden als Kontext mitgegeben, damit das Modell
    /// bevorzugt vorhandene Werte wiederverwendet statt neue zu erfinden.
    static func vorschlag(
        fuerArtikelName name: String,
        bekannteKategorien: [String],
        bekannteRegale: [String]
    ) async throws -> ArtikelVorschlag {
        let anweisungen = """
        Du hilfst in einer Einkaufs-App dabei, neu angelegte Artikel einzuordnen. \
        Schlage für den genannten Artikel eine passende Artikelkategorie und optional \
        ein Regal vor. Verwende nach Möglichkeit eine dieser bestehenden Kategorien, \
        falls sie passt: \(bekannteKategorien.joined(separator: ", ")). \
        Bekannte Regalnamen: \(bekannteRegale.joined(separator: ", ")).
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: "Artikel: \(name)", generating: ArtikelVorschlag.self)
        return antwort.content
    }
}
