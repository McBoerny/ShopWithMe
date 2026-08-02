import Foundation
import Testing
@testable import ShopWithMe

/// Tests für ``WiederholungsFilter`` (siehe `docs/LOGGING.md` — Live-Fund:
/// ein einziger anhaltender `sync_ordner_zugriff_fehlgeschlagen`-Zustand
/// erzeugte binnen 27 Minuten 1065 identische Protokollzeilen).
struct WiederholungsFilterTests {
    @Test
    func ersteMeldungWirdImmerDurchgelassen() {
        let filter = WiederholungsFilter()

        let ergebnis = filter.pruefe(ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots")

        #expect(ergebnis == "importiereSnapshots")
    }

    @Test
    func exakteWiederholungInnerhalbDesIntervallsWirdUnterdrueckt() {
        let filter = WiederholungsFilter(lebenszeichenIntervall: 60)
        let start = Date()
        _ = filter.pruefe(ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots", jetzt: start)

        let ergebnis = filter.pruefe(
            ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots",
            jetzt: start.addingTimeInterval(5)
        )

        #expect(ergebnis == nil)
    }

    @Test
    func exakteWiederholungNachIntervallErzeugtLebenszeichen() {
        let filter = WiederholungsFilter(lebenszeichenIntervall: 60)
        let start = Date()
        _ = filter.pruefe(ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots", jetzt: start)
        // Zwei unterdrückte Wiederholungen dazwischen.
        _ = filter.pruefe(
            ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots",
            jetzt: start.addingTimeInterval(10)
        )
        _ = filter.pruefe(
            ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots",
            jetzt: start.addingTimeInterval(20)
        )

        let ergebnis = filter.pruefe(
            ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots",
            jetzt: start.addingTimeInterval(65)
        )

        #expect(ergebnis != nil)
        #expect(ergebnis?.contains("importiereSnapshots") == true)
        #expect(ergebnis?.contains("2 weitere unterdrückt") == true)
    }

    @Test
    func geaenderterInhaltWirdSofortWiederDurchgelassen() {
        let filter = WiederholungsFilter(lebenszeichenIntervall: 60)
        let start = Date()
        _ = filter.pruefe(ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "importiereSnapshots", jetzt: start)

        // Fehler behoben, nächster Zyklus erfolgreich -> anderes Ereignis,
        // kein Unterdrücken-Kandidat mehr für diesen Schlüssel.
        let ergebnis = filter.pruefe(
            ereignis: "sync_ordner_zugriff_fehlgeschlagen", details: "exportierePaket",
            jetzt: start.addingTimeInterval(5)
        )

        #expect(ergebnis == "exportierePaket")
    }

    @Test
    func unterschiedlicheTeilbereicheDesselbenEreignisWerdenGetrenntVerfolgt() {
        // Wie sync_snapshot_unveraendert_uebersprungen: 6 Aufrufe pro Zyklus
        // mit demselben Ereignistyp, aber unterschiedlichem Teilbereich als
        // erstem Wort — dürfen sich nicht gegenseitig als "geändert" auslösen.
        let filter = WiederholungsFilter(lebenszeichenIntervall: 60)
        let start = Date()
        _ = filter.pruefe(ereignis: "sync_snapshot_unveraendert_uebersprungen", details: "tombstones fingerabdruck=aaa", jetzt: start)
        _ = filter.pruefe(ereignis: "sync_snapshot_unveraendert_uebersprungen", details: "stamm fingerabdruck=bbb", jetzt: start)

        // Zweiter Zyklus, dieselben Fingerabdrücke -> beide weiterhin exakt
        // dieselbe Wiederholung wie beim jeweils letzten Mal, sollten also
        // unterdrückt werden statt als "geändert" (weil zwischenzeitlich der
        // je andere Teilbereich protokolliert wurde) durchzugehen.
        let tombstonesErgebnis = filter.pruefe(
            ereignis: "sync_snapshot_unveraendert_uebersprungen", details: "tombstones fingerabdruck=aaa",
            jetzt: start.addingTimeInterval(6)
        )
        let stammErgebnis = filter.pruefe(
            ereignis: "sync_snapshot_unveraendert_uebersprungen", details: "stamm fingerabdruck=bbb",
            jetzt: start.addingTimeInterval(6)
        )

        #expect(tombstonesErgebnis == nil)
        #expect(stammErgebnis == nil)
    }
}
