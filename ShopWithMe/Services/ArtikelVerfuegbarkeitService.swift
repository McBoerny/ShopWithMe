import Foundation
import SwiftData

/// Bestimmt, ob ein ``Artikel`` in einem bestimmten ``Geschaeft`` "verfügbar" ist —
/// Grundlage für den Standard-Filter beim Einkaufen (siehe
/// `EinkaufslisteView.verfuegbarkeitsgefiltert(_:)`).
///
/// Besitzt das Geschäft eigene Kategorien (``Geschaeft/verfuegbareKategorien`` —
/// direkt zugeordnet oder über ein Regal, ein Regal ist dafür nicht erforderlich),
/// ist ein Artikel verfügbar, wenn mindestens eine seiner Kategorien darin
/// enthalten ist (ein Artikel kann mehreren Kategorien angehören).
/// Besitzt das Geschäft keine eigenen Kategorien, lernt die App stattdessen aus der
/// Kaufhistorie: ein Artikel gilt als verfügbar, sobald er dort mindestens einmal
/// abgehakt/gekauft wurde (``KaufEintrag``) — das Abhaken eines bislang unbekannten
/// Artikels (bei eingeblendeten "alle Artikeln" während des Einkaufs) macht ihn also
/// unmittelbar auch für künftige Einkäufe in diesem Geschäft "verfügbar".
enum ArtikelVerfuegbarkeitService {
    static func istVerfuegbar(_ artikel: Artikel, in geschaeft: Geschaeft, context: ModelContext) -> Bool {
        guard geschaeft.verfuegbareKategorien.isEmpty else {
            let kategorien = artikel.effektiveKategorien(context: context)
            return kategorien.contains(where: geschaeft.verfuegbareKategorien.contains)
        }

        let artikelID = artikel.persistentModelID
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<KaufEintrag>(
            predicate: #Predicate { $0.artikel?.persistentModelID == artikelID && $0.geschaeft?.persistentModelID == geschaeftID }
        )
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }
}
