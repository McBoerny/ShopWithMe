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

/// Zeigt den Bericht des letzten (automatisch beim App-Start gelaufenen)
/// ``DatenintegritaetsService/repariereFallsNoetig(context:)`` und erlaubt eine
/// manuelle erneute Prüfung sowie das Exportieren des vollständigen,
/// dauerhaften Protokolls — Stufe 2 des mit dem Anwender abgestimmten
/// zweistufigen Vorgehens (Stufe 1: stille automatische Reparatur beim Start).
private struct DatenintegritaetSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var bericht = DatenintegritaetsService.letzterBericht
    @State private var logGroesse = DatenintegritaetsLogger.gesamtGroesse()
    @State private var zeigeTeilen = false

    var body: some View {
        Section {
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
                bericht = DatenintegritaetsService.repariereFallsNoetig(context: modelContext).map(\.beschreibung)
                logGroesse = DatenintegritaetsLogger.gesamtGroesse()
            }
            Button("Protokoll teilen…") {
                zeigeTeilen = true
            }
            .disabled(logGroesse == 0)
        } header: {
            Text("Datenintegrität")
        } footer: {
            Text("Repariert automatisch bei jedem App-Start baumelnde Referenzen auf bereits gelöschte Objekte (z.B. nach einer fehlerhaften Synchronisation) und verhindert dadurch Abstürze. Zeigt den zuletzt gefundenen Bestand — das vollständige Protokoll aller bisherigen Reparaturen lässt sich über „Protokoll teilen…“ exportieren.")
        }
        .sheet(isPresented: $zeigeTeilen) {
            DebugLogTeilenView(urls: DatenintegritaetsLogger.exportURLs)
        }
        .onAppear {
            logGroesse = DatenintegritaetsLogger.gesamtGroesse()
        }
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
}
