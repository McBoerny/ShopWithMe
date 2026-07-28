import Foundation
import SwiftData

/// Eine benannte Einkaufsliste, z.B. „Wocheneinkauf“ oder „Baumarkt“.
///
/// Der Nutzer kann beliebig viele Einkaufslisten anlegen; beim Einkaufen (siehe
/// ``EinkaufenView``) wird eine davon ausgewählt und bestimmt, welche
/// ``EinkaufslistenEintrag``e (und damit welche ``Artikel``) angezeigt werden. Ein
/// ``Artikel`` kann gleichzeitig auf mehreren Listen stehen, jeweils mit eigener
/// Menge/Notiz.
@Model
final class Einkaufsliste {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename der Liste, z.B. "Wocheneinkauf".
    var name: String
    /// Zeitpunkt der Anlage — bestimmt auch die Standard-Sortierung in Auswahllisten.
    var erstelltAm: Date

    /// Die Artikel, die aktuell auf dieser Liste stehen.
    @Relationship(deleteRule: .cascade, inverse: \EinkaufslistenEintrag.einkaufsliste)
    var eintraege: [EinkaufslistenEintrag] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.erstelltAm = Date()
    }
}

extension Einkaufsliste {
    /// Name der automatisch angelegten ersten Liste (siehe ``standard(context:)``).
    static let standardName = "Einkaufsliste"

    /// Findet die zuerst angelegte Liste oder legt (namens ``standardName``) eine
    /// neue an, falls noch keine existiert — analog ``ArtikelKategorie/sonstige(context:)``.
    /// Stellt sicher, dass ``EinkaufenView`` immer mindestens eine Liste anzeigen kann.
    static func standard(context: ModelContext) -> Einkaufsliste {
        var deskriptor = FetchDescriptor<Einkaufsliste>(sortBy: [SortDescriptor(\.erstelltAm)])
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            return bestehende
        }
        let neue = Einkaufsliste(name: standardName)
        context.insert(neue)
        return neue
    }

    /// Ob `artikel` bereits auf dieser Liste steht.
    func enthaelt(_ artikel: Artikel) -> Bool {
        eintraege.contains { $0.artikel == artikel }
    }

    /// Der ``EinkaufslistenEintrag`` für `artikel` auf dieser Liste, falls vorhanden.
    func eintrag(fuer artikel: Artikel) -> EinkaufslistenEintrag? {
        eintraege.first { $0.artikel == artikel }
    }

    /// Setzt `artikel` (neu oder erneut) auf diese Liste: legt bei Bedarf einen
    /// neuen ``EinkaufslistenEintrag`` an, oder setzt einen bestehenden zurück auf
    /// ``Artikel/mengenSchritt`` und leert dessen Notiz — unabhängig vom zuletzt vor
    /// dem Abhaken gewählten Wert. Zentrale Stelle für alle Orte, die einen Artikel
    /// (neu oder erneut) auf eine Liste setzen (siehe ``ArtikelHinzufuegenView``,
    /// ``Einkaufsvorgang/artikelAbwaehlen(_:context:)``).
    @discardableResult
    func artikelHinzufuegen(_ artikel: Artikel, context: ModelContext) -> EinkaufslistenEintrag {
        if let bestehender = eintrag(fuer: artikel) {
            bestehender.menge = artikel.mengenSchritt
            bestehender.notiz = nil
            return bestehender
        }
        let neuer = EinkaufslistenEintrag(einkaufsliste: self, artikel: artikel, menge: artikel.mengenSchritt)
        context.insert(neuer)
        return neuer
    }

    /// Nimmt `artikel` wieder von dieser Liste — Gegenstück zu
    /// ``artikelHinzufuegen(_:context:)``, ohne Wirkung falls er nicht darauf
    /// steht. Rein die Listenmitgliedschaft betreffend, nicht zu verwechseln mit
    /// ``Einkaufsvorgang/artikelAbwaehlen(_:context:)`` (macht ein Abhaken
    /// während eines laufenden Einkaufs rückgängig, GitHub #45).
    func artikelEntfernen(_ artikel: Artikel, context: ModelContext) {
        guard let bestehender = eintrag(fuer: artikel) else { return }
        context.delete(bestehender)
    }
}
