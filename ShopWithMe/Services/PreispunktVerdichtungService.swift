import Foundation
import SwiftData

/// Automatische Verdichtung der Preishistorie (``Preispunkt``) nach Alter (GitHub
/// #76-Folgearbeit) — reduziert die Datenmenge, ohne die grobe Preisentwicklung zu
/// verlieren: aktuelle Preise bleiben tagesgenau, ältere werden zunehmend gröber
/// zusammengefasst.
///
/// Drei Stufen, in dieser Reihenfolge angewendet (jede baut auf dem Ergebnis der
/// vorherigen auf):
/// 1. **Täglich** (``maxPunkteProTag``, Standard 1): pro (``Artikel``, ``Geschaeft``,
///    Kalendertag) höchstens so viele Punkte — bei Überschuss bleiben nur die
///    zuletzt beobachteten. Der **heutige** Tag ist davon ausgenommen — das fängt
///    hauptsächlich rückwirkend bereits bestehende Mehrfach-Punkte ab (z.B. aus der
///    `KaufEintrag`-Migration); für künftig neu erfasste Punkte verhindert bereits
///    eine interaktive Abfrage beim Scannen (siehe `BelegScanView`/
///    `PreisschildScanView`, `PreispunktService/vorhandenerPunktHeute(...)`) die
///    meisten Kollisionen direkt.
/// 2. **Wöchentlich** (``tageBisWochenVerdichtung``, Standard 7 Tage): Punkte, die
///    älter als diese Frist sind, werden pro (Artikel, Geschäft, Kalenderwoche) auf
///    einen einzigen reduziert — der mit dem höchsten Preis.
/// 3. **Monatlich** (``tageBisMonatsVerdichtung``, Standard 365 Tage): die bereits
///    wochenverdichteten Punkte, die zusätzlich älter als diese Frist sind, werden
///    pro (Artikel, Geschäft, Kalendermonat) noch einmal auf einen einzigen
///    reduziert — wieder der mit dem höchsten Preis.
///
/// Der jeweils überlebende Punkt behält sein **echtes Beobachtungsdatum** (der Tag,
/// an dem der Höchstpreis tatsächlich gemessen wurde) statt eines künstlichen
/// Bucket-Datums (z.B. Wochenanfang) — Nutzerentscheidung.
///
/// Alle drei Schwellwerte sind im Debug-Menü einstellbar (siehe `DebuggingView`) und
/// gelten global für alle Geschäfte einheitlich (keine Pro-Geschäft-Overrides).
/// Läuft automatisch für alle Nutzer, ohne dass der Sync-Debug-Modus aktiv sein
/// muss. Löschungen hinterlassen wie bei ``PreisHistorieBereinigungService``/
/// ``KaufEintragBereinigungService`` einen ``SyncTombstone``.
enum PreispunktVerdichtungService {
    private static let maxPunkteProTagSchluessel = "preispunktVerdichtungMaxProTag"
    private static let tageBisWochenSchluessel = "preispunktVerdichtungTageBisWoche"
    private static let tageBisMonatSchluessel = "preispunktVerdichtungTageBisMonat"
    private static let letzteVerdichtungSchluessel = "preispunktVerdichtungLetzteVerdichtung"

    /// Mindestabstand zwischen zwei automatischen Läufen, analog
    /// ``PreisHistorieBereinigungService/automatischesIntervall``.
    static let automatischesIntervall: TimeInterval = 60 * 60 * 24

