import SwiftUI

#if DEBUG
/// Nur in Debug-Builds sichtbar (siehe ``DebugEinstellungen``, `#if DEBUG` in
/// ``SettingsView``): erlaubt es, den Suchradius der Standort-basierten
/// Ladenerkennung (``GeschaeftErkennungService``) testweise zu erhöhen, um sie ohne
/// echte Nähe zu einem Apple-Maps-Laden auszuprobieren. Betrifft sowohl den
/// automatischen Einzelvorschlag als auch „Alle Geschäfte in der Nähe“. Ist die
/// Überschreibung aus, gelten die festen Standardwerte
/// (``GeschaeftErkennungService/standardSuchradius``/
/// ``GeschaeftErkennungService/standardAlleInDerNaeheRadius``).
struct DebugEinstellungenView: View {
    @State private var ueberschreibungAktiv: Bool
    @State private var radius: Double

    init() {
        let vorhandeneUeberschreibung = DebugEinstellungen.sucheRadiusUeberschreibung
        _ueberschreibungAktiv = State(initialValue: vorhandeneUeberschreibung != nil)
        _radius = State(initialValue: vorhandeneUeberschreibung ?? GeschaeftErkennungService.standardSuchradius)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Suchradius überschreiben", isOn: $ueberschreibungAktiv)
                    .onChange(of: ueberschreibungAktiv) { _, _ in speichern() }

                if ueberschreibungAktiv {
                    Stepper("\(Int(radius)) m", value: $radius, in: 100...5000, step: 50)
                        .onChange(of: radius) { _, _ in speichern() }
                }
            } footer: {
                Text("Nur in Debug-Builds sichtbar. Erhöht testweise den Suchradius der Standort-basierten Ladenerkennung (automatischer Vorschlag und „Alle Geschäfte in der Nähe“), um sie ohne echte Nähe zu einem Apple-Maps-Laden zu testen. Ohne Überschreibung gelten die Standardwerte (\(Int(GeschaeftErkennungService.standardSuchradius))m bzw. \(Int(GeschaeftErkennungService.standardAlleInDerNaeheRadius))m).")
            }
        }
        .navigationTitle("Debug-Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func speichern() {
        DebugEinstellungen.sucheRadiusUeberschreibung = ueberschreibungAktiv ? radius : nil
    }
}

#Preview {
    NavigationStack {
        DebugEinstellungenView()
    }
}
#endif
