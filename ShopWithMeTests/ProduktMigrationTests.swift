import Foundation
import SwiftData
import Testing
@testable import ShopWithMe

/// Testet die erste echte strukturelle SwiftData-Migration dieses Projekts
/// (``SchemaV1`` → ``SchemaV2``, GitHub #47 Schritt 1/5) end-to-end mit einem
/// echten, VOR der Modelländerung angelegten On-Disk-Store — nicht nur einem
/// frischen In-Memory-Store. Bewusst nötig, siehe `docs/BUILD_WORKFLOW.md`:
/// das bekannte Absturzrisiko strukturell geänderter Modelle reproduziert
/// sich NICHT mit `isStoredInMemoryOnly`-Stores, die den Migrationspfad nie
/// durchlaufen.
@MainActor
struct ProduktMigrationTests {
    private func temporaereStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("produkt-migration-\(UUID().uuidString).sqlite")
    }

    private func raeumeAuf(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    @Test
    func migrationVergibtStandardProduktFuerBereitsBestehendePreispunkteUndEintraege() throws {
        let url = temporaereStoreURL()
        defer { raeumeAuf(url) }

        let artikelID = UUID()
        let preispunktID = UUID()
        let listenEintragID = UUID()

        // 1. Store exakt im alten (SchemaV1) Zustand anlegen — vor jeder
        // Kenntnis von `Produkt`, wie auf einem bereits installierten Gerät.
        do {
            let schemaV1 = Schema(versionedSchema: SchemaV1.self)
            let konfiguration = ModelConfiguration(schema: schemaV1, url: url)
            let container = try ModelContainer(for: schemaV1, configurations: [konfiguration])
            let context = container.mainContext

            let artikel = SchemaV1.Artikel(
                id: artikelID, name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE",
                kategorie: nil, erstelltAm: Date(), notiz: nil, einheitRaw: nil, mengenSchrittRaw: nil
            )
            context.insert(artikel)

            let einkaufsliste = SchemaV1.Einkaufsliste(id: UUID(), name: "Einkaufsliste", erstelltAm: Date())
            context.insert(einkaufsliste)

            let punkt = SchemaV1.Preispunkt(
                id: preispunktID, artikel: artikel, geschaeft: nil, preis: 2.49, datum: Date(),
                produktName: nil, alternativerName: nil, artikelNameSnapshot: "Zahnpasta", geschaeftNameSnapshot: ""
            )
            context.insert(punkt)

            let listenEintrag = SchemaV1.EinkaufslistenEintrag(
                id: listenEintragID, einkaufsliste: einkaufsliste, artikel: artikel, menge: 1, notiz: nil, erstelltAm: Date()
            )
            context.insert(listenEintrag)

            try context.save()
        }

        // 2. Denselben Store erneut öffnen, diesmal mit dem vollen
        // Migrationsplan (SchemaV1 → SchemaV2) — genau der Pfad, den ein
        // reales Gerät nach einem App-Update durchläuft.
        let konfigurationV2 = ModelConfiguration(schema: SchemaDefinition.schema, url: url)
        let container = try ModelContainer(
            for: SchemaDefinition.schema, migrationPlan: SchemaDefinition.migrationPlan, configurations: [konfigurationV2]
        )
        let context = container.mainContext

        let punkte = try context.fetch(FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.id == preispunktID }))
        let punkt = try #require(punkte.first)
        let produktVomPreispunkt = try #require(punkt.produkt)
        #expect(produktVomPreispunkt.istStandard)
        #expect(produktVomPreispunkt.name == "Zahnpasta")
        #expect(produktVomPreispunkt.artikel?.id == artikelID)

        let eintraege = try context.fetch(FetchDescriptor<EinkaufslistenEintrag>(predicate: #Predicate { $0.id == listenEintragID }))
        let eintrag = try #require(eintraege.first)
        let produktVomEintrag = try #require(eintrag.produkt)
        #expect(produktVomEintrag === produktVomPreispunkt)
    }
}
