import SwiftUI
import SwiftData

/// Einstiegspunkt der App.
///
/// Baut den ``ModelContainer`` mit dem vollständigen Datenmodell-Schema auf —
/// immer am SwiftData-Standardpfad (GitHub #54) — und sät beim ersten Start
/// die Standardabteilungen via ``SeedData``.
@main
struct ShopWithMeApp: App {
    @StateObject private var modelContainerController: ModelContainerController
    @StateObject private var syncPollingService = SyncPollingService()
    @StateObject private var multipeerSyncService = MultipeerSyncService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let schema = SchemaDefinition.schema

        // Im Test-Umfeld reicht ein In-Memory-Store — BelegScan-Tests benoetigen
        // SwiftData nicht, und der persistente Store oeffnet auf dem Mac nicht zuverlaessig.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            do {
                let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
                _modelContainerController = StateObject(wrappedValue: ModelContainerController(modelContainer: container))
            } catch {
                fatalError("In-Memory-ModelContainer konnte nicht erstellt werden: \(error)")
            }
            return
        }

        // Räumt Store-Dateien vergangener Live-Ersetzen-Vorgänge (siehe
        // ``ModelContainerController``) auf — muss ganz am Anfang eines
        // frischen Prozesses passieren, bevor irgendein ``ModelContainer``
        // existiert (per Definition der einzige Zeitpunkt, an dem garantiert
        // keine dieser Dateien noch offen ist).
        ModelContainerController.raeumeVerwaisteStoreDateienAuf()

        let konfiguration = ModelConfiguration(schema: schema, url: ModelContainerController.aktuelleStoreURL())

        // Fallback für den Fall, dass der Store selbst beim Start bereits
        // unlesbar ist (GitHub #119, ``SyncErsetzenService/loescheUnlesbarenStoreUndPlaneWiederherstellung(url:)``)
        // — dort existiert per Definition noch kein offener Container, ein
        // Live-Tausch (``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)``)
        // ist nicht anwendbar. Der reguläre Ersetzen-/Wiederherstellen-Weg
        // aus der laufenden App heraus läuft seit dem zweiten Live-Anlauf
        // dagegen nicht mehr über diesen Neustart-Mechanismus (siehe
        // ``SyncErsetzenService``).
        //
        // GitHub #119: Steht bereits eine Wiederherstellung aus (der Store
        // wurde also in einer vorherigen Sitzung verworfen, siehe
        // ``oeffneContainer(schema:konfiguration:)``), MUSS das VOR dem
        // `loescheStoreDateiFallsAusstehend`-Aufruf ausgelesen werden —
        // danach ist der Zustand bereits wieder "kein Store" und nicht mehr
        // von einer regulären Erstinstallation unterscheidbar.
        let wiederherstellungAusstehend = SyncErsetzenService.ausstehendeAktion != nil
        // Race-frei HIER gesetzt, synchron und vor `body` (siehe Doku bei
        // `SyncPollingService.ueberspringeRueckkehrerErkennungBeimNaechstenStart`
        // für die Begründung — ein früherer Versuch, dieselbe Information nur
        // über den `.task`-Aufrufer als Parameter durchzureichen, verlor das
        // Rennen gegen `.onChange(of: scenePhase)` praktisch immer).
        SyncPollingService.ueberspringeRueckkehrerErkennungBeimNaechstenStart = wiederherstellungAusstehend
        SyncErsetzenService.loescheStoreDateiFallsAusstehend(url: konfiguration.url)

        DatabaseDebugLogger.log(.storeOpenStart, details: konfiguration.url.path)
        let container: ModelContainer
        do {
            container = try Self.oeffneContainer(schema: schema, konfiguration: konfiguration)
        } catch {
            // Log ist Best-Effort: `fatalError` beendet den Prozess sofort danach,
            // das asynchrone Schreiben des Log-Eintrags kann daher vereinzelt nicht
            // mehr rechtzeitig abschließen.
            DatabaseDebugLogger.log(.storeOpenFailure, details: "\(error)")
            fatalError("ModelContainer konnte nicht erstellt werden: \(error)")
        }
        DatabaseDebugLogger.log(.storeOpenSuccess, details: konfiguration.url.path)
        _modelContainerController = StateObject(wrappedValue: ModelContainerController(modelContainer: container))

        let context = container.mainContext
        // Autosave aus: alle Schreibzugriffe laufen ab jetzt über explizite,
        // Lease-geschützte `save()`-Aufrufe (siehe `docs/DATABASE_CONCURRENCY.md` →
        // „Voraussetzung: explizite Speicherpunkte statt implizitem Autosave“).
        context.autosaveEnabled = false
        DatabaseLeaseService.storeURL = konfiguration.url
        SeedData.seedeStandarddatenFallsLeer(context: context)
        SeedData.seedeGeschaeftsTypenFallsLeer(context: context)
        SeedData.migriereStandardGeschaeftsTypSymboleFallsNoetig(context: context)
        Geschaeft.typenMigrierenFallsNoetig(context: context)
        Abteilung.geschaeftsTypenMigrierenFallsNoetig(context: context)
        KaufEintrag.preisverlaufMigrierenFallsNoetig(context: context)
        DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context: context)
        DatenintegritaetsService.migriereArtikelListenKaeufeFallsNoetig(context: context)
        DatenintegritaetsService.bereinigeDoppelteKaufEintraegeFallsNoetig(context: context)
        DatenintegritaetsService.raeumeLeereListenloseVorgaengeAuf(context: context)
        DatenintegritaetsService.pruefe(context: context)
        try? context.save()
    }

    /// Öffnet den `ModelContainer` — bei einem Fehler (GitHub #119: ein Store,
    /// der sich über SwiftData nicht mehr öffnen lässt, z.B. durch
    /// Beschädigung oder einen inkompatiblen Vorzustand) ist der Store nicht
    /// mehr reparierbar. Einziger Ausweg: den unlesbaren Store physisch
    /// verwerfen und aus einem Peer-Snapshot wiederherstellen (siehe
    /// ``SyncErsetzenService``) — anders als
    /// ``SyncErsetzenService/planeErsetzenDurchPeer(context:)`` OHNE
    /// Vorher-Backup, weil der Store zu diesem Zeitpunkt gar nicht mehr
    /// offen ist. Jeder lokale, noch nicht synchronisierte Stand geht dabei
    /// unwiederbringlich verloren — strukturell unvermeidbar, sobald der
    /// Store gar nicht mehr geöffnet werden kann.
    ///
    /// **Bewusst KEIN sofortiger Retry im selben Prozess:** Ein
    /// zurückliegender fehlgeschlagener Öffnen-Versuch scheitert bei einem
    /// erneuten `ModelContainer`-Aufruf im selben Prozess zuverlässig
    /// identisch (SwiftData/CoreData behält internen Zustand offenbar
    /// prozessweit bei, unabhängig davon, ob die Store-Datei zwischenzeitlich
    /// gelöscht wurde — reproduziert bei GitHub #119, deckt sich mit
    /// Berichten im Apple Developer Forum). Der verworfene, für den nächsten
    /// Start vorgemerkte Store wird deshalb erst beim NÄCHSTEN Prozessstart
    /// tatsächlich neu geöffnet.
    private static func oeffneContainer(schema: Schema, konfiguration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [konfiguration])
        } catch {
            DatabaseDebugLogger.log(.storeOpenFailure, details: "Öffnen fehlgeschlagen, verwerfe Store für Wiederherstellung beim nächsten Start: \(error)")
            SyncErsetzenService.loescheUnlesbarenStoreUndPlaneWiederherstellung(url: konfiguration.url)
            throw error
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(modelContainerController.generation)
                .environmentObject(syncPollingService)
                .environmentObject(multipeerSyncService)
                // `.task(id:)` statt `.task {}` — ein `.task` ohne explizite
                // `id:` ist nicht zuverlässig an die Identität eines vorher in
                // derselben Kette angewandten `.id(_:)` gebunden. Nach einem
                // Live-Ersetzen (``ModelContainerController``) liefen sonst
                // `syncPollingService`/`multipeerSyncService` still am
                // verlassenen alten Context weiter (Live-Fund, dank
                // ``ModelContainerController/vergangeneContainer`` ohne
                // sofortigen Absturz, aber falsch), bis ein zufälliger
                // `scenePhase`-Wechsel sie neu verdrahtete.
                .task(id: modelContainerController.generation) {
                    // Nach einem Neustart wegen ``SyncErsetzenService`` steht
                    // hier ein frisch geöffneter, gerade eben (siehe `init()`)
                    // physisch geleerter Store — jetzt aus Peer-Snapshot oder
                    // lokalem Backup befüllen, bevor das normale Polling
                    // beginnt. Ohne Wirkung, falls nichts aussteht.
                    await SyncErsetzenService.fuehreAusstehendeAktionAus(context: modelContainerController.modelContainer.mainContext)
                    syncPollingService.starten(context: modelContainerController.modelContainer.mainContext)
                    multipeerSyncService.starten(context: modelContainerController.modelContainer.mainContext)
                }
        }
        .modelContainer(modelContainerController.modelContainer)
        .onChange(of: scenePhase) { _, neuePhase in
            switch neuePhase {
            case .active:
                syncPollingService.starten(context: modelContainerController.modelContainer.mainContext)
                multipeerSyncService.starten(context: modelContainerController.modelContainer.mainContext)
            default:
                syncPollingService.stoppen()
                multipeerSyncService.stoppen()
            }
        }
    }
}
