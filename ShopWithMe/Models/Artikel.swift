import Foundation
import SwiftData

/// Maßeinheit, in der ``EinkaufslistenEintrag/menge``/``Artikel/mengenSchritt``
/// geführt werden — Gewicht, Volumen oder Stück.
enum Einheit: String, Codable, CaseIterable, Identifiable {
    case stueck
    case kilogramm
    case gramm
    case liter
    case milliliter

    var id: String { rawValue }

    /// Anzeigename in Auswahllisten (z.B. Picker in ``ArtikelEditView``).
    var anzeigename: String {
        switch self {
        case .stueck: return "Stück"
        case .kilogramm: return "Kilogramm"
        case .gramm: return "Gramm"
        case .liter: return "Liter"
        case .milliliter: return "Milliliter"
        }
    }

    /// Kompakte Kurzform für die Anzeige in der Einkaufsliste (z.B. "2 kg").
    var kurzform: String {
        switch self {
        case .stueck: return "Stk."
        case .kilogramm: return "kg"
        case .gramm: return "g"
        case .liter: return "l"
        case .milliliter: return "ml"
        }
    }
}

/// Ein einkaufbarer Artikel (z.B. "Vollmilch").
///
/// Ein Artikel kann mehreren ``ArtikelKategorie``n gleichzeitig angehören (siehe
/// ``kategorien``) — die Kategorien können jederzeit über die
/// Bearbeiten-Bildschirme geändert werden.
@Model
final class Artikel {
    /// Eindeutige Kennung. `@Attribute(.unique)` seit GitHub #102 (vorher
    /// unindiziert, jeder ID-Lookup im Sync-Merge war ein Full-Table-Scan) —
    /// sicher eingeführt erst nach Prüfung des realen Bestands per
    /// ``ModellIDDuplikatService`` auf bereits bestehende Duplikate.
    @Attribute(.unique) var id: UUID
    /// Anzeigename des Artikels.
    var name: String
    /// SF-Symbol-Name — aktuell in keiner UI mehr angezeigt/editierbar, bleibt als
    /// Feld für eine mögliche künftige Wiederverwendung erhalten.
    var symbolName: String
    /// Farbe als Hex-String (z.B. `"#34C759"`) — aktuell in keiner UI mehr
    /// angezeigt/editierbar, bleibt als Feld für eine mögliche künftige
    /// Wiederverwendung erhalten.
    var farbeHex: String
    /// Die (einzelne) Kategorie dieses Artikels — seit Einführung von
    /// ``kategorien`` (Mehrfachzuordnung) nicht mehr direkt von außen gesetzt,
    /// bleibt aber als Migrations-Fallback für vor diesem Zeitpunkt angelegte
    /// Artikel sowie als führende (erste) Kategorie erhalten — von ``kategorien``
    /// synchron gehalten.
    var kategorie: ArtikelKategorie?
    /// Rohspeicher für ``kategorien`` — bewusst `internal` (nicht `private`),
    /// damit ``ArtikelKategorie`` per `inverse:`-KeyPath darauf verweisen kann.
    /// Nicht direkt verwenden, stattdessen ``kategorien``.
    @Relationship(inverse: \ArtikelKategorie.zugeordneteArtikel)
    var kategorienRaw: [ArtikelKategorie] = []
    /// Zeitpunkt der Anlage.
    var erstelltAm: Date
    /// Optionale, dauerhafte Notiz, z.B. bevorzugte Marke.
    var notiz: String?
    /// Rohwert für ``alternativeNamen`` — durch `\n` getrennt gespeichert.
    /// Additiv-optional, analog ``Geschaeft/alternativeNamenRaw``.
    private var alternativeNamenRaw: String?
    /// Generische Synonyme dieses Artikels (z.B. „Fettreiche Milch" für
    /// „Vollmilch") — geschäfts- und produktunabhängig, frei vom Nutzer
    /// gepflegt (``ArtikelEditView``) und Teil der Substring-Matchstufe in
    /// ``ArtikelZuordnungsService`` (Nachfolge von `ArtikelAlias`, siehe
    /// `docs/ARTIKEL_PRODUKT_MODELL.md`).
    var alternativeNamen: [String] {
        get { (alternativeNamenRaw ?? "").split(separator: "\n").map(String.init) }
        set { alternativeNamenRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }

    /// Die Einkaufslisten-Mitgliedschaften dieses Artikels — je ``Einkaufsliste``,
    /// auf der er aktuell steht, ein Eintrag (siehe ``EinkaufslistenEintrag``). Wird
    /// der Artikel gelöscht, verschwinden auch seine Mitgliedschaften.
    @Relationship(deleteRule: .cascade, inverse: \EinkaufslistenEintrag.artikel)
    var einkaufslistenEintraege: [EinkaufslistenEintrag] = []
    /// Kaufeinträge, die diesen Artikel referenzieren — inverse zu
    /// ``KaufEintrag/artikel``. Nullify statt Cascade: ``KaufEintrag`` bleibt
    /// als operative Buchungszeile bestehen, auch wenn der zugehörige Artikel
    /// gelöscht wird (genau dafür existiert ``KaufEintrag/artikelNameSnapshot``).
    /// Ohne diese `inverse`-Deklaration bliebe `KaufEintrag.artikel` beim
    /// Löschen eines Artikels eine "baumelnde" Referenz statt automatisch auf
    /// `nil` gesetzt zu werden — Absturzrisiko wie bei
    /// ``Geschaeft/einkaufsvorgaenge`` beschrieben.
    @Relationship(deleteRule: .nullify, inverse: \KaufEintrag.artikel)
    var kaufEintraege: [KaufEintrag] = []
    /// Konkrete Produkte dieses Artikels (GitHub #47, z.B. "Odol"/"Paradontol"
    /// für "Zahnpasta") — inverse zu ``Produkt/artikel``. Kaskadierend: ein
    /// Produkt ist ohne seinen Artikel bedeutungslos (analog
    /// ``einkaufslistenEintraege``). Enthält auch das automatisch angelegte
    /// Platzhalter-Produkt (``Produkt/istStandard``), solange der Nutzer noch
    /// kein eigenes benennt. Siehe `docs/ARTIKEL_PRODUKT_MODELL.md`.
    @Relationship(deleteRule: .cascade, inverse: \Produkt.artikel)
    var produkte: [Produkt] = []

    /// Rohwert für ``einheit``. Optional gespeichert, damit vor Einführung dieses
    /// Attributs angelegte Artikel beim automatischen Laden nicht abstürzen — ein
    /// `nil`-Rohwert wird als ``Einheit/stueck`` interpretiert.
    private var einheitRaw: String?
    /// Maßeinheit, in der ``menge``/``mengenSchritt`` geführt werden.
    var einheit: Einheit {
        get { einheitRaw.flatMap(Einheit.init(rawValue:)) ?? .stueck }
        set { einheitRaw = newValue.rawValue }
    }

    /// Rohwert für ``mengenSchritt``. Optional gespeichert (siehe ``einheitRaw``);
    /// ein `nil`-Rohwert fällt auf `1` zurück.
    private var mengenSchrittRaw: Double?
    /// Vom Nutzer beim Anlegen (und danach jederzeit) festgelegte Standardmenge —
    /// dient als Start- und Schrittwert für ``EinkaufslistenEintrag/menge`` (siehe
    /// ``EinkaufslistenEintrag/mengeErhoehen()``/``EinkaufslistenEintrag/mengeVerringern()``).
    var mengenSchritt: Double {
        get { mengenSchrittRaw ?? 1 }
        set { mengenSchrittRaw = newValue }
    }

    /// Rohspeicher für ``lamportZaehler`` — additiv optional, siehe
    /// ``GeschaeftTyp/lamportZaehler``.
    private var lamportZaehlerRaw: UInt64?
    /// Logischer Zeitstempel der letzten Änderung an ``name``/``einheit``/
    /// ``mengenSchritt`` — Grundlage dafür, dass eine Umbenennung/
    /// Mengenänderung auch bereits synchronisierte Geräte erreicht
    /// (`SyncSnapshotImportService.mergeArtikel`); ``symbolName``/``farbeHex``
    /// haben aktuell keinen Bearbeitungs-Pfad für bestehende Artikel und
    /// bleiben deshalb bewusst außen vor. Siehe ``GeschaeftTyp/lamportZaehler``
    /// für die volle Begründung.
    var lamportZaehler: UInt64 { lamportZaehlerRaw ?? 0 }

    init(
        name: String,
        symbolName: String,
        farbeHex: String,
        kategorien: [ArtikelKategorie] = [],
        notiz: String? = nil,
        einheit: Einheit = .stueck,
        mengenSchritt: Double = 1
    ) {
        self.id = UUID()
        self.name = name
        self.symbolName = symbolName
        self.farbeHex = farbeHex
        self.kategorie = kategorien.first
        self.kategorienRaw = kategorien
        self.erstelltAm = Date()
        self.notiz = notiz
        self.einheitRaw = einheit.rawValue
        self.mengenSchrittRaw = mengenSchritt
    }

    /// Aufgerufen, wenn der Anwender ``name``/``einheit``/``mengenSchritt``
    /// dieses bereits bestehenden Artikels ändert (siehe `ArtikelEditView`) —
    /// nie bei bloßer Neuanlage, siehe ``GeschaeftTyp/markiereGeaendert()``.
    func markiereGeaendert() {
        lamportZaehlerRaw = LamportClock.naechsterZaehler()
    }

    /// Übernimmt beim Sync-Merge einen tatsächlich neueren Zählerstand, siehe
    /// ``GeschaeftTyp/uebernehmeLamportZaehler(_:)``.
    func uebernehmeLamportZaehler(_ fremderZaehler: UInt64) {
        lamportZaehlerRaw = fremderZaehler
    }
}

extension Artikel {
    /// Preishistorie über alle ``produkte`` dieses Artikels hinweg — abgeleitet,
    /// kein eigenes gespeichertes Feld mehr (``Preispunkt`` hängt seit der
    /// Produkt-Pflicht nur noch an ``Produkt``, siehe dort).
    var preispunkte: [Preispunkt] { produkte.flatMap(\.preispunkte) }

