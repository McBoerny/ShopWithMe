import SwiftUI

/// Einstiegspunkt für Einstellungen: Hilfe/Anleitungen, Geschäfte-, Kategorien- und
/// Einkaufslisten-Verwaltung, Datenbank-Speicherort und App-Informationen.
///
/// „Geschäfte“ verlinkt auf dieselbe ``GeschaeftListView`` wie der gleichnamige Tab
/// (``RootView``) — sie erwartet deshalb einen umgebenden `NavigationStack` beim
/// Aufrufer statt selbst einen anzulegen, siehe deren Dokumentation.
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
                        GeschaeftListView()
                    } label: {
                        Label("Geschäfte", systemImage: "cart")
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
                    #if DEBUG
                    NavigationLink {
                        DebugEinstellungenView()
                    } label: {
                        Label("Debug-Einstellungen", systemImage: "hammer")
                    }
                    #endif
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
