import Foundation
import SwiftData

/// Bereich-A-Export (`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 5.2):
/// schreibt lokale, noch nicht hochgeladene ``SyncEvent``s als einzelne
/// JSON-Dateien in den eigenen Peer-Ordner (`peers/{geraeteID}/events/`). Reines
/// Schreiben — Lesen fremder Peer-Ordner (Import) ist Phase 2/3 des Plans.
enum SyncExportService {
    /// Der Event-Ordner eines beliebigen Geräts (eigenes oder fremdes) innerhalb
    /// des Sync-Ordners — siehe ``SyncImportService`` für das Lesen fremder
    /// Ordner.
    static func eventsOrdner(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(geraeteID, isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    /// Der Event-Ordner dieses Geräts innerhalb des Sync-Ordners — Ordnername
    /// trägt seit GitHub #81 den Gerätenamen (``SyncOrdnerService/eigenerPeerOrdnerName(in:)``),
    /// nicht mehr die rohe `geraeteID`.
    @MainActor
    static func eigenerEventsOrdner(in syncOrdner: URL) -> URL {
        eventsOrdner(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }

    /// Schreibt alle noch nicht hochgeladenen `SyncEvent`s in den eigenen
    /// Peer-Ordner und markiert sie danach als hochgeladen. Ohne hinterlegten
    /// Sync-Ordner (``SyncOrdnerService/gewaehlterOrdner()`` liefert `nil`) ohne
    /// Wirkung — Synchronisation ist optional.
    ///
    /// **Aufräumen alter Event-Dateien seit GitHub #89 wieder eingeführt**
    /// (siehe ``raeumeAlteEigeneEventDateienAufFallsFaellig()``) — ein früherer
    /// Versuch (reine Alters-Heuristik ohne Sicherheitsnetz) wurde revertiert,
    /// weil „hochgeladen" nur bedeutet, dass DIESES Gerät die Datei geschrieben
    /// hat, nicht, dass ein Peer sie bereits gelesen hat: ein zu diesem
    /// Zeitpunkt abwesender Peer verlor dadurch unwiederbringlich
    /// `artikelAbgehakt`-Events. Sicher ist die Löschung seit Peer-Lebenszyklus
    /// Baustein C nicht mehr über eine feste Alters-Frist, sondern über einen
    /// dynamischen Wasserstand (``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)``):
    /// gelöscht wird erst, wenn JEDER aktuell bekannte Peer nachweislich schon
    /// einen vollständigen Sync danach hatte — ein tatsächlich abwesender Peer
    /// hält den Wasserstand selbst zurück, solange er nicht per Peer-
    /// Lebenszyklus (Baustein A/B) ausgeschlossen wurde.
    /// Rückgabewert meldet ausschließlich, ob der Ordnerzugriff (Berechtigung)
    /// geklappt hat, analog ``SyncSnapshotImportService/importiereSnapshots(context:)``.
    @discardableResult
    @MainActor
    static func exportiereNeueEvents(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }

        var beschreibung = FetchDescriptor<SyncEvent>(
            predicate: #Predicate { $0.hochgeladen == false }
        )
        beschreibung.sortBy = [SortDescriptor(\.lamportZaehler)]
        guard let ausstehende = try? context.fetch(beschreibung), !ausstehende.isEmpty else { return true }

        let zugriffErfolgreich = syncOrdner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(aufrufstelle: "exportiereNeueEvents", erfolgreich: zugriffErfolgreich)
        guard zugriffErfolgreich else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereNeueEvents")
            return false
        }
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "exportiereNeueEvents")
        }

