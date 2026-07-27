import Foundation
import SwiftData

/// Lernt aus der Abhakreihenfolge abgeschlossener ``Einkaufsvorgang``e eine
/// ladenspezifische, paarweise Distanz zwischen Artikelkategorien ("Warengruppen")
/// und leitet daraus eine dynamisch nachsortierbare Einkaufsreihenfolge ab — siehe
/// `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md` (GitHub #36).
///
/// Löst dieselbe Aufgabe wie ``ShelfOrderLearningService``, aber feiner: statt eines
/// einzelnen Durchschnittswerts je Kategorie (``KategorieBesuchsStatistik``) lernt
/// dieser Service eine vollständige paarweise Distanzmatrix
/// (``WarengruppenDistanz``), die sich nach jeder Abhakung neu sortieren lässt
/// (``sortierteReihenfolge(offeneKategorien:startpunkt:in:context:)``), statt nur
/// einmal beim Einkaufsstart.
enum WarengruppenDistanzService {
    /// Ab wie vielen abgeschlossenen Einkäufen in einem Geschäft eine sortierte
    /// Reihenfolge angeboten wird — unabhängig von
    /// ``ShelfOrderLearningService/mindestEinkaeufeFuerVorschlag`` (dort 5), da
    /// beide Schwellen unterschiedliche Algorithmen mit unterschiedlichem
    /// Datenbedarf betreffen (siehe Architekturvorschlag Abschnitt 12, Phase 3).
    static let mindestEinkaeufeFuerVorschlag = 3
    /// Normale Lernrate: ~10% Gewicht des neuen Einkaufs gegenüber der bisherigen
    /// Erfahrung (gleitender Durchschnitt).
    static let lernrate = 0.1
    /// Temporär erhöhte Lernrate, solange ``Geschaeft/umbauVerdacht`` gesetzt ist,
    /// damit sich die Matrix schneller an eine neue Ladenanordnung anpasst.
    static let erhoehteLernrate = 0.3
    /// Ab welcher durchschnittlichen Abweichung zwischen erwarteter und
    /// tatsächlicher Distanz aufeinanderfolgender Besuche ein Ladenumbau vermutet
    /// wird.
    static let umbauSchwelle = 0.3
    /// Nach wie vielen Einkäufen ohne erneut hohe Abweichung ``Geschaeft/umbauVerdacht``
    /// wieder zurückgesetzt wird.
    static let einkaeufeBisUmbauZurueckgesetzt = 5
    /// Zeitfenster, innerhalb dessen der zeitliche Abstand zweier Besuche noch als
    /// Signal gilt — größere Abstände (z.B. durch eine Pause) werden verworfen.
    static let zeitfenster: TimeInterval = 5 * 60

    /// Ein einzelner Warengruppen-Besuch innerhalb eines Einkaufs — eine Zeile pro
    /// distinktem ``KaufEintrag/kategorieBesuchsIndex``, mit dem frühesten
    /// beobachteten ``KaufEintrag/datum`` als Besuchszeitpunkt (mehrere Artikel
    /// derselben Kategorie werden im selben Zeitraum abgehakt). `internal` statt
    /// `private`, damit ``erkenneUmbau(besuche:matrix:geschaeft:)`` ohne
    /// vollständigen Einkaufsvorgang direkt getestet werden kann.
    struct Besuch {
        let kategorie: ArtikelKategorie
        let zeitstempel: Date
    }

    /// Wertet einen gerade abgeschlossenen Einkaufsvorgang aus: aktualisiert die
    /// Distanzmatrix (``lerne(besuche:matrix:geschaeft:context:)``) und prüft auf
    /// einen möglichen Ladenumbau (``erkenneUmbau(besuche:matrix:geschaeft:)``).
    /// Ohne Wirkung, wenn der Einkauf kein Geschäft hat oder weniger als zwei
    /// unterschiedliche Warengruppen besucht wurden (keine Paare zum Lernen).
    static func verarbeiteEinkauf(_ einkaufsvorgang: Einkaufsvorgang, context: ModelContext) {
        guard let geschaeft = einkaufsvorgang.geschaeft else { return }
        let besuche = besuchsreihenfolge(fuer: einkaufsvorgang)
        guard besuche.count >= 2 else { return }

        let bekannte = WarengruppenDistanz.alle(fuer: geschaeft, context: context)
        var matrix = Dictionary(uniqueKeysWithValues: bekannte.map { (paarSchluessel(fuer: $0), $0) })

        // Umbau-Erkennung nutzt bewusst die Matrix VOR dem Lernschritt dieses
        // Einkaufs — sie vergleicht die neue Beobachtung gegen die bisherige
        // Erfahrung, nicht gegen sich selbst.
        erkenneUmbau(besuche: besuche, matrix: matrix, geschaeft: geschaeft)
        lerne(besuche: besuche, matrix: &matrix, geschaeft: geschaeft, context: context)
    }

