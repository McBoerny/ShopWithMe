import Foundation

/// Vollständiger Stammdaten-/Historien-/Lern-Snapshot dieses Geräts für die
/// Datensynchronisation (`docs/DATENSYNCHRONISATION_VERLAUF.md`,
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
    /// `docs/DATENSYNCHRONISATION_VERLAUF.md`).
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
    ///
    /// **Version 4 (Preishistorie-Entkopplung, GitHub #76):** ``preispunkte``
    /// und ``artikelAliase`` neu hinzugekommen, ``KaufEintragSnapshot`` verliert
    /// dafür `preis`/`produktName`/`alternativerName` — die Preishistorie-Rolle
    /// ist nach ``Preispunkt`` verschoben (unabhängig vom laufenden
    /// ``Einkaufsvorgang``, nur bei tatsächlicher Preisänderung ein neuer
    /// Eintrag statt bei jedem Kauf, siehe `docs/BELEGSCAN.md`).
    /// Alias-Lernen (vormals implizit über die komplette ``KaufEintrag``-
    /// Historie) ist jetzt ein eigener, kleiner ``ArtikelAlias``-Bestand.
    /// Wieder keine Rückwärtskompatibilität nötig, siehe Version 3.
    ///
    /// **Version 5 (G-Counter für ``WarengruppenDistanzSnapshot``, GitHub
    /// #87):** ``WarengruppenDistanzSnapshot/distanz`` wurde beim Merge naiv
    /// im Verhältnis 50/50 gemittelt, unabhängig davon, wie viele
    /// Beobachtungen hinter jeder Seite steckten — reihenfolgeabhängig und
    /// anfällig für Ausreißer. Neu: ``WarengruppenDistanzSnapshot/eigeneAnzahlBeobachtungen``
    /// (nur der rein lokale Anteil, analog zu
    /// ``GeschaeftSnapshot/eigeneAnzahlEinkaufsvorgaenge`` seit Version 3)
    /// macht daraus einen echten gewichteten Mittelwert
    /// (``WarengruppenDistanzPeerZaehlerStand``). Wieder keine
    /// Rückwärtskompatibilität nötig, siehe Version 3.
    static let aktuelleFormatVersion = 5

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
    /// Preishistorie (seit Version 4, GitHub #76) — unabhängig vom
    /// ``Einkaufsvorgang``, siehe ``Preispunkt``.
    var preispunkte: [PreispunktSnapshot]
    /// Gelernte Beleg-/Preisschild-Aliase (seit Version 4, GitHub #76), siehe
    /// ``ArtikelAlias``.
    var artikelAliase: [ArtikelAliasSnapshot]
    var warengruppenDistanzen: [WarengruppenDistanzSnapshot]
    /// Absichtliche Löschungen von Bereich-B-Entitäten (``Geschaeft``,
    /// ``Artikel``, ``ArtikelKategorie``, ``Einkaufsliste``, ``KaufEintrag``,
    /// ``Preispunkt``), siehe ``SyncTombstone``.
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
    var datum: Date
    var menge: Double
    var kategorieBesuchsIndex: Int?
}

struct WarengruppenDistanzSnapshot: Codable {
    var id: UUID
    var geschaeftID: UUID?
    var kategorieAID: UUID
    var kategorieBID: UUID
    var distanz: Double
    /// NUR der rein lokal auf dem exportierenden Gerät entstandene Anteil von
    /// ``WarengruppenDistanz/beobachtungsAnzahl`` (``WarengruppenDistanz/eigeneBeobachtungsAnzahl``)
    /// — bewusst NICHT der bereits gemergte Gesamtwert. G-Counter-Muster
    /// (seit Version 5, GitHub #87), exaktes Gegenstück zu
    /// ``GeschaeftSnapshot/eigeneAnzahlEinkaufsvorgaenge``: jeder Beitrag wird
    /// beim Empfänger einmalig unter (Peer, Distanz-Zeile) gemerkt
    /// (``WarengruppenDistanzPeerZaehlerStand``), der tatsächliche Gesamtwert
    /// ergibt sich erst beim Lesen aus der Summe aller bekannten Beiträge.
    var eigeneAnzahlBeobachtungen: Int
}

