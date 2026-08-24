import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``EinkaufsvorgangAbschlussService`` (GitHub #107, extrahiert aus
/// `EinkaufenView.swift`) — jeder Testfall entspricht einem der drei
/// aufeinanderfolgenden Live-Test-Funde aus `docs/DATENSYNCHRONISATION.md`
/// §4.3 (Session 2026-08-03), die vorher nur live am Gerät gefunden werden
/// konnten, weil diese Logik ausschließlich als private View-Methode
/// existierte.
@MainActor
struct EinkaufsvorgangAbschlussServiceTests {
    private let schema = Schema([
        Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
        Einkaufsvorgang.self, KaufEintrag.self, Einkaufsliste.self, EinkaufslistenEintrag.self,
        WarengruppenDistanz.self, SyncEvent.self, SyncPeerZaehlerStand.self, GeschaeftBesuch.self,
    ])

    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    @Test
    func schliesstAnkerAbUndZaehltGenauEinenBesuch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let anker = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(anker)

        let ergebnis = EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(anker: anker, duplikate: [], context: context)

        #expect(anker.istAbgeschlossen)
        #expect(geschaeft.eigeneAnzahlEinkaufsvorgaenge == 1)
        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 1)
        #expect(ergebnis.geschlosseneDuplikate == 0)
    }

    @Test
    func schliesstDuplikatDerselbenGeschaeftListeKombinationOhneDoppeltZuZaehlen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let anker = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(anker)
        let duplikat = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(duplikat)

        let ergebnis = EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(
            anker: anker, duplikate: [ModelReference(duplikat)], context: context
        )

        #expect(anker.istAbgeschlossen)
        #expect(duplikat.istAbgeschlossen)
        #expect(geschaeft.eigeneAnzahlEinkaufsvorgaenge == 1)
        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 1)
        #expect(ergebnis.geschlosseneDuplikate == 1)
    }

    @Test
    func schliesstDuplikatEinesAnderenGeschaeftsDerselbenListe() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeftA = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let geschaeftB = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        context.insert(geschaeftA)
        context.insert(geschaeftB)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        context.insert(liste)
        let anker = Einkaufsvorgang(geschaeft: geschaeftA, einkaufsliste: liste)
        context.insert(anker)
        // Duplikat an einem ANDEREN Geschäft derselben Liste — genau der Fall,
        // den der dritte, finale Live-Test-Fix abdeckt (Entfernen des
        // Geschäfts-Filters bei der Duplikat-Auswahl). Der Service selbst
        // kennt gar kein Geschäfts-Konzept in seiner Auswahl — dieser Test
        // verifiziert nur, dass ein vom Aufrufer übergebenes Duplikat auch
        // dann korrekt geschlossen wird, wenn es an einem anderen Geschäft hängt.
        let duplikat = Einkaufsvorgang(geschaeft: geschaeftB, einkaufsliste: liste)
        context.insert(duplikat)

        EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(
            anker: anker, duplikate: [ModelReference(duplikat)], context: context
        )

        #expect(anker.istAbgeschlossen)
        #expect(duplikat.istAbgeschlossen)
        #expect(geschaeftA.eigeneAnzahlEinkaufsvorgaenge == 1)
        #expect(geschaeftB.eigeneAnzahlEinkaufsvorgaenge == 0)
    }

    @Test
    func ueberspringtBereitsGeschlossenesDuplikatOhneAbbruch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let anker = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(anker)
        let bereitsGeschlossen = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(bereitsGeschlossen)
        let bereitsGeschlosseneEndZeit = Date().addingTimeInterval(-1000)
        bereitsGeschlossen.abschliessen(am: bereitsGeschlosseneEndZeit, zaehleAlsBesuch: false)

        let ergebnis = EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(
            anker: anker, duplikate: [ModelReference(bereitsGeschlossen)], context: context
        )

        #expect(anker.istAbgeschlossen)
        #expect(bereitsGeschlossen.endZeit == bereitsGeschlosseneEndZeit)
        #expect(ergebnis.geschlosseneDuplikate == 0)
    }

    @Test
    func ueberspringtNichtMehrAufloesbaresDuplikat() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let anker = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(anker)
        let geloeschtesDuplikat = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(geloeschtesDuplikat)
        try context.save()
        let referenz = ModelReference(geloeschtesDuplikat)
        context.delete(geloeschtesDuplikat)
        try context.save()

        let ergebnis = EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(
            anker: anker, duplikate: [referenz], context: context
        )

        #expect(anker.istAbgeschlossen)
        #expect(ergebnis.geschlosseneDuplikate == 0)
    }

    /// Baut über ``WarengruppenDistanz`` + zwei ``KaufEintrag``e eine
    /// "deutliche Abweichung" auf, analog
    /// `AbteilungsDistanzServiceTests.erkenneUmbauSetztVerdachtBeiDeutlicherAbweichung`.
    private func richteDeutlicheAbweichungEin(
        geschaeft: Geschaeft, vorgang: Einkaufsvorgang, context: ModelContext
    ) {
        let a = Abteilung(name: "A", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let b = Abteilung(name: "B", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(a)
        context.insert(b)
        let (abteilungA, abteilungB) = WarengruppenDistanz.kanonischesPaar(a, b)
        context.insert(WarengruppenDistanz(geschaeft: geschaeft, abteilungA: abteilungA, abteilungB: abteilungB, distanz: 0.1))

        let start = Date()
        let ersterEintrag = KaufEintrag(artikel: nil, geschaeft: geschaeft, abteilung: a, datum: start, abteilungBesuchsIndex: 0)
        context.insert(ersterEintrag)
        ersterEintrag.einkaufsvorgang = vorgang
        let zweiterEintrag = KaufEintrag(
            artikel: nil, geschaeft: geschaeft, abteilung: b, datum: start.addingTimeInterval(300), abteilungBesuchsIndex: 1
        )
        context.insert(zweiterEintrag)
        zweiterEintrag.einkaufsvorgang = vorgang
    }

    @Test
    func gibtUmbauErkennungDesAnkersAlsErgebnisZurueck() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let anker = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(anker)
        richteDeutlicheAbweichungEin(geschaeft: geschaeft, vorgang: anker, context: context)

        let ergebnis = EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(anker: anker, duplikate: [], context: context)

        #expect(ergebnis.umbauNeuErkannt == true)
        #expect(geschaeft.umbauVerdacht == true)
    }

    @Test
    func laesstDuplikateNichtInDieAbteilungsDistanzEinfliessen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        // Anker hat weniger als zwei besuchte Abteilungen → verarbeiteEinkauf
        // liefert für ihn allein `false`, unabhängig von der Matrix.
        let anker = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(anker)
        // Das Duplikat trägt die "deutliche Abweichung" — würde der Service
        // fälschlich auch das Duplikat an AbteilungsDistanzService
        // weiterreichen, würde umbauNeuErkannt hier `true` werden.
        let duplikat = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(duplikat)
        richteDeutlicheAbweichungEin(geschaeft: geschaeft, vorgang: duplikat, context: context)

        let ergebnis = EinkaufsvorgangAbschlussService.schliesseAbMitDuplikaten(
            anker: anker, duplikate: [ModelReference(duplikat)], context: context
        )

        #expect(ergebnis.umbauNeuErkannt == false)
        #expect(geschaeft.umbauVerdacht == false)
        #expect(duplikat.istAbgeschlossen)
    }

    // MARK: - schliesseAlleOffenenEinkaufsvorgaenge (Sync-(Wieder-)Beitritt)

    @Test
    func schliesseAlleOffenenEinkaufsvorgaengeSchliesstJedenUnabhaengigUndZaehltJedenAlsEigenenBesuch() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeftA = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        let geschaeftB = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        context.insert(geschaeftA)
        context.insert(geschaeftB)
        let listeEins = Einkaufsliste(name: "Wocheneinkauf")
        let listeZwei = Einkaufsliste(name: "Urlaub")
        context.insert(listeEins)
        context.insert(listeZwei)
        // Zwei völlig unabhängige, alte offene Vorgänge für unterschiedliche
        // Geschäft+Liste-Kombinationen — z.B. lokal entstanden, bevor das
        // Gerät (wieder) einer Sync-Gruppe beitritt.
        let ersterVorgang = Einkaufsvorgang(geschaeft: geschaeftA, einkaufsliste: listeEins)
        let zweiterVorgang = Einkaufsvorgang(geschaeft: geschaeftB, einkaufsliste: listeZwei)
        context.insert(ersterVorgang)
        context.insert(zweiterVorgang)

        let anzahl = EinkaufsvorgangAbschlussService.schliesseAlleOffenenEinkaufsvorgaenge(context: context)

        #expect(anzahl == 2)
        #expect(ersterVorgang.istAbgeschlossen)
        #expect(zweiterVorgang.istAbgeschlossen)
        #expect(geschaeftA.eigeneAnzahlEinkaufsvorgaenge == 1)
        #expect(geschaeftB.eigeneAnzahlEinkaufsvorgaenge == 1)
    }

    @Test
    func schliesseAlleOffenenEinkaufsvorgaengeLaesstBereitsAbgeschlosseneUnberuehrt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let bereitsAbgeschlossen = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(bereitsAbgeschlossen)
        let abschlusszeit = Date().addingTimeInterval(-1000)
        bereitsAbgeschlossen.abschliessen(am: abschlusszeit, zaehleAlsBesuch: false)

        let anzahl = EinkaufsvorgangAbschlussService.schliesseAlleOffenenEinkaufsvorgaenge(context: context)

        #expect(anzahl == 0)
        #expect(bereitsAbgeschlossen.endZeit == abschlusszeit)
        #expect(geschaeft.eigeneAnzahlEinkaufsvorgaenge == 0)
    }
}
