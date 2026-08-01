import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

@MainActor
struct PreispunktVerdichtungServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self,
            Preispunkt.self, ArtikelAlias.self, SyncTombstone.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func artikelUndGeschaeft(_ context: ModelContext) -> (Artikel, Geschaeft) {
        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Rewe", typen: [typ])
        context.insert(geschaeft)
        let artikel = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#34C759")
        context.insert(artikel)
        return (artikel, geschaeft)
    }

    @Test
    func taeglicheVerdichtungBehaeltNurDenJuengstenVergangenerTage() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()
        // Bewusst relativ zum Start des Vortags verankert (nicht relativ zu `jetzt`
        // selbst) — sonst könnte je nach Tageszeit des Testlaufs einer der drei
        // Zeitpunkte über Mitternacht auf einen anderen Kalendertag rutschen.
        let startVortag = Calendar.current.startOfDay(for: jetzt.addingTimeInterval(-1 * 86400))

        let morgens = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.19, datum: startVortag.addingTimeInterval(3600 * 8))
        let mittags = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.29, datum: startVortag.addingTimeInterval(3600 * 12))
        let abends = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.09, datum: startVortag.addingTimeInterval(3600 * 18))
        context.insert(morgens)
        context.insert(mittags)
        context.insert(abends)
        try context.save()

        let anzahl = await PreispunktVerdichtungService.verdichten(
            context: context, jetzt: jetzt, maxProTag: 1, tageBisWoche: 30, tageBisMonat: 400
        )

        #expect(anzahl == 2)
        let verbleibende = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == abends.id)
        #expect(verbleibende.first?.preis == 1.09)
    }

    @Test
    func taeglicheVerdichtungLaesstHeutigenTagUnangetastet() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()
        // Relativ zum Start des heutigen Tages verankert (nicht relativ zu `jetzt`
        // selbst) — sonst könnte je nach Tageszeit des Testlaufs ein Punkt
        // fälschlich auf den Vortag rutschen.
        let heute = Calendar.current.startOfDay(for: jetzt)

        let morgens = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.19, datum: heute.addingTimeInterval(3600 * 4))
        let mittags = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.29, datum: heute.addingTimeInterval(3600 * 8))
        context.insert(morgens)
        context.insert(mittags)
        try context.save()

        let anzahl = await PreispunktVerdichtungService.verdichten(
            context: context, jetzt: jetzt, maxProTag: 1, tageBisWoche: 7, tageBisMonat: 365
        )

        #expect(anzahl == 0)
        #expect(try context.fetch(FetchDescriptor<Preispunkt>()).count == 2)
    }

    @Test
    func wochenverdichtungBehaeltHoechstenPreisMitEchtemDatum() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()
        // Beide Punkte in derselben Kalenderwoche, älter als die 7-Tage-Frist,
        // aber an unterschiedlichen Tagen (sonst würde bereits Stufe 1 greifen).
        let montag = jetzt.addingTimeInterval(-10 * 86400)
        let mittwoch = jetzt.addingTimeInterval(-8 * 86400)

        let niedriger = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.19, datum: montag)
        let hoeher = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.49, datum: mittwoch)
        context.insert(niedriger)
        context.insert(hoeher)
        try context.save()

        // Sicherstellen, dass beide tatsächlich in derselben ISO-Kalenderwoche liegen.
        let kalender = Calendar.current
        try #require(
            kalender.component(.weekOfYear, from: montag) == kalender.component(.weekOfYear, from: mittwoch)
                && kalender.component(.yearForWeekOfYear, from: montag) == kalender.component(.yearForWeekOfYear, from: mittwoch)
        )

        let anzahl = await PreispunktVerdichtungService.verdichten(
            context: context, jetzt: jetzt, maxProTag: 1, tageBisWoche: 7, tageBisMonat: 400
        )

        #expect(anzahl == 1)
        let verbleibende = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == hoeher.id)
        #expect(verbleibende.first?.datum == mittwoch)
    }

    @Test
    func monatsverdichtungReduziertBereitsWochenverdichtetePunkte() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()
        let kalender = Calendar.current

        // Zwei Punkte im selben Kalendermonat, aber unterschiedlichen Kalenderwochen,
        // beide älter als die Monats-Frist.
        var komponenten = kalender.dateComponents([.year, .month], from: jetzt.addingTimeInterval(-400 * 86400))
        komponenten.day = 3
        let anfangDesMonats = kalender.date(from: komponenten)!
        komponenten.day = 20
        let spaeterImMonat = kalender.date(from: komponenten)!
        try #require(
            kalender.component(.month, from: anfangDesMonats) == kalender.component(.month, from: spaeterImMonat)
        )

        let niedriger = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.19, datum: anfangDesMonats)
        let hoeher = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.59, datum: spaeterImMonat)
        context.insert(niedriger)
        context.insert(hoeher)
        try context.save()

        let anzahl = await PreispunktVerdichtungService.verdichten(
            context: context, jetzt: jetzt, maxProTag: 1, tageBisWoche: 7, tageBisMonat: 365
        )

        #expect(anzahl == 1)
        let verbleibende = try context.fetch(FetchDescriptor<Preispunkt>())
        #expect(verbleibende.count == 1)
        #expect(verbleibende.first?.id == hoeher.id)
    }

    @Test
    func verdichtenHinterlaesstTombstoneFuerGeloeschtePunkte() async throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let (artikel, geschaeft) = artikelUndGeschaeft(context)
        let jetzt = Date()
        // Relativ zum Start des Vortags verankert, siehe Begründung in
        // ``taeglicheVerdichtungBehaeltNurDenJuengstenVergangenerTage``.
        let startVortag = Calendar.current.startOfDay(for: jetzt.addingTimeInterval(-1 * 86400))

        let aelter = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.19, datum: startVortag.addingTimeInterval(3600 * 8))
        let juenger = Preispunkt(artikel: artikel, geschaeft: geschaeft, preis: 1.29, datum: startVortag.addingTimeInterval(3600 * 12))
        context.insert(aelter)
        context.insert(juenger)
        let aelterID = aelter.id
        try context.save()

        await PreispunktVerdichtungService.verdichten(
            context: context, jetzt: jetzt, maxProTag: 1, tageBisWoche: 30, tageBisMonat: 400
        )

        #expect(SyncTombstoneService.istGeloescht(art: SyncEntitaetsArt.preispunkt, id: aelterID, context: context))
    }

    @Test
    func persistierteSchwellwerteHabenSinnvolleStandardwerte() {
        // `UserDefaults`-Fallback greift nur, wenn nie ein Wert gesetzt wurde —
        // hier nur die reinen Default-Konstanten geprüft, ohne den (prozessweit
        // geteilten) UserDefaults-Zustand für andere Tests zu verändern.
        #expect(PreispunktVerdichtungService.maxPunkteProTag >= 1)
        #expect(PreispunktVerdichtungService.tageBisWochenVerdichtung >= 1)
        #expect(PreispunktVerdichtungService.tageBisMonatsVerdichtung >= 1)
    }
}
