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
///
/// **`NSMetadataQuery`-Weckimpuls ausprobiert und wieder entfernt** (GitHub
/// #91, erster Anlauf): Ein kurz laufender `NSMetadataQuery`-Aufruf vor jedem
/// Zyklus sollte iCloud aktiv zum Abgleich anstoßen. Live-Test zeigte
/// keinerlei Wirkung. Der zweite Anlauf (koordinierte Verzeichnis-Listings,
/// ``SyncDateiZugriff/listeKoordiniert(_:)``) half laut Live-Test ebenfalls
/// nicht. Details zu beiden in `docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 39/40.
///
/// **Dritter Anlauf: langlebige `NSMetadataQuery`** (``SyncICloudAenderungsBeobachter``):
/// Apples „Designing for Documents in iCloud"-Guide dokumentiert
/// `NSMetadataQuery` explizit als korrekten iOS-Weg, neue Fremd-Dateien zu
/// entdecken — aber nur, wenn sie früh gestartet und dauerhaft am Laufen
/// gehalten wird (`enableUpdates()` + `NSMetadataQueryDidUpdateNotification`),
/// nicht als kurzer Einzelaufruf wie beim ersten Anlauf. Zusätzlich diesmal
/// pro Peer-Unterordner gescoped, nicht nur auf die Sync-Ordner-Wurzel
/// (unbeantworteter Apple-Forenthread #783958: die Query beobachtet
/// zuverlässig nur die Wurzel jedes gescopten Ordners). Details in
/// `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 41.
@MainActor
final class SyncPollingService: ObservableObject {
    /// `static var` statt `let`, damit Tests sie auf sehr kurze Werte setzen
    /// können, ohne auf reale Wartezeiten angewiesen zu sein.
    static var intervallAktivesEinkaufen: Duration = .seconds(5)
    static var intervallRuhend: Duration = .seconds(60)

    /// Von `EinkaufslisteView` gesetzt, solange der Einkaufen-Bildschirm
    /// sichtbar ist — schaltet auf das schnellere Intervall um.
    var einkaufAktiv = false

    /// `true`, sobald der Rückkehrer-Check beim Loop-Start (``starten(context:)``)
    /// festgestellt hat, dass der eigene Peer-Ordner nicht mehr existiert (die
    /// Gruppe hat dieses Gerät entfernt) — Backup + Sync-Ordner-Entfernung sind
    /// zu diesem Zeitpunkt bereits erfolgt, dies ist nur noch das Signal für
    /// die UI (`RootView`), einen erklärenden Dialog zu zeigen.
    @Published var wurdeAusGruppeEntfernt = false

    private var context: ModelContext?
    private var schleife: Task<Void, Never>?
    private let icloudBeobachter = SyncICloudAenderungsBeobachter()
    private let connector: any SyncConnector = FileShareSyncConnector()

    /// Race-frei synchron in `ShopWithMeApp.init()` gesetzt — BEVOR `body`
    /// (und damit `.task`/`.onChange(of: scenePhase)`, die beiden
    /// nebenläufigen Aufrufer von ``starten(context:)`` ohne garantierte
    /// Reihenfolge zueinander) überhaupt existieren. Ein früherer Ansatz
    /// reichte dieselbe Information stattdessen als Parameter NUR über den
    /// `.task`-Aufrufer durch — verlor das Rennen aber praktisch immer gegen
    /// `.onChange(of: scenePhase)` (feuert beim App-Start meist SOFORT,
    /// während `.task` noch auf den asynchronen Peer-Import wartet), sodass
    /// der Skip faktisch nie griff (Live-Fund direkt nach dem ersten
    /// Fix-Versuch, siehe `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt
    /// 49). Wird beim ersten ``starten(context:)``-Aufruf dieser Sitzung
    /// konsumiert (auf `false` zurückgesetzt) — dank des `schleife == nil`-
    /// Guards direkt darunter ist das trotz zweier möglicher Aufrufer
    /// eindeutig, da beide auf dem `@MainActor` seriell laufen. Bewusst
    /// `nonisolated(unsafe)` statt actor-isoliert (analog
    /// ``DatabaseLeaseService/storeURL``), damit `ShopWithMeApp.init()` —
    /// selbst nicht `@MainActor` — den Wert synchron setzen kann, bevor
    /// `body` (und damit jeder mögliche Aufrufer von ``starten(context:)``)
    /// überhaupt existiert.
    nonisolated(unsafe) static var ueberspringeRueckkehrerErkennungBeimNaechstenStart = false

