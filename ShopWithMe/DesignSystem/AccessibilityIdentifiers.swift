import Foundation

/// Zentrale, stringly-typed Accessibility-Identifier für XCUITests.
///
/// Sowohl Produktionscode (`.accessibilityIdentifier(A11yID.…)`) als auch
/// `ShopWithMeUITests` referenzieren dieselben Konstanten — vermeidet
/// Divergenz/Tippfehler zwischen Test und View (Single Source of Truth statt
/// frei getippter Strings auf beiden Seiten).
enum A11yID {
    enum Tab {
        static let einkaufen = "tab.einkaufen"
        static let scannen = "tab.scannen"
        static let einstellungen = "tab.einstellungen"
    }

    enum Settings {
        static let abteilungenRow = "settings.abteilungenRow"
    }

    enum AbteilungenVerwaltung {
        static let list = "abteilungenVerwaltung.list"
        static let hinzufuegenButton = "abteilungenVerwaltung.hinzufuegenButton"
        static func kategorieRow<ID>(_ id: ID) -> String {
            "abteilungenVerwaltung.kategorieRow.\(String(describing: id))"
        }
    }

    enum AbteilungBearbeiten {
        static let artikelHinzufuegenButton = "abteilungBearbeiten.artikelHinzufuegenButton"
    }

    enum GeschaeftAbteilungenSektion {
        static let hinzufuegenButton = "geschaeftAbteilungenSektion.hinzufuegenButton"
    }

    /// Gilt für alle Verwender der generischen ``AuswahlSheet``-Komponente
    /// (``AbteilungHinzufuegenSheet``, ``KategorieHinzufuegenSheet``,
    /// `ArtikelZuAbteilungHinzufuegenSheet`, ``ArtikelAuswahlSheet`` u.a.) — ein
    /// Test greift also unabhängig vom konkreten Aufrufer immer auf dieselben
    /// Bezeichner zu.
    enum AuswahlSheet {
        static let list = "auswahlSheet.list"
        static func zeile<ID>(_ id: ID) -> String { "auswahlSheet.zeile.\(String(describing: id))" }
        static let neuAnlegenButton = "auswahlSheet.neuAnlegenButton"
        static let abbrechenButton = "auswahlSheet.abbrechenButton"
        static let bestaetigenButton = "auswahlSheet.bestaetigenButton"
    }

    enum NeueAbteilungSheet {
        static let nameField = "neueAbteilungSheet.nameField"
        static let sichernButton = "neueAbteilungSheet.sichernButton"
    }
}
