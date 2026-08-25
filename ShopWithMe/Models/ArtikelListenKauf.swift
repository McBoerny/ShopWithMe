import Foundation
import SwiftData

/// Dauerhafte, von ``KaufEintrag``/``Einkaufsvorgang`` unabhängige Tatsache:
/// „``artikel`` wurde mindestens einmal von ``einkaufsliste`` abgehakt" —
/// Grundlage für das Sicherheitsnetz gegen wiederbelebte Käufe in
/// ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``
/// (GitHub #99).
///
/// **Root Cause, die dieser Typ behebt:** Die vorherige Prüfung stützte sich
/// ausschließlich auf noch existierende ``KaufEintrag``e unter den noch
/// existierenden ``Einkaufsvorgang``en einer Liste. `KaufEintragBereinigungService`
/// löscht diese aber 48h nach Abschluss ihres Vorgangs — verliert ein Gerät
/// dadurch seine einzige lokale Evidenz für "wurde schon gekauft", holt ein
/// Peer mit veraltetem (per Fingerabdruck-Skip übersprungenem) `listen.json`
/// den Artikel klaglos zurück auf die offene Liste. Analog
/// ``ArtikelGeschaeftVerfuegbarkeit`` (siehe `docs/GESCHAEFTS_AGGREGATE.md`):
/// eine Zeile pro (``Artikel``, ``Einkaufsliste``)-Paar, kein Tombstone nötig
/// (wird vom Nutzer nie direkt gelöscht), bleibt auch nach der 48h-Löschung
/// des zugrundeliegenden ``KaufEintrag`` unverändert bestehen, und hängt
/// bewusst NICHT an der Tombstone-Aufräum-Watermark (Peer-Lebenszyklus, siehe
/// `docs/PEER_LEBENSZYKLUS.md`) — die Absicherung soll unabhängig von deren
/// Timing dauerhaft gelten, nicht nur "so lange, bis der zugehörige Tombstone
/// aufgeräumt wird".
///
/// **``zuletztAbgehaktAm`` (Nutzerbericht 2026-08-10, Folgefund zu GitHub
/// #99):** ursprünglich bewusst OHNE jeden Zeitstempel („reine
/// Existenz-Tatsache") — das permanente Veto in `istBereitsAbgehakt` blockte
/// dadurch aber auch ein legitimes ERNEUTES Hinzufügen eines wiederkehrenden
/// Artikels (z.B. „Milch nochmal, eine Woche später"), sobald dessen direktes
/// `artikelHinzugefuegt`-Ereignis ein Gerät nie erreichte (frisch per
/// `SyncErsetzenService` neu aufgebaut, oder das Ereignis bereits verfallen)
/// — live bestätigt über das neue Diagnose-Ereignis
/// `sync_listeneintrag_sicherheitsnetz_uebersprungen` (`docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 54). Dieser Zeitstempel ist bewusst KEIN Tombstone-artiger
/// Aufräum-Zeitstempel (die Zeile bleibt weiterhin für immer bestehen, auch
/// wenn er `nil` ist) — er dient einzig als Vergleichsbasis: ein vom Peer
/// aktuell gemeldeter Listen-Eintrag, dessen ``EinkaufslistenEintragSnapshot/erstelltAm``
/// NACH diesem Zeitpunkt liegt, ist nachweislich neuer als der letzte
/// bekannte Kauf — also ein legitimes erneutes Hinzufügen, keine stale
/// Resurrektion einer längst veralteten Momentaufnahme. `nil` (Altbestand vor
/// diesem Feld, oder ein Peer, dessen Snapshot noch kein Zeitstempel-Feld
/// kennt) bleibt bewusst beim alten, strengeren Verhalten — permanentes Veto,
/// keine Lockerung ohne echten Vergleichswert.
///
/// **``zuletztHinzugefuegtAm`` (Nutzerbericht 2026-08-10, Architektur-Review
/// nach drei aufeinanderfolgenden Live-Test-Funden am selben Symptom-Cluster
/// — „kurzzeitiges Flackern", dann „ein Artikel verschwindet trotzdem noch
/// einmal").** Symmetrisches Gegenstück zu ``zuletztAbgehaktAm``: dieselbe
/// additiv-monotone G-Counter-artige Zusicherung („bewegt sich nur nach
/// vorne, nie zurück", siehe ``ArtikelListenKaufService/vermerkeHinzugefuegt(artikel:einkaufsliste:am:context:)``),
/// nur für die Gegenseite — „wann wurde dieser Artikel zuletzt (nachweislich,
/// geräteübergreifend) auf diese Liste gesetzt". **Root Cause, die dieses
/// Feld behebt:** vor seiner Einführung gab es für die "hinzugefügt"-Seite
/// KEIN robustes Äquivalent — ``EinkaufslistenEintrag/erstelltAm`` sieht wie
/// eine Vergleichsbasis aus, ist aber keine: die Zeile wird beim Abhaken
/// gelöscht und beim erneuten Hinzufügen neu angelegt, und
/// ``SyncSnapshotImportService/mergeEinkaufslistenEintraege(_:listeZuordnung:artikelZuordnung:produktZuordnung:peerGeraeteID:context:)``
/// übernimmt dabei bewusst den ORIGINAL-Zeitstempel des sendenden Geräts
/// (verhindert, dass ein Artikel nach einem Neuaufbau künstlich frisch
/// aussieht, siehe Nachtrag dort) — der kann seinerseits von einem DRITTEN
/// Gerät geerbt sein, beliebig oft weitergereicht, ohne jede monotone
/// Absicherung. Jeder Vergleich gegen diesen unprotected Rohwert (sowohl in
/// `istBereitsAbgehakt` als auch in einem Zwischenfund in
/// `mergeKaufEintraege`) blieb dadurch strukturell fragil — jeder Fix machte
/// nur die eine gerade beobachtete Reihenfolge korrekt, eine andere
/// Verkettung von Geräten/Zyklen produzierte dasselbe Symptom erneut. Mit
/// diesem Feld werden BEIDE Seiten der Entscheidung „ist der Artikel aktuell
/// offen" additiv gemergte, monotone Fakten — siehe
/// ``ArtikelListenKaufService/istOffen(hinzugefuegtAm:abgehaktAm:)`` für die
/// daraus resultierende, an beiden bisherigen Vergleichsstellen
/// EINHEITLICHE Entscheidungsregel. Rückwirkend für Bestandsdaten befüllt
/// über ``DatenintegritaetsService/migriereArtikelListenKaeufeFallsNoetig(context:)``.
@Model
final class ArtikelListenKauf {
    /// Eindeutige Kennung.
    var id: UUID
    var artikel: Artikel?
    /// Das konkrete Produkt, falls die Fakten dieser Zeile sich auf ein
    /// bestimmtes Produkt des Artikels beziehen (analog
    /// ``EinkaufslistenEintrag/produkt``) — `nil` bei genereller Auswahl ohne
    /// Produktwahl. **GitHub #172:** vor diesem Feld war dieser ganze Typ rein
    /// artikelweit geschlüsselt — der Kauf EINES Produkts eines generischen
    /// Artikels (z.B. „Batterie") setzte dadurch das Sicherheitsnetz für ALLE
    /// anderen, noch offenen Produkte desselben Artikels mit zurück und ließ
    /// deren Listeneinträge beim nächsten Merge fälschlich als „schon
    /// gekauft" verschwinden. Additiv-optional, keine Migration nötig.
    var produkt: Produkt?
    var einkaufsliste: Einkaufsliste?
    /// Siehe Typ-Doku „``zuletztAbgehaktAm``" oben.
    var zuletztAbgehaktAm: Date?
    /// Siehe Typ-Doku „``zuletztHinzugefuegtAm``" oben.
    var zuletztHinzugefuegtAm: Date?

