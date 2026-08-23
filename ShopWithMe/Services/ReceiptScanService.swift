import Foundation
import Vision
import FoundationModels
import UIKit

/// Eine einzelne, aus einem Kassenbon extrahierte Position.
///
/// Kassenbons weisen bei mehreren Stück oft nur den Gesamtpreis der Zeile aus (z.B.
/// "3 x 1.50 = 4.50"). Da ``BelegScanView`` nur den ``einzelpreis`` in die
/// Preishistorie übernimmt, hält dieser Typ ``menge`` separat, damit das Modell die
/// Rechnung (Gesamtpreis ÷ Menge) nachvollziehbar in einem eigenen Feld ablegt statt
/// sie unsichtbar in einem einzelnen Preisfeld zu vermischen.
@Generable
struct BelegPosition {
    @Guide(description: "Artikelname wie auf dem Kassenbon, ohne Mengenangabe oder Artikelnummer")
    var artikelName: String
    @Guide(description: "Menge dieser Position. Norma/Lidl/Penny-Format: Folgezeile direkt unter dem Artikel, z.B. Artikelzeile gefolgt von \"2 x 1,49\" bedeutet menge=2. Prefix-Format: \"2x Artikel 2,98\" bedeutet menge=2. Gewichtsangabe: \"0,5 kg\" bedeutet menge=0.5. Ohne jede Mengenangabe auf dem Bon: 1 angeben.")
    var menge: Double
    @Guide(description: "Einzelpreis (Preis pro Stueck/Einheit) in Euro, z.B. 2.49. Erscheint nach einem Artikel eine Folgezeile der Form N x P (z.B. \"2 x 1,49\"), ist P der Einzelpreis und N die Menge — niemals den Gesamtpreis einer Mengenposition uebernehmen.")
    var einzelpreis: Decimal
}

/// Ergebnis der Belegauswertung.
@Generable
struct BelegErgebnis {
    @Guide(description: "Name des Geschäfts, falls auf dem Bon erkennbar, sonst ein leerer String")
    var geschaeftName: String
    @Guide(description: "Alle auf dem Bon vorkommenden, voneinander unterscheidbaren Adressen (Strassenname und -abkuerzung genau wie auf dem Bon, Hausnummer, Postleitzahl, Ort) — typischerweise die Filialadresse in der Kopfzeile und/oder die Betreiber-/Zentraladresse im Kleingedruckten der Fusszeile. Postleitzahl je Adresse einschliessen wenn vorhanden. Abkuerzungen nicht aendern. Doppelte Adressen nicht wiederholen. Leeres Array, falls keine erkennbar.")
    var geschaeftAdressen: [String]
    @Guide(description: "Datum des Einkaufs im Format JJJJ-MM-TT (z.B. 2026-03-24), falls auf dem Bon erkennbar, sonst ein leerer String")
    var datum: String
    @Guide(description: "Alle erkannten Artikelpositionen mit Menge und Einzelpreis, ohne Zwischensummen/Pfand/MwSt.-Zeilen")
    var positionen: [BelegPosition]
}

extension BelegErgebnis {
    private static let datumsParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Das erkannte ``datum`` als geparstes ``Date``, oder `nil`, falls der Bon kein
    /// Datum erkennen ließ oder die KI kein gültiges `JJJJ-MM-TT`-Format geliefert hat.
    var erkanntesDatum: Date? {
        Self.datumsParser.date(from: datum)
    }
}

/// Eine von Vision (OCR) erkannte Textzeile samt ihrer Position im Originalbild.
///
/// `boundingBox` ist Visions normalisiertes Koordinatensystem (0–1, Ursprung unten
/// links) — siehe ``ZoombareBildAnsicht`` für die Umrechnung in Bildschirm-Koordinaten.
struct ErkannteZeile: Equatable {
    let text: String
    let boundingBox: CGRect
}

