import SwiftUI
import SwiftData
import PhotosUI

/// Kontext, in dem ein Kassenbon gescannt wird.
///
/// Während eines laufenden ``Einkaufsvorgang``s werden erkannte Preise bereits
/// abgehakten ``KaufEintrag``en zugeordnet (Namensabgleich). Unabhängig davon lässt
/// sich ein Beleg auch direkt für ein ``Geschaeft`` scannen — dort entsteht für jede
/// erkannte Position ein neuer, eigenständiger ``KaufEintrag``, standardmäßig mit dem
/// heutigen Datum (vom Anwender bei Bedarf überschreibbar, siehe ``BelegScanView``).
enum BelegScanKontext {
    case einkaufsvorgang(Einkaufsvorgang)
    case geschaeft(Geschaeft)

    var geschaeft: Geschaeft? {
        switch self {
        case .einkaufsvorgang(let einkaufsvorgang): einkaufsvorgang.geschaeft
        case .geschaeft(let geschaeft): geschaeft
        }
    }
}

/// Scannt einen Kassenbon und trägt die erkannten Einzelpreise als ``KaufEintrag``e
/// ein — siehe ``BelegScanKontext`` für die beiden möglichen Aufrufsituationen.
///
/// Erkannte Positionen, die sich keinem bestehenden ``Artikel`` zuordnen lassen,
/// werden trotzdem als eigenständiger ``KaufEintrag`` ohne ``Artikel``-Verknüpfung
/// gespeichert — der Artikelname bleibt über `artikelNameSnapshot` trotzdem in der
/// Preishistorie lesbar. Kassenbons weisen bei mehreren Stück oft nur einen
/// Gesamtpreis aus; übernommen wird ausschließlich der von der KI berechnete
/// Einzelpreis (siehe ``BelegPosition``), keine Mengenangabe.
///
/// Das Einkaufsdatum wird von der KI aus dem Beleg erkannt (Vorbelegung), lässt sich
/// vor dem Übernehmen aber jederzeit manuell korrigieren (``ErgebnisListe``). Benennt
/// der Anwender eine Position zwecks Zuordnung auf einen bestehenden, ggf.
/// generischen ``Artikel`` um (z.B. „Colgate Total“ → „Zahnpasta“), bleibt der
/// ursprünglich erkannte Produktname über ``KaufEintrag/produktName`` erhalten —
/// so lassen sich verschiedene Marken desselben generischen Artikels weiterhin
/// getrennt in der Preishistorie nachverfolgen.
struct BelegScanView: View {
    let kontext: BelegScanKontext

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var ausgewaehltesFoto: PhotosPickerItem?
    @State private var zeigeKamera = false
    @State private var laeuft = false
    @State private var fehlermeldung: String?
    @State private var bearbeitbarePositionen: [BearbeitbarePosition]?
    @State private var belegDatum: Date

    private let scanner: ReceiptScanService = VisionFoundationModelsReceiptScanner()

    init(einkaufsvorgang: Einkaufsvorgang) {
        self.kontext = .einkaufsvorgang(einkaufsvorgang)
        _belegDatum = State(initialValue: einkaufsvorgang.startZeit)
    }

