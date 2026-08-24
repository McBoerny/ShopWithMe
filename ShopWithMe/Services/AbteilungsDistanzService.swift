import Foundation
import SwiftData

/// Lernt aus der Abhakreihenfolge abgeschlossener ``Einkaufsvorgang``e eine
/// ladenspezifische, paarweise Distanz zwischen Abteilungen ("Abteilungen")
/// und leitet daraus eine dynamisch nachsortierbare Einkaufsreihenfolge ab — siehe
/// `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md` (GitHub #36).
///
/// Ersetzt den früheren, gröberen Ansatz über einen einzelnen Durchschnittswert je
/// Abteilung: dieser Service lernt eine vollständige paarweise Distanzmatrix
/// (``WarengruppenDistanz``), die sich nach jeder Abhakung neu sortieren lässt
/// (``sortierteReihenfolge(offeneAbteilungen:startpunkt:in:context:)``), statt nur
/// einmal beim Einkaufsstart.
enum AbteilungsDistanzService {
    /// Ab wie vielen abgeschlossenen Einkäufen in einem Geschäft eine sortierte
    /// Reihenfolge angeboten wird (siehe Architekturvorschlag Abschnitt 12, Phase 3).
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
    /// Ab wie vielen ``KaufEintrag``en desselben Artikels in einem Geschäft
    /// ``gelernteAbteilung(fuer:in:context:)`` überhaupt eine Aussage trifft (siehe
    /// dort) — darunter bleibt das Ergebnis `nil`. Bewusst nicht rein prozentual
    /// ab dem ersten Kauf: ein einzelner Kauf wäre immer "100% Mehrheit" und würde
    /// einen einzelnen Fehltap (falsche Abteilung versehentlich angetippt) sofort
    /// ungefiltert übernehmen. Bei einer echten Vorliebe mit ca. 10% gelegentlicher
    /// Fehltap-Rate erreicht die 80%-Schwelle
    /// (``mehrheitsschwelleGelernteAbteilung``) bereits nach 5 Käufen mit ca. 92%
    /// Wahrscheinlichkeit; bei einem tatsächlich 50/50 mehrdeutigen Artikel liegt
    /// die Wahrscheinlichkeit eines rein zufälligen Früh-Treffers bei ca. 19% —
    /// siehe `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md` Abschnitt 14 für
    /// die vollständige Herleitung.
    static let mindestKaeufeFuerGelernteAbteilung = 5
    /// Ab welchem Anteil der häufigsten Abteilung an allen Käufen
    /// ``gelernteAbteilung(fuer:in:context:)`` sie als eindeutig genug wertet.
    static let mehrheitsschwelleGelernteAbteilung = 0.8

    /// Ein einzelner Abteilungs-Besuch innerhalb eines Einkaufs — eine Zeile pro
    /// distinktem ``KaufEintrag/abteilungBesuchsIndex``, mit dem frühesten
    /// beobachteten ``KaufEintrag/datum`` als Besuchszeitpunkt (mehrere Artikel
    /// derselben Abteilung werden im selben Zeitraum abgehakt). `internal` statt
    /// `private`, damit ``erkenneUmbau(besuche:matrix:geschaeft:)`` ohne
    /// vollständigen Einkaufsvorgang direkt getestet werden kann.
    struct Besuch {
        let abteilung: Abteilung
        let zeitstempel: Date
    }

    /// Wertet einen gerade abgeschlossenen Einkaufsvorgang aus: aktualisiert die
    /// Distanzmatrix (``lerne(besuche:matrix:geschaeft:context:)``) und prüft auf
    /// einen möglichen Ladenumbau (``erkenneUmbau(besuche:matrix:geschaeft:)``).
    /// Ohne Wirkung, wenn der Einkauf kein Geschäft hat oder weniger als zwei
    /// unterschiedliche Abteilungen besucht wurden (keine Paare zum Lernen).
    ///
    /// Liefert `true`, wenn ``Geschaeft/umbauVerdacht`` durch **diesen** Einkauf
    /// neu von `false` auf `true` gewechselt ist — anders als der reine
    /// Feldwert bleibt dieses Ergebnis über die folgenden Einkäufe hinweg nicht
    /// `true`, sodass ein Aufrufer (z.B. ein Hinweis-Dialog) nur beim
    /// erstmaligen Erkennen reagieren kann statt bei jedem Einkauf erneut,
    /// solange der Verdacht noch nicht wieder zurückgesetzt wurde.
    @discardableResult
    static func verarbeiteEinkauf(_ einkaufsvorgang: Einkaufsvorgang, context: ModelContext) -> Bool {
        guard let geschaeft = einkaufsvorgang.geschaeft else { return false }
        let besuche = besuchsreihenfolge(fuer: einkaufsvorgang)
        guard besuche.count >= 2 else { return false }

        let bekannte = WarengruppenDistanz.alle(fuer: geschaeft, context: context)
        var matrix = Dictionary(uniqueKeysWithValues: bekannte.map { (paarSchluessel(fuer: $0), $0) })

        // Umbau-Erkennung nutzt bewusst die Matrix VOR dem Lernschritt dieses
        // Einkaufs — sie vergleicht die neue Beobachtung gegen die bisherige
        // Erfahrung, nicht gegen sich selbst.
        let umbauNeuErkannt = erkenneUmbau(besuche: besuche, matrix: matrix, geschaeft: geschaeft)
        lerne(besuche: besuche, matrix: &matrix, geschaeft: geschaeft, context: context)
        return umbauNeuErkannt
    }

