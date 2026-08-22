import Foundation
import SwiftData

/// Ein konkretes, kaufbares Produkt unter einem übergreifenden ``Artikel`` —
/// trägt den Preis, im Unterschied zum generischen Artikel selbst (GitHub
/// #47). Siehe `docs/ARTIKEL_PRODUKT_MODELL.md` für das vollständige Konzept.
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
    /// Kaskadierend: ein ``Preispunkt`` ist ohne sein Produkt fachlich
    /// bedeutungslos (Produkt-Pflicht, siehe ``Preispunkt``-Typ-Doku) — anders
    /// als früher (Nullify) überlebt die Preishistorie eine Produktlöschung
    /// deshalb bewusst nicht mehr.
    @Relationship(deleteRule: .cascade, inverse: \Preispunkt.produkt)
    var preispunkte: [Preispunkt] = []
    /// Rohwert für ``alternativeKlarnamen`` — durch `\n` getrennt gespeichert.
    /// Additiv-optional, analog ``Geschaeft/alternativeNamenRaw``.
    private var alternativeKlarnamenRaw: String?
    /// Vom Nutzer frei vergebene, zusätzliche Anzeigenamen dieses Produkts
    /// (z.B. „Andechser Vollmilch fett" für „Andechser Milch 3,5%") —
    /// geschäftsunabhängig, im Unterschied zu ``Produktname`` (Nachfolge von
    /// `ArtikelAlias.alternativerName`, aber auf Produkt- statt Artikel-Ebene,
    /// siehe `docs/ARTIKEL_PRODUKT_MODELL.md`).
    var alternativeKlarnamen: [String] {
        get { (alternativeKlarnamenRaw ?? "").split(separator: "\n").map(String.init) }
        set { alternativeKlarnamenRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }
    /// Markiert ein automatisch angelegtes Platzhalter-Produkt (siehe
    /// ``standardProdukt(fuer:context:)``) — entsteht, solange der Nutzer für
    /// einen Artikel noch kein eigenes, benanntes Produkt angelegt hat (kein
    /// UI dafür vor GitHub #47 Schritt 4). Unterscheidet dieses Platzhalter-
    /// Produkt zuverlässig von einem später vom Nutzer angelegten, echten
    /// Produkt mit zufällig demselben Namen wie der Artikel.
    var istStandard: Bool
    /// Rohspeicher für ``lamportZaehler`` — additiv optional, siehe
    /// ``GeschaeftTyp/lamportZaehler``.
    private var lamportZaehlerRaw: UInt64?
    /// Logischer Zeitstempel der letzten Änderung an ``name`` — Grundlage
    /// dafür, dass eine Umbenennung auch bereits synchronisierte Geräte
    /// erreicht (`SyncSnapshotImportService.mergeProdukte``); ``istStandard``
    /// hat aktuell keinen Bearbeitungs-Pfad für bestehende Produkte und bleibt
    /// deshalb bewusst außen vor. Siehe ``GeschaeftTyp/lamportZaehler`` für
    /// die volle Begründung.
    var lamportZaehler: UInt64 { lamportZaehlerRaw ?? 0 }

    init(name: String, artikel: Artikel?, elternProdukt: Produkt? = nil, istStandard: Bool = false) {
        self.id = UUID()
        self.name = name
        self.artikel = artikel
        self.elternProdukt = elternProdukt
        self.istStandard = istStandard
    }

    /// Aufgerufen, wenn der Anwender ``name`` dieses bereits bestehenden
    /// Produkts ändert (siehe `ProduktEditView`) — nie bei bloßer Neuanlage,
    /// siehe ``GeschaeftTyp/markiereGeaendert()``.
    func markiereGeaendert() {
        lamportZaehlerRaw = LamportClock.naechsterZaehler()
    }

    /// Übernimmt beim Sync-Merge einen tatsächlich neueren Zählerstand, siehe
    /// ``GeschaeftTyp/uebernehmeLamportZaehler(_:)``.
    func uebernehmeLamportZaehler(_ fremderZaehler: UInt64) {
        lamportZaehlerRaw = fremderZaehler
    }
}

extension Produkt {
    /// Merkt sich `name` als zusätzlichen ``alternativeKlarnamen``-Eintrag
    /// dieses Produkts, falls er weder dem eigentlichen ``name`` noch einem
    /// bereits bekannten alternativen Klarnamen entspricht — analog
    /// ``Artikel/alternativenNamenLernen(_:)``. Genutzt für den additiven
    /// Sync-Merge (``SyncSnapshotImportService``, GitHub #128).
    func alternativenKlarnamenLernen(_ name: String) {
        let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !getrimmt.isEmpty,
              getrimmt.localizedCaseInsensitiveCompare(self.name) != .orderedSame,
              !alternativeKlarnamen.contains(where: { $0.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame })
        else { return }
        alternativeKlarnamen.append(getrimmt)
    }


