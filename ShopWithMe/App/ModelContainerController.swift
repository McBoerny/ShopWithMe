import Foundation
import SwiftData

/// Fehler rund um das Austauschen des lokalen ``ModelContainer``.
enum ModelContainerFehler: LocalizedError {
    case keineStoreURL

    var errorDescription: String? {
        switch self {
        case .keineStoreURL:
            return "Der aktuelle Datenbank-Speicherort konnte nicht ermittelt werden."
        }
    }
}

/// Hält den aktuell aktiven ``ModelContainer`` austauschbar, damit
/// ``SyncErsetzenService`` den lokalen Store zur Laufzeit vollständig ersetzen
/// kann, ohne die App neu starten zu müssen (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`
/// → „SyncErsetzenService").
///
/// **Warum physisches Löschen statt zeilenweisem Wipe:** Ein bereits
/// korrumpierter Datensatz (baumelnde Referenz, siehe
/// `docs/DATABASE_CONCURRENCY.md` → „Nachtrag: rückwirkende Reparatur…") lässt
/// sich über die normale SwiftData-Objektgraph-API nicht sicher entfernen —
/// jede schreibende Operation (Nullen wie Löschen einer Relationship) muss die
/// Inverse-Gegenseite auffalten und crasht dabei, falls genau diese Gegenseite
/// die bereits baumelnde ist. Wird die Store-Datei stattdessen physisch
/// gelöscht, öffnet SwiftData die korrumpierten Zeilen nie wieder — das
/// Problem ist strukturell ausgeschlossen statt nur wahrscheinlich vermieden.
@MainActor
final class ModelContainerController: ObservableObject {
    @Published private(set) var modelContainer: ModelContainer
    /// Ändert sich bei jedem Ersetzen — über `.id(generation)` an `RootView`
    /// erzwingt das einen kompletten Neuaufbau des View-Baums. Notwendig, weil
    /// jede Ansicht tiefer in einem NavigationStack/Sheet, die noch ein
    /// Modellobjekt aus dem alten (jetzt gelöschten) Store in `@State` hält,
    /// sonst beim nächsten Zugriff denselben SwiftData-Fatal-Error auslösen
    /// würde, den dieses Feature gerade vermeiden soll.
    @Published private(set) var generation = UUID()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Baut die Standard-Konfiguration für den App-Start: am vom Anwender
    /// gewählten Speicherort (``DatabaseLocationService``), falls einer
    /// hinterlegt ist, sonst am SwiftData-Standardpfad. Von
    /// ``ShopWithMeApp/init()`` verwendet.
    static func baueStandardKonfiguration() -> (konfiguration: ModelConfiguration, geteilterOrdner: URL?) {
        let schema = SchemaDefinition.schema
        if let ordner = DatabaseLocationService.gewaehlterOrdner(), ordner.startAccessingSecurityScopedResource() {
            return (ModelConfiguration(schema: schema, url: DatabaseLocationService.storeURL(inOrdner: ordner)), ordner)
        }
        return (ModelConfiguration(schema: schema), nil)
    }

    static func baueContainer(konfiguration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: SchemaDefinition.schema, migrationPlan: SchemaDefinition.migrationPlan, configurations: [konfiguration])
    }

    /// Löscht den aktuellen lokalen Store vollständig (Datei + `-wal`/`-shm`,
    /// analog dem Suffix-Muster in `DatabaseLocationService`) und ersetzt ihn
    /// durch einen frischen, leeren Container an derselben URL. Ruft NICHT
    /// selbst den Peer-Import auf — das bleibt Aufgabe von
    /// ``SyncErsetzenService``, das nach dem Austausch den neuen, leeren
    /// Context erhält und befüllt.
    func ersetzeDurchLeerenContainer() throws -> ModelContext {
        guard let url = modelContainer.configurations.first?.url else {
            throw ModelContainerFehler.keineStoreURL
        }
        let dateiManager = FileManager.default
        let ordner = url.deletingLastPathComponent()
        let basisname = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            try? dateiManager.removeItem(at: ordner.appendingPathComponent(basisname + suffix))
        }

        let neuerContainer = try Self.baueContainer(konfiguration: ModelConfiguration(schema: SchemaDefinition.schema, url: url))
        neuerContainer.mainContext.autosaveEnabled = false
        modelContainer = neuerContainer
        generation = UUID()
        return neuerContainer.mainContext
    }
}
