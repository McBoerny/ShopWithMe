import Foundation
import SwiftData

/// Bestimmt, ob ein ``Artikel`` in einem bestimmten ``Geschaeft`` "verfügbar" ist —
/// Grundlage für den Standard-Filter beim Einkaufen (siehe
/// `EinkaufslisteView.verfuegbarkeitsgefiltert(_:)`).
///
/// Besitzt das Geschäft eigene Abteilungen (``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)``
/// — direkt zugeordnet oder über den Geschäftstyp, siehe
/// ``Abteilung/geschaeftsTypen``), ist ein Artikel verfügbar, wenn
/// mindestens eine seiner Abteilungen darin enthalten ist (ein Artikel kann
/// mehreren Abteilungen angehören).
/// Besitzt das Geschäft keine eigenen Abteilungen, lernt die App stattdessen aus der
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
    /// `alleAbteilungen` bewusst als Parameter statt intern gefetcht — der
    /// einzige Aufrufer (``EinkaufslistenAnzeigeService/verfuegbarkeitsgefiltert(_:geschaeft:zeigeAlleArtikel:context:)``)
    /// ruft diese Funktion pro Listenelement auf; ein interner Fetch hätte pro
    /// Element einen eigenen `Abteilung`-Roundtrip bedeutet statt einmal pro
    /// Aufruf des Aufrufers (Performance-Fund #152).
    static func istVerfuegbar(_ artikel: Artikel, in geschaeft: Geschaeft, alleAbteilungen: [Abteilung], context: ModelContext) -> Bool {
        let verfuegbareAbteilungen = geschaeft.verfuegbareAbteilungen(alleAbteilungen: alleAbteilungen)
        guard verfuegbareAbteilungen.isEmpty else {
            let abteilungen = artikel.effektiveAbteilungen(context: context)
            return abteilungen.contains(where: verfuegbareAbteilungen.contains)
        }
        return wurdeBereitsGekauft(artikel, in: geschaeft, context: context)
    }

    /// `true`, sobald ``artikel`` mindestens einmal in ``geschaeft`` als
    /// gekauft vermerkt wurde (``vermerkeGekauft(artikel:geschaeft:context:)``).
    /// Bewusst nicht `private` — direkt testbar unabhängig vom
    /// Abteilung-Kurzschluss in ``istVerfuegbar(_:in:context:)``.
    static func wurdeBereitsGekauft(_ artikel: Artikel, in geschaeft: Geschaeft, context: ModelContext) -> Bool {
        let artikelID = artikel.persistentModelID
        let geschaeftID = geschaeft.persistentModelID
        let deskriptor = FetchDescriptor<ArtikelGeschaeftVerfuegbarkeit>(
            predicate: #Predicate { $0.artikel?.persistentModelID == artikelID && $0.geschaeft?.persistentModelID == geschaeftID }
        )
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }

    /// Vermerkt dauerhaft, dass ``artikel`` in ``geschaeft`` gekauft wurde —
    /// aufgerufen aus ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:abteilung:geschaeft:)``.
    /// Idempotent: eine bereits bekannte Kombination erzeugt keine weitere
    /// Zeile (reine Existenz-Tatsache, kein Zähler).
    static func vermerkeGekauft(artikel: Artikel, geschaeft: Geschaeft, context: ModelContext) {
        guard !wurdeBereitsGekauft(artikel, in: geschaeft, context: context) else { return }
        context.insert(ArtikelGeschaeftVerfuegbarkeit(artikel: artikel, geschaeft: geschaeft))
    }
}
