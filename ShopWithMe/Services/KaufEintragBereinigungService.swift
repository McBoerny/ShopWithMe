import Foundation
import SwiftData

/// Automatische, für den Nutzer unsichtbare Bereinigung bereits verarbeiteter
/// ``KaufEintrag``e (GitHub #76, Phase 2) — anders als die nutzerkonfigurierbare
/// Preishistorie-Aufbewahrung (``PreisHistorieBereinigungService``, seit GitHub #76
/// für ``Preispunkt``) hat ein `KaufEintrag` nach Abschluss seines
/// ``Einkaufsvorgang``s keine fachliche Funktion mehr: ``WarengruppenDistanzService``
/// hat seinen Beitrag bereits synchron beim Abschluss verarbeitet
/// (``WarengruppenDistanzService/verarbeiteEinkauf(_:context:)``), die Preisrolle
/// liegt vollständig bei ``Preispunkt``, und die Einkaufslisten-Mitgliedschaft wurde
/// bereits beim Abhaken entfernt. Läuft deshalb automatisch, ohne Nutzer-Einstellung,
/// mit fester, kurzer Karenzzeit statt der langen, standardmäßig deaktivierten
/// Preishistorie-Frist — dieselbe Lösch-/Tombstone-Logik wie vormals in
/// `PreisHistorieBereinigungService`, hier verallgemeinert auf alle abgeschlossenen
/// Vorgänge statt nur listenlose (siehe ``DatenintegritaetsService/raeumeLeereListenloseVorgaengeAuf(context:)``
/// für den engeren, strukturellen Fall).
enum KaufEintragBereinigungService {
    /// Karenzzeit nach Abschluss eines Einkaufsvorgangs, bevor seine
    /// `KaufEintrag`e automatisch gelöscht werden — großzügig genug, damit ein
    /// nachträglicher Belegscan (`BelegScanView` im `.einkaufsvorgang`-Kontext,
    /// `passtZu`-Namensabgleich) den gerade abgeschlossenen Einkauf noch findet,
    /// statt fälschlich neue, eigenständige `Preispunkt`e anzulegen. Dieselbe
    /// Größenordnung wie `SyncImportService.maximalesEventAlterFuerRetry`.
    /// `static var` statt Konstante, damit Tests sie auf sehr kurze Werte setzen
    /// können (analog `SyncSnapshotImportService.maximalesSnapshotAlter`).
    @MainActor static var karenzzeit: TimeInterval = 48 * 60 * 60

    private static let letzteBereinigungSchluessel = "kaufEintragBereinigungLetzteBereinigung"

    /// Mindestabstand zwischen zwei automatischen Läufen, analog
    /// ``PreisHistorieBereinigungService/automatischesIntervall``.
    static let automatischesIntervall: TimeInterval = 60 * 60 * 24

    static var letzteBereinigung: Date? {
        get { UserDefaults.standard.object(forKey: letzteBereinigungSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: letzteBereinigungSchluessel) }
    }

