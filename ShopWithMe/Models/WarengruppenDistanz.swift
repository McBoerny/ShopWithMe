import Foundation
import SwiftData

/// Gelernte Distanz zwischen zwei ``ArtikelKategorie``n ("Warengruppen") in einem
/// bestimmten ``Geschaeft`` — Kernbaustein der adaptiven Einkaufslistenoptimierung
/// (siehe `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`, GitHub #36).
///
/// Eine Zeile deckt ein **ungeordnetes** Kategorie-Paar ab (siehe
/// ``kanonischesPaar(_:_:)``) — die Matrix ist symmetrisch, es gibt also nie
/// getrennte Einträge für (A, B) und (B, A). ``distanz`` liegt im Bereich `[0, 1]`:
/// 0 = sehr nah, 1 = sehr weit, ``initialwert`` (0.5) = noch unbeobachtet.
///
/// Wird ausschließlich von ``AbteilungsDistanzService`` gelesen/geschrieben.
@Model
final class WarengruppenDistanz {
    /// Eindeutige Kennung.
    var id: UUID
    /// Das Geschäft, für das diese Distanz gilt.
    var geschaeft: Geschaeft?
    /// Erste Kategorie des Paares (siehe ``kanonischesPaar(_:_:)`` für die
    /// Reihenfolge-Konvention).
    var kategorieA: ArtikelKategorie?
    /// Zweite Kategorie des Paares.
    var kategorieB: ArtikelKategorie?
    /// Gelernte Distanz im Bereich `[0, 1]` — siehe Typ-Dokumentation.
    var distanz: Double
    /// Rohwert für ``eigeneBeobachtungsAnzahl``. Optional gespeichert, damit vor
    /// Einführung dieses Attributs angelegte Zeilen beim automatischen Laden
    /// nicht abstürzen — ein `nil`-Rohwert fällt auf `1` zurück (eine bereits
    /// bestehende Zeile beruht per Definition auf mindestens einer
    /// Beobachtung, siehe GitHub #87).
    private var beobachtungsAnzahlRaw: Int?

    init(geschaeft: Geschaeft?, kategorieA: ArtikelKategorie, kategorieB: ArtikelKategorie, distanz: Double) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.kategorieA = kategorieA
        self.kategorieB = kategorieB
        self.distanz = distanz
    }
}

extension WarengruppenDistanz {
    /// Wie oft DIESES Gerät für dieses Kategorie-Paar bereits selbst eine
    /// Beobachtung gelernt hat (``AbteilungsDistanzService/lerne(besuche:matrix:geschaeft:context:)``)
    /// — NIE durch Sync verändert, nur durch eine echte lokale Abhakung.
    /// Grundlage (zusammen mit dem zuletzt bekannten eigenen Beitrag jedes
    /// Peers) für ``beobachtungsAnzahl``.
    var eigeneBeobachtungsAnzahl: Int {
        get { beobachtungsAnzahlRaw ?? 1 }
        set { beobachtungsAnzahlRaw = newValue }
    }

