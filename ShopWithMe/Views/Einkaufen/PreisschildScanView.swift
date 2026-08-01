import SwiftUI
import SwiftData
import PhotosUI

/// Scannt das Foto eines einzelnen Preisschilds im Regal und legt dafür sofort
/// einen ``Preispunkt`` mit heutigem Datum an — unabhängig von einem tatsächlichen
/// Kauf, um Preise auch ohne späteren Belegscan (z.B. beim Preisvergleich vor dem
/// Kauf) in der Preishistorie zu erfassen.
///
/// Anders als ``BelegScanView`` gibt es hier nur eine einzelne Position ohne
/// Mengenangabe (ein Preisschild zeigt keine Stückzahl) und kein vom Beleg
/// erkanntes Datum — das Erfassungsdatum ist immer der Scan-Zeitpunkt. Die
/// Mitlern-Logik (``ArtikelAlias/passend(fuerErkannterName:in:)``,
/// ``ArtikelAlias/alternativerName``) entspricht ansonsten dem Belegscan, siehe
/// `docs/PREISSCHILD_SCAN.md`.
///
/// Funktioniert immer direkt für ein feststehendes ``Geschaeft`` (aus
/// ``GeschaeftDetailView`` oder ``EinkaufenView`` bei bereits gewähltem Geschäft) —
/// anders als der Belegscan gibt es hier keinen geschäftslosen Einstieg mit
/// automatischer Geschäftserkennung, da ein Preisschild so gut wie nie den
/// Geschäftsnamen zeigt (siehe `docs/PREISSCHILD_SCAN.md`).
struct PreisschildScanView: View {
    let geschaeft: Geschaeft

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var ausgewaehltesFoto: PhotosPickerItem?
    @State private var zeigeKamera = false
    @State private var laeuft = false
    @State private var fehlermeldung: String?
    @State private var bearbeitbarePosition: BearbeitbarePreisschildPosition?
    /// Zeigt eine Rückfrage, bevor ``bearbeitbarePosition`` beim Abbrechen verworfen
    /// wird — siehe ``abbrechenGetappt()``.
    @State private var zeigeAbbruchBestaetigung = false

