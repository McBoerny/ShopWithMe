import Foundation
import SwiftData

/// Dauerhafter, von ``Einkaufsvorgang``/``Einkaufsliste`` unabhängiger
/// Besuchsprotokoll-Eintrag — Grundlage für ``GeschaeftBesuchsProtokollView``.
///
/// **Entkoppelt seit 2026-08-04** (vormals direkt aus ``Einkaufsvorgang`` gelesen,
/// siehe `docs/GESCHAEFTS_AGGREGATE.md`): eine ``Einkaufsliste`` ist ein
/// dynamisches, jederzeit lösch- und neu anlegbares Planungswerkzeug — ob ein
/// vergangener Ladenbesuch im Protokoll sichtbar bleibt, darf nicht davon
/// abhängen, ob die Liste, aus der heraus damals eingekauft wurde, noch
/// existiert. `id` übernimmt bewusst die `id` des ursprünglichen
/// ``Einkaufsvorgang``s (siehe ``GeschaeftBesuchService/erfassen(fuer:context:)``)
/// — macht Dedup beim Sync-Merge trivial (Union nach `id`, analog
/// ``Preispunkt``) und die einmalige Bestandsmigration eindeutig.
@Model
final class GeschaeftBesuch {
    var id: UUID
    var geschaeft: Geschaeft?
    var startZeit: Date
    var endZeit: Date
    /// Anzahl der in diesem Besuch gekauften Produkte (``KaufEintrag``-Anzahl
    /// des ursprünglichen ``Einkaufsvorgang``s zum Abschlusszeitpunkt).
    var anzahlProdukte: Int

    init(id: UUID = UUID(), geschaeft: Geschaeft?, startZeit: Date, endZeit: Date, anzahlProdukte: Int) {
        self.id = id
        self.geschaeft = geschaeft
        self.startZeit = startZeit
        self.endZeit = endZeit
        self.anzahlProdukte = anzahlProdukte
    }
}

enum GeschaeftBesuchService {
    /// Erfasst einen abgeschlossenen ``Einkaufsvorgang`` als dauerhaften
    /// ``GeschaeftBesuch`` — aufgerufen direkt nach ``Einkaufsvorgang/abschliessen(am:zaehleAlsBesuch:)``
    /// an denselben Stellen wie ``AbteilungsDistanzService/verarbeiteEinkauf(_:context:)``
    /// (``EinkaufenView``). Wirkungslos ohne ``Einkaufsvorgang/geschaeft`` (kein
    /// sinnvoller Protokoll-Eintrag ohne Laden) oder ohne gesetztes `endZeit`
    /// (noch nicht abgeschlossen). Duplikat-Vorgänge desselben physischen
    /// Besuchs (``Einkaufsvorgang/abschliessen(am:zaehleAlsBesuch:)``,
    /// `zaehleAlsBesuch: false``) werden bewusst NICHT hier aufgerufen — sie
    /// repräsentieren denselben Besuch, ein zweiter Protokoll-Eintrag würde ihn
    /// doppelt zählen.
    static func erfassen(fuer vorgang: Einkaufsvorgang, context: ModelContext) {
        guard let geschaeft = vorgang.geschaeft, let endZeit = vorgang.endZeit else { return }
        let vorgangID = vorgang.id
        var deskriptor = FetchDescriptor<GeschaeftBesuch>(predicate: #Predicate { $0.id == vorgangID })
        deskriptor.fetchLimit = 1
        guard ((try? context.fetchCount(deskriptor)) ?? 0) == 0 else { return }
        context.insert(GeschaeftBesuch(
            id: vorgangID, geschaeft: geschaeft, startZeit: vorgang.startZeit, endZeit: endZeit,
            anzahlProdukte: vorgang.kaufEintraege.count
        ))
    }
}
