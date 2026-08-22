import CoreLocation
import Foundation
import SwiftData

/// Ein Geschäft, das der Anwender zum Einkaufen aufsucht.
///
/// Ein Geschäft bekommt ``ArtikelKategorie``n direkt zugeordnet (``kategorien``) —
/// die Reihenfolge beim Einkaufen wird nicht manuell festgelegt, sondern von
/// ``AbteilungsDistanzService`` aus dem bisherigen Abhakverhalten gelernt (siehe
/// `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`).
@Model
final class Geschaeft {
    /// Eindeutige Kennung. `@Attribute(.unique)` seit GitHub #102 (vorher
    /// unindiziert, jeder ID-Lookup im Sync-Merge war ein Full-Table-Scan) —
    /// sicher eingeführt erst nach Prüfung des realen Bestands per
    /// ``ModellIDDuplikatService`` auf bereits bestehende Duplikate.
    @Attribute(.unique) var id: UUID
    /// Anzeigename des Geschäfts, z.B. "Rewe am Markt".
    var name: String
    /// Rohwert für ``typen`` von vor Einführung von ``GeschaeftTyp`` als
    /// eigenständigem SwiftData-Modell (GitHub #25) — enum-Rohwerte wie
    /// `"lebensmittel"`. Bleibt nach der einmaligen Migration
    /// (``typenMigrierenFallsNoetig(context:)``) unverändert im Datensatz stehen
    /// (tote Altlast) und wird nur noch von dieser Migration gelesen. Bewusst
    /// nicht `private`, damit Tests „alte“ Datensätze simulieren können.
    var typenRaw: [String]?
    /// Rohspeicher für ``typen`` — bewusst `internal` (nicht `private`), damit
    /// ``GeschaeftTyp`` per `inverse:`-KeyPath darauf verweisen kann. Nicht direkt
    /// verwenden, stattdessen ``typen``.
    @Relationship(inverse: \GeschaeftTyp.geschaefte)
    var typenModelle: [GeschaeftTyp] = []
    /// Geschäftstypen (Lebensmittel, Drogerie, …) — ein Geschäft kann mehrere
    /// gleichzeitig haben (z.B. Drogerie + Lebensmittel). Der erste Wert gilt als
    /// führender Typ (``fuehrenderTyp``).
    var typen: [GeschaeftTyp] {
        get { typenModelle }
        set { typenModelle = newValue }
    }
    /// Der führende (erste zugeordnete) Geschäftstyp — z.B. für die Icon-Anzeige in
    /// ``GeschaeftListView``/``GeschaeftDetailView``. `nil`, falls (ungültigerweise)
    /// kein Typ zugeordnet ist.
    var fuehrenderTyp: GeschaeftTyp? { typen.first }
    /// Optionale Adresse.
    var adresse: String?
    /// Breitengrad — Grundlage der standortbasierten Ladenerkennung
    /// (``GeschaeftErkennungService``) und der Kartenansicht in
    /// ``GeschaeftStammdatenEditView`` (siehe ``koordinate``).
    var breitengrad: Double?
    /// Längengrad — siehe ``breitengrad``.
    var laengengrad: Double?
    /// Rohspeicher für ``erkennungsradius`` — additiv optional, `nil` solange
    /// nicht individuell gesetzt (dann gilt
    /// ``GeschaeftErkennungService/koordinatenTreffertoleranz`` als Standard).
    /// Bewusst nicht `private`, damit ``GeschaeftErkennungService`` den größten
    /// individuellen Radius unter allen Geschäften ermitteln kann (siehe dort,
    /// „effektiver Suchradius“).
    var erkennungsradiusRaw: Double?
    /// Individueller Umkreis (in Metern) um ``koordinate``, innerhalb dessen ein
    /// Apple-Maps-Treffer als dieses Geschäft erkannt wird (GitHub #41) — z.B.
    /// größer für einen Baumarkt mit großem Parkplatz, kleiner für einen
    /// einzelnen Laden in einer Fußgängerzone mit dicht benachbarten Geschäften.
    /// Fällt ohne explizite Wahl auf den globalen Standard zurück.
    var erkennungsradius: Double {
        get { erkennungsradiusRaw ?? GeschaeftErkennungService.koordinatenTreffertoleranz }
        set { erkennungsradiusRaw = newValue }
    }
    /// Artikelkategorien, die diesem Geschäft zugeordnet sind — der einzige Weg,
    /// eine Kategorie in einem Geschäft verfügbar zu machen (siehe
    /// ``verfuegbareKategorien``).
    @Relationship(inverse: \ArtikelKategorie.geschaefte)
    var kategorien: [ArtikelKategorie] = []
    /// Kategorien, die trotz automatischer Verfügbarkeit über einen der
    /// ``typen`` (``ArtikelKategorie/geschaeftsTypen``) für dieses eine
    /// Geschäft ausgeschlossen sind (GitHub #43) — eine Negativliste zusätzlich
    /// zur Positivliste ``kategorien``. Wird eine hier gelistete Kategorie
    /// später direkt zu ``kategorien`` hinzugefügt (z.B. über
    /// ``AbteilungHinzufuegenSheet``), sticht das den Ausschluss (siehe
    /// ``verfuegbareKategorien(alleKategorien:)``).
    var ausgeschlosseneKategorien: [ArtikelKategorie] = []
    /// Operative Einkaufs-Buchungszeilen (``KaufEintrag``) in diesem Geschäft — seit
    /// GitHub #76 ohne Preisrolle, siehe ``preispunkte``. Wird das Geschäft gelöscht,
    /// werden auch seine Buchungszeilen gelöscht — siehe `docs/GESCHAEFTSERKENNUNG.md`.
    @Relationship(deleteRule: .cascade, inverse: \KaufEintrag.geschaeft)
    var kaufEintraege: [KaufEintrag] = []
    /// Preishistorie (``Preispunkt``, GitHub #76), die in diesem Geschäft erfasst
    /// wurde. Wird das Geschäft gelöscht, wird auch seine gesamte Preishistorie
    /// gelöscht — dieselbe Begründung wie ``kaufEintraege``.
    @Relationship(deleteRule: .cascade, inverse: \Preispunkt.geschaeft)
    var preispunkte: [Preispunkt] = []
    /// Beim Belegscan dauerhaft ignorierte Artikelnamen für dieses Geschäft (siehe
    /// ``IgnorierterArtikel``). Wird das Geschäft gelöscht, verschwinden auch seine
    /// Ignorier-Einträge.
    @Relationship(deleteRule: .cascade, inverse: \IgnorierterArtikel.geschaeft)
    var ignorierteArtikel: [IgnorierterArtikel] = []
    /// Einkaufsvorgänge, die in diesem Geschäft stattfanden — inverse zu
    /// ``Einkaufsvorgang/geschaeft``. Bewusst NICHT kaskadierend: ein gelöschtes
    /// Geschäft soll die historische Tatsache "hier fand ein Einkauf statt"
    /// nicht mit auslöschen, nur den Bezug dazu verlieren. Ohne diese
    /// `inverse`-Deklaration bleibt `Einkaufsvorgang.geschaeft` beim Löschen
    /// eines Geschäfts eine "baumelnde" Referenz auf eine nicht mehr
    /// existierende Zeile im Store, statt automatisch auf `nil` gesetzt zu
    /// werden — ein späterer Zugriff auf eine Eigenschaft dieser Referenz
    /// crasht dann mit einem SwiftData-Fatal-Error (siehe
    /// `docs/DATABASE_CONCURRENCY.md`, Abschnitt zu diesem Fund).
    @Relationship(deleteRule: .nullify, inverse: \Einkaufsvorgang.geschaeft)
    var einkaufsvorgaenge: [Einkaufsvorgang] = []
    /// Gelernte Abteilungs-Distanzen für dieses Geschäft — inverse zu
    /// ``WarengruppenDistanz/geschaeft``. Kaskadierend: ohne das Geschäft sind
    /// geschäftsspezifisch gelernte Distanzen bedeutungslos (siehe
    /// ``einkaufsvorgaenge`` oben für die Begründung, warum eine fehlende
    /// `inverse`-Deklaration hier ein Absturzrisiko ist).
    @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.geschaeft)
    var warengruppenDistanzen: [WarengruppenDistanz] = []
    /// Rohwert für ``alternativeNamen`` — durch `\n` getrennt gespeichert. Optional,
    /// damit vor Einführung dieses Attributs angelegte Geschäfte beim automatischen
    /// Laden nicht abstürzen (siehe `docs/BELEGSCAN.md`).
    private var alternativeNamenRaw: String?
    /// Zusätzliche Namen, unter denen dieses Geschäft auf einem Kassenbon erkannt
    /// werden kann (z.B. Kurzform oder Filial-Zusatz wie „REWE Center Musterstadt“
    /// für „Rewe“) — gelernt beim automatischen Geschäfts-Abgleich in
    /// ``BelegScanView``, siehe ``alternativenNamenLernen(_:)`` und
    /// `docs/BELEGSCAN.md`.
    var alternativeNamen: [String] {
        get { (alternativeNamenRaw ?? "").split(separator: "\n").map(String.init) }
        set { alternativeNamenRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }
    /// Markenname der Kette, zu der diese Filiale gehört — z.B. „Rewe" für
    /// „Rewe Maisach". Dient als Gruppierungsschlüssel in ``GeschaeftListView``:
    /// Filialen mit demselben Markennamen werden dort zusammengefasst und können
    /// aufgeklappt werden. `nil`, solange keine Kette zugeordnet ist.
    var markenname: String?
    /// Rohwert für ``eigeneAnzahlEinkaufsvorgaenge``. Optional gespeichert, damit
    /// vor Einführung dieses Attributs angelegte Geschäfte beim automatischen
    /// Laden nicht abstürzen — ein `nil`-Rohwert fällt auf `0` zurück.
    private var anzahlEinkaufsvorgaengeRaw: Int?
    /// Wie oft DIESES Gerät in diesem Geschäft bereits selbst einen
    /// Einkaufsvorgang abgeschlossen hat (``Einkaufsvorgang/abschliessen(am:)``)
    /// — NIE durch Sync verändert, nur durch eine echte lokale Aktion oder den
    /// manuellen Reset (siehe ``zaehlerZuruecksetzen(context:)``, GitHub #30).
    /// Grundlage (zusammen mit dem zuletzt bekannten eigenen Beitrag jedes
    /// Peers) für ``anzahlEinkaufsvorgaenge``.
    var eigeneAnzahlEinkaufsvorgaenge: Int {
        get { anzahlEinkaufsvorgaengeRaw ?? 0 }
        set { anzahlEinkaufsvorgaengeRaw = newValue }
    }
    /// Wie oft in diesem Geschäft gruppenweit, über alle bekannten Geräte
    /// hinweg, bereits ein Einkaufsvorgang abgeschlossen wurde — unabhängig von
    /// der Preishistorie, daher unabhängig von deren Aufbewahrungsfrist.
    ///
    /// **Bewusst ein reiner G-Counter (CRDT-Muster) statt der ursprünglichen
    /// "Delta seit zuletzt gesehenem Gesamtwert"-Regel:** Summe aus
    /// ``eigeneAnzahlEinkaufsvorgaenge`` und dem zuletzt bekannten EIGENEN
    /// Beitrag jedes Peers (``SyncPeerZaehlerStand``, jetzt „was hat Peer P
    /// selbst beigetragen", nicht mehr „welchen Gesamtwert hatte Peer P
    /// zuletzt"). Die vorherige Regel addierte bei jedem Sync-Durchlauf einen
    /// Zuwachs auf einen bereits gemergten Gesamtwert — da dieser Gesamtwert
    /// selbst schon Beiträge anderer Peers enthielt, wurde derselbe Beitrag bei
    /// jedem weiteren Hin-und-Her zwischen zwei Geräten erneut mitgezählt und
    /// wuchs dadurch unbegrenzt, ohne dass je ein echter neuer Einkauf
    /// stattfand (Live-Test-Fund, siehe `docs/DATENSYNCHRONISATION_VERLAUF.md`
    /// Abschnitt 17) — als Nebeneffekt änderte sich dadurch bei praktisch jedem
    /// Sync-Zyklus der Inhalt von `export.json`. Ein G-Counter zählt jeden
    /// Beitrag an genau einer Stelle, unabhängig davon, über wie viele Geräte
    /// er weitergereicht wird.
    ///
    /// Berechnet bei jedem Zugriff (kein zusätzlicher gespeicherter
    /// Gesamtwert) — bei den hier realistischen Peer-Zahlen unkritisch. Ohne
    /// zugeordneten ``modelContext`` (z.B. ein noch nicht eingefügtes,
    /// frisches Geschäft) liefert nur ``eigeneAnzahlEinkaufsvorgaenge`` zurück.
    var anzahlEinkaufsvorgaenge: Int {
        guard let context = modelContext else { return eigeneAnzahlEinkaufsvorgaenge }
        let eigeneID = id
        let deskriptor = FetchDescriptor<SyncPeerZaehlerStand>(predicate: #Predicate { $0.geschaeftID == eigeneID })
        let peerBeitraege = (try? context.fetch(deskriptor)) ?? []
        return eigeneAnzahlEinkaufsvorgaenge + peerBeitraege.reduce(0) { $0 + $1.zuletztGesehenerWert }
    }

    /// Setzt ``eigeneAnzahlEinkaufsvorgaenge`` auf `0` und vergisst die zuletzt
    /// bekannten eigenen Beiträge aller Peers für dieses Geschäft (GitHub #30)
    /// — lässt die eigentliche Kaufhistorie (``KaufEintrag``) unangetastet.
    /// Rein lokal: andere Geräte erfahren davon nicht automatisch (dieselbe,
    /// bereits vorher akzeptierte Einschränkung wie beim alten Zähler — ein
    /// Peer, der seinen eigenen Beitrag später erneut meldet, würde ihn sonst
    /// wieder mitzählen).
    func zaehlerZuruecksetzen(context: ModelContext) {
        eigeneAnzahlEinkaufsvorgaenge = 0
        let eigeneID = id
        let deskriptor = FetchDescriptor<SyncPeerZaehlerStand>(predicate: #Predicate { $0.geschaeftID == eigeneID })
        for beitrag in (try? context.fetch(deskriptor)) ?? [] {
            context.delete(beitrag)
        }
    }
    /// Rohwert für ``umbauVerdacht``. Optional gespeichert, damit vor Einführung
    /// dieses Attributs angelegte Geschäfte beim automatischen Laden nicht
    /// abstürzen — ein `nil`-Rohwert fällt auf `false` zurück.
    private var umbauVerdachtRaw: Bool?
    /// Ob ``AbteilungsDistanzService`` bei den letzten Einkäufen in diesem
    /// Geschäft eine deutliche Abweichung von der gelernten Abteilungs-Distanz
    /// festgestellt hat (z.B. nach einem Ladenumbau) — siehe
    /// ``AbteilungsDistanzService/erkenneUmbau(_:context:)``. Löst in der UI
    /// einen Hinweis aus und erhöht vorübergehend die Lernrate, damit sich die
    /// Distanzmatrix schneller an die neue Anordnung anpasst.
    var umbauVerdacht: Bool {
        get { umbauVerdachtRaw ?? false }
        set { umbauVerdachtRaw = newValue }
    }
    /// Rohwert für ``unauffaelligeEinkaeufeInFolge``. Optional gespeichert, damit
    /// vor Einführung dieses Attributs angelegte Geschäfte beim automatischen
    /// Laden nicht abstürzen — ein `nil`-Rohwert fällt auf `0` zurück.
    private var unauffaelligeEinkaeufeInFolgeRaw: Int?
    /// Anzahl aufeinanderfolgender Einkäufe seit dem letzten ``umbauVerdacht``,
    /// die keine deutliche Abweichung von der gelernten Abteilungs-Distanz
    /// mehr gezeigt haben — siehe
    /// ``AbteilungsDistanzService/erkenneUmbau(besuche:matrix:geschaeft:)``.
    /// Erreicht der Zähler die dort definierte Schwelle, wird ``umbauVerdacht``
    /// wieder zurückgesetzt.
    var unauffaelligeEinkaeufeInFolge: Int {
        get { unauffaelligeEinkaeufeInFolgeRaw ?? 0 }
        set { unauffaelligeEinkaeufeInFolgeRaw = newValue }
    }

    /// Rohspeicher für ``lamportZaehler`` — additiv optional, siehe
    /// ``GeschaeftTyp/lamportZaehler``.
    private var lamportZaehlerRaw: UInt64?
    /// Logischer Zeitstempel der letzten Änderung an ``name`` — Grundlage
    /// dafür, dass eine Umbenennung auch bereits synchronisierte Geräte
    /// erreicht (`SyncSnapshotImportService.mergeGeschaefte`); alle übrigen
    /// Felder bleiben unverändert additiv/nil-füllend, siehe
    /// ``GeschaeftTyp/lamportZaehler`` für die volle Begründung.
    var lamportZaehler: UInt64 { lamportZaehlerRaw ?? 0 }

    init(name: String, typen: [GeschaeftTyp], adresse: String? = nil) {
        self.id = UUID()
        self.name = name
        self.typenModelle = typen
        self.adresse = adresse
    }

    /// Aufgerufen, wenn der Anwender ``name`` dieses bereits bestehenden
    /// Geschäfts ändert (siehe `GeschaeftStammdatenEditView`) — nie bei
    /// bloßer Neuanlage, siehe ``GeschaeftTyp/markiereGeaendert()``.
    func markiereGeaendert() {
        lamportZaehlerRaw = LamportClock.naechsterZaehler()
    }

    /// Übernimmt beim Sync-Merge einen tatsächlich neueren Zählerstand, siehe
    /// ``GeschaeftTyp/uebernehmeLamportZaehler(_:)``.
    func uebernehmeLamportZaehler(_ fremderZaehler: UInt64) {
        lamportZaehlerRaw = fremderZaehler
    }

    /// Merkt sich `name` als zusätzlichen ``alternativeNamen``-Eintrag dieses
    /// Geschäfts, falls er weder dem eigentlichen ``name`` noch einem bereits
    /// bekannten Alias entspricht (kein Duplikat). Grundlage für das automatische
    /// Wiedererkennen desselben Geschäfts bei künftigen Scans — siehe
    /// ``passendes(fuerErkannterName:unter:)``.
    func alternativenNamenLernen(_ name: String) {
        let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !getrimmt.isEmpty,
              getrimmt.localizedCaseInsensitiveCompare(self.name) != .orderedSame,
              !alternativeNamen.contains(where: { $0.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame })
        else { return }
        alternativeNamen.append(getrimmt)
    }

    /// Findet-oder-legt-an das Pseudo-Geschäft für ``Preispunkt``e ohne
    /// bekanntes Geschäft — seit GitHub #128 braucht ``Preispunkt/geschaeft``
    /// zwingend einen Wert (Geschäfts-Pflicht bei der Preiserfassung, siehe
    /// `docs/ARTIKEL_PRODUKT_MODELL.md`). Genutzt für Alt-Daten (historische
    /// ``KaufEintrag``-Migration) und für nicht auflösbare Geschäfts-Referenzen
    /// beim Sync-Import (``SyncSnapshotImportService``). Ein ganz gewöhnliches
    /// ``Geschaeft`` ohne Sondermarkierung im Modell — der Nutzer kann es
    /// hinterher wie jedes andere umbenennen. Gefunden über den festen Namen
    /// „Unbekannt" (case-insensitiv), nicht über ein Flag.
    static func unbekanntesGeschaeft(context: ModelContext) -> Geschaeft {
        let name = "Unbekannt"
        let alle = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []
        if let bestehendes = alle.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return bestehendes
        }
        let neues = Geschaeft(name: name, typen: [])
        context.insert(neues)
        return neues
    }

    /// Sucht unter `geschaefte` dasjenige, dessen ``name`` oder ``alternativeNamen``
    /// zum per KI erkannten `erkannterName` eines Kassenbons passt (beidseitiger
    /// `localizedCaseInsensitiveContains`-Abgleich, analog
    /// ``KaufEintrag/gelernteZuordnung(fuerErkannterName:in:)``). `nil`, falls
    /// weder Name noch Adresse zu einem eindeutigen Treffer führen — dann fragt die
    /// aufrufende Scan-Ansicht über `GeschaeftWahlSheet` nach.
    ///
    /// Gibt es zum Namen **mehrere** Kandidaten (z.B. zwei Filialen derselben
    /// Kette), wird die ebenfalls vom Kassenbon erkannte `erkannteAdresse` als
    /// automatischer Tie-Breaker genutzt (beidseitiger Teilstring-Abgleich gegen
    /// ``adresse``) — bewusst ohne Rückfrage. Bleibt danach mehr als ein oder gar
    /// kein Kandidat übrig (keine/nicht passende Adresse erkannt), fällt die
    /// Funktion auf den ersten Namens-Kandidaten zurück (unverändertes
    /// Vorher-Verhalten), statt den Anwender zu unterbrechen.
    ///
    /// Liefert der Name **keinen** Kandidaten (leer erkannt oder kein passendes
    /// Geschäft), wird stattdessen versucht, allein über `erkannteAdresse` einen
    /// **eindeutigen** Treffer zu finden (GitHub #19) — z.B. wenn die KI den
    /// Namen nicht zuverlässig lesen konnte, die Adresse aber eindeutig einem
    /// bekannten Geschäft zuzuordnen ist.
    static func passendes(
        fuerErkannterName erkannterName: String,
        erkannteAdresse: String = "",
        unter geschaefte: [Geschaeft]
    ) -> Geschaeft? {
        let erkannterName = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let getrimmteAdresse = erkannteAdresse.trimmingCharacters(in: .whitespacesAndNewlines)

        func nameTrifftZu(_ bekannterName: String) -> Bool {
            guard !bekannterName.isEmpty, !erkannterName.isEmpty else { return false }
            return bekannterName.localizedCaseInsensitiveContains(erkannterName)
                || erkannterName.localizedCaseInsensitiveContains(bekannterName)
        }
        func adresseTrifftZu(_ bekannteAdresse: String?) -> Bool {
            guard let bekannteAdresse, !bekannteAdresse.isEmpty, !getrimmteAdresse.isEmpty else { return false }
            return bekannteAdresse.localizedCaseInsensitiveContains(getrimmteAdresse)
                || getrimmteAdresse.localizedCaseInsensitiveContains(bekannteAdresse)
        }

        let kandidaten = erkannterName.isEmpty
            ? []
            : geschaefte.filter { nameTrifftZu($0.name) || $0.alternativeNamen.contains(where: nameTrifftZu) }

        guard !kandidaten.isEmpty else {
            let adressTreffer = geschaefte.filter { adresseTrifftZu($0.adresse) }
            return adressTreffer.count == 1 ? adressTreffer.first : nil
        }
        guard kandidaten.count > 1 else { return kandidaten.first }

        guard !getrimmteAdresse.isEmpty else { return kandidaten.first }
        let anhandAdresse = kandidaten.filter { adresseTrifftZu($0.adresse) }
        return anhandAdresse.count == 1 ? anhandAdresse.first : kandidaten.first
    }

    /// Kurzform von ``adresse`` (Straße + Ort, ohne Postleitzahl) — z.B. „Marktstraße
    /// 1, Musterstadt“ aus „Marktstraße 1, 12345 Musterstadt“. Dient zur
    /// Unterscheidung namensgleicher Geschäfte in `GeschaeftWahlSheet`/
    /// `GeschaeftListView` (siehe ``namenMitDuplikaten(unter:)``). `nil` ohne
    /// hinterlegte ``adresse``; enthält die Adresse kein Komma, wird sie
    /// unverändert zurückgegeben (kein erkennbares Straße/Ort-Format).
    var kurzeAdresse: String? {
        guard let adresse, !adresse.isEmpty else { return nil }
        let teile = adresse.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard teile.count == 2 else { return adresse }
        let ort = teile[1].replacingOccurrences(of: #"^\d{4,5}\s*"#, with: "", options: .regularExpression)
        return "\(teile[0]), \(ort)"
    }

    /// ``breitengrad``/``laengengrad`` als `CLLocationCoordinate2D`, `nil` solange
    /// (noch) keine Koordinaten hinterlegt sind. Praktischer Zugriff für die
    /// Kartenansicht in ``GeschaeftStammdatenEditView`` (GitHub #24).
    var koordinate: CLLocationCoordinate2D? {
        get {
            guard let breitengrad, let laengengrad else { return nil }
            return CLLocationCoordinate2D(latitude: breitengrad, longitude: laengengrad)
        }
        set {
            breitengrad = newValue?.latitude
            laengengrad = newValue?.longitude
        }
    }

    /// Liefert die (kleingeschriebenen) Namen aller Geschäfte, die mehrfach unter
    /// `geschaefte` vorkommen — Grundlage dafür, ob ``kurzeAdresse`` zur
    /// Unterscheidung angezeigt werden soll. `GeschaeftWahlSheet`/`GeschaeftListView`
    /// nutzen diese eine gemeinsame Funktion statt eigener Duplikat-Erkennung.
    static func namenMitDuplikaten(unter geschaefte: [Geschaeft]) -> Set<String> {
        let namenLower = geschaefte.map { $0.name.lowercased() }
        let anzahl = Dictionary(namenLower.map { ($0, 1) }, uniquingKeysWith: +)
        return Set(anzahl.filter { $0.value > 1 }.keys)
    }

    /// Alle Artikelkategorien, die in diesem Geschäft manuell verfügbar gemacht
    /// wurden, sortiert nach ``ArtikelKategorie/sortIndex``. Zeigt bewusst **nicht**
    /// die zusätzlich über ``verfuegbareKategorien(alleKategorien:)`` einbezogenen,
    /// rein aus dem Geschäftstyp abgeleiteten Kategorien — diese Variante ist die
    /// Grundlage für die manuelle Verwaltung (``GeschaeftDetailView``, Entfernen
    /// einer Kategorie), wo nur tatsächlich zugeordnete Kategorien entfernbar sein
    /// dürfen.
    var verfuegbareKategorien: [ArtikelKategorie] {
        kategorien.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Wie ``verfuegbareKategorien``, ergänzt um Kategorien, die zwar nicht
    /// ``kategorien`` dieses Geschäfts zugeordnet sind, aber laut
    /// ``ArtikelKategorie/geschaeftsTypen`` als typische Abteilung für einen der
    /// ``typen`` dieses Geschäfts gelten (GitHub #5) — abzüglich individuell
    /// ``ausgeschlosseneKategorien`` (GitHub #43). Eine ausgeschlossene Kategorie,
    /// die trotzdem direkt zu ``kategorien`` hinzugefügt wird, bleibt verfügbar —
    /// der Ausschluss betrifft nur den automatischen, typ-basierten Weg. Wird für
    /// die tatsächliche Verfügbarkeit beim Einkaufen genutzt (siehe
    /// ``ArtikelVerfuegbarkeitService``, ``Artikel/fuehrendeKategorie(inGeschaeft:context:)``)
    /// — `alleKategorien` kommt dort aus einem ``ModelContext``-Fetch bzw. einem
    /// bestehenden `@Query`.
    func verfuegbareKategorien(alleKategorien: [ArtikelKategorie]) -> [ArtikelKategorie] {
        let eigeneTypen = Set(typen)
        let ausgeschlossen = Set(ausgeschlosseneKategorien.map(\.persistentModelID))
        let typBasiert = alleKategorien.filter {
            !Set($0.geschaeftsTypen).isDisjoint(with: eigeneTypen) && !ausgeschlossen.contains($0.persistentModelID)
        }
        var gesehen = Set<PersistentIdentifier>()
        return (verfuegbareKategorien + typBasiert)
            .filter { gesehen.insert($0.persistentModelID).inserted }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Migriert vor GitHub #25 angelegte Geschäfte (deren ``typen`` noch leer ist,
    /// aber ``typenRaw`` alte enum-Rohwerte gespeichert hat) einmalig auf die
    /// entsprechenden ``GeschaeftTyp``-Objekte. Wird beim App-Start für alle
    /// Geschäfte aufgerufen (siehe ``SeedData``); bereits migrierte oder neu
    /// angelegte Geschäfte (``typen`` nicht leer) bleiben unverändert.
    static func typenMigrierenFallsNoetig(context: ModelContext) {
        let alle = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []
        for geschaeft in alle {
            guard geschaeft.typen.isEmpty, let rohwerte = geschaeft.typenRaw, !rohwerte.isEmpty else { continue }
            let namen = rohwerte.compactMap(GeschaeftTyp.legacyName(fuerRohwert:))
            geschaeft.typen = namen.isEmpty
                ? [GeschaeftTyp.sonstiges(context: context)]
                : namen.map { GeschaeftTyp.mitNamen($0, context: context) }
        }
    }
}
