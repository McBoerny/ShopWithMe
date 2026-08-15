import Foundation
import UIKit
import Testing
@testable import ShopWithMe

// MARK: - Fixture-Format

/// Soll-Zustand für einen Beleg-Testfall.
///
/// Je Testfall liegen zwei Dateien mit identischem Basisnamen im Ordner
/// `ShopWithMeTests/Belege/` im Test-Bundle:
/// - `<name>.jpg/.jpeg/.png` — Foto des Kassenbons
/// - `<name>.json` — diese Struktur
///
/// Ausführliche Dokumentation: `ShopWithMeTests/Belege/README.md` sowie
/// `docs/BELEGSCAN.md` → „Test-Infrastruktur".
struct BelegFixture: Codable, Sendable {
    let beschreibung: String
    let sollErgebnis: SollErgebnis
    /// Mindest-Anteil erkannter Positionen (0.0–1.0). Default 0.75.
    let mindestPositionenTrefferQuote: Double

    struct SollErgebnis: Codable, Sendable {
        /// Erwarteter Geschäftsname. Leer → wird nicht geprüft.
        let geschaeftName: String
        /// Erwartetes Datum im Format `JJJJ-MM-TT`. Leer → wird nicht geprüft.
        let datum: String
        let positionen: [SollPosition]
    }

    struct SollPosition: Codable, Sendable {
        let artikelName: String
        /// Einzelpreis mit `.` als Dezimaltrennzeichen, z.B. `"1.29"`.
        let einzelpreis: String
    }
}

// MARK: - Testfall

private class _BundleLocator {}

/// Ein geladener Testfall: Bild-URL + Soll-Zustand aus dem Test-Bundle.
struct BelegTestfall: Sendable, CustomTestStringConvertible {
    let name: String
    let bildURL: URL
    let fixture: BelegFixture

    var testDescription: String { "\(name) – \(fixture.beschreibung)" }

    var bild: UIImage {
        UIImage(contentsOfFile: bildURL.path) ?? UIImage()
    }