    /// Löscht `KaufEintrag`e, deren `Einkaufsvorgang` abgeschlossen ist und dessen
    /// `endZeit` länger als ``karenzzeit`` vor `jetzt` zurückliegt, sowie
    /// (sofort, ohne Karenzzeit — siehe Begründung an der Stelle des Filters)
    /// bereits verwaiste Einträge ohne jeden `Einkaufsvorgang`, sowie
    /// anschließend Vorgänge, die dadurch leer geworden sind (unabhängig von einer
    /// weiterhin bestehenden `Einkaufsliste`-Zuordnung — anders als
    /// ``DatenintegritaetsService/raeumeLeereListenloseVorgaengeAuf(context:)``).
    /// Beide Löschungen hinterlassen einen ``SyncTombstone``, damit sie im
    /// Mehrgeräte-Fall nicht von einem Peer unwissentlich wiederbelebt werden.
    ///
    /// **Welche Vorgänge „leer werden" wird bewusst VOR jeder Löschung berechnet**
    /// (`vorgaengeDieLeerWerden`, über die noch frische, unveränderte
    /// `vorgang.kaufEintraege`-Relationship), nicht danach über einen erneuten
    /// `.isEmpty`-Check: SwiftData aktualisiert die inverse `@Relationship`-Sammlung
    /// nachweislich erst bei/nach `context.save()`, nicht sofort bei `context.delete(...)`
    /// — ein Check direkt nach dem Löschen, aber vor dem (erst nach diesem gesamten
    /// `mutate`-Block laufenden) Save sähe die Sammlung fälschlich noch als
    /// unverändert (GitHub #77).
    @MainActor
    @discardableResult
    static func bereinigen(context: ModelContext, jetzt: Date = Date()) async -> Int {
        let stichtag = jetzt.addingTimeInterval(-karenzzeit)

        // Verwaiste Einträge (`einkaufsvorgang == nil`) entstehen ausschließlich
        // durch einen (mittlerweile behobenen) Bug im Sync-Snapshot-Merge
        // (`SyncSnapshotImportService.mergeKaufEintraege`): kein aktueller
        // Code-Pfad legt einen `KaufEintrag` absichtlich ohne Vorgang an. Ein
        // solcher Eintrag hat damit nie eine fachliche Funktion gehabt und wird
        // NIE nachträglich einem Vorgang zugeordnet — anders als ein noch
        // laufender Vorgang (`endZeit == nil`) gibt es hier keinen Grund, auf
        // Ablauf der ``karenzzeit`` zu warten, bevor gelöscht wird (Analyse-Fund:
        // machte in einem Live-Export über die Hälfte aller `KaufEintrag`e aus).
        let kaufEintragKandidaten = ((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? [])
            .filter { eintrag in
                guard let vorgang = eintrag.einkaufsvorgang else { return true }
                return vorgang.endZeit.map { $0 < stichtag } ?? false
            }
        let kaufEintragKandidatenIDs = Set(kaufEintragKandidaten.map(\.persistentModelID))

        // Bewusst ein ungefilterter Fetch + Swift-seitiger `.filter` statt eines
        // `#Predicate` mit `$0.endZeit! < stichtag` — Letzteres lieferte in einem
        // gezielten Isolationstest nachweislich leere Ergebnisse, obwohl derselbe
        // Vergleich in reinem Swift auf denselben Objekten korrekt `true` ergab
        // (GitHub #77-Nachfolgefund: Force-Unwrap eines optionalen Felds innerhalb
        // eines `#Predicate`-Ausdrucks scheint hier nicht zuverlässig übersetzt zu
        // werden). Bei den hier relevanten Datenmengen unkritisch.
        let vorgangKandidaten = ((try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? [])
            .filter { $0.endZeit.map { $0 < stichtag } ?? false }
        // Ein Vorgang ist nach diesem Durchlauf leer, wenn ALLE seine aktuell
        // (noch vor jeder Löschung) bekannten KaufEintraege unter den gleich zu
        // löschenden Kandidaten sind — `allSatisfy` liefert für einen bereits
        // (schon vorher) leeren Vorgang absichtlich `true` (vacuous truth), damit
        // auch ein von Anfang an leerer, abgeschlossener Vorgang erfasst wird,
        // nicht nur einer, der erst durch diesen Durchlauf leer wird.
        let vorgaengeDieLeerWerden = vorgangKandidaten.filter { vorgang in
            vorgang.kaufEintraege.allSatisfy { kaufEintragKandidatenIDs.contains($0.persistentModelID) }
        }

        guard !kaufEintragKandidaten.isEmpty || !vorgaengeDieLeerWerden.isEmpty else { return 0 }

        // Nur Identitäten über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — während des Micro-Lease-Erwerbs kann ein
        // nebenläufiger Sync-Zyklus einen dieser Einträge bereits gelöscht haben.
        let kaufEintragReferenzen = kaufEintragKandidaten.map { ModelReference($0) }
        let vorgangReferenzen = vorgaengeDieLeerWerden.map { ModelReference($0) }

        var geloeschteKaufEintraegeAnzahl = 0
        var geloeschteKaufEintragIDs: [UUID] = []
        await DatabaseLeaseService.performMicroLease(context: context) {
            for referenz in kaufEintragReferenzen {
                guard let eintrag = referenz.resolved(in: context) else { continue }
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintrag.id, context: context)
                geloeschteKaufEintragIDs.append(eintrag.id)
                context.delete(eintrag)
            }
            geloeschteKaufEintraegeAnzahl = kaufEintragReferenzen.count

            for referenz in vorgangReferenzen {
                guard let vorgang = referenz.resolved(in: context) else { continue }
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.einkaufsvorgang, id: vorgang.id, context: context)
                context.delete(vorgang)
            }
        }
        // GitHub #82: außerhalb der Micro-Lease (reine Datei-I/O, keine
        // ModelContext-Mutation) — räumt die eigenen `kaeufe/{id}.json` der
        // gelöschten Einträge in EINEM gebündelten Zugriff auf, siehe
        // ``SyncKaeufeExportService/entferneDateien(fuerKaufEintragIDs:)``
        // (bewusst nicht einzeln pro Eintrag — siehe dortige Begründung).
        SyncKaeufeExportService.entferneDateien(fuerKaufEintragIDs: geloeschteKaufEintragIDs)
        return geloeschteKaufEintraegeAnzahl
    }

    /// Führt ``bereinigen(context:jetzt:)`` nur aus, wenn seit dem letzten Lauf
    /// mindestens ``automatischesIntervall`` vergangen ist — für den Aufruf bei
    /// App-Start/Vordergrund-Wechsel (siehe `RootView`).
    @MainActor
    static func automatischBereinigenFallsFaellig(context: ModelContext) async {
        if let letzte = letzteBereinigung, Date().timeIntervalSince(letzte) < automatischesIntervall {
            return
        }
        await bereinigen(context: context)
        letzteBereinigung = Date()
    }
}
