import Foundation
import SwiftData

/// Bündelt die Anzeige-Entscheidungslogik der laufenden Einkaufsliste —
/// extrahiert aus `EinkaufenView.swift`s privater `EinkaufslisteView`
/// (GitHub #107, Schritt 3/3, #110): welche Artikel als "verfügbar" gelten,
/// unter welcher(n) Abteilung(n) ein Artikel angezeigt wird, und wie die
/// Abteilung-Abschnitte sortiert werden (inkl. ``AbteilungsDistanzService``-
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
        // Einmal pro Aufruf geladen statt in ``ArtikelVerfuegbarkeitService/istVerfuegbar(_:in:alleAbteilungen:context:)``
        // pro Element neu zu fetchen (Performance-Fund #152).
        let alleAbteilungen = (try? context.fetch(FetchDescriptor<Abteilung>())) ?? []
        return eintraege.filter { eintrag in
            guard let artikel = eintrag.artikel else { return false }
            return ArtikelVerfuegbarkeitService.istVerfuegbar(artikel, in: geschaeft, alleAbteilungen: alleAbteilungen, context: context)
        }
    }

    /// Abteilungen, unter denen `artikel` in der Liste angezeigt wird:
    /// normalerweise alle zugeordneten (``Artikel/effektiveAbteilungen(context:)``)
    /// — außer bei gewähltem `geschaeft` liegt für `artikel` bereits eine
    /// eindeutig genug gelernte Abteilung vor
    /// (``AbteilungsDistanzService/gelernteAbteilung(fuer:in:context:)``, GitHub-
    /// Nachfolgefund zu #36): dann nur noch diese eine, statt weiter alle
    /// zugeordneten Abschnitte zu duplizieren. Ohne Geschäft (globale
    /// Listenansicht) bleibt es bei allen zugeordneten Abteilungen, da dort keine
    /// geschäftsspezifische Kaufhistorie zur Auswahl herangezogen werden kann.
    ///
    /// Bei aktivem `zeigeAlleArtikel` (Lernmodus) bewusst immer ungefiltert —
    /// derselbe Bypass wie in ``verfuegbarkeitsgefiltert(_:geschaeft:zeigeAlleArtikel:context:)``:
    /// der Lernmodus soll gezielt ALLES zeigen, auch um eine zuvor gelernte,
    /// aber inzwischen falsche Zuordnung sichtbar korrigieren zu können.
    static func abteilungenFuerAnzeige(
        _ artikel: Artikel,
        geschaeft: Geschaeft?,
        zeigeAlleArtikel: Bool,
        context: ModelContext
    ) -> [Abteilung] {
        let alle = artikel.effektiveAbteilungen(context: context)
        guard !zeigeAlleArtikel, alle.count > 1, let geschaeft,
              let gelernt = AbteilungsDistanzService.gelernteAbteilung(fuer: artikel, in: geschaeft, context: context)
        else { return alle }
        return [gelernt]
    }

    /// `offeneEintraege`/`abgehakteArtikel` gruppiert nach Abteilung und
    /// sortiert über ``AbteilungsDistanzService`` — der gelernten, paarweisen
    /// Abteilungs-Distanzmatrix des Geschäfts (Architekturvorschlag Abschnitt
    /// 4.2/4.3, GitHub #36). Startpunkt der Sortierung ist
    /// `zuletztAbgehakteAbteilung` — die verbleibende Liste wird so nach jeder
    /// Abhakung dynamisch neu sortiert, ausgehend vom aktuellen (impliziten)
    /// Standort. Ohne genügend gelernte Daten
    /// (``AbteilungsDistanzService/genuegendDatenVerfuegbar(fuer:)``) bleibt es
    /// bei alphabetischer Reihenfolge.
    ///
    /// Ein Artikel mit mehreren Abteilungen (z.B. Ohropax unter "Drogerie" UND
    /// "Reisebedarf") landet in JEDER zugehörigen Gruppe statt nur in einer
    /// einzigen "führenden" — solange ``abteilungenFuerAnzeige(_:geschaeft:zeigeAlleArtikel:context:)``
    /// für dieses Geschäft noch keine eindeutig gelernte Abteilung liefert
    /// (siehe dort): eine Duplizierung ist bis dahin gewollt (der Nutzer tappt
    /// ihn dort ab, wo er im jeweiligen Geschäft tatsächlich steht).
    ///
    /// Innerhalb jeder Gruppe (GitHub #176): offene Artikel vor bereits
    /// abgehakten, innerhalb beider Blöcke alphabetisch
    /// (``vergleicheElemente(_:_:)``). Zusätzlich wandert eine Gruppe, in der
    /// kein offener Artikel mehr übrig ist (``AbteilungGruppe/istVollstaendigAbgehakt``),
    /// ans Ende der Gesamtliste — als stabiler Zusatzschritt NACH der
    /// eigentlichen Bereichs-Sortierung (alphabetisch oder
    /// ``AbteilungsDistanzService``-Distanzmatrix), damit deren Reihenfolge
    /// unter den jeweils verbleibenden Gruppen unangetastet bleibt.
    static func abteilungGruppen(
        offeneEintraege: [EinkaufslistenEintrag],
        abgehakteArtikel: [Artikel],
        zeigeAbgehakteArtikel: Bool,
        zeigeAlleArtikel: Bool,
        geschaeft: Geschaeft?,
        zuletztAbgehakteAbteilung: Abteilung?,
        context: ModelContext
    ) -> [AbteilungGruppe] {
        var nachAbteilung: [PersistentIdentifier: AbteilungGruppe] = [:]
        let gefiltert = verfuegbarkeitsgefiltert(offeneEintraege, geschaeft: geschaeft, zeigeAlleArtikel: zeigeAlleArtikel, context: context)
        for eintrag in gefiltert {
            guard let artikel = eintrag.artikel else { continue }
            let element = AbteilungGruppe.Element(id: eintrag.persistentModelID, artikel: artikel, eintrag: eintrag)
            for abteilung in abteilungenFuerAnzeige(artikel, geschaeft: geschaeft, zeigeAlleArtikel: zeigeAlleArtikel, context: context) {
                nachAbteilung[abteilung.persistentModelID, default: AbteilungGruppe(abteilung: abteilung, elemente: [])].elemente.append(element)
            }
        }
        if zeigeAbgehakteArtikel {
            for artikel in abgehakteArtikel {
                let element = AbteilungGruppe.Element(id: artikel.persistentModelID, artikel: artikel, eintrag: nil)
                for abteilung in abteilungenFuerAnzeige(artikel, geschaeft: geschaeft, zeigeAlleArtikel: zeigeAlleArtikel, context: context) {
                    nachAbteilung[abteilung.persistentModelID, default: AbteilungGruppe(abteilung: abteilung, elemente: [])].elemente.append(element)
                }
            }
        }
        for schluessel in nachAbteilung.keys {
            nachAbteilung[schluessel]?.elemente.sort(by: vergleicheElemente)
        }
        let alphabetisch = nachAbteilung.values.map(\.abteilung)
            .sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
        let basisSortiert: [AbteilungGruppe]
        if let geschaeft {
            let sortiert = AbteilungsDistanzService.sortierteReihenfolge(
                offeneAbteilungen: alphabetisch,
                startpunkt: zuletztAbgehakteAbteilung,
                in: geschaeft,
                context: context
            )
            let position = Dictionary(uniqueKeysWithValues: sortiert.enumerated().map { ($1.persistentModelID, $0) })
            basisSortiert = nachAbteilung.values.sorted {
                (position[$0.abteilung.persistentModelID] ?? .max) < (position[$1.abteilung.persistentModelID] ?? .max)
            }
        } else {
            basisSortiert = nachAbteilung.values.sorted { $0.abteilung.name.vergleicheAlphabetisch(mit: $1.abteilung.name) == .orderedAscending }
        }
        return basisSortiert.sorted { !$0.istVollstaendigAbgehakt && $1.istVollstaendigAbgehakt }
    }

    /// Reihenfolge zweier Artikel innerhalb derselben Abteilungsgruppe (GitHub
    /// #176): offene Artikel (`eintrag != nil`) immer vor bereits abgehakten
    /// (`eintrag == nil`), innerhalb beider Blöcke alphabetisch über den
    /// locale-bewussten ``String/vergleicheAlphabetisch(mit:)``.
    private static func vergleicheElemente(_ erstes: AbteilungGruppe.Element, _ zweites: AbteilungGruppe.Element) -> Bool {
        let ersteAbgehakt = erstes.eintrag == nil
        let zweiteAbgehakt = zweites.eintrag == nil
        if ersteAbgehakt != zweiteAbgehakt { return zweiteAbgehakt }
        return erstes.artikel.name.vergleicheAlphabetisch(mit: zweites.artikel.name) == .orderedAscending
    }
}
