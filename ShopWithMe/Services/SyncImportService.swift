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
        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "importiereNeueEvents")
            return
        }
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

            let jsonDateien = dateien.filter { $0.pathExtension == "json" }
            let empfangeneEvents = await ladeEvents(aus: jsonDateien)
                .sorted { $0.lamportZaehler < $1.lamportZaehler }

            for empfangen in empfangeneEvents {
                wendeAn(empfangen, context: context)
            }
        }

        try? context.save()
    }

    /// Lädt und dekodiert Event-Dateien über einen koordinierten Lesezugriff
    /// (``SyncDateiZugriff``, GitHub #52) — in einem `Task.detached`, damit ein
    /// bei Bedarf ausgelöster Download nicht den `MainActor` blockiert.
    nonisolated private static func ladeEvents(aus dateien: [URL]) async -> [SyncEventExportDarstellung] {
        await Task.detached(priority: .utility) {
            dateien.compactMap { url -> SyncEventExportDarstellung? in
                guard let daten = SyncDateiZugriff.leseKoordiniert(url) else { return nil }
                return try? JSONDecoder().decode(SyncEventExportDarstellung.self, from: daten)
            }
        }.value
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
        // Beobachtete Latenz dieses Updates (siehe SyncDebugLogger-Typ-Doku) —
        // nur für tatsächlich neu angewendete Events, nicht für Verlierer im
        // Konfliktfall oder unbekannte Arten (dort fand keine reale
        // Zustandsänderung statt).
        SyncDebugLogger.protokolliereAlter(.eventEmpfangen, erzeugtAm: empfangen.wallClock, zusatz: "art=\(art.rawValue)")
    }

    /// Prüft per ``SyncEventService/aktuellerGewinner(bezugsID:artikelID:context:)``,
    /// ob das neue Event gegen den bisher bekannten Gewinner für dasselbe
    /// (`bezugsID`, `artikelID`)-Paar besteht. Ohne konkurrierende Events
    /// gewinnt das neue Event automatisch.
    @MainActor
    private static func darfAngewendetWerden(
        art: SyncEventArt, lamportZaehler: UInt64, bezugsID: UUID, artikelID: UUID, context: ModelContext
    ) -> Bool {
        guard let bisherigerGewinner = SyncEventService.aktuellerGewinner(bezugsID: bezugsID, artikelID: artikelID, context: context),
              let bisherigeArt = bisherigerGewinner.art
        else { return true }

        let neuerKandidat = SyncKonfliktAufloesung.Kandidat(art: art, lamportZaehler: lamportZaehler)
        let bisherigerKandidat = SyncKonfliktAufloesung.Kandidat(art: bisherigeArt, lamportZaehler: bisherigerGewinner.lamportZaehler)
        return SyncKonfliktAufloesung.gewinnt(neuerKandidat, ueber: bisherigerKandidat)
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

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namensmatching, Phase 3, kann einen fremden Artikel mit einem
    /// anderen lokalen zusammengeführt haben), bevor direkt per `id` gesucht
    /// wird.
    private static func artikel(mitID id: UUID, context: ModelContext) -> Artikel? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.artikel, context: context)
        var deskriptor = FetchDescriptor<Artikel>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }
}
