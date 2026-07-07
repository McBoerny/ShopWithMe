import SwiftUI
import SwiftData
import PhotosUI

/// Scannt das Foto eines einzelnen Preisschilds im Regal und legt dafür sofort
/// einen ``KaufEintrag`` mit heutigem Datum an — unabhängig von einem tatsächlichen
/// Kauf, um Preise auch ohne späteren Belegscan (z.B. beim Preisvergleich vor dem
/// Kauf) in der Preishistorie zu erfassen.
///
/// Anders als ``BelegScanView`` gibt es hier nur eine einzelne Position ohne
/// Mengenangabe (ein Preisschild zeigt keine Stückzahl) und kein vom Beleg
/// erkanntes Datum — das Erfassungsdatum ist immer der Scan-Zeitpunkt. Die
/// Mitlern-Logik (``KaufEintrag/gelernteZuordnung(fuerErkannterName:in:)``,
/// ``alternativerName``) entspricht ansonsten dem Belegscan, siehe
/// `docs/PREISSCHILD_SCAN.md`.
///
/// Wird ohne ``vorgegebenesGeschaeft`` gestartet (z.B. nachträglich zuhause, ohne
/// vorher ein Geschäft zu wählen), versucht diese Ansicht das Geschäft nach dem Scan
/// automatisch über ``Geschaeft/passendes(fuerErkannterName:unter:)`` zuzuordnen und
/// fragt sonst über ``GeschaeftWahlSheet`` nach — identisches Verhalten zu
/// ``BelegScanView``, siehe `docs/BELEGSCAN.md` → „Automatischer Geschäfts-Abgleich“.
struct PreisschildScanView: View {
    /// Bereits feststehendes Geschäft, wenn von einer Geschäfts-Detailseite aus
    /// aufgerufen — `nil`, wenn der Scan geschäftslos gestartet wurde.
    let vorgegebenesGeschaeft: Geschaeft?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Geschaeft.name) private var alleGeschaefte: [Geschaeft]

    @State private var ausgewaehltesFoto: PhotosPickerItem?
    @State private var zeigeKamera = false
    @State private var laeuft = false
    @State private var fehlermeldung: String?
    @State private var bearbeitbarePosition: BearbeitbarePreisschildPosition?
    @State private var erkanntesGeschaeft: Geschaeft?
    @State private var erkannterGeschaeftName = ""
    @State private var zeigeGeschaeftWahl = false

    private let scanner: PriceTagScanService = VisionFoundationModelsPriceTagScanner()

    /// Siehe ``BelegScanView/geschaeftAbgleichNoetig``.
    private var geschaeftAbgleichNoetig: Bool { vorgegebenesGeschaeft == nil }

    init(geschaeft: Geschaeft) {
        self.vorgegebenesGeschaeft = geschaeft
    }

    /// Scannt ein Preisschild, ohne vorher ein Geschäft festzulegen — siehe
    /// ``geschaeftAbgleichNoetig``.
    init() {
        self.vorgegebenesGeschaeft = nil
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
                        geschaeftAbgleichNoetig: geschaeftAbgleichNoetig,
                        erkanntesGeschaeft: erkanntesGeschaeft,
                        geschaeftWaehlen: { zeigeGeschaeftWahl = true },
                        uebernehmen: uebernehmen
                    )
                } else {
                    AufnahmeAnsicht(
                        laeuft: laeuft,
                        fehlermeldung: fehlermeldung,
                        geschaeftName: vorgegebenesGeschaeft?.name ?? "",
                        ausgewaehltesFoto: $ausgewaehltesFoto,
                        kameraOeffnen: { zeigeKamera = true }
                    )
                }
            }
            .navigationTitle("Preisschild scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $zeigeKamera) {
            KameraAufnahmeView { bild in
                zeigeKamera = false
                verarbeite(bild: bild)
            }
        }
        .sheet(isPresented: $zeigeGeschaeftWahl) {
            GeschaeftWahlSheet(erkannterName: erkannterGeschaeftName) { gewaehlt in
                erkanntesGeschaeft = gewaehlt
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
                geschaeftAbgleichen(erkannterName: ergebnis.geschaeftName)
                let bekannterVerlauf = (try? modelContext.fetch(FetchDescriptor<KaufEintrag>())) ?? []
                let gelernt = KaufEintrag.gelernteZuordnung(
                    fuerErkannterName: ergebnis.artikelName,
                    in: bekannterVerlauf
                )
                bearbeitbarePosition = BearbeitbarePreisschildPosition(
                    erkannterName: ergebnis.artikelName,
                    artikelName: gelernt?.alias ?? ergebnis.artikelName,
                    preisText: "\(ergebnis.preis)",
                    gelernterArtikel: gelernt?.artikel
                )
            } catch {
                fehlermeldung = error.localizedDescription
            }
        }
    }

    /// Siehe ``BelegScanView/geschaeftAbgleichen(erkannterName:)``.
    private func geschaeftAbgleichen(erkannterName: String) {
        erkannterGeschaeftName = erkannterName
        guard geschaeftAbgleichNoetig else {
            erkanntesGeschaeft = vorgegebenesGeschaeft
            return
        }
        if let treffer = Geschaeft.passendes(fuerErkannterName: erkannterName, unter: alleGeschaefte) {
            erkanntesGeschaeft = treffer
        } else {
            erkanntesGeschaeft = nil
            zeigeGeschaeftWahl = true
        }
    }

    private func uebernehmen() {
        guard let bearbeitbarePosition else { return }
        Task {
            let name = bearbeitbarePosition.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let erkannterName = bearbeitbarePosition.erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let preis = Decimal(string: bearbeitbarePosition.preisText.replacingOccurrences(of: ",", with: "."))
            else { return }

            // Diskrete Einzelaktion → ein Micro-Lease (siehe
            // `docs/DATABASE_CONCURRENCY.md` → „Vollständiger Schreibvorgang-Katalog“).
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if !erkannterGeschaeftName.isEmpty {
                    erkanntesGeschaeft?.alternativenNamenLernen(erkannterGeschaeftName)
                }
                let artikel = bearbeitbarePosition.gelernterArtikel ?? passendesArtikel(fuer: name)
                let neuerEintrag = KaufEintrag(
                    artikel: artikel,
                    geschaeft: erkanntesGeschaeft,
                    kategorie: artikel?.kategorie,
                    preis: preis,
                    datum: .now
                )
                neuerEintrag.artikelNameSnapshot = artikel?.name ?? name
                neuerEintrag.produktName = erkannterName.isEmpty ? nil : erkannterName
                neuerEintrag.alternativerName = leiteAlternativenNamenAb(eingegeben: name, erkannt: erkannterName)
                modelContext.insert(neuerEintrag)
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
    /// Preisschild-Text passt, damit der neue ``KaufEintrag`` in der Preishistorie
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
                    Label("Preisschild scannen", systemImage: "tag.viewfinder")
                } description: {
                    Text(geschaeftName.isEmpty
                         ? "Fotografiere ein Preisschild im Regal oder wähle ein Foto aus deiner Mediathek. Das Geschäft wird nach Möglichkeit automatisch erkannt."
                         : "Fotografiere ein Preisschild im Regal von „\(geschaeftName)“ oder wähle ein Foto aus deiner Mediathek.")
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
    /// Siehe ``BelegScanView/ErgebnisListe``.
    let geschaeftAbgleichNoetig: Bool
    let erkanntesGeschaeft: Geschaeft?
    let geschaeftWaehlen: () -> Void
    let uebernehmen: () -> Void

    var body: some View {
        Form {
            if geschaeftAbgleichNoetig {
                Section {
                    Button(action: geschaeftWaehlen) {
                        HStack {
                            Text("Geschäft")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(erkanntesGeschaeft?.name ?? "Wählen")
                                .foregroundStyle(erkanntesGeschaeft == nil ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(erkanntesGeschaeft == nil
                         ? "Auf dem Foto wurde kein bekanntes Geschäft erkannt — bitte auswählen, damit der Preis diesem Geschäft zugeordnet wird."
                         : "Automatisch erkannt. Bei Bedarf antippen, um ein anderes Geschäft zu wählen.")
                }
            }

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
