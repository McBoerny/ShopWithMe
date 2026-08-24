import Foundation

/// Sitzungsweite Security-Scope-Verwaltung für den Sync-Ordner (GitHub #171).
///
/// **Ersetzt das bisherige Muster** (jede Sync-Teilfunktion öffnet/schließt
/// ihren eigenen Scope auf demselben externen Bookmark, mehrmals pro
/// Sync-Zyklus, alle 2–60s) durch genau ein Öffnen pro App-Vordergrund-
/// Sitzung. Grund: wiederholtes Öffnen/Schließen desselben Security-Scoped-
/// Bookmarks destabilisiert den Zugriff auf echten Geräten nachweisbar
/// dauerhaft (`docs/DATENSYNCHRONISATION_VERLAUF.md` §30, dort lokal für
/// eine verschachtelte Schleife behoben; GitHub #171 ist dieselbe
/// Fehlerklasse auf Ebene wiederholter Zyklen — `sandbox_extension_consume
/// error=[12: Cannot allocate memory]` nach ca. 10–15 Minuten Dauerbetrieb,
/// danach kein Zugriff mehr für den Rest der App-Sitzung).
///
/// **Es gibt zu jedem Zeitpunkt genau einen relevanten externen Ordner**
/// (`SyncOrdnerService.gewaehlterOrdner()`) — deshalb reicht ein einzelner
/// globaler `URL?`-Zustand, kein Referenzzähler.
///
/// **Aufrufregel (Lehre aus §30):** ``offen`` öffnet NIE selbst einen Scope —
/// nur ``oeffnen()``/``sicherstellenOffen()`` tun das. Rekurrierende
/// Sync-Teilfunktionen (innerhalb eines laufenden ``SyncPollingService``-
/// Zyklus) nutzen ausschließlich ``offen`` und setzen einen bereits offenen
/// Scope voraus, statt selbst einen zu öffnen.
@MainActor
enum SyncOrdnerZugriffsSitzung {
    private static var offenerOrdner: URL?

    /// Öffnet den Scope für die aktuelle Vordergrund-Sitzung. Ist bereits
    /// derselbe Bookmark offen, wirkungslos (kein erneutes Öffnen). Ist ein
    /// ANDERER Bookmark offen (Ordnerwechsel), wird zuerst der alte
    /// geschlossen. Von ``SyncPollingService/starten(context:)`` sowie bei
    /// jedem Ordnerwechsel (`SyncOrdnerSettingsView.ordnerFestlegen(_:)`)
    /// aufzurufen.
    @discardableResult
    static func oeffnen() -> Bool {
        guard let ordner = SyncOrdnerService.gewaehlterOrdner() else {
            schliessen()
            return false
        }
        if let bereitsOffen = offenerOrdner {
            guard bereitsOffen != ordner else { return true }
            schliessen()
        }
        let erfolgreich = ordner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(
            aufrufstelle: "SyncOrdnerZugriffsSitzung.oeffnen", erfolgreich: erfolgreich
        )
        guard erfolgreich else { return false }
        offenerOrdner = ordner
        return true
    }

    /// Schließt den Scope, falls offen. Von
    /// ``SyncPollingService/stoppen()`` sowie bei
    /// `SyncOrdnerService.ordnerEntfernen()`/`ordnerEntfernenUndPeersVergessen(...)`
    /// aufzurufen.
    static func schliessen() {
        guard let ordner = offenerOrdner else { return }
        ordner.stopAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "SyncOrdnerZugriffsSitzung.oeffnen")
        offenerOrdner = nil
    }

    /// Der aktuell offene Sync-Ordner, sofern die Sitzung gerade läuft —
    /// öffnet selbst NIE einen Scope (siehe Typ-Doku). Für alle
    /// rekurrierenden Sync-Teilfunktionen, die nur innerhalb eines bereits
    /// laufenden Polling-Zyklus aufgerufen werden.
    static var offen: URL? { offenerOrdner }

    /// Wie ``offen``, öffnet aber bei Bedarf selbst (idempotent) — für
    /// einmalige/nutzerausgelöste Aktionen außerhalb des Polling-Loops
    /// (z.B. `DebuggingView`, `KaufEintragBereinigungService`), die auch
    /// funktionieren müssen, wenn der Loop gerade nicht läuft.
    @discardableResult
    static func sicherstellenOffen() -> Bool {
        offenerOrdner != nil || oeffnen()
    }
}
