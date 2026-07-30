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
            // Bewusst NICHT als bekannt markieren, siehe Typ-Dokumentation —
            // wird also bei jedem weiteren Zyklus erneut protokolliert, bis
            // die Referenz auflösbar wird (z.B. durch einen künftigen
            // Bereich-B-Namens-Alias, siehe GitHub #52-Nachfolgefund).
            SyncDebugLogger.log(
                .eventNichtAnwendbar,
                details: "art=\(art.rawValue) bezugsID=\(nutzlast.bezugsID) artikelID=\(nutzlast.artikelID)"
            )
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
            // aufOffenenNachfolgerUmleiten: true — ein Abhaken MATERIALISIERT einen
            // neuen KaufEintrag; landet der bezeichnete Vorgang inzwischen auf einem
            // geschlossenen, ist die Umleitung auf den offenen Nachfolger korrekt
            // (siehe `einkaufsvorgang(mitID:context:aufOffenenNachfolgerUmleiten:)`).
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context, aufOffenenNachfolgerUmleiten: true),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            // indexFuerDistanzlernen: false — dieses Abhaken beschreibt die
            // Laufreihenfolge des SENDENDEN Geräts durchs Geschäft, nicht die
            // dieses Geräts (siehe Einkaufsvorgang-Typ-Doku). Ein hier vergebener
            // Index würde WarengruppenDistanzService mit einer erfundenen
            // Position für diesen Nutzer füttern.
            vorgang.artikelAbhakenOhneEventAufzeichnung(artikel, context: context, indexFuerDistanzlernen: false)
            return true
        case .artikelAbgewaehlt:
            // KEINE Umleitung: Abwählen muss den bereits existierenden KaufEintrag
            // FINDEN, der auf dem ursprünglich referenzierten (ggf. inzwischen
            // geschlossenen) Vorgang liegt — nicht auf dessen offenem Nachfolger, wo
            // gar kein passender Eintrag existiert. Eine Umleitung würde
            // `artikelAbwaehlenOhneEventAufzeichnung` hier verlässlich ins Leere
            // laufen lassen (kein Treffer, `false`), das Event trotzdem als
            // materialisiert gelten (unten `return true`) und den eigentlichen
            // Abwähl-Wunsch des Peers dauerhaft verwerfen.
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelAbwaehlenOhneEventAufzeichnung(artikel, context: context)
            return true
        case .artikelDauerhaftEntfernt:
            // KEINE Umleitung — dieselbe Begründung wie bei .artikelAbgewaehlt: der
            // zu löschende KaufEintrag liegt auf dem ursprünglich referenzierten
            // Vorgang, nicht auf einem offenen Nachfolger.
            guard let vorgang = einkaufsvorgang(mitID: nutzlast.bezugsID, context: context),
                  let artikel = artikel(mitID: nutzlast.artikelID, context: context)
            else { return false }
            vorgang.artikelDauerhaftEntfernenOhneEventAufzeichnung(artikel, context: context)
            return true
        }
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Namensmatching, Phase 3/GitHub #52-Nachfolgefund, kann eine
    /// fremde Einkaufsliste mit einer anderen lokalen zusammengeführt haben),
    /// bevor direkt per `id` gesucht wird — analog ``artikel(mitID:context:)``.
    private static func einkaufsliste(mitID id: UUID, context: ModelContext) -> Einkaufsliste? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.einkaufsliste, context: context)
        var deskriptor = FetchDescriptor<Einkaufsliste>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first
    }

    /// Löst zuerst einen bekannten Alias auf (siehe ``SyncEntitaetsAlias`` —
    /// Bereich-B-Matching kann einen fremden Einkaufsvorgang mit einem anderen
    /// lokalen zusammengeführt haben, GitHub #52-Nachfolgefund), bevor direkt
    /// per `id` gesucht wird — analog ``einkaufsliste(mitID:context:)``.
    ///
    /// `aufOffenenNachfolgerUmleiten: true` leitet zusätzlich auf den aktuell
    /// offenen Nachfolge-Einkaufsvorgang um, falls der so aufgelöste bereits
    /// abgeschlossen ist (siehe ``aufOffenenNachfolgerUmgeleitet(_:fremdeID:context:)``)
    /// — **nur** für Events sinnvoll, die einen NEUEN `KaufEintrag` anlegen
    /// (`.artikelAbgehakt`). Events, die einen bereits bestehenden `KaufEintrag`
    /// FINDEN müssen (`.artikelAbgewaehlt`/`.artikelDauerhaftEntfernt`), dürfen
    /// nicht umgeleitet werden — der gesuchte Eintrag liegt auf dem ursprünglich
    /// referenzierten Vorgang, nicht auf dessen offenem Nachfolger; eine
    /// Umleitung ließe sie dort verlässlich ins Leere laufen (siehe
    /// ``materialisiere(_:nutzlast:context:)``).
    private static func einkaufsvorgang(
        mitID id: UUID, context: ModelContext, aufOffenenNachfolgerUmleiten: Bool = false
    ) -> Einkaufsvorgang? {
        let aufgeloesteID = SyncEntitaetsAliasService.aufgeloesteID(fuer: id, art: SyncEntitaetsArt.einkaufsvorgang, context: context)
        var deskriptor = FetchDescriptor<Einkaufsvorgang>(predicate: #Predicate { $0.id == aufgeloesteID })
        deskriptor.fetchLimit = 1
        guard let vorgang = try? context.fetch(deskriptor).first else { return nil }
        guard aufOffenenNachfolgerUmleiten else { return vorgang }
        return aufOffenenNachfolgerUmgeleitet(vorgang, fremdeID: id, context: context)
    }

    /// **Bug (Absturz-Loop-Serie, dieselbe Ursachen-Familie wie GitHub
    /// #52-Nachfolgefund — hier: „dangling Einkaufsvorgang" statt „dangling
    /// Geschaeft"):** Ein Peer, der ``Einkaufsvorgang/artikelAbhaken(_:context:)``
    /// noch für einen gerade auf einem ANDEREN Gerät per „Einkauf abschließen"
    /// beendeten Vorgang aufzeichnet (weil er dessen ``Einkaufsvorgang/endZeit``
    /// beim Senden noch nicht kannte), lieferte hier bislang den bereits
    /// geschlossenen, für die aktuelle Einkaufsansicht unsichtbaren
    /// ``Einkaufsvorgang`` zurück — sichtbar als: abgehakte Artikel erscheinen
    /// auf dem anderen Gerät nicht, UND landen (weil
    /// ``SyncSnapshotImportService/istBereitsAbgehakt(_:aufListe:context:)``
    /// nur offene Vorgänge prüft) beim nächsten Snapshot-Merge wieder
    /// fälschlich auf der offenen Liste.
    ///
    /// Sucht dafür einen offenen Nachfolger für dieselbe ``Einkaufsliste`` —
    /// bevorzugt mit demselben ``Geschaeft`` (zwei Geräte können gleichzeitig
    /// an unterschiedlichen Geschäften für dieselbe Liste einkaufen, analog
    /// ``SyncSnapshotImportService/mergeEinkaufsvorgaenge(_:geschaeftZuordnung:listeZuordnung:context:)``),
    /// sonst irgendeinen offenen Vorgang für die Liste. **Bewusst kein
    /// Geschäft-Zwang:** „Einkauf abschließen" setzt die Geschäftsauswahl des
    /// schließenden Geräts zurück (GitHub #51), der direkt danach neu
    /// angelegte Nachfolger hat also fast immer `geschaeft == nil` — ein
    /// harter Geschäft-Abgleich hätte hier NIE gegriffen und genau den Fall
    /// verfehlt, für den diese Umleitung gedacht ist. Wird ein Nachfolger
    /// gefunden, wird zusätzlich ein Alias registriert, damit künftige Events
    /// derselben `fremdeID` direkt dorthin auflösen.
    private static func aufOffenenNachfolgerUmgeleitet(
        _ vorgang: Einkaufsvorgang, fremdeID: UUID, context: ModelContext
    ) -> Einkaufsvorgang {
        guard vorgang.istAbgeschlossen, let einkaufsliste = vorgang.einkaufsliste else { return vorgang }
        guard let offenerNachfolger = Einkaufsvorgang.offenerNachfolger(
            fuerListe: einkaufsliste, bevorzugtesGeschaeft: vorgang.geschaeft, context: context
        ) else { return vorgang }

        SyncEntitaetsAliasService.registriere(
            entitaetsArt: SyncEntitaetsArt.einkaufsvorgang, fremdeID: fremdeID, lokaleID: offenerNachfolger.id, context: context
        )
        return offenerNachfolger
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
