import Foundation
import SwiftData

/// Dauerhafte, von ``Einkaufsvorgang``/``Einkaufsliste`` unabhängige Tatsache:
/// „``artikel`` wurde mindestens einmal in ``geschaeft`` gekauft" — Grundlage für
/// ``ArtikelVerfuegbarkeitService``.
///
/// **Entkoppelt seit 2026-08-04** (vormals ein Live-`KaufEintrag`-Scan, siehe
/// `docs/GESCHAEFTS_AGGREGATE.md`): eine ``Einkaufsliste`` ist ein dynamisches,
/// jederzeit lösch- und neu anlegbares Planungswerkzeug — ob ein Artikel in einem
/// Geschäft erhältlich ist, darf davon nicht abhängen, ob die Liste, über die er
/// zufällig einmal gekauft wurde, noch existiert. Eine Zeile pro (``Artikel``,
/// ``Geschaeft``)-Paar, reine Existenz-Tatsache ohne Zähler/Zeitstempel — anders
/// als ``WarengruppenDistanz`` gibt es hier nichts zu mitteln, ein Peer-Beitrag ist
/// entweder schon bekannt oder wird einmalig ergänzt (siehe
/// ``SyncSnapshotImportService``).
@Model
final class ArtikelGeschaeftVerfuegbarkeit {
    /// Eindeutige Kennung.
    var id: UUID
    var artikel: Artikel?
    var geschaeft: Geschaeft?

    init(artikel: Artikel?, geschaeft: Geschaeft?) {
        self.id = UUID()
        self.artikel = artikel
        self.geschaeft = geschaeft
    }
}
