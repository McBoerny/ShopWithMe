import SwiftUI
import SwiftData

/// Einstiegspunkt der App.
///
/// Baut den ``ModelContainer`` mit dem vollständigen Datenmodell-Schema und dem
/// ``ShopWithMeMigrationPlan`` auf — immer am SwiftData-Standardpfad (GitHub #54)
/// — und sät beim ersten Start die Standardkategorien via ``SeedData``.
@main
struct ShopWithMeApp: App {
    let modelContainer: ModelContainer
    @StateObject private var syncPollingService = SyncPollingService()
    @StateObject private var multipeerSyncService = MultipeerSyncService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let schema = SchemaDefinition.schema
        let konfiguration = ModelConfiguration(schema: schema)

        // Muss VOR dem Öffnen des Containers passieren (siehe
        // ``SyncErsetzenService``): ein bereits laufender ModelContainer für
        // dieselbe Datei lässt sich nicht sicher zur Laufzeit physisch
        // ersetzen — ein erster Versuch dazu führte auf einem echten Gerät zu
        // einem SQLite-I/O-Fehler und Absturz, weil `SyncPollingService`s
        // Hintergrund-Timer trotz `stoppen()` noch nebenläufig lief (siehe
        // `docs/DATABASE_CONCURRENCY.md`). Deshalb erst hier, ganz am Anfang
        // eines frischen Prozesses, an dem garantiert noch nichts geöffnet ist.
        SyncErsetzenService.loescheStoreDateiFallsAusstehend(url: konfiguration.url)

        DatabaseDebugLogger.log(.storeOpenStart, details: konfiguration.url.path)
        do {
            modelContainer = try Self.oeffneContainer(schema: schema, konfiguration: konfiguration)
        } catch {
            // Log ist Best-Effort: `fatalError` beendet den Prozess sofort danach,
            // das asynchrone Schreiben des Log-Eintrags kann daher vereinzelt nicht
            // mehr rechtzeitig abschließen.
            DatabaseDebugLogger.log(.storeOpenFailure, details: "\(error)")
            fatalError("ModelContainer konnte nicht erstellt werden: \(error)")
        }
        DatabaseDebugLogger.log(.storeOpenSuccess, details: konfiguration.url.path)

        let context = modelContainer.mainContext
        // Autosave aus: alle Schreibzugriffe laufen ab jetzt über explizite,
        // Lease-geschützte `save()`-Aufrufe (siehe `docs/DATABASE_CONCURRENCY.md` →
        // „Voraussetzung: explizite Speicherpunkte statt implizitem Autosave“).
        context.autosaveEnabled = false
        DatabaseLeaseService.storeURL = konfiguration.url
        SeedData.seedeStandarddatenFallsLeer(context: context)
        SeedData.seedeGeschaeftsTypenFallsLeer(context: context)
        Geschaeft.typenMigrierenFallsNoetig(context: context)
        ArtikelKategorie.geschaeftsTypenMigrierenFallsNoetig(context: context)
        KaufEintrag.preisverlaufMigrierenFallsNoetig(context: context)
        DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context: context)
        DatenintegritaetsService.migriereArtikelListenKaeufeFallsNoetig(context: context)
        DatenintegritaetsService.raeumeLeereListenloseVorgaengeAuf(context: context)
        DatenintegritaetsService.pruefe(context: context)
        try? context.save()
    }

    /// Öffnet den `ModelContainer` — bei einem Migrationsfehler (GitHub #119:
    /// ein Gerät, dessen Store eine Zwischenstufe des additiven Schema-
    /// Verlaufs vor der ersten echten `MigrationStage` trägt, siehe
    /// `docs/DECISIONS.md`, "Explizite SwiftData-Migrationslogik ab v1.5")
    /// ist der Store über SwiftData nicht mehr reparierbar. Einziger Ausweg:
    /// den unlesbaren Store physisch verwerfen und aus einem Peer-Snapshot
    /// wiederherstellen (siehe ``SyncErsetzenService``) — anders als
    /// ``SyncErsetzenService/planeErsetzenDurchPeer(context:)`` OHNE
    /// Vorher-Backup, weil der Store zu diesem Zeitpunkt gar nicht mehr
    /// offen ist. Jeder lokale, noch nicht synchronisierte Stand geht dabei
    /// unwiederbringlich verloren — strukturell unvermeidbar, sobald der
    /// Store gar nicht mehr geöffnet werden kann.
    private static func oeffneContainer(schema: Schema, konfiguration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, migrationPlan: SchemaDefinition.migrationPlan, configurations: [konfiguration])
        } catch {
            DatabaseDebugLogger.log(.storeOpenFailure, details: "Migration fehlgeschlagen, verwerfe Store und stelle aus Peer-Snapshot wieder her: \(error)")
            SyncErsetzenService.loescheUnlesbarenStoreUndPlaneWiederherstellung(url: konfiguration.url)
            return try ModelContainer(for: schema, migrationPlan: SchemaDefinition.migrationPlan, configurations: [konfiguration])
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(syncPollingService)
                .environmentObject(multipeerSyncService)
                .task {
                    // Nach einem Neustart wegen ``SyncErsetzenService`` steht
                    // hier ein frisch geöffneter, gerade eben (siehe `init()`)
                    // physisch geleerter Store — jetzt aus Peer-Snapshot oder
                    // lokalem Backup befüllen, bevor das normale Polling
                    // beginnt. Ohne Wirkung, falls nichts aussteht.
                    await SyncErsetzenService.fuehreAusstehendeAktionAus(context: modelContainer.mainContext)
                    syncPollingService.starten(context: modelContainer.mainContext)
                    multipeerSyncService.starten(context: modelContainer.mainContext)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, neuePhase in
            switch neuePhase {
            case .active:
                syncPollingService.starten(context: modelContainer.mainContext)
                multipeerSyncService.starten(context: modelContainer.mainContext)
            default:
                syncPollingService.stoppen()
                multipeerSyncService.stoppen()
            }
        }
    }
}