    /// Kategorien, denen dieser Artikel zugeordnet ist — ein Artikel kann mehreren
    /// gleichzeitig angehören (z.B. "Süßigkeiten" und "Geschenke"). Die erste
    /// Kategorie gilt als führend und bleibt automatisch in ``kategorie``
    /// gespiegelt (Migrations-Fallback, Grundlage für
    /// ``fuehrendeKategorie(inGeschaeft:context:)``).
    var kategorien: [ArtikelKategorie] {
        get { kategorienRaw }
        set {
            kategorienRaw = newValue
            kategorie = newValue.first
        }
    }

    /// Die tatsächlich wirksamen Kategorien: ``kategorien``, falls gesetzt; sonst
    /// (Migrations-Fallback für vor der Mehrfachauswahl angelegte Artikel, deren
    /// `kategorienRaw` noch leer ist) das alte, einzelwertige ``kategorie``; sonst
    /// automatisch "Sonstiges" (siehe ``ArtikelKategorie/sonstige(context:)``). Nie
    /// leer.
    func effektiveKategorien(context: ModelContext) -> [ArtikelKategorie] {
        if !kategorien.isEmpty { return kategorien }
        if let kategorie { return [kategorie] }
        return [ArtikelKategorie.sonstige(context: context)]
    }

    /// Beste Schätzung der Kategorie eines Artikels in `geschaeft`, wenn keine
    /// explizite Sektionsauswahl vorliegt (Belegscan, Preisschild-Scan,
    /// Sync-Import empfangener Bereich-A-Events — siehe
    /// ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:kategorie:)``,
    /// deren `kategorie`-Parameter für die reguläre Einkaufsliste bevorzugt
    /// genutzt wird).
    ///
    /// Priorität: die aus der Kaufhistorie **gelernte** Kategorie
    /// (``AbteilungsDistanzService/gelernteKategorie(fuer:in:context:)``, sobald
    /// genug Käufe vorliegen) > eine im Geschäft tatsächlich verfügbare Kategorie >
    /// die erste zugeordnete Kategorie (ohne `geschaeft`, z.B. in der
    /// geschäftsunabhängigen Artikel-Verwaltung). Kandidaten werden vor der Auswahl
    /// deterministisch sortiert (``sortIndex``, dann `id` als letzter Tiebreaker) —
    /// `kategorien` selbst ist eine ungeordnete SwiftData-Relationship, deren
    /// Aufzählungsreihenfolge sich zwischen Fetches/Sync-Merges ändern kann; ohne
    /// diese Sortierung hätte ein mehrfach kategorisierter Artikel vor Erreichen
    /// der Lernschwelle bei jedem Sync-Zyklus zufällig eine andere Kategorie
    /// liefern können.
    ///
    /// **Bis zur Lernschwelle weiterhin kein "Gewinner" im Sinne der
    /// EinkaufenView-Anzeige** (die zeigt einen Artikel mit mehreren, noch nicht
    /// geschäftsspezifisch gelernten Kategorien gleichzeitig in allen zugehörigen
    /// Abschnitten, GitHub-Nachfolgefund zu #36 — zwei Geräte/Nutzer können pro
    /// Artikel und Geschäft unterschiedliche, jeweils tatsächlich zutreffende
    /// Kategorien lernen, z.B. Sojasauce bei Edeka unter "Soßen", bei Aldi unter
    /// "Asia"; `EinkaufenView` fragt dafür direkt bei
    /// ``AbteilungsDistanzService/gelernteKategorie(fuer:in:context:)`` nach,
    /// nicht über diese Funktion hier).
    func fuehrendeKategorie(inGeschaeft geschaeft: Geschaeft?, context: ModelContext) -> ArtikelKategorie {
        let kandidaten = effektiveKategorien(context: context).sorted { a, b in
            a.sortIndex != b.sortIndex ? a.sortIndex < b.sortIndex : a.id.uuidString < b.id.uuidString
        }
        guard let geschaeft else { return kandidaten[0] }
        if kandidaten.count > 1,
           let gelernt = AbteilungsDistanzService.gelernteKategorie(fuer: self, in: geschaeft, context: context) {
            return gelernt
        }
        let alleKategorien = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        let verfuegbareKategorien = geschaeft.verfuegbareKategorien(alleKategorien: alleKategorien)
        if let verfuegbar = kandidaten.first(where: { verfuegbareKategorien.contains($0) }) {
            return verfuegbar
        }
        return kandidaten[0]
    }

