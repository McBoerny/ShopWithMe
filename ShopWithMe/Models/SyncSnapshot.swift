import Foundation

/// Vollständiger Stammdaten-/Historien-/Lern-Snapshot dieses Geräts für die
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`,
/// GitHub #39, Phase 1b) — Bereiche B (Stammdaten), C (Historie) und D (Lernen)
/// aus Abschnitt 4.2 des Plans. Wird komplett aus dem aktuellen lokalen
/// Modellzustand abgeleitet (nicht inkrementell wie ``SyncEvent``/Bereich A) und
/// als `export.json` in den eigenen Peer-Ordner geschrieben
/// (``SyncSnapshotExportService``).
///
/// Alle Relationen werden über die app-eigene `UUID` der jeweiligen Entität
/// referenziert (nie über `persistentModelID`), damit ein Peer-Gerät sie beim
/// künftigen Import (Phase 3) unabhängig von lokalen Objekt-Identitäten auflösen
/// kann — siehe dieselbe Konvention in ``SyncEventNutzlast``.
///
/// **Bewusst enthalten, obwohl in der ursprünglichen Bereich-Tabelle des Plans
/// nicht als "Bereich B" gelistet:** ``Einkaufsliste`` (nur `id`/`name`) und
/// **alle** ``Einkaufsvorgang``e statt nur abgeschlossener — beide werden von
/// Bereich-A-`SyncEvent`s über ihre ID referenziert (`bezugsID`); ohne einen
/// eigenen Snapshot-Eintrag könnte ein Peer-Gerät ein empfangenes Event nicht
/// anwenden, dessen `bezugsID` auf eine ihm noch unbekannte Liste/einen noch
/// unbekannten, laufenden Einkauf verweist (siehe „offene Anschlussfrage“ im
/// Plan-Dokument, dort beim Entwurf dieses Typs entdeckt).
struct SyncSnapshot: Codable {
    /// Erhöht sich, wenn sich die Struktur dieses Typs (oder eines enthaltenen
    /// DTOs) inkompatibel ändert — Grundlage für künftige Migrationslogik beim
    /// Import, falls ein Peer eine ältere/neuere App-Version nutzt.
    static let aktuelleFormatVersion = 1

    var formatVersion: Int
    var erzeugtAm: Date
    var geraeteID: String

    var geschaeftsTypen: [GeschaeftTypSnapshot]
    var artikelKategorien: [ArtikelKategorieSnapshot]
    var geschaefte: [GeschaeftSnapshot]
    var artikel: [ArtikelSnapshot]
    var einkaufslisten: [EinkaufslisteSnapshot]
    var einkaufsvorgaenge: [EinkaufsvorgangSnapshot]
    var kaufEintraege: [KaufEintragSnapshot]
    var warengruppenDistanzen: [WarengruppenDistanzSnapshot]
}

struct GeschaeftTypSnapshot: Codable {
    var id: UUID
    var name: String
    var symbolName: String
    var farbeHex: String
    var sortIndex: Int
}

struct ArtikelKategorieSnapshot: Codable {
    var id: UUID
    var name: String
    var standardSymbol: String
    var standardFarbeHex: String
    var sortIndex: Int
    /// ``GeschaeftTypSnapshot/id``s, für die diese Kategorie als typische
    /// Warengruppe gilt (GitHub #5) — einseitig hier kodiert, nicht zusätzlich
    /// auf ``GeschaeftTypSnapshot`` gespiegelt (dieselbe Relationship, keine
    /// redundante Doppelspeicherung).
    var geschaeftsTypIDs: [UUID]
}

struct GeschaeftSnapshot: Codable {
    var id: UUID
    var name: String
    var typIDs: [UUID]
    var adresse: String?
    var breitengrad: Double?
    var laengengrad: Double?
    /// `nil`, solange kein individueller Radius gesetzt ist (entspricht
    /// ``Geschaeft/erkennungsradiusRaw``, nicht dem mit Fallback aufgelösten
    /// ``Geschaeft/erkennungsradius``) — der Fallback-Standardwert soll sich
    /// künftig ändern können, ohne alte Snapshots zu verfälschen.
    var erkennungsradius: Double?
    var kategorieIDs: [UUID]
    var ausgeschlosseneKategorieIDs: [UUID]
    var alternativeNamen: [String]
    /// Dauerhaft ignorierte Belegscan-Artikelnamen (GitHub #19) — laut
    /// Nutzerentscheidung eine Eigenschaft des Ladens ("obwohl es ein
    /// Lebensmittelladen ist, gibt es dort kein XY"), daher Bereich B statt
    /// gerätelokal.
    var ignorierteArtikelNamen: [String]
    /// Additive Merge-Regel (siehe Plan-Dokument Abschnitt 4.4-B): Summe der
    /// Zuwächse seit dem letzten bekannten Stand jedes Peers, nicht einfaches
    /// Überschreiben — sonst gehen Besuche verloren, die auf einem Gerät
    /// zwischen zwei Sync-Zyklen entstanden sind.
    var anzahlEinkaufsvorgaenge: Int
    /// Merge-Vorschlag: ODER-Verknüpfung (verdächtigt irgendein Gerät einen
    /// Umbau, gilt er als verdächtigt).
    var umbauVerdacht: Bool
    /// **Nicht additiv trotz Zähler-Charakter** — zählt aufeinanderfolgende
    /// unauffällige Einkäufe *in Folge*; ein naives Aufaddieren zweier
    /// Geräte-Werte würde eine so nie stattgefundene Serie vortäuschen. Für
    /// Phase 3 vorgeschlagen: gerätelokal berechnet lassen statt zu mergen
    /// (siehe Plan-Dokument).
    var unauffaelligeEinkaeufeInFolge: Int
}

struct ArtikelSnapshot: Codable {
    var id: UUID
    var name: String
    var symbolName: String
    var farbeHex: String
    var kategorieIDs: [UUID]
    var notiz: String?
    var einheit: String
    var mengenSchritt: Double
    var erstelltAm: Date
}

struct EinkaufslisteSnapshot: Codable {
    var id: UUID
    var name: String
    var erstelltAm: Date
}

struct EinkaufsvorgangSnapshot: Codable {
    var id: UUID
    var geschaeftID: UUID?
    var einkaufslisteID: UUID?
    var startZeit: Date
    var endZeit: Date?
}

struct KaufEintragSnapshot: Codable {
    var id: UUID
    var artikelID: UUID?
    var einkaufsvorgangID: UUID?
    var geschaeftID: UUID?
    var kategorieID: UUID?
    var artikelNameSnapshot: String
    var geschaeftNameSnapshot: String
    var produktName: String?
    var alternativerName: String?
    var datum: Date
    var preis: Decimal?
    var menge: Double
    var kategorieBesuchsIndex: Int?
}

struct WarengruppenDistanzSnapshot: Codable {
    var id: UUID
    var geschaeftID: UUID?
    var kategorieAID: UUID
    var kategorieBID: UUID
    var distanz: Double
}
