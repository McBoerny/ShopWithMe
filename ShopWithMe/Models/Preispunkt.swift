import Foundation
import SwiftData

/// Ein einzelner beobachteter Preis eines Artikels in einem Geschäft — die
/// Preishistorie-Rolle, die früher Teil von ``KaufEintrag`` war (siehe
/// `docs/BELEGSCAN.md`, GitHub #76). Entsteht ausschließlich, wenn Belegscan
/// oder Preisschild-Scan tatsächlich einen Preis erfassen, und nur, wenn sich
/// dieser Preis gegenüber dem zuletzt bekannten ``Preispunkt`` für dasselbe
/// (``produkt``, ``geschaeft``)-Paar unterscheidet (Slowly-Changing-
/// Dimension-Muster „nur Änderungen") — reines Abhaken ohne Preis und ein
/// unveränderter Preis erzeugen keinen neuen Eintrag, siehe
/// ``PreispunktService/erfassen(preis:produkt:geschaeft:datum:produktName:alternativerName:context:)``.
///
/// Anders als ``KaufEintrag`` ohne Bezug zu einem ``Einkaufsvorgang`` — ein
/// Preis ist auch ohne laufenden Einkauf sinnvoll (Preisschild-Scan).
///
/// **Produkt-Pflicht:** ein ``Preispunkt`` hängt fachlich nie direkt an einem
/// ``Artikel``, sondern immer an einem konkreten ``Produkt`` (``artikel`` ist
/// nur noch die abgeleitete ``produkt``/``Produkt/artikel``-Kette, siehe
/// ``artikel``). Ein Preis ganz ohne Produkt-Zuordnung („Ohne
/// Artikel-Zuordnung", der frühere Freitext-Fall bei Scans ohne Treffer) wird
/// nicht mehr angelegt — ``PreispunktService`` erzwingt ein aufgelöstes
/// ``Produkt`` bereits vor der Erfassung. ``produkt`` bleibt im Modell
/// dennoch optional, da SwiftData-Relationships auf Storage-Ebene ohnehin
/// immer nullable sind (kein struktureller Storage-Vorteil durch ein
/// non-optionales Feld) — siehe ``geschaeft`` für dieselbe Begründung.
@Model
final class Preispunkt {
    /// Eindeutige Kennung.
    var id: UUID
    /// Das konkrete Produkt, dessen Preis beobachtet wurde (GitHub #47) —
    /// inverse zu ``Produkt/preispunkte``. Der eigentliche Preisträger (siehe
    /// `docs/ARTIKEL_PRODUKT_MODELL.md`) — seit GitHub #131 die einzige
    /// Zuordnung, ``artikel`` ist nur noch davon abgeleitet.
    var produkt: Produkt?
    /// Das Geschäft, in dem der Preis beobachtet wurde. Im Modell weiterhin
    /// optional (SwiftData-Relationships sind auf Storage-Ebene ohnehin immer
    /// optional, siehe `docs/ARTIKEL_PRODUKT_MODELL.md`) — die Geschäfts-
    /// Pflicht bei der Preiserfassung (GitHub #128, Pseudo-Geschäft bei
    /// Bedarf) wird bewusst nur auf Service-Ebene durchgesetzt
    /// (``PreispunktService/erfassen(preis:produkt:geschaeft:datum:produktName:alternativerName:context:)``),
    /// nicht hier — ein non-optionales Modellfeld hätte hier ohne echten
    /// Storage-Vorteil eine riskante strukturelle SwiftData-Migration
    /// erzwungen.
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
    /// ``produkt`` — siehe ``anzeigeName``.
    var alternativerName: String?
    /// Name des Geschäfts zum Beobachtungszeitpunkt (dauerhafter Schnappschuss)
    /// — bleibt bestehen, weil der Peer-Sync ohne zentrale Autorität einen
    /// Preispunkt empfangen kann, dessen ``geschaeft`` auf diesem Gerät
    /// niemals auflösbar ist (das referenzierte Geschäft wurde beim Sender
    /// gelöscht, bevor es je zu diesem Gerät synchronisiert wurde) — siehe
    /// `docs/DATENSYNCHRONISATION.md` §4.5. ``produkt``/``Produkt/artikel``
    /// brauchen kein Pendant: ``Produkt`` kaskadiert seit derselben
    /// Produkt-Pflicht mit ``Preispunkt``, ein lebender Preispunkt hat also
    /// immer ein lebendes ``produkt``.
    var geschaeftNameSnapshot: String

    init(
        produkt: Produkt?,
        geschaeft: Geschaeft?,
        preis: Decimal,
        datum: Date = Date(),
        produktName: String? = nil,
        alternativerName: String? = nil
    ) {
        self.id = UUID()
        self.produkt = produkt
        self.geschaeft = geschaeft
        self.preis = preis
        self.datum = datum
        self.produktName = produktName
        self.alternativerName = alternativerName
        self.geschaeftNameSnapshot = geschaeft?.name ?? ""
    }
}

extension Preispunkt {
    /// Der übergreifende Artikel des ``produkt``s — abgeleitet, kein eigenes
    /// gespeichertes Feld mehr (siehe Typ-Doku „Produkt-Pflicht“).
    var artikel: Artikel? { produkt?.artikel }

    /// Der Name von ``produkt``, sofern es noch tatsächlich existiert (nicht
    /// bereits eine baumelnde Referenz auf ein gelöschtes Produkt ist — siehe
    /// `docs/DATABASE_CONCURRENCY.md`), sonst der rohe ``produktName`` vom
    /// Scan, falls vorhanden — beides sichere, keine baumelnde Referenz
    /// lesende Quellen (anders als früher gibt es keinen dauerhaften
    /// Namens-Schnappschuss mehr, da ``produkt`` einen lebenden Preispunkt
    /// dank Cascade-Löschregel nie überlebt).
    var produktNameSicher: String {
        guard let produkt, let context = modelContext, context.existiertNochImStore(produkt) else {
            return produktName ?? ""
        }
        return produkt.name
    }

    /// Wie ``produktNameSicher``, für ``geschaeft``/``geschaeftNameSnapshot``.
    var geschaeftNameSicher: String {
        guard let geschaeft, let context = modelContext, context.existiertNochImStore(geschaeft) else {
            return geschaeftNameSnapshot
        }
        return geschaeft.name
    }

    /// Der für Anzeigen (z.B. `PreisHistorieZeile`) tatsächlich zu verwendende
    /// Artikelname, mit ``alternativerName`` an oberster Priorität, sonst
    /// ``produktName`` (Original vom Kassenbon), dann ``produktNameSicher``.
    var anzeigeName: String {
        if let alternativerName, !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alternativerName
        }
        let name = produktName ?? produktNameSicher
        return name.isEmpty ? "Unbekannter Artikel" : name
    }
}