    /// Startet den Polling-Loop (wirkungslos, falls bereits gestartet) — führt
    /// sofort einen ersten Sync-Zyklus aus, bevor das erste Intervall
    /// abgewartet wird.
    func starten(context: ModelContext) {
        self.context = context
        icloudBeobachter.starten { [weak self] in
            Task { @MainActor [weak self] in
                await self?.syncZyklus()
            }
        }
        guard schleife == nil else { return }
        let ueberspringeRueckkehrerErkennung = Self.ueberspringeRueckkehrerErkennungBeimNaechstenStart
        Self.ueberspringeRueckkehrerErkennungBeimNaechstenStart = false
        // Niedrige Priorität (GitHub #55): der Loop startet direkt beim
        // App-Start bzw. bei jeder Rückkehr aus dem Hintergrund, exakt dann,
        // wenn SwiftUI mit dem initialen Rendering/Layout um den MainActor
        // konkurriert. `.utility` signalisiert dem kooperativen Scheduler,
        // UI-Arbeit bei Bedarf vorzuziehen, statt den Sync-Zyklus stur mit
        // Standardpriorität dazwischenzudrängen.
        schleife = Task(priority: .utility) { [weak self] in
            // Rückkehrer-Erkennung (Peer-Lebenszyklus): läuft als allererster
            // Schritt, VOR dem eigentlichen Sync-Loop — dieser `Task`-Block
            // ist der einzige Punkt, der garantiert vor jedem möglichen
            // `syncZyklus()` dieser Session erreicht wird, unabhängig davon,
            // ob `starten(context:)` über `RootView().task` oder
            // `.onChange(of: scenePhase)` ausgelöst wurde. Bei `false`
            // (definitiv ausgeschlossen) sofort Backup + Sync-Ordner-
            // Entfernung, KEIN weiterer `syncZyklus()` in dieser Session —
            // dadurch kann kein veralteter Bestand mehr exportiert werden,
            // bevor der Nutzer überhaupt vom Ausschluss erfährt.
            //
            // `ueberspringeRueckkehrerErkennung` (oben konsumiert, siehe
            // Doku bei ``ueberspringeRueckkehrerErkennungBeimNaechstenStart``)
            // lässt genau diesen einen Aufruf aus — die Prüfung greift beim
            // nächsten regulären Vordergrund-Wechsel wieder normal.
            if !ueberspringeRueckkehrerErkennung,
               let selbst = self,
               await selbst.connector.binIchNochMitglied() == false {
                _ = try? SyncErsetzenService.erstelleBackup(context: context, grund: "Vor Gruppen-Ausschluss")
                SyncOrdnerService.ordnerEntfernen()
                self?.wurdeAusGruppeEntfernt = true
                return
            }
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
        icloudBeobachter.stoppen()
    }

    /// Rückgabewert meldet, ob der Ordnerzugriff in allen fünf Teilschritten
    /// geklappt hat — die einzige Fehlerart, die den Zyklus insgesamt als
    /// fehlgeschlagen ausweist (siehe Doku der einzelnen Services). Vom
    /// automatischen Polling-Loop bewusst ignoriert (der versucht es beim
    /// nächsten Intervall einfach erneut); ``SyncOrdnerSettingsView`` nutzt
    /// ihn dagegen für ehrliches Erfolgs-/Fehler-Feedback beim manuellen
    /// „Jetzt synchronisieren".
    ///
    /// **Re-Entranz-Schutz (Nutzerbericht 2026-08-11):** diese Funktion hat
    /// VIER voneinander unabhängige, unkoordinierte Auslöser — den eigenen
    /// Polling-Loop (``starten(context:)``), den ``SyncICloudAenderungsBeobachter``-
    /// Callback (spawnt bei JEDER Fremdänderungs-Benachrichtigung einen
    /// frischen, unabhängigen `Task`), ``RootView/vollAbgleichAusloesen()``
    /// und ``SyncOrdnerSettingsView/jetztSynchronisieren()``. `@MainActor`
    /// verhindert dabei nur, dass zwei Stücke Code im exakt selben Instant
    /// laufen — nicht, dass ein zweiter Aufruf startet, während der erste an
    /// einem seiner vielen `await`-Punkte (Datei-I/O) unterbrochen ist. Live
    /// bestätigt: zwei nebenläufige, unkoordinierte Durchläufe von
    /// ``SyncSnapshotImportService/importiereSnapshots(context:)`` gegen
    /// denselben `ModelContext` korrumpierten den sichtbaren Listenstand
    /// (`sync_einkaufslisten_stand` sprang binnen derselben Sekunde von 0 auf
    /// 6, ein späterer Zyklus „pendelte" bei 3 ein — drei tatsächlich noch
    /// offene Artikel verschwanden spurlos). ``SyncImportService/versucheVollstaendigenZyklusZuStarten()``
    /// (siehe dort für die vollständige Begründung inkl. Log-Beleg) lässt
    /// einen zweiten, überlappenden Aufruf jetzt seinen gesamten Durchlauf
    /// überspringen, statt einen konkurrierenden Merge-Pass zu starten —
    /// `true` (kein Fehler) statt `false`, da „ein anderer Zyklus deckt das
    /// bereits ab" kein Ordnerzugriffs-Fehlschlag ist.
    @discardableResult
    func syncZyklus() async -> Bool {
        guard let context else { return true }
        guard SyncImportService.versucheVollstaendigenZyklusZuStarten() else { return true }
        defer { SyncImportService.beendeVollstaendigenZyklus() }
        // Kein Sync-Ordner konfiguriert: nichts zu tun, kein Fehler.
        guard SyncOrdnerService.gewaehlterOrdner() != nil else { return true }
        // Scope einmalig für den gesamten Zyklus öffnen — die fünf Teil-Services
        // öffnen ihn darunter nochmals (Ref-Count ≥ 1 bleibt garantiert); verhindert
        // das bisherige Auf-0-Fallen zwischen den Service-Aufrufen.
        guard await connector.beginneZugriff() else { return false }
        defer { connector.beendeZugriff() }
        SyncDebugLogger.log(.zyklusStart, details: einkaufAktiv ? "einkaufAktiv" : "ruhend")
        let start = ContinuousClock.now

        // Periodische Reaktivierung zusätzlich zur reaktiven (bei jeder
        // eigenen Benachrichtigung) — schließt die Lücke, dass ein gerade
        // erst gewechselter Sync-Ordner sonst erst nach der ersten
        // Fremdänderung im NEUEN Ordner erkannt würde.
        icloudBeobachter.aktualisiereScopeFallsNoetig()

        let snapshotImportErfolgreich = await SyncSnapshotImportService.importiereSnapshots(context: context)
        let eventImportErfolgreich = await SyncImportService.importiereNeueEvents(context: context)
        let eventExportErfolgreich = await SyncExportService.exportiereNeueEvents(context: context)
        // GitHub #82: `exportierePaket` (Stammdaten/Lernen/Vorgänge/Preise/
        // Tombstones, je unabhängig fingerabdruck-geprüft) ersetzt das
        // bisherige `exportiereSnapshot` (ein monolithisches `export.json`);
        // `exportiereNeueKaeufe` schreibt die Kaufhistorie separat als
        // Append-Log, statt sie bei jedem Zyklus erneut zu kodieren.
        // Peer-Lebenszyklus, Baustein C0: `importErfolgreich` bestimmt, ob
        // `manifest.json` einen neuen Zeitstempel bekommt (siehe
        // ``SyncPeerManifest``-Typ-Doku) — nur der Import-Teil zählt, nicht
        // der Export-Erfolg dieses Aufrufs selbst.
        let paketExportErfolgreich = await SyncSnapshotExportService.exportierePaket(
            context: context, importErfolgreich: snapshotImportErfolgreich && eventImportErfolgreich
        )
        let kaeufeExportErfolgreich = await SyncKaeufeExportService.exportiereNeueKaeufe(context: context)

        let dauer = start.duration(to: .now)
        SyncDebugLogger.log(.zyklusEnde, details: "dauer=\(dauer)")

        let erfolgreich = snapshotImportErfolgreich && eventImportErfolgreich && eventExportErfolgreich
            && paketExportErfolgreich && kaeufeExportErfolgreich
        // GitHub #89: Grundlage für ``SyncAktualitaetsService/istAusDerZeitGefallen(context:)``
        // — nur bei tatsächlichem Erfolg vermerkt, ein fehlgeschlagener
        // Ordnerzugriff (Berechtigung entzogen, Ordner kurzzeitig nicht
        // erreichbar) darf die Uhr nicht weiterlaufen lassen.
        if erfolgreich {
            SyncAktualitaetsService.vermerkeErfolgreichenZyklus()
        }
        return erfolgreich
    }
}
