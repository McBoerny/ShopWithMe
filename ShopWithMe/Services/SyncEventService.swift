import Foundation
import SwiftData

/// Zeichnet ``SyncEvent``e für die geplante Datensynchronisation auf
/// (`docs/DATENSYNCHRONISATION_VERLAUF.md`, GitHub #39, Phase 0) — die
/// einzige Stelle, die einen ``SyncEvent`` erzeugt, damit Lamport-Zähler-Vergabe
/// und Geräte-ID-Zuordnung konsistent an einem Ort passieren.
///
/// Aufgerufen von den bestehenden Bereich-A-Mutationsfunktionen
/// (``Einkaufsliste/artikelHinzufuegen(_:context:)``,
/// ``Einkaufsvorgang/artikelAbhaken(_:context:)``, …) direkt im Anschluss an die
/// eigentliche Modelländerung — diese Funktionen bleiben die einzige Quelle für
/// Änderungen, sowohl bei lokal ausgelösten Aktionen als auch (ab Phase 2 des
/// Plans) beim Anwenden empfangener Remote-Events.
enum SyncEventService {
    @discardableResult
    static func aufzeichnen(
        _ art: SyncEventArt,
        bezugsID: UUID,
        artikelID: UUID,
        context: ModelContext
    ) -> SyncEvent {
        let event = SyncEvent(
            art: art,
            nutzlast: SyncEventNutzlast(bezugsID: bezugsID, artikelID: artikelID),
            lamportZaehler: LamportClock.naechsterZaehler(),
            lamportGeraeteID: DatabaseLeaseService.geraeteID,
            autorGeraeteID: DatabaseLeaseService.geraeteID
        )
        context.insert(event)
        return event
    }

    /// Übernimmt ein von einem Peer empfangenes Event unverändert in die lokale
    /// Datenbank (Phase 2, `SyncImportService`) — im Unterschied zu
    /// ``aufzeichnen(_:bezugsID:artikelID:context:)`` wird KEIN neuer
    /// Lamport-Zähler vergeben und KEINE eigene Autorenschaft gesetzt (siehe
    /// ``SyncEvent/init(empfangen:)``). Gleicht die eigene Uhr über
    /// ``LamportClock/beiEmpfang(fremderZaehler:)`` ab.
    @discardableResult
    static func uebernehmen(_ empfangen: SyncEventExportDarstellung, context: ModelContext) -> SyncEvent {
        LamportClock.beiEmpfang(fremderZaehler: empfangen.lamportZaehler)
        let event = SyncEvent(empfangen: empfangen)
        context.insert(event)
        return event
    }

    /// Ob bereits ein lokales ``SyncEvent`` mit dieser `id` existiert — Grundlage
    /// für die Idempotenz des Imports (``SyncImportService``): ein Event, das
    /// schon einmal übernommen wurde (eigenes oder bereits importiertes fremdes),
    /// darf nicht ein zweites Mal angewendet werden.
    static func istBereitsBekannt(_ id: UUID, context: ModelContext) -> Bool {
        var deskriptor = FetchDescriptor<SyncEvent>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return ((try? context.fetchCount(deskriptor)) ?? 0) > 0
    }

