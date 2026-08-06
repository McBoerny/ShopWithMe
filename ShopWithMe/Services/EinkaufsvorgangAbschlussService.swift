import Foundation
import SwiftData

/// Bündelt die beim Abschließen eines Einkaufsvorgangs geteilte Logik zwischen
/// dem manuellen "Einkauf abschließen"-Button
/// (``EinkaufslisteView/einkaufAbschliessen()``, `EinkaufenView.swift`) und dem
/// automatischen Abschluss nach Inaktivität
/// (``EinkaufenView/inaktivitaetPruefen()``) — extrahiert aus GitHub #107, da
/// diese Logik (siehe `docs/DATENSYNCHRONISATION.md` §4.3) drei aufeinander
/// folgende Live-Test-Fixes brauchte, aber vorher nur als private View-Methode
/// existierte und deshalb nie per Unit-Test abgesichert werden konnte.
enum EinkaufsvorgangAbschlussService {
    /// Ergebnis eines Abschlusses — ``umbauNeuErkannt`` bestimmt, ob die
    /// aufrufende View einen Umbau-Hinweis zeigen soll; ``geschlosseneDuplikate``
    /// ist die Grundlage für die "Ausgeloest"/"Durchgefuehrt"-Diagnose-Events,
    /// die weiterhin beim Aufrufer verbleiben.
    struct Ergebnis: Equatable {
        let umbauNeuErkannt: Bool
        let geschlosseneDuplikate: Int
    }

    /// Schließt den bereits als offen validierten `anker` ab (zählt dabei —
    /// anders als jedes Duplikat — als eigener Ladenbesuch, siehe
    /// ``Einkaufsvorgang/abschliessen(am:zaehleAlsBesuch:)``), lässt
    /// ``AbteilungsDistanzService`` und ``GeschaeftBesuchService`` NUR für ihn
    /// laufen, und schließt danach alle noch offenen `duplikate` derselben
    /// Einkaufsliste mit ab (`zaehleAlsBesuch: false` — sie repräsentieren
    /// denselben physischen Ladenbesuch, siehe `docs/DATENSYNCHRONISATION.md`
    /// §4.3, zweiter/dritter Live-Test-Nachtrag).
    ///
    /// `duplikate` als ``ModelReference`` statt lebendiger Objekte, weil
    /// zwischen dem Erfassen der Kandidaten (vor einem `await`, z.B. dem
    /// Micro-Lease-Erwerb) und dieser Ausführung ein nebenläufiger Sync-Zyklus
    /// sie bereits verändert/gelöscht haben kann — bereits geschlossene oder
    /// nicht mehr auflösbare Duplikate werden übersprungen, OHNE die
    /// Verarbeitung des Ankers oder der übrigen Duplikate abzubrechen.
    ///
    /// Die Auswahl, WELCHE Vorgänge als `duplikate` gelten (listen-, nicht
    /// geschäftsgebunden, siehe `EinkaufenView.weitereOffeneVorgaengeDerListe`),
    /// bleibt bewusst Aufgabe des Aufrufers — dieser Service trifft dazu keine
    /// eigene Geschäfts-/Listen-Entscheidung, damit der dritte Live-Test-Fix
    /// (Entfernen des Geschäfts-Filters) nicht versehentlich hier erneut
    /// eingeführt werden kann.
    ///
    /// Ebenso bleibt die Auflösung/Gültigkeitsprüfung des `anker`s selbst
    /// Aufgabe des Aufrufers — die beiden heutigen Aufrufstellen unterscheiden
    /// sich hier bewusst (Button-Tap auf garantiert offenen Vorgang vs.
    /// automatisches Schließen, das einen zwischenzeitlich bereits per Sync
    /// geschlossenen Anker tolerieren muss und dann den gesamten Aufruf
    /// unterlässt) — das hier zu vereinheitlichen wäre eine eigene, separat zu
    /// rechtfertigende Änderung.
    @discardableResult
    static func schliesseAbMitDuplikaten(
        anker: Einkaufsvorgang,
        duplikate: [ModelReference<Einkaufsvorgang>],
        context: ModelContext
    ) -> Ergebnis {
        anker.abschliessen()
        let umbauNeuErkannt = AbteilungsDistanzService.verarbeiteEinkauf(anker, context: context)
        GeschaeftBesuchService.erfassen(fuer: anker, context: context)

        var geschlossen = 0
        for referenz in duplikate {
            guard let weiterer = referenz.resolved(in: context), !weiterer.istAbgeschlossen else { continue }
            protokolliereVorDuplikatSchliessung(weiterer)
            weiterer.abschliessen(zaehleAlsBesuch: false)
            geschlossen += 1
        }
        return Ergebnis(umbauNeuErkannt: umbauNeuErkannt, geschlosseneDuplikate: geschlossen)
    }

