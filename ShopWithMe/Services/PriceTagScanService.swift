import Foundation
import Vision
import FoundationModels
import UIKit

/// Ergebnis der Auswertung eines einzelnen, fotografierten Preisschilds.
@Generable
struct PreisschildErgebnis {
    @Guide(description: "Artikelname wie auf dem Preisschild, ohne Mengenangabe, Grundpreis oder Artikelnummer")
    var artikelName: String
    @Guide(description: "Verkaufspreis des Produkts in Euro, z.B. 2.49. Zeigt das Preisschild zusätzlich einen Grundpreis (z.B. „1,99 € / 100g“ oder „3,98 € / kg“), NICHT diesen, sondern ausschließlich den tatsächlichen Verkaufspreis zurückgeben.")
    var preis: Decimal
}

/// Fehler beim Scannen/Auswerten eines Preisschilds.
enum PriceTagScanError: LocalizedError {
    case ungueltigesBild
    case keinTextErkannt

    var errorDescription: String? {
        switch self {
        case .ungueltigesBild:
            return "Das Bild konnte nicht gelesen werden."
        case .keinTextErkannt:
            return "Auf dem Bild wurde kein Text erkannt."
        }
    }
}

/// Wertet das Foto eines einzelnen Preisschilds aus und liefert Artikelname + Preis.
///
/// Hinter einem Protokoll gekapselt, damit eine speziellere, zukünftige
/// On-Device-Scan-API (sobald mit verifizierten APIs verfügbar) ohne UI-Änderungen
/// als Ersatz eingesetzt werden kann (siehe `docs/PREISSCHILD_SCAN.md`).
protocol PriceTagScanService: Sendable {
    func auswerten(bild: UIImage) async throws -> PreisschildErgebnis
}

/// Preisschild-Scan auf Basis von Vision-Texterkennung (OCR) kombiniert mit
/// FoundationModels-Strukturextraktion — dasselbe Muster wie
/// ``VisionFoundationModelsReceiptScanner``, hier auf ein einzelnes Preisschild
/// statt einen ganzen Kassenbon angewendet.
///
/// Das on-device Foundation-Model bekommt dabei kein Bild, sondern ausschließlich
/// den von Vision erkannten Rohtext — die Bildanalyse bleibt vollständig bei Vision
/// (siehe `docs/PREISSCHILD_SCAN.md` zur Abgrenzung gegenüber einem künftigen
/// Mehrfach-Regal-Scan).
struct VisionFoundationModelsPriceTagScanner: PriceTagScanService {
    func auswerten(bild: UIImage) async throws -> PreisschildErgebnis {
        let text = try erkenneText(in: bild)
        return try await extrahiere(aus: text)
    }

    private func erkenneText(in bild: UIImage) throws -> String {
        guard let cgImage = bild.cgImage else {
            throw PriceTagScanError.ungueltigesBild
        }

        let anfrage = VNRecognizeTextRequest()
        anfrage.recognitionLevel = .accurate
        anfrage.usesLanguageCorrection = true
        anfrage.recognitionLanguages = ["de-DE", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([anfrage])

        let zeilen = (anfrage.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !zeilen.isEmpty else {
            throw PriceTagScanError.keinTextErkannt
        }
        return zeilen.joined(separator: "\n")
    }

    private func extrahiere(aus text: String) async throws -> PreisschildErgebnis {
        let anweisungen = """
        Du extrahierst Produktname und Verkaufspreis aus rohem OCR-Text eines \
        einzelnen fotografierten Preisschilds aus einem Supermarktregal. \
        Preisschilder zeigen oft zusätzlich einen Grundpreis (z.B. „1,99 € / 100g“ \
        oder „3,98 € / kg“) — ignoriere diesen und gib ausschließlich den \
        tatsächlichen Verkaufspreis des Produkts zurück. Der Artikelname soll ohne \
        Mengenangabe, Marke-Zusatzcodes oder Artikelnummer erscheinen.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: text, generating: PreisschildErgebnis.self)
        return antwort.content
    }
}