    /// Merkt sich `name` als zusätzlichen ``alternativeNamen``-Eintrag dieses
    /// Artikels, falls er weder dem eigentlichen ``name`` noch einem bereits
    /// bekannten alternativen Namen entspricht (kein Duplikat) — analog
    /// ``Geschaeft/alternativenNamenLernen(_:)``. Genutzt für den
    /// additiven Sync-Merge (``SyncSnapshotImportService``, GitHub #128).
    func alternativenNamenLernen(_ name: String) {
        let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !getrimmt.isEmpty,
              getrimmt.localizedCaseInsensitiveCompare(self.name) != .orderedSame,
              !alternativeNamen.contains(where: { $0.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame })
        else { return }
        alternativeNamen.append(getrimmt)
    }

    /// Ein anderer Artikel unter `alle` mit demselben Namen (case-insensitiv,
    /// nach Trimmen — dieselbe Vergleichsregel wie beim Sync-Merge, siehe
    /// `docs/DATENSYNCHRONISATION.md` §4.2), `ausgenommen` selbst — `nil`,
    /// falls keiner. Reine Warnhilfe für ``ArtikelEditView`` (Nutzerbericht
    /// 2026-08-10): zwei unabhängig angelegte, rein lokal nie
    /// zusammengeführte Artikel gleichen Namens erschienen als zwei separate
    /// Einträge auf derselben Einkaufsliste — der namensbasierte Merge greift
    /// nur beim Import eines fremden Sync-Snapshots, nie auf rein lokal
    /// entstandenen Dubletten. Deshalb bewusst kein technisch erzwungenes
    /// Verbot (kein `throw`, kein Speicher-Block) — der Artikel-Name ist
    /// außerhalb des Sync-Kontexts kein technisch eindeutiges Merkmal, nur
    /// meist ungewollt doppelt.
    static func dublette(name: String, alle: [Artikel], ausgenommen: Artikel?) -> Artikel? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return alle.first {
            $0.persistentModelID != ausgenommen?.persistentModelID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
}
