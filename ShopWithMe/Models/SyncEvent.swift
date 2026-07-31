import Foundation
import SwiftData

/// Art eines ``SyncEvent`` — vorerst nur die „Bereich A"-Aktionen aus
/// `docs/DATENSYNCHRONISATION_VERLAUF.md` (zeitkritische
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
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_VERLAUF.md`,
/// GitHub #39) — additives SwiftData-Modell, keine Ablösung der bestehenden
/// Modelle. Events werden bei lokalen Aktionen aufgezeichnet
/// (``SyncEventService``) und in den eigenen Peer-Ordner exportiert
/// (``SyncExportService``, Phase 1). Import fremder Events ist Phase 2.
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
    /// exportiert wurde (siehe ``SyncExportService``).
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

    /// Rekonstruiert ein von einem Peer empfangenes Event unverändert (Phase 2,
    /// ``SyncEventService/uebernehmen(_:context:)``) — im Unterschied zum
    /// regulären Init werden `id`, `lamportZaehler`, `lamportGeraeteID` und
    /// `autorGeraeteID` direkt übernommen statt neu vergeben, damit die
    /// ursprüngliche Urheberschaft erhalten bleibt (sonst würde dieses Gerät sich
    /// fälschlich eine fremde Aktion zuschreiben). `hochgeladen` wird auf `true`
    /// gesetzt, da dieses Event bereits in einem fremden Peer-Ordner liegt und
    /// nicht zusätzlich in den eigenen re-exportiert werden soll.
    init(empfangen: SyncEventExportDarstellung) {
        self.id = empfangen.id
        self.artRaw = empfangen.art
        self.nutzlast = empfangen.nutzlast
        self.lamportZaehler = empfangen.lamportZaehler
        self.lamportGeraeteID = empfangen.lamportGeraeteID
        self.autorGeraeteID = empfangen.autorGeraeteID
        self.wallClock = empfangen.wallClock
        self.hochgeladen = true
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

    /// Als eigenständiger Codable-Wert statt das `@Model` selbst zu kodieren —
    /// SwiftData-Modellklassen sind nicht dafür ausgelegt, direkt durch
    /// `JSONEncoder` zu laufen (u.a. wegen interner Storage-Attribute).
    var exportDarstellung: SyncEventExportDarstellung {
        SyncEventExportDarstellung(
            id: id,
            art: artRaw,
            nutzlast: nutzlast,
            lamportZaehler: lamportZaehler,
            lamportGeraeteID: lamportGeraeteID,
            autorGeraeteID: autorGeraeteID,
            wallClock: wallClock
        )
    }
}

/// Peer-Dateiformat für ein einzelnes exportiertes ``SyncEvent`` (siehe
/// ``SyncExportService``, `docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 5.1). Feldgleich zu ``SyncEvent``, aber als reiner Wert-Typ, den
/// `JSONEncoder`/`JSONDecoder` direkt verarbeiten können.
struct SyncEventExportDarstellung: Codable {
    var id: UUID
    var art: String
    var nutzlast: Data
    var lamportZaehler: UInt64
    var lamportGeraeteID: String
    var autorGeraeteID: String
    var wallClock: Date
}
