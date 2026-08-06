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
        //
        // GitHub #119: Steht bereits eine Wiederherstellung aus (der Store
        // wurde also in einer vorherigen Sitzung verworfen, siehe
        // ``oeffneContainer(schema:konfiguration:mitMigrationsplan:)``), MUSS
        // das VOR dem `loescheStoreDateiFallsAusstehend`-Aufruf ausgelesen
        // werden — danach ist der Zustand bereits wieder "kein Store" und
        // nicht mehr von einer regulären Erstinstallation unterscheidbar.
        let wiederherstellungAusstehend = SyncErsetzenService.ausstehendeAktion != nil
        SyncErsetzenService.loescheStoreDateiFallsAusstehend(url: konfiguration.url)

        DatabaseDebugLogger.log(.storeOpenStart, details: konfiguration.url.path)
        do {
            modelContainer = try Self.oeffneContainer(
                schema: schema, konfiguration: konfiguration, mitMigrationsplan: !wiederherstellungAusstehend
            )
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
    ///
    /// **Bewusst KEIN sofortiger Retry im selben Prozess:** Ein
    /// zurückliegender fehlgeschlagener Staged-Migration-Versuch scheitert
    /// bei einem erneuten `ModelContainer`-Aufruf im selben Prozess
    /// zuverlässig identisch (SwiftData/CoreData behält den
    /// Migrations-Manager-Zustand offenbar prozessweit bei, unabhängig davon,
    /// ob der Store-Datei zwischenzeitlich gelöscht wurde — reproduziert bei
    /// GitHub #119, deckt sich mit Berichten im Apple Developer Forum). Der
    /// verworfene, für den nächsten Start vorgemerkte Store wird deshalb erst
    /// beim NÄCHSTEN Prozessstart tatsächlich neu geöffnet.
    ///
    /// **`mitMigrationsplan: false` bei bereits ausstehender Wiederherstellung
    /// (Live-Test-Nachtrag GitHub #119):** Auch ein tatsächlich per
    /// `destroyPersistentStore` vollständig verworfener, also GARANTIERT
    /// leerer Store scheiterte auf dem Testgerät beim nächsten
    /// Prozessstart am selben `Cannot use staged migration with an unknown
    /// model version`-Fehler, solange `migrationPlan:` übergeben wurde — die
    /// Staged-Migration-Engine verlangt offenbar zwingend eine erkennbare
    /// Ausgangsversion, auch für einen frisch angelegten Store ohne jede
    /// Historie. Ein leerer Store hat aber ohnehin nichts zu migrieren, daher
    /// öffnet dieser eine Aufruf (ausgelöst über ``wiederherstellungAusstehend``
    /// in ``init()``) bewusst ohne `migrationPlan:` — umgeht die
    /// Staged-Migration-Engine für diesen Fall vollständig, statt auf ihr
    /// korrektes Verhalten bei leeren Stores angewiesen zu sein.
    private static func oeffneContainer(schema: Schema, konfiguration: ModelConfiguration, mitMigrationsplan: Bool) throws -> ModelContainer {
        guard mitMigrationsplan else {
            return try ModelContainer(for: schema, configurations: [konfiguration])
        }
        do {
            return try ModelContainer(for: schema, migrationPlan: SchemaDefinition.migrationPlan, configurations: [konfiguration])
        } catch {
            DatabaseDebugLogger.log(.storeOpenFailure, details: "Migration fehlgeschlagen, verwerfe Store für Wiederherstellung beim nächsten Start: \(error)")
            SyncErsetzenService.loescheUnlesbarenStoreUndPlaneWiederherstellung(url: konfiguration.url)
            throw error
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
                    let geradeErsetztOderWiederhergestellt = await SyncErsetzenService.fuehreAusstehendeAktionAus(context: modelContainer.mainContext)
                    // `ueberspringeRueckkehrerErkennung` s. Parameter-Doku
                    // dort — verhindert eine Neustart-Schleife direkt nach
                    // einem frischen Wipe-und-Neuaufbau.
                    syncPollingService.starten(
                        context: modelContainer.mainContext,
                        ueberspringeRueckkehrerErkennung: geradeErsetztOderWiederhergestellt
                    )
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
