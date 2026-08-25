import Foundation
import SwiftData

/// Merkt vor, dass eine ``Artikel``↔``Abteilung``-Zuordnung absichtlich entfernt
/// wurde (GitHub #173) — Gegenstück zu ``SyncTombstone`` (der eine ganze
/// gelöschte Entität vormerkt), hier aber für eine einzelne Kante einer
/// ansonsten additiven Mehrfachbeziehung.
///
/// **Warum nötig:** ``Artikel/abteilungen`` wird beim Sync-Merge rein additiv
/// vereinigt (`SyncSnapshotImportService.vervollstaendige`,
/// `docs/DATENSYNCHRONISATION.md` §4.1) — absichtlich so, damit zwei Geräte
/// offline unterschiedliche Abteilungen zum selben Artikel hinzufügen können,
/// ohne dass beim nächsten Sync eine der beiden Ergänzungen verloren geht.
/// Ohne diesen Tombstone wäre ein lokal entfernter Eintrag deshalb nie wirklich
/// entfernt: ein Peer, der die alte Zuordnung noch in seinem Snapshot führt,
/// würde sie bei jedem weiteren Sync-Zyklus erneut hinzufügen.
///
/// **Derselbe Lamport-Zähler-Trick wie §4.1a, aber mit einem eigenen,
/// dedizierten Zähler statt Mitbenutzung von ``Artikel/lamportZaehler``:**
/// `lamportZaehler` ist der Stand von ``Artikel/abteilungenLamportZaehler``
/// **zum Zeitpunkt des Entfernens**. Beim Merge (`vervollstaendige`) wird eine
/// remote gemeldete Abteilungs-ID nur dann wieder aufgenommen, wenn der
/// `abteilungenLamportZaehler` des einliefernden ``ArtikelSnapshot`` diesen
/// Wert übersteigt — ein Beweis, dass auf jenem Gerät seither tatsächlich eine
/// spätere Abteilungs-Bearbeitung stattfand. **Bewusst NICHT**
/// ``Artikel/lamportZaehler`` (den ``name``/``einheit``/``mengenSchritt``
/// gemeinsam nutzen, §4.1a): `abteilungen` ist eine additive Mehrfachbeziehung
/// mit Tombstone-Entfernen, ein grundverschiedenes CRDT-Muster von den dort
/// gebündelten „ersetzenden" Skalarfeldern — ein gemeinsamer Zähler hätte eine
/// bloße Umbenennung einen Tombstone unbeabsichtigt entwerten lassen und
/// umgekehrt jede Abteilungs-Änderung einen eigentlich unveränderten
/// Namen/Einheit-Stand angreifbarer gemacht (Live-Fund während der Umsetzung,
/// GitHub #173 — siehe `docs/DATENSYNCHRONISATION.md` §4.1b). Der dedizierte
/// Zähler macht den Vergleich dadurch sogar präziser als §4.1a: er bewegt sich
/// ausschließlich durch tatsächliche Abteilungs-Änderungen.
///
/// **Absichtlich kein Löschen bei einem lokalen Wieder-Hinzufügen:** Ein
/// bereits getombstonter Tombstone bleibt liegen (analog ``SyncTombstone``,
/// „vorher bewusst unbegrenzt") — er wird beim nächsten Export einfach mit
/// exportiert und ist harmlos, weil das Wieder-Hinzufügen den
/// `Artikel.abteilungenLamportZaehler` bereits über den Tombstone-Stand
/// angehoben hat (siehe oben). **Bekannte, aktuell folgenlose Lücke:** anders als
/// ``SyncTombstone`` gibt es für diese Tabelle noch keine
/// Aufräum-/Bereinigungsroutine (`SyncTombstoneService/raeumeAlteTombstonesAufFallsFaellig`-
/// Äquivalent) — bei sehr vielen Entfernungen wächst sie unbegrenzt. Aktuell
/// kein Live-Problem (Abteilungs-Zuordnungen ändern sich selten), aber ein
/// naheliegender Folgeschritt, falls das relevant wird.
@Model
final class ArtikelAbteilungsTombstone {
    var artikelID: UUID
    var abteilungID: UUID
    var lamportZaehler: UInt64
    var entferntAm: Date

