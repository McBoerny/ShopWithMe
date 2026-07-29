import Foundation
import SwiftData

/// Adaptive Synchronisation im Vordergrund
/// (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` Abschnitt 5.4, Phase 4).
///
/// Läuft ausschließlich, während die App aktiv sichtbar ist — iOS pausiert
/// einen zeitgesteuerten Loop wie diesen automatisch, sobald die App in den
/// Hintergrund wechselt (siehe ``ShopWithMeApp``, das ``starten(context:)``/
/// ``stoppen()`` an `scenePhase` koppelt). Für echte Synchronisation bei
/// gesperrtem Gerät oder geschlossener App bräuchte es das
/// `BackgroundTasks`-Framework mit eigenen Entitlements — bewusst nicht Teil
/// dieser Phase.
///
/// **Intervall situationsabhängig** (Nutzerentscheidung, abweichend von der
/// ursprünglichen starren 5s/30s-Tabelle im Plan-Dokument): kurzes Intervall
/// (``intervallAktivesEinkaufen``), solange gemeinsam eingekauft wird
/// (``einkaufAktiv``, von `EinkaufslisteView` gesetzt), sonst das längere
/// Ruhe-Intervall (``intervallRuhend``) — plus ein sofortiger Sync-Zyklus
/// beim ``starten(context:)`` selbst (App-Start bzw. Rückkehr in den
/// Vordergrund), nicht erst nach dem ersten Intervall.
@MainActor
final class SyncPollingService: ObservableObject {
    /// `static var` statt `let`, damit Tests sie auf sehr kurze Werte setzen
    /// können, ohne auf reale Wartezeiten angewiesen zu sein.
    static var intervallAktivesEinkaufen: Duration = .seconds(5)
    static var intervallRuhend: Duration = .seconds(60)

    /// Von `EinkaufslisteView` gesetzt, solange der Einkaufen-Bildschirm
    /// sichtbar ist — schaltet auf das schnellere Intervall um.
    var einkaufAktiv = false

    private var context: ModelContext?
    private var schleife: Task<Void, Never>?

    /// Startet den Polling-Loop (wirkungslos, falls bereits gestartet) — führt
    /// sofort einen ersten Sync-Zyklus aus, bevor das erste Intervall
    /// abgewartet wird.
    func starten(context: ModelContext) {
        self.context = context
        guard schleife == nil else { return }
        // Niedrige Priorität (GitHub #55): der Loop startet direkt beim
        // App-Start bzw. bei jeder Rückkehr aus dem Hintergrund, exakt dann,
        // wenn SwiftUI mit dem initialen Rendering/Layout um den MainActor
        // konkurriert. `.utility` signalisiert dem kooperativen Scheduler,
        // UI-Arbeit bei Bedarf vorzuziehen, statt den Sync-Zyklus stur mit
        // Standardpriorität dazwischenzudrängen.
        schleife = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.syncZyklus()
                guard !Task.isCancelled else { return }
                let intervall = (self?.einkaufAktiv ?? false) ? Self.intervallAktivesEinkaufen : Self.intervallRuhend
                try? await Task.sleep(for: intervall)
            }
        }
    }

    /// Beendet den Polling-Loop — der laufende Sync-Zyklus (falls einer
    /// gerade läuft) wird noch zu Ende geführt, es startet nur kein weiterer.
    func stoppen() {
        schleife?.cancel()
        schleife = nil
    }

    func syncZyklus() async {
        guard let context else { return }
        SyncDebugLogger.log(.zyklusStart, details: einkaufAktiv ? "einkaufAktiv" : "ruhend")
        let start = ContinuousClock.now

        await SyncSnapshotImportService.importiereSnapshots(context: context)
        await SyncImportService.importiereNeueEvents(context: context)
        await SyncExportService.exportiereNeueEvents(context: context)
        await SyncSnapshotExportService.exportiereSnapshot(context: context)

        let dauer = start.duration(to: .now)
        SyncDebugLogger.log(.zyklusEnde, details: "dauer=\(dauer)")
    }
}
