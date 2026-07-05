import Foundation
import SwiftData

/// Die Mitgliedschaft eines ``Artikel``s auf einer ``Einkaufsliste`` — mit einer für
/// diese Liste eigenen Menge und temporären Notiz.
///
/// Ein Artikel kann gleichzeitig auf mehreren Listen stehen (je ein eigener
/// Eintrag); wird er auf einer Liste abgehakt (siehe
/// ``Einkaufsvorgang/artikelAbhaken(_:context:)``), wird nur der Eintrag dieser
/// Liste gelöscht, andere Listen bleiben unberührt.
@Model
final class EinkaufslistenEintrag {
    /// Eindeutige Kennung.
    var id: UUID
    /// Die Liste, auf der dieser Eintrag steht.
    var einkaufsliste: Einkaufsliste?
    /// Der Artikel, um den es geht.
    var artikel: Artikel?
    /// Aktuell auf dieser Liste gewünschte Menge — startet bei
    /// ``Artikel/mengenSchritt`` und wird beim Einkaufen in dessen Schritten
    /// verändert (siehe ``mengeErhoehen()``/``mengeVerringern()``).
    var menge: Double
    /// Temporäre, listenspezifische Notiz (z.B. "diesmal die große Packung") —
    /// anders als ``Artikel/notiz`` nicht dauerhaft, sondern endet mit diesem Eintrag.
    var notiz: String?
    /// Zeitpunkt, zu dem der Artikel auf diese Liste gesetzt wurde.
    var erstelltAm: Date

    init(einkaufsliste: Einkaufsliste?, artikel: Artikel?, menge: Double, notiz: String? = nil) {
        self.id = UUID()
        self.einkaufsliste = einkaufsliste
        self.artikel = artikel
        self.menge = menge
        self.notiz = notiz
        self.erstelltAm = Date()
    }
}

extension EinkaufslistenEintrag {
    /// Erhöht ``menge`` um ``Artikel/mengenSchritt`` — Reaktion auf eine Swipe-Geste
    /// in der Einkaufsliste (siehe ``EinkaufenView``).
    func mengeErhoehen() {
        guard let schritt = artikel?.mengenSchritt else { return }
        menge += schritt
    }

    /// Verringert ``menge`` um ``Artikel/mengenSchritt``, ohne unter diesen Wert zu
    /// fallen — Reaktion auf eine Swipe-Geste in der Einkaufsliste (siehe
    /// ``EinkaufenView``).
    func mengeVerringern() {
        guard let schritt = artikel?.mengenSchritt else { return }
        menge = max(schritt, menge - schritt)
    }
}
