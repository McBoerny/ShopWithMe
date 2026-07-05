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
    /// Die Einkaufsliste, aus der dieser Einkauf abgehakt wird.
    var einkaufsliste: Einkaufsliste?
    /// Startzeitpunkt des Einkaufs.
    var startZeit: Date
    /// Endzeitpunkt — `nil`, solange der Einkauf noch läuft.
    var endZeit: Date?
    /// Die einzelnen Käufe dieses Einkaufsvorgangs.
    @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.einkaufsvorgang)
    var kaufEintraege: [KaufEintrag] = []

    init(geschaeft: Geschaeft? = nil, einkaufsliste: Einkaufsliste? = nil, startZeit: Date = Date()) {
        self.id = UUID()
        self.geschaeft = geschaeft
        self.einkaufsliste = einkaufsliste
        self.startZeit = startZeit
    }

    /// Ob dieser Einkaufsvorgang bereits abgeschlossen wurde.
    var istAbgeschlossen: Bool { endZeit != nil }

    /// Beendet den Einkaufsvorgang zum angegebenen Zeitpunkt (Standard: jetzt).
    func abschliessen(am zeitpunkt: Date = Date()) {
        endZeit = zeitpunkt
    }

    /// Markiert einen Artikel als gekauft: legt einen ``KaufEintrag`` (zunächst ohne
    /// Preis) in diesem Einkaufsvorgang an und entfernt den Artikel von
    /// ``einkaufsliste`` (falls dort noch ein ``EinkaufslistenEintrag`` existiert).
    /// Artikel derselben ``ArtikelKategorie`` erhalten denselben
    /// ``KaufEintrag/kategorieBesuchsIndex``, neue Kategorien den jeweils nächsten
    /// Index — das ist die Rohdatenbasis für ``ShelfOrderLearningService``. Artikel
    /// ohne eigene Kategorie fallen dabei automatisch unter "Sonstiges" (siehe
    /// ``Artikel/effektiveKategorie(context:)``).
    func artikelAbhaken(_ artikel: Artikel, context: ModelContext) {
        // Dedupe-Schutz gegen das in `docs/DATABASE_CONCURRENCY.md` dokumentierte
        // Restrisiko (Sync-Latenz-Kollisionsfenster bei zeitgleichem Abhaken auf zwei
        // Geräten): pro (Einkaufsvorgang, Artikel) darf nur ein `KaufEintrag`
        // entstehen. Existiert bereits einer (z.B. weil das andere Gerät knapp vor
        // uns synchronisiert hat), kein Duplikat anlegen.
        let einkaufsvorgangID = persistentModelID
        let artikelID = artikel.persistentModelID
        let deskriptor = FetchDescriptor<KaufEintrag>(
            predicate: #Predicate { $0.einkaufsvorgang?.persistentModelID == einkaufsvorgangID && $0.artikel?.persistentModelID == artikelID }
        )
        let listenEintrag = einkaufsliste?.eintrag(fuer: artikel)
        if let anzahl = try? context.fetchCount(deskriptor), anzahl > 0 {
            DatabaseDebugLogger.log(.dedupeConflictDetected, details: "artikelAbhaken: \(artikel.name)")
            if let listenEintrag {
                context.delete(listenEintrag)
            }
            return
        }

        let kategorie = artikel.effektiveKategorie(context: context)
        let index = naechsterKategorieBesuchsIndex(fuer: kategorie)
        let eintrag = KaufEintrag(
            artikel: artikel,
            geschaeft: geschaeft,
            kategorie: kategorie,
            menge: listenEintrag?.menge ?? artikel.mengenSchritt,
            kategorieBesuchsIndex: index
        )
        context.insert(eintrag)
        eintrag.einkaufsvorgang = self
        if let listenEintrag {
            context.delete(listenEintrag)
        }
    }

    /// Macht ``artikelAbhaken(_:context:)`` rückgängig: löscht den zugehörigen
    /// ``KaufEintrag`` und setzt den Artikel zurück auf ``einkaufsliste`` (inkl.
    /// Zurücksetzen von Menge/temporärer Notiz, siehe
    /// ``Einkaufsliste/artikelHinzufuegen(_:context:)``).
    func artikelAbwaehlen(_ artikel: Artikel, context: ModelContext) {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return }
        let eintrag = kaufEintraege.remove(at: index)
        context.delete(eintrag)
        einkaufsliste?.artikelHinzufuegen(artikel, context: context)
    }

    /// Entfernt einen bereits abgehakten Artikel dauerhaft aus der Einkaufsliste-Ansicht
    /// dieses Einkaufsvorgangs: anders als ``artikelAbwaehlen(_:context:)`` wird der
    /// Artikel dabei NICHT wieder auf die Einkaufsliste zurückgesetzt (er bleibt, was er
    /// nach ``artikelAbhaken(_:context:)`` bereits war). Nur der zugehörige
    /// ``KaufEintrag`` wird gelöscht, damit der Artikel auch aus der
    /// "abgehakt"-Ansicht dieses Einkaufs verschwindet, statt versehentlich per Tipp
    /// wieder zurückgeholt werden zu können.
    func artikelDauerhaftEntfernen(_ artikel: Artikel, context: ModelContext) {
        guard let index = kaufEintraege.firstIndex(where: { $0.artikel == artikel }) else { return }
        let eintrag = kaufEintraege.remove(at: index)
        context.delete(eintrag)
    }

    private func naechsterKategorieBesuchsIndex(fuer kategorie: ArtikelKategorie) -> Int {
        if let vorhandenerIndex = kaufEintraege.first(where: { $0.kategorie == kategorie })?.kategorieBesuchsIndex {
            return vorhandenerIndex
        }
        return (kaufEintraege.compactMap(\.kategorieBesuchsIndex).max() ?? -1) + 1
    }
}