    /// Lädt alle gültigen Testfälle aus `Belege/` im Test-Bundle.
    /// Gibt eine leere Liste zurück, wenn der Ordner fehlt oder keine passenden
    /// Bild+JSON-Paare enthält — Tests laufen dann 0-mal ohne Fehler.
    static func ladeAlle() -> [BelegTestfall] {
        let bundle = Bundle(for: _BundleLocator.self)
        guard let belegeURL = bundle.url(forResource: "Belege", withExtension: nil) else {
            return []
        }
        guard let dateien = try? FileManager.default.contentsOfDirectory(
            at: belegeURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        let bildEndungen: Set<String> = ["jpg", "jpeg", "png"]
        return dateien
            .filter { bildEndungen.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { bildURL in
                let baseName = bildURL.deletingPathExtension().lastPathComponent
                let jsonURL = belegeURL.appendingPathComponent(baseName + ".json")
                guard
                    let jsonDaten = try? Data(contentsOf: jsonURL),
                    let fixture = try? JSONDecoder().decode(BelegFixture.self, from: jsonDaten)
                else { return nil }
                return BelegTestfall(name: baseName, bildURL: bildURL, fixture: fixture)
            }
    }
}

// MARK: - Tests

struct BelegScanIntegrationTests {

    // MARK: OCR-Stufe (deterministisch, läuft auf Simulator + Gerät)

    /// Prüft, ob Vision-OCR für jeden Soll-Artikel mindestens seinen Namen **oder**
    /// seinen Preis irgendwo im erkannten Text findet.
    ///
    /// Dieser Test läuft ohne Apple Intelligence und ist deterministisch — er sichert,
    /// dass der Kassenbon grundsätzlich lesbar ist und die Schlüsseldaten nicht durch
    /// OCR verloren gehen, bevor sie die KI-Extraktion erreichen.
    @Test("OCR erkennt Namen/Preise aller Soll-Positionen", arguments: BelegTestfall.ladeAlle())
    func ocrErkenntPositionen(testfall: BelegTestfall) throws {
        let scanner = VisionFoundationModelsReceiptScanner()
        let zeilen = try scanner.erkenneText(in: testfall.bild)
        #expect(!zeilen.isEmpty, "OCR lieferte keine Zeilen für Testfall „\(testfall.name)"")

        for sollPos in testfall.fixture.sollErgebnis.positionen {
            // Preis: sowohl "1.29" als auch "1,29" prüfen
            let preisUS = sollPos.einzelpreis
            let preisDE = sollPos.einzelpreis.replacingOccurrences(of: ".", with: ",")

            let namenTreffer = zeilen.contains {
                $0.text.localizedCaseInsensitiveContains(sollPos.artikelName) ||
                sollPos.artikelName.localizedCaseInsensitiveContains($0.text)
            }
            let preisTreffer = zeilen.contains {
                $0.text.contains(preisUS) || $0.text.contains(preisDE)
            }
            #expect(
                namenTreffer || preisTreffer,
                "OCR-Text enthält weder Name „\(sollPos.artikelName)" " +
                "noch Preis „\(sollPos.einzelpreis)" für Testfall „\(testfall.name)""
            )
        }
    }

    // MARK: Vollständige Pipeline (Apple Intelligence erforderlich)

    /// Prüft die vollständige Scan-Pipeline (OCR + KI-Extraktion) gegen den
    /// Soll-Zustand mit konfigurierbarer Mindest-Trefferquote.
    ///
    /// Läuft nur auf einem Gerät mit Apple Intelligence — ohne KI wird der Test still
    /// übersprungen. Nicht deterministisch: das Sprachmodell kann bei identischem
    /// Eingabe-Text leicht unterschiedliche Ergebnisse liefern. Die Trefferquote
    /// aus der Fixture-Datei puffert diese Varianz ab.
    @Test("Vollständiger Scan erreicht Mindest-Trefferquote", arguments: BelegTestfall.ladeAlle())
    func vollstaendigerScanErreichtMindestTrefferquote(testfall: BelegTestfall) async throws {
        guard AISuggestionService.istVerfuegbar else { return }

        let scanner = VisionFoundationModelsReceiptScanner()
        let scanErgebnis = try await scanner.auswerten(bild: testfall.bild)
        let ist = scanErgebnis.ergebnis
        let soll = testfall.fixture.sollErgebnis

        // Datum (falls angegeben)
        if !soll.datum.isEmpty {
            #expect(
                ist.datum == soll.datum,
                "Erkanntes Datum „\(ist.datum)" ≠ Soll „\(soll.datum)" für „\(testfall.name)""
            )
        }

        // Geschäftsname (Teilstring-Abgleich in beide Richtungen, falls angegeben)
        if !soll.geschaeftName.isEmpty {
            let namePasst =
                ist.geschaeftName.localizedCaseInsensitiveContains(soll.geschaeftName) ||
                soll.geschaeftName.localizedCaseInsensitiveContains(ist.geschaeftName)
            #expect(
                namePasst,
                "Erkannter Geschäftsname „\(ist.geschaeftName)" ≠ Soll „\(soll.geschaeftName)" " +
                "für „\(testfall.name)""
            )
        }

        // Positionen: Preis-exakt (Cent) ODER Namens-Teilstring
        let erkannt = soll.positionen.filter { sollPos in
            let sollPreis = Decimal(string: sollPos.einzelpreis)?.aufCentGerundet
            return ist.positionen.contains { istPos in
                let preisPasst = sollPreis != nil &&
                    istPos.einzelpreis.aufCentGerundet == sollPreis
                let namePasst =
                    istPos.artikelName.localizedCaseInsensitiveContains(sollPos.artikelName) ||
                    sollPos.artikelName.localizedCaseInsensitiveContains(istPos.artikelName)
                return preisPasst || namePasst
            }
        }

        let quote = soll.positionen.isEmpty
            ? 1.0
            : Double(erkannt.count) / Double(soll.positionen.count)
        let mindest = testfall.fixture.mindestPositionenTrefferQuote

        #expect(
            quote >= mindest,
            "Trefferquote \(Int(quote * 100)) % < Mindest-\(Int(mindest * 100)) % " +
            "(\(erkannt.count)/\(soll.positionen.count) Positionen erkannt) für „\(testfall.name)""
        )
    }
}
