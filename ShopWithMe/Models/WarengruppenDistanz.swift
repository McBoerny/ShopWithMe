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
/// Wird ausschließlich von ``WarengruppenDistanzService`` gelesen/geschrieben.
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

    init(geschaeft: Geschaeft?, kategorieA: ArtikelKategorie, kategorieB: ArtikelKategorie, distanz: Double) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.kategorieA = kategorieA
        self.kategorieB = kategorieB
        self.distanz = distanz
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