extension Array where Element == ErkannteZeile {
    /// Findet die ``ErkannteZeile``, deren Text am besten zu `artikelName` passt
    /// (beidseitiger, Groß-/Kleinschreibung ignorierender Teilstring-Abgleich, analog
    /// `BelegScanView.passtZu`/`passendesArtikel`) — oder `nil`, wenn keine Zeile
    /// passt. Grundlage für die Positions-Markierung im Original-Beleg
    /// (`docs/BELEGSCAN.md`).
    ///
    /// Die umgekehrte Richtung (`artikelName` enthält den Zeilentext) verlangt
    /// mindestens 3 Zeichen Zeilentext — sonst matchen sehr kurze, generische
    /// OCR-Fragmente (einzelne Ziffern, Trennzeichen) fast jeden Artikelnamen und
    /// liefern für jede Position dieselbe (meist erste) Zeile zurück, statt für
    /// jeden Preis eine eigene, korrekte Markierung zu finden (GitHub #17).
    func boundingBox(fuerArtikelName artikelName: String) -> CGRect? {
        first { zeile in
            let text = zeile.text.trimmingCharacters(in: .whitespaces)
            if text.localizedCaseInsensitiveContains(artikelName) { return true }
            return text.count >= 3 && artikelName.localizedCaseInsensitiveContains(text)
        }?.boundingBox
    }

    /// Sortiert nach Leserichtung (oben nach unten, bei gleicher Zeile links nach
    /// rechts) statt Visions Ausgabereihenfolge zu übernehmen — die ist bei gut
    /// ausgerichteten Dokumenten meist schon lesereihenfolge-treu, aber nicht
    /// garantiert, insbesondere bei einer leicht schiefen Aufnahme. Wichtig, weil
    /// ``VisionFoundationModelsReceiptScanner`` die Zeilen als einzelnen
    /// zusammenhängenden Text an das Sprachmodell übergibt — eine durcheinander
    /// geratene Reihenfolge kann Artikelname und Preis unterschiedlicher Zeilen
    /// fälschlich zusammenführen. Visions `boundingBox` hat den Ursprung unten
    /// links, daher absteigend nach `y` (oben zuerst).
    func sortiertInLeserichtung() -> [ErkannteZeile] {
        sorted { erste, zweite in
            erste.boundingBox.origin.y != zweite.boundingBox.origin.y
                ? erste.boundingBox.origin.y > zweite.boundingBox.origin.y
                : erste.boundingBox.origin.x < zweite.boundingBox.origin.x
        }
    }
}

/// Ergebnis eines vollständigen Belegscans: die strukturierten Daten (``BelegErgebnis``)
/// zusammen mit den roh erkannten OCR-Zeilen inkl. Position — letztere ausschließlich
/// dafür, im Original-Beleg auf die erkannte Stelle einer Position zu verweisen
/// (``ErgebnisListe`` in ``BelegScanView``), keine weitere Verwendung.
struct BelegScanErgebnis {
    let ergebnis: BelegErgebnis
    let ocrZeilen: [ErkannteZeile]
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
    func auswerten(bild: UIImage) async throws -> BelegScanErgebnis
}

private extension CGImagePropertyOrientation {
    /// Konvertiert `UIImage.imageOrientation` in Visions Orientierungstyp — die
    /// Rohwerte beider Enums stimmen nicht überein, daher explizite Zuordnung statt
    /// `rawValue`-Cast.
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Belegscan auf Basis von Vision-Texterkennung (OCR) kombiniert mit
/// FoundationModels-Strukturextraktion — beides reale, mit iOS 26 ausgelieferte APIs.
struct VisionFoundationModelsReceiptScanner: ReceiptScanService {
    func auswerten(bild: UIImage) async throws -> BelegScanErgebnis {
        let zeilen = try erkenneText(in: bild)
        let ergebnis = try await extrahiere(aus: zeilen)
        return BelegScanErgebnis(ergebnis: ergebnis, ocrZeilen: zeilen)
    }

