import SwiftUI
import SwiftData

/// Einstellung für die automatische Löschung alter Preishistorie-Einträge — siehe
/// ``PreisHistorieBereinigungService``.
struct PreisHistorieSettingsView: View {
    private enum Auswahl: Hashable {
        case tage30, monate3, monate6, jahr1, nie, eigen
    }

    @Environment(\.modelContext) private var modelContext
    @State private var auswahl: Auswahl
    @State private var eigeneTage: Int
    @State private var laeuftBereinigung = false
    @State private var letztesErgebnis: Int?
    @State private var letzteBereinigung = PreisHistorieBereinigungService.letzteBereinigung

    init() {
        switch PreisHistorieBereinigungService.aktuelleAufbewahrung {
        case .tage30: _auswahl = State(initialValue: .tage30); _eigeneTage = State(initialValue: 60)
        case .monate3: _auswahl = State(initialValue: .monate3); _eigeneTage = State(initialValue: 60)
        case .monate6: _auswahl = State(initialValue: .monate6); _eigeneTage = State(initialValue: 60)
        case .jahr1: _auswahl = State(initialValue: .jahr1); _eigeneTage = State(initialValue: 60)
        case .nie: _auswahl = State(initialValue: .nie); _eigeneTage = State(initialValue: 60)
        case .eigeneTage(let tage): _auswahl = State(initialValue: .eigen); _eigeneTage = State(initialValue: tage)
        }
    }

    private var aktuelleAufbewahrung: PreisHistorieAufbewahrung {
        switch auswahl {
        case .tage30: return .tage30
        case .monate3: return .monate3
        case .monate6: return .monate6
        case .jahr1: return .jahr1
        case .nie: return .nie
        case .eigen: return .eigeneTage(max(1, eigeneTage))
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Aufbewahrungsdauer", selection: $auswahl) {
                    Text("30 Tage").tag(Auswahl.tage30)
                    Text("3 Monate").tag(Auswahl.monate3)
                    Text("6 Monate").tag(Auswahl.monate6)
                    Text("1 Jahr").tag(Auswahl.jahr1)
                    Text("Nie").tag(Auswahl.nie)
                    Text("Eigene Vorgabe").tag(Auswahl.eigen)
                }
                .onChange(of: auswahl) { _, _ in speichern() }

                if auswahl == .eigen {
                    Stepper("\(eigeneTage) Tage", value: $eigeneTage, in: 1...3650)
                        .onChange(of: eigeneTage) { _, _ in speichern() }
                }
            } footer: {
                Text("Preishistorie-Einträge, die älter als die gewählte Frist sind, werden automatisch beim App-Start bzw. beim Zurückkehren aus dem Hintergrund gelöscht. Einträge eines noch laufenden Einkaufsvorgangs bleiben davon immer unberührt. „Nie“ deaktiviert die automatische Löschung vollständig.")
            }

            Section {
                if let letzteBereinigung {
                    LabeledContent("Letzte Bereinigung", value: letzteBereinigung.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await jetztBereinigen() }
                } label: {
                    if laeuftBereinigung {
                        ProgressView()
                    } else {
                        Text("Jetzt bereinigen")
                    }
                }
                .disabled(laeuftBereinigung || auswahl == .nie)

                if let letztesErgebnis {
                    Text(letztesErgebnis == 0 ? "Keine alten Einträge gefunden." : "\(letztesErgebnis) Einträge gelöscht.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Preishistorie")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func speichern() {
        PreisHistorieBereinigungService.aktuelleAufbewahrung = aktuelleAufbewahrung
    }

    private func jetztBereinigen() async {
        laeuftBereinigung = true
        defer { laeuftBereinigung = false }
        letztesErgebnis = await PreisHistorieBereinigungService.jetztBereinigen(context: modelContext)
        letzteBereinigung = PreisHistorieBereinigungService.letzteBereinigung
    }
}

#Preview {
    NavigationStack {
        PreisHistorieSettingsView()
    }
}
