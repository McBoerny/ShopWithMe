import SwiftUI

/// Einstiegspunkt für Einstellungen: Hilfe/Anleitungen, Datenbank-Speicherort und
/// App-Informationen.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("Hilfe & Anleitungen", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        DatabaseLocationSettingsView()
                    } label: {
                        Label("Datenbank & Speicherort", systemImage: "externaldrive")
                    }
                    NavigationLink {
                        DatabaseDebugSettingsView()
                    } label: {
                        Label("DB-Debug-Modus", systemImage: "ladybug")
                    }
                }

                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
            }
            .navigationTitle("Einstellungen")
        }
    }
}

private extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "–"
    }
}

#Preview {
    SettingsView()
}
