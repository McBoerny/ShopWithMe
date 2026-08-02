import Foundation
import SwiftData

/// Erkennt ein bereits etabliertes Sync-Gruppenmitglied, das so lange nicht
/// erfolgreich synchronisiert hat, dass eigene, inzwischen gelöschte
/// Event-Dateien (siehe ``SyncExportService/eventAufbewahrungsfrist``) auf
/// anderen Geräten Löschungen enthalten haben könnten, die dieses Gerät nie
/// erfahren hat (GitHub #89, siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 9a
/// „Event-Bereinigung").
///
/// **Warum ein eigener, rein lokaler Zeitstempel statt einer Konsum-Quittung
/// zwischen Peers:** Eine echte Quittung ("hat jeder Peer meine Events schon
/// gelesen?") scheitert an volatilen Geräten — jede Definition von "wie lange
/// warten wir auf ein fehlendes Quittungs-Peer, bevor wir es ignorieren" ist
/// wieder nur eine Heuristik, nur eine Ebene tiefer versteckt. Die hier
/// beantwortete Frage ist dagegen rein lokal klärbar: "wie lange kann ICH
/// mich nicht mehr auf die Vollständigkeit MEINES EIGENEN Event-Lesens
/// verlassen" — analog ``LamportClock``, kein Cross-Device-Protokoll nötig.
///
/// **Warum kein Zusammenführen-Angebot für ein betroffenes, bereits
/// etabliertes Gerät:** additive Merges (auch das Bereich-A-Sicherheitsnetz
/// ``SyncListenSnapshot``) können nur hinzufügen, nie entfernen — ein
/// bereits etabliertes Gerät mit potenziell veralteten lokalen
/// `EinkaufslistenEintrag`/`KaufEintrag`-Karteileichen bekäme den aktuellen
/// Peer-Stand additiv draufgepackt, die eigenen Karteileichen blieben aber
/// unangetastet. Nur ein echter Ersatz (``SyncErsetzenService``) räumt das
/// strukturell weg, weil danach nichts Altes mehr übrig ist, das fälschlich
/// bestehen bleiben könnte. Ein NEU beitretendes Gerät hat dieses Risiko
/// nicht (siehe ``istEtabliertesMitglied(context:)``) und behält deshalb
/// unverändert die bestehende Zusammenführen/Ersetzen/Abbrechen-Wahl
/// (`SyncOrdnerSettingsView`, `docs/DATENSYNCHRONISATION.md` Abschnitt 6).
enum SyncAktualitaetsService {
    private static let zuletztErfolgreichSchluessel = "syncZuletztErfolgreichSynchronisiertAm"

    /// Zeitpunkt des letzten ERFOLGREICHEN Sync-Zyklus (alle fünf Teilschritte
    /// von `SyncPollingService.syncZyklus()` erfolgreich) — `nil`, falls noch
    /// nie einer erfolgreich war (frisches Gerät, oder ein bereits vor
    /// GitHub #89 etabliertes Gerät, das diesen Zeitpunkt noch nie
    /// aufgezeichnet hat, siehe ``istAusDerZeitGefallen(context:)`` für den
    /// Umgang mit diesem Migrations-Fall).
    static var zuletztErfolgreichSynchronisiertAm: Date? {
        get { UserDefaults.standard.object(forKey: zuletztErfolgreichSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: zuletztErfolgreichSchluessel) }
    }

    /// Von `SyncPollingService.syncZyklus()` nach jedem erfolgreichen
    /// Durchlauf aufgerufen.
    static func vermerkeErfolgreichenZyklus(am zeitpunkt: Date = Date()) {
        zuletztErfolgreichSynchronisiertAm = zeitpunkt
    }

    /// Ob dieses Gerät bereits Mitglied einer Sync-Gruppe ist (mindestens ein
    /// bekannter Peer aus einem früheren erfolgreichen Import,
    /// ``SyncPeerInfo``) — Voraussetzung dafür, dass „aus der Zeit gefallen"
    /// überhaupt zutreffen kann, siehe Typ-Doku.
    @MainActor
    static func istEtabliertesMitglied(context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<SyncPeerInfo>())) ?? 0) > 0
    }

    /// Ob dieses Gerät als „aus der Zeit gefallen" gilt: ein Sync-Ordner ist
    /// aktiv verknüpft, das Gerät ist bereits etabliertes Mitglied (siehe
    /// ``istEtabliertesMitglied(context:)``), UND der letzte erfolgreiche
    /// Sync-Zyklus liegt länger als ``SyncExportService/eventAufbewahrungsfrist``
    /// zurück.
    ///
    /// **Migrations-Fall:** `nil` (noch nie ein Zeitpunkt aufgezeichnet) gilt
    /// bewusst NICHT als „aus der Zeit gefallen" — sonst würde jedes bereits
    /// vor dieser Funktion etablierte Gerät beim ersten Start nach dem
    /// App-Update fälschlich einen Voll-Abgleich auslösen, obwohl es die
    /// ganze Zeit über normal synchronisiert hat. Der erste tatsächlich
    /// erfolgreiche Zyklus nach dem Update setzt den Zeitpunkt dann ganz
    /// regulär, ab dann greift die Erkennung wie vorgesehen.
    @MainActor
    static func istAusDerZeitGefallen(context: ModelContext) -> Bool {
        guard SyncOrdnerService.gewaehlterOrdner() != nil else { return false }
        guard istEtabliertesMitglied(context: context) else { return false }
        guard let zuletzt = zuletztErfolgreichSynchronisiertAm else { return false }
        return Date().timeIntervalSince(zuletzt) > SyncExportService.eventAufbewahrungsfrist
    }
}
