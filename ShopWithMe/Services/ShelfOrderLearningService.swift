import Foundation
import SwiftData

/// Lernt aus abgeschlossenen ``Einkaufsvorgang``en, in welcher Reihenfolge der
/// Anwender die Artikelkategorien eines Geschäfts typischerweise abläuft, und leitet
/// daraus eine vorgeschlagene automatische Regal-Reihenfolge ab. Besitzt ein Geschäft
/// keine Regale, dient die gelernte Kategorie-Reihenfolge selbst als
/// Sortiergrundlage (siehe ``kategoriePositionen(fuer:context:)``).
///
/// Die manuelle Reihenfolge (``Regal/sortIndex``) bleibt davon unberührt: Über
/// ``Geschaeft/regalSortierModus`` wählt der Anwender, ob die manuelle oder die
/// gelernte Reihenfolge tatsächlich verwendet wird (siehe
/// ``effektiveReihenfolge(fuer:context:)``) — beide bestehen unabhängig
/// nebeneinander. ``vorgeschlageneReihenfolgeUebernehmen(fuer:context:)`` erlaubt es
/// zusätzlich, die gelernte Reihenfolge einmalig als neue manuelle Reihenfolge zu
/// übernehmen.
enum ShelfOrderLearningService {
    /// Ab wie vielen abgeschlossenen Einkäufen in einem Geschäft ein automatischer
    /// Reihenfolge-Vorschlag angeboten wird.
    static let mindestEinkaeufeFuerVorschlag = 5

    /// Wertet einen gerade abgeschlossenen Einkaufsvorgang aus und aktualisiert die
    /// ``KategorieBesuchsStatistik`` der darin besuchten Artikelkategorien.
    static func lernenAus(_ einkaufsvorgang: Einkaufsvorgang, context: ModelContext) {
        guard let geschaeft = einkaufsvorgang.geschaeft else { return }

        var besuchteKategorienNachIndex: [PersistentIdentifier: (kategorie: ArtikelKategorie, index: Int)] = [:]
        for eintrag in einkaufsvorgang.kaufEintraege {
            guard let kategorie = eintrag.kategorie, let index = eintrag.kategorieBesuchsIndex else { continue }
            besuchteKategorienNachIndex[kategorie.persistentModelID] = (kategorie, index)
        }

        for (kategorie, index) in besuchteKategorienNachIndex.values {
            let statistik = statistik(fuer: kategorie, in: geschaeft, context: context)
            statistik.erfassen(sequenzPosition: index)
        }
    }

    /// Anzahl der abgeschlossenen Einkaufsvorgänge in diesem Geschäft.
    static func abgeschlosseneEinkaeufe(fuer geschaeft: Geschaeft, context: ModelContext) -> Int {
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<Einkaufsvorgang>(
            predicate: #Predicate { $0.geschaeft?.persistentModelID == geschaeftID && $0.endZeit != nil }
        )
        return (try? context.fetchCount(deskriptor)) ?? 0
    }

    /// Die anhand der bisherigen Einkäufe gelernte Regal-Reihenfolge für dieses
    /// Geschäft. Die Position eines Regals ergibt sich aus dem Durchschnitt der
    /// gelernten Positionen seiner ``Regal/kategorien``; Regale ohne Kategorien mit
    /// Beobachtungen werden ans Ende sortiert.
    static func vorgeschlageneReihenfolge(fuer geschaeft: Geschaeft, context: ModelContext) -> [Regal] {
        let positionen = kategoriePositionen(fuer: geschaeft, context: context)
        return geschaeft.regale.sorted { a, b in
            let posA = position(fuer: a, kategoriePositionen: positionen)
            let posB = position(fuer: b, kategoriePositionen: positionen)
            if posA == posB {
                return a.sortIndex < b.sortIndex
            }
            return posA < posB
        }
    }