struct PreispunktSnapshot: Codable {
    var id: UUID
    var artikelID: UUID?
    var geschaeftID: UUID?
    var preis: Decimal
    var datum: Date
    var produktName: String?
    var alternativerName: String?
    var artikelNameSnapshot: String
    var geschaeftNameSnapshot: String
}

struct ArtikelAliasSnapshot: Codable {
    var id: UUID
    var erkannterName: String
    var alternativerName: String?
    var artikelID: UUID?
}

// MARK: - Paket-Format für den laufenden Peer-Sync-Zyklus (GitHub #82)

/// **`SyncSnapshot` bleibt unverändert bestehen**, dient aber seit GitHub #82
/// nur noch dem lokalen Backup/Wiederherstellungs-Pfad (``SyncErsetzenService``,
/// GitHub #63) — dort ist ein einzelner, vollständiger In-Memory-Snapshot
/// weiterhin die richtige Form (ein Backup vor Ort, keine Datei-Größen-/
/// Wiederholungsprobleme wie beim laufenden Peer-Sync-Zyklus).
///
/// Für den eigentlichen Peer-zu-Peer-Datenaustausch (bisher eine einzige,
/// monolithische `export.json`, bei jedem Sync-Zyklus komplett neu geschrieben
/// — Analyse-Fund: 56% Dateigröße allein durch `kaufEintraege`, plus
/// unnötiges Neuschreiben unveränderter Teile) ersetzen diese Typen das
/// Monolith-Format durch mehrere unabhängig fingerabdruck-geprüfte Teile
/// (``SyncSnapshotExportService/erstellePaketTeile(context:)``) plus ein
/// Append-Log für `KaufEintrag` (``SyncKaeufeExportService``, analog dem
/// bereits bestehenden Bereich-A-Eventlog `events/`). **Harter Formatschnitt**
/// (siehe `docs/EXPORT_PAKET_UMBAU.md`): kein Dual-Read, dieselbe
/// „keine Rückwärtskompatibilität nötig"-Haltung wie bei den bisherigen
/// `SyncSnapshot.formatVersion`-Sprüngen.

/// Kleine, immer (jeden Zyklus, unabhängig vom Fingerabdruck-Skip der übrigen
/// Teile) geschriebene Datei — ersetzt das bisherige `erzeugtAm`/`formatVersion`
/// auf dem Monolithen als Peer-Alters-Gate
/// (``SyncSnapshotImportService/maximalesSnapshotAlter``). Muss unbedingt bei
/// jedem Zyklus aktualisiert werden, auch wenn kein Teil sich inhaltlich
/// geändert hat — sonst würde ein seit Tagen inhaltlich unverändertes, aber
/// weiterhin aktives Gerät fälschlich als verwaist gelten (siehe
/// `SyncSnapshotExportService`, Abschnitt „Schreibt nur bei tatsächlich
/// geändertem Inhalt").
struct SyncPeerManifest: Codable {
    /// Eigene, vom Bereich-B/C/D-`SyncSnapshot.formatVersion` unabhängige
    /// Versionierung des Paket-Layouts selbst.
    static let aktuelleFormatVersion = 1
    var formatVersion: Int
    var erzeugtAm: Date
    var geraeteID: String
    var geraeteName: String
}

/// Bereich B (Stammdaten) — ändert sich selten, klein, immer als Ganzes
/// neu aufgebaut wie bisher der komplette Monolith, aber unabhängig von den
/// anderen Teilen fingerabdruck-geprüft.
///
/// **Enthält bewusst NICHT `einkaufslistenEintraege`** (GitHub #85, siehe
/// ``SyncListenSnapshot``) — dieses Feld gehörte zwar inhaltlich zu Bereich B
/// (Sicherheitsnetz-Kopie), änderte sich aber mit der Frequenz von Bereich A
/// (bei jedem Abhaken/Hinzufügen/Entfernen auf einer Einkaufsliste) und riss
/// dadurch bislang bei JEDER dieser sehr häufigen Aktionen einen kompletten
/// Neuaufbau/-schrieb der eigentlich seltenen echten Stammdaten
/// (Geschäftstypen/Kategorien/Geschäfte/Artikel/Listen/Aliase) mit sich, weil
/// der Fingerabdruck-Vergleich die gesamte Struktur als eine Einheit
/// behandelt — analog der bereits bestehenden Begründung für die Trennung von
/// ``SyncVorgaengeSnapshot``/``SyncPreisSnapshot`` unten.
struct SyncStammSnapshot: Codable {
    var geschaeftsTypen: [GeschaeftTypSnapshot]
    var artikelKategorien: [ArtikelKategorieSnapshot]
    var geschaefte: [GeschaeftSnapshot]
    var artikel: [ArtikelSnapshot]
    var einkaufslisten: [EinkaufslisteSnapshot]
    var artikelAliase: [ArtikelAliasSnapshot]
}

