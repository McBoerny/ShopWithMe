import SwiftUI

/// Einstiegspunkt für Einstellungen: Hilfe/Anleitungen, Artikel-, Geschäfte-,
/// Kategorien-, Geschäftstypen- und Einkaufslisten-Verwaltung, Datensynchronisation
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
    case produkte
    case geschaeftsTypen
    case einkaufslisten
    case preishistorie
    case syncOrdner
    case debugging
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
                        Label("Abteilungen", systemImage: "tag")
                    }
                    NavigationLink(value: SettingsNavigationsziel.produkte) {
                        Label("Produkte", systemImage: "shippingbox")
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
                    NavigationLink(value: SettingsNavigationsziel.syncOrdner) {
                        Label("Datensynchronisation", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                // Bündelt die zuvor über mehrere Zeilen/Bildschirme verstreuten
                // Diagnose-Einstiegspunkte in einer einzigen Ansicht (GitHub #53).
                Section {
                    NavigationLink(value: SettingsNavigationsziel.debugging) {
                        Label("Debugging", systemImage: "ladybug")
                    }
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
                    AbteilungenVerwaltungView()
                case .produkte:
                    ProduktVerwaltungView()
                case .geschaeftsTypen:
                    GeschaeftsTypenVerwaltungView()
                case .einkaufslisten:
                    EinkaufslistenVerwaltungView()
                case .preishistorie:
                    PreisHistorieSettingsView()
                case .syncOrdner:
                    SyncOrdnerSettingsView()
                case .debugging:
                    DebuggingView()
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
