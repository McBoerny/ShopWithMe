import SwiftUI

/// Einstiegspunkt für Einstellungen: Hilfe/Anleitungen, Kategorien- und
/// Einkaufslisten-Verwaltung, Datenbank-Speicherort und App-Informationen.
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
                        KategorienVerwaltungView()
                    } label: {
                        Label("Kategorien", systemImage: "tag")
                    }
                    NavigationLink {
                        EinkaufslistenVerwaltungView()
                    } label: {
                        Label("Einkaufslisten", systemImage: "checklist")
                    }
                    NavigationLink {
                        PreisHistorieSettingsView()
                    } label: {
                        Label("Preishistorie", systemImage: "clock.arrow.circlepath")
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
        let version = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "–"
        let build = (infoDictionary?["CFBundleVersion"] as? String) ?? "–"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
}
