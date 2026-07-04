import SwiftUI
import SwiftData

/// Einstiegspunkt der App.
///
/// Baut den ``ModelContainer`` mit dem vollständigen Datenmodell-Schema und dem
/// ``ShopWithMeMigrationPlan`` auf — am vom Anwender gewählten Speicherort (siehe
/// ``DatabaseLocationService``), falls einer hinterlegt ist, sonst am SwiftData-
/// Standardpfad — und sät beim ersten Start die Standardkategorien via ``SeedData``.
@main
struct ShopWithMeApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = SchemaDefinition.schema
        let konfiguration: ModelConfiguration
        if let ordner = DatabaseLocationService.gewaehlterOrdner(), ordner.startAccessingSecurityScopedResource() {
            konfiguration = ModelConfiguration(schema: schema, url: DatabaseLocationService.storeURL(inOrdner: ordner))
        } else {
            konfiguration = ModelConfiguration(schema: schema)
        }

        do {
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: SchemaDefinition.migrationPlan,
                configurations: [konfiguration]
            )
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
