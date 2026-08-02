import Foundation
import SwiftData
import CryptoKit

/// Bereich-B/C/D-Export (`docs/DATENSYNCHRONISATION_VERLAUF.md`
/// Abschnitt 5.2, Phase 1b, seit GitHub #82 Abschnitt 29): leitet aus dem
/// aktuellen lokalen Modellzustand mehrere Sync-Paket-Teile ab und schreibt
/// sie in den eigenen Peer-Ordner — siehe `docs/EXPORT_PAKET_UMBAU.md` für das
/// vollständige Layout (`manifest.json`/`tombstones.json`/`stamm.json`/
/// `lernen.json`/`vorgaenge.json`/`preise.json`; die Kaufhistorie liegt
/// separat in `kaeufe/`, siehe ``SyncKaeufeExportService``). Anders als
/// ``SyncExportService`` (Bereich A) kein inkrementelles Mitschreiben, sondern
/// bei jedem Aufruf ein vollständiger Neuaufbau JE TEIL. Reines Schreiben —
/// Lesen fremder Pakete ist ``SyncSnapshotImportService``.
///
/// **Schreibt nur bei tatsächlich geändertem Inhalt, pro Teil** (GitHub
/// #70/#71/#78/#82): ohne diesen Mechanismus würde jeder Sync-Zyklus (5s/60s)
/// einen vollständigen Neuaufbau samt Datei-Schreiben erzwingen, selbst wenn
/// sich am lokalen Bestand seit dem letzten Zyklus nichts geändert hatte —
/// jedes Gerät schriebe dadurch dauerhaft alle paar Sekunden neue Dateien mit
/// frischem Zeitstempel, was auf Peer-Seite wiederum jeden Zyklus eine echte
/// Store-Änderung erzwänge (siehe ``SyncPeerInfo``). ``exportierePaket(context:)``
/// vergleicht deshalb je Teil einen Inhalts-Fingerabdruck mit dem zuletzt
/// tatsächlich geschriebenen und überspringt Encoding *und* Datei-Schreiben,
/// wenn identisch — `manifest.json` selbst bildet die einzige Ausnahme (immer
/// geschrieben, siehe ``SyncPeerManifest``). Der Peer-Alters-Check
/// (``SyncSnapshotImportService/maximalesSnapshotAlter``) bleibt davon
/// unberührt: ein seit Tagen unverändertes, aber weiterhin aktives Gerät ist
/// kein „verwaister Peer-Ordner" — genau die 30-Tage-Schwelle dafür bleibt
/// grob genug, dass ein nicht mehr aktualisiertes `erzeugtAm` bei echter
/// Inaktivität kein Problem ist.
enum SyncSnapshotExportService {
    /// **GitHub #78:** `JSONEncoder` garantiert eine stabile Schlüsselreihenfolge
    /// nur mit `.sortedKeys` — ohne diese Option kann Foundation zwei inhaltlich
    /// identische Werte mit unterschiedlicher Top-Level-Schlüsselreihenfolge
    /// kodieren (empirisch bestätigt: zwei zeitnah nacheinander geschriebene
    /// `export.json` desselben, unveränderten Bestands begannen mit
    /// unterschiedlichen Schlüsseln). Ohne diese Option ergaben die
    /// Fingerabdruck-Vergleiche unten für inhaltlich identische Werte
    /// unterschiedliche SHA256-Hashes, wodurch der „nur bei echter Änderung
    /// schreiben"-Vergleich (GitHub #70/#71) fälschlich JEDEN Zyklus als
    /// geändert erkannte. Ein einziger geteilter, deterministisch
    /// konfigurierter Encoder für alle Verwendungsstellen (auch
    /// ``SyncKaeufeExportService``) statt mehrerer eigener `JSONEncoder()`-
    /// Instanzen. Bewusst nicht `private` — von ``SyncKaeufeExportService``
    /// mitgenutzt.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// `mitKaufEintraegen: false` überspringt Fetch und Mapping der (laut
    /// Analyse-Fund oft größten) `KaufEintrag`-Historie — für
    /// ``erstellePaketTeile(context:)`` (Peer-Zyklus-Pfad), der
    /// `snapshot.kaufEintraege` nie verwendet (seit GitHub #82 läuft die
    /// Kaufhistorie separat über ``SyncKaeufeExportService``). Ohne diesen
    /// Parameter lud jeder 5s/60s-Zyklus die komplette lokale Kaufhistorie aus
    /// SwiftData und kodierte sie in Snapshot-Structs, nur um das Ergebnis
    /// sofort zu verwerfen. Der Backup-Pfad (``SyncErsetzenService``) braucht
    /// weiterhin die volle Historie und lässt den Parameter auf seinem
    /// Default `true`.
    @MainActor
    static func erstelleSnapshot(context: ModelContext, mitKaufEintraegen: Bool = true) -> SyncSnapshot {
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

        let alleEinkaufslisten = (try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []
        let gueltigeEinkaufslistenIDs = Set(alleEinkaufslisten.map(\.persistentModelID))
        let einkaufslisten = alleEinkaufslisten.map {
            EinkaufslisteSnapshot(id: $0.id, name: $0.name, erstelltAm: $0.erstelltAm)
        }

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

        let alleEinkaufsvorgaenge = (try? context.fetch(FetchDescriptor<Einkaufsvorgang>())) ?? []
        let gueltigeEinkaufsvorgangIDs = Set(alleEinkaufsvorgaenge.map(\.persistentModelID))
        let einkaufsvorgaenge = alleEinkaufsvorgaenge.map {
            EinkaufsvorgangSnapshot(
                id: $0.id,
                geschaeftID: sichereID($0.geschaeft, gueltigeIDs: gueltigeGeschaeftIDs),
                einkaufslisteID: sichereID($0.einkaufsliste, gueltigeIDs: gueltigeEinkaufslistenIDs),
                startZeit: $0.startZeit,
                endZeit: $0.endZeit
            )
        }

        let kaufEintraege = mitKaufEintraegen
            ? ((try? context.fetch(FetchDescriptor<KaufEintrag>())) ?? []).map {
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
            : []

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
    /// Bewusst nicht `private` — von ``SyncKaeufeExportService`` mitgenutzt.
    static func sichereID<T: IdentifizierbaresModell>(_ objekt: T?, gueltigeIDs: Set<PersistentIdentifier>) -> UUID? {
        guard let objekt else { return nil }
        guard gueltigeIDs.contains(objekt.persistentModelID) else {
            SyncDebugLogger.log(.baumelndeReferenzGefunden, details: "typ=\(T.self) referenz=\(objekt.persistentModelID)")
            return nil
        }
        return objekt.id
    }

    /// Wie ``sichereID(_:gueltigeIDs:)``, für Arrays — verwaiste Einträge
    /// werden stillschweigend herausgefiltert statt die App abstürzen zu lassen.
    static func sichereIDs<T: IdentifizierbaresModell>(_ objekte: [T], gueltigeIDs: Set<PersistentIdentifier>) -> [UUID] {
        objekte.compactMap { sichereID($0, gueltigeIDs: gueltigeIDs) }
    }

    /// Schreibt über `NSFileCoordinator`, damit File-Provider-Erweiterungen von
    /// der Änderung erfahren — analog zum bestehenden Muster in
    /// ``DatabaseLeaseService``/``SyncExportService``. Bewusst nicht `private`
    /// — von ``SyncKaeufeExportService`` mitgenutzt.
    nonisolated static func schreibeBlocking(_ daten: Data, nach url: URL) -> Bool {
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

    // MARK: - Paket-Format (GitHub #82)

    /// Pfad-Bausteine für alle Peer-Paket-Dateien — Muster wie das bisherige
    /// `exportURL(fuerPeer:in:)`, jetzt mehrere benannte Dateien statt einer.
    private static func peerOrdner(fuer geraeteID: String, in syncOrdner: URL) -> URL {
        syncOrdner
            .appendingPathComponent("peers", isDirectory: true)
            .appendingPathComponent(geraeteID, isDirectory: true)
    }
    static func manifestURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("manifest.json")
    }
    static func tombstonesURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("tombstones.json")
    }
    static func stammURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("stamm.json")
    }
    /// GitHub #85: aus `stamm.json` herausgelöst, siehe ``SyncListenSnapshot``.
    static func listenURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("listen.json")
    }
    static func lernenURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("lernen.json")
    }
    static func vorgaengeURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("vorgaenge.json")
    }
    static func preiseURL(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("preise.json")
    }
    /// Bewusst nicht `private` — von ``SyncKaeufeExportService``/
    /// ``SyncSnapshotImportService`` mitgenutzt.
    static func kaeufeOrdner(fuerPeer geraeteID: String, in syncOrdner: URL) -> URL {
        peerOrdner(fuer: geraeteID, in: syncOrdner).appendingPathComponent("kaeufe", isDirectory: true)
    }

    @MainActor static func eigenerManifestURL(in syncOrdner: URL) -> URL {
        manifestURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    @MainActor static func eigeneTombstonesURL(in syncOrdner: URL) -> URL {
        tombstonesURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    @MainActor static func eigeneStammURL(in syncOrdner: URL) -> URL {
        stammURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    @MainActor static func eigeneListenURL(in syncOrdner: URL) -> URL {
        listenURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    @MainActor static func eigeneLernenURL(in syncOrdner: URL) -> URL {
        lernenURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    @MainActor static func eigeneVorgaengeURL(in syncOrdner: URL) -> URL {
        vorgaengeURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    @MainActor static func eigenePreiseURL(in syncOrdner: URL) -> URL {
        preiseURL(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }
    /// Bewusst nicht `private` — von ``SyncKaeufeExportService`` mitgenutzt.
    @MainActor static func eigenerKaeufeOrdner(in syncOrdner: URL) -> URL {
        kaeufeOrdner(fuerPeer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
    }

    /// Je ein `UserDefaults`-Schlüssel für den zuletzt geschriebenen
    /// Fingerabdruck jedes unabhängig geprüften Teils — ersetzt den einen
    /// `letzterFingerabdruckSchluessel` des bisherigen Monolithen.
    private static let fingerabdruckSchluesselTombstones = "syncPaketFingerabdruckTombstones"
    private static let fingerabdruckSchluesselStamm = "syncPaketFingerabdruckStamm"
    /// GitHub #85: aus `stamm.json` herausgelöst, siehe ``SyncListenSnapshot``.
    private static let fingerabdruckSchluesselListen = "syncPaketFingerabdruckListen"
    private static let fingerabdruckSchluesselLernen = "syncPaketFingerabdruckLernen"
    private static let fingerabdruckSchluesselVorgaenge = "syncPaketFingerabdruckVorgaenge"
    private static let fingerabdruckSchluesselPreise = "syncPaketFingerabdruckPreise"

    /// Debug-Werkzeug für manuelle Statuskonsolidierung: verwirft alle
    /// gespeicherten Fingerabdruck-Caches und erzwingt dadurch ein sofortiges,
    /// garantiert frisches Neuschreiben aller Teile — unabhängig vom
    /// sonstigen Skip-Mechanismus. Rein additiv/sicher: schreibt nur die
    /// eigenen Paket-Dateien neu, rührt keine fremden an.
    @discardableResult
    @MainActor
    static func erzwingeFrischesPaket(context: ModelContext) async -> Bool {
        for schluessel in [
            fingerabdruckSchluesselTombstones, fingerabdruckSchluesselStamm, fingerabdruckSchluesselListen,
            fingerabdruckSchluesselLernen, fingerabdruckSchluesselVorgaenge, fingerabdruckSchluesselPreise,
        ] {
            UserDefaults.standard.removeObject(forKey: schluessel)
        }
        return await exportierePaket(context: context)
    }

    /// Baut die Paket-Teile aus dem aktuellen Modellzustand und schreibt jeden
    /// nur dann neu, wenn sich sein Inhalt seit dem letzten Schreiben
    /// tatsächlich geändert hat — Nachfolger von `exportiereSnapshot(context:)`
    /// (siehe `docs/EXPORT_PAKET_UMBAU.md`). `manifest.json` wird davon
    /// unabhängig **immer** neu geschrieben (siehe ``SyncPeerManifest``).
    /// Ohne hinterlegten Sync-Ordner ohne Wirkung. Rückgabewert meldet
    /// ausschließlich, ob der Ordnerzugriff (Berechtigung) geklappt hat.
    @discardableResult
    @MainActor
    static func exportierePaket(context: ModelContext) async -> Bool {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return true }
        let teile = erstellePaketTeile(context: context)

        guard syncOrdner.startAccessingSecurityScopedResource() else {
            SyncDebugLogger.log(.ordnerZugriffFehlgeschlagen, details: "exportierePaket")
            return false
        }
        defer { syncOrdner.stopAccessingSecurityScopedResource() }

        let eigenerOrdner = peerOrdner(fuer: SyncOrdnerService.eigenerPeerOrdnerName(in: syncOrdner), in: syncOrdner)
        guard (try? FileManager.default.createDirectory(at: eigenerOrdner, withIntermediateDirectories: true)) != nil else {
            return true
        }

        if let manifestDaten = try? encoder.encode(teile.manifest) {
            _ = schreibeBlocking(manifestDaten, nach: eigenerOrdner.appendingPathComponent("manifest.json"))
        }

        schreibeTeilFallsGeaendert(
            normalisiereTombstones(teile.tombstones), url: eigenerOrdner.appendingPathComponent("tombstones.json"),
            fingerabdruckSchluessel: fingerabdruckSchluesselTombstones, teilName: "tombstones"
        )
        schreibeTeilFallsGeaendert(
            normalisiereStamm(teile.stamm), url: eigenerOrdner.appendingPathComponent("stamm.json"),
            fingerabdruckSchluessel: fingerabdruckSchluesselStamm, teilName: "stamm"
        )
        schreibeTeilFallsGeaendert(
            normalisiereListen(teile.listen), url: eigenerOrdner.appendingPathComponent("listen.json"),
            fingerabdruckSchluessel: fingerabdruckSchluesselListen, teilName: "listen"
        )
        schreibeTeilFallsGeaendert(
            normalisiereLernen(teile.lernen), url: eigenerOrdner.appendingPathComponent("lernen.json"),
            fingerabdruckSchluessel: fingerabdruckSchluesselLernen, teilName: "lernen"
        )
        schreibeTeilFallsGeaendert(
            normalisiereVorgaenge(teile.vorgaenge), url: eigenerOrdner.appendingPathComponent("vorgaenge.json"),
            fingerabdruckSchluessel: fingerabdruckSchluesselVorgaenge, teilName: "vorgaenge"
        )
        schreibeTeilFallsGeaendert(
            normalisierePreise(teile.preise), url: eigenerOrdner.appendingPathComponent("preise.json"),
            fingerabdruckSchluessel: fingerabdruckSchluesselPreise, teilName: "preise"
        )
        return true
    }

    /// Schreibt `wert` nur, wenn sein SHA256-Fingerabdruck vom zuletzt unter
    /// `fingerabdruckSchluessel` gespeicherten abweicht — Kern des „nur bei
    /// echter Änderung schreiben"-Verhaltens (GitHub #70/#71/#78), jetzt pro
    /// Teil statt einmal für den gesamten Monolithen. `wert` wird zuvor per
    /// `normalisiere*`-Funktion sortiert, damit eine bloß andere SwiftData-
    /// Fetch-Reihenfolge nicht fälschlich als Änderung erkannt wird — die
    /// GESCHRIEBENEN Bytes selbst müssen dafür nicht sortiert sein (Werte
    /// werden hier bereits normalisiert übergeben, siehe Aufrufer).
    ///
    /// Protokolliert im Sync-Debug-Modus explizit geschrieben/übersprungen je
    /// Teil (`teilName`) — Live-Test-Nachfolgefund: die Vorgänger-Funktion
    /// `exportiereSnapshot` hatte diese Sichtbarkeit (`.snapshotGeschrieben`/
    /// `.snapshotUnveraendertUebersprungen`), beim Aufteilen in fünf Teile
    /// zunächst verlorengegangen — ohne sie ließ sich „welcher Teil schreibt,
    /// welcher wird fälschlich als unverändert übersprungen" nicht mehr direkt
    /// aus dem Protokoll ablesen, nur noch indirekt über die Datei-Zeitstempel.
    ///
    /// **Live-Test-Nachfolgefund (2026-08-01): Fingerabdruck-Übereinstimmung
    /// allein reicht nicht.** `letzterGeschriebenerFingerabdruck` in
    /// `UserDefaults` übersteht bewusst einen App-Neustart (Zweck: „diese
    /// Daten habe ich schon geschrieben"), sagt aber nichts darüber aus, ob
    /// die zugehörige Datei am Zielort tatsächlich noch existiert. Nach
    /// Deaktivieren/Reaktivieren der Synchronisierung (oder jedem anderen
    /// Verlust der Zieldatei unabhängig von einer echten Inhaltsänderung)
    /// verhinderte das fälschlich jedes erneute Schreiben — beobachtet als
    /// dauerhaft fehlende `stamm.json`/`lernen.json`/`vorgaenge.json`/
    /// `preise.json`/`tombstones.json` in einem frisch verbundenen
    /// Peer-Ordner, während `manifest.json` (immer geschrieben) und
    /// `kaeufe/` (Existenz-Check auf die Datei selbst, kein Fingerabdruck)
    /// unauffällig blieben. Fix: zusätzlich zum Fingerabdruck-Vergleich
    /// prüfen, ob die Datei tatsächlich noch vorhanden ist — fehlt sie, wird
    /// unabhängig vom Fingerabdruck neu geschrieben.
    @discardableResult
    private static func schreibeTeilFallsGeaendert<T: Encodable>(_ wert: T, url: URL, fingerabdruckSchluessel: String, teilName: String) -> Bool {
        guard let daten = try? encoder.encode(wert) else { return true }
        let fingerabdruck = SHA256.hash(data: daten).map { String(format: "%02x", $0) }.joined()
        let unveraendertUndVorhanden = fingerabdruck == UserDefaults.standard.string(forKey: fingerabdruckSchluessel)
            && FileManager.default.fileExists(atPath: url.path)
        guard !unveraendertUndVorhanden else {
            if SyncDebugLogger.istAktiv {
                SyncDebugLogger.log(.snapshotUnveraendertUebersprungen, details: "\(teilName) fingerabdruck=\(fingerabdruck.prefix(8))")
            }
            return true
        }
        guard schreibeBlocking(daten, nach: url) else { return true }
        let vorherigerFingerabdruck = UserDefaults.standard.string(forKey: fingerabdruckSchluessel)
        UserDefaults.standard.set(fingerabdruck, forKey: fingerabdruckSchluessel)
        if SyncDebugLogger.istAktiv {
            let vorherKurz = vorherigerFingerabdruck.map { String($0.prefix(8)) } ?? "nil"
            SyncDebugLogger.log(.snapshotGeschrieben, details: "\(teilName) vorher=\(vorherKurz) jetzt=\(fingerabdruck.prefix(8))")
        }
        return true
    }

    private static func normalisiereTombstones(_ tombstones: [SyncTombstoneSnapshot]) -> [SyncTombstoneSnapshot] {
        tombstones.sorted { "\($0.entitaetsArt)_\($0.geloeschteID)" < "\($1.entitaetsArt)_\($1.geloeschteID)" }
    }

    /// Bewusst nicht `private` (analog dem bisherigen `normalisiertFuerVergleich`)
    /// — damit Tests direkt prüfen können, dass zwei `SyncStammSnapshot`, die
    /// sich nur in der Reihenfolge ihrer äußeren/inneren Arrays unterscheiden,
    /// denselben normalisierten Inhalt ergeben.
    static func normalisiereStamm(_ stamm: SyncStammSnapshot) -> SyncStammSnapshot {
        var stamm = stamm
        stamm.geschaeftsTypen.sort { $0.id.uuidString < $1.id.uuidString }
        stamm.artikelKategorien = stamm.artikelKategorien.map { kategorie in
            var kategorie = kategorie
            kategorie.geschaeftsTypIDs.sort { $0.uuidString < $1.uuidString }
            return kategorie
        }
        stamm.artikelKategorien.sort { $0.id.uuidString < $1.id.uuidString }
        stamm.geschaefte = stamm.geschaefte.map { geschaeft in
            var geschaeft = geschaeft
            geschaeft.typIDs.sort { $0.uuidString < $1.uuidString }
            geschaeft.kategorieIDs.sort { $0.uuidString < $1.uuidString }
            geschaeft.ausgeschlosseneKategorieIDs.sort { $0.uuidString < $1.uuidString }
            geschaeft.alternativeNamen.sort()
            geschaeft.ignorierteArtikelNamen.sort()
            return geschaeft
        }
        stamm.geschaefte.sort { $0.id.uuidString < $1.id.uuidString }
        stamm.artikel = stamm.artikel.map { artikel in
            var artikel = artikel
            artikel.kategorieIDs.sort { $0.uuidString < $1.uuidString }
            return artikel
        }
        stamm.artikel.sort { $0.id.uuidString < $1.id.uuidString }
        stamm.einkaufslisten.sort { $0.id.uuidString < $1.id.uuidString }
        stamm.artikelAliase.sort { $0.id.uuidString < $1.id.uuidString }
        return stamm
    }

    /// GitHub #85: analog dem entsprechenden Teil-Sort in ``normalisiereStamm(_:)``,
    /// nur für den jetzt eigenständigen ``SyncListenSnapshot``.
    private static func normalisiereListen(_ listen: SyncListenSnapshot) -> SyncListenSnapshot {
        var listen = listen
        listen.einkaufslistenEintraege.sort { "\($0.einkaufslisteID)_\($0.artikelID)" < "\($1.einkaufslisteID)_\($1.artikelID)" }
        return listen
    }

    private static func normalisiereLernen(_ lernen: SyncLernenSnapshot) -> SyncLernenSnapshot {
        var lernen = lernen
        lernen.warengruppenDistanzen.sort { $0.id.uuidString < $1.id.uuidString }
        return lernen
    }

    private static func normalisiereVorgaenge(_ vorgaenge: SyncVorgaengeSnapshot) -> SyncVorgaengeSnapshot {
        var vorgaenge = vorgaenge
        vorgaenge.einkaufsvorgaenge.sort { $0.id.uuidString < $1.id.uuidString }
        return vorgaenge
    }

    private static func normalisierePreise(_ preise: SyncPreisSnapshot) -> SyncPreisSnapshot {
        var preise = preise
        preise.preispunkte.sort { $0.id.uuidString < $1.id.uuidString }
        return preise
    }

    /// Zerlegt einen frisch gebauten ``erstelleSnapshot(context:mitKaufEintraegen:)``
    /// in die unabhängig fingerabdruck-geprüften Paket-Teile — **bewusst kein
    /// eigener, sparsamerer Fetch je Teil**: `stamm`/`listen`/`lernen`/
    /// `vorgaenge`/`preise`/`tombstones` sind klein und ihr Fetch war nie das
    /// Problem (Analyse-Fund: `kaufEintraege` allein machte 56% der
    /// Dateigröße aus, alles andere zusammen nur 44%). Der eigentliche
    /// Performance-Gewinn entsteht durch `mitKaufEintraegen: false` — dieser
    /// Bereich wird separat und inkrementell über ``SyncKaeufeExportService``
    /// geschrieben, ohne die wachsende Historie bei jedem Zyklus erneut aus
    /// SwiftData zu laden und zu kodieren. Wiederverwendung von
    /// ``erstelleSnapshot(context:mitKaufEintraegen:)`` hält diesen Code kurz
    /// und beweisbar konsistent mit dem weiterhin unveränderten Backup-Pfad
    /// (``SyncErsetzenService``, der die volle Historie über den Default
    /// `mitKaufEintraegen: true` weiterhin bekommt).
    ///
    /// `listen` (GitHub #85) separat von `stamm` zurückgegeben, obwohl beide
    /// aus demselben `snapshot.einkaufslistenEintraege`-Feld gespeist werden
    /// — sie werden vom Aufrufer unabhängig fingerabdruck-geprüft, damit ein
    /// häufiges Abhaken/Hinzufügen/Entfernen (ändert nur `listen`) nicht mehr
    /// automatisch auch die seltenen `stamm`-Stammdaten neu schreibt (siehe
    /// ``SyncListenSnapshot``).
    @MainActor
    static func erstellePaketTeile(context: ModelContext) -> (
        manifest: SyncPeerManifest, tombstones: [SyncTombstoneSnapshot], stamm: SyncStammSnapshot,
        listen: SyncListenSnapshot, lernen: SyncLernenSnapshot, vorgaenge: SyncVorgaengeSnapshot, preise: SyncPreisSnapshot
    ) {
        let snapshot = erstelleSnapshot(context: context, mitKaufEintraegen: false)
        let manifest = SyncPeerManifest(
            formatVersion: SyncPeerManifest.aktuelleFormatVersion, erzeugtAm: snapshot.erzeugtAm,
            geraeteID: snapshot.geraeteID, geraeteName: snapshot.geraeteName
        )
        let stamm = SyncStammSnapshot(
            geschaeftsTypen: snapshot.geschaeftsTypen, artikelKategorien: snapshot.artikelKategorien,
            geschaefte: snapshot.geschaefte, artikel: snapshot.artikel, einkaufslisten: snapshot.einkaufslisten,
            artikelAliase: snapshot.artikelAliase
        )
        let listen = SyncListenSnapshot(einkaufslistenEintraege: snapshot.einkaufslistenEintraege)
        let lernen = SyncLernenSnapshot(warengruppenDistanzen: snapshot.warengruppenDistanzen)
        let vorgaenge = SyncVorgaengeSnapshot(einkaufsvorgaenge: snapshot.einkaufsvorgaenge)
        let preise = SyncPreisSnapshot(preispunkte: snapshot.preispunkte)
        return (manifest, snapshot.tombstones, stamm, listen, lernen, vorgaenge, preise)
    }
}
