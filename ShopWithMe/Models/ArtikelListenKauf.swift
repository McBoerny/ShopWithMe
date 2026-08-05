import Foundation
import SwiftData

/// Dauerhafte, von ``KaufEintrag``/``Einkaufsvorgang`` unabhängige Tatsache:
/// „``artikel`` wurde mindestens einmal von ``einkaufsliste`` abgehakt" —
/// Grundlage für das Sicherheitsnetz gegen wiederbelebte Käufe in
/// ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:alleVorgaenge:istAusDerZeitGefallen:jemalsAbgehakteSchluessel:)``
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
/// eine Zeile pro (``Artikel``, ``Einkaufsliste``)-Paar, reine
/// Existenz-Tatsache ohne Zähler/Zeitstempel — kein Tombstone nötig (wird vom
/// Nutzer nie direkt gelöscht), bleibt auch nach der 48h-Löschung des
/// zugrundeliegenden ``KaufEintrag`` unverändert bestehen, und hängt bewusst
/// NICHT an der Tombstone-Aufräum-Watermark (Peer-Lebenszyklus, siehe
/// `docs/PEER_LEBENSZYKLUS.md`) — die Absicherung soll unabhängig von deren
/// Timing dauerhaft gelten, nicht nur "so lange, bis der zugehörige Tombstone
/// aufgeräumt wird".
@Model
final class ArtikelListenKauf {
    /// Eindeutige Kennung.
    var id: UUID
    var artikel: Artikel?
    var einkaufsliste: Einkaufsliste?

    init(artikel: Artikel?, einkaufsliste: Einkaufsliste?) {
        self.id = UUID()
        self.artikel = artikel
        self.einkaufsliste = einkaufsliste
    }
}

enum ArtikelListenKaufService {
    /// Schlüssel für Set-basierte Existenz-Prüfungen über ein
    /// (``Artikel``, ``Einkaufsliste``)-Paar — verwendet die app-eigenen
    /// `UUID`s (nicht `persistentModelID`), damit sich der Schlüssel auch für
    /// Objekte bilden lässt, die (noch) nicht im selben ``ModelContext``
    /// verankert sind (analog ``SyncEventService/PaarSchluessel``).
    struct Schluessel: Hashable {
        let artikelID: UUID
        let einkaufslisteID: UUID
    }

    /// Ob `artikel` jemals von `einkaufsliste` abgehakt wurde.
    static func istJemalsAbgehakt(artikel: Artikel, einkaufsliste: Einkaufsliste, context: ModelContext) -> Bool {
        let artikelID = artikel.persistentModelID
        let listeID = einkaufsliste.persistentModelID
        let deskriptor = FetchDescriptor<ArtikelListenKauf>(
            predicate: #Predicate { $0.artikel?.persistentModelID == artikelID && $0.einkaufsliste?.persistentModelID == listeID }
        )
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }

    /// Vermerkt dauerhaft, dass `artikel` von `einkaufsliste` abgehakt wurde —
    /// aufgerufen aus
    /// ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:ursprungsGeraeteID:kategorie:geschaeft:)``.
    /// Idempotent: eine bereits bekannte Kombination erzeugt keine weitere
    /// Zeile (reine Existenz-Tatsache, kein Zähler) — für den
    /// Einzelaufruf-Fall (ein Abhaken = ein Existenz-Check). Für Merge-Batches
    /// mit potenziell mehreren Einträgen desselben Paares siehe
    /// ``vermerkeAbgehaktFallsNoetig(artikel:einkaufsliste:bekannt:context:)``.
    static func vermerkeAbgehakt(artikel: Artikel, einkaufsliste: Einkaufsliste, context: ModelContext) {
        guard !istJemalsAbgehakt(artikel: artikel, einkaufsliste: einkaufsliste, context: context) else { return }
        context.insert(ArtikelListenKauf(artikel: artikel, einkaufsliste: einkaufsliste))
    }

    /// Wie ``vermerkeAbgehakt(artikel:einkaufsliste:context:)``, hält aber
    /// `bekannt` dabei selbst aktuell (Muster wie die "sofort
    /// nachführen"-Caches in ``SyncSnapshotImportService``) — für Merge-Läufe,
    /// die mehrere neue ``KaufEintrag``e desselben (Artikel,
    /// Einkaufsliste)-Paares in einem Batch verarbeiten können
    /// (``SyncSnapshotImportService/mergeKaufEintraege(_:artikelZuordnung:einkaufsvorgangZuordnung:geschaeftZuordnung:kategorieZuordnung:peerGeraeteID:context:)``)
    /// und dafür nicht pro Eintrag einen eigenen Existenz-Check ausführen sollen.
    static func vermerkeAbgehaktFallsNoetig(
        artikel: Artikel, einkaufsliste: Einkaufsliste, bekannt: inout Set<Schluessel>, context: ModelContext
    ) {
        let schluessel = Schluessel(artikelID: artikel.id, einkaufslisteID: einkaufsliste.id)
        guard !bekannt.contains(schluessel) else { return }
        context.insert(ArtikelListenKauf(artikel: artikel, einkaufsliste: einkaufsliste))
        bekannt.insert(schluessel)
    }

    /// Alle lokal bekannten (Artikel, Einkaufsliste)-Schlüssel — für
    /// wiederholte Prüfungen innerhalb eines Merge-Durchlaufs effizienter als
    /// einzelne Existenz-Checks (Muster wie
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
        let gueltigeArtikelIDs = Set(((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map(\.persistentModelID))
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))
        let alle = (try? context.fetch(FetchDescriptor<ArtikelListenKauf>())) ?? []
        return Set(alle.compactMap { eintrag -> Schluessel? in
            guard let artikel = eintrag.artikel, gueltigeArtikelIDs.contains(artikel.persistentModelID),
                  let einkaufsliste = eintrag.einkaufsliste, gueltigeEinkaufslistenIDs.contains(einkaufsliste.persistentModelID)
            else { return nil }
            return Schluessel(artikelID: artikel.id, einkaufslisteID: einkaufsliste.id)
        })
    }
}
