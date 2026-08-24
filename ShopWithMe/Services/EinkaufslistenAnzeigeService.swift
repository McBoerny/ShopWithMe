import Foundation
import SwiftData

/// Bündelt die Anzeige-Entscheidungslogik der laufenden Einkaufsliste —
/// extrahiert aus `EinkaufenView.swift`s privater `EinkaufslisteView`
/// (GitHub #107, Schritt 3/3, #110): welche Artikel als "verfügbar" gelten,
/// unter welcher(n) Kategorie(n) ein Artikel angezeigt wird, und wie die
/// Kategorie-Abschnitte sortiert werden (inkl. ``AbteilungsDistanzService``-
/// gelernter Reihenfolge).
///
/// Anders als Schritt 1/2 hängt an dieser Logik kein historischer
/// Live-Test-Bug — der Wert liegt rein in Testbarkeit/Struktur, nicht in
/// Fehlerbehebung. Stateloser `enum`-Service nach demselben Muster wie
/// ``EinkaufsvorgangAbschlussService``/``BelegUebernahmeService``. Alle drei
/// Funktionen sind inhaltlich 1:1 identisch zum Original — nur die vorher
/// implizit gelesenen View-`@State`/`let`-Werte (`zeigeAlleArtikel`,
/// `geschaeft`, …) sind jetzt explizite Parameter.
enum EinkaufslistenAnzeigeService {
    /// Ist ein Geschäft gewählt, blendet dies standardmäßig Artikel aus, die
    /// darin (noch) nicht als verfügbar gelten (siehe
    /// ``ArtikelVerfuegbarkeitService``). Bei aktivem `zeigeAlleArtikel`
    /// (Lernmodus) kann der Anwender diesen Filter für den laufenden Einkauf
    /// übergehen.
    static func verfuegbarkeitsgefiltert(
        _ eintraege: [EinkaufslistenEintrag],
        geschaeft: Geschaeft?,
        zeigeAlleArtikel: Bool,
        context: ModelContext
    ) -> [EinkaufslistenEintrag] {
        guard let geschaeft, !zeigeAlleArtikel else { return eintraege }
        return eintraege.filter { eintrag in
            guard let artikel = eintrag.artikel else { return false }
            return ArtikelVerfuegbarkeitService.istVerfuegbar(artikel, in: geschaeft, context: context)
        }
    }

    /// Kategorien, unter denen `artikel` in der Liste angezeigt wird:
    /// normalerweise alle zugeordneten (``Artikel/effektiveKategorien(context:)``)
    /// — außer bei gewähltem `geschaeft` liegt für `artikel` bereits eine
    /// eindeutig genug gelernte Kategorie vor
    /// (``AbteilungsDistanzService/gelernteKategorie(fuer:in:context:)``, GitHub-
    /// Nachfolgefund zu #36): dann nur noch diese eine, statt weiter alle
    /// zugeordneten Abschnitte zu duplizieren. Ohne Geschäft (globale
    /// Listenansicht) bleibt es bei allen zugeordneten Kategorien, da dort keine
    /// geschäftsspezifische Kaufhistorie zur Auswahl herangezogen werden kann.
    ///
    /// Bei aktivem `zeigeAlleArtikel` (Lernmodus) bewusst immer ungefiltert —
    /// derselbe Bypass wie in ``verfuegbarkeitsgefiltert(_:geschaeft:zeigeAlleArtikel:context:)``:
    /// der Lernmodus soll gezielt ALLES zeigen, auch um eine zuvor gelernte,
    /// aber inzwischen falsche Zuordnung sichtbar korrigieren zu können.
    static func kategorienFuerAnzeige(
        _ artikel: Artikel,
        geschaeft: Geschaeft?,
        zeigeAlleArtikel: Bool,
        context: ModelContext
    ) -> [ArtikelKategorie] {
        let alle = artikel.effektiveKategorien(context: context)
        guard !zeigeAlleArtikel, alle.count > 1, let geschaeft,
              let gelernt = AbteilungsDistanzService.gelernteKategorie(fuer: artikel, in: geschaeft, context: context)
        else { return alle }
        return [gelernt]
    }