    private let scanner: PriceTagScanService = VisionFoundationModelsPriceTagScanner()

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
    }

    var body: some View {
        NavigationStack {
            Group {
                if let bearbeitbarePosition {
                    ErgebnisAnsicht(
                        position: Binding(
                            get: { bearbeitbarePosition },
                            set: { self.bearbeitbarePosition = $0 }
                        ),
                        uebernehmen: uebernehmen
                    )
                } else {
                    AufnahmeAnsicht(
                        laeuft: laeuft,
                        fehlermeldung: fehlermeldung,
                        geschaeftName: geschaeft.name,
                        ausgewaehltesFoto: $ausgewaehltesFoto,
                        kameraOeffnen: { zeigeKamera = true }
                    )
                }
            }
            .navigationTitle("Preisschild scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { abbrechenGetappt() }
                }
            }
        }
        .confirmationDialog(
            "Scan verwerfen?",
            isPresented: $zeigeAbbruchBestaetigung,
            titleVisibility: .visible
        ) {
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) {}
        } message: {
            Text("Die erkannte Position wird nicht übernommen.")
        }
        .sheet(isPresented: $zeigeKamera) {
            KameraAufnahmeView { bild in
                zeigeKamera = false
                verarbeite(bild: bild)
            }
        }
        .onChange(of: ausgewaehltesFoto) { _, neuesFoto in
            guard let neuesFoto else { return }
            Task {
                if let daten = try? await neuesFoto.loadTransferable(type: Data.self),
                   let bild = UIImage(data: daten) {
                    verarbeite(bild: bild)
                }
            }
        }
    }

    private func verarbeite(bild: UIImage) {
        laeuft = true
        fehlermeldung = nil
        Task {
            defer { laeuft = false }
            do {
                let ergebnis = try await scanner.auswerten(bild: bild)
                let bekannteAliase = (try? modelContext.fetch(FetchDescriptor<ArtikelAlias>())) ?? []
                let gelernt = ArtikelAlias.passend(
                    fuerErkannterName: ergebnis.artikelName,
                    in: bekannteAliase
                )
                // Tages-Kollisionsprüfung (GitHub #76-Folgearbeit), siehe
                // ``BelegScanView`` für dasselbe Muster.
                var bestehenderPreisHeute: Decimal?
                if let artikel = gelernt?.artikel {
                    bestehenderPreisHeute = PreispunktService.vorhandenerPunktHeute(
                        artikel: artikel, geschaeft: geschaeft, amDatum: .now, context: modelContext
                    )?.preis
                    if bestehenderPreisHeute == ergebnis.preis { bestehenderPreisHeute = nil }
                }
                bearbeitbarePosition = BearbeitbarePreisschildPosition(
                    erkannterName: ergebnis.artikelName,
                    artikelName: gelernt?.alias ?? ergebnis.artikelName,
                    preisText: "\(ergebnis.preis.aufCentGerundet)",
                    gelernterArtikel: gelernt?.artikel,
                    bestehenderPreisHeute: bestehenderPreisHeute
                )
            } catch {
                fehlermeldung = error.localizedDescription
            }
        }
    }

    /// Reaktion auf den „Abbrechen“-Button: analog
    /// ``BelegScanView/abbrechenGetappt()`` — Rückfrage nur, wenn bereits eine
    /// Position zur Prüfung vorliegt.
    private func abbrechenGetappt() {
        if bearbeitbarePosition != nil {
            zeigeAbbruchBestaetigung = true
        } else {
            dismiss()
        }
    }

    private func uebernehmen() {
        guard let bearbeitbarePosition else { return }
        // Nur die Identitäten über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — zwischen jetzt und dem Micro-Lease-Erwerb kann
        // ein nebenläufiger Sync-Zyklus Geschäft oder gelernten Artikel (per
        // Tombstone eines Peers) gelöscht haben.
        let geschaeftReferenz = ModelReference(geschaeft)
        let gelernterArtikelReferenz = ModelReference(bearbeitbarePosition.gelernterArtikel)
        Task {
            let name = bearbeitbarePosition.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let erkannterName = bearbeitbarePosition.erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let preis = Decimal(string: bearbeitbarePosition.preisText.replacingOccurrences(of: ",", with: "."))
            else { return }

            // Diskrete Einzelaktion → ein Micro-Lease (siehe
            // `docs/DATABASE_CONCURRENCY.md` → „Vollständiger Schreibvorgang-Katalog“).
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                // Ist das Geschäft inzwischen gelöscht, gibt es nichts mehr,
                // dem sich diese Position sinnvoll zuordnen ließe.
                guard let geschaeftFrisch = geschaeftReferenz.resolved(in: modelContext) else { return }
                let artikel = gelernterArtikelReferenz?.resolved(in: modelContext) ?? passendesArtikel(fuer: name)
                let produktName: String? = erkannterName.isEmpty ? nil : erkannterName
                let alternativerName = leiteAlternativenNamenAb(eingegeben: name, erkannt: erkannterName)

                let behalteBestehenden = bearbeitbarePosition.bestehenderPreisHeute != nil
                    && bearbeitbarePosition.behalteBestehendenPreisHeute
                if bearbeitbarePosition.bestehenderPreisHeute != nil, !behalteBestehenden,
                   let vorhandenerPunkt = PreispunktService.vorhandenerPunktHeute(
                       artikel: artikel, geschaeft: geschaeftFrisch, amDatum: .now, context: modelContext
                   ) {
                    PreispunktService.ersetzeVorhandenenPunkt(vorhandenerPunkt, context: modelContext)
                }
                if !behalteBestehenden {
                    PreispunktService.erfassen(
                        preis: preis, artikel: artikel, geschaeft: geschaeftFrisch, datum: .now,
                        produktName: produktName, alternativerName: alternativerName, nameFallback: name, context: modelContext
                    )
                }
                ArtikelAlias.lernen(erkannterName: erkannterName, alternativerName: alternativerName, artikel: artikel, context: modelContext)
            }
            dismiss()
        }
    }

    /// Wie ``BelegScanView/leiteAlternativenNamenAb(eingegeben:erkannt:)``: nur
    /// gesetzt, wenn der Anwender den erkannten Namen zwecks Zuordnung geändert hat.
    private func leiteAlternativenNamenAb(eingegeben: String, erkannt: String) -> String? {
        guard !erkannt.isEmpty, eingegeben.localizedCaseInsensitiveCompare(erkannt) != .orderedSame else { return nil }
        return eingegeben
    }

    /// Sucht unter allen vorhandenen Artikeln einen, dessen Name zum erkannten
    /// Preisschild-Text passt, damit der neue ``Preispunkt`` in der Preishistorie
    /// dieses ``Artikel``s auftaucht statt nur als Namens-Schnappschuss zu existieren.
    private func passendesArtikel(fuer name: String) -> Artikel? {
        let alleArtikel = (try? modelContext.fetch(FetchDescriptor<Artikel>())) ?? []
        return alleArtikel.first {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }
    }
}

