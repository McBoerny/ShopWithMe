import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für ``DatenintegritaetsService`` (Erkennung baumelnder Referenzen,
/// GitHub-Absturzmeldung zu `Geschaeft/p9`).
///
/// **Bewusst rein lesend, keine Reparatur mehr:** Ein früherer Versuch, eine
/// erkannte baumelnde Referenz per Setter zu nullen (`eintrag.artikel = nil`),
/// verursachte selbst einen Absturz (`Artikel/p19`, Crash-Log
/// `ShopWithMe-2026-07-30-000333.ips`) — SwiftDatas Setter für eine Beziehung
/// mit `inverse:`-Deklaration muss beim Nullen die alte Gegenseite auffalten,
/// um sich selbst aus deren inversem Array zu entfernen; ist genau diese alte
/// Gegenseite bereits baumelnd, stürzt exakt dort derselbe Fatal Error, den die
/// Reparatur beheben sollte. Siehe Typ-Dokumentation von
/// ``DatenintegritaetsService`` für die vollständige Erklärung.
///
/// **Bewusst auch kein Test, der eine echte "baumelnde" Referenz nachstellt:**
/// Seit den `@Relationship(inverse:)`-Deklarationen auf allen hier relevanten
/// Beziehungen sorgt SwiftData bei jedem `context.delete()` selbst dafür, dass
/// abhängige Referenzen genullt oder kaskadiert werden — sie lassen sich mit
/// dem aktuellen Modell grundsätzlich nicht mehr über eine normale
/// Programmoperation künstlich erzeugen, sie betreffen ausschließlich Daten von
/// vor Einführung dieser `inverse`-Deklarationen. Verifiziert wird hier daher
/// nur, dass ``DatenintegritaetsService/pruefe(context:)`` auf sauberen Daten
/// nichts fälschlich meldet und nichts verändert.
@MainActor
struct DatenintegritaetsServiceTests {
    private let schema = Schema([
        Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
        Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self,
        Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
        SyncEvent.self, ArtikelGeschaeftVerfuegbarkeit.self, GeschaeftBesuch.self,
    ])

    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    @Test
    func pruefungAufVollstaendigIntaktenDatenMeldetNichts() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Milch", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let kaufEintrag = KaufEintrag(artikel: artikel, geschaeft: geschaeft)
        context.insert(kaufEintrag)
        try context.save()

        let befunde = DatenintegritaetsService.pruefe(context: context)

        #expect(befunde.isEmpty)
        #expect(kaufEintrag.artikel === artikel)
        #expect(kaufEintrag.geschaeft === geschaeft)
        #expect(DatenintegritaetsService.letzterBericht.isEmpty)
    }

    @Test
    func pruefungVeraendertVollstaendigVerknuepfteWarengruppenDistanzNicht() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let kategorieA = ArtikelKategorie(name: "Obst", standardSymbol: "carrot.fill", standardFarbeHex: "#34C759")
        let kategorieB = ArtikelKategorie(name: "Gemüse", standardSymbol: "leaf.fill", standardFarbeHex: "#34C759")
        context.insert(kategorieA)
        context.insert(kategorieB)
        let distanz = WarengruppenDistanz(geschaeft: nil, kategorieA: kategorieA, kategorieB: kategorieB, distanz: 3)
        context.insert(distanz)
        try context.save()

        let befunde = DatenintegritaetsService.pruefe(context: context)

        #expect(befunde.isEmpty)
        #expect((try? context.fetchCount(FetchDescriptor<WarengruppenDistanz>())) == 1)
    }

    /// Regressionstest für einen Live-Test-Nachfolgefund (Abschnitt 20/21):
    /// ein ``Einkaufsvorgang`` ohne Einkaufsliste ist kein Absturzrisiko
    /// (``istBaumelnd`` erfasst ihn deshalb nicht, `nil` ist für SwiftData
    /// gültig), aber für die App komplett unerreichbar — eine eigene
    /// Fehlerkategorie, die ``pruefe(context:)`` jetzt zusätzlich als EINE
    /// aggregierte Zeile meldet, inklusive der Anzahl real angehängter Käufe.
    @Test
    func einkaufsvorgangOhneListeWirdAlsUnerreichbarGemeldetMitKaufAnzahl() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        DatenintegritaetsService.wachstumsUeberwachungZuruecksetzen()

        let artikel = Artikel(name: "Bananen", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let listenloserVorgangMitKauf = Einkaufsvorgang(geschaeft: nil, einkaufsliste: nil)
        context.insert(listenloserVorgangMitKauf)
        let kauf = KaufEintrag(artikel: artikel, geschaeft: nil)
        kauf.einkaufsvorgang = listenloserVorgangMitKauf
        context.insert(kauf)
        let listenloserVorgangLeer = Einkaufsvorgang(geschaeft: nil, einkaufsliste: nil)
        context.insert(listenloserVorgangLeer)
        try context.save()

        let befunde = DatenintegritaetsService.pruefe(context: context)

        #expect(befunde.count == 1)
        let beschreibung = try #require(befunde.first?.beschreibung)
        #expect(beschreibung.contains("2 Einkaufsvorgänge ohne Einkaufsliste"))
        #expect(beschreibung.contains("1 davon mit insgesamt 1 angehängten Käufen"))
    }

    /// Regressionstest für die automatische Bereinigung (Abschnitt 22): leere
    /// listenlose Vorgänge werden gelöscht, ein listenloser Vorgang MIT
    /// angehängtem Kauf bleibt erhalten (Cascade-Löschung würde den echten
    /// Kauf sonst mitlöschen) und wird stattdessen weiterhin von
    /// ``pruefe(context:)`` gemeldet. Ein Vorgang MIT Liste bleibt so oder so
    /// unangetastet.
    @Test
    func raeumtNurLeereListenloseVorgaengeAufUndBehaeltSolcheMitKaeufen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let liste = Einkaufsliste(name: "Urlaub")
        context.insert(liste)
        let vorgangMitListe = Einkaufsvorgang(geschaeft: nil, einkaufsliste: liste)
        context.insert(vorgangMitListe)

        let artikel = Artikel(name: "Bananen", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let listenloserMitKauf = Einkaufsvorgang(geschaeft: nil, einkaufsliste: nil)
        context.insert(listenloserMitKauf)
        let kauf = KaufEintrag(artikel: artikel, geschaeft: nil)
        kauf.einkaufsvorgang = listenloserMitKauf
        context.insert(kauf)

        let listenloserLeer = Einkaufsvorgang(geschaeft: nil, einkaufsliste: nil)
        context.insert(listenloserLeer)
        try context.save()

        let anzahlBereinigt = DatenintegritaetsService.raeumeLeereListenloseVorgaengeAuf(context: context)

        #expect(anzahlBereinigt == 1)
        let verbleibende = try context.fetch(FetchDescriptor<Einkaufsvorgang>())
        #expect(verbleibende.count == 2)
        #expect(verbleibende.contains { $0.id == vorgangMitListe.id })
        #expect(verbleibende.contains { $0.id == listenloserMitKauf.id })
        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 1)
    }

    /// Regressionstest für dieselbe Live-Test-Session: eine reine
    /// Bestandszahl verrät nicht, ob sie langsam über Wochen getröpfelt ist
    /// oder gerade akut wächst (beobachtet: 875 an einem einzigen Tag) — ein
    /// Zuwachs über ``DatenintegritaetsService/warnschwelleSchnellesWachstum``
    /// seit der letzten Prüfung muss deshalb zusätzlich als Warnung markiert
    /// werden.
    @Test
    func schnellesWachstumListenloserVorgaengeWirdAlsWarnungMarkiert() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        DatenintegritaetsService.wachstumsUeberwachungZuruecksetzen()
        let vorherigeSchwelle = DatenintegritaetsService.warnschwelleSchnellesWachstum
        DatenintegritaetsService.warnschwelleSchnellesWachstum = 3
        defer { DatenintegritaetsService.warnschwelleSchnellesWachstum = vorherigeSchwelle }

        func fuegeListenloseVorgaengeHinzu(_ anzahl: Int) {
            for _ in 0..<anzahl {
                context.insert(Einkaufsvorgang(geschaeft: nil, einkaufsliste: nil))
            }
            try? context.save()
        }

        // Erste Prüfung: 2 (unter der Schwelle) — noch keine Warnung, nur die
        // Basis-Zeile, merkt sich aber die Anzahl für den nächsten Vergleich.
        fuegeListenloseVorgaengeHinzu(2)
        let ersterBefund = try #require(DatenintegritaetsService.pruefe(context: context).first)
        #expect(!ersterBefund.beschreibung.contains("⚠️"))

        // Zweite Prüfung: 5 weitere (Zuwachs 5 ≥ Schwelle 3) — jetzt mit Warnung.
        fuegeListenloseVorgaengeHinzu(5)
        let zweiterBefund = try #require(DatenintegritaetsService.pruefe(context: context).first)
        #expect(zweiterBefund.beschreibung.contains("7 Einkaufsvorgänge ohne Einkaufsliste"))
        #expect(zweiterBefund.beschreibung.contains("⚠️ +5"))
    }

    /// Regressionstest für `docs/GESCHAEFTS_AGGREGATE.md`: ein listenloser
    /// Vorgang MIT Kauf wird jetzt (anders als
    /// ``raeumtNurLeereListenloseVorgaengeAufUndBehaeltSolcheMitKaeufen``)
    /// endgültig gelöscht — aber erst, nachdem Artikel-Verfügbarkeit und
    /// Besuchsprotokoll-Eintrag als dauerhafte Aggregate gesichert wurden.
    @Test
    func migriertBestandVorLoeschungListenloserVorgaengeMitKaeufen() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Bananen", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)

        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: nil, startZeit: Date().addingTimeInterval(-600))
        context.insert(vorgang)
        vorgang.endZeit = Date()
        let kauf = KaufEintrag(artikel: artikel, geschaeft: geschaeft)
        kauf.einkaufsvorgang = vorgang
        context.insert(kauf)
        try context.save()

        DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context: context)

        #expect(ArtikelVerfuegbarkeitService.wurdeBereitsGekauft(artikel, in: geschaeft, context: context))
        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Einkaufsvorgang>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<KaufEintrag>()) == 0)
    }

    /// Idempotenz analog ``KaufEintrag/preisverlaufMigrierenFallsNoetig(context:)``:
    /// ein zweiter Aufruf auf bereits migrierten/leeren Daten verändert nichts
    /// und stürzt nicht ab.
    @Test
    func migrationIstIdempotent() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container

        let geschaeft = Geschaeft(name: "Rewe", typen: [])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Bananen", symbolName: "cart", farbeHex: "#000000")
        context.insert(artikel)
        let vorgang = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: nil)
        context.insert(vorgang)
        vorgang.endZeit = Date()
        try context.save()

        DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context: context)
        DatenintegritaetsService.migriereGeschaeftsAggregateFallsNoetig(context: context)

        #expect(try context.fetchCount(FetchDescriptor<GeschaeftBesuch>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Einkaufsvorgang>()) == 0)
    }
}