    init(artikelID: UUID, abteilungID: UUID, lamportZaehler: UInt64, entferntAm: Date = Date()) {
        self.artikelID = artikelID
        self.abteilungID = abteilungID
        self.lamportZaehler = lamportZaehler
        self.entferntAm = entferntAm
    }
}

enum ArtikelAbteilungsTombstoneService {
    /// Merkt ein lokales Entfernen vor. `lamportZaehler` ist der Aufrufer-Stand
    /// von `artikel.abteilungenLamportZaehler` **nach** dem zugehörigen
    /// ``Artikel/markiereAbteilungenGeaendert()``-Aufruf — nicht hier selbst per
    /// ``LamportClock`` gezogen, damit Tombstone-Tick und der exportierte
    /// ``ArtikelSnapshot/abteilungenLamportZaehler`` garantiert derselbe Wert
    /// sind (siehe Typ-Doku). Idempotent für dieselbe (`artikelID`, `abteilungID`):
    /// ein bereits bestehender Tombstone wird auf den neuen, höheren Zähler
    /// angehoben statt dupliziert (relevant bei wiederholtem
    /// Entfernen/Wieder-Hinzufügen/Entfernen derselben Kombination).
    @discardableResult
    static func markiereEntfernt(artikelID: UUID, abteilungID: UUID, lamportZaehler: UInt64, context: ModelContext) -> ArtikelAbteilungsTombstone {
        if let bestehender = tombstone(artikelID: artikelID, abteilungID: abteilungID, context: context) {
            bestehender.lamportZaehler = lamportZaehler
            bestehender.entferntAm = Date()
            return bestehender
        }
        let neuer = ArtikelAbteilungsTombstone(artikelID: artikelID, abteilungID: abteilungID, lamportZaehler: lamportZaehler)
        context.insert(neuer)
        return neuer
    }

    /// Übernimmt einen von einem Peer empfangenen Tombstone — analog
    /// ``markiereEntfernt(artikelID:abteilungID:lamportZaehler:context:)``,
    /// aber ohne den lokalen `lamportZaehler` je zu SENKEN (ein älterer,
    /// nachträglich empfangener Peer-Stand darf einen bereits höheren
    /// lokalen Stand nicht zurückdrehen).
    static func uebernehmeFremdenTombstone(artikelID: UUID, abteilungID: UUID, lamportZaehler: UInt64, context: ModelContext) {
        if let bestehender = tombstone(artikelID: artikelID, abteilungID: abteilungID, context: context) {
            guard lamportZaehler > bestehender.lamportZaehler else { return }
            bestehender.lamportZaehler = lamportZaehler
            return
        }
        context.insert(ArtikelAbteilungsTombstone(artikelID: artikelID, abteilungID: abteilungID, lamportZaehler: lamportZaehler))
    }

    private static func tombstone(artikelID: UUID, abteilungID: UUID, context: ModelContext) -> ArtikelAbteilungsTombstone? {
        var deskriptor = FetchDescriptor<ArtikelAbteilungsTombstone>(
            predicate: #Predicate { $0.artikelID == artikelID && $0.abteilungID == abteilungID }
        )
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Alle lokal bekannten Tombstones, indiziert nach Artikel- dann
    /// Abteilungs-ID — für effizienten Merge einmal pro Sync-Zyklus geladen
    /// statt pro Artikel einzeln gefetcht (Muster wie
    /// ``SyncTombstoneService/geloeschteIDs(art:context:)``).
    static func alleNachArtikel(context: ModelContext) -> [UUID: [UUID: UInt64]] {
        let alle = (try? context.fetch(FetchDescriptor<ArtikelAbteilungsTombstone>())) ?? []
        var ergebnis: [UUID: [UUID: UInt64]] = [:]
        for eintrag in alle {
            ergebnis[eintrag.artikelID, default: [:]][eintrag.abteilungID] = eintrag.lamportZaehler
        }
        return ergebnis
    }

    /// Alle lokal bekannten Tombstones — für den Snapshot-Export.
    static func alle(context: ModelContext) -> [ArtikelAbteilungsTombstone] {
        (try? context.fetch(FetchDescriptor<ArtikelAbteilungsTombstone>())) ?? []
    }
}
