import SwiftUI
import SwiftData

/// Einstiegspunkt der App.
///
/// Baut den ``ModelContainer`` mit dem vollständigen Datenmodell-Schema auf und sät
/// beim ersten Start die Standardkategorien via ``SeedData``.
@main
struct ShopWithMeApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Artikel.self,
            ArtikelKategorie.self,
            Regal.self,
            Geschaeft.self,
            Einkaufsvorgang.self,
            KaufEintrag.self,
            RegalBesuchsStatistik.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [konfiguration])
        } catch {
            fatalError("ModelContainer konnte nicht erstellt werden: \(error)")
        }

        let context = modelContainer.mainContext
        SeedData.seedeStandarddatenFallsLeer(context: context)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
