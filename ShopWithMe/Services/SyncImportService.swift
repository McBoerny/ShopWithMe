import Foundation
import SwiftData

/// Bereich-A-Import (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md` Abschnitt
/// 5.3, Phase 2): liest Event-Dateien aus allen fremden Peer-Ordnern, wendet
/// ``SyncKonfliktAufloesung`` auf konkurrierende Events desselben
/// (`bezugsID`, `artikelID`)-Paares an und materialisiert das Ergebnis über
/// dieselben Mutationsfunktionen, die auch lokale Aktionen auslösen — nur ohne
/// erneute Event-Aufzeichnung (siehe ``SyncEventService/uebernehmen(_:context:)``).
///
/// **Bekannte Grenze dieser Phase:** Ein empfangenes Event referenziert seine
/// ``Einkaufsliste``/seinen ``Einkaufsvorgang``/seinen ``Artikel`` nur über
/// deren `UUID`. Existiert die referenzierte Entität lokal noch nicht (Bereich-
/// B/C-Import ist erst Phase 3), wird das Event bewusst NICHT als bekannt
/// markiert, sondern beim nächsten Sync-Zyklus automatisch erneut versucht —
/// die Peer-Event-Datei bleibt dafür unverändert liegen (siehe
/// ``wendeAn(_:context:)``). Ein konkurrierendes, aber bereits anwendbares
/// schwächeres Event kann dadurch übergangsweise vor einem noch nicht
/// anwendbaren stärkeren Event materialisiert werden — das System konvergiert
/// aber selbstständig auf den korrekten Endzustand, sobald auch das stärkere
/// Event anwendbar wird (die Mutationsfunktionen sind für genau diesen Fall
/// bereits idempotent/selbstkorrigierend ausgelegt).
enum SyncImportService {
    @MainActor
    static func importiereNeueEvents(context: ModelContext) async {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        guard syncOrdner.startAccessingSecurityScopedResource() else { return }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let peersOrdner = syncOrdner.appendingPathComponent("peers", isDirectory: true)
        let eigeneGeraeteID = DatabaseLeaseService.geraeteID
        guard let peerVerzeichnisse = try? FileManager.default.contentsOfDirectory(
            at: peersOrdner, includingPropertiesForKeys: nil
        ) else { return }

        for peerOrdner in peerVerzeichnisse where peerOrdner.lastPathComponent != eigeneGeraeteID {
            let eventsOrdner = SyncExportService.eventsOrdner(fuerPeer: peerOrdner.lastPathComponent, in: syncOrdner)
            guard let dateien = try? FileManager.default.contentsOfDirectory(
                at: eventsOrdner, includingPropertiesForKeys: nil
            ) else { continue }

            let empfangeneEvents = dateien
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> SyncEventExportDarstellung? in
                    guard let daten = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(SyncEventExportDarstellung.self, from: daten)
                }
                .sorted { $0.lamportZaehler < $1.lamportZaehler }

            for empfangen in empfangeneEvents {
                wendeAn(empfangen, context: context)
            }
        }

