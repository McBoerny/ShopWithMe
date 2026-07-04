import SwiftUI

/// Wurzel-Ansicht der App: Tab-Navigation zwischen den Hauptbereichen.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Artikel", systemImage: "carrot.fill") {
                ArtikelListView()
            }
            Tab("Geschäfte", systemImage: "cart.fill") {
                GeschaeftListView()
            }
            Tab("Einkaufen", systemImage: "checklist") {
                EinkaufenView()
            }
            Tab("Einstellungen", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
    }
}

#Preview {
    RootView()
}
