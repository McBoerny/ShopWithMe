import Foundation

/// Fachlicher Wrapper um ``DebugLogWriter`` für die Datensynchronisation
/// (`docs/DATENSYNCHRONISATION_VERLAUF.md`, GitHub #39, `docs/LOGGING.md`).
/// Protokolliert nur, wenn der Debug-Modus in den Einstellungen aktiv ist —
/// Standard: aus, kein spürbarer Overhead bei Deaktivierung (In-Memory-gecachter
/// Schalter-Zustand, analog ``DatabaseDebugLogger``).
///
/// **Zweck:** Der Plan-Dokument-Abschnitt „Realistische Erwartung ohne
/// Multipeer" schätzt die tatsächliche Sync-Latenz (5–30s iCloud Drive, 1–10s
/// Synology Drive) auf Basis von `docs/DATABASE_CONCURRENCY.md`, nicht auf
/// Basis echter Messungen — und Phase 4 verzichtet bewusst auf Fehler-Backoff,
/// weil die Sync-Funktionen bisher keine auswertbare Erfolgs-/Fehlerrückmeldung
/// liefern. Dieses Protokoll schafft die fehlende Datengrundlage für beides:
/// tatsächlich beobachtete Latenz (wie alt war ein empfangenes Update, als es
/// hier ankam) und tatsächliche Fehlerhäufigkeit, um die Polling-Intervalle aus
/// ``SyncPollingService`` später mit echten Praxisdaten statt Annahmen
/// nachzujustieren.
///
/// Anders als ``DatabaseDebugLogger`` bewusst **nur lokal**, ohne Spiegelung in
/// den Sync-Ordner — die für die Optimierung relevanten Werte (Alter eines
/// empfangenen Updates, Dauer eines Sync-Zyklus) sind bereits aus rein lokaler
/// Sicht aussagekräftig; eine geräteübergreifende Zusammenführung würde
/// zusätzliche Sicherheits-Scope-Handhabung beim Schreiben in den Sync-Ordner
/// erfordern, ohne für den Optimierungszweck nötig zu sein.
enum SyncDebugLogger {
    /// Protokollierte Ereignistypen (siehe `docs/LOGGING.md` → Abschnitt
    /// „Datensynchronisation").
    enum Ereignis: String {
        case zyklusStart = "sync_zyklus_start"
        case zyklusEnde = "sync_zyklus_ende"
        case eventEmpfangen = "sync_event_empfangen"
        case snapshotEmpfangen = "sync_snapshot_empfangen"
        case ordnerZugriffFehlgeschlagen = "sync_ordner_zugriff_fehlgeschlagen"
        case baumelndeReferenzGefunden = "sync_baumelnde_referenz_gefunden"
        case einkaufslistenStand = "sync_einkaufslisten_stand"
        case eventNichtAnwendbar = "sync_event_nicht_anwendbar"
        case peerVerworfenAltersgrenze = "sync_peer_verworfen_altersgrenze"
        case snapshotUnveraendertUebersprungen = "sync_snapshot_unveraendert_uebersprungen"
        case snapshotGeschrieben = "sync_snapshot_geschrieben"
        case eventAufgegeben = "sync_event_aufgegeben"
        case debugModeEnabled = "debug_mode_enabled"
        case debugModeDisabled = "debug_mode_disabled"
        /// Diagnose für einen Nutzerbericht (2026-08-02, "Einkauf abschließen
        /// synchronisiert nicht"): ``SyncSnapshotImportService.mergeEinkaufsvorgaenge``
        /// protokolliert damit explizit, WARUM eine vom Peer gemeldete `endZeit`
        /// NICHT auf den lokalen Einkaufsvorgang übertragen wurde.
        case einkaufsvorgangAbschlussNichtUebernommen = "sync_einkaufsvorgang_abschluss_nicht_uebernommen"
        /// Gegenstück zu ``einkaufsvorgangAbschlussNichtUebernommen`` — die
        /// `endZeit` wurde tatsächlich übernommen (Erfolgsfall zur Kontrolle).
        case einkaufsvorgangAbschlussUebernommen = "sync_einkaufsvorgang_abschluss_uebernommen"
        /// Ein Einkaufsvorgang-Eintrag wurde ohne jeden Matching-Versuch
        /// übersprungen (unauflösbare Liste ohne bekannten ID-/Alias-Treffer,
        /// oder per Tombstone als gelöscht markiert).
        case einkaufsvorgangEintragUebersprungen = "sync_einkaufsvorgang_eintrag_uebersprungen"
        /// GitHub #89: ``SyncExportService/raeumeAlteEigeneEventDateienAufFallsFaellig()``
        /// hat eigene Event-Dateien gelöscht, die älter als der aktuelle
        /// dynamische Aufbewahrungs-Wasserstand waren (Peer-Lebenszyklus
        /// Baustein C, siehe ``SyncSnapshotImportService/aktuellerAufraeumWasserstand(in:)``).
        /// Details: `anzahl=N`.
        case eventDateienBereinigt = "sync_event_dateien_bereinigt"
        /// Peer-Lebenszyklus, Baustein C: ``SyncTombstoneService/raeumeAlteTombstonesAufFallsFaellig(context:)``
        /// hat Tombstones gelöscht, die älter als der aktuelle dynamische
        /// Aufbewahrungs-Wasserstand waren. Details: `anzahl=N`.
        case tombstonesBereinigt = "sync_tombstones_bereinigt"
        /// GitHub #89: ``SyncAktualitaetsService/istAusDerZeitGefallen(context:)``
        /// hat zugeschlagen — ein bereits etabliertes Gerät war länger als
        /// ``SyncAktualitaetsService/veraltungsSchwelle`` nicht erfolgreich
        /// synchronisiert. Details: `zuletztErfolgreichAm=…`.
        case ausDerZeitGefallenErkannt = "sync_aus_der_zeit_gefallen_erkannt"
        /// GitHub #89: der erzwungene Voll-Abgleich für ein „aus der Zeit
        /// gefallenes" Gerät wurde erfolgreich eingeleitet (eigener Export
        /// abgeschlossen, „Ersetzen durch Peer" für den nächsten Start
        /// vorgemerkt).
        case vollAbgleichEingeleitet = "sync_voll_abgleich_eingeleitet"
        /// Diagnose für einen Live-Test-Fund (2026-08-02, „Backup"-Gerät nach
        /// permanentem `sync_ordner_zugriff_fehlgeschlagen`, siehe
        /// `docs/DATENSYNCHRONISATION_VERLAUF.md` §30/§32): jeder
        /// `startAccessingSecurityScopedResource()`/`stop…`-Aufruf einer der
        /// Top-Level-Sync-Funktionen (siehe ``SyncOrdnerZugriffsDiagnose``),
        /// mit Aufrufstelle, Erfolg/Fehlschlag und welche anderen
        /// Aufrufstellen zu diesem Zeitpunkt selbst noch einen eigenen Scope
        /// offen halten — verschachtelter/überlappender Zugriff war die Root
        /// Cause des historischen §30-Vorfalls und lässt sich damit von einem
        /// rein extern verursachten Ordner-Ausfall unterscheiden. Nur bei
        /// ``Protokollstufe/ausfuehrlich`` protokolliert (feuert pro
        /// Aufrufstelle bei jedem Zyklus).
        case scopeZugriff = "sync_scope_zugriff"