    /// Diagnose für den Live-Test-Fund „Einkauf abschließen auf einem Gerät
    /// beendet ungewollt einen noch aktiven Vorgang eines anderen Geräts"
    /// (Session 2026-08-03) — protokolliert je tatsächlich mitgeschlossenem
    /// Duplikat-Vorgang dessen Geschäft, Anzahl eigener Einträge und wie lange
    /// seine letzte Aktivität (jüngster ``KaufEintrag/datum``, sonst
    /// ``Einkaufsvorgang/startZeit``) zurückliegt. Verschoben aus
    /// `EinkaufenView.swift` (dort freie Funktion, weil von zwei Stellen im
    /// selben File gebraucht) — jetzt `private`, da nur noch die Schleife oben
    /// sie aufruft.
    private static func protokolliereVorDuplikatSchliessung(_ vorgang: Einkaufsvorgang) {
        guard DatabaseDebugLogger.istAktiv else { return }
        let letzteAktivitaet = vorgang.kaufEintraege.map(\.datum).max() ?? vorgang.startZeit
        let sekundenSeitAktivitaet = Int(Date.now.timeIntervalSince(letzteAktivitaet))
        DatabaseDebugLogger.log(
            .einkaufAbschlussDuplikatGeschlossen,
            details: "geschaeft=\(vorgang.geschaeft?.name ?? "kein Geschäft") eigeneEintraege=\(vorgang.kaufEintraege.count) "
                + "letzteAktivitaetVorSekunden=\(sekundenSeitAktivitaet)"
        )
    }

    /// Schließt ALLE aktuell offenen Einkaufsvorgänge unabhängig voneinander ab
    /// — jeder für sich wie ein eigenständiger Anker ohne Duplikate (siehe
    /// ``schliesseAbMitDuplikaten(anker:duplikate:context:)``), zählt also
    /// normal als eigener Besuch und fließt normal ins Distanzlernen ein.
    ///
    /// Für den Moment, in dem ein Gerät (neu) an einer Sync-Gruppe teilnimmt
    /// (Erstbeitritt, Wieder-Beitritt nach Entfernung, Backup-Wiederherstellung
    /// bei weiterhin verknüpftem Sync-Ordner, `SyncOrdnerSettingsView`/
    /// `SyncErsetzenService`) — ohne das würde ein lokal noch offener,
    /// möglicherweise längst vergessener Vorgang über
    /// ``SyncSnapshotImportService``s `offenerTreffer`-Matching blind mit
    /// einem tatsächlich gerade aktiven Vorgang eines Peers aliasiert. Seine
    /// bereits vorhandenen eigenen `KaufEintrag`e blieben dadurch am
    /// zusammengeführten Vorgang hängen und erschienen zusätzlich in der
    /// listenweiten "abgehakt"-Ansicht (`docs/DATENSYNCHRONISATION.md` §4.3)
    /// — auch wenn sie mit der aktuellen Gruppenaktivität nichts zu tun haben.
    ///
    /// Bewusst NICHT aufgerufen für einen frisch importierten Peer-Snapshot
    /// (``SyncErsetzenService``, Fall `.ersetzenDurchPeer`) — dessen offene
    /// Vorgänge gehören echten, aktuell aktiven Peers und sollen genau
    /// deshalb offen bleiben.
    @discardableResult
    static func schliesseAlleOffenenEinkaufsvorgaenge(context: ModelContext) -> Int {
        let offene = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.endZeit == nil }))) ?? []
        for vorgang in offene {
            schliesseAbMitDuplikaten(anker: vorgang, duplikate: [], context: context)
        }
        return offene.count
    }
}