    /// Baut die Besuchsreihenfolge eines Einkaufsvorgangs: eine ``Besuch``-Zeile je
    /// distinktem ``KaufEintrag/kategorieBesuchsIndex``, aufsteigend sortiert.
    private static func besuchsreihenfolge(fuer einkaufsvorgang: Einkaufsvorgang) -> [Besuch] {
        var nachIndex: [Int: (kategorie: ArtikelKategorie, fruehesterZeitpunkt: Date)] = [:]
        for eintrag in einkaufsvorgang.kaufEintraege {
            guard let kategorie = eintrag.kategorie, let index = eintrag.kategorieBesuchsIndex else { continue }
            if let bisher = nachIndex[index] {
                nachIndex[index] = (kategorie, min(bisher.fruehesterZeitpunkt, eintrag.datum))
            } else {
                nachIndex[index] = (kategorie, eintrag.datum)
            }
        }
        return nachIndex.keys.sorted().map { index in
            let (kategorie, zeitpunkt) = nachIndex[index]!
            return Besuch(kategorie: kategorie, zeitstempel: zeitpunkt)
        }
    }

    /// Aktualisiert die Distanzmatrix für jedes Paar besuchter Warengruppen dieses
    /// Einkaufs (Architekturvorschlag Abschnitt 4.1): kombiniert Positions- und
    /// Zeitdistanz und trägt sie per gleitendem Durchschnitt ein. Legt für bisher
    /// unbeobachtete Paare einen neuen ``WarengruppenDistanz``-Eintrag an.
    private static func lerne(
        besuche: [Besuch],
        matrix: inout [String: WarengruppenDistanz],
        geschaeft: Geschaeft,
        context: ModelContext
    ) {
        let gesamtanzahl = Double(besuche.count)
        let aktuelleLernrate = geschaeft.umbauVerdacht ? erhoehteLernrate : lernrate

        for i in 0..<besuche.count {
            for j in (i + 1)..<besuche.count {
                let distanz = kombinierteDistanz(von: besuche[i], nach: besuche[j], positionsAbstand: Double(j - i), gesamtanzahl: gesamtanzahl)
                let schluessel = paarSchluessel(fuer: besuche[i].kategorie, besuche[j].kategorie)
                if let bestehender = matrix[schluessel] {
                    bestehender.distanz = bestehender.distanz * (1 - aktuelleLernrate) + distanz * aktuelleLernrate
                } else {
                    let (kategorieA, kategorieB) = WarengruppenDistanz.kanonischesPaar(besuche[i].kategorie, besuche[j].kategorie)
                    let neuer = WarengruppenDistanz(
                        geschaeft: geschaeft,
                        kategorieA: kategorieA,
                        kategorieB: kategorieB,
                        distanz: WarengruppenDistanz.initialwert * (1 - aktuelleLernrate) + distanz * aktuelleLernrate
                    )
                    context.insert(neuer)
                    matrix[schluessel] = neuer
                }
            }
        }
    }

    /// Positions- und ggf. Zeitdistanz zwischen zwei Besuchen, kombiniert nach
    /// Architekturvorschlag Abschnitt 4.1, Schritte 1–3.
    private static func kombinierteDistanz(von a: Besuch, nach b: Besuch, positionsAbstand: Double, gesamtanzahl: Double) -> Double {
        let posDistanz = positionsAbstand / gesamtanzahl
        let zeitDelta = b.zeitstempel.timeIntervalSince(a.zeitstempel)
        guard zeitDelta <= zeitfenster else { return posDistanz }
        let zeitDistanz = min(zeitDelta, zeitfenster) / zeitfenster
        return 0.7 * posDistanz + 0.3 * zeitDistanz
    }

