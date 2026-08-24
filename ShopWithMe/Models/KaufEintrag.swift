import Foundation
import SwiftData

/// Ein einzelner Kauf eines Artikels — die operative Buchungszeile eines
/// laufenden ``Einkaufsvorgang``s (Dedupe-Schutz, Entfernen von der Liste,
/// ``abteilungBesuchsIndex`` für ``AbteilungsDistanzService``).
///
/// **Seit GitHub #76 keine Preishistorie-Rolle mehr** — die ist nach
/// ``Preispunkt`` verschoben, da sie fachlich unabhängig vom laufenden
/// Einkauf ist (z.B. beim Preisschild-Scan ganz ohne ``Einkaufsvorgang``) und
/// anders wächst (jeder Kauf vs. nur echte Preisänderungen). `preis`/
/// `produktName`/`alternativerName` bleiben als migrierte Altlast auf diesem
/// Typ bestehen, siehe deren Dokumentation und
/// ``preisverlaufMigrierenFallsNoetig(context:)``.
///
/// `artikelNameSnapshot`/`geschaeftNameSnapshot` speichern den Namen zum Kaufzeitpunkt
/// dauerhaft, damit ``passtZu(name:eintrag:)`` in ``BelegScanView`` auch dann noch
/// funktioniert, wenn der zugehörige ``Artikel`` oder ``Geschaeft`` später
/// umbenannt oder gelöscht wird.
@Model
final class KaufEintrag {
    /// Eindeutige Kennung. `@Attribute(.unique)` seit GitHub #102 (vorher
    /// unindiziert, jeder ID-Lookup im Sync-Merge war ein Full-Table-Scan) —
    /// sicher eingeführt erst nach Prüfung des realen Bestands per
    /// ``ModellIDDuplikatService`` auf bereits bestehende Duplikate.
    @Attribute(.unique) var id: UUID
    /// Der gekaufte Artikel (kann `nil` werden, wenn der Artikel später gelöscht wird).
    var artikel: Artikel?
    /// Der Einkaufsvorgang, zu dem dieser Kauf gehört.
    var einkaufsvorgang: Einkaufsvorgang?
    /// Das Geschäft, in dem der Kauf stattfand.
    var geschaeft: Geschaeft?
    /// Die Abteilung des Artikels zum Kaufzeitpunkt — Grundlage für
    /// ``AbteilungsDistanzService``, unabhängig von einer späteren Änderung der
    /// Artikel-Abteilung-Zuordnung.
    var abteilung: Abteilung?
    /// Name des Artikels zum Kaufzeitpunkt (dauerhafter Schnappschuss).
    var artikelNameSnapshot: String
    /// Name des Geschäfts zum Kaufzeitpunkt (dauerhafter Schnappschuss).
    var geschaeftNameSnapshot: String
    /// **Altlast seit GitHub #76** (Preishistorie-Rolle nach ``Preispunkt``
    /// verschoben, analog ``Geschaeft/typenRaw``): wird nicht mehr befüllt,
    /// bleibt nur, bis ``preisverlaufMigrierenFallsNoetig(context:)`` sie beim
    /// nächsten App-Start liest und danach auf `nil` zurücksetzt. Niemals neu
    /// lesen oder schreiben — siehe ``Preispunkt/produktName``.
    var produktName: String?
    /// **Altlast seit GitHub #76**, siehe ``produktName`` — siehe
    /// ``Preispunkt/alternativerName``.
    var alternativerName: String?
    /// Datum des Kaufs.
    var datum: Date
    /// **Altlast seit GitHub #76**, siehe ``produktName`` — siehe
    /// ``Preispunkt/preis``.
    var preis: Decimal?
    /// Gekaufte Menge (Standard: 1).
    var menge: Double
    /// Position in der chronologischen Abteilung-Besuchsreihenfolge dieses
    /// Einkaufsvorgangs — Grundlage für ``AbteilungsDistanzService``.
    var abteilungBesuchsIndex: Int?
    /// `nil`, wenn dieser Eintrag lokal auf diesem Gerät entstanden ist (oder ein
    /// Altdatensatz von vor Einführung dieses Attributs ist); sonst die Geräte-ID
    /// des Peers, von dem er per Sync-Event oder Snapshot übernommen wurde —
    /// analog ``SyncEvent/autorGeraeteID`` (GitHub #68).
    ///
    /// `init` erzwingt zentral, dass ein fremder Ursprung nie einen
    /// ``abteilungBesuchsIndex`` bekommt: ein von einem ANDEREN Gerät stammender
    /// Eintrag beschreibt dessen Laufreihenfolge durch den Laden, nicht die
    /// dieses Geräts — würde er trotzdem einen Index bekommen, würde er
    /// fälschlich als eigene Beobachtung in die lokal gelernte, ladenspezifische
    /// Distanzmatrix (``AbteilungsDistanzService``) einfließen. Vorher war diese
    /// Regel nur an den beiden Konstruktions-Call-Sites von Hand nachgebildet
    /// (``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:abteilung:geschaeft:)``,
    /// ``SyncSnapshotImportService``) — hier im Typ selbst gilt sie automatisch
    /// für jeden, auch künftigen, Konstruktionsort.
    var ursprungsGeraeteID: String?

