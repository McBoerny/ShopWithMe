import Foundation
import Testing
@testable import ShopWithMe

struct PeerOrdnerNameTests {
    @Test
    func kurzeIDLiefertSechsKleinbuchstabenHexZeichenOhneBindestriche() {
        let id = "550E8400-E29B-41D4-A716-446655440000"
        #expect(PeerOrdnerName.kurzeID(id) == "550e84")
    }

    @Test
    func bereinigterNameErsetztUnsichereZeichenUndFasstMehrfacheBindestricheZusammen() {
        #expect(PeerOrdnerName.bereinigterName("Annas iPhone") == "Annas-iPhone")
        #expect(PeerOrdnerName.bereinigterName("Anna's  iPhone / 15") == "Anna-s-iPhone-15")
    }

    @Test
    func bereinigterNameEntferntFuehrendeUndAbschliessendeBindestriche() {
        #expect(PeerOrdnerName.bereinigterName("--iPhone--") == "iPhone")
    }

    @Test
    func bereinigterNameFaelltBeiRestlosLeeremNamenAufFallbackZurueck() {
        #expect(PeerOrdnerName.bereinigterName("🎉🎉🎉") == "Geraet")
    }

    @Test
    func bereinigterNameBegrenztAufVierzigZeichen() {
        let langerName = String(repeating: "A", count: 60)
        #expect(PeerOrdnerName.bereinigterName(langerName).count == 40)
    }

    @Test
    func nameHaengtKurzeIDImmerAn() {
        let name = PeerOrdnerName.name(geraeteID: "550E8400-E29B-41D4-A716-446655440000", geraeteName: "Annas iPhone")
        #expect(name == "Annas-iPhone_550e84")
    }

    @Test
    func gehoertZuErkenntNeuesSchema() {
        let id = "550E8400-E29B-41D4-A716-446655440000"
        #expect(PeerOrdnerName.gehoertZu("Annas-iPhone_550e84", geraeteID: id))
        #expect(!PeerOrdnerName.gehoertZu("Bens-iPhone_abcdef", geraeteID: id))
    }

    @Test
    func gehoertZuErkenntAltenReinenUUIDOrdnerVorGitHub81() {
        let id = "550E8400-E29B-41D4-A716-446655440000"
        #expect(PeerOrdnerName.gehoertZu(id, geraeteID: id))
    }
}
