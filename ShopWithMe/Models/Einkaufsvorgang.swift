import Foundation
import SwiftData

/// Ein einzelner Einkaufsvorgang (Ladenbesuch) in einem bestimmten ``Geschaeft``.
///
/// Während eines Einkaufsvorgangs entstehen ``KaufEintrag``e, aus deren
/// Reihenfolge der ``ShelfOrderLearningService`` lernt, in welcher Reihenfolge der
/// Anwender die Artikelkategorien (und damit die zugehörigen Regale) typischerweise
/// abläuft.
@Model
final class Einkaufsvorgang {
    /// Eindeutige Kennung.
    var id: UUID
    /// Das Geschäft, in dem dieser Einkauf stattfindet.
    var geschaeft: Geschaeft?
    /// Startzeitpunkt des Einkaufs.
    var startZeit: Date
    /// Endzeitpunkt — `nil`, solange der Einkauf noch läuft.
    var endZeit: Date?
    /// Die einzelnen Käufe dieses Einkaufsvorgangs.
    @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.einkaufsvorgang)
    var kaufEintraege: [KaufEintrag] = []

    init(geschaeft: Geschaeft? = nil, startZeit: Date = Date()) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.startZeit = startZeit
    }

    /// Ob dieser Einkaufsvorgang bereits abgeschlossen wurde.
    var istAbgeschlossen: Bool { endZeit != nil }

    /// Beendet den Einkaufsvorgang zum angegebenen Zeitpunkt (Standard: jetzt).
    func abschliessen(am zeitpunkt: Date = Date()) {
        endZeit = zeitpunkt
    }

    /// Markiert einen Artikel als gekauft: legt einen ``KaufEintrag`` (zunächst ohne
    /// Preis) in diesem Einkaufsvorgang an und nimmt den Artikel von der
    /// Einkaufsliste. Artikel derselben ``ArtikelKategorie`` erhalten denselben
    /// ``KaufEintrag/kategorieBesuchsIndex``, neue Kategorien den jeweils nächsten
    /// Index — das ist die Rohdatenbasis für ``ShelfOrderLearningService``. Artikel
    /// ohne eigene Kategorie fallen dabei automatisch unter "Sonstiges" (siehe
    /// ``Artikel/effektiveKategorie(context:)``).
    func artikelAbhaken(_ artikel: Artikel, context: ModelContext) {
        let kategorie = artikel.effektiveKategorie(context: context)
        let index = naechsterKategorieBesuchsIndex(fuer: kategorie)
        let eintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft, kategorie: kategorie, kategorieBesuchsIndex: index)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = self
        artikel.istAufEinkaufsliste = false
    }

    /// Macht ``artikelAbhaken(_:context:)`` rückgängig: löscht den zugehörigen
    /// ``KaufEintrag`` und setzt den Artikel zurück auf die Einkaufsliste.
    func artikelAbwaehlen(_ artikel: Artikel, context: ModelContext) {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return }
        let eintrag = kaufEintraege.remove(at: index)
        context.delete(eintrag)
        artikel.istAufEinkaufsliste = true
    }

    private func naechsterKategorieBesuchsIndex(fuer kategorie: ArtikelKategorie) -> Int {
        if let vorhandenerIndex = kaufEintraege.first(where: { $0.kategorie == kategorie })?.kategorieBesuchsIndex {
            return vorhandenerIndex
        }
        return (kaufEintraege.compactMap(\.kategorieBesuchsIndex).max() ?? -1) + 1
    }
}