    init(
        artikel: Artikel?, produkt: Produkt? = nil, einkaufsliste: Einkaufsliste?,
        zuletztAbgehaktAm: Date? = nil, zuletztHinzugefuegtAm: Date? = nil
    ) {
        self.id = UUID()
        self.artikel = artikel
        self.produkt = produkt
        self.einkaufsliste = einkaufsliste
        self.zuletztAbgehaktAm = zuletztAbgehaktAm
        self.zuletztHinzugefuegtAm = zuletztHinzugefuegtAm
    }
}

enum ArtikelListenKaufService {
    /// Schlüssel für Set-/Dictionary-basierte Existenz-Prüfungen über ein
    /// (``Artikel``, ``Einkaufsliste``)-Paar — verwendet die app-eigenen
    /// `UUID`s (nicht `persistentModelID`), damit sich der Schlüssel auch für
    /// Objekte bilden lässt, die (noch) nicht im selben ``ModelContext``
    /// verankert sind (analog ``SyncEventService/PaarSchluessel``).
    struct Schluessel: Hashable {
        let artikelID: UUID
        /// `nil` bei genereller Auswahl ohne Produktwahl — siehe
        /// ``ArtikelListenKauf/produkt``. Ein `nil`-Schlüssel ist ein
        /// eigener, von jedem konkreten Produkt-Schlüssel unterschiedener
        /// Eimer: zwei Personen, die BEIDE ohne Produktwahl hinzufügen,
        /// teilen sich weiterhin bewusst dieselbe Zeile (so ist auch
        /// ``Einkaufsliste/eintrag(fuer:produkt:)`` angelegt); erst ein
        /// tatsächlich gewähltes, unterschiedliches ``Produkt`` trennt sie.
        let produktID: UUID?
        let einkaufslisteID: UUID
    }