/// Bereich A, Sicherheitsnetz-Kopie des vollständigen Einkaufslisten-Inhalts
/// (GitHub #85, herausgelöst aus ``SyncStammSnapshot``) — eigene Datei, weil
/// sich dieser Inhalt mit der Häufigkeit von Bereich-A-Aktionen ändert
/// (Abhaken/Hinzufügen/Entfernen, oft alle paar Sekunden während aktiv
/// eingekauft wird), nicht mit der Häufigkeit echter Stammdaten-Änderungen.
/// Zweck und additive Merge-Regel unverändert gegenüber der bisherigen
/// Platzierung, siehe ``SyncSnapshot/einkaufslistenEintraege`` (dort für den
/// weiterhin unveränderten lokalen Backup-Pfad) bzw.
/// `docs/DATENSYNCHRONISATION.md` Abschnitt 4, „Architektur-Revision
/// Alternative A".
struct SyncListenSnapshot: Codable {
    var einkaufslistenEintraege: [EinkaufslistenEintragSnapshot]
}

/// Bereich D (Lernen) — eigene Datei statt Bündelung mit Stammdaten, da
/// ``WarengruppenDistanz`` bei jedem abgeschlossenen Einkauf potenziell
/// aktualisiert wird, Stammdaten aber nur selten.
struct SyncLernenSnapshot: Codable {
    var warengruppenDistanzen: [WarengruppenDistanzSnapshot]
}

/// Bereich C, Einkaufsvorgänge — eigene Datei, da `Einkaufsvorgang.endZeit`
/// bei praktisch jedem Kaufabschluss wechselt, `Preispunkt` (``SyncPreisSnapshot``)
/// aber nur bei einer echten Preisänderung; eine gemeinsame Datei würde
/// unnötig oft neu geschrieben.
struct SyncVorgaengeSnapshot: Codable {
    var einkaufsvorgaenge: [EinkaufsvorgangSnapshot]
}

/// Bereich C, Preishistorie (GitHub #76) — siehe ``SyncVorgaengeSnapshot``
/// für die Begründung der eigenen Datei.
struct SyncPreisSnapshot: Codable {
    var preispunkte: [PreispunktSnapshot]
}

/// `KaufEintrag` (Bereich C, Kaufhistorie) ist **nicht** Teil eines der
/// fünf obigen Teile — dieser Bereich wächst unbeschränkt (kein Kompaktierungs-
/// Mechanismus wie bei `Preispunkt`, siehe `PreispunktVerdichtungService`) und
/// war mit 56% der Dateigröße in einer realen `export.json` der dominante
/// Anteil. Statt bei jedem Zyklus die komplette, wachsende Historie neu zu
/// kodieren, schreibt ``SyncKaeufeExportService`` ein `<uuid>.json` pro
/// `KaufEintrag` in `peers/{peer}/kaeufe/` — analog dem bereits bestehenden
/// Bereich-A-Eventlog `events/`, aber ohne Zähler-Präfix im Dateinamen: anders
/// als `SyncEvent` (Konfliktauflösung braucht Lamport-Reihenfolge) ist
/// `KaufEintrag`-Merge bereits heute reine Union nach `id`, ohne
/// Reihenfolgeabhängigkeit. `KaufEintragSnapshot` (oben) ist unverändert die
/// richtige Pro-Datei-Form.