    /// Prüft, ob dieser Einkauf deutlich von der bisher gelernten Erfahrung
    /// abweicht (Architekturvorschlag Abschnitt 4.4), und pflegt
    /// ``Geschaeft/umbauVerdacht``/``Geschaeft/unauffaelligeEinkaeufeInFolge``
    /// entsprechend. `internal` statt `private`, damit die Erkennung ohne
    /// vollständigen Einkaufsvorgang direkt getestet werden kann.
    static func erkenneUmbau(besuche: [Besuch], matrix: [String: WarengruppenDistanz], geschaeft: Geschaeft) {
        guard besuche.count >= 2 else { return }
        let gesamtanzahl = Double(besuche.count)
        var abweichungen: [Double] = []
        for i in 0..<(besuche.count - 1) {
            let erwartet = matrix[paarSchluessel(fuer: besuche[i].kategorie, besuche[i + 1].kategorie)]?.distanz ?? WarengruppenDistanz.initialwert
            let tatsaechlich = kombinierteDistanz(von: besuche[i], nach: besuche[i + 1], positionsAbstand: 1, gesamtanzahl: gesamtanzahl)
            abweichungen.append(abs(erwartet - tatsaechlich))
        }
        let durchschnittlicheAbweichung = abweichungen.reduce(0, +) / Double(abweichungen.count)

        if durchschnittlicheAbweichung > umbauSchwelle {
            geschaeft.umbauVerdacht = true
            geschaeft.unauffaelligeEinkaeufeInFolge = 0
        } else if geschaeft.umbauVerdacht {
            geschaeft.unauffaelligeEinkaeufeInFolge += 1
            if geschaeft.unauffaelligeEinkaeufeInFolge >= einkaeufeBisUmbauZurueckgesetzt {
                geschaeft.umbauVerdacht = false
                geschaeft.unauffaelligeEinkaeufeInFolge = 0
            }
        }
    }

    // MARK: - Sortierung (Architekturvorschlag Abschnitt 4.2/4.3)

    /// Ob für dieses Geschäft genügend abgeschlossene Einkäufe vorliegen, um eine
    /// sortierte Reihenfolge statt der unsortierten Liste anzubieten.
    static func genuegendDatenVerfuegbar(fuer geschaeft: Geschaeft) -> Bool {
        geschaeft.anzahlEinkaufsvorgaenge >= mindestEinkaeufeFuerVorschlag
    }

    /// Sortiert `offeneKategorien` anhand der gelernten Distanzmatrix von
    /// `geschaeft`: Greedy-Nearest-Neighbor gefolgt von 2-opt-Verbesserung
    /// (Architekturvorschlag Abschnitt 4.2). `startpunkt` ist beim erstmaligen
    /// Sortieren `nil` (dann wird die Kategorie mit der niedrigsten
    /// Durchschnittsdistanz zu den übrigen als Start gewählt — vermutlich nahe
    /// dem Eingang); bei der dynamischen Neusortierung während des Einkaufs
    /// (Abschnitt 4.3) ist es die zuletzt abgehakte Kategorie. Liefert
    /// `offeneKategorien` unverändert (alphabetisch ist Aufgabe des Aufrufers),
    /// solange ``genuegendDatenVerfuegbar(fuer:)`` `false` ist oder weniger als
    /// zwei Kategorien offen sind.
    static func sortierteReihenfolge(
        offeneKategorien: [ArtikelKategorie],
        startpunkt: ArtikelKategorie?,
        in geschaeft: Geschaeft,
        context: ModelContext
    ) -> [ArtikelKategorie] {
        guard offeneKategorien.count > 1, genuegendDatenVerfuegbar(fuer: geschaeft) else { return offeneKategorien }

        let bekannte = WarengruppenDistanz.alle(fuer: geschaeft, context: context)
        let matrix = Dictionary(uniqueKeysWithValues: bekannte.map { (paarSchluessel(fuer: $0), $0.distanz) })
        func distanz(_ a: ArtikelKategorie, _ b: ArtikelKategorie) -> Double {
            matrix[paarSchluessel(fuer: a, b)] ?? WarengruppenDistanz.initialwert
        }

        var restliste = offeneKategorien
        let start: ArtikelKategorie
        if let startpunkt, let index = restliste.firstIndex(where: { $0.persistentModelID == startpunkt.persistentModelID }) {
            start = restliste.remove(at: index)
        } else {
            start = restliste.min { kandidatEins, kandidatZwei in
                durchschnittsdistanz(von: kandidatEins, zu: offeneKategorien, distanz: distanz)
                    < durchschnittsdistanz(von: kandidatZwei, zu: offeneKategorien, distanz: distanz)
            } ?? restliste.removeFirst()
            restliste.removeAll { $0.persistentModelID == start.persistentModelID }
        }

        var pfad = [start]
        while !restliste.isEmpty {
            let aktuell = pfad[pfad.count - 1]
            let naechsterIndex = restliste.indices.min { distanz(aktuell, restliste[$0]) < distanz(aktuell, restliste[$1]) }!
            pfad.append(restliste.remove(at: naechsterIndex))
        }

        return zweiOptVerbessert(pfad, distanz: distanz)
    }

