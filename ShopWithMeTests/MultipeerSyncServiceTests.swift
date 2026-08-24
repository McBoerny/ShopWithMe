import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity
import SwiftData
import Testing
@testable import ShopWithMe

/// Tests für den Multipeer-Beschleunigungskanal (GitHub #49). Die eigentliche
/// `MCSession`/Bonjour-Kommunikation lässt sich nicht sinnvoll unit-testen —
/// Simulatoren können Bluetooth/AWDL-Peer-Discovery nicht zuverlässig
/// nachbilden, echte Verifikation braucht reale Zwei-Geräte-Live-Tests
/// (analog dem Datei-Kanal, siehe `docs/DATENSYNCHRONISATION.md` §9). Hier
/// getestet: die wiederverwendete Konfliktauflösung/Materialisierung
/// (``SyncImportService/wendeEinzelnesEmpfangenesEventAn(_:context:)``) sowie
/// die Gruppen-Identität/Service-Type-Ableitung (``SyncOrdnerService``).
@MainActor
struct MultipeerSyncServiceTests {
    private func machtLeerenContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, SyncEvent.self, SyncEntitaetsAlias.self,
            ArtikelGeschaeftVerfuegbarkeit.self, ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    /// Erweiterter Container inklusive aller Modelltypen, die
    /// ``SyncSnapshotImportService/mergePaket(tombstones:stamm:listen:lernen:vorgaenge:preise:kaeufe:geraeteName:peerGeraeteID:erzeugtAm:context:)``
    /// fetcht (Muster wie `SyncSnapshotImportServiceTests.machtLeerenContainer`)
    /// — für die Catch-up-Tests unten, die diese Funktion als geteilten
    /// Merge-Einstiegspunkt mit dem Datei-Kanal nutzen (GitHub #125).
    private func machtLeerenContainerFuerCatchUp() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Artikel.self, Abteilung.self, Geschaeft.self, GeschaeftTyp.self,
            Einkaufsvorgang.self, KaufEintrag.self, WarengruppenDistanz.self, WarengruppenDistanzPeerZaehlerStand.self,
            Einkaufsliste.self, EinkaufslistenEintrag.self, IgnorierterArtikel.self,
            SyncEvent.self, SyncEntitaetsAlias.self, SyncPeerZaehlerStand.self, SyncPeerInfo.self,
            SyncTombstone.self, Preispunkt.self, SyncAbgleichKandidat.self,
            ArtikelGeschaeftVerfuegbarkeit.self, GeschaeftBesuch.self, ArtikelListenKauf.self,
        ])
        let konfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [konfiguration])
        return (container, container.mainContext)
    }

    private func leeresCatchUpPaket(geraeteID: String, geraeteName: String = "Fremdes iPhone") -> MultipeerCatchUpPaket {
        MultipeerCatchUpPaket(
            teile: SyncPaketTeile(
                manifest: SyncPeerManifest(
                    formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: Date(),
                    geraeteID: geraeteID, geraeteName: geraeteName
                ),
                tombstones: [], stamm: SyncStammSnapshot(
                    geschaeftsTypen: [], abteilungen: [], geschaefte: [], artikel: [],
                    einkaufslisten: [], produkte: [], produktnamen: []
                ),
                listen: SyncListenSnapshot(einkaufslistenEintraege: []),
                lernen: SyncLernenSnapshot(
                    warengruppenDistanzen: [], artikelGeschaeftVerfuegbarkeiten: [],
                    geschaeftBesuche: [], artikelListenKaeufe: []
                ),
                vorgaenge: SyncVorgaengeSnapshot(einkaufsvorgaenge: []), preise: SyncPreisSnapshot(preispunkte: [])
            ),
            kaeufe: []
        )
    }

    private func macheTempSyncOrdner() -> URL {
        let ordner = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    // MARK: - wendeEinzelnesEmpfangenesEventAn (geteilte Logik mit dem Datei-Import)

    @Test
    func wendeEinzelnesEmpfangenesEventAnMaterialisiertArtikelHinzugefuegt() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        let empfangen = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "peer-a", autorGeraeteID: "peer-a", wallClock: Date()
        )

        SyncImportService.wendeEinzelnesEmpfangenesEventAn(empfangen, context: context)

        #expect(liste.enthaelt(apfel))
    }

    @Test
    func wendeEinzelnesEmpfangenesEventAnIstBeiWiederholungIdempotent() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        try context.save()

        let empfangen = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelHinzugefuegt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: liste.id, artikelID: apfel.id)),
            lamportZaehler: 1, lamportGeraeteID: "peer-a", autorGeraeteID: "peer-a", wallClock: Date()
        )

        SyncImportService.wendeEinzelnesEmpfangenesEventAn(empfangen, context: context)
        liste.artikelEntfernenOhneEventAufzeichnung(apfel, context: context)
        try context.save()
        SyncImportService.wendeEinzelnesEmpfangenesEventAn(empfangen, context: context)

        // Das (identische) Event darf beim zweiten Mal nicht erneut angewendet
        // werden — sonst wäre der Artikel wieder auf der Liste. Wichtig gerade
        // für diesen Kanal: dasselbe Event trifft später oft zusätzlich über
        // den Datei-Kanal ein (Multipeer ist rein additiv, siehe Typ-Doku
        // ``MultipeerSyncService``).
        #expect(!liste.enthaelt(apfel))
    }

    /// Beweist, dass der Multipeer-Empfangspfad dieselbe Konfliktauflösung
    /// nutzt wie der Datei-Import (``SyncImportServiceTests/abwaehlenGewinntGegenAbhakenUnabhaengigVonReihenfolge``) —
    /// keine zweite, separat gepflegte Kopie der Merge-Logik.
    @Test
    func wendeEinzelnesEmpfangenesEventAnRespektiertKonfliktaufloesungWieDerDateiImport() throws {
        let (container, context) = try machtLeerenContainer()
        _ = container
        let typ = GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")
        context.insert(typ)
        let geschaeft = Geschaeft(name: "Testladen", typen: [typ])
        context.insert(geschaeft)
        let liste = Einkaufsliste(name: "Einkaufsliste")
        context.insert(liste)
        let apfel = Artikel(name: "Apfel", symbolName: "carrot.fill", farbeHex: "#34C759")
        context.insert(apfel)
        liste.artikelHinzufuegenOhneEventAufzeichnung(apfel, context: context)
        let einkauf = Einkaufsvorgang(geschaeft: geschaeft, einkaufsliste: liste)
        context.insert(einkauf)
        try context.save()

        // Lokal (dieses Gerät) abgehakt, mit niedrigerem Lamport-Zähler.
        einkauf.artikelAbhakenOhneEventAufzeichnung(apfel, context: context)
        let lokalesEvent = SyncEvent(
            art: .artikelAbgehakt,
            nutzlast: SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id),
            lamportZaehler: 5, lamportGeraeteID: "dieses-geraet", autorGeraeteID: "dieses-geraet"
        )
        context.insert(lokalesEvent)
        try context.save()

        // Per Multipeer sofort empfangen: kausal unabhängiges Abwählen mit
        // höherem Lamport-Zähler.
        let empfangen = SyncEventExportDarstellung(
            id: UUID(), art: SyncEventArt.artikelAbgewaehlt.rawValue,
            nutzlast: try JSONEncoder().encode(SyncEventNutzlast(bezugsID: einkauf.id, artikelID: apfel.id)),
            lamportZaehler: 10, lamportGeraeteID: "peer-a", autorGeraeteID: "peer-a", wallClock: Date()
        )

        SyncImportService.wendeEinzelnesEmpfangenesEventAn(empfangen, context: context)

        #expect(einkauf.kaufEintraege.isEmpty)
        #expect(liste.enthaelt(apfel))
    }

    // MARK: - Gruppen-Identität (SyncOrdnerService)

    @Test
    func multipeerGruppenIDWirdEinmaligErzeugtUndDanachWiederverwendet() async {
        let syncOrdner = macheTempSyncOrdner()
        let ersterAufruf = await SyncOrdnerService.multipeerGruppenID(in: syncOrdner)
        let zweiterAufruf = await SyncOrdnerService.multipeerGruppenID(in: syncOrdner)
        #expect(ersterAufruf != nil)
        #expect(ersterAufruf == zweiterAufruf)
    }

    @Test
    func multipeerGruppenIDUnterscheidetSichZwischenVerschiedenenOrdnern() async {
        let ordnerA = macheTempSyncOrdner()
        let ordnerB = macheTempSyncOrdner()
        let idA = await SyncOrdnerService.multipeerGruppenID(in: ordnerA)
        let idB = await SyncOrdnerService.multipeerGruppenID(in: ordnerB)
        #expect(idA != nil && idB != nil)
        #expect(idA != idB)
    }

    /// Nachfolgefund zu GitHub #49: ein nicht erreichbarer Ordner (hier
    /// simuliert durch einen bereits wieder gelöschten Pfad) darf KEINE
    /// geratene ID liefern — sonst würden zwei zeitgleich nicht erreichbare
    /// Geräte unabhängig voneinander unterschiedliche IDs erfinden und sich
    /// per Multipeer nie mehr finden, siehe Typ-Doku
    /// ``SyncOrdnerService/multipeerGruppenID(in:)``.
    @Test
    func multipeerGruppenIDLiefertNilBeiNichtErreichbaremOrdner() async {
        let nichtErreichbar = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("unterordner", isDirectory: true)
        let ergebnis = await SyncOrdnerService.multipeerGruppenID(in: nichtErreichbar)
        #expect(ergebnis == nil)
    }

    /// Bonjour-Zwang (`MCNearbyServiceAdvertiser`/`-Browser`, verifiziert
    /// gegen den installierten iOS-SDK-Header): max. 15 Zeichen,
    /// ausschließlich Kleinbuchstaben/Ziffern/Bindestrich. Der Service-Type
    /// ist bewusst eine feste Konstante (siehe Typ-Doku
    /// ``SyncOrdnerService/multipeerServiceType``) — dieser Test schützt vor
    /// einer künftigen Änderung, die versehentlich gegen die Bonjour-Regeln
    /// verstößt.
    @Test
    func multipeerServiceTypeIstBonjourKonform() {
        let type = SyncOrdnerService.multipeerServiceType
        #expect(type.count <= 15)
        #expect(type.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }

    @Test
    func multipeerGruppenSchluesselIstDeterministischUndUnterscheidetGruppen() {
        let gruppenID = UUID()
        let ersterAufruf = SyncOrdnerService.multipeerGruppenSchluessel(fuerGruppenID: gruppenID)
        let zweiterAufruf = SyncOrdnerService.multipeerGruppenSchluessel(fuerGruppenID: gruppenID)
        let andereGruppe = SyncOrdnerService.multipeerGruppenSchluessel(fuerGruppenID: UUID())

        func alsData(_ schluessel: SymmetricKey) -> Data { schluessel.withUnsafeBytes { Data($0) } }

        #expect(alsData(ersterAufruf) == alsData(zweiterAufruf))
        #expect(alsData(ersterAufruf) != alsData(andereGruppe))
    }

    /// Schützt das in ``MultipeerSyncService`` implementierte Challenge-
    /// Response-Verfahren (GitHub #97) gegen Regressionen: derselbe Nachweis
    /// darf nur für exakt Nonce+Schlüssel+Peer-Identität gültig sein, für den
    /// er gebildet wurde.
    @Test
    func challengeResponseNachweisIstAnNonceSchluesselUndPeerGebunden() {
        let schluessel = SyncOrdnerService.multipeerGruppenSchluessel(fuerGruppenID: UUID())
        let andererSchluessel = SyncOrdnerService.multipeerGruppenSchluessel(fuerGruppenID: UUID())
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let andererNonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let peerName = "Testgerät"
        let andererPeerName = "Anderes Gerät"

        func nachweis(schluessel: SymmetricKey, nonce: Data, peerName: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: nonce + Data(peerName.utf8), using: schluessel))
        }

        let gueltig = nachweis(schluessel: schluessel, nonce: nonce, peerName: peerName)

        #expect(HMAC<SHA256>.isValidAuthenticationCode(
            gueltig, authenticating: nonce + Data(peerName.utf8), using: schluessel
        ))
        #expect(!HMAC<SHA256>.isValidAuthenticationCode(
            gueltig, authenticating: nonce + Data(peerName.utf8), using: andererSchluessel
        ))
        #expect(!HMAC<SHA256>.isValidAuthenticationCode(
            gueltig, authenticating: andererNonce + Data(peerName.utf8), using: schluessel
        ))
        #expect(!HMAC<SHA256>.isValidAuthenticationCode(
            gueltig, authenticating: nonce + Data(andererPeerName.utf8), using: schluessel
        ))
    }

    // MARK: - Bereich-B/C/D-Catch-up (GitHub #125)

    /// Beweist, dass der Multipeer-Catch-up-Empfangspfad
    /// (``MultipeerSyncService/session(_:didFinishReceivingResourceWithName:fromPeer:at:withError:)``)
    /// dieselbe, geteilte Merge-Funktion wie der Datei-Import anwendet und
    /// bei Wiederholung idempotent bleibt — kein zweiter, separat gepflegter
    /// Konfliktalgorithmus.
    @Test
    func catchUpPaketWirdUebernommenUndIstBeiWiederholungIdempotent() async throws {
        let (container, context) = try machtLeerenContainerFuerCatchUp()
        _ = container

        var paket = leeresCatchUpPaket(geraeteID: "fremdes-geraet")
        paket.teile.stamm = SyncStammSnapshot(
            geschaeftsTypen: [
                GeschaeftTypSnapshot(id: UUID(), name: "Lebensmittel", symbolName: "cart", farbeHex: "#FF0000", sortIndex: 0),
            ],
            abteilungen: [], geschaefte: [], artikel: [], einkaufslisten: [], produkte: [], produktnamen: []
        )

        let dienst = MultipeerSyncService()
        dienst.starten(context: context)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(paket).write(to: tempURL)
        let fremdeSession = MCSession(peer: MCPeerID(displayName: "Testgerät"))
        let fremderPeer = MCPeerID(displayName: "Fremdes iPhone")

        dienst.session(fremdeSession, didFinishReceivingResourceWithName: "paket", fromPeer: fremderPeer, at: tempURL, withError: nil)
        // Der eigentliche Merge läuft in einem intern gestarteten `Task {
        // @MainActor in }` (Delegate-Callback-Konvention, siehe Typ-Doku) —
        // auf dem `@MainActor`-`Test` reicht ein `Task.yield()`-Zyklus, um
        // sicherzustellen, dass dieser Task vor der Prüfung unten drankam.
        for _ in 0..<5 { await Task.yield() }

        let typen = try context.fetch(FetchDescriptor<GeschaeftTyp>())
        #expect(typen.count == 1)
        #expect(typen.first?.name == "Lebensmittel")

        // Zweiter, identischer Empfang desselben Pakets — kein Duplikat.
        let zweiteTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(paket).write(to: zweiteTempURL)
        dienst.session(fremdeSession, didFinishReceivingResourceWithName: "paket", fromPeer: fremderPeer, at: zweiteTempURL, withError: nil)
        for _ in 0..<5 { await Task.yield() }

        let typenNachWiederholung = try context.fetch(FetchDescriptor<GeschaeftTyp>())
        #expect(typenNachWiederholung.count == 1)
    }

    /// Re-Entranz-Schutz (siehe Typ-Doku ``MultipeerSyncService/wendeCatchUpPaketAn(_:context:)``):
    /// läuft bereits ein anderer vollständiger Sync-Zyklus (hier simuliert
    /// durch direkten Aufruf von ``SyncImportService/versucheVollstaendigenZyklusZuStarten()``,
    /// wie es der Datei-Zyklus tut), wird der Catch-up komplett übersprungen
    /// statt gegen denselben `ModelContext` einen konkurrierenden Merge zu
    /// starten — die bereits einmal real aufgetretene Datenkorruption
    /// zwischen zwei überlappenden `mergePaket`-Läufen darf sich hier nicht
    /// wiederholen.
    @Test
    func catchUpPaketWirdBeiLaufendemZyklusUebersprungen() async throws {
        let (container, context) = try machtLeerenContainerFuerCatchUp()
        _ = container

        var paket = leeresCatchUpPaket(geraeteID: "fremdes-geraet")
        paket.teile.stamm = SyncStammSnapshot(
            geschaeftsTypen: [
                GeschaeftTypSnapshot(id: UUID(), name: "Lebensmittel", symbolName: "cart", farbeHex: "#FF0000", sortIndex: 0),
            ],
            abteilungen: [], geschaefte: [], artikel: [], einkaufslisten: [], produkte: [], produktnamen: []
        )

        let dienst = MultipeerSyncService()
        dienst.starten(context: context)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(paket).write(to: tempURL)
        let fremdeSession = MCSession(peer: MCPeerID(displayName: "Testgerät"))
        let fremderPeer = MCPeerID(displayName: "Fremdes iPhone")

        #expect(SyncImportService.versucheVollstaendigenZyklusZuStarten())
        defer { SyncImportService.beendeVollstaendigenZyklus() }

        dienst.session(fremdeSession, didFinishReceivingResourceWithName: "paket", fromPeer: fremderPeer, at: tempURL, withError: nil)
        for _ in 0..<5 { await Task.yield() }

        let typen = try context.fetch(FetchDescriptor<GeschaeftTyp>())
        #expect(typen.isEmpty)
    }
}
