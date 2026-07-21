import Foundation
import SwiftData

/// Ein vom Anwender beim Belegscan dauerhaft ignorierter, erkannter Artikelname —
/// verhindert, dass dieselbe Position bei künftigen Scans **desselben Geschäfts**
/// erneut in der Prüf-Ansicht (``BelegScanView``) auftaucht (siehe
/// `docs/BELEGSCAN.md` → „Dauerhaft ignorierte Artikel pro Geschäft“).
///
/// Anders als ``IgnorierterGeschaeftsVorschlag`` referenziert dieser Typ ``Geschaeft``
/// über eine echte Relationship: Zum Zeitpunkt des Ignorierens steht das Geschäft
/// (``BelegScanView/erkanntesGeschaeft``) bereits fest und ist persistiert — es gibt
/// hier keinen Fall wie den noch unbekannten, per Apple Maps erkannten Laden bei der
/// Standort-Erkennung.
@Model
final class IgnorierterArtikel {
    /// Der auf dem Kassenbon erkannte Rohtext, der ignoriert werden soll.
    var erkannterName: String
    /// Das Geschäft, für das dieser Name ignoriert wird — Ignorieren ist bewusst pro
    /// Geschäft skaliert, nicht global, da Artikelbezeichnungen auf Kassenbons je
    /// Geschäft unterschiedlich formatiert sind.
    var geschaeft: Geschaeft?
    var ignoriertAm: Date

    init(erkannterName: String, geschaeft: Geschaeft?) {
        self.erkannterName = erkannterName
        self.geschaeft = geschaeft
        self.ignoriertAm = .now
    }
}

extension IgnorierterArtikel {
    /// Prüft, ob `erkannterName` für `geschaeft` als dauerhaft ignoriert hinterlegt
    /// ist (Namensgleichheit ODER beidseitiger Teilstring, case-insensitive — analog
    /// den bestehenden Namens-Abgleichen im Projekt, z.B.
    /// ``GeschaeftErkennungService``/``Geschaeft/passendes(fuerErkannterName:unter:)``).
    /// Liefert `false` ohne `geschaeft` (kein Geschäft, keine Skalierung möglich) —
    /// Positionen werden dann nicht gefiltert.
    static func istIgnoriert(_ erkannterName: String, geschaeft: Geschaeft?, unter ignorierte: [IgnorierterArtikel]) -> Bool {
        guard let geschaeft else { return false }
        let erkannterName = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !erkannterName.isEmpty else { return false }
        return ignorierte.contains { eintrag in
            eintrag.geschaeft?.persistentModelID == geschaeft.persistentModelID
                && (eintrag.erkannterName.localizedCaseInsensitiveCompare(erkannterName) == .orderedSame
                    || eintrag.erkannterName.localizedCaseInsensitiveContains(erkannterName)
                    || erkannterName.localizedCaseInsensitiveContains(eintrag.erkannterName))
        }
    }
}