    private static func durchschnittsdistanz(von kategorie: ArtikelKategorie, zu alle: [ArtikelKategorie], distanz: (ArtikelKategorie, ArtikelKategorie) -> Double) -> Double {
        let andere = alle.filter { $0.persistentModelID != kategorie.persistentModelID }
        guard !andere.isEmpty else { return 0 }
        return andere.reduce(0) { $0 + distanz(kategorie, $1) } / Double(andere.count)
    }

    /// 2-opt-Verbesserung (Architekturvorschlag Abschnitt 4.2, Phase 2): tauscht
    /// wiederholt Segmente des Pfads, solange sich die Gesamtdistanz dadurch
    /// verringert. Für die hier relevanten Listengrößen (5–30 Warengruppen)
    /// deutlich unter der geforderten 10ms-Grenze.
    private static func zweiOptVerbessert(_ pfad: [ArtikelKategorie], distanz: (ArtikelKategorie, ArtikelKategorie) -> Double) -> [ArtikelKategorie] {
        // Ab 3 Elementen kann eine Vertauschung die Gesamtdistanz noch verbessern
        // (z.B. [B, A, C] → [A, B, C]); bei ≤2 Elementen gibt es keine wirksame
        // Vertauschung.
        guard pfad.count > 2 else { return pfad }
        var pfad = pfad
        func gesamtdistanz(_ p: [ArtikelKategorie]) -> Double {
            guard p.count > 1 else { return 0 }
            return (0..<(p.count - 1)).reduce(0) { $0 + distanz(p[$1], p[$1 + 1]) }
        }
        var verbessert = true
        while verbessert {
            verbessert = false
            for i in 0..<(pfad.count - 1) {
                for j in (i + 1)..<pfad.count {
                    var kandidat = pfad
                    kandidat[i...j].reverse()
                    if gesamtdistanz(kandidat) < gesamtdistanz(pfad) {
                        pfad = kandidat
                        verbessert = true
                    }
                }
            }
        }
        return pfad
    }

    // MARK: - Gemeinsame Schlüssel-Erzeugung

    private static func paarSchluessel(fuer eintrag: WarengruppenDistanz) -> String {
        guard let a = eintrag.kategorieA, let b = eintrag.kategorieB else { return eintrag.id.uuidString }
        return paarSchluessel(fuer: a, b)
    }

    /// `internal` statt `private`, damit Tests dieselben Schlüssel bilden können
    /// wie ``erkenneUmbau(besuche:matrix:geschaeft:)``/``lerne(besuche:matrix:geschaeft:context:)``,
    /// um eine passende Test-Matrix zu konstruieren.
    ///
    /// Nutzt bewusst ``ArtikelKategorie/id`` (die von der App vergebene `UUID`)
    /// statt `persistentModelID`: dessen String-Darstellung ist für noch nicht
    /// gespeicherte ("temporäre") Objekte nicht eindeutig — zwei unterschiedliche,
    /// frisch angelegte Kategorien können sich dann auf denselben Schlüssel
    /// abbilden, was zu einem Absturz beim Aufbau der Lookup-Map führt.
    static func paarSchluessel(fuer a: ArtikelKategorie, _ b: ArtikelKategorie) -> String {
        let (erste, zweite) = WarengruppenDistanz.kanonischesPaar(a, b)
        return "\(erste.id)_\(zweite.id)"
    }
}