    /// Ob `(artikel, produkt)` jemals von `einkaufsliste` abgehakt wurde.
    static func istJemalsAbgehakt(artikel: Artikel, produkt: Produkt? = nil, einkaufsliste: Einkaufsliste, context: ModelContext) -> Bool {
        bestehenderEintrag(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, context: context) != nil
    }

    /// Der bestehende Eintrag für dieses Tripel, falls vorhanden — `nil`-Limit
    /// 1, da (Artikel, Produkt, Einkaufsliste) faktisch eindeutig ist (siehe
    /// `vermerkeAbgehakt`/`vermerkeAbgehaktFallsNoetig`, die nie eine zweite
    /// Zeile für dasselbe Tripel anlegen).
    private static func bestehenderEintrag(
        artikel: Artikel, produkt: Produkt?, einkaufsliste: Einkaufsliste, context: ModelContext
    ) -> ArtikelListenKauf? {
        let artikelID = artikel.persistentModelID
        let produktID = produkt?.persistentModelID
        let listeID = einkaufsliste.persistentModelID
        var deskriptor = FetchDescriptor<ArtikelListenKauf>(
            predicate: #Predicate {
                $0.artikel?.persistentModelID == artikelID && $0.produkt?.persistentModelID == produktID
                    && $0.einkaufsliste?.persistentModelID == listeID
            }
        )
        deskriptor.fetchLimit = 1
        if let exakt = (try? context.fetch(deskriptor))?.first { return exakt }
        return bestehenderEintragNamensgleich(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, context: context)
    }

    /// Namens-Backstop (siehe ``Einkaufsliste/eintragNamensgleich(fuer:produkt:)``
    /// für die ausführliche Begründung): findet einen bestehenden Eintrag für
    /// dieselbe Liste UND dasselbe Produkt, dessen ``ArtikelListenKauf/artikel``
    /// zwar ein ANDERES lokales Objekt als `artikel` ist, aber denselben Namen
    /// trägt (case-insensitiv) — schützt vor einer gesplitteten „bereits
    /// hinzugefügt"/„bereits abgehakt"-Historie für dieselbe logische
    /// Position, falls Bereich-A-Event-Anwendung und Bereich-B-„Sicherheitsnetz"
    /// im selben Zyklus denselben Artikel auf zwei noch nicht per Alias
    /// zusammengeführte lokale ``Artikel``-Objekte auflösen. Der Produkt-
    /// Vergleich läuft bewusst über exakte Objektgleichheit statt eines
    /// eigenen Namens-Backstops für ``Produkt`` — ein noch nicht per Alias
    /// zusammengeführtes Produkt-Duplikat legt im schlimmsten Fall einmalig
    /// eine zusätzliche Zeile an (harmlos), statt wie vor GitHub #172 quer
    /// über unterschiedliche Produkte hinweg fälschlich zu blockieren.
    private static func bestehenderEintragNamensgleich(
        artikel: Artikel, produkt: Produkt?, einkaufsliste: Einkaufsliste, context: ModelContext
    ) -> ArtikelListenKauf? {
        let listeID = einkaufsliste.persistentModelID
        let deskriptor = FetchDescriptor<ArtikelListenKauf>(predicate: #Predicate { $0.einkaufsliste?.persistentModelID == listeID })
        guard let kandidaten = try? context.fetch(deskriptor) else { return nil }
        // Absturzfund 2026-08-24: `$0.artikel` ist hier (siehe Typ-Doku
        // ``alleSchluessel(context:)``) ohne `inverse`-Deklaration referenziert
        // und kann daher baumeln, wenn der referenzierte Artikel andernorts
        // (z.B. per Sync-Merge) gelöscht wurde. `persistentModelID` bleibt
        // darauf sicher lesbar, jede andere Eigenschaft — auch `.name` — stürzt
        // sonst mit einem SwiftData-Fatal-Error ab. Deshalb erst gegen die
        // Menge tatsächlich noch existierender Artikel-IDs prüfen, bevor
        // `.name` gelesen wird (dasselbe Muster wie ``alleGueltigenEintraege``).
        let gueltigeArtikelIDs = Set(((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map(\.persistentModelID))
        let produktID = produkt?.persistentModelID
        return kandidaten.first {
            guard $0.produkt?.persistentModelID == produktID else { return false }
            guard let kandidatArtikel = $0.artikel, gueltigeArtikelIDs.contains(kandidatArtikel.persistentModelID) else { return false }
            return kandidatArtikel.name.localizedCaseInsensitiveCompare(artikel.name) == .orderedSame
        }
    }

    /// Vermerkt dauerhaft, dass `artikel` von `einkaufsliste` abgehakt wurde —
    /// aufgerufen aus
    /// ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:produkt:am:context:ursprungsGeraeteID:abteilung:geschaeft:)``.
    /// Existiert bereits ein Eintrag für dieses Paar, wird `zuletztAbgehaktAm`
    /// nur nach VORNE (später) korrigiert, nie zurück — für den
    /// Einzelaufruf-Fall (ein Abhaken = eine Aktualisierung). Für Merge-Batches
    /// mit potenziell mehreren Einträgen desselben Paares siehe
    /// ``vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``.
    static func vermerkeAbgehakt(
        artikel: Artikel, produkt: Produkt? = nil, einkaufsliste: Einkaufsliste, am zeitpunkt: Date = Date(), context: ModelContext
    ) {
        if let bestehender = bestehenderEintrag(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, context: context) {
            if bestehender.zuletztAbgehaktAm == nil || zeitpunkt > bestehender.zuletztAbgehaktAm! {
                bestehender.zuletztAbgehaktAm = zeitpunkt
            }
            return
        }
        context.insert(ArtikelListenKauf(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, zuletztAbgehaktAm: zeitpunkt))
    }

    /// Wie ``vermerkeAbgehakt(artikel:einkaufsliste:am:context:)``, hält aber
    /// `bekannt` dabei selbst aktuell (Muster wie die "sofort
    /// nachführen"-Caches in ``SyncSnapshotImportService``) — für Merge-Läufe,
    /// die mehrere neue ``KaufEintrag``e/Fakten desselben (Artikel,
    /// Einkaufsliste)-Paares in einem Batch verarbeiten können. `bekannt`
    /// bildet auf das tatsächliche Objekt ab (nicht nur ein Set), damit ein
    /// zweiter Treffer desselben Paares IM SELBEN Batch dessen
    /// `zuletztAbgehaktAm` ebenfalls (nach vorne) aktualisieren kann, statt
    /// nur ein reines "schon angelegt, nichts weiter tun".
    /// `zeitpunkt == nil` (Peer/Altbestand ohne Zeitstempel-Info) legt einen
    /// neuen Eintrag ohne `zuletztAbgehaktAm` an bzw. lässt einen bestehenden
    /// unverändert — verwässert einen bereits bekannten Zeitstempel nie.
    static func vermerkeAbgehaktFallsNoetig(
        artikel: Artikel, produkt: Produkt? = nil, einkaufsliste: Einkaufsliste, am zeitpunkt: Date?,
        bekannt: inout [Schluessel: ArtikelListenKauf], context: ModelContext
    ) {
        let schluessel = Schluessel(artikelID: artikel.id, produktID: produkt?.id, einkaufslisteID: einkaufsliste.id)
        if let bestehender = bekannt[schluessel] {
            if let zeitpunkt, bestehender.zuletztAbgehaktAm == nil || zeitpunkt > bestehender.zuletztAbgehaktAm! {
                bestehender.zuletztAbgehaktAm = zeitpunkt
            }
            return
        }
        let neu = ArtikelListenKauf(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, zuletztAbgehaktAm: zeitpunkt)
        context.insert(neu)
        bekannt[schluessel] = neu
    }

    /// Symmetrisches Gegenstück zu ``vermerkeAbgehakt(artikel:einkaufsliste:am:context:)``
    /// — siehe Typ-Doku „``ArtikelListenKauf/zuletztHinzugefuegtAm``" für die
    /// Begründung. Vermerkt dauerhaft, dass `artikel` auf `einkaufsliste`
    /// (neu oder erneut) gesetzt wurde; bewegt `zuletztHinzugefuegtAm` wie dort
    /// nur nach VORNE, nie zurück.
    static func vermerkeHinzugefuegt(
        artikel: Artikel, produkt: Produkt? = nil, einkaufsliste: Einkaufsliste, am zeitpunkt: Date = Date(), context: ModelContext
    ) {
        if let bestehender = bestehenderEintrag(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, context: context) {
            if bestehender.zuletztHinzugefuegtAm == nil || zeitpunkt > bestehender.zuletztHinzugefuegtAm! {
                bestehender.zuletztHinzugefuegtAm = zeitpunkt
            }
            return
        }
        context.insert(ArtikelListenKauf(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, zuletztHinzugefuegtAm: zeitpunkt))
    }

    /// Batch-Variante von ``vermerkeHinzugefuegt(artikel:einkaufsliste:am:context:)``,
    /// analog ``vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``
    /// — nutzt denselben `bekannt`-Cache (eine Zeile pro (Artikel,Einkaufsliste)-Paar
    /// trägt beide Zeitstempel, siehe ``alleEintraege(context:)``).
    /// `zeitpunkt == nil` lässt einen bestehenden Eintrag unverändert und legt
    /// keinen neuen an (nichts Neues zu vermerken) — verwässert einen bereits
    /// bekannten Zeitstempel nie.
    static func vermerkeHinzugefuegtFallsNoetig(
        artikel: Artikel, produkt: Produkt? = nil, einkaufsliste: Einkaufsliste, am zeitpunkt: Date?,
        bekannt: inout [Schluessel: ArtikelListenKauf], context: ModelContext
    ) {
        guard let zeitpunkt else { return }
        let schluessel = Schluessel(artikelID: artikel.id, produktID: produkt?.id, einkaufslisteID: einkaufsliste.id)
        if let bestehender = bekannt[schluessel] {
            if bestehender.zuletztHinzugefuegtAm == nil || zeitpunkt > bestehender.zuletztHinzugefuegtAm! {
                bestehender.zuletztHinzugefuegtAm = zeitpunkt
            }
            return
        }
        let neu = ArtikelListenKauf(artikel: artikel, produkt: produkt, einkaufsliste: einkaufsliste, zuletztHinzugefuegtAm: zeitpunkt)
        context.insert(neu)
        bekannt[schluessel] = neu
    }

    /// Die zentrale, robuste Entscheidung „gilt der Artikel aktuell als
    /// offen" — rein auf Basis der beiden additiv gemergten, monotonen
    /// Zeitstempel (siehe Typ-Doku „``ArtikelListenKauf/zuletztHinzugefuegtAm``"),
    /// EINHEITLICH verwendet an beiden Stellen, die vorher je einen eigenen,
    /// teils fragilen Vergleich anstellten
    /// (``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``,
    /// ``SyncSnapshotImportService/mergeKaufEintraege(_:artikelZuordnung:einkaufsvorgangZuordnung:geschaeftZuordnung:abteilungZuordnung:peerGeraeteID:context:)``).
    ///
    /// Bewusst BEIDE Werte erforderlich (kein Default-„offen" bei fehlendem
    /// `abgehaktAm`): eine bestehende ``ArtikelListenKauf``-Zeile OHNE
    /// `zuletztAbgehaktAm` (Altbestand vor dessen Einführung, GitHub #99)
    /// bedeutet weiterhin „schon mal gekauft, nur kein Vergleichswert" — also
    /// NICHT offen, dasselbe permanente Veto wie zuvor, keine Lockerung ohne
    /// echten Vergleichswert auf beiden Seiten.
    static func istOffen(hinzugefuegtAm: Date?, abgehaktAm: Date?) -> Bool {
        guard let hinzugefuegtAm, let abgehaktAm else { return false }
        return hinzugefuegtAm > abgehaktAm
    }

    /// Alle lokal bekannten (Artikel, Einkaufsliste)-Schlüssel — für
    /// wiederholte Existenz-Prüfungen innerhalb eines Merge-Durchlaufs
    /// effizienter als einzelne Existenz-Checks (Muster wie
    /// ``SyncTombstoneService/geloeschteIDs(art:context:)``).
    ///
    /// **Absichtlich über `persistentModelID` abgesichert, bevor `.id` gelesen
    /// wird** (Muster wie ``SyncSnapshotExportService/sichereID(_:gueltigeIDs:)``):
    /// `artikel`/`einkaufsliste` sind hier ohne `inverse`-Deklaration
    /// referenziert (wie ``ArtikelGeschaeftVerfuegbarkeit``) — wird der
    /// referenzierte ``Artikel``/die referenzierte ``Einkaufsliste``
    /// andernorts gelöscht, bleibt die Referenz eine "baumelnde"
    /// `PersistentIdentifier`-only-Referenz. `persistentModelID` bleibt darauf
    /// sicher lesbar, jede andere Eigenschaft (auch nur `.id`) stürzt sonst
    /// mit einem SwiftData-Fatal-Error ab (siehe
    /// `docs/DATABASE_CONCURRENCY.md`).
    static func alleSchluessel(context: ModelContext) -> Set<Schluessel> {
        Set(alleGueltigenEintraege(context: context).map { $0.0 })
    }

    /// Wie ``alleSchluessel(context:)``, aber mit dem tatsächlichen Objekt
    /// statt nur dem Schlüssel — Grundlage für
    /// ``vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:am:bekannt:context:)``s
    /// `bekannt`-Parameter: ein Merge-Batch muss bereits VOR diesem Durchlauf
    /// bestehende Zeilen erkennen (sonst legt er Dubletten an) UND deren
    /// `zuletztAbgehaktAm` bei einem neueren Treffer im selben Batch
    /// aktualisieren können (dafür reicht ein reines `Set<Schluessel>` nicht).
    static func alleEintraege(context: ModelContext) -> [Schluessel: ArtikelListenKauf] {
        let gueltigeArtikelIDs = Set(((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map(\.persistentModelID))
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))
        // Wie `artikel`/`einkaufsliste` unten ohne `inverse`-Deklaration
        // referenziert, also derselbe Baumel-Schutz vor dem Lesen von `.id`.
        let gueltigeProduktIDs = Set(((try? context.fetch(FetchDescriptor<Produkt>())) ?? []).map(\.persistentModelID))
        let alle = (try? context.fetch(FetchDescriptor<ArtikelListenKauf>())) ?? []
        var ergebnis: [Schluessel: ArtikelListenKauf] = [:]
        for eintrag in alle {
            guard let artikel = eintrag.artikel, gueltigeArtikelIDs.contains(artikel.persistentModelID),
                  let einkaufsliste = eintrag.einkaufsliste, gueltigeEinkaufslistenIDs.contains(einkaufsliste.persistentModelID)
            else { continue }
            if let produkt = eintrag.produkt, !gueltigeProduktIDs.contains(produkt.persistentModelID) { continue }
            ergebnis[Schluessel(artikelID: artikel.id, produktID: eintrag.produkt?.id, einkaufslisteID: einkaufsliste.id)] = eintrag
        }
        return ergebnis
    }

    /// Wie ``alleSchluessel(context:)``, aber mit `zuletztAbgehaktAm` statt
    /// nur der reinen Existenz — Grundlage für
    /// ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:bekannterEintrag:)``s
    /// Vergleich „ist der vom Peer gemeldete Listen-Eintrag NEUER als der
    /// letzte bekannte Kauf". **Bewusst `Date?` als WERT, nicht als
    /// herausgefilterte Abwesenheit** — ein bekanntes Paar OHNE Zeitstempel
    /// (Altbestand vor Einführung dieses Felds) muss sich für den Aufrufer
    /// klar von einem komplett UNBEKANNTEN Paar unterscheiden lassen: Ersteres
    /// bedeutet weiterhin „schon mal gekauft, aber kein Vergleichswert" (also
    /// blockieren), Letzteres „noch nie gekauft" (also durchlassen).
    static func alleZeitstempel(context: ModelContext) -> [Schluessel: Date?] {
        Dictionary(uniqueKeysWithValues: alleGueltigenEintraege(context: context))
    }

    private static func alleGueltigenEintraege(context: ModelContext) -> [(Schluessel, Date?)] {
        let gueltigeArtikelIDs = Set(((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map(\.persistentModelID))
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))
        let gueltigeProduktIDs = Set(((try? context.fetch(FetchDescriptor<Produkt>())) ?? []).map(\.persistentModelID))
        let alle = (try? context.fetch(FetchDescriptor<ArtikelListenKauf>())) ?? []
        return alle.compactMap { eintrag -> (Schluessel, Date?)? in
            guard let artikel = eintrag.artikel, gueltigeArtikelIDs.contains(artikel.persistentModelID),
                  let einkaufsliste = eintrag.einkaufsliste, gueltigeEinkaufslistenIDs.contains(einkaufsliste.persistentModelID)
            else { return nil }
            if let produkt = eintrag.produkt, !gueltigeProduktIDs.contains(produkt.persistentModelID) { return nil }
            return (Schluessel(artikelID: artikel.id, produktID: eintrag.produkt?.id, einkaufslisteID: einkaufsliste.id), eintrag.zuletztAbgehaktAm)
        }
    }
}