    init(
        artikel: Artikel?,
        geschaeft: Geschaeft?,
        abteilung: Abteilung? = nil,
        preis: Decimal? = nil,
        menge: Double = 1,
        datum: Date = Date(),
        abteilungBesuchsIndex: Int? = nil,
        ursprungsGeraeteID: String? = nil
    ) {
        self.id = UUID()
        self.artikel = artikel
        self.geschaeft = geschaeft
        self.abteilung = abteilung
        self.artikelNameSnapshot = artikel?.name ?? ""
        self.geschaeftNameSnapshot = geschaeft?.name ?? ""
        self.datum = datum
        self.preis = preis
        self.menge = menge
        self.ursprungsGeraeteID = ursprungsGeraeteID
        self.abteilungBesuchsIndex = ursprungsGeraeteID == nil ? abteilungBesuchsIndex : nil
    }
}

extension KaufEintrag {
    /// Der Name von ``artikel``, sofern er noch tatsächlich existiert (nicht
    /// bereits eine baumelnde Referenz auf einen gelöschten Artikel ist —
    /// siehe `docs/DATABASE_CONCURRENCY.md`), sonst der dauerhafte
    /// ``artikelNameSnapshot``. `modelContext` ist hier sicher lesbar, da
    /// `self` (im Gegensatz zu einem möglicherweise baumelnden ``artikel``)
    /// immer ein gültiges, gerade abgefragtes Objekt ist.
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

    /// Migriert vor GitHub #76 erfasste Preise/Namen (``preis``/``produktName``/
    /// ``alternativerName``, jetzt Altlast-Felder) einmalig nach ``Preispunkt``/
    /// ``Produktname``/``Artikel/alternativeNamen`` (GitHub #128, vormals
    /// `ArtikelAlias`) — dieselbe Rolle wie
    /// ``Geschaeft/typenMigrierenFallsNoetig(context:)``. Wird beim App-Start
    /// aufgerufen (siehe ``ShopWithMeApp``).
    ///
    /// Verarbeitet chronologisch aufsteigend nach ``datum``, damit
    /// ``PreispunktService`` die Preishistorie korrekt auf echte Änderungen
    /// komprimiert (Slowly-Changing-Dimension-Muster). Setzt die migrierten
    /// Altlast-Felder danach auf `nil` zurück — macht die Funktion idempotent
    /// (ein wiederholter Aufruf findet nichts mehr vor) und verhindert
    /// doppelte ``Preispunkt``e bei jedem weiteren App-Start.
    @MainActor
    static func preisverlaufMigrierenFallsNoetig(context: ModelContext) {
        let deskriptor = FetchDescriptor<KaufEintrag>(sortBy: [SortDescriptor(\.datum, order: .forward)])
        let alle = (try? context.fetch(deskriptor)) ?? []
        for eintrag in alle {
            // Produkt-Pflicht bei ``Preispunkt``: ohne Artikel-Zuordnung lässt
            // sich kein Produkt bestimmen, der historische Preis wird dann
            // nicht migriert (die operative Buchungszeile selbst bleibt
            // unangetastet).
            guard let preis = eintrag.preis, let artikel = eintrag.artikel else { continue }
            // Geschäfts-Pflicht bei ``Preispunkt``: historische Einträge ohne
            // Geschäft bekommen das Pseudo-Geschäft (siehe
            // ``Geschaeft/unbekanntesGeschaeft(context:)``).
            let geschaeft = eintrag.geschaeft ?? Geschaeft.unbekanntesGeschaeft(context: context)
            let produkt = Produkt.standardProdukt(fuer: artikel, context: context)
            PreispunktService.erfassen(
                preis: preis, produkt: produkt, geschaeft: geschaeft, datum: eintrag.datum,
                produktName: eintrag.produktName, alternativerName: eintrag.alternativerName, context: context
            )
            if let alternativerName = eintrag.alternativerName,
               !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let erkannterName = eintrag.produktName ?? eintrag.artikelNameSnapshot
                if !erkannterName.isEmpty {
                    if !produkt.produktnamen.contains(where: {
                        $0.geschaeft == nil && $0.name.localizedCaseInsensitiveCompare(erkannterName) == .orderedSame
                    }) {
                        context.insert(Produktname(name: erkannterName, produkt: produkt, geschaeft: nil))
                    }
                }
                artikel.alternativenNamenLernen(alternativerName)
            }
            eintrag.preis = nil
            eintrag.produktName = nil
            eintrag.alternativerName = nil
        }
    }
}
