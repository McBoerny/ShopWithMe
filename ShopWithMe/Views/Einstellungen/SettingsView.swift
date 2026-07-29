import SwiftUI

/// Einstiegspunkt für Einstellungen: Hilfe/Anleitungen, Artikel-, Geschäfte-,
/// Kategorien-, Geschäftstypen- und Einkaufslisten-Verwaltung, Datenbank-Speicherort
/// und App-Informationen.
///
/// „Artikel“ und „Geschäfte“ sind seit GitHub #1 keine eigenen Tabs mehr (die App
/// startet immer direkt auf „Einkaufen“, siehe ``RootView``) — beide verlinken
/// direkt auf ``ArtikelListView``/``GeschaeftListView``, die deshalb bewusst
/// keinen eigenen `NavigationStack` anlegen, sondern den von hier erwarten.
///
/// Navigationsziele der Zeilen als eigenes `Hashable`-Werteziel für
/// `NavigationLink(value:)`/`.navigationDestination(for:)`, statt der älteren
/// closure-basierten `NavigationLink { destination } label: {}`-Variante
/// (analog `GeschaeftDetailNavigationsziel` in ``GeschaeftDetailView``).
/// Letztere konstruiert ihre Destination-View eager bei **jedem** Rendern von
/// `SettingsView` — bei `GeschaeftListView` (eigenes `@Query` und, seit dem
/// GitHub-#33-Fix, eigenes `.navigationDestination(for: Geschaeft.self)`)
/// führte das dazu, dass der Tap auf ein Geschäft nicht mehr zur Detailansicht
/// navigierte (dieselbe Fehlerklasse wie die Preisübersicht-Endlosschleife,
/// nur eine weitere Ebene höher).
private enum SettingsNavigationsziel: Hashable {
    case hilfe
    case artikel
    case geschaefte
    case kategorien
    case geschaeftsTypen
    case einkaufslisten
    case preishistorie
    case datenbankSpeicherort
    case syncOrdner
    case syncDebugModus
    case dbDebugModus
    case debugEinstellungen
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: SettingsNavigationsziel.hilfe) {
                        Label("Hilfe & Anleitungen", systemImage: "questionmark.circle")
                    }
                    NavigationLink(value: SettingsNavigationsziel.artikel) {
                        Label("Artikel", systemImage: "carrot")
                    }
                    NavigationLink(value: SettingsNavigationsziel.geschaefte) {
                        Label("Geschäfte", systemImage: "cart")
                    }
                    NavigationLink(value: SettingsNavigationsziel.kategorien) {
                        Label("Kategorien", systemImage: "tag")
                    }
                    NavigationLink(value: SettingsNavigationsziel.geschaeftsTypen) {
                        Label("Geschäftstypen", systemImage: "square.grid.2x2")
                    }
                    NavigationLink(value: SettingsNavigationsziel.einkaufslisten) {
                        Label("Einkaufslisten", systemImage: "checklist")
                    }
                    NavigationLink(value: SettingsNavigationsziel.preishistorie) {
                        Label("Preishistorie", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(value: SettingsNavigationsziel.datenbankSpeicherort) {
                        Label("Datenbank & Speicherort", systemImage: "externaldrive")
                    }
                    NavigationLink(value: SettingsNavigationsziel.syncOrdner) {
                        Label("Datensynchronisation", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                // Bündelt die zuvor über mehrere Zeilen verstreuten Diagnose-
                // Einstiegspunkte (GitHub #53).
                Section("Debugging") {
                    NavigationLink(value: SettingsNavigationsziel.syncDebugModus) {
                        Label("Sync-Debug-Modus", systemImage: "ladybug")
                    }
                    NavigationLink(value: SettingsNavigationsziel.dbDebugModus) {
                        Label("DB-Debug-Modus", systemImage: "ladybug")
                    }
                    #if DEBUG
                    NavigationLink(value: SettingsNavigationsziel.debugEinstellungen) {
                        Label("Debug-Einstellungen", systemImage: "hammer")
                    }
                    #endif
                }

                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationDestination(for: SettingsNavigationsziel.self) { ziel in
                switch ziel {
                case .hilfe:
                    HelpView()
                case .artikel:
                    ArtikelListView()
                case .geschaefte:
                    GeschaeftListView()
                case .kategorien:
                    KategorienVerwaltungView()
                case .geschaeftsTypen:
                    GeschaeftsTypenVerwaltungView()
                case .einkaufslisten:
                    EinkaufslistenVerwaltungView()
                case .preishistorie:
                    PreisHistorieSettingsView()
                case .datenbankSpeicherort:
                    DatabaseLocationSettingsView()
                case .syncOrdner:
                    SyncOrdnerSettingsView()
                case .syncDebugModus:
                    SyncDebugSettingsView()
                case .dbDebugModus:
                    DatabaseDebugSettingsView()
                case .debugEinstellungen:
                    DebugEinstellungenView()
                }
            }
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