    static var maxPunkteProTag: Int {
        get {
            let wert = UserDefaults.standard.integer(forKey: maxPunkteProTagSchluessel)
            return wert > 0 ? wert : 1
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: maxPunkteProTagSchluessel) }
    }

    static var tageBisWochenVerdichtung: Int {
        get {
            let wert = UserDefaults.standard.integer(forKey: tageBisWochenSchluessel)
            return wert > 0 ? wert : 7
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: tageBisWochenSchluessel) }
    }

    static var tageBisMonatsVerdichtung: Int {
        get {
            let wert = UserDefaults.standard.integer(forKey: tageBisMonatSchluessel)
            return wert > 0 ? wert : 365
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: tageBisMonatSchluessel) }
    }

    static var letzteVerdichtung: Date? {
        get { UserDefaults.standard.object(forKey: letzteVerdichtungSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: letzteVerdichtungSchluessel) }
    }

    /// Führt alle drei Stufen nacheinander aus. Jede Stufe ist ein eigener,
    /// abgeschlossener Lese-/Schreibdurchlauf (eigener Fetch, eigener
    /// `performMicroLease`+Save) statt einer gemeinsamen Transaktion — vermeidet
    /// dieselbe Klasse von Stale-Relationship-Problemen wie in
    /// ``KaufEintragBereinigungService`` bereits gefunden (GitHub #77): eine
    /// spätere Stufe soll nie auf einem innerhalb desselben Durchlaufs noch nicht
    /// gespeicherten Zwischenstand einer früheren Stufe aufbauen müssen.
    ///
    /// Die drei Schwellwerte sind explizite Parameter (Standard: die aktuellen
    /// ``maxPunkteProTag``/``tageBisWochenVerdichtung``/``tageBisMonatsVerdichtung``-
    /// Werte) statt direkt intern gelesen — analog
    /// `PreisHistorieBereinigungService.bereinigen(context:aufbewahrung:jetzt:)`,
    /// damit Tests sie unabhängig vom (prozessweit geteilten) `UserDefaults`-Zustand
    /// gezielt setzen können, ohne sich gegenseitig zu beeinflussen.
    @MainActor
    @discardableResult
    static func verdichten(
        context: ModelContext, jetzt: Date = Date(),
        maxProTag: Int = maxPunkteProTag, tageBisWoche: Int = tageBisWochenVerdichtung, tageBisMonat: Int = tageBisMonatsVerdichtung
    ) async -> Int {
        var geloescht = 0
        geloescht += await verdichteTaeglich(context: context, jetzt: jetzt, grenze: maxProTag)
        geloescht += await verdichteNachKalenderEinheit(
            context: context, jetzt: jetzt, minAlterTage: tageBisWoche,
            periodenKomponenten: [.yearForWeekOfYear, .weekOfYear]
        )
        geloescht += await verdichteNachKalenderEinheit(
            context: context, jetzt: jetzt, minAlterTage: tageBisMonat,
            periodenKomponenten: [.year, .month]
        )
        return geloescht
    }

    /// Wie ``verdichten(context:jetzt:)``, aktualisiert zusätzlich
    /// ``letzteVerdichtung`` — für den manuellen „Jetzt verdichten"-Button im
    /// Debug-Menü (siehe `DebuggingView`).
    @MainActor
    @discardableResult
    static func jetztVerdichten(context: ModelContext) async -> Int {
        let anzahl = await verdichten(context: context)
        letzteVerdichtung = Date()
        return anzahl
    }

    /// Führt ``jetztVerdichten(context:)`` nur aus, wenn seit dem letzten Lauf
    /// mindestens ``automatischesIntervall`` vergangen ist — für den Aufruf bei
    /// App-Start/Vordergrund-Wechsel (siehe `RootView`).
    @MainActor
    static func automatischVerdichtenFallsFaellig(context: ModelContext) async {
        if let letzte = letzteVerdichtung, Date().timeIntervalSince(letzte) < automatischesIntervall {
            return
        }
        await jetztVerdichten(context: context)
    }

    // MARK: - Stufe 1: täglich

    @MainActor
    private static func verdichteTaeglich(context: ModelContext, jetzt: Date, grenze: Int) async -> Int {
        let kalender = Calendar.current
        let heute = kalender.startOfDay(for: jetzt)
        let alle = ((try? context.fetch(FetchDescriptor<Preispunkt>())) ?? [])
            .filter { kalender.startOfDay(for: $0.datum) < heute }

        let gruppiert = Dictionary(grouping: alle) { punkt in
            GruppenSchluessel(
                artikelID: punkt.artikel?.persistentModelID, geschaeftID: punkt.geschaeft?.persistentModelID,
                periode: kalender.dateComponents([.year, .month, .day], from: punkt.datum)
            )
        }

        var zuLoeschen: [Preispunkt] = []
        for (_, gruppe) in gruppiert where gruppe.count > grenze {
            // Neueste zuerst — die ersten `grenze` bleiben erhalten ("nur die
            // zuletzt beobachteten"), der Rest wird gelöscht.
            let sortiert = gruppe.sorted { $0.datum > $1.datum }
            zuLoeschen.append(contentsOf: sortiert.dropFirst(grenze))
        }
        return await loeschePunkte(zuLoeschen, context: context)
    }

    // MARK: - Stufe 2/3: nach Kalendereinheit (Woche/Monat), höchsten behalten

    @MainActor
    private static func verdichteNachKalenderEinheit(
        context: ModelContext, jetzt: Date, minAlterTage: Int, periodenKomponenten: Set<Calendar.Component>
    ) async -> Int {
        guard let stichtag = Calendar.current.date(byAdding: .day, value: -minAlterTage, to: jetzt) else { return 0 }
        let kalender = Calendar.current
        let kandidaten = ((try? context.fetch(FetchDescriptor<Preispunkt>())) ?? []).filter { $0.datum < stichtag }

        let gruppiert = Dictionary(grouping: kandidaten) { punkt in
            GruppenSchluessel(
                artikelID: punkt.artikel?.persistentModelID, geschaeftID: punkt.geschaeft?.persistentModelID,
                periode: kalender.dateComponents(periodenKomponenten, from: punkt.datum)
            )
        }

        var zuLoeschen: [Preispunkt] = []
        for (_, gruppe) in gruppiert where gruppe.count > 1 {
            // Höchster Preis gewinnt; bei Gleichstand der jüngere Beobachtungszeitpunkt
            // (beliebige, aber deterministische Tie-Break-Regel).
            let hoechster = gruppe.max { a, b in
                a.preis == b.preis ? a.datum < b.datum : a.preis < b.preis
            }!
            zuLoeschen.append(contentsOf: gruppe.filter { $0.persistentModelID != hoechster.persistentModelID })
        }
        return await loeschePunkte(zuLoeschen, context: context)
    }

    @MainActor
    private static func loeschePunkte(_ punkte: [Preispunkt], context: ModelContext) async -> Int {
        guard !punkte.isEmpty else { return 0 }
        // Nur Identitäten über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — während des Micro-Lease-Erwerbs kann ein
        // nebenläufiger Sync-Zyklus einen dieser Punkte bereits gelöscht haben.
        let referenzen = punkte.map { ModelReference($0) }
        var geloescht = 0
        await DatabaseLeaseService.performMicroLease(context: context) {
            for referenz in referenzen {
                guard let punkt = referenz.resolved(in: context) else { continue }
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.preispunkt, id: punkt.id, context: context)
                context.delete(punkt)
            }
            geloescht = referenzen.count
        }
        return geloescht
    }

    private struct GruppenSchluessel: Hashable {
        let artikelID: PersistentIdentifier?
        let geschaeftID: PersistentIdentifier?
        let periode: DateComponents
    }
}