        try? context.save()
    }

    @MainActor
    private static func wendeAn(_ empfangen: SyncEventExportDarstellung, context: ModelContext) {
        guard !SyncEventService.istBereitsBekannt(empfangen.id, context: context) else { return }

        guard let art = SyncEventArt(rawValue: empfangen.art),
              let nutzlast = try? JSONDecoder().decode(SyncEventNutzlast.self, from: empfangen.nutzlast)
        else {
            // Unbekannte Art (neuere Peer-App-Version) oder korrupte Nutzlast —
            // niemals interpretierbar, ein Retry würde nichts ändern.
            SyncEventService.uebernehmen(empfangen, context: context)
            return
        }

        guard darfAngewendetWerden(art: art, lamportZaehler: empfangen.lamportZaehler, bezugsID: nutzlast.bezugsID, artikelID: nutzlast.artikelID, context: context) else {
            // Ein bereits bekanntes, stärkeres Event hat dieses Paar schon
            // entschieden (siehe SyncKonfliktAufloesung) — das gilt dauerhaft,
            // ein Retry ist hier (anders als bei fehlender Referenz) nie nötig.
            SyncEventService.uebernehmen(empfangen, context: context)
            return
        }

        guard materialisiere(art, nutzlast: nutzlast, context: context) else {
            // Referenzierte Liste/Einkauf/Artikel noch nicht lokal bekannt.
            // Bewusst NICHT als bekannt markieren, siehe Typ-Dokumentation.
            return
        }

        SyncEventService.uebernehmen(empfangen, context: context)
    }

    /// Sammelt alle lokal bekannten Events (eigene wie bereits importierte
    /// fremde) für dasselbe (`bezugsID`, `artikelID`)-Paar und prüft per
    /// ``SyncKonfliktAufloesung``, ob das neue Event gegen den bisherigen
    /// Gewinner besteht. Ohne konkurrierende Events gewinnt das neue Event
    /// automatisch.
    ///
    /// Performance-Hinweis: durchsucht aktuell alle lokalen `SyncEvent`s (kein
    /// indiziertes Prädikat auf der JSON-kodierten Nutzlast möglich) — für den
    /// heutigen Umfang unkritisch, potenzieller Optimierungspunkt, falls der
    /// Event-Log deutlich wächst.
    @MainActor
    private static func darfAngewendetWerden(
        art: SyncEventArt, lamportZaehler: UInt64, bezugsID: UUID, artikelID: UUID, context: ModelContext
    ) -> Bool {
        let neuerKandidat = SyncKonfliktAufloesung.Kandidat(art: art, lamportZaehler: lamportZaehler)
        let bekannteKandidaten = ((try? context.fetch(FetchDescriptor<SyncEvent>())) ?? [])
            .compactMap { event -> SyncKonfliktAufloesung.Kandidat? in
                guard let bekannteArt = event.art, let bekannteNutzlast = event.nutzlastDekodiert,
                      bekannteNutzlast.bezugsID == bezugsID, bekannteNutzlast.artikelID == artikelID
                else { return nil }
                return SyncKonfliktAufloesung.Kandidat(art: bekannteArt, lamportZaehler: event.lamportZaehler)
            }

        let reduziert: SyncKonfliktAufloesung.Kandidat? = bekannteKandidaten.reduce(nil) { bisher, kandidat in
            guard let bisher else { return kandidat }
            return SyncKonfliktAufloesung.gewinnt(kandidat, ueber: bisher) ? kandidat : bisher
        }
        guard let bisherigerGewinner = reduziert else { return true }

        return SyncKonfliktAufloesung.gewinnt(neuerKandidat, ueber: bisherigerGewinner)
    }

    /// Wendet die dem `art` entsprechende, nicht-aufzeichnende Mutationsfunktion
    /// an. Liefert `false`, falls die referenzierte Liste/der Einkauf oder der
    /// Artikel lokal (noch) nicht existiert — siehe Typ-Dokumentation zur
    /// Retry-Semantik.
    @MainActor
    private static func materialisiere(_ art: SyncEventArt, nutzlast: SyncEventNutzlast, context: ModelContext) -> Bool {
        switch art {
        case .artikelHinzugefuegt:
            guard let liste = einkaufsliste(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            liste.artikelHinzufuegenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelEntfernt:
            guard let liste = einkaufsliste(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            liste.artikelEntfernenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelAbgehakt:
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelAbhakenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelAbgewaehlt:
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelAbwaehlenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelDauerhaftEntfernt:
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelDauerhaftEntfernenOhneEventAufzeichnung(artikel, context: context)
            return true
        }
    }

    private static func einkaufsliste(mitID id: UUID, context: ModelContext) -> Einkaufsliste? {
        var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    private static func einkaufsvorgang(mitID id: UUID, context: ModelContext) -> Einkaufsvorgang? {
        var deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    private static func artikel(mitID id: UUID, context: ModelContext) -> Artikel? {
        var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == id })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }
}
