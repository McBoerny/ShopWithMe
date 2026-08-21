import Foundation
import SwiftData

/// Fehler beim Live-Ersetzen des lokalen ``ModelContainer``.
enum ModelContainerErsetzenFehler: LocalizedError {
    case containerKonnteNichtErstelltWerden(Error)

    var errorDescription: String? {
        switch self {
        case .containerKonnteNichtErstelltWerden(let error):
            return "Der neue lokale Datenbestand konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }
}

/// Hält den aktiven ``ModelContainer`` austauschbar, damit ``SyncErsetzenService``
/// den lokalen Datenbestand LIVE ersetzen kann, ohne dass die App neu gestartet
/// werden muss — zweiter Anlauf nach `docs/DATENSYNCHRONISATION_VERLAUF.md`
/// (Abschnitt „Live-Ersetzen statt Neustart-Aufforderung").
///
/// **Warum ein neuer, PRO ERSETZEN EINDEUTIGER Dateipfad statt Wiederverwendung
/// (auch nicht abwechselnd zwischen zwei festen Slots):** Ein erster Versuch
/// (Commit `35161a5`, revertiert in `6af943c`) löschte die Store-Datei
/// physisch, WÄHREND der alte `ModelContainer` sie noch geöffnet hatte —
/// Absturz auf einem echten Gerät (`BUG IN CLIENT OF libsqlite3.dylib: vnode
/// unlinked while in use`). SwiftData legt den zugrundeliegenden
/// `NSPersistentStoreCoordinator` nie öffentlich frei, ein sauberes
/// `removePersistentStore`/`destroyPersistentStore` VOR dem Löschen ist über
/// die SwiftData-API deshalb nicht möglich. Ein zweiter Entwurf mit nur zwei
/// festen, abwechselnden Slot-Namen reproduzierte bei zweimaligem Ersetzen
/// ohne zwischenzeitlichen Neustart exakt denselben Absturz — das bloße
/// Fallenlassen der letzten `ModelContainer`-Referenz ist keine Garantie,
/// dass SwiftData/CoreData intern bereits fertig ist. Jetzt bekommt JEDES
/// Ersetzen einen frischen, noch nie dagewesenen Dateinamen (siehe
/// ``ersetzeLiveMitNeuemStore(befuellen:)``) — nie zuvor in diesem oder einem
/// früheren Prozess geöffnet, ein vorheriges Löschen des Ziels entfällt
/// dadurch vollständig.
///
/// Verwaiste Dateien vergangener Ersetzen-Vorgänge sammeln sich als Liste
/// (``verwaisteDateinamenSchluessel``) und werden ausschließlich am sicheren
/// Zeitpunkt aufgeräumt: dem Anfang eines NEUEN Prozesses
/// (``raeumeVerwaisteStoreDateienAuf()``, aufgerufen von `ShopWithMeApp.init()`,
/// bevor irgendein `ModelContainer` existiert) — dort kann per Definition
/// keine dieser Dateien noch offen sein.
///
/// Der eigentliche Container-Tausch läuft über `.modelContainer(_:)`/
/// ``generation`` — laut Apple-DTS offiziell unterstützt: das injizierte
/// `ModelContext` der View-Hierarchie wechselt dabei automatisch mit.
@MainActor
final class ModelContainerController: ObservableObject {
    @Published private(set) var modelContainer: ModelContainer
    /// Ändert sich bei jedem Live-Ersetzen — über `.id(generation)` an
    /// `RootView` erzwingt das einen kompletten View-Baum-Neuaufbau (nötig,
    /// falls eine Ansicht tief in einem NavigationStack/Sheet noch ein
    /// Modellobjekt aus dem jetzt verlassenen Store in `@State` hält, das
    /// sonst beim nächsten Zugriff einen SwiftData-Fatal-Error auslösen würde).
    @Published private(set) var generation = UUID()

    /// Hält jeden bei einem Live-Ersetzen verlassenen `ModelContainer` für den
    /// Rest der Prozesslaufzeit am Leben — `ModelContext` hält seinen
    /// erzeugenden `ModelContainer` NICHT stark. Ohne diese Liste
    /// dealloziert ``ersetzeLiveMitNeuemStore(befuellen:)`` den alten
    /// Container beim Umhängen von ``modelContainer`` sofort — ein zu diesem
    /// Zeitpunkt noch laufender Sync-Zyklus mit einem `ModelContext` des
    /// ALTEN Containers (z.B. `SyncPollingService`, das seinen `context` erst
    /// beim nächsten `starten(context:)`-Aufruf aktualisiert) crasht dann bei
    /// seinem nächsten Zugriff. Die zugehörige Datei bleibt ohnehin bis zum
    /// nächsten Prozessstart liegen (``raeumeVerwaisteStoreDateienAuf()``) —
    /// den Swift-Objektgraphen ebenfalls bis Prozessende zu behalten ist
    /// dieselbe Kompromisslinie, nur im Arbeitsspeicher statt auf der Platte.
    private var vergangeneContainer: [ModelContainer] = []

    /// Schutz gegen überlappende ``ersetzeLiveMitNeuemStore(befuellen:)``-
    /// Aufrufe (z.B. „Vorherigen Stand wiederherstellen" direkt gefolgt von
    /// erneutem Ordner-Beitritt mit „Ersetzen", beides live ohne Neustart
    /// dazwischen) — ohne Sperre lesen beide denselben Ausgangszustand, der
    /// zuletzt committende überschreibt den anderen. Synchron vor dem ersten
    /// `await` geprüft/gesetzt (analog `MultipeerSyncService.wirdAufgebaut`).
    private var wirdErsetzt = false

    /// Schwache Referenz auf die laufende Instanz, damit ``SyncErsetzenService``
    /// (reine Service-Schicht, kennt keine View-Hierarchie) den Live-Tausch
    /// anstoßen kann — gleiches Muster wie `MultipeerSyncService.aktuell`/
    /// `DatabaseLeaseService.storeURL`.
    private(set) static weak var aktuell: ModelContainerController?

    private static let aktiverSlotSchluessel = "syncErsetzenAktiverSlotName"
    private static let verwaisteDateinamenSchluessel = "syncErsetzenVerwaisteStoreDateinamen"

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        Self.aktuell = self
    }

    /// Verzeichnis des SwiftData-Standard-Speicherorts.
    private static var standardOrdner: URL {
        ModelConfiguration(schema: SchemaDefinition.schema).url.deletingLastPathComponent()
    }

    /// Der beim aktuellen Prozessstart zu öffnende Dateiname — SwiftDatas
    /// eigener Standardname, sofern nie ersetzt, sonst der zuletzt aktive
    /// Slot-Name.
    private static var standardDateiname: String {
        ModelConfiguration(schema: SchemaDefinition.schema).url.lastPathComponent
    }

    /// Die beim aktuellen Prozessstart zu öffnende Store-URL — der zuletzt
    /// aktive Datei-NAME wird in `UserDefaults` persistiert (nicht die volle
    /// URL: das übergeordnete Verzeichnis kann sich zwischen App-/OS-Versionen
    /// unterscheiden). `nil` (nie ersetzt, oder erster Start) → Standarddatei.
    /// Von `ShopWithMeApp.init()` verwendet, um den `ModelContainer` an der
    /// tatsächlich aktuellen Datei zu öffnen.
    static func aktuelleStoreURL() -> URL {
        let dateiname = UserDefaults.standard.string(forKey: aktiverSlotSchluessel) ?? standardDateiname
        return standardOrdner.appendingPathComponent(dateiname)
    }

    /// Löscht eine Store-Datei (samt `-wal`/`-shm`) physisch — nur sicher
    /// aufzurufen, wenn `url` garantiert in KEINEM Prozess (auch nicht diesem,
    /// auch nicht in der Vergangenheit desselben Prozesses) noch offen war/ist
    /// (siehe Typ-Doku). Best-Effort, kein Fehler bei fehlender Datei.
    private static func loescheStoreDateiPhysisch(url: URL) {
        let ordner = url.deletingLastPathComponent()
        let basisname = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: ordner.appendingPathComponent(basisname + suffix))
        }
    }

    /// Räumt beim App-Start alle seit dem letzten Neustart verwaisten
    /// Store-Dateien vergangener Live-Ersetzen-Vorgänge auf (siehe Typ-Doku:
    /// jede davon bekommt einen eindeutigen, nie wiederverwendeten Namen —
    /// diese Liste kann deshalb bei mehrfachem Ersetzen ohne
    /// zwischenzeitlichen Neustart mehrere Einträge enthalten). Sicher, weil
    /// per Definition ein neuer Prozess läuft, der keine von ihnen je
    /// geöffnet hat. Muss VOR dem Öffnen des `ModelContainer` passieren
    /// (siehe `ShopWithMeApp/init()`).
    static func raeumeVerwaisteStoreDateienAuf() {
        let dateinamen = UserDefaults.standard.stringArray(forKey: verwaisteDateinamenSchluessel) ?? []
        guard !dateinamen.isEmpty else { return }
        for dateiname in dateinamen {
            loescheStoreDateiPhysisch(url: standardOrdner.appendingPathComponent(dateiname))
        }
        UserDefaults.standard.removeObject(forKey: verwaisteDateinamenSchluessel)
    }

    /// Ersetzt den aktiven Store LIVE durch einen frisch aufgebauten, an einer
    /// noch nie dagewesenen Datei-URL (siehe Typ-Doku): legt dort einen leeren
    /// ``ModelContainer`` an (bewusst OHNE Migrationsplan — ein frischer,
    /// leerer Store hat nichts zu migrieren), ruft `befuellen` mit dessen
    /// Context auf, und hängt den neuen Container erst danach über
    /// `.modelContainer(_:)` (``modelContainer``/``generation``) ein. Merkt
    /// die jetzt verwaiste alte Datei für die Aufräumung beim nächsten Start
    /// vor (``raeumeVerwaisteStoreDateienAuf()``) — löscht sie NICHT selbst.
    /// Bei einem Fehler beim Container-Aufbau bleibt der aktive Container
    /// unverändert. Wirft ``ModelContainerErsetzenFehler`` bei bereits
    /// laufendem Ersetzen (``wirdErsetzt``) ebenfalls nicht — ruft `befuellen`
    /// in diesem Fall gar nicht erst auf und liefert einfach ohne Wirkung
    /// zurück, da ein sich überlappender Aufruf ein Programmierfehler des
    /// Aufrufers wäre (UI verhindert das bereits durch Deaktivieren der
    /// entsprechenden Buttons während eines laufenden Austauschs).
    func ersetzeLiveMitNeuemStore(befuellen: @MainActor (ModelContext) async -> Void) async throws {
        guard !wirdErsetzt else { return }
        wirdErsetzt = true
        defer { wirdErsetzt = false }

        let alteURL = modelContainer.configurations.first?.url ?? Self.aktuelleStoreURL()
        // Bewusst vom AKTUELLEN Container abgeleitet, nicht von
        // ``standardOrdner`` — funktioniert dadurch unabhängig davon, wo der
        // aktuelle Store tatsächlich liegt (Testbarkeit mit einem isolierten
        // Verzeichnis, ohne den echten SwiftData-Standardpfad anzufassen).
        let neueURL = alteURL.deletingLastPathComponent().appendingPathComponent("ersetzt-\(UUID().uuidString).store")

        let neueKonfiguration = ModelConfiguration(schema: SchemaDefinition.schema, url: neueURL)
        let neuerContainer: ModelContainer
        do {
            neuerContainer = try ModelContainer(for: SchemaDefinition.schema, configurations: [neueKonfiguration])
        } catch {
            throw ModelContainerErsetzenFehler.containerKonnteNichtErstelltWerden(error)
        }
        neuerContainer.mainContext.autosaveEnabled = false

        await befuellen(neuerContainer.mainContext)

        var verwaist = UserDefaults.standard.stringArray(forKey: Self.verwaisteDateinamenSchluessel) ?? []
        verwaist.append(alteURL.lastPathComponent)
        UserDefaults.standard.set(verwaist, forKey: Self.verwaisteDateinamenSchluessel)
        UserDefaults.standard.set(neueURL.lastPathComponent, forKey: Self.aktiverSlotSchluessel)
        DatabaseLeaseService.storeURL = neueURL
        // VOR dem Umhängen in die Rückhalteliste — siehe ``vergangeneContainer``-Doku:
        // sonst dealloziert ARC den alten Container in genau diesem Moment.
        vergangeneContainer.append(modelContainer)
        modelContainer = neuerContainer
        generation = UUID()
    }
}