        /// GitHub #91 (dritter Anlauf): ``SyncICloudAenderungsBeobachter``
        /// hat eine `NSMetadataQueryDidUpdateNotification` erhalten und
        /// einen zusätzlichen Sync-Zyklus angestoßen — Beleg dafür, dass die
        /// langlebige Query tatsächlich Fremdänderungen bemerkt (statt nur
        /// beim ersten, wirkungslosen Einzelaufruf-Versuch zu verharren).
        case iCloudBeobachterAusgeloest = "sync_icloud_beobachter_ausgeloest"

        /// ``SyncICloudAenderungsBeobachter`` hat die Query mit
        /// aktualisierten Scopes neu aufgebaut (initial oder weil sich die
        /// bekannte Peer-Liste geändert hat). Details:
        /// `peers=N scopes=M`.
        case iCloudBeobachterScopeAktualisiert = "sync_icloud_beobachter_scope_aktualisiert"

        /// GitHub #92 (experimentell): der manuelle "Jetzt
        /// synchronisieren"-Button hat kurz einen `UIDocumentPickerViewController`
        /// auf den Sync-Ordner eingeblendet (Testidee: dieselbe
        /// File-Provider-Enumeration wie beim Öffnen in der Files-App, siehe
        /// `docs/DATENSYNCHRONISATION_VERLAUF.md` §39/42, auslösen). Unbelegt,
        /// dieses Ereignis macht im Live-Test sichtbar, ob sich danach
        /// tatsächlich etwas am Sync-Verhalten ändert.
        case iCloudPickerTriggerAusgeloest = "sync_icloud_picker_trigger_ausgeloest"

