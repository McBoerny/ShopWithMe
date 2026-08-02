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
                Text("Preishistorie-Einträge, die älter als die gewählte Frist sind, werden automatisch beim App-Start bzw. beim Zurückkehren aus dem Hintergrund gelöscht. „Nie“ deaktiviert die automatische Löschung vollständig.")
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

            PreispunktVerdichtungSection()
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

/// Einstellbare Schwellwerte für ``PreispunktVerdichtungService`` (GitHub
/// #76-Folgearbeit) — läuft automatisch für alle Nutzer, diese Sektion dient nur
/// zum Nachjustieren/Testen der drei Stufen, nicht zum Ein-/Ausschalten des
/// Features selbst. Gilt global für alle Geschäfte einheitlich. Ursprünglich unter
/// „Debugging" (GitHub #83: gehört fachlich zur Preishistorie, nicht zur Diagnose).
private struct PreispunktVerdichtungSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var maxProTag = PreispunktVerdichtungService.maxPunkteProTag
    @State private var tageBisWoche = PreispunktVerdichtungService.tageBisWochenVerdichtung
    @State private var tageBisMonat = PreispunktVerdichtungService.tageBisMonatsVerdichtung
    @State private var letzteVerdichtung = PreispunktVerdichtungService.letzteVerdichtung
    @State private var laeuft = false
    @State private var letztesErgebnis: Int?

    var body: some View {
        Section {
            Stepper("Max. Preispunkte pro Tag: \(maxProTag)", value: $maxProTag, in: 1...10)
                .onChange(of: maxProTag) { _, neuerWert in
                    PreispunktVerdichtungService.maxPunkteProTag = neuerWert
                }
            Stepper("Wochenverdichtung nach \(tageBisWoche) Tagen", value: $tageBisWoche, in: 1...90)
                .onChange(of: tageBisWoche) { _, neuerWert in
                    PreispunktVerdichtungService.tageBisWochenVerdichtung = neuerWert
                }
            Stepper("Monatsverdichtung nach \(tageBisMonat) Tagen", value: $tageBisMonat, in: 30...1095)
                .onChange(of: tageBisMonat) { _, neuerWert in
                    PreispunktVerdichtungService.tageBisMonatsVerdichtung = neuerWert
                }

            if let letzteVerdichtung {
                LabeledContent("Letzte Verdichtung", value: letzteVerdichtung.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                Task { await jetztVerdichten() }
            } label: {
                if laeuft {
                    ProgressView()
                } else {
                    Text("Jetzt verdichten")
                }
            }
            .disabled(laeuft)

            if let letztesErgebnis {
                Text(letztesErgebnis == 0 ? "Nichts zu verdichten gefunden." : "\(letztesErgebnis) Preispunkte verdichtet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Preishistorie-Verdichtung")
        } footer: {
            Text("Läuft automatisch für alle Nutzer im Hintergrund (kein Ein-/Ausschalter, nur die drei Schwellwerte hier). Pro Artikel/Geschäft und Tag bleiben höchstens so viele Preispunkte wie oben eingestellt (überzählige: nur die zuletzt beobachteten bleiben). Nach der Wochen-Frist werden ältere Tagespunkte pro Kalenderwoche auf den höchsten Preis reduziert, nach der Monats-Frist entsprechend pro Kalendermonat.")
        }
    }

    private func jetztVerdichten() async {
        laeuft = true
        defer { laeuft = false }
        letztesErgebnis = await PreispunktVerdichtungService.jetztVerdichten(context: modelContext)
        letzteVerdichtung = PreispunktVerdichtungService.letzteVerdichtung
    }
}

#Preview {
    NavigationStack {
        PreisHistorieSettingsView()
    }
}
