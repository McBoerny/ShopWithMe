import SwiftUI
import SwiftData
import PhotosUI

/// Scannt den Kassenbon eines abgeschlossenen ``Einkaufsvorgang``s und trägt die
/// erkannten Preise in die zugehörigen ``KaufEintrag``e ein.
///
/// Erkannte Positionen, die sich keinem bestehenden ``KaufEintrag`` zuordnen lassen
/// (z.B. weil der Artikel nicht auf der Einkaufsliste war), werden als eigenständiger
/// ``KaufEintrag`` ohne ``Artikel``-Verknüpfung gespeichert — der Artikelname bleibt
/// über `artikelNameSnapshot` trotzdem in der Preishistorie lesbar.
struct BelegScanView: View {
    let einkaufsvorgang: Einkaufsvorgang

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var ausgewaehltesFoto: PhotosPickerItem?
    @State private var laeuft = false
    @State private var fehlermeldung: String?
    @State private var bearbeitbarePositionen: [BearbeitbarePosition]?

    private let scanner: ReceiptScanService = VisionFoundationModelsReceiptScanner()

    var body: some View {
        NavigationStack {
            Group {
                if let bearbeitbarePositionen {
                    ErgebnisListe(
                        positionen: Binding(
                            get: { bearbeitbarePositionen },
                            set: { self.bearbeitbarePositionen = $0 }
                        ),
                        uebernehmen: uebernehmen
                    )
                } else {
                    AufnahmeAnsicht(
                        laeuft: laeuft,
                        fehlermeldung: fehlermeldung,
                        geschaeftName: einkaufsvorgang.geschaeft?.name ?? "",
                        ausgewaehltesFoto: $ausgewaehltesFoto
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
                bearbeitbarePositionen = ergebnis.positionen.map {
                    BearbeitbarePosition(artikelName: $0.artikelName, preisText: "\($0.preis)")
                }
            } catch {
                fehlermeldung = error.localizedDescription
            }
        }
    }

    private func uebernehmen() {
        for position in bearbeitbarePositionen ?? [] {
            let name = position.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let preis = Decimal(string: position.preisText.replacingOccurrences(of: ",", with: "."))
            else { continue }

            if let vorhandenerEintrag = einkaufsvorgang.kaufEintraege.first(where: { passtZu(name: name, eintrag: $0) }) {
                vorhandenerEintrag.preis = preis
            } else {
                let neuerEintrag = KaufEintrag(
                    artikel: nil,
                    geschaeft: einkaufsvorgang.geschaeft,
                    preis: preis,
                    datum: einkaufsvorgang.startZeit
                )
                neuerEintrag.artikelNameSnapshot = name
                modelContext.insert(neuerEintrag)
                neuerEintrag.einkaufsvorgang = einkaufsvorgang
            }
        }
        dismiss()
    }

    private func passtZu(name: String, eintrag: KaufEintrag) -> Bool {
        let artikelName = eintrag.artikel?.name ?? eintrag.artikelNameSnapshot
        guard !artikelName.isEmpty else { return false }
        return artikelName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(artikelName)
    }
}

/// Eine editierbare Kopie einer erkannten Belegposition, solange der Anwender sie
/// noch prüfen/korrigieren kann.
private struct BearbeitbarePosition: Identifiable {
    let id = UUID()
    var artikelName: String
    var preisText: String
}

/// Aufforderung, ein Beleg-Foto aus der Mediathek zu wählen.
private struct AufnahmeAnsicht: View {
    let laeuft: Bool
    let fehlermeldung: String?
    let geschaeftName: String
    @Binding var ausgewaehltesFoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            if laeuft {
                ProgressView("Beleg wird ausgewertet…")
            } else {
                ContentUnavailableView {
                    Label("Beleg scannen", systemImage: "doc.text.viewfinder")
                } description: {
                    Text("Wähle ein Foto des Kassenbons von „\(geschaeftName)“ aus deiner Mediathek.")
                } actions: {
                    PhotosPicker("Aus Fotomediathek wählen", selection: $ausgewaehltesFoto, matching: .images)
                        .buttonStyle(.glass)
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

/// Editierbare Liste der erkannten Positionen zur Kontrolle vor dem Übernehmen.
private struct ErgebnisListe: View {
    @Binding var positionen: [BearbeitbarePosition]
    let uebernehmen: () -> Void

    var body: some View {
        List {
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
