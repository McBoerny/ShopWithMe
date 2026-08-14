import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// End-to-End-Szenarien für Mehrgeräte-Sync (Workstream 3,
/// docs/SYNC_CONNECTOR_ARCHITEKTUR.md). Treibt `MehrgeraeteSimulator` und
/// prüft, dass die CRDT-Merge-Strategien aus `docs/SYNC_MERGE_STRATEGIEN.md`
/// über den vollständigen Export/Import-Pfad korrekt konvergieren.
///
/// `@Suite(.serialized)`: Tests in dieser Suite modifizieren `SyncOrdnerService`-
/// GlobalState (UserDefaults-Bookmark) und dürfen nicht parallel laufen.
@Suite(.serialized)
@MainActor
struct MehrgeraeteSzenarienTests {

    // MARK: - Szenario 1: Stammdaten-Konvergenz (mergeArtikel — Zeile 7)
    //
    // Zwei Geräte legen unabhängig voneinander verschiedene Artikel an.
    // Nach einem Sync-Schritt soll jedes Gerät beide Artikel kennen.

    @Test
    func artikelKonvergenzNachEinemSyncSchritt() async throws {
        let sim = try MehrgeraeteSimulator(anzahlGeraete: 2)

        let milch = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#FFFFFF")
        sim.a.context.insert(milch)
        try sim.a.context.save()

        let butter = Artikel(name: "Butter", symbolName: "star.fill", farbeHex: "#FFEE00")
        sim.b.context.insert(butter)
        try sim.b.context.save()

        // Ein vollständiger Sync-Schritt: beide exportieren, beide importieren.
        try await sim.synchronisiereAlleGeraete()

        let artikelA = try sim.a.context.fetch(FetchDescriptor<Artikel>())
            .map(\.name).sorted()
        let artikelB = try sim.b.context.fetch(FetchDescriptor<Artikel>())
            .map(\.name).sorted()

        #expect(artikelA == ["Butter", "Milch"])
        #expect(artikelB == ["Butter", "Milch"])
    }

    // MARK: - Szenario 2: Tombstone-Propagation (mergeTombstones — Zeile 3)
    //
    // Gerät A legt ein Geschäft an, synchronisiert es zu B.
    // Dann löscht A das Geschäft (setzt Tombstone) und synchronisiert erneut.
    // Nach dem zweiten Sync soll das Geschäft auch bei B verschwunden sein.

    @Test
    func tombstonePropagiertzuPeer() async throws {
        let sim = try MehrgeraeteSimulator(anzahlGeraete: 2)

        let reweID = UUID()
        let rewe = Geschaeft(name: "Rewe", typen: [])
        // UUID manuell setzen, damit Tombstone und Objekt dieselbe ID haben.
        rewe.id = reweID
        sim.a.context.insert(rewe)
        try sim.a.context.save()

        // Erster Sync: A → B (B erhält das Geschäft).
        try await sim.synchronisiereAlleGeraete()
        let geschaefteNachSync1 = try sim.b.context.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefteNachSync1.count == 1, "B muss das Geschäft nach dem ersten Sync kennen")

        // A löscht das Geschäft und registriert einen Tombstone.
        let reweLokal = try sim.a.context.fetch(FetchDescriptor<Geschaeft>()).first!
        SyncTombstoneService.markiereGeloescht(art: "Geschaeft", id: reweLokal.id, context: sim.a.context)
        sim.a.context.delete(reweLokal)
        try sim.a.context.save()

