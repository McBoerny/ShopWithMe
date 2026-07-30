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
    ///
    /// **Version 2 (Architektur-Revision „Alternative A"):** ergänzt
    /// ``einkaufslistenEintraege`` (vollständiger Einkaufslisten-Inhalt statt
    /// nur Identität — Bereich A bekommt dasselbe Sicherheitsnetz wie Bereich
    /// B: ein Peer, der Events verpasst hat oder neu beitritt, holt sich den
    /// fehlenden Stand beim nächsten Snapshot-Import nach) und ``tombstones``
    /// (Löschungen von Bereich-B-Entitäten, damit sie von anderen Peers nicht
    /// unwissentlich wiederbelebt werden). Keine Rückwärtskompatibilität zu
    /// Version 1 nötig (Projekt ohne feste Nutzerbasis, siehe
    /// `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`).
    ///
    /// **Version 3 (G-Counter-Korrektur, Abschnitt 17):**
    /// ``GeschaeftSnapshot/anzahlEinkaufsvorgaenge`` (bereits gemergter
    /// Gesamtwert) wurde zu ``GeschaeftSnapshot/eigeneAnzahlEinkaufsvorgaenge``
    /// (nur der rein lokale Anteil des exportierenden Geräts) — die alte
    /// Feldbedeutung führte zu unbegrenzt aufschaukelndem Doppelzählen bei
    /// jedem Sync-Zyklus. Wieder keine Rückwärtskompatibilität nötig; bis
    /// beide Geräte einmal mit dem neuen Code exportiert haben, wird das
    /// jeweils andere `export.json` beim Decodieren übergangsweise wie „kein
    /// Snapshot vorhanden" behandelt (stiller Fehlschlag über `try?`,
    /// selbstheilend nach dem nächsten eigenen Export).
    static let aktuelleFormatVersion = 3

    var formatVersion: Int
    var erzeugtAm: Date
    var geraeteID: String
    /// Anzeigename dieses Geräts (``DatabaseLeaseService/geraeteName``) — nicht
    /// für Bereich-B-Matching genutzt, sondern nur zur Auflösung von
    /// `SyncEvent.autorGeraeteID` in eine menschenlesbare Form, siehe
    /// ``SyncPeerInfo`` (GitHub #48, Überkauf-Hinweis).
    var geraeteName: String

    var geschaeftsTypen: [GeschaeftTypSnapshot]
    var artikelKategorien: [ArtikelKategorieSnapshot]
    var geschaefte: [GeschaeftSnapshot]
    var artikel: [ArtikelSnapshot]
    var einkaufslisten: [EinkaufslisteSnapshot]
    /// Vollständiger Einkaufslisten-Inhalt (welcher ``Artikel`` mit welcher
    /// Menge/Notiz auf welcher ``Einkaufsliste`` steht) — additives
    /// Sicherheitsnetz neben den weiterhin bestehenden, schnelleren
    /// Bereich-A-`SyncEvent`s (`artikelHinzugefuegt`/`artikelEntfernt`).
    /// **Nur additiv beim Import** (fehlende Einträge werden ergänzt, nie
    /// vorhandene entfernt) — Entfernen bleibt Aufgabe der Events, dieser
    /// Snapshot-Teil fängt nur verpasste/zu spät kommende Hinzufügungen auf.
    var einkaufslistenEintraege: [EinkaufslistenEintragSnapshot]
    var einkaufsvorgaenge: [EinkaufsvorgangSnapshot]
    var kaufEintraege: [KaufEintragSnapshot]
    var warengruppenDistanzen: [WarengruppenDistanzSnapshot]
    /// Absichtliche Löschungen von Bereich-B-Entitäten (``Geschaeft``,
    /// ``Artikel``, ``ArtikelKategorie``, ``Einkaufsliste``, ``KaufEintrag``),
    /// siehe ``SyncTombstone``.
    var tombstones: [SyncTombstoneSnapshot]
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
    /// NUR der rein lokal auf dem exportierenden Gerät entstandene Anteil von
    /// ``Geschaeft/anzahlEinkaufsvorgaenge`` (``Geschaeft/eigeneAnzahlEinkaufsvorgaenge``)
    /// — bewusst NICHT der bereits gemergte Gesamtwert. G-Counter-Muster
    /// (Plan-Dokument Abschnitt 4.4-B, korrigiert in Abschnitt 17): jeder
    /// Beitrag wird beim Empfänger einmalig unter (Peer, Geschäft) gemerkt
    /// (``SyncPeerZaehlerStand``), der tatsächliche Gesamtwert ergibt sich
    /// erst beim Lesen aus der Summe aller bekannten Beiträge. Die
    /// ursprüngliche „Delta seit letztem Gesamtwert"-Regel zählte denselben
    /// Beitrag bei jedem Hin-und-Her zwischen zwei Geräten erneut mit.
    var eigeneAnzahlEinkaufsvorgaenge: Int
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

struct EinkaufslistenEintragSnapshot: Codable {
    var einkaufslisteID: UUID
    var artikelID: UUID
    var menge: Double
    var notiz: String?
}

struct SyncTombstoneSnapshot: Codable {
    var entitaetsArt: String
    var geloeschteID: UUID
    var geloeschtAm: Date
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
