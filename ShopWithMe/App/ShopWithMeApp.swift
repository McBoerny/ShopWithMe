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
    @StateObject private var containerController: ModelContainerController
    @StateObject private var syncPollingService = SyncPollingService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let (konfiguration, geteilterOrdner) = ModelContainerController.baueStandardKonfiguration()

        DatabaseDebugLogger.log(.storeOpenStart, details: konfiguration.url.path)
        let container: ModelContainer
        do {
            container = try ModelContainerController.baueContainer(konfiguration: konfiguration)
        } catch {
            // Log ist Best-Effort: `fatalError` beendet den Prozess sofort danach,
            // das asynchrone Schreiben des Log-Eintrags kann daher vereinzelt nicht
            // mehr rechtzeitig abschließen.
            DatabaseDebugLogger.log(.storeOpenFailure, details: "\(error)")
            fatalError("ModelContainer konnte nicht erstellt werden: \(error)")
        }
        DatabaseDebugLogger.log(.storeOpenSuccess, details: konfiguration.url.path)

        let context = container.mainContext
        // Autosave aus: alle Schreibzugriffe laufen ab jetzt über explizite,
        // Lease-geschützte `save()`-Aufrufe (siehe `docs/DATABASE_CONCURRENCY.md` →
        // „Voraussetzung: explizite Speicherpunkte statt implizitem Autosave“).
        context.autosaveEnabled = false
        DatabaseLeaseService.storeURL = konfiguration.url
        DatabaseDebugLogger.konfiguriere(geteilterOrdner: geteilterOrdner)
        SeedData.seedeStandarddatenFallsLeer(context: context)
        SeedData.seedeGeschaeftsTypenFallsLeer(context: context)
        Geschaeft.typenMigrierenFallsNoetig(context: context)
        ArtikelKategorie.geschaeftsTypenMigrierenFallsNoetig(context: context)
        DatenintegritaetsService.pruefe(context: context)
        try? context.save()

        _containerController = StateObject(wrappedValue: ModelContainerController(modelContainer: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Erzwingt einen kompletten View-Baum-Neuaufbau nach einem
                // ``SyncErsetzenService``-Austausch — siehe
                // ``ModelContainerController/generation``.
                .id(containerController.generation)
                .environmentObject(syncPollingService)
                .environmentObject(containerController)
                .task { syncPollingService.starten(context: containerController.modelContainer.mainContext) }
        }
        .modelContainer(containerController.modelContainer)
        .onChange(of: scenePhase) { _, neuePhase in
            switch neuePhase {
            case .active:
                syncPollingService.starten(context: containerController.modelContainer.mainContext)
            default:
                syncPollingService.stoppen()
            }
        }
    }
}
