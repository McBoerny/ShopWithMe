import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct EinkaufsvorgangTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func lebensmittelTyp() -> GeschaeftTyp { GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill") }

    @Test
    func abhakenErstelltKaufEintragUndEntferntVonEinkaufsliste() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst], einheit: .stueck, mengenSchritt: 3)
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        // In der App löst `DatabaseLeaseService.performMicroLease` nach jeder
        // Mutation ein `save()` aus — erst danach spiegelt sich ein `context.delete()`
        // auch in Relationship-Arrays anderer Objekte (hier `liste.eintraege`) wider.
        try context.save()

        #expect(liste.enthaelt(apfel) == false)
        #expect(einkauf.kaufEintraege.count == 1)
        #expect(einkauf.kaufEintraege.first?.kategorie == obst)
        #expect(einkauf.kaufEintraege.first?.kategorieBesuchsIndex == 0)
        #expect(einkauf.kaufEintraege.first?.preis == nil)
        #expect(einkauf.kaufEintraege.first?.menge == 3)
    }

    @Test
    func gleicheKategorieTeiltSichDenBesuchsIndex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE")
        context.insert(obst)
        context.insert(drogerie)

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)

        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let shampoo = Artikel(name: "Shampoo", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie])
        context.insert(apfel)
        context.insert(birne)
        context.insert(shampoo)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbhaken(birne, context: context)
        einkauf.artikelAbhaken(shampoo, context: context)

        let apfelEintrag = einkauf.kaufEintraege.first { $0.artikel == apfel }
        let birneEintrag = einkauf.kaufEintraege.first { $0.artikel == birne }
        let shampooEintrag = einkauf.kaufEintraege.first { $0.artikel == shampoo }

        #expect(apfelEintrag?.kategorieBesuchsIndex == 0)
        #expect(birneEintrag?.kategorieBesuchsIndex == 0)
        #expect(shampooEintrag?.kategorieBesuchsIndex == 1)
    }

    @Test
    func unkategorisierterArtikelFaelltUnterSonstigesUndTeiltSichDenIndex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sonstiges = ArtikelKategorie(name: "Sonstiges", standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93")
        context.insert(sonstiges)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let ohneKategorie = Artikel(name: "Mysteriöses Ding", symbolName: "questionmark", farbeHex: "#8E8E93")
        let explizitSonstiges = Artikel(name: "Kerzen", symbolName: "flame.fill", farbeHex: "#8E8E93", kategorien: [sonstiges])
        context.insert(ohneKategorie)
        context.insert(explizitSonstiges)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(ohneKategorie, context: context)
        einkauf.artikelAbhaken(explizitSonstiges, context: context)

        let ohneKategorieEintrag = einkauf.kaufEintraege.first { $0.artikel == ohneKategorie }
        let sonstigesEintrag = einkauf.kaufEintraege.first { $0.artikel == explizitSonstiges }

        #expect(ohneKategorieEintrag?.kategorie == sonstiges)
        #expect(ohneKategorieEintrag?.kategorieBesuchsIndex == 0)
        #expect(sonstigesEintrag?.kategorieBesuchsIndex == 0)
        #expect(try context.fetchCount(FetchDescriptor<ArtikelKategorie>()) == 1)
    }

    @Test
    func abwaehlenMachtAbhakenRueckgaengig() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst], mengenSchritt: 2)
        context.insert(apfel)
        let listenEintrag = liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        listenEintrag.mengeErhoehen()
        listenEintrag.notiz = "Nur grüne"
        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbwaehlen(apfel, context: context)

        #expect(liste.enthaelt(apfel) == true)
        #expect(einkauf.kaufEintraege.isEmpty)
        // Menge/temporäre Notiz werden beim erneuten Auf-die-Liste-Setzen
        // zurückgesetzt, siehe `Einkaufsliste.artikelHinzufuegen(_:context:)`.
        let neuerEintrag = try #require(liste.eintrag(fuer: apfel))
        #expect(neuerEintrag.menge == apfel.mengenSchritt)
        #expect(neuerEintrag.notiz == nil)
    }

    /// Dedupe-Schutz gegen das in `docs/DATABASE_CONCURRENCY.md` dokumentierte
    /// Sync-Latenz-Restrisiko: ein zweiter Aufruf von `artikelAbhaken` für denselben
    /// Artikel im selben Einkaufsvorgang darf keinen zweiten `KaufEintrag` anlegen.
    @Test
    func abhakenErstelltBeiWiederholtemAufrufKeinDuplikat() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)
        try context.save()
        einkauf.artikelAbhaken(apfel, context: context)
        try context.save()

        #expect(einkauf.kaufEintraege.count == 1)
        #expect(liste.enthaelt(apfel) == false)
    }

    /// Regressionstest für den Live-Test-Fund (Nachtrag Session 2026-08-03,
    /// „in unterschiedlichen Läden eingekauft, Artikel kann nicht wieder
    /// aktiviert werden"): der Dedupe-Schutz griff bisher nur PRO VORGANG —
    /// derselbe Artikel konnte unter zwei unterschiedlichen, beide offenen
    /// Vorgängen (hier: zwei Geschäften) unabhängig voneinander abgehakt
    /// werden. Seit die Anzeige listenweit gilt, muss auch der Dedupe-Schutz
    /// listenweit über alle offenen Vorgänge prüfen — sonst entstehen zwei
    /// `KaufEintrag`e, von denen ein einzelnes „Abwählen" nur einen entfernt.
    @Test
    func abhakenInZweitemOffenemVorgangDerselbenListeErzeugtKeinDuplikat() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let edeka = Geschaeft(name: "Edeka", typen: [lebensmittelTyp()])
        context.insert(edeka)
        let rewe = Geschaeft(name: "Rewe", typen: [lebensmittelTyp()])
        context.insert(rewe)
        let milch = Artikel(name: "H-Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(milch)
        liste.artikelHinzufuegen(milch, context: context)

        let einkaufEdeka = Einkaufsvorgang(geschaeft: edeka, einkaufsliste: liste)
        context.insert(einkaufEdeka)
        let einkaufRewe = Einkaufsvorgang(geschaeft: rewe, einkaufsliste: liste)
        context.insert(einkaufRewe)

        let ersteAbhakung = einkaufEdeka.artikelAbhaken(milch, context: context)
        try context.save()
        let zweiteAbhakung = einkaufRewe.artikelAbhaken(milch, context: context)
        try context.save()

        #expect(ersteAbhakung == .abgehakt)
        #expect(zweiteAbhakung == .bereitsAbgehaktVon(geraeteID: nil))
        #expect(einkaufEdeka.kaufEintraege.count == 1)
        #expect(einkaufRewe.kaufEintraege.isEmpty)
        #expect(liste.enthaelt(milch) == false)

        // Ein einzelnes Abwählen (auf welchem der beiden Vorgänge auch immer
        // aufgerufen, hier bewusst über den tatsächlichen Besitzer) muss den
        // Artikel vollständig zurücksetzen.
        einkaufEdeka.artikelAbwaehlen(milch, context: context)
        #expect(einkaufEdeka.kaufEintraege.isEmpty)
        #expect(liste.enthaelt(milch))
    }

    @Test
    func artikelAbhakenLiefertAbgehaktBeimErstenUndBereitsAbgehaktVonBeimZweitenAufruf() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        let erstesErgebnis = einkauf.artikelAbhaken(apfel, context: context)
        try context.save()
        let zweitesErgebnis = einkauf.artikelAbhaken(apfel, context: context)

        #expect(erstesErgebnis == .abgehakt)
        guard case .bereitsAbgehaktVon(let geraeteID) = zweitesErgebnis else {
            Issue.record("Erwartete .bereitsAbgehaktVon, bekam \(zweitesErgebnis)")
            return
        }
        #expect(geraeteID == DatabaseLeaseService.geraeteID)
    }

    /// Ein per Sync-Import materialisiertes Abhaken (siehe
    /// `SyncImportService.materialisiere`) beschreibt die Laufreihenfolge des
    /// SENDENDEN Geräts, nicht die dieses Geräts — es darf deshalb keinen
    /// ``KaufEintrag/kategorieBesuchsIndex`` bekommen, sonst würde
    /// ``AbteilungsDistanzService`` mit einer erfundenen Besuchsposition für
    /// diesen Nutzer gefüttert (siehe Typ-Doku
    /// ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:indexFuerDistanzlernen:)``).
    @Test
    func syncMaterialisiertesAbhakenBekommtKeinenBesuchsindex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(apfel)
        liste.artikelHinzufuegen(apfel, context: context)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context, indexFuerDistanzlernen: false)
        // Siehe `abhakenErstelltKaufEintragUndEntferntVonEinkaufsliste`: ein
        // `context.delete()` spiegelt sich in `liste.eintraege` erst nach `save()`.
        try context.save()

        #expect(einkauf.kaufEintraege.first?.kategorieBesuchsIndex == nil)
        #expect(einkauf.kaufEintraege.first?.kategorie == obst)
        #expect(liste.enthaelt(apfel) == false)
    }

    /// GitHub #48: Ein von einem Peer per Bereich-A-Import empfangenes
    /// "abgehakt"-Event (siehe `SyncImportServiceTests`) muss beim eigenen
    /// `artikelAbhaken`-Aufruf als `.bereitsAbgehaktVon` mit der Geräte-ID des
    /// ursprünglichen Peers erkannt werden, nicht als neue eigene Aktion.
    @Test
    func artikelAbhakenErkenntFremdesGeraetAlsUrsprungNachBereichAImport() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)

        // Simuliert ein bereits importiertes Fremd-Event (siehe
        // SyncEventService.uebernehmen) statt den echten Dateisystem-Import
        // aufzurufen — der Kern hier ist SyncEventService.aktuellerGewinner.
        let empfangenesEvent = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgehakt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "fremdes-geraet", autorGeraeteID: "fremdes-geraet", wallClock: Date()
        )
        SyncEventService.uebernehmen(empfangenesEvent, context: context)
        // Das eigentliche Abhaken (KaufEintrag) übernimmt der Import separat —
        // hier direkt nachgebildet, um den Fokus auf aktuellerGewinner zu halten.
        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        try context.save()

        let ergebnis = einkauf.artikelAbhaken(apfel, context: context)

        guard case .bereitsAbgehaktVon(let geraeteID) = ergebnis else {
            Issue.record("Erwartete .bereitsAbgehaktVon, bekam \(ergebnis)")
            return
        }
        #expect(geraeteID == "fremdes-geraet")
    }

    /// GitHub-Nachfolgefund zu #36: ``EinkaufenView`` zeigt einen Artikel mit
    /// mehreren Kategorien jetzt gleichzeitig in allen zugehörigen Abschnitten
    /// an (statt nur in einer "führenden") und übergibt beim Abhaken die
    /// tatsächlich getappte Kategorie — Grundlage dafür, dass
    /// ``AbteilungsDistanzService`` pro Geschäft lernen kann, in welcher der
    /// mehreren Kategorien ein Artikel dort tatsächlich steht (z.B. Sojasauce
    /// bei Edeka unter "Soßen", bei Aldi unter "Asia"), statt einer für den
    /// Artikel global geratenen.
    @Test
    func explizitUebergebeneKategorieUeberschreibtFuehrendeKategorie() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let sossen = ArtikelKategorie(name: "Soßen", standardSymbol: "drop.fill", standardFarbeHex: "#FF9500")
        let asia = ArtikelKategorie(name: "Asia", standardSymbol: "fork.knife", standardFarbeHex: "#FF3B30")
        context.insert(sossen)
        context.insert(asia)
        let geschaeft = Geschaeft(name: "Aldi", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let sojasauce = Artikel(
            name: "Sojasauce", symbolName: "drop.fill", farbeHex: "#FF9500", kategorien: [sossen, asia]
        )
        context.insert(sojasauce)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        // Getappt aus dem "Asia"-Abschnitt, nicht aus dem (ggf. "führenden")
        // "Soßen"-Abschnitt.
        einkauf.artikelAbhaken(sojasauce, context: context, kategorie: asia)

        #expect(einkauf.kaufEintraege.first?.kategorie == asia)
    }

    /// Ohne explizite Kategorie (Belegscan, Preisschild-Scan, Sync-Import) bleibt
    /// das bisherige Verhalten über ``Artikel/fuehrendeKategorie(inGeschaeft:context:)``
    /// erhalten.
    @Test
    func ohneExpliziteKategorieWirdWeiterhinDieFuehrendeVerwendet() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(apfel)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        einkauf.artikelAbhaken(apfel, context: context)

        #expect(einkauf.kaufEintraege.first?.kategorie == obst)
    }

    /// Regressionstest für die Ursache des "Anzeige springt hin und her"-Bugs:
    /// ``Artikel/kategorien`` ist eine ungeordnete SwiftData-Relationship, deren
    /// Enumerationsreihenfolge sich zwischen Fetches/Sync-Merges ändern kann.
    /// ``Artikel/fuehrendeKategorie(inGeschaeft:context:)`` muss deshalb
    /// unabhängig von der Initialisierungs-/Zuweisungsreihenfolge immer
    /// dieselbe Kategorie liefern (hier: niedrigerer ``ArtikelKategorie/sortIndex``
    /// gewinnt).
    @Test
    func fuehrendeKategorieIstUnabhaengigVonDerZuweisungsreihenfolge() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let drogerie = ArtikelKategorie(name: "Drogerie", standardSymbol: "sparkles", standardFarbeHex: "#AF52DE", sortIndex: 0)
        let reise = ArtikelKategorie(name: "Reisebedarf", standardSymbol: "airplane", standardFarbeHex: "#5AC8FA", sortIndex: 1)
        context.insert(drogerie)
        context.insert(reise)

        let ohropaxA = Artikel(name: "Ohropax A", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [drogerie, reise])
        let ohropaxB = Artikel(name: "Ohropax B", symbolName: "sparkles", farbeHex: "#AF52DE", kategorien: [reise, drogerie])
        context.insert(ohropaxA)
        context.insert(ohropaxB)

        #expect(ohropaxA.fuehrendeKategorie(inGeschaeft: nil, context: context) == drogerie)
        #expect(ohropaxB.fuehrendeKategorie(inGeschaeft: nil, context: context) == drogerie)
    }

    /// Regressionstest (Code-Review-Fund): eine remote materialisierte
    /// `KaufEintrag` ohne Index (`indexFuerDistanzlernen: false`, siehe
    /// `SyncImportService`) darf `naechsterKategorieBesuchsIndex` nicht dazu
    /// verleiten, für eine Kategorie, die bereits einen echten Index hat,
    /// einen zweiten (Duplikat-)Index zu vergeben — sonst zerfällt eine
    /// Abteilung in der ``AbteilungsDistanzService``-Distanzmatrix in zwei
    /// Besuchs-Slots. Der ohne-Index-Eintrag wird bewusst ZUERST angelegt,
    /// damit ein naives `kaufEintraege.first(where:)` (ungeordnete
    /// SwiftData-Relationship, folgt vor jedem Save/Fetch typischerweise der
    /// Einfüge-Reihenfolge) ihn zuerst träfe, wäre der Nil-Filter nicht da.
    @Test
    func naechsterKategorieBesuchsIndexIgnoriertEintraegeOhneIndex() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let obst = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        context.insert(obst)
        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        let kirsche = Artikel(name: "Kirsche", symbolName: "carrot.fill", farbeHex: "#34C759", kategorien: [obst])
        context.insert(birne)
        context.insert(apfel)
        context.insert(kirsche)

        let einkauf = Einkaufsvorgang(geschaeft: geschaeft)
        context.insert(einkauf)

        // Reihenfolge ist Teil der Regression: Birne zuerst (kein Index), dann
        // Apfel (bekommt den ersten echten Index, 0), dann Kirsche — muss
        // ebenfalls 0 bekommen (dieselbe Kategorie), nicht fälschlich 1.
        einkauf.artikelAbhakenOhneEventAufzeichnung(birne, context: context, indexFuerDistanzlernen: false)
        einkauf.artikelAbhaken(apfel, context: context)
        einkauf.artikelAbhaken(kirsche, context: context)

        let apfelEintrag = einkauf.kaufEintraege.first { $0.artikel == apfel }
        let kirscheEintrag = einkauf.kaufEintraege.first { $0.artikel == kirsche }
        #expect(apfelEintrag?.kategorieBesuchsIndex == 0)
        #expect(kirscheEintrag?.kategorieBesuchsIndex == 0)
    }

    /// GitHub #67-Erweiterung: Zwei gleichzeitig offene Vorgänge für dieselbe
    /// (Geschäft, Liste)-Kombination (Race zweier Geräte vor dem ersten
    /// Sync-Zyklus) müssen von jedem Gerät auf denselben kanonischen Vorgang
    /// aufgelöst werden — unabhängig von der Reihenfolge, in der sie
    /// übergeben werden (unterschiedliche lokale Fetch-Reihenfolgen auf
    /// unterschiedlichen Geräten dürfen zu keinem unterschiedlichen Ergebnis
    /// führen). Der ältere ``Einkaufsvorgang/startZeit`` gewinnt.
    @Test
    func kanonischerWaehltImmerDenAeltestenUnabhaengigVonDerReihenfolge() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)

        let neuer = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste, startZeit: Date())
        let aelterer = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste, startZeit: Date(timeIntervalSinceNow: -60))
        context.insert(neuer)
        context.insert(aelterer)

        #expect(Einkaufsvorgang.kanonischer(unter: [neuer, aelterer])?.id == aelterer.id)
        #expect(Einkaufsvorgang.kanonischer(unter: [aelterer, neuer])?.id == aelterer.id)
    }

    /// Bei exaktem Gleichstand der ``Einkaufsvorgang/startZeit`` (praktisch nur
    /// bei einem echten Zeitgleichheits-Rennen zweier Geräte) muss die Wahl
    /// trotzdem für alle Geräte identisch ausfallen — die `id` als stabiler
    /// Tiebreaker leistet das, ein zufälliger `.first`-Treffer nicht.
    @Test
    func kanonischerEntscheidetBeiGleicherStartZeitUeberDieId() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)

        let zeitpunkt = Date()
        let a = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste, startZeit: zeitpunkt)
        let b = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste, startZeit: zeitpunkt)
        context.insert(a)
        context.insert(b)

        let erwarteterGewinner = a.id.uuidString < b.id.uuidString ? a : b
        #expect(Einkaufsvorgang.kanonischer(unter: [a, b])?.id == erwarteterGewinner.id)
        #expect(Einkaufsvorgang.kanonischer(unter: [b, a])?.id == erwarteterGewinner.id)
    }

    /// Regressionstest für den Live-Test-Fund (Nachtrag Session 2026-08-03):
    /// ein Kaufeintrag zählt als „gerade abgehakt" GENAU DANN, wenn sein
    /// Container-Vorgang noch nicht abgeschlossen ist (`endZeit == nil`) —
    /// unabhängig davon, WANN er abgehakt wurde. Die vorherige, zeitfenster-
    /// basierte Fassung koppelte die Sichtbarkeit fälschlich an die lokale
    /// Vorgangs-Historie des BETRACHTENDEN Geräts statt an den tatsächlichen
    /// Zustand des Vorgangs — ein bereits abgeschlossener Kauf blieb dadurch
    /// je nach Gerät/Ansicht inkonsistent sichtbar oder unsichtbar. Einträge
    /// anderer Listen werden unabhängig vom Vorgangs-Status ausgeschlossen.
    @Test
    func abgehakteKaufEintraegeZaehltNurOffeneVorgaenge() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Testladen", typen: [lebensmittelTyp()])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let andereListe = Einkaufsliste(name: "Andere Liste")
        context.insert(andereListe)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        let birne = Artikel(name: "Birne", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(birne)
        let kirsche = Artikel(name: "Kirsche", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(kirsche)

        let offenerVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(offenerVorgang)
        _ = offenerVorgang.artikelAbhakenOhneEventAufzeichnung(apfel, context: context, indexFuerDistanzlernen: false)

        // Bereits abgeschlossener Vorgang derselben Liste — der Kaufeintrag
        // bleibt als Historie bestehen, zählt aber nicht mehr als „gerade
        // abgehakt" (unabhängig davon, dass der Abschluss erst gerade eben
        // erfolgte).
        let geschlossenerVorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(geschlossenerVorgang)
        _ = geschlossenerVorgang.artikelAbhakenOhneEventAufzeichnung(birne, context: context, indexFuerDistanzlernen: false)
        geschlossenerVorgang.abschliessen()

        // Offener Vorgang einer ANDEREN Liste — trotz offenem Status nicht
        // mitgezählt.
        let vorgangAndereListe = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: andereListe)
        context.insert(vorgangAndereListe)
        _ = vorgangAndereListe.artikelAbhakenOhneEventAufzeichnung(kirsche, context: context, indexFuerDistanzlernen: false)

        try context.save()

        let ergebnis = Einkaufsvorgang.abgehakteKaufEintraege(
            fuerListe: liste, unter: [offenerVorgang, geschlossenerVorgang, vorgangAndereListe]
        )

        #expect(ergebnis.contains { $0.artikel == apfel })
        #expect(!ergebnis.contains { $0.artikel == birne })
        #expect(!ergebnis.contains { $0.artikel == kirsche })
    }
}
