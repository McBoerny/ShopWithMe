import Foundation
import Vision
import FoundationModels
import UIKit

/// Eine einzelne, aus einem Kassenbon extrahierte Position.
///
/// Kassenbons weisen bei mehreren Stück oft nur den Gesamtpreis der Zeile aus (z.B.
/// „3 x 1.50 = 4.50“). Da ``BelegScanView`` nur den ``einzelpreis`` in die
/// Preishistorie übernimmt, hält dieser Typ ``menge`` separat, damit das Modell die
/// Rechnung (Gesamtpreis ÷ Menge) nachvollziehbar in einem eigenen Feld ablegt statt
/// sie unsichtbar in einem einzelnen Preisfeld zu vermischen.
@Generable
struct BelegPosition {
    @Guide(description: "Artikelname wie auf dem Kassenbon, ohne Mengenangabe oder Artikelnummer")
    var artikelName: String
    @Guide(description: "Auf dem Kassenbon angegebene Menge dieser Position, z.B. 3 bei „3 x Milch“ oder 0.5 bei „0,5 kg Äpfel“. Steht keine Menge auf dem Bon, hier 1 angeben.")
    var menge: Double
    @Guide(description: "Einzelpreis (Preis pro Stück/Einheit) dieser Position in Euro, z.B. 2.49. Weist der Bon nur einen Gesamtpreis für mehrere Stück aus (z.B. „3 x 1.50 = 4.50“), hier den Gesamtpreis geteilt durch die Menge angeben — niemals den Gesamtpreis selbst.")
    var einzelpreis: Decimal
}

/// Ergebnis der Belegauswertung.
@Generable
struct BelegErgebnis {
    @Guide(description: "Name des Geschäfts, falls auf dem Bon erkennbar, sonst ein leerer String")
    var geschaeftName: String
    @Guide(description: "Alle erkannten Artikelpositionen mit Menge und Einzelpreis, ohne Zwischensummen/Pfand/MwSt.-Zeilen")
    var positionen: [BelegPosition]
}

/// Fehler beim Scannen/Auswerten eines Kassenbons.
enum ReceiptScanError: LocalizedError {
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

/// Wertet ein Foto eines Kassenbons aus und liefert die erkannten Positionen.
///
/// Hinter einem Protokoll gekapselt, damit eine speziellere, zukünftige
/// On-Device-Beleg-Scan-API (sobald mit verifizierten APIs verfügbar) ohne
/// UI-Änderungen als Ersatz eingesetzt werden kann (siehe `docs/DECISIONS.md`).
protocol ReceiptScanService: Sendable {
    func auswerten(bild: UIImage) async throws -> BelegErgebnis
}

/// Belegscan auf Basis von Vision-Texterkennung (OCR) kombiniert mit
/// FoundationModels-Strukturextraktion — beides reale, mit iOS 26 ausgelieferte APIs.
struct VisionFoundationModelsReceiptScanner: ReceiptScanService {
    func auswerten(bild: UIImage) async throws -> BelegErgebnis {
        let text = try erkenneText(in: bild)
        return try await extrahiere(aus: text)
    }

    private func erkenneText(in bild: UIImage) throws -> String {
        guard let cgImage = bild.cgImage else {
            throw ReceiptScanError.ungueltigesBild
        }

        let anfrage = VNRecognizeTextRequest()
        anfrage.recognitionLevel = .accurate
        anfrage.usesLanguageCorrection = true
        anfrage.recognitionLanguages = ["de-DE", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([anfrage])

        let zeilen = (anfrage.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !zeilen.isEmpty else {
            throw ReceiptScanError.keinTextErkannt
        }
        return zeilen.joined(separator: "\n")
    }

    private func extrahiere(aus text: String) async throws -> BelegErgebnis {
        let anweisungen = """
        Du extrahierst Kassenbon-Daten aus rohem OCR-Text einer deutschen \
        Einkaufs-App. Ignoriere Zwischensummen, Pfand-Sammel-Zeilen, \
        MwSt.-Hinweise und Zahlungsart. Erkenne pro Artikelzeile Name, Menge und \
        Einzelpreis in Euro. Weist eine Zeile nur einen Gesamtpreis für mehrere \
        Stück aus, berechne daraus den Einzelpreis (Gesamtpreis geteilt durch \
        die Menge) statt den Gesamtpreis zu übernehmen.
        """
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: text, generating: BelegErgebnis.self)
        return antwort.content
    }
}