/// Eine editierbare Kopie der erkannten Preisschild-Position, solange der Anwender
/// sie noch prüfen/korrigieren kann — siehe ``BearbeitbarePosition`` in
/// ``BelegScanView`` für das analoge Konzept beim Belegscan.
private struct BearbeitbarePreisschildPosition {
    let erkannterName: String
    var artikelName: String
    var preisText: String
    var gelernterArtikel: Artikel?
    /// Siehe ``BearbeitbarePosition/bestehenderPreisHeute`` in ``BelegScanView``.
    var bestehenderPreisHeute: Decimal? = nil
    /// Siehe ``BearbeitbarePosition/behalteBestehendenPreisHeute`` in ``BelegScanView``.
    var behalteBestehendenPreisHeute = false
}

/// Aufforderung, ein Preisschild-Foto aufzunehmen oder aus der Mediathek zu wählen.
private struct AufnahmeAnsicht: View {
    let laeuft: Bool
    let fehlermeldung: String?
    let geschaeftName: String
    @Binding var ausgewaehltesFoto: PhotosPickerItem?
    let kameraOeffnen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if laeuft {
                ProgressView("Preisschild wird ausgewertet…")
            } else {
                ContentUnavailableView {
                    Label("Preisschild scannen", systemImage: "text.viewfinder")
                } description: {
                    Text("Fotografiere ein Preisschild im Regal von „\(geschaeftName)“ oder wähle ein Foto aus deiner Mediathek.")
                } actions: {
                    VStack(spacing: 12) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Foto aufnehmen", action: kameraOeffnen)
                                .buttonStyle(.glass)
                        }
                        PhotosPicker("Aus Fotomediathek wählen", selection: $ausgewaehltesFoto, matching: .images)
                            .buttonStyle(.glass)
                    }
                }
                if let fehlermeldung {
                    Text(fehlermeldung)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }
}

/// UIKit-Brücke für die Kamera-Aufnahme eines Preisschild-Fotos.
private struct KameraAufnahmeView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let bild = info[.originalImage] as? UIImage {
                onImage(bild)
            }
        }
    }
}

/// Editierbare Einzelposition zur Kontrolle vor dem Übernehmen.
private struct ErgebnisAnsicht: View {
    @Binding var position: BearbeitbarePreisschildPosition
    let uebernehmen: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Artikel", text: $position.artikelName)
                    Spacer()
                    TextField("Preis", text: $position.preisText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("€")
                        .foregroundStyle(.secondary)
                }
                if let artikel = position.gelernterArtikel {
                    Label("Wird verknüpft mit „\(artikel.name)“", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let bestehenderPreisHeute = position.bestehenderPreisHeute {
                    TagesKollisionZeile(
                        bestehenderPreis: bestehenderPreisHeute,
                        behalteBestehenden: $position.behalteBestehendenPreisHeute
                    )
                }
            } header: {
                Text("Erkanntes Preisschild")
            } footer: {
                Text("Prüfe Name und Preis, bevor du übernimmst. Bereits bekannte Produkte werden automatisch dem passenden Artikel zugeordnet.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Preis übernehmen", action: uebernehmen)
                .buttonStyle(.glass)
                .padding()
        }
    }
}
