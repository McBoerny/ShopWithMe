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
    /// dem Abhaken gewählten Wert. Reine Zustandsmutation ohne Event-Aufzeichnung —
    /// siehe ``artikelHinzufuegen(_:context:)`` für die reguläre, aufzeichnende
    /// Variante. Wird von ``SyncImportService`` genutzt, um ein empfangenes
    /// ``SyncEventArt/artikelHinzugefuegt``-Event zu materialisieren, ohne es
    /// dabei fälschlich diesem Gerät als Urheber zuzuschreiben (siehe
    /// `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`, Phase 2).
    @discardableResult
    func artikelHinzufuegenOhneEventAufzeichnung(_ artikel: Artikel, context: ModelContext) -> EinkaufslistenEintrag {
        if let bestehender = eintrag(fuer: artikel) {
            bestehender.menge = artikel.mengenSchritt
            bestehender.notiz = nil
            return bestehender
        }
        let neuer = EinkaufslistenEintrag(einkaufsliste: self, artikel: artikel, menge: artikel.mengenSchritt)
        context.insert(neuer)
        return neuer
    }

    /// Wie ``artikelHinzufuegenOhneEventAufzeichnung(_:context:)``, zeichnet
    /// zusätzlich ein ``SyncEventArt/artikelHinzugefuegt``-Event auf (Phase 0,
    /// `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`) — die Stelle für alle lokal
    /// ausgelösten Aktionen, die einen Artikel (neu oder erneut) auf eine Liste
    /// setzen (siehe ``ArtikelHinzufuegenView``,
    /// ``Einkaufsvorgang/artikelAbwaehlen(_:context:)``). Zeichnet bewusst auch
    /// dann ein Event auf, wenn diese Funktion nur als Seiteneffekt von
    /// ``Einkaufsvorgang/artikelAbwaehlen(_:context:)`` aufgerufen wird (zwei
    /// Events für eine Nutzeraktion) — akzeptierte Vereinfachung, da erneutes
    /// Anwenden idempotent ist.
    @discardableResult
    func artikelHinzufuegen(_ artikel: Artikel, context: ModelContext) -> EinkaufslistenEintrag {
        let eintrag = artikelHinzufuegenOhneEventAufzeichnung(artikel, context: context)
        SyncEventService.aufzeichnen(.artikelHinzugefuegt, bezugsID: id, artikelID: artikel.id, context: context)
        return eintrag
    }

    /// Nimmt `artikel` wieder von dieser Liste — Gegenstück zu
    /// ``artikelHinzufuegenOhneEventAufzeichnung(_:context:)``, ohne Wirkung falls
    /// er nicht darauf steht. Reine Zustandsmutation ohne Event-Aufzeichnung,
    /// siehe ``artikelEntfernen(_:context:)``. Liefert `true`, falls tatsächlich
    /// etwas entfernt wurde (Grundlage dafür, ob die aufzeichnende Variante ein
    /// Event erzeugt).
    @discardableResult
    func artikelEntfernenOhneEventAufzeichnung(_ artikel: Artikel, context: ModelContext) -> Bool {
        guard let bestehender = eintrag(fuer: artikel) else { return false }
        context.delete(bestehender)
        return true
    }

    /// Wie ``artikelEntfernenOhneEventAufzeichnung(_:context:)``, zeichnet
    /// zusätzlich (nur bei tatsächlicher Entfernung) ein
    /// ``SyncEventArt/artikelEntfernt``-Event auf. Rein die Listenmitgliedschaft
    /// betreffend, nicht zu verwechseln mit
    /// ``Einkaufsvorgang/artikelAbwaehlen(_:context:)`` (macht ein Abhaken
    /// während eines laufenden Einkaufs rückgängig, GitHub #45).
    func artikelEntfernen(_ artikel: Artikel, context: ModelContext) {
        guard artikelEntfernenOhneEventAufzeichnung(artikel, context: context) else { return }
        SyncEventService.aufzeichnen(.artikelEntfernt, bezugsID: id, artikelID: artikel.id, context: context)
    }
}