    /// Das unter allen lokal bekannten Events (eigene wie bereits importierte
    /// fremde) zu diesem (`bezugsID`, `artikelID`)-Paar aktuell gewinnende Event
    /// laut ``SyncKonfliktAufloesung`` — `nil`, falls keines bekannt ist.
    ///
    /// Genutzt sowohl von ``SyncImportService`` (Konfliktprüfung vor dem
    /// Anwenden eines neu empfangenen Events) als auch vom Überkauf-Hinweis
    /// (GitHub #48, ``Einkaufsvorgang/artikelAbhakenOhneEventAufzeichnung(_:context:)``),
    /// um herauszufinden, welches Gerät einen bereits vorhandenen `KaufEintrag`
    /// ursprünglich ausgelöst hat.
    ///
    /// Performance-Hinweis: durchsucht aktuell alle lokalen `SyncEvent`s (kein
    /// indiziertes Prädikat auf der JSON-kodierten Nutzlast möglich) — für den
    /// heutigen Umfang unkritisch, potenzieller Optimierungspunkt, falls der
    /// Event-Log deutlich wächst.
    static func aktuellerGewinner(bezugsID: UUID, artikelID: UUID, context: ModelContext) -> SyncEvent? {
        let kandidaten = ((try? context.fetch(FetchDescriptor<SyncEvent>())) ?? []).filter { event in
            guard let nutzlast = event.nutzlastDekodiert else { return false }
            return nutzlast.bezugsID == bezugsID && nutzlast.artikelID == artikelID
        }
        return kandidaten.reduce(nil) { (bisher: SyncEvent?, kandidat: SyncEvent) -> SyncEvent? in
            guard let bisher, let bisherigeArt = bisher.art, let kandidatArt = kandidat.art else {
                return bisher == nil ? kandidat : bisher
            }
            let gewinntKandidat = SyncKonfliktAufloesung.gewinnt(
                SyncKonfliktAufloesung.Kandidat(art: kandidatArt, lamportZaehler: kandidat.lamportZaehler),
                ueber: SyncKonfliktAufloesung.Kandidat(art: bisherigeArt, lamportZaehler: bisher.lamportZaehler)
            )
            return gewinntKandidat ? kandidat : bisher
        }
    }

    /// Schlüssel für den Gewinner-Index (``alleAktuellenGewinner(context:)``).
    struct PaarSchluessel: Hashable {
        var bezugsID: UUID
        var artikelID: UUID
    }

    /// Baut den aktuell gewinnenden ``SyncEvent`` je (`bezugsID`,`artikelID`)-Paar
    /// für ALLE lokal bekannten Events in EINEM Durchlauf (Performance-Fund) —
    /// für ``SyncImportService``, das sonst pro eingehendem Event erneut per
    /// ``aktuellerGewinner(bezugsID:artikelID:context:)`` die komplette Tabelle
    /// fetchen und jede Nutzlast erneut dekodieren müsste (O(n²) bei n
    /// eingehenden Events in einem Zyklus statt O(n) für den Indexaufbau).
    /// **Nur für diesen Batch-Anwendungsfall** — die einmalige Einzelabfrage
    /// (z.B. der Überkauf-Hinweis in ``Einkaufsvorgang``) bleibt bei
    /// ``aktuellerGewinner(bezugsID:artikelID:context:)``, ein voller
    /// Indexaufbau lohnt sich dort nicht.
    ///
    /// Der Aufrufer muss den zurückgegebenen Index während der Verarbeitung
    /// selbst aktuell halten (siehe ``SyncImportService/wendeAn(_:gewinner:context:)``):
    /// ein innerhalb desselben Zyklus neu übernommenes Event kann den
    /// Gewinner für sein eigenes Paar sofort ändern, dieser Index ist nur eine
    /// Momentaufnahme zum Zeitpunkt des Aufrufs.
    static func alleAktuellenGewinner(context: ModelContext) -> [PaarSchluessel: SyncEvent] {
        let alle = (try? context.fetch(FetchDescriptor<SyncEvent>())) ?? []
        var gewinner: [PaarSchluessel: SyncEvent] = [:]
        for event in alle {
            guard let nutzlast = event.nutzlastDekodiert, let art = event.art else { continue }
            let schluessel = PaarSchluessel(bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID)
            guard let bisheriger = gewinner[schluessel], let bisherigeArt = bisheriger.art else {
                gewinner[schluessel] = event
                continue
            }
            let kandidatGewinnt = SyncKonfliktAufloesung.gewinnt(
                SyncKonfliktAufloesung.Kandidat(art: art, lamportZaehler: event.lamportZaehler),
                ueber: SyncKonfliktAufloesung.Kandidat(art: bisherigeArt, lamportZaehler: bisheriger.lamportZaehler)
            )
            if kandidatGewinnt { gewinner[schluessel] = event }
        }
        return gewinner
    }
}
