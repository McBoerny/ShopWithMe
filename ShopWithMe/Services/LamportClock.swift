import Foundation

/// Logische Uhr für die geplante Datensynchronisation
/// (`docs/DATENSYNCHRONISATION_VERLAUF.md`, GitHub #39) — liefert eine
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

/// Wiederverwendbarer Baustein für den „Ersetzend mit Lamport-Zähler"-Trick
/// aus `docs/DATENSYNCHRONISATION.md` §4.1a/§4.1b — bündelt die Logik (Stand
/// lesen, neuen eigenen Tick ziehen, fremden Stand beim Merge übernehmen)
/// genau einmal, statt dass jede Entität mit einem solchen Zähler
/// (``GeschaeftTyp``, ``Abteilung``, ``Geschaeft``, ``Produkt``, ``Artikel`` —
/// gleich zweimal, siehe ``Artikel/abteilungenLamportZaehler``) sie erneut
/// abschreibt. Live-Fund GitHub #173: eine zweite, praktisch identische Kopie
/// dieser drei Zeilen innerhalb derselben Entität (``Artikel``) war der
/// Auslöser, das seit `GeschaeftTyp` fünffach kopierte Muster endlich zu
/// extrahieren, statt es ein sechstes Mal abzuschreiben.
///
/// **Bewusst ein Namensraum aus statischen Funktionen über `inout UInt64?`,
/// kein Property Wrapper und kein gespeicherter Custom-Struct-Typ:** der
/// Rohwert jeder Entität bleibt ein gewöhnliches, natives
/// `private var xyzRaw: UInt64?` — der einzige Property-Typ, den SwiftDatas
/// Schema-Introspektion/`#Predicate`/Codable-Export für dieses Muster bereits
/// nachgewiesen zuverlässig unterstützt (fünffach im Einsatz, seit
/// `GeschaeftTyp`). Ein Property Wrapper oder ein gespeichertes Wert-Typ-Bündel
/// wäre zusätzlich unüblich genug (siehe `ios-swift-engineering`-Skill, „Bei
/// weniger gebräuchlichen APIs vorher aktuelle Dokumentation prüfen"), um das
/// Risiko ohne dokumentierten Bedarf einzugehen — und löst nebenbei nicht
/// einmal das eigentliche Problem: eine Entität mit MEHREREN unabhängigen
/// Zählern (wie ``Artikel``, s.o.) kann nicht zweimal an dieselbe
/// Protokoll-Property gebunden sein. Ein Namensraum aus Funktionen über
/// `inout` hat diese Einschränkung nicht — beliebig viele unabhängige Zähler
/// pro Entität, jeweils ein eigenes `Raw`-Feld, aber dieselbe geteilte Logik.
enum LamportVersionierung {
    /// Aktueller Stand, `0` falls noch nie gesetzt (Peer auf älterer
    /// App-Version, oder Entität seit Neuanlage unverändert).
    static func stand(_ roh: UInt64?) -> UInt64 { roh ?? 0 }

    /// Zieht einen neuen eigenen Tick — aufgerufen, wenn der Anwender das
    /// zugehörige Feld/die zugehörigen Felder eines bereits bestehenden
    /// Datensatzes ändert (nie bei bloßer Neuanlage).
    static func markiereGeaendert(_ roh: inout UInt64?) {
        roh = LamportClock.naechsterZaehler()
    }

    /// Übernimmt beim Sync-Merge einen vom sendenden Peer mitgebrachten
    /// Zählerstand direkt (kein neuer eigener Tick) — der Aufrufer entscheidet
    /// vorher, ob `fremderZaehler` tatsächlich neuer als der aktuelle Stand
    /// ist, bzw. seedet bedingungslos bei einer Neuanlage aus einem
    /// Remote-Eintrag (siehe `docs/DATENSYNCHRONISATION.md` §4.1a Schritt 5).
    static func uebernehmeFremdenStand(_ roh: inout UInt64?, fremderZaehler: UInt64) {
        roh = fremderZaehler
    }
}
