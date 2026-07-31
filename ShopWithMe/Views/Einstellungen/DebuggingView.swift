import SwiftUI
import SwiftData

/// Bündelt alle Diagnose-/Debug-Einstellungen der App in einer einzigen
/// Ansicht (GitHub #53) — zuvor auf drei getrennte Bildschirme verteilt
/// (Sync-Debug-Modus, DB-Debug-Modus, Debug-Einstellungen).
struct DebuggingView: View {
    @State private var syncDebugAktiv = SyncDebugLogger.istAktiv
    @State private var syncLogGroesse = SyncDebugLogger.gesamtGroesse()
    @State private var zeigeSyncTeilen = false

    @State private var dbDebugAktiv = DatabaseDebugLogger.istAktiv
    @State private var dbLogGroesse = DatabaseDebugLogger.gesamtGroesse()
    @State private var zeigeDbTeilen = false

    var body: some View {
        Form {
            Section {
                Toggle("Debug-Modus", isOn: $syncDebugAktiv)
                    .onChange(of: syncDebugAktiv) { _, neuerWert in
                        SyncDebugLogger.istAktiv = neuerWert
                    }
                LabeledContent("Protokollgröße", value: syncLogGroesse.formatted(.byteCount(style: .file)))
                Button("Protokoll teilen…") {
                    zeigeSyncTeilen = true
                }
                .disabled(syncLogGroesse == 0)
                Button("Protokoll leeren", role: .destructive) {
                    SyncDebugLogger.leeren()
                    syncLogGroesse = SyncDebugLogger.gesamtGroesse()
                }
                .disabled(syncLogGroesse == 0)
            } header: {
                Text("Sync-Debug-Modus")
            } footer: {
                Text("Protokolliert lokal, wie alt empfangene Updates beim Eintreffen waren und wie lange ein Sync-Zyklus dauert — Grundlage, um die Sync-Intervalle später mit echten Messwerten zu optimieren. Nur für gezielte Testphasen aktivieren.")
            }

            Section {
                Toggle("Debug-Modus", isOn: $dbDebugAktiv)
                    .onChange(of: dbDebugAktiv) { _, neuerWert in
                        DatabaseDebugLogger.istAktiv = neuerWert
                    }
                LabeledContent("Protokollgröße", value: dbLogGroesse.formatted(.byteCount(style: .file)))
                Button("Protokoll teilen…") {
                    zeigeDbTeilen = true
                }
                .disabled(dbLogGroesse == 0)
                Button("Protokoll leeren", role: .destructive) {
                    DatabaseDebugLogger.leeren()
                    dbLogGroesse = DatabaseDebugLogger.gesamtGroesse()
                }
                .disabled(dbLogGroesse == 0)
            } header: {
                Text("DB-Debug-Modus")
            } footer: {
                Text("Protokolliert Probleme rund um den Mehrbenutzerzugriff auf die Datenbank (Sync, Sperren, Öffnen, Speichern) lokal und zusätzlich im gemeinsamen Datenbank-Ordner, falls einer gewählt ist. Nur für gezielte Testphasen aktivieren.")
            }

            BekannteSyncPeersSection()

            StatuskonsolidierungSection()

            DatenintegritaetSection()

            #if DEBUG
            SuchradiusUeberschreibungSection()
            #endif
        }
        .navigationTitle("Debugging")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeSyncTeilen) {
            DebugLogTeilenView(urls: SyncDebugLogger.exportURLs)
        }
        .sheet(isPresented: $zeigeDbTeilen) {
            DebugLogTeilenView(urls: DatabaseDebugLogger.exportURLs)
        }
        .onAppear {
            syncLogGroesse = SyncDebugLogger.gesamtGroesse()
            dbLogGroesse = DatabaseDebugLogger.gesamtGroesse()
        }
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
        let syncOrdner = SyncOrdnerService.gewaehlterOrdner()
        for index in offsets {
            let peer = peers[index]
            if let syncOrdner, syncOrdner.startAccessingSecurityScopedResource() {
                let peerOrdner = syncOrdner
                    .appendingPathComponent("peers", isDirectory: true)
                    .appendingPathComponent(peer.peerGeraeteID, isDirectory: true)
                try? FileManager.default.removeItem(at: peerOrdner)
                syncOrdner.stopAccessingSecurityScopedResource()
            }
            modelContext.delete(peer)
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

                Button("Export.json aufräumen") {
                    fuehreAus("Export.json aufgeräumt.") {
                        await SyncSnapshotExportService.erzwingeFrischenExport(context: modelContext)
                        await SyncSnapshotImportService.raeumeVerwaisteFremdeExportsAuf()
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
                Text("„Events aufräumen“ gibt aktuell nicht anwendbare empfangene Events sofort auf, statt die automatische 48h-Frist abzuwarten. „Export.json aufräumen“ erzwingt einen frischen eigenen Export und löscht verwaiste export.json-Dateien von Peers, die die 30-Tage-Altersgrenze überschritten haben.")
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
    @State private var bericht = DatenintegritaetsService.letzterBericht
    @State private var logGroesse = DatenintegritaetsLogger.gesamtGroesse()
    @State private var zeigeTeilen = false
    @State private var zeigeResetBestaetigung = false
    @State private var zeigeNeustartHinweis = false
    @State private var resetFehlermeldung: String?
    @State private var neuaufbauZusammenfassung = SyncErsetzenService.letzteNeuaufbauZusammenfassung

    var body: some View {
        Section {
            if let neuaufbauZusammenfassung {
                NeuaufbauZusammenfassungView(zusammenfassung: neuaufbauZusammenfassung)
                Button("Zusammenfassung ausblenden") {
                    SyncErsetzenService.zusammenfassungVerwerfen()
                    self.neuaufbauZusammenfassung = nil
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

            if let resetFehlermeldung {
                Label(resetFehlermeldung, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Datenintegrität")
        } footer: {
            Text("Zeigt bei jedem App-Start erkannte baumelnde Referenzen auf bereits gelöschte Objekte sowie Einkaufsvorgänge ohne Einkaufsliste, die dadurch für die App unerreichbar sind (z.B. nach einer fehlerhaften Synchronisation) — rein informativ, keine automatische Reparatur. Das vollständige Protokoll lässt sich über „Protokoll teilen…“ exportieren. „Gerät zurücksetzen“ sichert den aktuellen Bestand lokal und baut die Datenbank anschließend ausschließlich aus dem Stand eines erreichbaren Sync-Geräts neu auf — setzt eine aktive Datensynchronisation mit mindestens einem erreichbaren Gerät voraus.")
        }
        .sheet(isPresented: $zeigeTeilen) {
            DebugLogTeilenView(urls: DatenintegritaetsLogger.exportURLs)
        }
        .onAppear {
            logGroesse = DatenintegritaetsLogger.gesamtGroesse()
            neuaufbauZusammenfassung = SyncErsetzenService.letzteNeuaufbauZusammenfassung
        }
        .confirmationDialog("Gerät zurücksetzen", isPresented: $zeigeResetBestaetigung, titleVisibility: .visible) {
            Button("Zurücksetzen und neu aufbauen", role: .destructive) {
                zuruecksetzen()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Sichert den aktuellen Bestand lokal und merkt den Neuaufbau aus einem erreichbaren Sync-Gerät für den nächsten App-Start vor — dafür muss die App danach einmal neu gestartet werden. Nicht rückgängig zu machen, außer über die Wiederherstellung bei „Synchronisierung deaktivieren“.")
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
            zeigeNeustartHinweis = true
        } catch {
            resetFehlermeldung = error.localizedDescription
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
            ("Kategorien", v.artikelKategorien, n.artikelKategorien),
            ("Geschäfte", v.geschaefte, n.geschaefte),
            ("Artikel", v.artikel, n.artikel),
            ("Einkaufslisten", v.einkaufslisten, n.einkaufslisten),
            ("Einkaufsvorgänge", v.einkaufsvorgaenge, n.einkaufsvorgaenge),
            ("Käufe", v.kaufEintraege, n.kaufEintraege),
            ("Warengruppen-Distanzen", v.warengruppenDistanzen, n.warengruppenDistanzen),
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
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