    /// Findet das Platzhalter-Produkt (``istStandard``) für `artikel` oder legt
    /// es an, falls es noch nicht existiert — Grundlage dafür, dass jeder
    /// ``Preispunkt``/``EinkaufslistenEintrag`` einem ``Produkt`` zugeordnet
    /// werden kann, auch bevor der Nutzer echte Produkte für einen Artikel
    /// angelegt hat (GitHub #47, Schritt 1/5). Genau ein Standard-Produkt pro
    /// Artikel (Upsert über ``istStandard`` + ``artikel``, nicht über den
    /// Namen — ein Nutzer könnte ein echtes Produkt zufällig identisch zum
    /// Artikel benennen).
    static func standardProdukt(fuer artikel: Artikel, context: ModelContext) -> Produkt {
        if let bestehendes = bestehendesStandardProdukt(fuer: artikel, context: context) {
            return bestehendes
        }
        let neues = Produkt(name: artikel.name, artikel: artikel, istStandard: true)
        context.insert(neues)
        return neues
    }

    /// Wie ``standardProdukt(fuer:context:)``, legt aber **keins** an, falls
    /// noch keins existiert (`nil` statt Neuanlage) — für reine Lese-/
    /// Vorschau-Zwecke wie `PreispunktService.vorhandenerPunktHeute(...)`
    /// (GitHub #47, Schritt 5/5), wo ein Seiteneffekt (Neuanlage während
    /// einer bloßen Prüfung, z.B. beim erneuten Verarbeiten eines Scans ohne
    /// Übernahme) unerwünscht wäre.
    static func bestehendesStandardProdukt(fuer artikel: Artikel, context: ModelContext) -> Produkt? {
        let artikelID = artikel.persistentModelID
        var deskriptor = FetchDescriptor<Produkt>(
            predicate: #Predicate { $0.istStandard && $0.artikel?.persistentModelID == artikelID }
        )
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
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

    /// Löst beim Belegscan ein konkretes ``Produkt`` für einen automatisch (per
    /// Artikel-Substring oder KI, nicht per Alias oder bereits bekanntem
    /// ``Produktname``) zugeordneten ``Artikel`` auf oder legt bei Bedarf eines
    /// neu an — Folgearbeit zu GitHub #47/#116, siehe
    /// `docs/ARTIKEL_PRODUKT_MODELL.md` → „Automatische Neuanlage beim
    /// Belegscan“. Ohne diese Auflösung würde ``PreispunktService.erfassen``
    /// sonst immer auf das geteilte ``standardProdukt(fuer:context:)`` des
    /// Artikels zurückfallen — verschiedene, noch nicht als ``Produktname``
    /// hinterlegte Produkte desselben Artikels würden sich dort gegenseitig die
    /// Preishistorie überschreiben.
    ///
    /// - `klarname`: vom Nutzer in der Prüf-Ansicht bestätigter Anzeigename
    ///   (Artikel-Textfeld). Weicht er vom generischen `artikel.name` ab (der
    ///   Nutzer hat also bewusst umbenannt), gilt er als Produktidentität —
    ///   Grundlage sowohl für `Produkt.name` bei Neuanlage als auch für den
    ///   Abgleich gegen bereits bestehende, gleichnamige Geschwister-Produkte
    ///   (verhindert Dubletten, wenn derselbe Klarname erneut auftaucht, z.B.
    ///   an einem anderen Geschäft).
    /// - Bleibt `klarname == artikel.name` (Normalfall, das Textfeld zeigt
    ///   standardmäßig den generischen Artikelnamen, siehe `docs/BELEGSCAN.md`),
    ///   trägt `klarname` keine unterscheidende Information — dann dient
    ///   stattdessen der rohe erkannte Bon-Text (`erkannterName`) als
    ///   Produktidentität, sonst würden mehrere tatsächlich unterschiedliche,
    ///   nur zufällig nicht umbenannte Produkte fälschlich unter demselben
    ///   Namen zusammengeführt.
    /// - `geschaeft`: bei bekanntem Geschäft entsteht zusätzlich ein
    ///   ``Produktname`` (`erkannterName` → Produkt, geschäftsspezifisch) —
    ///   ohne Geschäft nur das ``Produkt`` selbst (`Produkt.name` ist
    ///   geschäftsunabhängig, nur ``Produktname`` ist es nicht).
    @MainActor
    static func aufgeloestesOderNeuesProdukt(
        klarname: String, erkannterName: String, artikel: Artikel, geschaeft: Geschaeft?, context: ModelContext
    ) -> Produkt? {
        let getrimmterKlarname = klarname.trimmingCharacters(in: .whitespacesAndNewlines)
        let getrimmterErkannterName = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let produktIdentitaet = getrimmterKlarname.localizedCaseInsensitiveCompare(artikel.name) != .orderedSame
            ? getrimmterKlarname
            : getrimmterErkannterName
        guard !produktIdentitaet.isEmpty else { return nil }

        let produkt: Produkt
        if let bestehendes = artikel.produkte.first(where: {
            !$0.istStandard
                && ($0.name.localizedCaseInsensitiveContains(produktIdentitaet)
                    || produktIdentitaet.localizedCaseInsensitiveContains($0.name))
        }) {
            produkt = bestehendes
        } else {
            produkt = Produkt(name: produktIdentitaet, artikel: artikel)
            context.insert(produkt)
        }

        if let geschaeft, !getrimmterErkannterName.isEmpty,
           !produkt.produktnamen.contains(where: {
               $0.geschaeft == geschaeft && $0.name.localizedCaseInsensitiveCompare(getrimmterErkannterName) == .orderedSame
           }) {
            context.insert(Produktname(name: getrimmterErkannterName, produkt: produkt, geschaeft: geschaeft))
        }
        return produkt
    }
}
