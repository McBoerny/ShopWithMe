import SwiftUI
import SwiftData

/// Bündelt alle Diagnose-/Debug-Einstellungen der App in einer einzigen
/// Ansicht (GitHub #53) — zuvor auf drei getrennte Bildschirme verteilt
/// (Sync-Debug-Modus, DB-Debug-Modus, Debug-Einstellungen).
struct DebuggingView: View {
    @State private var syncStufe = SyncDebugLogger.stufe
    @State private var dbStufe = DatabaseDebugLogger.stufe
    @State private var gesamtGroesse = SyncDebugLogger.gesamtGroesse() + DatabaseDebugLogger.gesamtGroesse()
    @State private var zeigeTeilen = false

    var body: some View {
        Form {
            // GitHub #84: Sync- und DB-Debug-Modus zu einem Setting mit zwei
            // Unteroptionen verschmolzen (zuvor zwei fast identische Sektionen
            // mit je eigenem Protokollgröße-/Teilen-/Leeren-Block).
            //
            // Drei Stufen statt eines einfachen An/Aus (2026-08-02, nach
            // einem Live-Fund mit 1065 identischen Fehlerzeilen aus einer
            // einzigen anhaltenden Störung sowie ca. 60% reinem
            // "unverändert"-Rauschen im Normalbetrieb): „Fehler" für eine
            // ruhige Dauerüberwachung, „Standard" für die bisherige normale
            // Zyklus-Aktivität, „Ausführlich" nur für eine gezielte
            // Tiefenanalyse (z.B. die Security-Scope-Zugriffsdiagnose).
            Section {
                Picker("Sync-Protokoll", selection: $syncStufe) {
                    ForEach(Protokollstufe.allCases, id: \.self) { stufe in
                        Text(stufe.anzeigename).tag(stufe)
                    }
                }
                .onChange(of: syncStufe) { _, neueStufe in
                    SyncDebugLogger.stufe = neueStufe
                }
                Picker("Datenbank-Protokoll", selection: $dbStufe) {
                    ForEach(Protokollstufe.allCases, id: \.self) { stufe in
                        Text(stufe.anzeigename).tag(stufe)
                    }
                }
                .onChange(of: dbStufe) { _, neueStufe in
                    DatabaseDebugLogger.stufe = neueStufe
                }
                LabeledContent("Protokollgröße", value: gesamtGroesse.formatted(.byteCount(style: .file)))
                Button("Protokoll teilen…") {
                    zeigeTeilen = true
                }
                .disabled(gesamtGroesse == 0)
                Button("Protokoll leeren", role: .destructive) {
                    SyncDebugLogger.leeren()
                    DatabaseDebugLogger.leeren()
                    aktualisiereGesamtGroesse()
                }
                .disabled(gesamtGroesse == 0)
            } header: {
                Text("Debug-Modus")
            } footer: {
                Text("Sync-Protokoll: wie alt empfangene Updates beim Eintreffen waren und wie lange ein Sync-Zyklus dauert. Datenbank-Protokoll: Probleme rund um den Mehrbenutzerzugriff (Sperren, Öffnen, Speichern). „Fehler“: nur Störungen und seltene bedeutsame Ereignisse. „Standard“: zusätzlich die normale Zyklus-Aktivität. „Ausführlich“: zusätzlich hochfrequente Detail-Ereignisse (u.a. je Sync-Teilbereich eine „unverändert“-Zeile, sowie eine Security-Ordnerzugriffs-Diagnose) — nur für eine gezielte Tiefenanalyse einschalten, nicht dauerhaft. Beide Protokolle nur lokal auf diesem Gerät, nicht geteilt.")
            }

            MultipeerStatusSection()

            BekannteSyncPeersSection()

            StatuskonsolidierungSection()

            DatenintegritaetSection()

            ModellIDDuplikatSection()

            #if DEBUG
            SuchradiusUeberschreibungSection()
            #endif
        }
        .navigationTitle("Debugging")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeTeilen) {
            DebugLogTeilenView(urls: SyncDebugLogger.exportURLs + DatabaseDebugLogger.exportURLs)
        }
        .onAppear {
            aktualisiereGesamtGroesse()
        }
    }

    private func aktualisiereGesamtGroesse() {
        gesamtGroesse = SyncDebugLogger.gesamtGroesse() + DatabaseDebugLogger.gesamtGroesse()
    }
}