    func erkenneText(in bild: UIImage) throws -> [ErkannteZeile] {
        guard let cgImage = bild.cgImage else {
            throw ReceiptScanError.ungueltigesBild
        }

        let anfrage = VNRecognizeTextRequest()
        anfrage.recognitionLevel = .accurate
        anfrage.usesLanguageCorrection = true
        anfrage.recognitionLanguages = ["de-DE", "en-US"]
        // Erkennt auch die kleine Thermodruck-Schrift typischer Kassenbons — ohne
        // diese Untergrenze übersieht Vision manche Positionszeilen auf einem eng
        // beschriebenen, aber vergleichsweise groß eingescannten Beleg.
        anfrage.minimumTextHeight = 0.01

        // Ohne explizite `orientation` interpretiert Vision den rohen, oft gedrehten
        // Kamera-Pixelpuffer — die zurückgegebenen `boundingBox`en passen dann nicht
        // zum per `imageOrientation` korrekt gedreht angezeigten Bild
        // (`Image(uiImage:)`/``ZoombareBildAnsicht``).
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(bild.imageOrientation),
            options: [:]
        )
        try handler.perform([anfrage])

        let zeilen: [ErkannteZeile] = (anfrage.results ?? []).compactMap { beobachtung in
            guard let text = beobachtung.topCandidates(1).first?.string else { return nil }
            return ErkannteZeile(text: text, boundingBox: beobachtung.boundingBox)
        }
        .sortiertInLeserichtung()
        guard !zeilen.isEmpty else {
            throw ReceiptScanError.keinTextErkannt
        }
        return zeilen
    }

    private func extrahiere(aus zeilen: [ErkannteZeile]) async throws -> BelegErgebnis {
        let anweisungen = """
        Du extrahierst Kassenbon-Daten aus rohem OCR-Text einer deutschen \
        Einkaufs-App.

        DATUM: Gib das Kaufdatum im Format JJJJ-MM-TT zurück. \
        Steht das Jahr vierstellig auf dem Bon (z.B. '17.07.2026'), dieses \
        unverändert übernehmen. Zweistellige Jahreszahlen: '26' → 2026.

        GESCHAEFTSNAME: Den Markennamen bevorzugen (z.B. 'hagebaumarkt', \
        'REWE', 'Aldi Süd'), der prominent im Kopf des Bons erscheint. \
        Den Firmennamen des Betreibers (z.B. 'HEV Heimwerkermarkt GmbH \
        & Co.KG') im Kleingedruckten ignorieren.

        ADRESSEN: Anders als beim Geschäftsnamen hier NICHT nur eine \
        Adresse auswählen, sondern alle voneinander unterscheidbaren \
        Adressen zurückgeben. Viele Bons drucken sowohl die Filialadresse \
        (Kopfzeile) als auch die Betreiber-/Zentraladresse (Kleingedrucktes \
        der Fusszeile, oft bei derselben Firma wie unter GESCHAEFTSNAME \
        ignoriert). Beide gehören hier hinein, auch wenn nur eine als \
        Geschäftsname übernommen wurde. Identische Adressen nicht doppelt \
        aufführen.

        MENGEN – besonders wichtig: Viele deutsche Kassenbons (Norma, Lidl, \
        Penny, Netto) drucken die Menge in einer separaten Folgezeile direkt \
        unter der Artikelzeile, z.B.:
          Saftige Stueckchen      1,49 B
          2 x 1,49
        Diese Folgezeile 'N x P' bedeutet: Menge N, Einzelpreis P. Ordne sie \
        immer der unmittelbar vorangehenden Artikelzeile zu und erstelle \
        keine eigene Position dafür. Dasselbe gilt für Formate wie \
        'Nx Artikel GESAMT' (Menge als Prefix) oder Gewichtsangaben.

        EINZELPREISE: Immer den Preis pro Stück/Einheit angeben, nie den \
        Gesamtpreis einer Mengenposition.

        IGNORIEREN: Zwischensummen, Rabattzeilen, Pfand-Sammelzeilen, \
        MwSt.-Hinweise, Zahlungsart, Treuepunkte.
        """
        let text = zeilen.map(\.text).joined(separator: "\n")
        let session = LanguageModelSession(instructions: anweisungen)
        let antwort = try await session.respond(to: text, generating: BelegErgebnis.self)
        return antwort.content
    }
}