        // Zweiter Sync: A exportiert Tombstone, B importiert und löscht das Geschäft.
        try await sim.synchronisiereAlleGeraete()
        let geschaefteNachSync2 = try sim.b.context.fetch(FetchDescriptor<Geschaeft>())
        #expect(geschaefteNachSync2.isEmpty, "Tombstone muss das Geschäft bei B löschen")
    }

    // MARK: - Szenario 3: OR-Set add-wins (mergeEinkaufslistenEintraege — Zeile 11)
    //
    // Beide Geräte kennen dieselbe Einkaufsliste (nach initialem Sync).
    // A fügt „Milch" hinzu, B fügt „Butter" hinzu — unabhängig voneinander.
    // Nach dem Sync sollen beide Geräte beide Einträge haben.
    // OR-Set add-wins: kein Eintrag darf durch den anderen unterdrückt werden.

    @Test
    func einkaufslistenEintraegeORSetAddWins() async throws {
        let sim = try MehrgeraeteSimulator(anzahlGeraete: 2)

        // Gemeinsame Ausgangslage: Artikel + Einkaufsliste auf Gerät A anlegen.
        let milchArtikel = Artikel(name: "Milch", symbolName: "drop.fill", farbeHex: "#FFFFFF")
        let butterArtikel = Artikel(name: "Butter", symbolName: "star.fill", farbeHex: "#FFEE00")
        sim.a.context.insert(milchArtikel)
        sim.a.context.insert(butterArtikel)
        let liste = Einkaufsliste(name: "Wocheneinkauf")
        sim.a.context.insert(liste)
        try sim.a.context.save()

        // Erster Sync: Artikel + Liste zu B übertragen.
        try await sim.synchronisiereAlleGeraete()

        // A fügt Milch-Eintrag zur Liste hinzu.
        let listeBeiA = try sim.a.context.fetch(FetchDescriptor<Einkaufsliste>()).first!
        let milchBeiA = try sim.a.context.fetch(FetchDescriptor<Artikel>(
            predicate: #Predicate { $0.name == "Milch" }
        )).first!
        let milchEintrag = EinkaufslistenEintrag(
            einkaufsliste: listeBeiA, artikel: milchBeiA, menge: 1
        )
        sim.a.context.insert(milchEintrag)
        try sim.a.context.save()

        // B fügt Butter-Eintrag zur Liste hinzu.
        let listeBeiB = try sim.b.context.fetch(FetchDescriptor<Einkaufsliste>()).first!
        let butterBeiB = try sim.b.context.fetch(FetchDescriptor<Artikel>(
            predicate: #Predicate { $0.name == "Butter" }
        )).first!
        let butterEintrag = EinkaufslistenEintrag(
            einkaufsliste: listeBeiB, artikel: butterBeiB, menge: 1
        )
        sim.b.context.insert(butterEintrag)
        try sim.b.context.save()

        // Zweiter Sync: OR-Set — beide Einträge sollen auf beiden Geräten landen.
        try await sim.synchronisiereAlleGeraete()

        let eintraegeA = try sim.a.context.fetch(FetchDescriptor<EinkaufslistenEintrag>())
        let eintraegeB = try sim.b.context.fetch(FetchDescriptor<EinkaufslistenEintrag>())
        #expect(eintraegeA.count == 2, "Gerät A muss beide Einträge haben")
        #expect(eintraegeB.count == 2, "Gerät B muss beide Einträge haben")
    }

    // MARK: - Szenario 4: Immutable-Log Union-by-ID (GeschaeftBesuch — Zeile 18)
    //
    // Gerät A und B haben nach initialem Sync dasselbe Geschäft.
    // Jedes Gerät erstellt unabhängig einen GeschaeftBesuch mit eigener UUID.
    // Nach dem Sync sollen beide Geräte beide Besuche kennen (additive Union,
    // kein Besuch wird durch den anderen überschrieben oder unterdrückt).

    @Test
    func geschaeftBesuchUnionNachSync() async throws {
        let sim = try MehrgeraeteSimulator(anzahlGeraete: 2)

        // Gemeinsame Ausgangslage: ein Geschäft auf beiden Geräten.
        let rewe = Geschaeft(name: "Rewe", typen: [])
        sim.a.context.insert(rewe)
        try sim.a.context.save()
        try await sim.synchronisiereAlleGeraete()

        // Gerät A registriert Besuch #1.
        let reweBeiA = try sim.a.context.fetch(FetchDescriptor<Geschaeft>()).first!
        let jetzt = Date()
        let besuchA = GeschaeftBesuch(
            geschaeft: reweBeiA,
            startZeit: jetzt.addingTimeInterval(-600),
            endZeit: jetzt.addingTimeInterval(-300),
            anzahlProdukte: 5
        )
        sim.a.context.insert(besuchA)
        try sim.a.context.save()

        // Gerät B registriert Besuch #2.
        let reweBeiB = try sim.b.context.fetch(FetchDescriptor<Geschaeft>()).first!
        let besuchB = GeschaeftBesuch(
            geschaeft: reweBeiB,
            startZeit: jetzt.addingTimeInterval(-200),
            endZeit: jetzt,
            anzahlProdukte: 8
        )
        sim.b.context.insert(besuchB)
        try sim.b.context.save()

        // Sync: Union-by-ID — beide Geräte sollen beide Besuche kennen.
        try await sim.synchronisiereAlleGeraete()

        let besuecheA = try sim.a.context.fetch(FetchDescriptor<GeschaeftBesuch>())
        let besuecheB = try sim.b.context.fetch(FetchDescriptor<GeschaeftBesuch>())
        #expect(besuecheA.count == 2, "Gerät A muss beide Besuche kennen")
        #expect(besuecheB.count == 2, "Gerät B muss beide Besuche kennen")
    }
}
