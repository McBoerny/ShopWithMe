import Foundation
import SwiftData

/// Ein konkretes, kaufbares Produkt unter einem übergreifenden ``Artikel`` —
/// trägt den Preis, im Unterschied zum generischen Artikel selbst (GitHub
/// #47). Siehe `docs/ARTIKEL_PRODUKT_MODELL.md` für das vollständige Konzept
/// inkl. Abgrenzung zu ``ArtikelAlias``.
///
/// Rekursiv selbstreferenzierend über ``elternProdukt``/``unterProdukte``
/// (z.B. für Packungsgrößen-Varianten desselben Produkts) — hat ein Produkt
/// Unter-Produkte, trägt es selbst keine eigenen ``preispunkte`` mehr,
/// sondern kumuliert die Preise seiner Blätter (siehe
/// `docs/ARTIKEL_PRODUKT_MODELL.md`, Regel 2).
@Model
final class Produkt {
    /// Eindeutige Kennung.
    @Attribute(.unique) var id: UUID
    /// Anzeigename des Produkts, z.B. "Paradontol Zahncreme".
    var name: String
    /// Der übergreifende Artikel, z.B. "Zahnpasta".
    var artikel: Artikel?
    /// Übergeordnetes Produkt, falls dies eine Variante ist (z.B. eine
    /// Packungsgröße eines anderen Produkts).
    var elternProdukt: Produkt?
    /// Rekursive Unter-Produkte (z.B. Packungsgrößen) — Löschen dieses
    /// Produkts löscht sie mit, sie sind ohne ihr Eltern-Produkt bedeutungslos.
    @Relationship(deleteRule: .cascade, inverse: \Produkt.elternProdukt)
    var unterProdukte: [Produkt] = []
    /// Geschäftsabhängige Namen dieses Produkts (GitHub #47/#111-Abgrenzung) —
    /// siehe ``Produktname``.
    @Relationship(deleteRule: .cascade, inverse: \Produktname.produkt)
    var produktnamen: [Produktname] = []
    /// Preishistorie dieses Produkts — inverse zu ``Preispunkt/produkt``.
    /// Nullify, dieselbe Begründung wie ``Artikel/preispunkte``
    /// (``Preispunkt/artikelNameSnapshot``/`produktNameSnapshot` halten den
    /// Namen dauerhaft fest).
    @Relationship(deleteRule: .nullify, inverse: \Preispunkt.produkt)
    var preispunkte: [Preispunkt] = []
    /// Markiert ein automatisch angelegtes Platzhalter-Produkt (siehe
    /// ``standardProdukt(fuer:context:)``) — entsteht, solange der Nutzer für
    /// einen Artikel noch kein eigenes, benanntes Produkt angelegt hat (kein
    /// UI dafür vor GitHub #47 Schritt 4). Unterscheidet dieses Platzhalter-
    /// Produkt zuverlässig von einem später vom Nutzer angelegten, echten
    /// Produkt mit zufällig demselben Namen wie der Artikel.
    var istStandard: Bool

    init(name: String, artikel: Artikel?, elternProdukt: Produkt? = nil, istStandard: Bool = false) {
        self.id = UUID()
        self.name = name
        self.artikel = artikel
        self.elternProdukt = elternProdukt
        self.istStandard = istStandard
    }
}

extension Produkt {
    /// Findet das Platzhalter-Produkt (``istStandard``) für `artikel` oder legt
    /// es an, falls es noch nicht existiert — Grundlage dafür, dass jeder
    /// ``Preispunkt``/``EinkaufslistenEintrag`` einem ``Produkt`` zugeordnet
    /// werden kann, auch bevor der Nutzer echte Produkte für einen Artikel
    /// angelegt hat (GitHub #47, Schritt 1/5). Genau ein Standard-Produkt pro
    /// Artikel (Upsert über ``istStandard`` + ``artikel``, nicht über den
    /// Namen — ein Nutzer könnte ein echtes Produkt zufällig identisch zum
    /// Artikel benennen).
    static func standardProdukt(fuer artikel: Artikel, context: ModelContext) -> Produkt {
        let artikelID = artikel.persistentModelID
        var deskriptor = FetchDescriptor<Produkt>(
            predicate: #Predicate { $0.istStandard && $0.artikel?.persistentModelID == artikelID }
        )
        deskriptor.fetchLimit = 1
        if let bestehendes = try? context.fetch(deskriptor).first {
            return bestehendes
        }
        let neues = Produkt(name: artikel.name, artikel: artikel, istStandard: true)
        context.insert(neues)
        return neues
    }

    /// Alle ``Preispunkt``e dieses Produkts UND (rekursiv) aller
    /// ``unterProdukte`` — Grundlage für ``minimum``/``maximum`` (GitHub #47,
    /// Schritt 3/5). Summiert bewusst immer über den gesamten Teilbaum statt
    /// nur über Blätter: bleibt dadurch auch dann korrekt, wenn ein
    /// Nicht-Blatt entgegen der Regel in `docs/ARTIKEL_PRODUKT_MODELL.md`
    /// (Regel 2) doch einen eigenen ``Preispunkt`` trägt.
    var preispunkteRekursiv: [Preispunkt] {
        preispunkte + unterProdukte.flatMap(\.preispunkteRekursiv)
    }

    /// Niedrigster erfasster Preis über ``preispunkteRekursiv``, `nil` falls
    /// keiner der Einträge einen Preis hat.
    var minimum: Decimal? { preispunkteRekursiv.map(\.preis).min() }
    /// Höchster erfasster Preis über ``preispunkteRekursiv``.
    var maximum: Decimal? { preispunkteRekursiv.map(\.preis).max() }
}
