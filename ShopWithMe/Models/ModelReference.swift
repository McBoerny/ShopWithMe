import Foundation
import SwiftData

/// Hält nur die stabile Identität (``IdentifizierbaresModell/id``) eines
/// `@Model`-Objekts statt einer lebendigen Referenz — sicher über eine
/// `await`-Grenze hinweg zu speichern (z.B. in `@State`), ohne Gefahr einer
/// baumelnden Referenz, falls das Objekt währenddessen von einem nebenläufigen
/// Sync-Zyklus gelöscht wird.
///
/// **Hintergrund:** `await DatabaseLeaseService.performMicroLease` awaitet
/// zuerst den Lease-Erwerb — währenddessen läuft `SyncPollingService`s eigener
/// Hintergrund-Timer unabhängig weiter und kann in genau diesem Zeitfenster ein
/// Objekt löschen (z.B. per Tombstone eines Peers). Wird eine vor dem `await`
/// erfasste Objektreferenz danach ungeprüft in eine Relationship geschrieben,
/// stürzt das mit demselben SwiftData-Fatal-Error ab wie eine bereits
/// bestehende baumelnde Referenz (siehe `docs/DATABASE_CONCURRENCY.md` →
/// „Nachtrag: rückwirkende Reparatur..." — dort für schon vorhandene, hier für
/// währenddessen neu entstehende Korruption). ``resolved(in:)`` löst deshalb
/// erst unmittelbar vor der eigentlichen Verwendung (innerhalb des
/// Lease-Blocks, der nicht mehr unterbrochen werden kann) frisch auf und
/// liefert `nil`, falls das Objekt inzwischen nicht mehr existiert, statt eine
/// ungültige Referenz weiterzureichen.
struct ModelReference<T: IdentifizierbaresModell> {
    let id: UUID

    init(_ objekt: T) {
        self.id = objekt.id
    }

    /// Bequemlichkeits-Initialisierer für optionale Objekte — liefert `nil`,
    /// wenn `objekt` bereits `nil` ist.
    init?(_ objekt: T?) {
        guard let objekt else { return nil }
        self.id = objekt.id
    }

    /// Löst die Referenz gegen den aktuellen Datenbestand in `context` auf.
    /// Bewusst ein vollständiger Fetch + Swift-seitiger Vergleich statt eines
    /// generischen `#Predicate` (in einem generischen Kontext über `T`
    /// unzuverlässig) — bei den hier relevanten Datenmengen (persönliche
    /// Einkaufs-App) unkritisch, siehe analoges Muster in
    /// `SyncImportService`/`SyncSnapshotImportService`.
    func resolved(in context: ModelContext) -> T? {
        let alle = (try? context.fetch(FetchDescriptor<T>())) ?? []
        return alle.first { $0.id == id }
    }
}
