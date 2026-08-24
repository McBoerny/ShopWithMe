import XCTest

/// Regressionstest für v0.16 (Commits 6c37f0d/335bb1a): ein bedingtes
/// `.searchable(...)`, dessen An-/Abwesenheit an einem live per `@Query`
/// befüllten Zähler hing, ließ das Sheet beim allerersten Öffnen (leeres
/// `@Query` beim ersten Rendern, kurz danach befüllt → Bedingung kippt mitten
/// in der ersten Darstellung) sofort wieder schließen (Live-Fund,
/// `AbteilungHinzufuegenSheet`). Die generische `AuswahlSheet` zeigt
/// `.searchable` seither unbedingt an — dieser Test öffnet ein `AuswahlSheet`
/// über den echten Navigationspfad (Einstellungen → Abteilungen →
/// „Sonstiges" → „Artikel hinzufügen") und prüft, dass es nach einer kurzen
/// Wartezeit noch offen ist.
///
/// `ShopWithMeUITests` läuft als eigener Prozess, der die App nur extern über
/// die Accessibility-Hierarchie steuert (`TEST_TARGET_NAME`, kein
/// `BUNDLE_LOADER` wie bei `ShopWithMeTests`) — `@testable import ShopWithMe`
/// kompiliert zwar, lässt sich aber nicht linken (kein Zugriff auf das
/// App-Binary). Die `A11yID`-Bezeichner aus `AccessibilityIdentifiers.swift`
/// werden hier deshalb bewusst als reine String-Literale dupliziert; ändert
/// sich ein Bezeichner dort, muss er hier manuell nachgezogen werden.
final class AuswahlSheetRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testArtikelHinzufuegenSheetBleibtNachErstemOeffnenOffen() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["tab.einstellungen"].tap()

        let abteilungenRow = app.buttons["settings.abteilungenRow"]
        XCTAssertTrue(abteilungenRow.waitForExistence(timeout: 5))
        abteilungenRow.tap()

        // "Sonstiges" ist die einzige Kategorie, die per SeedData bei jedem
        // frischen App-Start garantiert existiert (ArtikelKategorie.sonstigesName).
        let ersteKategorieRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "abteilungenVerwaltung.kategorieRow.")
        ).firstMatch
        XCTAssertTrue(ersteKategorieRow.waitForExistence(timeout: 5))
        ersteKategorieRow.tap()

        let artikelHinzufuegenButton = app.buttons["abteilungBearbeiten.artikelHinzufuegenButton"]
        XCTAssertTrue(artikelHinzufuegenButton.waitForExistence(timeout: 5))
        artikelHinzufuegenButton.tap()

        let sheetList = app.descendants(matching: .any)["auswahlSheet.list"]
        XCTAssertTrue(sheetList.waitForExistence(timeout: 5), "AuswahlSheet sollte sich öffnen")

        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(sheetList.exists, "AuswahlSheet hat sich unerwartet wieder geschlossen (v0.16-Regression)")
    }
}
