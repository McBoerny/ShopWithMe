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
/// `docs/BELEGSCAN.md` -> "Test-Infrastruktur".
struct BelegFixture: Codable, Sendable {
    let beschreibung: String
    let sollErgebnis: SollErgebnis
    /// Mindest-Anteil erkannter Positionen (0.0-1.0). Default 0.75.
    let mindestPositionenTrefferQuote: Double

    struct SollErgebnis: Codable, Sendable {
        /// Erwarteter Geschaeftsname. Leer -> wird nicht geprueft.
        let geschaeftName: String
        /// Erwartete Adresse aus Kopf-/Fusszeile (Teilstring-Abgleich). Leer -> wird nicht geprueft.
        let geschaeftAdresse: String
        /// Erwartetes Datum im Format JJJJ-MM-TT. Leer -> wird nicht geprueft.
        let datum: String
        let positionen: [SollPosition]
    }

    struct SollPosition: Codable, Sendable {
        let artikelName: String
        /// Einzelpreis mit '.' als Dezimaltrennzeichen, z.B. "1.29".
        let einzelpreis: String
        /// Erwartete Menge/Stueckzahl. nil oder weggelassen -> wird nicht geprueft.
        /// Relevant fuer Belege mit Gesamtpreiszeilen (z.B. "3 x Milch 4.50"),
        /// wo die KI die Menge benoetigt um den Einzelpreis zu berechnen.
        let menge: Double?
    }
}

// MARK: - Testfall

private class _BundleLocator {}

/// Ein geladener Testfall: Bild-URL + Soll-Zustand aus dem Test-Bundle.
struct BelegTestfall: Sendable, CustomTestStringConvertible {
    let name: String
    let bildURL: URL
    let fixture: BelegFixture

    var testDescription: String { "\(name) - \(fixture.beschreibung)" }

    var bild: UIImage {
        UIImage(contentsOfFile: bildURL.path) ?? UIImage()
    }

    /// Laedt alle gueltigen Testfaelle aus `Belege/` im Test-Bundle.
    /// Gibt eine leere Liste zurueck, wenn der Ordner fehlt oder keine passenden
    /// Bild+JSON-Paare enthaelt -- Tests laufen dann 0-mal ohne Fehler.
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

    // MARK: OCR-Stufe (deterministisch, laeuft auf Simulator + Geraet)

    /// Prueft, ob Vision-OCR fuer jeden Soll-Artikel mindestens seinen Namen ODER
    /// seinen Preis irgendwo im erkannten Text findet.
    ///
    /// Dieser Test laeuft ohne Apple Intelligence und ist deterministisch -- er sichert,
    /// dass der Kassenbon grundsaetzlich lesbar ist und die Schluessel-Daten nicht durch
    /// OCR verloren gehen, bevor sie die KI-Extraktion erreichen.
    @Test("OCR erkennt Namen/Preise aller Soll-Positionen", arguments: BelegTestfall.ladeAlle())
    func ocrErkenntPositionen(testfall: BelegTestfall) throws {
        let scanner = VisionFoundationModelsReceiptScanner()
        let zeilen = try scanner.erkenneText(in: testfall.bild)
        #expect(!zeilen.isEmpty, "OCR lieferte keine Zeilen fuer Testfall '\(testfall.name)'")

        for sollPos in testfall.fixture.sollErgebnis.positionen {
            // Preis: sowohl "1.29" als auch "1,29" pruefen
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
                "OCR-Text enthaelt weder Name '\(sollPos.artikelName)' noch Preis '\(sollPos.einzelpreis)' [Testfall: \(testfall.name)]"
            )
        }
    }

    // MARK: Vollstaendige Pipeline (Apple Intelligence erforderlich)

    /// Prueft die vollstaendige Scan-Pipeline (OCR + KI-Extraktion) gegen den
    /// Soll-Zustand mit konfigurierbarer Mindest-Trefferquote.
    ///
    /// Laeuft nur auf einem Geraet mit Apple Intelligence -- ohne KI wird der Test still
    /// uebersprungen. Nicht deterministisch: das Sprachmodell kann bei identischem
    /// Eingabe-Text leicht unterschiedliche Ergebnisse liefern. Die Trefferquote
    /// aus der Fixture-Datei puffert diese Varianz ab.
    @Test("Vollstaendiger Scan erreicht Mindest-Trefferquote", arguments: BelegTestfall.ladeAlle())
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
                "Erkanntes Datum '\(ist.datum)' != Soll '\(soll.datum)' [Testfall: \(testfall.name)]"
            )
        }

        // Geschaeftsname (Teilstring-Abgleich in beide Richtungen, falls angegeben)
        if !soll.geschaeftName.isEmpty {
            let namePasst =
                ist.geschaeftName.localizedCaseInsensitiveContains(soll.geschaeftName) ||
                soll.geschaeftName.localizedCaseInsensitiveContains(ist.geschaeftName)
            #expect(
                namePasst,
                "Erkannter Geschaeftsname '\(ist.geschaeftName)' != Soll '\(soll.geschaeftName)' [Testfall: \(testfall.name)]"
            )
        }

        // Adresse (Teilstring-Abgleich in beide Richtungen, falls angegeben)
        if !soll.geschaeftAdresse.isEmpty {
            let adressePasst =
                ist.geschaeftAdresse.localizedCaseInsensitiveContains(soll.geschaeftAdresse) ||
                soll.geschaeftAdresse.localizedCaseInsensitiveContains(ist.geschaeftAdresse)
            #expect(
                adressePasst,
                "Erkannte Adresse '\(ist.geschaeftAdresse)' != Soll '\(soll.geschaeftAdresse)' [Testfall: \(testfall.name)]"
            )
        }

        // Positionen: Preis-exakt (Cent) ODER Namens-Teilstring
        // Pro gefundener Position wird zusaetzlich die Menge geprueft (falls im Fixture angegeben).
        var erkannt = 0
        for sollPos in soll.positionen {
            let sollPreis = Decimal(string: sollPos.einzelpreis)?.aufCentGerundet
            let treffer = ist.positionen.first { istPos in
                let preisPasst = sollPreis != nil &&
                    istPos.einzelpreis.aufCentGerundet == sollPreis
                let namePasst =
                    istPos.artikelName.localizedCaseInsensitiveContains(sollPos.artikelName) ||
                    sollPos.artikelName.localizedCaseInsensitiveContains(istPos.artikelName)
                return preisPasst || namePasst
            }
            if treffer != nil { erkannt += 1 }

            // Menge nur pruefen wenn Position gefunden und Soll-Menge angegeben
            if let istPos = treffer, let sollMenge = sollPos.menge {
                #expect(
                    abs(istPos.menge - sollMenge) < 0.001,
                    "Menge \(istPos.menge) != Soll \(sollMenge) fuer '\(sollPos.artikelName)' [Testfall: \(testfall.name)]"
                )
            }
        }

        let quote = soll.positionen.isEmpty
            ? 1.0
            : Double(erkannt) / Double(soll.positionen.count)
        let mindest = testfall.fixture.mindestPositionenTrefferQuote

        #expect(
            quote >= mindest,
            "Trefferquote \(Int(quote * 100))% < Mindest-\(Int(mindest * 100))% (\(erkannt)/\(soll.positionen.count) Positionen erkannt) [Testfall: \(testfall.name)]"
        )
    }
}
