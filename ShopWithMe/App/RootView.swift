import SwiftUI
import SwiftData

/// Wurzel-Ansicht der App: Tab-Navigation zwischen den Hauptbereichen.
///
/// Stößt außerdem bei jedem App-Start und Rückkehr aus dem Hintergrund die
/// automatische Preishistorie-Bereinigung an (siehe
/// ``PreisHistorieBereinigungService/automatischBereinigenFallsFaellig(context:)``).
///
/// Reagiert außerdem auf `shopwithme://milkforus-import`, geöffnet von der
/// ``ShopWithMeShareExtension`` nachdem sie eine geteilte MilkForUs-Datei über
/// ``MilkForUsPendingImportStore`` bereitgelegt hat, und präsentiert dafür direkt
/// ``MilkForUsImportView`` — siehe `docs/MILKFORUS_IMPORT.md`.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var ausstehenderMilkForUsImport: AusstehenderImport?

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
        .onOpenURL { url in
            guard url.scheme == "shopwithme", url.host == "milkforus-import",
                  let text = MilkForUsPendingImportStore.abholen()
            else { return }
            ausstehenderMilkForUsImport = AusstehenderImport(text: text)
        }
        .sheet(item: $ausstehenderMilkForUsImport) { eintrag in
            MilkForUsImportView(initialText: eintrag.text)
        }
    }
}

/// Macht den von der Share Extension übergebenen Text `.sheet(item:)`-fähig.
private struct AusstehenderImport: Identifiable {
    let id = UUID()
    let text: String
}

#Preview {
    RootView()
}
