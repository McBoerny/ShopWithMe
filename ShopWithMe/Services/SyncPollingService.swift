import Foundation
import SwiftData

/// Adaptive Synchronisation im Vordergrund
/// (`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 5.4, Phase 4).
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
///
/// **Kein `NSFilePresenter`-basiertes Sofort-Erkennen** (kurzzeitig
/// versucht, GitHub #52-Nachfolgefund): führte auf echten Geräten zu einem
/// Hänger beim App-Start ohne Absturzprotokoll — vermutlich ein Deadlock
/// zwischen dem `presentedItemOperationQueue = .main` des Presenters und den
/// bereits bestehenden synchronen `NSFileCoordinator`-Schreibzugriffen
/// (ebenfalls auf dem Main-Thread, da `@MainActor`): Der Haupt-Thread blockiert
/// innerhalb der Schreibkoordination und wartet auf einen Presenter-Callback,
/// der ebenfalls für den Haupt-Thread eingeplant ist, aber nie drankommt.
/// Deshalb bewusst zurückgenommen zugunsten des reinen, bereits bewährten
/// Zeit-Pollings — eine spätere Wiederaufnahme müsste den Presenter auf einer
/// eigenen Hintergrund-`OperationQueue` betreiben und auf echten Geräten
/// getestet werden, nicht nur mit einem lokalen Testordner (siehe dazu die in
/// dieser Session verworfene ``SyncOrdnerBeobachter``-Klasse, kein
/// Ersatz-Sicherheitsnetz vor unentdeckten Deadlocks in genau dieser
/// Konstellation).
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

    /// Rückgabewert meldet, ob der Ordnerzugriff in allen fünf Teilschritten
    /// geklappt hat — die einzige Fehlerart, die den Zyklus insgesamt als
    /// fehlgeschlagen ausweist (siehe Doku der einzelnen Services). Vom
    /// automatischen Polling-Loop bewusst ignoriert (der versucht es beim
    /// nächsten Intervall einfach erneut); ``SyncOrdnerSettingsView`` nutzt
    /// ihn dagegen für ehrliches Erfolgs-/Fehler-Feedback beim manuellen
    /// „Jetzt synchronisieren".
    @discardableResult
    func syncZyklus() async -> Bool {
        guard let context else { return true }
        SyncDebugLogger.log(.zyklusStart, details: einkaufAktiv ? "einkaufAktiv" : "ruhend")
        let start = ContinuousClock.now

        let snapshotImportErfolgreich = await SyncSnapshotImportService.importiereSnapshots(context: context)
        let eventImportErfolgreich = await SyncImportService.importiereNeueEvents(context: context)
        let eventExportErfolgreich = await SyncExportService.exportiereNeueEvents(context: context)
        // GitHub #82: `exportierePaket` (Stammdaten/Lernen/Vorgänge/Preise/
        // Tombstones, je unabhängig fingerabdruck-geprüft) ersetzt das
        // bisherige `exportiereSnapshot` (ein monolithisches `export.json`);
        // `exportiereNeueKaeufe` schreibt die Kaufhistorie separat als
        // Append-Log, statt sie bei jedem Zyklus erneut zu kodieren.
        let paketExportErfolgreich = await SyncSnapshotExportService.exportierePaket(context: context)
        let kaeufeExportErfolgreich = await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)

        let dauer = start.duration(to: .now)
        SyncDebugLogger.log(.zyklusEnde, details: "dauer=\(dauer)")

        return snapshotImportErfolgreich && eventImportErfolgreich && eventExportErfolgreich
            && paketExportErfolgreich && kaeufeExportErfolgreich
    }
}
