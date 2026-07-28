import Foundation
import SwiftData

/// Art eines ``SyncEvent`` — vorerst nur die „Bereich A"-Aktionen aus
/// `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` (zeitkritische
/// Einkaufslisten-/Abhak-Änderungen). Weitere Bereiche (Stammdaten, Historie,
/// Lernen) werden nicht pro Änderung protokolliert, sondern beim Export aus dem
/// jeweils aktuellen Modellzustand abgeleitet (siehe Plan, Abschnitt 4.2) — dafür
/// braucht es keine eigenen `SyncEventArt`-Fälle.
enum SyncEventArt: String, Codable {
    /// Entspricht ``Einkaufsliste/artikelHinzufuegen(_:context:)``.
    case artikelHinzugefuegt
    /// Entspricht ``Einkaufsliste/artikelEntfernen(_:context:)``.
    case artikelEntfernt
    /// Entspricht ``Einkaufsvorgang/artikelAbhaken(_:context:)``.
    case artikelAbgehakt
    /// Entspricht ``Einkaufsvorgang/artikelAbwaehlen(_:context:)``.
    case artikelAbgewaehlt
    /// Entspricht ``Einkaufsvorgang/artikelDauerhaftEntfernen(_:context:)``.
    case artikelDauerhaftEntfernt
}

/// Nutzlast eines ``SyncEvent`` — bewusst ein einziger, generischer Payload-Typ
/// für alle ``SyncEventArt``-Fälle (statt einem eigenen Typ je Art), da alle
/// aktuellen Bereich-A-Aktionen exakt dieselben zwei Bezugsgrößen brauchen: das
/// Objekt, auf dem die Aktion stattfand (``Einkaufsliste`` oder
/// ``Einkaufsvorgang``, je nach `art`), und den betroffenen ``Artikel``.
/// Referenziert beide bewusst über ihre app-eigene `UUID`
/// (``Einkaufsliste/id``/``Einkaufsvorgang/id``/``Artikel/id``), nie über
/// `persistentModelID` — dessen String-Darstellung ist für noch nicht
/// gespeicherte Objekte nicht eindeutig (siehe
/// ``WarengruppenDistanzService/paarSchluessel(fuer:_:)`` für den Präzedenzfall).
struct SyncEventNutzlast: Codable {
    /// `Einkaufsliste.id` oder `Einkaufsvorgang.id`, je nach `SyncEventArt`.
    var bezugsID: UUID
    var artikelID: UUID
}

/// Ein einzelnes, unveränderliches Ereignis für die geplante
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`,
/// GitHub #39) — additives SwiftData-Modell, keine Ablösung der bestehenden
/// Modelle. Phase 0 (aktueller Stand): Events werden bei lokalen Aktionen
/// aufgezeichnet (``SyncEventService``), aber noch nicht exportiert/importiert —
/// das folgt in Phase 1/2 des Plans.
@Model
final class SyncEvent {
    var id: UUID
    /// Rohwert von ``SyncEventArt`` — als `String` statt als Enum gespeichert,
    /// damit ein künftiger, hier noch unbekannter Fall beim Lesen eines von einem
    /// neueren Peer geschriebenen Events nicht zum Absturz führt (siehe
    /// ``art``-Computed-Property).
    var artRaw: String
    /// JSON-codierte ``SyncEventNutzlast``.
    var nutzlast: Data
    /// Lamport-Zähler zum Zeitpunkt der Erzeugung (siehe ``LamportClock``).
    var lamportZaehler: UInt64
    /// Geräte-ID (``DatabaseLeaseService/geraeteID``), die den Lamport-Zähler
    /// vergeben hat — zusammen mit `lamportZaehler` die eindeutige Gesamtordnung
    /// zweier Events (siehe ``LamportClock``).
    var lamportGeraeteID: String
    /// Geräte-ID, die dieses Event ursprünglich erzeugt hat — identisch zu
    /// `lamportGeraeteID`, aber semantisch getrennt gehalten (der Lamport-Wert
    /// beschreibt Ordnung, `autorGeraeteID` Urheberschaft, z.B. für einen
    /// künftigen Überkauf-Hinweis, siehe GitHub #48).
    var autorGeraeteID: String
    /// Erzeugungszeitpunkt nach Geräteuhr — nur informativ, nie für Ordnung
    /// zwischen Geräten verwendet (siehe ``LamportClock``-Doku).
    var wallClock: Date
    /// Ob dieses (lokal erzeugte) Event bereits in den eigenen Peer-Ordner
    /// exportiert wurde — in Phase 0 noch ohne Wirkung, da es noch keinen Export
    /// gibt.
    var hochgeladen: Bool

    init(
        art: SyncEventArt,
        nutzlast: SyncEventNutzlast,
        lamportZaehler: UInt64,
        lamportGeraeteID: String,
        autorGeraeteID: String,
        wallClock: Date = Date()
    ) {
        self.id = UUID()
        self.artRaw = art.rawValue
        self.nutzlast = (try? JSONEncoder().encode(nutzlast)) ?? Data()
        self.lamportZaehler = lamportZaehler
        self.lamportGeraeteID = lamportGeraeteID
        self.autorGeraeteID = autorGeraeteID
        self.wallClock = wallClock
        self.hochgeladen = false
    }
}

extension SyncEvent {
    /// ``artRaw`` als ``SyncEventArt``, `nil` bei einem unbekannten Rohwert (z.B.
    /// von einem Peer mit neuerer App-Version, die eine hier noch unbekannte Art
    /// erzeugt hat).
    var art: SyncEventArt? { SyncEventArt(rawValue: artRaw) }

    /// ``nutzlast`` dekodiert als ``SyncEventNutzlast``, `nil` bei fehlerhaften
    /// Daten.
    var nutzlastDekodiert: SyncEventNutzlast? {
        try? JSONDecoder().decode(SyncEventNutzlast.self, from: nutzlast)
    }
}
