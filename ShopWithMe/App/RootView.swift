import SwiftUI
import SwiftData

/// Wurzel-Ansicht der App: Tab-Navigation zwischen den Hauptbereichen.
///
/// Stößt außerdem bei jedem App-Start und Rückkehr aus dem Hintergrund die
/// automatische Preishistorie-Bereinigung an (siehe
/// ``PreisHistorieBereinigungService/automatischBereinigenFallsFaellig(context:)``).
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Artikel", systemImage: "carrot.fill") {
                ArtikelListView()
            }
            Tab("Geschäfte", systemImage: "cart.fill") {
                NavigationStack {
                    GeschaeftListView()
                }
            }
            Tab("Einkaufen", systemImage: "checklist") {
                EinkaufenView()
            }
            Tab("Einstellungen", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .task {
            await PreisHistorieBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
        }
        .onChange(of: scenePhase) { _, neuePhase in
            guard neuePhase == .active else { return }
            Task {
                await PreisHistorieBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
            }
        }
    }
}

#Preview {
    RootView()
}