#if DEBUG
/// Nur in Debug-Builds sichtbar: erlaubt es, den Suchradius der
/// Standort-basierten Ladenerkennung (``GeschaeftErkennungService``) testweise
/// zu erhöhen, um sie ohne echte Nähe zu einem Apple-Maps-Laden auszuprobieren.
/// Betrifft sowohl den automatischen Einzelvorschlag als auch „Alle Geschäfte
/// in der Nähe“. Ist die Überschreibung aus, gelten die festen Standardwerte
/// (``GeschaeftErkennungService/standardSuchradius``/
/// ``GeschaeftErkennungService/standardAlleInDerNaeheRadius``).
private struct SuchradiusUeberschreibungSection: View {
    @State private var ueberschreibungAktiv: Bool
    @State private var radius: Double

    init() {
        let vorhandeneUeberschreibung = DebugEinstellungen.sucheRadiusUeberschreibung
        _ueberschreibungAktiv = State(initialValue: vorhandeneUeberschreibung != nil)
        _radius = State(initialValue: vorhandeneUeberschreibung ?? GeschaeftErkennungService.standardSuchradius)
    }

    var body: some View {
        Section {
            Toggle("Suchradius überschreiben", isOn: $ueberschreibungAktiv)
                .onChange(of: ueberschreibungAktiv) { _, _ in speichern() }

            if ueberschreibungAktiv {
                Stepper("\(Int(radius)) m", value: $radius, in: 100...5000, step: 50)
                    .onChange(of: radius) { _, _ in speichern() }
            }
        } header: {
            Text("Standort-Suchradius")
        } footer: {
            Text("Nur in Debug-Builds sichtbar. Erhöht testweise den Suchradius der Standort-basierten Ladenerkennung (automatischer Vorschlag und „Alle Geschäfte in der Nähe“), um sie ohne echte Nähe zu einem Apple-Maps-Laden zu testen. Ohne Überschreibung gelten die Standardwerte (\(Int(GeschaeftErkennungService.standardSuchradius))m bzw. \(Int(GeschaeftErkennungService.standardAlleInDerNaeheRadius))m).")
        }
    }

    private func speichern() {
        DebugEinstellungen.sucheRadiusUeberschreibung = ueberschreibungAktiv ? radius : nil
    }
}
#endif

/// Zeigt, ob der zusätzliche Multipeer-Beschleunigungskanal (GitHub #49,
/// ``MultipeerSyncService``) gerade läuft und mit wem verbunden ist — bislang
/// nirgends für den Anwender sichtbar, obwohl der Kanal seit GitHub #49
/// existiert. ``MultipeerSyncService/aktiv`` wird normalerweise von
/// `EinkaufenView` gesetzt (nur während des Einkaufens); der Debug-Schalter
/// unten überschreibt das testweise, wird aber beim nächsten Betreten/
/// Verlassen des Einkaufen-Bildschirms wieder auf dessen eigenen Zustand
/// zurückgesetzt.
private struct MultipeerStatusSection: View {
    @EnvironmentObject private var multipeerSyncService: MultipeerSyncService

