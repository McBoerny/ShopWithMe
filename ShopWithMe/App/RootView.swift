import SwiftUI

/// Wurzel-Ansicht der App: Tab-Navigation zwischen den Hauptbereichen.
///
/// Die einzelnen Tabs werden schrittweise mit Inhalten gefüllt (siehe
/// `docs/ROADMAP.md`); bis dahin zeigen sie Platzhalter.
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
                PlatzhalterView(titel: "Einkaufen", geplantAb: "v0.4")
            }
            Tab("Einstellungen", systemImage: "gearshape.fill") {
                PlatzhalterView(titel: "Einstellungen", geplantAb: "v0.6")
            }
        }
    }
}

/// Einfacher Platzhalter für Bereiche, die in einer späteren Version umgesetzt werden.
private struct PlatzhalterView: View {
    let titel: String
    let geplantAb: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                titel,
                systemImage: "hammer.fill",
                description: Text("Wird in \(geplantAb) umgesetzt.")
            )
            .navigationTitle(titel)
        }
    }
}

#Preview {
    RootView()
}
