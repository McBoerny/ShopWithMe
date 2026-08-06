import Foundation
import SwiftData

/// Ein einzelner beobachteter Preis eines Artikels in einem Geschäft — die
/// Preishistorie-Rolle, die früher Teil von ``KaufEintrag`` war (siehe
/// `docs/BELEGSCAN.md`, GitHub #76). Entsteht ausschließlich, wenn Belegscan
/// oder Preisschild-Scan tatsächlich einen Preis erfassen, und nur, wenn sich
/// dieser Preis gegenüber dem zuletzt bekannten ``Preispunkt`` für dasselbe
/// (``artikel``, ``geschaeft``)-Paar unterscheidet (Slowly-Changing-
/// Dimension-Muster „nur Änderungen") — reines Abhaken ohne Preis und ein
/// unveränderter Preis erzeugen keinen neuen Eintrag, siehe
/// ``PreispunktService/erfassen(preis:artikel:geschaeft:datum:produktName:alternativerName:context:)``.
///
/// Anders als ``KaufEintrag`` ohne Bezug zu einem ``Einkaufsvorgang`` — ein
/// Preis ist auch ohne laufenden Einkauf sinnvoll (Preisschild-Scan).
@Model
final class Preispunkt {
    /// Eindeutige Kennung.
    var id: UUID
    /// Der Artikel, dessen Preis beobachtet wurde (kann `nil` werden, wenn der
    /// Artikel später gelöscht wird).
    var artikel: Artikel?
    /// Das konkrete Produkt, dessen Preis beobachtet wurde (GitHub #47) —
    /// inverse zu ``Produkt/preispunkte``. Fachlich der eigentliche
    /// Preisträger (siehe `docs/ARTIKEL_PRODUKT_MODELL.md`); ``artikel``
    /// bleibt zusätzlich gepflegt als der über viele bestehende Stellen
    /// bereits genutzte, direkte Bezug zum übergreifenden Artikel.
    var produkt: Produkt?
    /// Das Geschäft, in dem der Preis beobachtet wurde.
    var geschaeft: Geschaeft?
    /// Der zuletzt beobachtete Preis.
    var preis: Decimal
    /// Zeitpunkt der (letzten) Beobachtung dieses Preises.
    var datum: Date
    /// Genauer Produkt-/Markenname vom Kassenbon/Preisschild, falls er sich vom
    /// (ggf. generischen) ``artikel`` unterscheidet — siehe ehemals
    /// `KaufEintrag.produktName`, `docs/BELEGSCAN.md`.
    var produktName: String?
    /// Vom Nutzer vergebener alternativer Anzeigename, siehe ehemals
    /// `KaufEintrag.alternativerName`. Hat Vorrang vor ``produktName``/
    /// ``artikel``/``artikelNameSnapshot`` — siehe ``anzeigeName``.
    var alternativerName: String?
    /// Name des Artikels zum Beobachtungszeitpunkt (dauerhafter Schnappschuss).
    var artikelNameSnapshot: String
    /// Name des Geschäfts zum Beobachtungszeitpunkt (dauerhafter Schnappschuss).
    var geschaeftNameSnapshot: String

    init(
        artikel: Artikel?,
        produkt: Produkt? = nil,
        geschaeft: Geschaeft?,
        preis: Decimal,
        datum: Date = Date(),
        produktName: String? = nil,
        alternativerName: String? = nil
    ) {
        self.id = UUID()
        self.artikel = artikel
        self.produkt = produkt
        self.geschaeft = geschaeft
        self.preis = preis
        self.datum = datum
        self.produktName = produktName
        self.alternativerName = alternativerName
        self.artikelNameSnapshot = artikel?.name ?? ""
        self.geschaeftNameSnapshot = geschaeft?.name ?? ""
    }
}

extension Preispunkt {
    /// Der Name von ``artikel``, sofern er noch tatsächlich existiert (nicht
    /// bereits eine baumelnde Referenz auf einen gelöschten Artikel ist —
    /// siehe `docs/DATABASE_CONCURRENCY.md`), sonst der dauerhafte
    /// ``artikelNameSnapshot``.
    var artikelNameSicher: String {
        guard let artikel, let context = modelContext, context.existiertNochImStore(artikel) else {
            return artikelNameSnapshot
        }
        return artikel.name
    }

    /// Wie ``artikelNameSicher``, für ``geschaeft``/``geschaeftNameSnapshot``.
    var geschaeftNameSicher: String {
        guard let geschaeft, let context = modelContext, context.existiertNochImStore(geschaeft) else {
            return geschaeftNameSnapshot
        }
        return geschaeft.name
    }

    /// Der für Anzeigen (z.B. `PreisHistorieZeile`) tatsächlich zu verwendende
    /// Artikelname, mit ``alternativerName`` an oberster Priorität, sonst
    /// ``produktName`` (Original vom Kassenbon), dann ``artikelNameSicher``.
    var anzeigeName: String {
        if let alternativerName, !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alternativerName
        }
        let name = produktName ?? artikelNameSicher
        return name.isEmpty ? "Unbekannter Artikel" : name
    }
}