        /// GitHub #49: ``MultipeerSyncService`` hat eine `MCSession`-Verbindung
        /// zu einem Peer hergestellt/verloren — Details: `peerID.displayName`.
        case multipeerPeerVerbunden = "multipeer_peer_verbunden"
        case multipeerPeerGetrennt = "multipeer_peer_getrennt"
        /// GitHub #49: ein `SyncEvent` wurde über den Multipeer-Kanal statt
        /// über den Datei-Kanal empfangen — Alter analog ``eventEmpfangen``,
        /// zum direkten Latenzvergleich zwischen beiden Kanälen.
        case multipeerEventEmpfangen = "multipeer_event_empfangen"

        /// GitHub #49-Nachfolgefund: ``SyncOrdnerService/multipeerGruppenID(in:)``
        /// konnte weder eine vorhandene ID lesen noch sicher bestätigen, dass
        /// noch keine existiert (Zeitlimit oder Lese-/Schreibfehler beim
        /// nicht erreichbaren Sync-Ordner) — der Multipeer-Aufbau wurde für
        /// diesen Versuch übersprungen, kein Fallback auf eine geratene ID.
        case multipeerGruppenIDNichtAufloesbar = "multipeer_gruppen_id_nicht_aufloesbar"

        /// Mindest-Protokollstufe, ab der dieses Ereignis geschrieben wird
        /// (siehe ``Protokollstufe``-Typ-Doku für die Einteilungskriterien).
        var mindestStufe: Protokollstufe {
            switch self {
            case .ordnerZugriffFehlgeschlagen, .baumelndeReferenzGefunden, .eventNichtAnwendbar,
                 .peerVerworfenAltersgrenze, .eventAufgegeben, .debugModeEnabled, .debugModeDisabled,
                 .einkaufsvorgangAbschlussNichtUebernommen, .einkaufsvorgangAbschlussUebernommen,
                 .einkaufsvorgangEintragUebersprungen, .eventDateienBereinigt, .tombstonesBereinigt,
                 .ausDerZeitGefallenErkannt, .vollAbgleichEingeleitet, .multipeerGruppenIDNichtAufloesbar:
                return .fehler
            case .zyklusStart, .zyklusEnde, .eventEmpfangen, .snapshotEmpfangen, .einkaufslistenStand,
                 .snapshotGeschrieben, .iCloudBeobachterAusgeloest, .iCloudBeobachterScopeAktualisiert,
                 .iCloudPickerTriggerAusgeloest, .multipeerPeerVerbunden, .multipeerPeerGetrennt,
                 .multipeerEventEmpfangen:
                return .standard
            case .snapshotUnveraendertUebersprungen, .scopeZugriff:
                return .ausfuehrlich
            }
        }
    }

    /// Nicht `private`, damit ``SyncDebugLoggerTests`` isolierte
    /// `UserDefaults`-Instanzen mit denselben Schlüsseln befüllen kann.
    static let stufeSchluessel = "datensyncProtokollstufe"
    /// Alter, vor der Stufen-Einführung genutzter Bool-Key — nur noch für die
    /// einmalige Migration bestehender Installationen gelesen (siehe
    /// ``ermittleMigrierteStartstufe(defaults:)``).
    static let alterAktivSchluessel = "datensyncDebugModusAktiv"