    /// Übernimmt die gelernte Reihenfolge als neue manuelle Reihenfolge
    /// (``Regal/sortIndex``).
    static func vorgeschlageneReihenfolgeUebernehmen(fuer geschaeft: Geschaeft, context: ModelContext) {
        for (index, regal) in vorgeschlageneReihenfolge(fuer: geschaeft, context: context).enumerated() {
            regal.sortIndex = index
        }
    }

    /// Ob für dieses Geschäft genügend abgeschlossene Einkäufe vorliegen, um eine
    /// automatische Reihenfolge anzubieten.
    static func automatischeReihenfolgeVerfuegbar(fuer geschaeft: Geschaeft, context: ModelContext) -> Bool {
        abgeschlosseneEinkaeufe(fuer: geschaeft, context: context) >= mindestEinkaeufeFuerVorschlag
    }

    /// Die tatsächlich anzuwendende Regal-Reihenfolge: die gelernte Reihenfolge, wenn
    /// ``Geschaeft/regalSortierModus`` auf ``RegalSortierModus/automatisch`` steht und
    /// genügend Beobachtungen vorliegen — sonst die manuelle Reihenfolge
    /// (``Regal/sortIndex``). Der Modus-Wechsel verändert ``Regal/sortIndex`` dabei
    /// nicht; die automatische Reihenfolge ist eine Alternative, keine Überschreibung.
    static func effektiveReihenfolge(fuer geschaeft: Geschaeft, context: ModelContext) -> [Regal] {
        guard geschaeft.regalSortierModus == .automatisch,
              automatischeReihenfolgeVerfuegbar(fuer: geschaeft, context: context) else {
            return geschaeft.regale.sorted { $0.sortIndex < $1.sortIndex }
        }
        return vorgeschlageneReihenfolge(fuer: geschaeft, context: context)
    }

    /// Die gelernten durchschnittlichen Besuchspositionen aller Artikelkategorien
    /// dieses Geschäfts, indiziert nach Kategorie. Enthält nur Kategorien, für die
    /// bereits mindestens eine Beobachtung vorliegt. Wird sowohl zur Regal-Aggregation
    /// (``vorgeschlageneReihenfolge(fuer:context:)``) als auch direkt von der
    /// Einkaufsliste genutzt, um Artikel ohne zugeordnetes Regal (z.B. in Geschäften
    /// ohne Regale) sinnvoll zu sortieren.
    static func kategoriePositionen(fuer geschaeft: Geschaeft, context: ModelContext) -> [PersistentIdentifier: Double] {
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<KategorieBesuchsStatistik>(
            predicate: #Predicate { $0.geschaeft?.persistentModelID == geschaeftID }
        )
        let ergebnisse = (try? context.fetch(deskriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: ergebnisse.compactMap { statistik -> (PersistentIdentifier, Double)? in
            guard let kategorie = statistik.kategorie else { return nil }
            return (kategorie.persistentModelID, statistik.durchschnittlichePosition)
        })
    }

    private static func position(fuer regal: Regal, kategoriePositionen: [PersistentIdentifier: Double]) -> Double {
        let beobachtetePositionen = regal.kategorien.compactMap { kategoriePositionen[$0.persistentModelID] }
        guard !beobachtetePositionen.isEmpty else { return .infinity }
        return beobachtetePositionen.reduce(0, +) / Double(beobachtetePositionen.count)
    }

    private static func statistik(fuer kategorie: ArtikelKategorie, in geschaeft: Geschaeft, context: ModelContext) -> KategorieBesuchsStatistik {
        let kategorieID = kategorie.persistentModelID
        var deskriptor = FetchDescriptor<KategorieBesuchsStatistik>(
            predicate: #Predicate { $0.kategorie?.persistentModelID == kategorieID }
        )
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            return bestehende
        }
        let neue = KategorieBesuchsStatistik(geschaeft: geschaeft, kategorie: kategorie)
        context.insert(neue)
        return neue
    }
}
