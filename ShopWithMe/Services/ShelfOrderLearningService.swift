import Foundation
import SwiftData

/// Lernt aus abgeschlossenen ``Einkaufsvorgang``en, in welcher Reihenfolge der
/// Anwender die Regale eines Geschäfts typischerweise abläuft, und leitet daraus eine
/// vorgeschlagene automatische Regal-Reihenfolge ab.
///
/// Die manuelle Reihenfolge (``Regal/sortIndex``) bleibt dabei unangetastet, bis der
/// Anwender den Vorschlag explizit über
/// ``vorgeschlageneReihenfolgeUebernehmen(fuer:context:)`` übernimmt.
enum ShelfOrderLearningService {
    /// Ab wie vielen abgeschlossenen Einkäufen in einem Geschäft ein automatischer
    /// Reihenfolge-Vorschlag angeboten wird.
    static let mindestEinkaeufeFuerVorschlag = 5

    /// Wertet einen gerade abgeschlossenen Einkaufsvorgang aus und aktualisiert die
    /// ``RegalBesuchsStatistik`` der darin besuchten Regale.
    static func lernenAus(_ einkaufsvorgang: Einkaufsvorgang, context: ModelContext) {
        guard let geschaeft = einkaufsvorgang.geschaeft else { return }

        var besuchteRegaleNachIndex: [PersistentIdentifier: (regal: Regal, index: Int)] = [:]
        for eintrag in einkaufsvorgang.kaufEintraege {
            guard let regal = eintrag.regal, let index = eintrag.regalBesuchsIndex else { continue }
            besuchteRegaleNachIndex[regal.persistentModelID] = (regal, index)
        }

        for (regal, index) in besuchteRegaleNachIndex.values {
            let statistik = statistik(fuer: regal, in: geschaeft, context: context)
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
    /// Geschäft. Regale ohne Beobachtungen werden ans Ende sortiert.
    static func vorgeschlageneReihenfolge(fuer geschaeft: Geschaeft, context: ModelContext) -> [Regal] {
        let statistikenNachRegal = statistiken(fuer: geschaeft, context: context)
        return geschaeft.regale.sorted { a, b in
            let posA = statistikenNachRegal[a.persistentModelID]?.durchschnittlichePosition ?? .infinity
            let posB = statistikenNachRegal[b.persistentModelID]?.durchschnittlichePosition ?? .infinity
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

    private static func statistik(fuer regal: Regal, in geschaeft: Geschaeft, context: ModelContext) -> RegalBesuchsStatistik {
        let regalID = regal.persistentModelID
        var deskriptor = FetchDescriptor<RegalBesuchsStatistik>(
            predicate: #Predicate { $0.regal?.persistentModelID == regalID }
        )
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            return bestehende
        }
        let neue = RegalBesuchsStatistik(geschaeft: geschaeft, regal: regal)
        context.insert(neue)
        return neue
    }

    private static func statistiken(fuer geschaeft: Geschaeft, context: ModelContext) -> [PersistentIdentifier: RegalBesuchsStatistik] {
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<RegalBesuchsStatistik>(
            predicate: #Predicate { $0.geschaeft?.persistentModelID == geschaeftID }
        )
        let ergebnisse = (try? context.fetch(deskriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: ergebnisse.compactMap { statistik in
            guard let regal = statistik.regal else { return nil }
            return (regal.persistentModelID, statistik)
        })
    }
}