    /// Wie oft dieses Kategorie-Paar gruppenweit, über alle bekannten Geräte
    /// hinweg, bereits beobachtet wurde.
    ///
    /// **G-Counter (CRDT-Muster), exaktes Gegenstück zu
    /// ``Geschaeft/anzahlEinkaufsvorgaenge``:** Summe aus
    /// ``eigeneBeobachtungsAnzahl`` und dem zuletzt bekannten EIGENEN Beitrag
    /// jedes Peers (``WarengruppenDistanzPeerZaehlerStand``). Eine naive
    /// "beide Zähler addieren"-Regel würde bei jedem erneuten Sync-Zyklus
    /// denselben Beitrag erneut mitzählen, weil Snapshots den kompletten
    /// aktuellen (bereits gemergten) Bestand exportieren statt nur Deltas
    /// (GitHub #87) — siehe ausführliche Begründung bei ``Geschaeft/anzahlEinkaufsvorgaenge``.
    ///
    /// Berechnet bei jedem Zugriff, kein zusätzlicher gespeicherter
    /// Gesamtwert. Ohne zugeordneten ``modelContext`` liefert nur
    /// ``eigeneBeobachtungsAnzahl`` zurück.
    var beobachtungsAnzahl: Int {
        guard let context = modelContext else { return eigeneBeobachtungsAnzahl }
        let eigeneID = id
        let deskriptor = FetchDescriptor<WarengruppenDistanzPeerZaehlerStand>(predicate: #Predicate { $0.distanzID == eigeneID })
        let peerBeitraege = (try? context.fetch(deskriptor)) ?? []
        return eigeneBeobachtungsAnzahl + peerBeitraege.reduce(0) { $0 + $1.zuletztGesehenerWert }
    }

    /// Deckelt das Gewicht, mit dem eine Seite beim Geräte-Sync in den
    /// gewichteten Mittelwert eingeht (``SyncSnapshotImportService``) —
    /// unabhängig von der tatsächlichen ``beobachtungsAnzahl``. Grund: das
    /// lokale Lernen (``AbteilungsDistanzService/lerne(besuche:matrix:geschaeft:context:)``)
    /// ist selbst ein exponentiell gleitender Durchschnitt mit fester
    /// Lernrate — ältere Beobachtungen verblassen geometrisch, das
    /// tatsächliche „Gedächtnis" reicht nur rund `1 / Lernrate` Beobachtungen
    /// zurück. Ohne diese Deckelung würde ein Gerät mit sehr vielen
    /// historischen (längst verblassten) Beobachtungen beim Merge eine
    /// Dominanz bekommen, die sein aktueller Wert inhaltlich gar nicht mehr
    /// trägt (GitHub #87).
    static let maximaleMergeGewichtung = Int((1 / AbteilungsDistanzService.lernrate).rounded())

    /// ``beobachtungsAnzahl``, gedeckelt bei ``maximaleMergeGewichtung`` — das
    /// beim Merge tatsächlich verwendete Gewicht dieser Seite.
    var mergeGewichtung: Int {
        min(beobachtungsAnzahl, WarengruppenDistanz.maximaleMergeGewichtung)
    }
}

extension WarengruppenDistanz {
    /// Distanz eines noch nie gemeinsam beobachteten Kategorie-Paares (siehe
    /// Architekturvorschlag Abschnitt 3.1: "0.5 = unbekannt").
    static let initialwert = 0.5

    /// Alle bekannten Distanz-Einträge dieses Geschäfts — eine Zeile pro
    /// ungeordnetem Kategorie-Paar, das schon mindestens einmal gemeinsam auf
    /// einer Einkaufsliste stand. Bewusst als einmaliger Fetch mit **einer**
    /// Beziehung im Prädikat gehalten (nicht live über `@Query` mit mehreren
    /// Beziehungen kombiniert) — siehe die dokumentierte Lehre aus GitHub #33
    /// zu zusammengesetzten Beziehungs-Prädikaten.
    static func alle(fuer geschaeft: Geschaeft, context: ModelContext) -> [WarengruppenDistanz] {
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<WarengruppenDistanz>(
            predicate: #Predicate { $0.geschaeft?.persistentModelID == geschaeftID }
        )
        return (try? context.fetch(deskriptor)) ?? []
    }

    /// Bildet zwei Kategorien auf ein kanonisches, nach ``ArtikelKategorie/id``
    /// sortiertes Paar ab — stellt sicher, dass `(a, b)` und `(b, a)` immer auf
    /// denselben Distanz-Eintrag verweisen (symmetrische Matrix ohne doppelte
    /// Zeilen).
    static func kanonischesPaar(_ a: ArtikelKategorie, _ b: ArtikelKategorie) -> (ArtikelKategorie, ArtikelKategorie) {
        a.id.uuidString < b.id.uuidString ? (a, b) : (b, a)
    }
}
