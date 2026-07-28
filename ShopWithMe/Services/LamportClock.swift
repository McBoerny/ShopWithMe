import Foundation

/// Logische Uhr für die geplante Datensynchronisation
/// (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`, GitHub #39) — liefert eine
/// geräteübergreifend eindeutig ordenbare Reihenfolge von ``SyncEvent``en, ohne
/// sich auf synchronisierte Geräteuhren zu verlassen.
///
/// Der Zähler selbst ist rein lokal und wird nicht direkt verglichen — die
/// Gesamtordnung zweier Events ergibt sich erst aus (`lamportZaehler`,
/// `lamportGeraeteID`) zusammen, siehe ``SyncEvent``. `beiEmpfang(fremderZaehler:)`
/// stellt sicher, dass der eigene Zähler nach dem Empfang eines fremden Events nie
/// hinter dessen Zähler zurückfällt (Lamport-Clock-Grundregel:
/// `eigen = max(eigen, fremd) + 1`).
enum LamportClock {
    /// `internal` statt `private`, damit Tests den Zähler zwischen einzelnen
    /// Testfällen zurücksetzen können (`UserDefaults.standard` ist prozessweit
    /// geteilt, ohne Reset würden sich Tests sonst gegenseitig beeinflussen).
    static let schluessel = "lamportZaehler"

    /// Aktueller Zählerstand, ohne ihn zu erhöhen — hauptsächlich für Tests.
    static var aktuellerZaehler: UInt64 {
        UInt64(UserDefaults.standard.string(forKey: schluessel) ?? "0") ?? 0
    }

    /// Erhöht den Zähler um eins und liefert den neuen Wert — aufgerufen, wenn
    /// dieses Gerät selbst ein ``SyncEvent`` erzeugt.
    @discardableResult
    static func naechsterZaehler() -> UInt64 {
        let naechster = aktuellerZaehler + 1
        UserDefaults.standard.set(String(naechster), forKey: schluessel)
        return naechster
    }

    /// Gleicht die eigene Uhr beim Empfang eines fremden Events ab — der eigene
    /// Zähler springt auf mindestens `fremderZaehler + 1`, fällt aber nie zurück,
    /// falls der eigene Zähler ohnehin schon weiter fortgeschritten ist.
    static func beiEmpfang(fremderZaehler: UInt64) {
        let naechster = max(aktuellerZaehler, fremderZaehler) + 1
        UserDefaults.standard.set(String(naechster), forKey: schluessel)
    }
}