    /// `offeneEintraege`/`abgehakteArtikel` gruppiert nach Artikelkategorie und
    /// sortiert über ``AbteilungsDistanzService`` — der gelernten, paarweisen
    /// Abteilungs-Distanzmatrix des Geschäfts (Architekturvorschlag Abschnitt
    /// 4.2/4.3, GitHub #36). Startpunkt der Sortierung ist
    /// `zuletztAbgehakteKategorie` — die verbleibende Liste wird so nach jeder
    /// Abhakung dynamisch neu sortiert, ausgehend vom aktuellen (impliziten)
    /// Standort. Ohne genügend gelernte Daten
    /// (``AbteilungsDistanzService/genuegendDatenVerfuegbar(fuer:)``) bleibt es
    /// bei alphabetischer Reihenfolge.
    ///
    /// Ein Artikel mit mehreren Kategorien (z.B. Ohropax unter "Drogerie" UND
    /// "Reisebedarf") landet in JEDER zugehörigen Gruppe statt nur in einer
    /// einzigen "führenden" — solange ``kategorienFuerAnzeige(_:geschaeft:zeigeAlleArtikel:context:)``
    /// für dieses Geschäft noch keine eindeutig gelernte Kategorie liefert
    /// (siehe dort): eine Duplizierung ist bis dahin gewollt (der Nutzer tappt
    /// ihn dort ab, wo er im jeweiligen Geschäft tatsächlich steht).
    static func kategorieGruppen(
        offeneEintraege: [EinkaufslistenEintrag],
        abgehakteArtikel: [Artikel],
        zeigeAbgehakteArtikel: Bool,
        zeigeAlleArtikel: Bool,
        geschaeft: Geschaeft?,
        zuletztAbgehakteKategorie: ArtikelKategorie?,
        context: ModelContext
    ) -> [KategorieGruppe] {
        var nachKategorie: [PersistentIdentifier: KategorieGruppe] = [:]
        let gefiltert = verfuegbarkeitsgefiltert(offeneEintraege, geschaeft: geschaeft, zeigeAlleArtikel: zeigeAlleArtikel, context: context)
        for eintrag in gefiltert {
            guard let artikel = eintrag.artikel else { continue }
            let element = KategorieGruppe.Element(id: eintrag.persistentModelID, artikel: artikel, eintrag: eintrag)
            for kategorie in kategorienFuerAnzeige(artikel, geschaeft: geschaeft, zeigeAlleArtikel: zeigeAlleArtikel, context: context) {
                nachKategorie[kategorie.persistentModelID, default: KategorieGruppe(kategorie: kategorie, elemente: [])].elemente.append(element)
            }
        }
        if zeigeAbgehakteArtikel {
            for artikel in abgehakteArtikel {
                let element = KategorieGruppe.Element(id: artikel.persistentModelID, artikel: artikel, eintrag: nil)
                for kategorie in kategorienFuerAnzeige(artikel, geschaeft: geschaeft, zeigeAlleArtikel: zeigeAlleArtikel, context: context) {
                    nachKategorie[kategorie.persistentModelID, default: KategorieGruppe(kategorie: kategorie, elemente: [])].elemente.append(element)
                }
            }
        }
        let alphabetisch = nachKategorie.values.map(\.kategorie)
            .sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
        guard let geschaeft else {
            return nachKategorie.values.sorted { $0.kategorie.name.vergleicheAlphabetisch(mit: $1.kategorie.name) == .orderedAscending }
        }
        let sortiert = AbteilungsDistanzService.sortierteReihenfolge(
            offeneKategorien: alphabetisch,
            startpunkt: zuletztAbgehakteKategorie,
            in: geschaeft,
            context: context
        )
        let position = Dictionary(uniqueKeysWithValues: sortiert.enumerated().map { ($1.persistentModelID, $0) })
        return nachKategorie.values.sorted {
            (position[$0.kategorie.persistentModelID] ?? .max) < (position[$1.kategorie.persistentModelID] ?? .max)
        }
    }
}