    /// Baut die Besuchsreihenfolge eines Einkaufsvorgangs: eine ``Besuch``-Zeile je
    /// distinktem ``KaufEintrag/abteilungBesuchsIndex``, aufsteigend sortiert.
    private static func besuchsreihenfolge(fuer einkaufsvorgang: Einkaufsvorgang) -> [Besuch] {
        var nachIndex: [Int: (abteilung: Abteilung, fruehesterZeitpunkt: Date)] = [:]
        for eintrag in einkaufsvorgang.kaufEintraege {
            guard let abteilung = eintrag.abteilung, let index = eintrag.abteilungBesuchsIndex else { continue }
            if let bisher = nachIndex[index] {
                nachIndex[index] = (abteilung, min(bisher.fruehesterZeitpunkt, eintrag.datum))
            } else {
                nachIndex[index] = (abteilung, eintrag.datum)
            }
        }
        return nachIndex.keys.sorted().map { index in
            let (abteilung, zeitpunkt) = nachIndex[index]!
            return Besuch(abteilung: abteilung, zeitstempel: zeitpunkt)
        }
    }

    /// Aktualisiert die Distanzmatrix für jedes Paar besuchter Abteilungen dieses
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
                let schluessel = paarSchluessel(fuer: besuche[i].abteilung, besuche[j].abteilung)
                if let bestehender = matrix[schluessel] {
                    bestehender.distanz = bestehender.distanz * (1 - aktuelleLernrate) + distanz * aktuelleLernrate
                    bestehender.eigeneBeobachtungsAnzahl += 1
                } else {
                    let (abteilungA, abteilungB) = WarengruppenDistanz.kanonischesPaar(besuche[i].abteilung, besuche[j].abteilung)
                    let neuer = WarengruppenDistanz(
                        geschaeft: geschaeft,
                        abteilungA: abteilungA,
                        abteilungB: abteilungB,
                        distanz: WarengruppenDistanz.initialwert * (1 - aktuelleLernrate) + distanz * aktuelleLernrate
                    )
                    neuer.eigeneBeobachtungsAnzahl = 1
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
    ///
    /// Liefert `true` genau dann, wenn ``Geschaeft/umbauVerdacht`` durch diesen
    /// Aufruf von `false` auf `true` wechselt (siehe
    /// ``verarbeiteEinkauf(_:context:)``); bleibt der Verdacht über mehrere
    /// Einkäufe hinweg bestehen, liefern die folgenden Aufrufe `false`.
    @discardableResult
    static func erkenneUmbau(besuche: [Besuch], matrix: [String: WarengruppenDistanz], geschaeft: Geschaeft) -> Bool {
        guard besuche.count >= 2 else { return false }
        let gesamtanzahl = Double(besuche.count)
        var abweichungen: [Double] = []
        for i in 0..<(besuche.count - 1) {
            let erwartet = matrix[paarSchluessel(fuer: besuche[i].abteilung, besuche[i + 1].abteilung)]?.distanz ?? WarengruppenDistanz.initialwert
            let tatsaechlich = kombinierteDistanz(von: besuche[i], nach: besuche[i + 1], positionsAbstand: 1, gesamtanzahl: gesamtanzahl)
            abweichungen.append(abs(erwartet - tatsaechlich))
        }
        let durchschnittlicheAbweichung = abweichungen.reduce(0, +) / Double(abweichungen.count)

        if durchschnittlicheAbweichung > umbauSchwelle {
            let neuErkannt = !geschaeft.umbauVerdacht
            geschaeft.umbauVerdacht = true
            geschaeft.unauffaelligeEinkaeufeInFolge = 0
            return neuErkannt
        } else if geschaeft.umbauVerdacht {
            geschaeft.unauffaelligeEinkaeufeInFolge += 1
            if geschaeft.unauffaelligeEinkaeufeInFolge >= einkaeufeBisUmbauZurueckgesetzt {
                geschaeft.umbauVerdacht = false
                geschaeft.unauffaelligeEinkaeufeInFolge = 0
            }
        }
        return false
    }

    // MARK: - Sortierung (Architekturvorschlag Abschnitt 4.2/4.3)

    /// Ob für dieses Geschäft genügend abgeschlossene Einkäufe vorliegen, um eine
    /// sortierte Reihenfolge statt der unsortierten Liste anzubieten.
    static func genuegendDatenVerfuegbar(fuer geschaeft: Geschaeft) -> Bool {
        geschaeft.anzahlEinkaufsvorgaenge >= mindestEinkaeufeFuerVorschlag
    }

    /// Sortiert `offeneAbteilungen` anhand der gelernten Distanzmatrix von
    /// `geschaeft`: Greedy-Nearest-Neighbor gefolgt von 2-opt-Verbesserung
    /// (Architekturvorschlag Abschnitt 4.2). `startpunkt` ist beim erstmaligen
    /// Sortieren `nil` (dann wird die Abteilung mit der niedrigsten
    /// Durchschnittsdistanz zu den übrigen als Start gewählt — vermutlich nahe
    /// dem Eingang); bei der dynamischen Neusortierung während des Einkaufs
    /// (Abschnitt 4.3) ist es die zuletzt abgehakte Abteilung. Liefert
    /// `offeneAbteilungen` unverändert (alphabetisch ist Aufgabe des Aufrufers),
    /// solange ``genuegendDatenVerfuegbar(fuer:)`` `false` ist oder weniger als
    /// zwei Abteilungen offen sind.
    static func sortierteReihenfolge(
        offeneAbteilungen: [Abteilung],
        startpunkt: Abteilung?,
        in geschaeft: Geschaeft,
        context: ModelContext
    ) -> [Abteilung] {
        guard offeneAbteilungen.count > 1, genuegendDatenVerfuegbar(fuer: geschaeft) else { return offeneAbteilungen }

        let bekannte = WarengruppenDistanz.alle(fuer: geschaeft, context: context)
        let matrix = Dictionary(uniqueKeysWithValues: bekannte.map { (paarSchluessel(fuer: $0), $0.distanz) })
        func distanz(_ a: Abteilung, _ b: Abteilung) -> Double {
            matrix[paarSchluessel(fuer: a, b)] ?? WarengruppenDistanz.initialwert
        }

        var restliste = offeneAbteilungen
        let start: Abteilung
        if let startpunkt, let index = restliste.firstIndex(where: { $0.persistentModelID == startpunkt.persistentModelID }) {
            start = restliste.remove(at: index)
        } else {
            // `restliste` ist an dieser Stelle noch unverändert `offeneAbteilungen`
            // und laut Guard oben nicht leer — `.min` kann daher nie `nil` liefern.
            start = restliste.min { kandidatEins, kandidatZwei in
                durchschnittsdistanz(von: kandidatEins, zu: offeneAbteilungen, distanz: distanz)
                    < durchschnittsdistanz(von: kandidatZwei, zu: offeneAbteilungen, distanz: distanz)
            }!
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

    private static func durchschnittsdistanz(von abteilung: Abteilung, zu alle: [Abteilung], distanz: (Abteilung, Abteilung) -> Double) -> Double {
        let andere = alle.filter { $0.persistentModelID != abteilung.persistentModelID }
        guard !andere.isEmpty else { return 0 }
        return andere.reduce(0) { $0 + distanz(abteilung, $1) } / Double(andere.count)
    }

    /// 2-opt-Verbesserung (Architekturvorschlag Abschnitt 4.2, Phase 2): tauscht
    /// wiederholt Segmente des Pfads, solange sich die Gesamtdistanz dadurch
    /// verringert. Für die hier relevanten Listengrößen (5–30 Abteilungen)
    /// deutlich unter der geforderten 10ms-Grenze.
    private static func zweiOptVerbessert(_ pfad: [Abteilung], distanz: (Abteilung, Abteilung) -> Double) -> [Abteilung] {
        // Ab 3 Elementen kann eine Vertauschung die Gesamtdistanz noch verbessern
        // (z.B. [B, A, C] → [A, B, C]); bei ≤2 Elementen gibt es keine wirksame
        // Vertauschung.
        guard pfad.count > 2 else { return pfad }
        var pfad = pfad
        func gesamtdistanz(_ p: [Abteilung]) -> Double {
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

    // MARK: - Gelernte Abteilung je Artikel und Geschäft (GitHub-Nachfolgefund zu #36)

    /// Die aus der Kaufhistorie gelernte Abteilung von `artikel` in `geschaeft` —
    /// `nil`, solange nicht eindeutig genug (siehe
    /// ``mindestKaeufeFuerGelernteAbteilung``/``mehrheitsschwelleGelernteAbteilung``).
    /// Grundlage: jeder ``KaufEintrag`` hält bereits fest, aus welchem Abschnitt er
    /// tatsächlich abgehakt wurde (siehe `Einkaufsvorgang.artikelAbhaken(_:context:abteilung:)`).
    /// Zählt schlicht die Häufigkeit je Abteilung — bewusst kein gleitender
    /// Durchschnitt wie bei der Distanzmatrix, da hier (anders als bei der
    /// Reihenfolge) nicht "wandern" soll, was einmal stabil gelernt ist: ein
    /// einzelner untypischer Kauf soll das Ergebnis nicht sofort kippen, sondern
    /// erst eine wiederholte Häufung in eine andere Abteilung.
    ///
    /// Absichtlich nicht dauerhaft zwischengespeichert, sondern bei jedem Aufruf neu
    /// aus den aktuellen ``KaufEintrag``en berechnet: verschiebt sich die Mehrheit
    /// durch neue Käufe (oder durch über den Sync eintreffende Käufe eines anderen
    /// Geräts) wieder unter die Schwelle, blendet die Anzeige automatisch wieder
    /// alle Abteilungen ein, statt an einer veralteten Entscheidung festzuhalten.
    static func gelernteAbteilung(fuer artikel: Artikel, in geschaeft: Geschaeft, context: ModelContext) -> Abteilung? {
        let artikelID = artikel.persistentModelID
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<KaufEintrag>(
            predicate: #Predicate<KaufEintrag> {
                $0.artikel?.persistentModelID == artikelID && $0.geschaeft?.persistentModelID == geschaeftID
            }
        )
        let abteilungen = ((try? context.fetch(deskriptor)) ?? []).compactMap(\.abteilung)
        guard abteilungen.count >= mindestKaeufeFuerGelernteAbteilung else { return nil }

        var haeufigkeit: [PersistentIdentifier: (abteilung: Abteilung, anzahl: Int)] = [:]
        for abteilung in abteilungen {
            haeufigkeit[abteilung.persistentModelID, default: (abteilung, 0)].anzahl += 1
        }
        guard let fuehrende = haeufigkeit.values.max(by: { $0.anzahl < $1.anzahl }) else { return nil }
        let anteil = Double(fuehrende.anzahl) / Double(abteilungen.count)
        return anteil >= mehrheitsschwelleGelernteAbteilung ? fuehrende.abteilung : nil
    }

    // MARK: - Gemeinsame Schlüssel-Erzeugung

    private static func paarSchluessel(fuer eintrag: WarengruppenDistanz) -> String {
        guard let a = eintrag.abteilungA, let b = eintrag.abteilungB else { return eintrag.id.uuidString }
        return paarSchluessel(fuer: a, b)
    }

    /// `internal` statt `private`, damit Tests dieselben Schlüssel bilden können
    /// wie ``erkenneUmbau(besuche:matrix:geschaeft:)``/``lerne(besuche:matrix:geschaeft:context:)``,
    /// um eine passende Test-Matrix zu konstruieren.
    ///
    /// Nutzt bewusst ``Abteilung/id`` (die von der App vergebene `UUID`)
    /// statt `persistentModelID`: dessen String-Darstellung ist für noch nicht
    /// gespeicherte ("temporäre") Objekte nicht eindeutig — zwei unterschiedliche,
    /// frisch angelegte Abteilungen können sich dann auf denselben Schlüssel
    /// abbilden, was zu einem Absturz beim Aufbau der Lookup-Map führt.
    static func paarSchluessel(fuer a: Abteilung, _ b: Abteilung) -> String {
        let (erste, zweite) = WarengruppenDistanz.kanonischesPaar(a, b)
        return "\(erste.id)_\(zweite.id)"
    }
}