    init(geschaeft: Geschaeft) {
        self.kontext = .geschaeft(geschaeft)
        _belegDatum = State(initialValue: .now)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let bearbeitbarePositionen {
                    ErgebnisListe(
                        positionen: Binding(
                            get: { bearbeitbarePositionen },
                            set: { self.bearbeitbarePositionen = $0 }
                        ),
                        belegDatum: $belegDatum,
                        uebernehmen: uebernehmen
                    )
                } else {
                    AufnahmeAnsicht(
                        laeuft: laeuft,
                        fehlermeldung: fehlermeldung,
                        geschaeftName: kontext.geschaeft?.name ?? "",
                        ausgewaehltesFoto: $ausgewaehltesFoto,
                        kameraOeffnen: { zeigeKamera = true }
                    )
                }
            }
            .navigationTitle("Beleg scannen")
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
                if let erkanntesDatum = ergebnis.erkanntesDatum {
                    belegDatum = erkanntesDatum
                }
                bearbeitbarePositionen = ergebnis.positionen.map {
                    BearbeitbarePosition(erkannterName: $0.artikelName, artikelName: $0.artikelName, preisText: "\($0.einzelpreis)")
                }
            } catch {
                fehlermeldung = error.localizedDescription
            }
        }
    }

    private func uebernehmen() {
        for position in bearbeitbarePositionen ?? [] {
            let name = position.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let erkannterName = position.erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
            let produktName: String? = erkannterName.isEmpty ? nil : erkannterName
            guard !name.isEmpty,
                  let preis = Decimal(string: position.preisText.replacingOccurrences(of: ",", with: "."))
            else { continue }

            switch kontext {
            case .einkaufsvorgang(let einkaufsvorgang):
                if let vorhandenerEintrag = einkaufsvorgang.kaufEintraege.first(where: { passtZu(name: name, eintrag: $0) }) {
                    vorhandenerEintrag.preis = preis
                    vorhandenerEintrag.datum = belegDatum
                    vorhandenerEintrag.produktName = produktName
                } else {
                    let neuerEintrag = KaufEintrag(
                        artikel: nil,
                        geschaeft: einkaufsvorgang.geschaeft,
                        preis: preis,
                        datum: belegDatum
                    )
                    neuerEintrag.artikelNameSnapshot = name
                    neuerEintrag.produktName = produktName
                    modelContext.insert(neuerEintrag)
                    neuerEintrag.einkaufsvorgang = einkaufsvorgang
                }
            case .geschaeft(let geschaeft):
                let artikel = passendesArtikel(fuer: name)
                let neuerEintrag = KaufEintrag(
                    artikel: artikel,
                    geschaeft: geschaeft,
                    kategorie: artikel?.kategorie,
                    preis: preis,
                    datum: belegDatum
                )
                neuerEintrag.artikelNameSnapshot = name
                neuerEintrag.produktName = produktName
                modelContext.insert(neuerEintrag)
            }
        }
        dismiss()
    }

    private func passtZu(name: String, eintrag: KaufEintrag) -> Bool {
        let artikelName = eintrag.artikel?.name ?? eintrag.artikelNameSnapshot
        guard !artikelName.isEmpty else { return false }
        return artikelName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(artikelName)
    }

    /// Sucht unter allen vorhandenen Artikeln einen, dessen Name zum erkannten
    /// Belegtext passt, damit ein beim Geschäft-Scan (ohne laufenden Einkauf) neu
    /// angelegter ``KaufEintrag`` in der Preishistorie dieses ``Artikel``s auftaucht
    /// statt nur als Namens-Schnappschuss zu existieren.
    private func passendesArtikel(fuer name: String) -> Artikel? {
        let alleArtikel = (try? modelContext.fetch(FetchDescriptor<Artikel>())) ?? []
        return alleArtikel.first {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }
    }
}

/// Eine editierbare Kopie einer erkannten Belegposition, solange der Anwender sie
/// noch prüfen/korrigieren kann.
///
/// `artikelName` ist editierbar, damit der Anwender die Position zwecks Zuordnung
/// auf einen bestehenden (ggf. generischen) ``Artikel`` umbenennen kann — z.B.
/// „Colgate Total“ → „Zahnpasta“. `erkannterName` bleibt dabei unverändert der
/// ursprünglich erkannte Produktname und wird als ``KaufEintrag/produktName``
/// übernommen, damit die Preishistorie weiterhin nach Marke/Produkt unterscheidet.
private struct BearbeitbarePosition: Identifiable {
    let id = UUID()
    let erkannterName: String
    var artikelName: String
    var preisText: String
}

/// Aufforderung, ein Beleg-Foto aufzunehmen oder aus der Mediathek zu wählen.
private struct AufnahmeAnsicht: View {
    let laeuft: Bool
    let fehlermeldung: String?
    let geschaeftName: String
    @Binding var ausgewaehltesFoto: PhotosPickerItem?
    let kameraOeffnen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if laeuft {
                ProgressView("Beleg wird ausgewertet…")
            } else {
                ContentUnavailableView {
                    Label("Beleg scannen", systemImage: "doc.text.viewfinder")
                } description: {
                    Text("Fotografiere den Kassenbon von „\(geschaeftName)“ oder wähle ein Foto aus deiner Mediathek.")
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

/// UIKit-Brücke für die Kamera-Aufnahme eines Belegfotos.
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

/// Editierbare Liste der erkannten Positionen zur Kontrolle vor dem Übernehmen.
private struct ErgebnisListe: View {
    @Binding var positionen: [BearbeitbarePosition]
    @Binding var belegDatum: Date
    let uebernehmen: () -> Void

    var body: some View {
        List {
            Section {
                DatePicker("Einkaufsdatum", selection: $belegDatum, displayedComponents: .date)
            } footer: {
                Text("Von der KI erkannt, falls auf dem Bon vorhanden — bei Bedarf korrigieren.")
            }

            Section {
                ForEach($positionen) { $position in
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
                }
                .onDelete { positionen.remove(atOffsets: $0) }
            } header: {
                Text("Erkannte Positionen")
            } footer: {
                Text("Prüfe Name und Preis, bevor du übernimmst. Nicht benötigte Positionen kannst du löschen.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Preise übernehmen", action: uebernehmen)
                .buttonStyle(.glass)
                .padding()
        }
    }
}
