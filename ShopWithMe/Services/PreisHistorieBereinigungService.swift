import Foundation
import SwiftData

/// Wie lange ``KaufEintrag``e mit erfasstem Preis aufbewahrt werden, bevor
/// ``PreisHistorieBereinigungService`` sie automatisch löscht.
enum PreisHistorieAufbewahrung: Equatable {
    case tage30
    case monate3
    case monate6
    case jahr1
    case nie
    /// Vom Anwender frei gewählte Anzahl Tage.
    case eigeneTage(Int)

    /// Anzahl Tage, ab der ein Eintrag als "alt" gilt — `nil` bedeutet "nie löschen".
    var tage: Int? {
        switch self {
        case .tage30: return 30
        case .monate3: return 90
        case .monate6: return 180
        case .jahr1: return 365
        case .nie: return nil
        case .eigeneTage(let tage): return tage
        }
    }

    /// Anzeigename für die Einstellungen-UI.
    var anzeigename: String {
        switch self {
        case .tage30: return "30 Tage"
        case .monate3: return "3 Monate"
        case .monate6: return "6 Monate"
        case .jahr1: return "1 Jahr"
        case .nie: return "Nie"
        case .eigeneTage(let tage): return "\(tage) Tage (eigene Vorgabe)"
        }
    }

    /// Stabiler String zum Persistieren in `UserDefaults` (siehe
    /// ``PreisHistorieBereinigungService/aktuelleAufbewahrung``).
    var persistenzWert: String {
        switch self {
        case .tage30: return "tage30"
        case .monate3: return "monate3"
        case .monate6: return "monate6"
        case .jahr1: return "jahr1"
        case .nie: return "nie"
        case .eigeneTage(let tage): return "eigen:\(tage)"
        }
    }

    init?(persistenzWert: String) {
        switch persistenzWert {
        case "tage30": self = .tage30
        case "monate3": self = .monate3
        case "monate6": self = .monate6
        case "jahr1": self = .jahr1
        case "nie": self = .nie
        default:
            guard persistenzWert.hasPrefix("eigen:"),
                  let tage = Int(persistenzWert.dropFirst("eigen:".count))
            else { return nil }
            self = .eigeneTage(tage)
        }
    }
}

/// Löscht alte ``KaufEintrag``e (Preishistorie) anhand einer vom Anwender in den
/// Einstellungen gewählten Aufbewahrungsfrist (siehe ``PreisHistorieSettingsView``).
///
/// Es entsteht bewusst keine separate Datenbank/kein separater Store dafür —
/// ``KaufEintrag`` bleibt im Hauptstore, da es zugleich Grundlage für den aktuell
/// laufenden Einkaufsvorgang ist. Um laufende Einkäufe nicht versehentlich zu
/// zerstören, lässt ``bereinigen(context:aufbewahrung:jetzt:)`` Einträge eines noch
/// nicht abgeschlossenen ``Einkaufsvorgang`` immer unangetastet, unabhängig vom Alter.
enum PreisHistorieBereinigungService {
    private static let aufbewahrungSchluessel = "preisHistorieAufbewahrung"
    private static let letzteBereinigungSchluessel = "preisHistorieLetzteBereinigung"

    /// Mindestabstand zwischen zwei automatischen Bereinigungen (siehe
    /// ``automatischBereinigenFallsFaellig(context:)``), damit nicht bei jedem
    /// App-Start/Vordergrund-Wechsel erneut gefetcht wird.
    static let automatischesIntervall: TimeInterval = 60 * 60 * 24

    /// Die aktuell in den Einstellungen gewählte Aufbewahrungsfrist. Standard: ``PreisHistorieAufbewahrung/nie``,
    /// damit bestehende Preishistorie bei einem Update nicht ungefragt gelöscht wird.
    static var aktuelleAufbewahrung: PreisHistorieAufbewahrung {
        get {
            guard let wert = UserDefaults.standard.string(forKey: aufbewahrungSchluessel),
                  let aufbewahrung = PreisHistorieAufbewahrung(persistenzWert: wert)
            else { return .nie }
            return aufbewahrung
        }
        set { UserDefaults.standard.set(newValue.persistenzWert, forKey: aufbewahrungSchluessel) }
    }

    /// Zeitpunkt der letzten (automatischen oder manuellen) Bereinigung, `nil` falls
    /// noch nie ausgeführt.
    static var letzteBereinigung: Date? {
        get { UserDefaults.standard.object(forKey: letzteBereinigungSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: letzteBereinigungSchluessel) }
    }

