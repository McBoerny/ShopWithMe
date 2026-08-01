import Foundation
import SwiftData
import CryptoKit

/// Bereich-B/C/D-Export (`docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 5.2, Phase 1b): leitet einen vollständigen ``SyncSnapshot`` aus dem
/// aktuellen lokalen Modellzustand ab und schreibt ihn als `export.json` in den
/// eigenen Peer-Ordner. Anders als ``SyncExportService`` (Bereich A) kein
/// inkrementelles Mitschreiben, sondern bei jedem Aufruf ein vollständiger
/// Neuaufbau. Reines Schreiben — Lesen fremder Snapshots ist Phase 3.
///
/// **Schreibt nur bei tatsächlich geändertem Inhalt** (GitHub #70/#71): jeder
/// Sync-Zyklus (5s/60s) rief bisher unbedingt einen vollständigen Neuaufbau
/// samt Datei-Schreiben auf, selbst wenn sich am lokalen Bestand seit dem
/// letzten Zyklus nichts geändert hatte — jedes Gerät schrieb dadurch
/// dauerhaft alle paar Sekunden ein neues `export.json` mit frischem
/// ``SyncSnapshot/erzeugtAm``, was auf Peer-Seite wiederum jeden Zyklus eine
/// echte Store-Änderung erzwang (siehe ``SyncPeerInfo``). ``exportiereSnapshot(context:)``
/// vergleicht deshalb einen Inhalts-Fingerabdruck (``inhaltsFingerabdruck(of:)``,
/// ohne die reinen Metafelder `erzeugtAm`/`geraeteID`/`geraeteName`) mit dem
/// zuletzt tatsächlich geschriebenen und überspringt Encoding *und*
/// Datei-Schreiben, wenn identisch. Der Peer-Alters-Check
/// (``SyncSnapshotImportService/maximalesSnapshotAlter``) bleibt davon
/// unberührt: eine über Tage unveränderte, aber weiterhin gültige `export.json`
/// ist kein „verwaister Peer-Ordner" — genau die 30-Tage-Schwelle dafür bleibt
/// grob genug, dass ein nicht mehr aktualisiertes `erzeugtAm` bei echter
/// Inaktivität kein Problem ist.
enum SyncSnapshotExportService {
    private static let dateiName = "export.json"
    private static let letzterFingerabdruckSchluessel = "syncSnapshotLetzterFingerabdruck"

    /// Fingerabdruck des zuletzt tatsächlich geschriebenen Snapshot-Inhalts,
    /// `static var` statt Konstante, damit Tests den Zustand zurücksetzen
    /// können.
    private static var letzterGeschriebenerFingerabdruck: String? {
        get { UserDefaults.standard.string(forKey: letzterFingerabdruckSchluessel) }
        set { UserDefaults.standard.set(newValue, forKey: letzterFingerabdruckSchluessel) }
    }

