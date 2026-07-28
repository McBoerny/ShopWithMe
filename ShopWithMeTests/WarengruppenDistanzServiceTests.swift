import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct WarengruppenDistanzServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self, SyncEvent.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    /// Legt einen ``KaufEintrag`` mit vorgegebenem ``KaufEintrag/kategorieBesuchsIndex``
    /// und ``KaufEintrag/datum`` an — bewusst statt über
    /// ``Einkaufsvorgang/artikelAbhaken(_:context:)``, damit Zeitstempel und Reihenfolge
    /// in den Tests präzise kontrollierbar sind.
    private func kaufEintrag(
        kategorie: ArtikelKategorie,
        index: Int,
        datum: Date,
        einkaufsvorgang: Einkaufsvorgang,
        geschaeft: Geschaeft,
        context: ModelContext
    ) {
        let eintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, kategorie: kategorie, datum: datum, kategorieBesuchsIndex: index)
        context.insert(eintrag)
        eintrag.einkaufsvorgang = einkaufsvorgang
    }

    @Test
    func kanonischesPaarIstUnabhaengigVonDerEingabereihenfolge() {
        let a = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let (a1, b1) = WarengruppenDistanz.kanonischesPaar(a, b)
        let (a2, b2) = WarengruppenDistanz.kanonischesPaar(b, a)
        #expect(a1 === a2)
        #expect(b1 === b2)
    }

    @Test
    func verarbeiteEinkaufLerntPositionsDistanzFuerBesuchteWarengruppenpaare() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let elektro = ArtikelKategorie(name: "Elektro", standardSymbol: "bolt.fill", standardFarbeHex: "#FFCC00")
        context.insert(obst)
        context.insert(drogerie)
        context.insert(elektro)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        // Zeitlich weit auseinander (> 5 Minuten), damit die Zeitdistanz verworfen
        // wird und nur die reine Positionsdistanz gelernt wird.
        let start = Date()
        kaufEintrag(kategorie: obst, index: 0, datum: start, einkaufsvorgang: einkauf, geschaeft: geschaeft, context: context)
        kaufEintrag(kategorie: drogerie, index: 1, datum: start.addingTimeInterval(600), einkaufsvorgang: einkauf, geschaeft: geschaeft, context: context)
        kaufEintrag(kategorie: elektro, index: 2, datum: start.addingTimeInterval(1200), einkaufsvorgang: einkauf, geschaeft: geschaeft, context: context)

        WarengruppenDistanzService.verarbeiteEinkauf(einkauf, context: context)

        let alle = WarengruppenDistanz.alle(fuer: geschaeft, context: context)
        #expect(alle.count == 3)

        func distanz(_ a: ArtikelKategorie, _ b: ArtikelKategorie) -> Double? {
            let schluessel = WarengruppenDistanzService.paarSchluessel(fuer: a, b)
            return alle.first { WarengruppenDistanzService.paarSchluessel(fuer: $0.kategorieA!, $0.kategorieB!) == schluessel }?.distanz
        }

        // posDistanz(obst, drogerie) = 1/3, posDistanz(obst, elektro) = 2/3 — nach
        // dem ersten Lernschritt (Initialwert 0.5, Lernrate 0.1):
        // neuerWert = 0.5*0.9 + posDistanz*0.1
        let erwarteteNaheDistanz = 0.5 * 0.9 + (1.0 / 3.0) * 0.1
        let erwarteteFerneDistanz = 0.5 * 0.9 + (2.0 / 3.0) * 0.1
        #expect(abs(distanz(obst, drogerie)! - erwarteteNaheDistanz) < 0.0001)
        #expect(abs(distanz(obst, elektro)! - erwarteteFerneDistanz) < 0.0001)
        // Zwei benachbarte Kategorien sollten eine kleinere gelernte Distanz haben
        // als zwei weit auseinanderliegende.
        #expect(distanz(obst, drogerie)! < distanz(obst, elektro)!)
    }

    @Test
    func verarbeiteEinkaufNaehertDistanzUeberWiederholteEinkaeufeAn() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let start = Date()
        for _ in 0..<50 {
            let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
            context.insert(einkauf)
            kaufEintrag(kategorie: obst, index: 0, datum: start, einkaufsvorgang: einkauf, geschaeft: geschaeft, context: context)
            kaufEintrag(kategorie: drogerie, index: 1, datum: start.addingTimeInterval(600), einkaufsvorgang: einkauf, geschaeft: geschaeft, context: context)
            WarengruppenDistanzService.verarbeiteEinkauf(einkauf, context: context)
        }

        let alle = WarengruppenDistanz.alle(fuer: geschaeft, context: context)
        #expect(alle.count == 1)
        // posDistanz(obst, drogerie) = 1/2 bei nur zwei Warengruppen — nach vielen
        // Wiederholungen nähert sich der gleitende Durchschnitt diesem Wert an.
        #expect(abs(alle[0].distanz - 0.5) < 0.01)
    }

    @Test
    func sortierteReihenfolgePlatziertMittigeWarengruppeZwischenZweiFernenAnEnden() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let a = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let c = ArtikelKategorie(name: "C", standardSymbol: "bolt.fill", standardFarbeHex: "#FFCC00")
        context.insert(a)
        context.insert(b)
        context.insert(c)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        geschaeft.anzahlEinkaufsvorgaenge = 3
        context.insert(geschaeft)

        // A und B liegen nah beieinander, B und C ebenfalls, A und C sind weit
        // entfernt — B muss daher in der Mitte liegen.
        let (abA, abB) = WarengruppenDistanz.kanonischesPaar(a, b)
        context.insert(WarengruppenDistanz(geschaeft: geschaeft, kategorieA: abA, kategorieB: abB, distanz: 0.1))
        let (bcA, bcB) = WarengruppenDistanz.kanonischesPaar(b, c)
        context.insert(WarengruppenDistanz(geschaeft: geschaeft, kategorieA: bcA, kategorieB: bcB, distanz: 0.1))
        let (acA, acB) = WarengruppenDistanz.kanonischesPaar(a, c)
        context.insert(WarengruppenDistanz(geschaeft: geschaeft, kategorieA: acA, kategorieB: acB, distanz: 0.9))

        let sortiert = WarengruppenDistanzService.sortierteReihenfolge(
            offeneKategorien: [a, b, c], startpunkt: nil, in: geschaeft, context: context
        )

        #expect(sortiert.count == 3)
        #expect(sortiert[1].persistentModelID == b.persistentModelID)
    }

    @Test
    func sortierteReihenfolgeBeginntMitExplizitemStartpunkt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let a = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let c = ArtikelKategorie(name: "C", standardSymbol: "bolt.fill", standardFarbeHex: "#FFCC00")
        context.insert(a)
        context.insert(b)
        context.insert(c)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        geschaeft.anzahlEinkaufsvorgaenge = 3
        context.insert(geschaeft)

        let sortiert = WarengruppenDistanzService.sortierteReihenfolge(
            offeneKategorien: [a, b, c], startpunkt: c, in: geschaeft, context: context
        )

        #expect(sortiert.first?.persistentModelID == c.persistentModelID)
    }

    @Test
    func sortierteReihenfolgeBleibtUnveraendertOhneGenuegendEinkaeufe() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let a = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(a)
        context.insert(b)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        geschaeft.anzahlEinkaufsvorgaenge = 1
        context.insert(geschaeft)

        let eingabe = [a, b]
        let sortiert = WarengruppenDistanzService.sortierteReihenfolge(
            offeneKategorien: eingabe, startpunkt: nil, in: geschaeft, context: context
        )

        #expect(sortiert.map(\.persistentModelID) == eingabe.map(\.persistentModelID))
    }

    @Test
    func erkenneUmbauSetztVerdachtBeiDeutlicherAbweichung() {
        let a = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])

        let (kategorieA, kategorieB) = WarengruppenDistanz.kanonischesPaar(a, b)
        let eintrag = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kategorieA, kategorieB: kategorieB, distanz: 0.1)
        let matrix = [WarengruppenDistanzService.paarSchluessel(fuer: a, b): eintrag]

        // Zeitabstand exakt am Zeitfenster (5 Minuten) → maximale Zeitdistanz (1.0),
        // tatsächliche Distanz 0.7*0.5 + 0.3*1.0 = 0.65 — Abweichung zur gelernten
        // Erwartung (0.1) beträgt 0.55, deutlich über der Schwelle (0.3).
        let start = Date()
        let besuche = [
            WarengruppenDistanzService.Besuch(kategorie: a, zeitstempel: start),
            WarengruppenDistanzService.Besuch(kategorie: b, zeitstempel: start.addingTimeInterval(300)),
        ]

        WarengruppenDistanzService.erkenneUmbau(besuche: besuche, matrix: matrix, geschaeft: geschaeft)

        #expect(geschaeft.umbauVerdacht == true)
        #expect(geschaeft.unauffaelligeEinkaeufeInFolge == 0)
    }

    @Test
    func erkenneUmbauSetztVerdachtNachFuenfUnauffaelligenEinkaeufenZurueck() {
        let a = ArtikelKategorie(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = ArtikelKategorie(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        geschaeft.umbauVerdacht = true

        let (kategorieA, kategorieB) = WarengruppenDistanz.kanonischesPaar(a, b)
        let eintrag = WarengruppenDistanz(geschaeft: geschaeft, kategorieA: kategorieA, kategorieB: kategorieB, distanz: 0.1)
        let matrix = [WarengruppenDistanzService.paarSchluessel(fuer: a, b): eintrag]

        // Zeitabstand 0 → Zeitdistanz 0, tatsächliche Distanz 0.7*0.5 = 0.35 —
        // Abweichung zur gelernten Erwartung (0.1) beträgt 0.25, unter der Schwelle.
        let start = Date()
        let besuche = [
            WarengruppenDistanzService.Besuch(kategorie: a, zeitstempel: start),
            WarengruppenDistanzService.Besuch(kategorie: b, zeitstempel: start),
        ]

        for durchlauf in 1...4 {
            WarengruppenDistanzService.erkenneUmbau(besuche: besuche, matrix: matrix, geschaeft: geschaeft)
            #expect(geschaeft.umbauVerdacht == true, "sollte vor dem fünften unauffälligen Einkauf bestehen bleiben (Durchlauf \(durchlauf))")
        }
        WarengruppenDistanzService.erkenneUmbau(besuche: besuche, matrix: matrix, geschaeft: geschaeft)
        #expect(geschaeft.umbauVerdacht == false)
        #expect(geschaeft.unauffaelligeEinkaeufeInFolge == 0)
    }
}