        let eventsOrdner = eigenerEventsOrdner(in: syncOrdner)
        // `nil` bedeutet Zeitüberschreitung/Fehler (Ordner nicht erreichbar) —
        // als echter Fehlschlag gemeldet statt wie zuvor stillschweigend als
        // Erfolg, sonst würde ``SyncAktualitaetsService/vermerkeErfolgreichenZyklus()``
        // fälschlich einen erfolgreichen Zyklus vermerken (GitHub
        // #49-Nachfolgefund, analog ``SyncImportService/importiereNeueEvents(context:)``).
        guard await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.erstelleVerzeichnisKoordiniert(eventsOrdner) }) == true else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereNeueEvents")
            return false
        }

        for event in ausstehende {
            guard let daten = try? JSONEncoder().encode(event.exportDarstellung) else { continue }
            let zielURL = eventsOrdner.appendingPathComponent(dateiname(fuer: event))
            // Zeitlimit statt (vormals) unbegrenzt blockierendem synchronem
            // Aufruf direkt auf dem `MainActor` — bei nicht erreichbarem
            // Ordner fror sonst die komplette UI ein, solange noch
            // ausstehende Events zu schreiben waren (GitHub #49-Nachfolgefund).
            guard await SyncDateiZugriff.mitZeitlimit({ SyncDateiZugriff.schreibeKoordiniert(daten, nach: zielURL) }) == true else { continue }
            event.hochgeladen = true
        }

        if context.hasChanges { try? context.save() }
        return true
    }

    private static let letzteEventBereinigungSchluessel = "syncEventBereinigungLetzteBereinigung"

    /// Mindestabstand zwischen zwei automatischen Aufräumläufen, analog
    /// `KaufEintragBereinigungService.automatischesIntervall` — verhindert,
    /// dass jeder 5s/60s-Sync-Zyklus den eigenen `events/`-Ordner komplett
    /// aufzählt.
    static let automatischesBereinigungsintervall: TimeInterval = 60 * 60 * 24

    static var letzteEventBereinigung: Date? {
        get { UserDefaults.standard.object(forKey: letzteEventBereinigungSchluessel) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: letzteEventBereinigungSchluessel) }
    }

    /// Löscht eigene Event-Dateien, deren Datei-Änderungsdatum vor dem
    /// aktuellen dynamischen Aufbewahrungs-Wasserstand liegt (siehe
    /// ``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)``,
    /// Peer-Lebenszyklus Baustein C) — höchstens einmal pro
    /// ``automatischesBereinigungsintervall`` tatsächlich ausgeführt (siehe
    /// `RootView` für den Aufrufort, analog den übrigen
    /// `automatisch…FallsFaellig`-Diensten). Kein Löschversuch, wenn der
    /// Wasserstand `nil` liefert (kein anderer Peer bekannt, oder ein
    /// aktuell vorhandener Peer-Ordner nicht lesbar).
    ///
    /// **Warum das Datei-Änderungsdatum statt eines Feldes im Event-Inhalt:**
    /// Ein Alters-Check über `wallClock` würde jede Datei erst lesen/dekodieren
    /// müssen — genau die Kosten, die der ID-Vorfilter beim Import (siehe
    /// `SyncImportService`) gerade vermeidet. Das Dateisystem-Änderungsdatum
    /// ist für diesen einmal-täglichen, groben Zweck präzise genug und kostet
    /// nur einen Verzeichnis-Listing-Aufruf.
    ///
    /// **Warum das sicher ist:** der Wasserstand garantiert, dass jeder
    /// aktuell bekannte Peer bereits einen vollständigen Sync NACH dem
    /// Löschzeitpunkt hatte (siehe Baustein C0, `SyncPeerManifest`-Typ-Doku)
    /// — ein Peer, der tatsächlich so lange abwesend war, dass er eine Datei
    /// verpasst haben könnte, hält den Wasserstand selbst zurück, solange er
    /// nicht per Peer-Lebenszyklus (Baustein A/B) ausgeschlossen wurde.
    /// - Parameter erzwungenerWasserstand: Wird nur vom manuellen „Ich bin
    ///   sicher, dass ich der einzige Peer bin"-Bestätigungs-Button in
    ///   `DebuggingView` übergeben und ersetzt dann den live berechneten
    ///   Wasserstand — für den Fall, dass ``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)``
    ///   dauerhaft `nil` liefert, weil aktuell kein anderer Peer bekannt ist.
    ///   Normale automatische Aufrufe lassen den Parameter `nil` und ändern
    ///   damit nichts am bisherigen Verhalten.
    @MainActor
    static func raeumeAlteEigeneEventDateienAufFallsFaellig(erzwungenerWasserstand: Date? = nil) async {
        if let letzte = letzteEventBereinigung, Date().timeIntervalSince(letzte) < automatischesBereinigungsintervall {
            return
        }
        letzteEventBereinigung = Date()

        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        // Eigener, in sich abgeschlossener Security-Scoped-Zugriff — VOR dem
        // Öffnen des eigenen Scopes unten aufgerufen, nicht von innen heraus,
        // um keinen verschachtelten/überlappenden Zugriff auf denselben
        // Bookmark zu erzeugen (siehe ``SyncOrdnerZugriffsDiagnose``-Typ-Doku).
        let berechneterWasserstand = erzwungenerWasserstand == nil
            ? await SyncSnapshotImportService.aktuellerAufraeumWasserstand(in: syncOrdner)
            : erzwungenerWasserstand
        guard let wasserstand = berechneterWasserstand else { return }

        let zugriffErfolgreich = syncOrdner.startAccessingSecurityScopedResource()
        SyncOrdnerZugriffsDiagnose.markiereOeffnen(aufrufstelle: "raeumeAlteEigeneEventDateienAuf", erfolgreich: zugriffErfolgreich)
        guard zugriffErfolgreich else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "raeumeAlteEigeneEventDateienAuf")
            return
        }
        defer {
            syncOrdner.stopAccessingSecurityScopedResource()
            SyncOrdnerZugriffsDiagnose.markiereSchliessen(aufrufstelle: "raeumeAlteEigeneEventDateienAuf")
        }

        let eventsOrdner = eigenerEventsOrdner(in: syncOrdner)
        guard let dateien = await Task.detached(priority: .utility, operation: {
            SyncDateiZugriff.listeKoordiniert(eventsOrdner)
        }).value else { return }

        let zuLoeschende = dateien.filter { datei in
            guard datei.pathExtension == "json",
                  let werte = try? datei.resourceValues(forKeys: [.contentModificationDateKey]),
                  let geaendertAm = werte.contentModificationDate
            else { return false }
            return geaendertAm < wasserstand
        }
        await Task.detached(priority: .utility, operation: {
            for datei in zuLoeschende {
                SyncDateiZugriff.loescheKoordiniert(datei)
            }
        }).value
        let geloeschteAnzahl = zuLoeschende.count
        if SyncDebugLogger.istAktiv, geloeschteAnzahl > 0 {
            SyncDebugLogger.log(.eventDateienBereinigt, details: "anzahl=\(geloeschteAnzahl)")
        }
    }

    /// Zehnstellig nullgepolsterter Lamport-Zähler sorgt für lexikografisch
    /// korrekte, aufsteigende Sortierung der Dateinamen unabhängig davon, wie das
    /// Dateisystem/der Cloud-Anbieter Verzeichnisse auflistet.
    private static func dateiname(fuer event: SyncEvent) -> String {
        let zaehlerText = String(event.lamportZaehler)
        let gepolstert = String(repeating: "0", count: max(0, 10 - zaehlerText.count)) + zaehlerText
        return "\(gepolstert)_\(event.id.uuidString).json"
    }

}