    var body: some View {
        Section {
            if !multipeerSyncService.aktiv {
                Label("Inaktiv — läuft nur während des Einkaufens", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            } else if multipeerSyncService.verbundenePeerNamen.isEmpty {
                Label("Sucht nach Geräten in der Nähe…", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("Verbunden: \(multipeerSyncService.verbundenePeerNamen.joined(separator: ", "))", systemImage: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.green)
            }
            #if DEBUG
            Toggle("Multipeer erzwingen", isOn: $multipeerSyncService.aktiv)
            #endif
        } header: {
            Text("Multipeer-Kanal")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        var text = "Zusätzlicher, rein beschleunigender Sync-Kanal über lokales WLAN/Bluetooth (GitHub #49) — läuft nur, solange gemeinsam eingekauft wird. Der geteilte Sync-Ordner bleibt davon unabhängig die eigentliche Quelle der Wahrheit."
        #if DEBUG
        text += " „Multipeer erzwingen“ startet/stoppt den Kanal testweise unabhängig vom Einkaufen-Bildschirm — wird beim nächsten Betreten/Verlassen dieses Bildschirms wieder überschrieben."
        #endif
        return text
    }
}

/// Listet alle jemals per Sync gesehenen Peer-Geräte (``SyncPeerInfo``) mit
/// Zuletzt-gesehen-Zeitpunkt — Gegenstück zur automatischen Altersgrenze in
/// ``SyncSnapshotImportService/maximalesSnapshotAlter`` (GitHub #52-Nachfolgefund):
/// Geräte, die die App nicht mehr nutzen (z.B. nach einer Neuinstallation mit
/// neuer Geräte-ID), lassen sich hier manuell entfernen — löscht sowohl den
/// lokalen Merkposten als auch den Peer-Ordner im Sync-Ordner selbst, damit
/// sein letzter bekannter Stand nicht mehr zurückgespielt wird.
private struct BekannteSyncPeersSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SyncPeerInfo.geraeteName) private var peers: [SyncPeerInfo]

    var body: some View {
        if !peers.isEmpty {
            Section {
                ForEach(peers) { peer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.geraeteName)
                        Text("Zuletzt gesehen: \(peer.zuletztGesehen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: peerEntfernen)
            } header: {
                Text("Bekannte Geräte")
            } footer: {
                Text("Wischen zum Entfernen — für Geräte, die die App nicht mehr nutzen. Verhindert, dass ihr letzter bekannter Stand weiterhin zurückgespielt wird.")
            }
        }
    }

    private func peerEntfernen(at offsets: IndexSet) {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else {
            for index in offsets { modelContext.delete(peers[index]) }
            return
        }
        let entfernte = offsets.map { peers[$0] }
        Task {
            for peer in entfernte {
                await SyncOrdnerService.entfernePeer(peer, in: syncOrdner, context: modelContext)
            }
        }
    }
}

/// Manuelle Statuskonsolidierung für Live-Tests, bei denen die automatische
/// Konvergenz (48h-Give-up-Frist für nicht anwendbare Events,
/// Fingerabdruck-basiertes Skip-Verhalten des eigenen Exports, 30-Tage-
/// Altersgrenze für fremde Exports) zu lange dauern würde, um sie im Test
/// abzuwarten — hier sofort auslösbar. Beide Werkzeuge rühren bewusst nicht
/// an den eigenen, noch nicht abgeholten ausgehenden Event-Dateien (siehe
/// Revert-Begründung in ``SyncExportService``, „Kein Aufräumen alter
/// Event-Dateien").
private struct StatuskonsolidierungSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var wirdAusgefuehrt = false
    @State private var meldung: String?

    var body: some View {
        if SyncOrdnerService.gewaehlterOrdner() != nil {
            Section {
                Button("Events aufräumen") {
                    fuehreAus("Events aufgeräumt.") {
                        await SyncImportService.raeumeNichtAnwendbareEventsAuf(context: modelContext)
                    }
                }
                .disabled(wirdAusgefuehrt)

                Button("Sync-Paket aufräumen") {
                    fuehreAus("Sync-Paket aufgeräumt.") {
                        await SyncSnapshotExportService.erzwingeFrischesPaket(context: modelContext)
                        await SyncKaeufeExportService.exportiereNeueKaeufe(context: modelContext)
                        await SyncSnapshotImportService.raeumeVerwaisteFremdeExportsAuf()
                    }
                }
                .disabled(wirdAusgefuehrt)

                // Ruft `bereinigen(context:)` bewusst DIREKT auf, nicht über
                // `automatischBereinigenFallsFaellig` — Letzteres würde durch
                // dessen 24h-Sperre (`KaufEintragBereinigungService.automatischesIntervall`)
                // einen bereits heute gelaufenen automatischen Durchlauf erneut
                // überspringen, obwohl der Anwender hier ausdrücklich SOFORT einen
                // neuen Lauf auslösen will (z.B. um einen frisch behobenen Bug wie
                // in `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 27 sofort zu
                // verifizieren, statt bis zum nächsten automatischen Zeitpunkt zu
                // warten). Lässt `letzteBereinigung` bewusst unangetastet — rein
                // additiv zur automatischen Terminierung, nicht deren Ersatz.
                Button("KaufEintraege jetzt bereinigen") {
                    meldung = nil
                    wirdAusgefuehrt = true
                    Task {
                        let anzahl = await KaufEintragBereinigungService.bereinigen(context: modelContext)
                        wirdAusgefuehrt = false
                        meldung = anzahl == 0
                            ? "Keine abgelaufenen oder verwaisten KaufEintraege gefunden."
                            : "\(anzahl) KaufEintrag\(anzahl == 1 ? "" : "e") bereinigt."
                    }
                }
                .disabled(wirdAusgefuehrt)

                if wirdAusgefuehrt {
                    ProgressView()
                } else if let meldung {
                    Text(meldung)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Statuskonsolidierung erzwingen")
            } footer: {
                Text("„Events aufräumen“ gibt aktuell nicht anwendbare empfangene Events sofort auf, statt die automatische 48h-Frist abzuwarten. „Sync-Paket aufräumen“ erzwingt ein frisches eigenes Paket (Stammdaten/Lernen/Vorgänge/Preise/Tombstones sowie die Kaufhistorie) und löscht verwaiste Paket-Dateien von Peers, die die 30-Tage-Altersgrenze überschritten haben. „KaufEintraege jetzt bereinigen“ löst die sonst höchstens einmal täglich automatisch laufende Bereinigung abgeschlossener und verwaister KaufEintraege sofort aus.")
            }
        }
    }

    private func fuehreAus(_ erfolgsmeldung: String, _ aktion: @escaping () async -> Void) {
        meldung = nil
        wirdAusgefuehrt = true
        Task {
            await aktion()
            wirdAusgefuehrt = false
            meldung = erfolgsmeldung
        }
    }
}

/// Zeigt den Bericht der letzten (automatisch beim App-Start gelaufenen)
/// ``DatenintegritaetsService/pruefe(context:)`` und erlaubt eine manuelle
/// erneute Prüfung sowie das Exportieren des vollständigen, dauerhaften
/// Protokolls. Rein informativ — siehe Typ-Dokumentation von
/// ``DatenintegritaetsService``, warum eine automatische Reparatur baumelnder
/// Referenzen über die normale SwiftData-API selbst zum Absturz führen kann.
private struct DatenintegritaetSection: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncPollingService: SyncPollingService
    @EnvironmentObject private var multipeerSyncService: MultipeerSyncService
    @State private var bericht = DatenintegritaetsService.letzterBericht
    @State private var logGroesse = DatenintegritaetsLogger.gesamtGroesse()
    @State private var zeigeTeilen = false
    @State private var zeigeResetBestaetigung = false
    @State private var zeigeBereinigungBestaetigung = false
    @State private var zeigeNeustartHinweis = false
    @State private var resetFehlermeldung: String?
    @State private var neuaufbauZusammenfassung = SyncErsetzenService.letzteNeuaufbauZusammenfassung
    @State private var neuaufbauAutomatischZurueckgerollt = SyncErsetzenService.letzterNeuaufbauAutomatischZurueckgerollt

    var body: some View {
        Section {
            if let neuaufbauZusammenfassung {
                if neuaufbauAutomatischZurueckgerollt {
                    Label("Neuaufbau fehlgeschlagen (leeres Ergebnis oder Ordnerzugriff gescheitert) — automatisch auf den vorherigen Stand zurückgesetzt.", systemImage: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.red)
                }
                NeuaufbauZusammenfassungView(zusammenfassung: neuaufbauZusammenfassung)
                Button("Zusammenfassung ausblenden") {
                    SyncErsetzenService.zusammenfassungVerwerfen()
                    self.neuaufbauZusammenfassung = nil
                    self.neuaufbauAutomatischZurueckgerollt = false
                }
            }
            if bericht.isEmpty {
                Text("Beim letzten Start keine baumelnden Referenzen gefunden.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(bericht.enumerated()), id: \.offset) { _, zeile in
                    Text(zeile)
                        .font(.caption)
                }
            }
            Button("Jetzt erneut prüfen") {
                bericht = DatenintegritaetsService.pruefe(context: modelContext).map(\.beschreibung)
                logGroesse = DatenintegritaetsLogger.gesamtGroesse()
            }
            Button("Protokoll teilen…") {
                zeigeTeilen = true
            }
            .disabled(logGroesse == 0)

            // Korruptions-Recovery (siehe ``SyncErsetzenService``): eine
            // automatische Reparatur ist über SwiftData nicht sicher möglich
            // (siehe Footer/Typ-Doku von ``DatenintegritaetsService``) — dies
            // ist die einzige verbleibende Abhilfe, sofern ein erreichbares
            // Sync-Gerät existiert, aus dem sich der Bestand neu aufbauen lässt.
            Button("Gerät zurücksetzen und von Sync-Gerät neu aufbauen…", role: .destructive) {
                zeigeResetBestaetigung = true
            }
            .disabled(SyncOrdnerService.gewaehlterOrdner() == nil)

            // Alternative ohne Sync-Gerät: ein frischer Snapshot des eigenen
            // (ggf. korrupten) Bestands ist bereits „repariert", da
            // erstelleSnapshot baumelnde Referenzen ohnehin ausfiltert (siehe
            // ``SyncErsetzenService/planeBereinigungBaumelnderReferenzen(context:)``)
            // — nur sinnvoll anzubieten, wenn oben tatsächlich etwas gemeldet wurde.
            if !bericht.isEmpty {
                Button("Baumelnde Referenzen bereinigen (ohne Sync-Gerät)…", role: .destructive) {
                    zeigeBereinigungBestaetigung = true
                }
            }

            if let resetFehlermeldung {
                Label(resetFehlermeldung, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Datenintegrität")
        } footer: {
            Text("Zeigt bei jedem App-Start erkannte baumelnde Referenzen auf bereits gelöschte Objekte sowie Einkaufsvorgänge ohne Einkaufsliste, die dadurch für die App unerreichbar sind (z.B. nach einer fehlerhaften Synchronisation) — rein informativ, ohne selbst etwas zu reparieren. Das vollständige Protokoll lässt sich über „Protokoll teilen…“ exportieren. „Gerät zurücksetzen“ sichert den aktuellen Bestand lokal und baut die Datenbank anschließend ausschließlich aus dem Stand eines erreichbaren Sync-Geräts neu auf — setzt eine aktive Datensynchronisation mit mindestens einem erreichbaren Gerät voraus. Schlägt der Neuaufbau eindeutig fehl (kein Ordnerzugriff oder komplett leeres Ergebnis), wird automatisch auf den vorherigen, gesicherten Stand zurückgesetzt, statt einen leeren Bestand zu übernehmen. „Baumelnde Referenzen bereinigen“ macht dasselbe ohne Sync-Gerät, aus einem frisch erstellten Snapshot des eigenen Bestands.")
        }
        .sheet(isPresented: $zeigeTeilen) {
            DebugLogTeilenView(urls: DatenintegritaetsLogger.exportURLs)
        }
        .onAppear {
            logGroesse = DatenintegritaetsLogger.gesamtGroesse()
            neuaufbauZusammenfassung = SyncErsetzenService.letzteNeuaufbauZusammenfassung
            neuaufbauAutomatischZurueckgerollt = SyncErsetzenService.letzterNeuaufbauAutomatischZurueckgerollt
        }
        .confirmationDialog("Gerät zurücksetzen", isPresented: $zeigeResetBestaetigung, titleVisibility: .visible) {
            Button("Zurücksetzen und neu aufbauen", role: .destructive) {
                zuruecksetzen()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Sichert den aktuellen Bestand lokal und merkt den Neuaufbau aus einem erreichbaren Sync-Gerät für den nächsten App-Start vor — dafür muss die App danach einmal neu gestartet werden. Nicht rückgängig zu machen, außer über die Wiederherstellung bei „Synchronisierung deaktivieren“.")
        }
        .confirmationDialog("Baumelnde Referenzen bereinigen", isPresented: $zeigeBereinigungBestaetigung, titleVisibility: .visible) {
            Button("Bereinigen und neu aufbauen", role: .destructive) {
                bereinigen()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Erstellt jetzt einen frischen Snapshot des eigenen Bestands und baut die Datenbank ausschließlich daraus neu auf — dafür muss die App danach einmal neu gestartet werden. Funktioniert ohne Sync-Gerät. Alle gültigen Daten bleiben erhalten, nur baumelnde Bezüge (siehe Bericht oben) werden dabei automatisch aufgelöst statt übernommen.")
        }
        .alert("Neustart nötig", isPresented: $zeigeNeustartHinweis) {
            Button("OK") {}
        } message: {
            Text("Bitte schließe die App jetzt vollständig (nicht nur in den Hintergrund legen) und öffne sie erneut, um den Vorgang abzuschließen.")
        }
    }

    /// Merkt den Neuaufbau nur für den nächsten App-Start vor (siehe Typ-Doku
    /// von ``SyncErsetzenService``, warum ein sofortiger Austausch zur
    /// Laufzeit auf einem echten Gerät abstürzte) — verändert selbst noch
    /// nichts am Datenbestand.
    private func zuruecksetzen() {
        resetFehlermeldung = nil
        do {
            try SyncErsetzenService.planeErsetzenDurchPeer(context: modelContext)
            neustartAusstehendMachen()
        } catch {
            resetFehlermeldung = error.localizedDescription
        }
    }

    /// Stoppt den Hintergrund-Sync sofort statt erst beim Neustart — siehe
    /// ``SyncOrdnerSettingsView/neustartAusstehendMachen()`` für die
    /// ausführliche Begründung (gleiche Race Condition, gleicher Mechanismus).
    private func neustartAusstehendMachen() {
        syncPollingService.stoppen()
        multipeerSyncService.stoppen()
        zeigeNeustartHinweis = true
    }

    /// Merkt den Neuaufbau aus einem JETZT erstellten Snapshot des eigenen
    /// Bestands vor (siehe ``SyncErsetzenService/planeBereinigungBaumelnderReferenzen(context:)``)
    /// — verändert selbst noch nichts am Datenbestand.
    private func bereinigen() {
        resetFehlermeldung = nil
        do {
            try SyncErsetzenService.planeBereinigungBaumelnderReferenzen(context: modelContext)
            neustartAusstehendMachen()
        } catch {
            resetFehlermeldung = error.localizedDescription
        }
    }
}

/// Manuell auslösbare Diagnose für GitHub #102: prüft, ob bereits doppelte
/// `id`-Werte innerhalb eines `@Model`-Typs existieren — Voraussetzung dafür,
/// `@Attribute(.unique)` auf den app-eigenen `id`-Feldern sicher einführen zu
/// können (eine Unique-Constraint-Migration würde bei bestehenden Duplikaten
/// fehlschlagen). Zeigt bewusst nur Typname und Anzahl, nie die betroffenen
/// IDs oder Inhalte selbst (siehe ``ModellIDDuplikatService``).
private struct ModellIDDuplikatSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var wurdeGeprueft = false
    @State private var befunde: [ModellIDDuplikatService.Befund] = []

    var body: some View {
        Section {
            if wurdeGeprueft {
                if befunde.isEmpty {
                    Text("Keine doppelten IDs gefunden.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(befunde) { befund in
                        Text(befund.beschreibung)
                            .font(.caption)
                    }
                }
            }
            Button("Auf doppelte Modell-IDs prüfen") {
                befunde = ModellIDDuplikatService.pruefe(context: modelContext)
                wurdeGeprueft = true
            }
        } header: {
            Text("Modell-ID-Duplikate (GitHub #102)")
        } footer: {
            Text("Prüft, ob innerhalb eines Datentyps (Artikel, Geschäft, …) bereits dieselbe ID mehrfach vergeben wurde — Voraussetzung, um künftig eindeutige IDs technisch zu erzwingen. Zeigt nur Typname und Anzahl, keine Inhalte.")
        }
    }
}

/// Vorher-/Nachher-Mengenvergleich eines „Ersetzen durch Peer"-Neuaufbaus
/// (``SyncErsetzenService/NeuaufbauZusammenfassung``, Abschnitt 21) — zeigt
/// jeden Bereich nur, wenn sich seine Anzahl tatsächlich geändert hat, damit
/// bei einer sauberen Zusammenführung nicht acht identische „±0"-Zeilen den
/// eigentlich interessanten Rückgang überdecken. Ein Rückgang ist rot
/// hervorgehoben — genau das Signal, das beim auslösenden Live-Test-Fund
/// (3 statt 2 Einkaufslisten nach einem Neuaufbau) gefehlt hat.
private struct NeuaufbauZusammenfassungView: View {
    let zusammenfassung: SyncErsetzenService.NeuaufbauZusammenfassung

    private var zeilen: [(name: String, vorher: Int, nachher: Int)] {
        let v = zusammenfassung.vorher
        let n = zusammenfassung.nachher
        return [
            ("Geschäftstypen", v.geschaeftsTypen, n.geschaeftsTypen),
            ("Abteilungen", v.artikelKategorien, n.artikelKategorien),
            ("Geschäfte", v.geschaefte, n.geschaefte),
            ("Artikel", v.artikel, n.artikel),
            ("Einkaufslisten", v.einkaufslisten, n.einkaufslisten),
            ("Einkaufsvorgänge", v.einkaufsvorgaenge, n.einkaufsvorgaenge),
            ("Käufe", v.kaufEintraege, n.kaufEintraege),
            ("Abteilungs-Distanzen", v.warengruppenDistanzen, n.warengruppenDistanzen),
        ].filter { $0.vorher != $0.nachher }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Letzter Neuaufbau: \(zusammenfassung.zeitpunkt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .bold()
            if zeilen.isEmpty {
                Text("Alle Bereiche unverändert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(zeilen, id: \.name) { zeile in
                    let delta = zeile.nachher - zeile.vorher
                    Text("\(zeile.name): \(zeile.vorher) → \(zeile.nachher) (\(delta > 0 ? "+" : "")\(delta))")
                        .font(.caption)
                        .foregroundStyle(delta < 0 ? .red : .secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// UIKit-Brücke für das Teilen der Debug-Log-Dateien per Share Sheet — von
/// beiden Debug-Modi in dieser Ansicht gemeinsam genutzt.
private struct DebugLogTeilenView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        DebuggingView()
    }
    .environmentObject(SyncPollingService())
    .environmentObject(MultipeerSyncService())
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
