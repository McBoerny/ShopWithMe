import Foundation
import SwiftData

/// Bestimmt, ob ein ``Artikel`` in einem bestimmten ``Geschaeft`` "verfügbar" ist —
/// Grundlage für den Standard-Filter beim Einkaufen (siehe
/// `EinkaufslisteView.verfuegbarkeitsgefiltert(_:)`).
///
/// Besitzt das Geschäft eigene Kategorien (``Geschaeft/verfuegbareKategorien(alleKategorien:)``
/// — direkt zugeordnet oder über den Geschäftstyp, siehe
/// ``ArtikelKategorie/geschaeftsTypen``), ist ein Artikel verfügbar, wenn
/// mindestens eine seiner Kategorien darin enthalten ist (ein Artikel kann
/// mehreren Kategorien angehören).
/// Besitzt das Geschäft keine eigenen Kategorien, lernt die App stattdessen aus der
/// Kaufhistorie: ein Artikel gilt als verfügbar, sobald er dort mindestens einmal
/// abgehakt/gekauft wurde (``ArtikelGeschaeftVerfuegbarkeit``) — das Abhaken eines
/// bislang unbekannten Artikels (bei eingeblendeten "alle Artikeln" während des
/// Einkaufs) macht ihn also unmittelbar auch für künftige Einkäufe in diesem
/// Geschäft "verfügbar".
///
/// **Seit 2026-08-04 kein Live-`KaufEintrag`-Scan mehr** (siehe
/// `docs/GESCHAEFTS_AGGREGATE.md`): las vorher bei jedem Aufruf direkt aus
/// ``KaufEintrag`` — dieselbe Kette, die auch der jederzeit lösch-/neu
/// anlegbaren ``Einkaufsliste`` hängt (``Einkaufsvorgang/einkaufsliste``).
/// ``ArtikelGeschaeftVerfuegbarkeit`` ist eine eigene, dauerhafte Tatsache,
/// unabhängig davon, ob der ursprüngliche ``Einkaufsvorgang`` noch existiert.
enum ArtikelVerfuegbarkeitService {
    static func istVerfuegbar(_ artikel: Artikel, in geschaeft: Geschaeft, context: ModelContext) -> Bool {
        let alleKategorien = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        let verfuegbareKategorien = geschaeft.verfuegbareKategorien(alleKategorien: alleKategorien)
        guard verfuegbareKategorien.isEmpty else {
            let kategorien = artikel.effektiveKategorien(context: context)
            return kategorien.contains(where: verfuegbareKategorien.contains)
        }
        return wurdeBereitsGekauft(artikel, in: geschaeft, context: context)
    }

    /// `true`, sobald ``artikel`` mindestens einmal in ``geschaeft`` als
    /// gekauft vermerkt wurde (``vermerkeGekauft(artikel:geschaeft:context:)``).
    /// Bewusst nicht `private` — direkt testbar unabhängig vom
    /// Kategorie-Kurzschluss in ``istVerfuegbar(_:in:context:)``.
    static func wurdeBereitsGekauft(_ artikel: Artikel, in geschaeft: Geschaeft, context: ModelContext) -> Bool {
        let artikelID = artikel.persistentModelID
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<ArtikelGeschaeftVerfuegbarkeit>(
            predicate: #Predicate { $0.artikel?.persistentModelID == artikelID && $0.geschaeft?.persistentModelID == geschaeftID }
        )
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }

    /// Vermerkt dauerhaft, dass ``artikel`` in ``geschaeft`` gekauft wurde —
    /// aufgerufen aus ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:kategorie:geschaeft:)``.
    /// Idempotent: eine bereits bekannte Kombination erzeugt keine weitere
    /// Zeile (reine Existenz-Tatsache, kein Zähler).
    static func vermerkeGekauft(artikel: Artikel, geschaeft: Geschaeft, context: ModelContext) {
        guard !wurdeBereitsGekauft(artikel, in: geschaeft, context: context) else { return }
        context.insert(ArtikelGeschaeftVerfuegbarkeit(artikel: artikel, geschaeft: geschaeft))
    }
}
