import Foundation
import SwiftData

/// Ermittelt die meistgenutzten ``Geschaeft``e innerhalb eines konfigurierbaren
/// Zeitfensters, anhand abgeschlossener ``Einkaufsvorgang``e — Grundlage für die
/// „Favoriten“-Schnellzugriffsliste in den Geschäfte-Einstellungen und die
/// Geschäftsauswahl beim Einkaufen (GitHub #31).
///
/// Anzahl und Zeitfenster sind vom Anwender in den Einstellungen konfigurierbar
/// (``anzahlFavoriten``/``zeitfensterTage``, in `UserDefaults` persistiert, analog
/// ``PreisHistorieAufbewahrung``).
enum GeschaeftHaeufigkeitService {
    private static let anzahlFavoritenSchluessel = "geschaeftFavoritenAnzahl"
    private static let zeitfensterTageSchluessel = "geschaeftFavoritenZeitfensterTage"

    static let standardAnzahlFavoriten = 5
    static let standardZeitfensterTage = 30

    /// Wie viele Geschäfte ``favoriten(aus:anzahl:zeitfensterTage:jetzt:)`` maximal
    /// liefert. Standard: ``standardAnzahlFavoriten``.
    static var anzahlFavoriten: Int {
        get {
            let wert = UserDefaults.standard.integer(forKey: anzahlFavoritenSchluessel)
            return wert > 0 ? wert : standardAnzahlFavoriten
        }
        set { UserDefaults.standard.set(newValue, forKey: anzahlFavoritenSchluessel) }
    }

    /// Zeitfenster in Tagen, innerhalb dessen Einkaufsvorgänge für die
    /// Häufigkeitsauswertung zählen. Standard: ``standardZeitfensterTage``.
    static var zeitfensterTage: Int {
        get {
            let wert = UserDefaults.standard.integer(forKey: zeitfensterTageSchluessel)
            return wert > 0 ? wert : standardZeitfensterTage
        }
        set { UserDefaults.standard.set(newValue, forKey: zeitfensterTageSchluessel) }
    }

    /// Die `anzahl` meistgenutzten Geschäfte unter `einkaufsvorgaenge`: gezählt
    /// werden nur bereits abgeschlossene (``Einkaufsvorgang/endZeit`` gesetzt), deren
    /// ``Einkaufsvorgang/startZeit`` innerhalb der letzten `zeitfensterTage` liegt.
    /// Absteigend nach Häufigkeit sortiert, bei Gleichstand alphabetisch nach Namen.
    static func favoriten(
        aus einkaufsvorgaenge: [Einkaufsvorgang],
        anzahl: Int = anzahlFavoriten,
        zeitfensterTage: Int = zeitfensterTage,
        jetzt: Date = Date()
    ) -> [Geschaeft] {
        guard let stichtag = Calendar.current.date(byAdding: .day, value: -zeitfensterTage, to: jetzt) else {
            return []
        }
        let relevante = einkaufsvorgaenge.filter { $0.endZeit != nil && $0.startZeit >= stichtag }

        var eintraege: [PersistentIdentifier: (geschaeft: Geschaeft, anzahl: Int)] = [:]
        for vorgang in relevante {
            // `vorgang.modelContext` ist sicher lesbar, da `vorgang` selbst immer
            // ein gültiges, gerade abgefragtes Objekt ist — `geschaeft` dagegen
            // kann eine baumelnde Referenz auf einen bereits gelöschten Datensatz
            // sein (siehe `docs/DATABASE_CONCURRENCY.md`); ungeprüftes Lesen von
            // `.name` weiter unten würde in diesem Fall abstürzen.
            guard let geschaeft = vorgang.geschaeft,
                  let context = vorgang.modelContext,
                  context.existiertNochImStore(geschaeft)
            else { continue }
            eintraege[geschaeft.persistentModelID, default: (geschaeft, 0)].anzahl += 1
        }

        return eintraege.values
            .sorted { lhs, rhs in
                lhs.anzahl != rhs.anzahl
                    ? lhs.anzahl > rhs.anzahl
                    : lhs.geschaeft.name.vergleicheAlphabetisch(mit: rhs.geschaeft.name) == .orderedAscending
            }
            .prefix(anzahl)
            .map(\.geschaeft)
    }
}
