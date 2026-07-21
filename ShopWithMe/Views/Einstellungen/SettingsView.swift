import SwiftUI

/// Einstiegspunkt für Einstellungen: Hilfe/Anleitungen, Artikel-, Geschäfte-,
/// Kategorien- und Einkaufslisten-Verwaltung, Datenbank-Speicherort und
/// App-Informationen.
///
/// „Artikel“ und „Geschäfte“ sind seit GitHub #1 keine eigenen Tabs mehr (die App
/// startet immer direkt auf „Einkaufen“, siehe ``RootView``) — beide verlinken
/// direkt auf ``ArtikelListView``/``GeschaeftListView``, die deshalb bewusst
/// keinen eigenen `NavigationStack` anlegen, sondern den von hier erwarten.
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
                        ArtikelListView()
                    } label: {
                        Label("Artikel", systemImage: "carrot")
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