    /// Löscht alle ``KaufEintrag``e, deren ``KaufEintrag/datum`` mehr als
    /// `aufbewahrung.tage` Tage vor `jetzt` liegt — außer solchen, die zu einem noch
    /// nicht abgeschlossenen ``Einkaufsvorgang`` gehören. Räumt zusätzlich
    /// abgeschlossene ``Einkaufsvorgang``e auf, deren ``Einkaufsvorgang/endZeit``
    /// ebenfalls vor `stichtag` liegt und die (nach der KaufEintrag-Bereinigung
    /// oben) keine verbleibenden ``KaufEintrag``e mehr haben — ein alter,
    /// leerer Vorgang wäre sonst für immer im Bestand geblieben (siehe GitHub
    /// #71: `Einkaufsvorgang` hatte bislang gar keine Aufräumlogik). Beide
    /// Löschungen hinterlassen einen ``SyncTombstone``, damit sie im
    /// Mehrgeräte-Fall nicht von einem Peer, der die Einträge noch führt,
    /// unwissentlich wiederbelebt werden — vorher bewusst unterlassen (siehe
    /// `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 11 „Bewusst
    /// nicht enthalten"), was die Bereinigung im Mehrgeräte-Fall faktisch
    /// wirkungslos machte, sobald mindestens ein Peer die Einträge noch hatte.
    ///
    /// Liefert `0` für ``PreisHistorieAufbewahrung/nie`` sofort ohne Fetch
    /// zurück. Liefert die Anzahl gelöschter ``KaufEintrag``e (unverändertes
    /// Rückgabewert-Verhalten — die Anzahl mitgelöschter Einkaufsvorgänge wird
    /// nicht mitgezählt).
    @MainActor
    @discardableResult
    static func bereinigen(
        context: ModelContext,
        aufbewahrung: PreisHistorieAufbewahrung,
        jetzt: Date = Date()
    ) async -> Int {
        guard let tage = aufbewahrung.tage,
              let stichtag = Calendar.current.date(byAdding: .day, value: -tage, to: jetzt)
        else { return 0 }

        let kaufEintragDeskriptor = FetchDescriptor<KaufEintrag>(predicate: #Predicate { $0.datum < stichtag })
        let kaufEintragKandidaten = (try? context.fetch(kaufEintragDeskriptor)) ?? []
        let zuLoeschendeKaufEintraege = kaufEintragKandidaten.filter { $0.einkaufsvorgang?.istAbgeschlossen ?? true }

        let vorgangDeskriptor = FetchDescriptor<Einkaufsvorgang>(
            predicate: #Predicate { $0.endZeit != nil && $0.endZeit! < stichtag }
        )
        let vorgangKandidaten = (try? context.fetch(vorgangDeskriptor)) ?? []

        guard !zuLoeschendeKaufEintraege.isEmpty || !vorgangKandidaten.isEmpty else { return 0 }

        // Nur Identitäten über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — während des Micro-Lease-Erwerbs kann ein
        // nebenläufiger Sync-Zyklus einen dieser Einträge bereits gelöscht
        // haben.
        let kaufEintragReferenzen = zuLoeschendeKaufEintraege.map { ModelReference($0) }
        let vorgangReferenzen = vorgangKandidaten.map { ModelReference($0) }

        var geloeschteKaufEintraegeAnzahl = 0
        await DatabaseLeaseService.performMicroLease(context: context) {
            for referenz in kaufEintragReferenzen {
                guard let eintrag = referenz.resolved(in: context) else { continue }
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.kaufEintrag, id: eintrag.id, context: context)
                context.delete(eintrag)
            }
            geloeschteKaufEintraegeAnzahl = kaufEintragReferenzen.count

            // Erst NACH den obigen Löschungen prüfen, ob ein Vorgang jetzt
            // leer ist — ein Vorgang, dessen letzte KaufEintraege gerade eben
            // durch diesen Aufruf entfernt wurden, soll im selben Durchlauf
            // mit aufgeräumt werden, nicht erst beim nächsten.
            for referenz in vorgangReferenzen {
                guard let vorgang = referenz.resolved(in: context), vorgang.kaufEintraege.isEmpty else { continue }
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.einkaufsvorgang, id: vorgang.id, context: context)
                context.delete(vorgang)
            }
        }
        return geloeschteKaufEintraegeAnzahl
    }

    /// Bereinigt jetzt anhand von ``aktuelleAufbewahrung`` und aktualisiert
    /// ``letzteBereinigung``. Für den manuellen "Jetzt bereinigen"-Button in
    /// ``PreisHistorieSettingsView``.
    @MainActor
    @discardableResult
    static func jetztBereinigen(context: ModelContext) async -> Int {
        let anzahl = await bereinigen(context: context, aufbewahrung: aktuelleAufbewahrung)
        letzteBereinigung = Date()
        return anzahl
    }

    /// Führt ``jetztBereinigen(context:)`` nur aus, wenn seit der letzten Bereinigung
    /// mindestens ``automatischesIntervall`` vergangen ist. Gedacht für den Aufruf bei
    /// App-Start/Vordergrund-Wechsel (siehe ``RootView``).
    @MainActor
    static func automatischBereinigenFallsFaellig(context: ModelContext) async {
        if let letzte = letzteBereinigung, Date().timeIntervalSince(letzte) < automatischesIntervall {
            return
        }
        await jetztBereinigen(context: context)
    }
}