    /// Die `export.json`-URL eines beliebigen Geräts (eigenes oder fremdes)
    /// innerhalb des Sync-Ordners — siehe ``SyncSnapshotImportService`` für das
    /// Lesen fremder Snapshots.
    static func exportURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(geraeteID, isDirectory: true)
            .appendingPathComponent(dateiName)
    }

    /// Die `export.json`-URL dieses Geräts innerhalb des Sync-Ordners —
    /// Ordnername trägt seit GitHub #81 den Gerätenamen
    /// (``SyncOrdnerService/eigenerPeerOrdnerName(in:)``), nicht mehr die
    /// rohe `geraeteID`.
    @MainActor
    static func eigeneExportURL(in syncOrdner: URL) -> URL {
        exportURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }

    /// Debug-Werkzeug für manuelle Statuskonsolidierung
    /// (``SyncOrdnerSettingsView``): verwirft den gespeicherten
    /// Fingerabdruck-Cache und erzwingt dadurch einen sofortigen, garantiert
    /// frischen Voll-Export — unabhängig vom sonstigen Skip-Mechanismus. Rein
    /// additiv/sicher: schreibt nur die eigene `export.json` neu, rührt keine
    /// fremden Dateien an.
    @discardableResult
    @MainActor
    static func erzwingeFrischenExport(context: ModelContext) async -> Bool {
        letzterGeschriebenerFingerabdruck = nil
        return await exportiereSnapshot(context: context)
    }

    /// Baut den ``SyncSnapshot`` aus dem aktuellen Modellzustand und schreibt ihn
    /// nach `peers/{geraeteID}/export.json`. Ohne hinterlegten Sync-Ordner
    /// (``SyncOrdnerService/gewaehlterOrdner()`` liefert `nil`) ohne Wirkung.
    /// Rückgabewert meldet ausschließlich, ob der Ordnerzugriff (Berechtigung)
    /// geklappt hat, analog ``SyncSnapshotImportService/importiereSnapshots(context:)``.
    @discardableResult
    @MainActor
    static func exportiereSnapshot(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }

        let snapshot = erstelleSnapshot(context: context)
        let normalisiert = normalisiertFuerVergleich(snapshot)
        guard let fingerabdruck = inhaltsFingerabdruck(of: normalisiert) else { return true }
        guard fingerabdruck != letzterGeschriebenerFingerabdruck else {
            if SyncDebugLogger.istAktiv {
                SyncDebugLogger.log(.snapshotUnveraendertUebersprungen, details: diagnoseText(of: normalisiert))
            }
            return true
        }
        guard let daten = try? JSONEncoder().encode(snapshot) else { return true }

        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportiereSnapshot")
            return false
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let zielURL = eigeneExportURL(in: syncOrdner)
        guard (try? FileManager.default.createDirectory(
            at: zielURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )) != nil else { return true }

        guard schreibeBlocking(daten, nach: zielURL) else { return true }
        let vorherigerFingerabdruck = letzterGeschriebenerFingerabdruck
        letzterGeschriebenerFingerabdruck = fingerabdruck
        if SyncDebugLogger.istAktiv {
            // vorher=nil beim allerersten Schreiben dieses Geräts — sonst die
            // ersten 8 Zeichen des vorherigen Fingerabdrucks, damit sich ein
            // Schreiben im Protokoll eindeutig einem vorherigen Übersprungen-
            // Eintrag zuordnen lässt.
            let vorherKurz = vorherigerFingerabdruck.map { String($0.prefix(8)) } ?? "nil"
            SyncDebugLogger.log(.snapshotGeschrieben, details: "vorher=\(vorherKurz) \(diagnoseText(of: normalisiert))")
        }
        return true
    }

    /// Normalisiert `snapshot` für den Inhalts-Vergleich (Fingerabdruck +
    /// Diagnose-Text): entfernt die reinen Metafelder `erzeugtAm`/`geraeteID`/
    /// `geraeteName`, die sich unabhängig vom eigentlichen Datenbestand jeden
    /// Zyklus ändern (würden) und damit jeden Vergleich wertlos machen
    /// würden, und sortiert alle Teil-Arrays nach ihrer `UUID`, damit eine
    /// bloß andere Fetch-Reihenfolge zwischen zwei Zyklen (SwiftData
    /// garantiert keine stabile Reihenfolge für einen unsortierten
    /// `FetchDescriptor`) nicht fälschlich als inhaltliche Änderung erkannt
    /// wird.
    ///
    /// **Live-Test-Nachfolgefund:** Dieselbe Instabilität gilt nicht nur für
    /// die äußeren Arrays (ein Snapshot-Eintrag je Entität), sondern auch für
    /// die ID-Arrays INNERHALB eines einzelnen Eintrags, die aus einer
    /// SwiftData-`@Relationship`-Sammlung abgeleitet sind (z.B.
    /// `GeschaeftSnapshot/typIDs`/`kategorieIDs` aus `Geschaeft.typen`/
    /// `.kategorien`) — deren Reihenfolge ist beim erneuten Fetch ebenso
    /// wenig garantiert wie die des äußeren `FetchDescriptor`. Ohne
    /// zusätzliche Sortierung dieser inneren Arrays erschien praktisch jeder
    /// Zyklus als inhaltliche Änderung, obwohl sich nur die Reihenfolge (nie
    /// die Menge) der zugeordneten IDs unterschied — beobachtet als
    /// durchgehend `sync_snapshot_geschrieben` statt
    /// `sync_snapshot_unveraendert_uebersprungen`, obwohl Anzahl und
    /// Fach-Inhalt über viele Zyklen stabil blieben.
    /// Bewusst `internal` statt `private` (kein `private` vor `static func`) —
    /// damit Tests direkt prüfen können, dass zwei Snapshots, die sich nur in
    /// der Reihenfolge ihrer ID-Arrays unterscheiden, denselben normalisierten
    /// Inhalt ergeben, ohne auf tatsächlich instabile SwiftData-Fetch-Reihenfolge
    /// angewiesen zu sein (die sich in einem kleinen In-Memory-Testcontainer
    /// nicht zuverlässig erzwingen lässt).
    static func normalisiertFuerVergleich(_ snapshot: SyncSnapshot) -> SyncSnapshot {
        var normalisiert = snapshot
        normalisiert.erzeugtAm = .distantPast
        normalisiert.geraeteID = ""
        normalisiert.geraeteName = ""

        normalisiert.geschaeftsTypen.sort { $0.id.uuidString < $1.id.uuidString }

        normalisiert.artikelKategorien = normalisiert.artikelKategorien.map { kategorie in
            var kategorie = kategorie
            kategorie.geschaeftsTypIDs.sort { $0.uuidString < $1.uuidString }
            return kategorie
        }
        normalisiert.artikelKategorien.sort { $0.id.uuidString < $1.id.uuidString }

        normalisiert.geschaefte = normalisiert.geschaefte.map { geschaeft in
            var geschaeft = geschaeft
            geschaeft.typIDs.sort { $0.uuidString < $1.uuidString }
            geschaeft.kategorieIDs.sort { $0.uuidString < $1.uuidString }
            geschaeft.ausgeschlosseneKategorieIDs.sort { $0.uuidString < $1.uuidString }
            geschaeft.alternativeNamen.sort()
            geschaeft.ignorierteArtikelNamen.sort()
            return geschaeft
        }
        normalisiert.geschaefte.sort { $0.id.uuidString < $1.id.uuidString }

        normalisiert.artikel = normalisiert.artikel.map { artikel in
            var artikel = artikel
            artikel.kategorieIDs.sort { $0.uuidString < $1.uuidString }
            return artikel
        }
        normalisiert.artikel.sort { $0.id.uuidString < $1.id.uuidString }

        normalisiert.einkaufslisten.sort { $0.id.uuidString < $1.id.uuidString }
        normalisiert.einkaufslistenEintraege.sort {
            "\($0.einkaufslisteID)_\($0.artikelID)" < "\($1.einkaufslisteID)_\($1.artikelID)"
        }
        normalisiert.einkaufsvorgaenge.sort { $0.id.uuidString < $1.id.uuidString }
        normalisiert.kaufEintraege.sort { $0.id.uuidString < $1.id.uuidString }
        normalisiert.preispunkte.sort { $0.id.uuidString < $1.id.uuidString }
        normalisiert.artikelAliase.sort { $0.id.uuidString < $1.id.uuidString }
        normalisiert.warengruppenDistanzen.sort { $0.id.uuidString < $1.id.uuidString }
        normalisiert.tombstones.sort { "\($0.entitaetsArt)_\($0.geloeschteID)" < "\($1.entitaetsArt)_\($1.geloeschteID)" }
        return normalisiert
    }

    /// SHA256-Fingerabdruck eines bereits ``normalisiertFuerVergleich(_:)``-ten
    /// Snapshots. `nil` nur bei einem (praktisch nie auftretenden)
    /// Encoding-Fehler.
    static func inhaltsFingerabdruck(of normalisiert: SyncSnapshot) -> String? {
        guard let daten = try? JSONEncoder().encode(normalisiert) else { return nil }
        let digest = SHA256.hash(data: daten)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Diagnose-Hilfsmittel für GitHub #70-Nachfolgefragen („welches Bereich
    /// löst tatsächlich einen Schreibvorgang aus, wie oft"): Anzahl UND ein
    /// kurzer Inhalts-Fingerabdruck je Teil-Bereich, damit sich zwei
    /// aufeinanderfolgende Protokollzeilen im Sync-Debug-Modus direkt
    /// vergleichen lassen — ändert sich nur die Anzahl, wuchs/schrumpfte der
    /// Bereich; ändert sich nur der Fingerabdruck bei gleicher Anzahl, hat
    /// sich ein Feld eines bestehenden Eintrags geändert (z.B. `endZeit`
    /// gesetzt, ein additiver Zähler erhöht). Nur aufrufen, wenn
    /// ``SyncDebugLogger/istAktiv`` ist — Encoding+Hashing pro Teil-Bereich
    /// ist bewusst nicht Teil des normalen (nicht-debuggenden) Pfads.
    private static func diagnoseText(of normalisiert: SyncSnapshot) -> String {
        func teil<T: Encodable>(_ name: String, _ werte: [T]) -> String {
            guard let daten = try? JSONEncoder().encode(werte) else { return "\(name)=\(werte.count)/?" }
            let kurz = SHA256.hash(data: daten).prefix(4).map { String(format: "%02x", $0) }.joined()
            return "\(name)=\(werte.count)/\(kurz)"
        }
        return [
            teil("geschaeftsTypen", normalisiert.geschaeftsTypen),
            teil("artikelKategorien", normalisiert.artikelKategorien),
            teil("geschaefte", normalisiert.geschaefte),
            teil("artikel", normalisiert.artikel),
            teil("einkaufslisten", normalisiert.einkaufslisten),
            teil("einkaufslistenEintraege", normalisiert.einkaufslistenEintraege),
            teil("einkaufsvorgaenge", normalisiert.einkaufsvorgaenge),
            teil("kaufEintraege", normalisiert.kaufEintraege),
            teil("preispunkte", normalisiert.preispunkte),
            teil("artikelAliase", normalisiert.artikelAliase),
            teil("warengruppenDistanzen", normalisiert.warengruppenDistanzen),
            teil("tombstones", normalisiert.tombstones),
        ].joined(separator: " ")
    }

    @MainActor
    static func erstelleSnapshot(context: ModelContext) -> SyncSnapshot {
        let alleGeschaeftsTypen = (try? context.fetch(FetchDescriptor<GeschaeftTyp>())) ?? []
        let gueltigeGeschaeftsTypIDs = Set(alleGeschaeftsTypen.map(\.persistentModelID))
        let geschaeftsTypen = alleGeschaeftsTypen.map {
            GeschaeftTypSnapshot(id: $0.id, name: $0.name, symbolName: $0.symbolName, farbeHex: $0.farbeHex, sortIndex: $0.sortIndex)
        }

        let alleArtikelKategorien = (try? context.fetch(FetchDescriptor<ArtikelKategorie>())) ?? []
        let gueltigeKategorieIDs = Set(alleArtikelKategorien.map(\.persistentModelID))
        let artikelKategorien = alleArtikelKategorien.map {
            ArtikelKategorieSnapshot(
                id: $0.id,
                name: $0.name,
                standardSymbol: $0.standardSymbol,
                standardFarbeHex: $0.standardFarbeHex,
                sortIndex: $0.sortIndex,
                geschaeftsTypIDs: sichereIDs($0.geschaeftsTypen, gueltigeIDs: gueltigeGeschaeftsTypIDs)
            )
        }

        let alleGeschaefte = (try? context.fetch(FetchDescriptor<Geschaeft>())) ?? []
        let gueltigeGeschaeftIDs = Set(alleGeschaefte.map(\.persistentModelID))
        let geschaefte = alleGeschaefte.map { geschaeft in
            GeschaeftSnapshot(
                id: geschaeft.id,
                name: geschaeft.name,
                typIDs: sichereIDs(geschaeft.typen, gueltigeIDs: gueltigeGeschaeftsTypIDs),
                adresse: geschaeft.adresse,
                breitengrad: geschaeft.breitengrad,
                laengengrad: geschaeft.laengengrad,
                erkennungsradius: geschaeft.erkennungsradiusRaw,
                kategorieIDs: sichereIDs(geschaeft.kategorien, gueltigeIDs: gueltigeKategorieIDs),
                ausgeschlosseneKategorieIDs: sichereIDs(geschaeft.ausgeschlosseneKategorien, gueltigeIDs: gueltigeKategorieIDs),
                alternativeNamen: geschaeft.alternativeNamen,
                ignorierteArtikelNamen: geschaeft.ignorierteArtikel.map(\.erkannterName),
                eigeneAnzahlEinkaufsvorgaenge: geschaeft.eigeneAnzahlEinkaufsvorgaenge,
                umbauVerdacht: geschaeft.umbauVerdacht,
                unauffaelligeEinkaeufeInFolge: geschaeft.unauffaelligeEinkaeufeInFolge
            )
        }

        let alleArtikel = (try? context.fetch(FetchDescriptor<Artikel>())) ?? []
        let gueltigeArtikelIDs = Set(alleArtikel.map(\.persistentModelID))
        let artikel = alleArtikel.map { artikel -> ArtikelSnapshot in
            let kategorieIDs = artikel.kategorien.isEmpty
                ? sichereIDs(artikel.kategorie.map { [$0] } ?? [], gueltigeIDs: gueltigeKategorieIDs)
                : sichereIDs(artikel.kategorien, gueltigeIDs: gueltigeKategorieIDs)
            return ArtikelSnapshot(
                id: artikel.id,
                name: artikel.name,
                symbolName: artikel.symbolName,
                farbeHex: artikel.farbeHex,
                kategorieIDs: kategorieIDs,
                notiz: artikel.notiz,
                einheit: artikel.einheit.rawValue,
                mengenSchritt: artikel.mengenSchritt,
                erstelltAm: artikel.erstelltAm
            )
        }

        let einkaufslisten = ((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map {
            EinkaufslisteSnapshot(id: $0.id, name: $0.name, erstelltAm: $0.erstelltAm)
        }
        let gueltigeEinkaufslistenIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsliste>()))?.map(\.persistentModelID) ?? [])

        // Vollständiger Einkaufslisten-Inhalt (Architektur-Revision „Alternative
        // A") — additives Sicherheitsnetz neben den Bereich-A-Events, siehe
        // Typ-Doku von ``SyncSnapshot/einkaufslistenEintraege``.
        let einkaufslistenEintraege = ((try? context.fetch(FetchDescriptor<EinkaufslistenEintrag>())) ?? [])
            .compactMap { eintrag -> EinkaufslistenEintragSnapshot? in
                guard let einkaufslisteID = sichereID(eintrag.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs),
                      let artikelID = sichereID(eintrag.artikel, gueltigeIDs: gueltigeArtikelIDs)
                else { return nil }
                return EinkaufslistenEintragSnapshot(
                    einkaufslisteID: einkaufslisteID, artikelID: artikelID, menge: eintrag.menge, notiz: eintrag.notiz
                )
            }

        let einkaufsvorgaenge = ((try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []).map {
            EinkaufsvorgangSnapshot(
                id: $0.id,
                geschaeftID: sichereID($0.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                einkaufslisteID: sichereID($0.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs),
                startZeit: $0.startZeit,
                endZeit: $0.endZeit
            )
        }
        let gueltigeEinkaufsvorgangIDs = Set((try? context.fetch(FetchDescriptor<Einkaufsvorgang>()))?.map(\.persistentModelID) ?? [])

        let kaufEintraege = ((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []).map {
            KaufEintragSnapshot(
                id: $0.id,
                artikelID: sichereID($0.artikel, gueltigeIDs: gueltigeArtikelIDs),
                einkaufsvorgangID: sichereID($0.einkaufsvorgang, gueltigeIDs: gueltigeEinkaufsvorgangIDs),
                geschaeftID: sichereID($0.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                kategorieID: sichereID($0.kategorie, gueltigeIDs: gueltigeKategorieIDs),
                artikelNameSnapshot: $0.artikelNameSnapshot,
                geschaeftNameSnapshot: $0.geschaeftNameSnapshot,
                datum: $0.datum,
                menge: $0.menge,
                kategorieBesuchsIndex: $0.kategorieBesuchsIndex
            )
        }

        let preispunkte = ((try? context.fetch(FetchDescriptor<Preispunkt>())) ?? []).map {
            PreispunktSnapshot(
                id: $0.id,
                artikelID: sichereID($0.artikel, gueltigeIDs: gueltigeArtikelIDs),
                geschaeftID: sichereID($0.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                preis: $0.preis,
                datum: $0.datum,
                produktName: $0.produktName,
                alternativerName: $0.alternativerName,
                artikelNameSnapshot: $0.artikelNameSnapshot,
                geschaeftNameSnapshot: $0.geschaeftNameSnapshot
            )
        }

        let artikelAliase = ((try? context.fetch(FetchDescriptor<ArtikelAlias>())) ?? []).map {
            ArtikelAliasSnapshot(
                id: $0.id,
                erkannterName: $0.erkannterName,
                alternativerName: $0.alternativerName,
                artikelID: sichereID($0.artikel, gueltigeIDs: gueltigeArtikelIDs)
            )
        }

        let warengruppenDistanzen = ((try? context.fetch(FetchDescriptor<WarengruppenDistanz>())) ?? [])
            .compactMap { distanz -> WarengruppenDistanzSnapshot? in
                guard let kategorieAID = sichereID(distanz.kategorieA, gueltigeIDs: gueltigeKategorieIDs),
                      let kategorieBID = sichereID(distanz.kategorieB, gueltigeIDs: gueltigeKategorieIDs)
                else { return nil }
                return WarengruppenDistanzSnapshot(
                    id: distanz.id,
                    geschaeftID: sichereID(distanz.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                    kategorieAID: kategorieAID,
                    kategorieBID: kategorieBID,
                    distanz: distanz.distanz
                )
            }

        let tombstones = SyncTombstoneService.alle(context: context).map {
            SyncTombstoneSnapshot(entitaetsArt: $0.entitaetsArt, geloeschteID: $0.geloeschteID, geloeschtAm: $0.geloeschtAm)
        }

        return SyncSnapshot(
            formatVersion: SyncSnapshot.aktuelleFormatVersion,
            erzeugtAm: Date(),
            geraeteID: DatabaseLeaseService.geraeteID,
            geraeteName: DatabaseLeaseService.geraeteName,
            geschaeftsTypen: geschaeftsTypen,
            artikelKategorien: artikelKategorien,
            geschaefte: geschaefte,
            artikel: artikel,
            einkaufslisten: einkaufslisten,
            einkaufslistenEintraege: einkaufslistenEintraege,
            einkaufsvorgaenge: einkaufsvorgaenge,
            kaufEintraege: kaufEintraege,
            preispunkte: preispunkte,
            artikelAliase: artikelAliase,
            warengruppenDistanzen: warengruppenDistanzen,
            tombstones: tombstones
        )
    }

    /// Liefert die `id` von `objekt`, aber nur, falls es tatsächlich in
    /// `gueltigeIDs` enthalten ist. Schützt vor bereits (durch fehlende
    /// `inverse`-Deklarationen, siehe ``Geschaeft/einkaufsvorgaenge``)
    /// "baumelnden" Referenzen auf gelöschte Objekte: `persistentModelID` ist
    /// reines Identitäts-Metadatum und daher auch auf einer baumelnden
    /// Referenz sicher lesbar, während der Zugriff auf `id` (oder jede andere
    /// Eigenschaft) in diesem Fall mit einem SwiftData-Fatal-Error abstürzt.
    private static func sichereID<T: IdentifizierbaresModell>(_ objekt: T?, gueltigeIDs: Set<PersistentIdentifier>) -> UUID? {
        guard let objekt else { return nil }
        guard gueltigeIDs.contains(objekt.persistentModelID) else {
            SyncDebugLogger.log(.baumelndeReferenzGefunden, details: "typ=\(T.self) referenz=\(objekt.persistentModelID)")
            return nil
        }
        return objekt.id
    }

    /// Wie ``sichereID(_:gueltigeIDs:)``, für Arrays — verwaiste Einträge
    /// werden stillschweigend herausgefiltert statt die App abstürzen zu lassen.
    private static func sichereIDs<T: IdentifizierbaresModell>(_ objekte: [T], gueltigeIDs: Set<PersistentIdentifier>) -> [UUID] {
        objekte.compactMap { sichereID($0, gueltigeIDs: gueltigeIDs) }
    }

    /// Schreibt über `NSFileCoordinator`, damit File-Provider-Erweiterungen von
    /// der Änderung erfahren — analog zum bestehenden Muster in
    /// ``DatabaseLeaseService``/``SyncExportService``.
    nonisolated private static func schreibeBlocking(_ daten: Data, nach url: URL) -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinatorFehler: NSError?
        var erfolgreich = false
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorFehler) { zielURL in
            do {
                try daten.write(to: zielURL, options: .atomic)
                erfolgreich = true
            } catch {
                erfolgreich = false
            }
        }
        return coordinatorFehler == nil && erfolgreich
    }
}