    /// In-Memory-gecachter Zustand, siehe ``DatabaseDebugLogger/stufeCache``
    /// für die identische Begründung.
    nonisolated(unsafe) private static var stufeCache: Protokollstufe = ermittleMigrierteStartstufe()

    /// `defaults`-Parameter ausschließlich für ``SyncDebugLoggerTests``, um die
    /// Migrationslogik isoliert zu testen — die statische ``stufeCache``
    /// selbst wird pro Prozess nur einmal lazy initialisiert und lässt sich
    /// danach nicht erneut auslösen.
    static func ermittleMigrierteStartstufe(defaults: UserDefaults = .standard) -> Protokollstufe {
        if let gespeichert = defaults.object(forKey: stufeSchluessel) as? Int, let stufe = Protokollstufe(rawValue: gespeichert) {
            return stufe
        }
        // Migration: vor der Stufen-Einführung gab es nur „an"/„aus" — „an"
        // wird zu `.standard`, dem bisherigen tatsächlichen Verhalten
        // (Ausführlich-Ereignisse gab es damals noch nicht).
        let migriert: Protokollstufe = defaults.bool(forKey: alterAktivSchluessel) ? .standard : .aus
        defaults.set(migriert.rawValue, forKey: stufeSchluessel)
        return migriert
    }

    static var stufe: Protokollstufe {
        get { stufeCache }
        set {
            let vorher = stufeCache
            stufeCache = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: stufeSchluessel)
            guard (vorher == .aus) != (newValue == .aus) else { return }
            log(newValue == .aus ? .debugModeDisabled : .debugModeEnabled, details: "")
        }
    }

    /// Kompatibler Zugriff für Aufrufstellen, die nur „protokolliert
    /// überhaupt etwas" statt der genauen Stufe wissen müssen (z.B. um vor
    /// einer teuren Detail-Text-Bildung früh abzubrechen).
    static var istAktiv: Bool {
        get { stufeCache != .aus }
        set { stufe = newValue ? (stufeCache == .aus ? .standard : stufeCache) : .aus }
    }

    private static let writer = DebugLogWriter(
        kategorie: "Datensynchronisation",
        dateiURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sync-debug.log")
    )

    private static let wiederholungsFilter = WiederholungsFilter()

    static func log(_ ereignis: Ereignis, details: String) {
        guard stufeCache >= ereignis.mindestStufe else { return }
        guard let effektiveDetails = wiederholungsFilter.pruefe(ereignis: ereignis.rawValue, details: details) else { return }
        Task.detached(priority: .background) {
            let geraeteName = await DatabaseLeaseService.geraeteName
            await writer.protokolliere(ereignis: ereignis.rawValue, details: effektiveDetails, geraeteName: geraeteName)
        }
    }

    /// Protokolliert das Alter eines empfangenen Updates (Bereich-A-Event oder
    /// Bereich-B/C/D-Snapshot) — die Differenz zwischen jetzt und dem
    /// Erzeugungszeitpunkt auf dem Herkunftsgerät. Grundlage für die
    /// tatsächlich beobachtete Sync-Latenz (siehe Typ-Doku).
    static func protokolliereAlter(_ ereignis: Ereignis, erzeugtAm: Date, zusatz: String = "") {
        guard stufeCache >= ereignis.mindestStufe else { return }
        let alterSekunden = Date().timeIntervalSince(erzeugtAm)
        let details = zusatz.isEmpty
            ? "alter_sekunden=\(String(format: "%.1f", alterSekunden))"
            : "alter_sekunden=\(String(format: "%.1f", alterSekunden)) \(zusatz)"
        log(ereignis, details: details)
    }

    static func gesamtGroesse() -> Int {
        writer.aktuelleGroesse()
    }

    static func leeren() {
        writer.leere()
    }

    static var exportURLs: [URL] {
        writer.exportURLs
    }
}
