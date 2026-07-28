import SwiftUI

/// Einstellung für den optionalen Datensynchronisations-Debug-Modus (siehe
/// `docs/LOGGING.md`) — protokolliert lokal die beobachtete Sync-Latenz
/// (Alter empfangener Events/Snapshots), Zyklus-Dauer und Ordner-Zugriffsfehler,
/// damit die Polling-Intervalle in ``SyncPollingService`` später mit echten
/// Praxisdaten statt Annahmen nachjustiert werden können. Standardmäßig aus.
struct SyncDebugSettingsView: View {
    @State private var istAktiv = SyncDebugLogger.istAktiv
    @State private var logGroesse = SyncDebugLogger.gesamtGroesse()
    @State private var zeigeTeilen = false

    var body: some View {
        Form {
            Section {
                Toggle("Debug-Modus", isOn: $istAktiv)
                    .onChange(of: istAktiv) { _, neuerWert in
                        SyncDebugLogger.istAktiv = neuerWert
                    }
            } footer: {
                Text("Protokolliert lokal, wie alt empfangene Updates beim Eintreffen waren und wie lange ein Sync-Zyklus dauert — Grundlage, um die Sync-Intervalle später mit echten Messwerten zu optimieren. Nur für gezielte Testphasen aktivieren.")
            }

            Section {
                LabeledContent("Protokollgröße", value: logGroesse.formatted(.byteCount(style: .file)))
                Button("Protokoll teilen…") {
                    zeigeTeilen = true
                }
                .disabled(logGroesse == 0)
                Button("Protokoll leeren", role: .destructive) {
                    SyncDebugLogger.leeren()
                    logGroesse = SyncDebugLogger.gesamtGroesse()
                }
                .disabled(logGroesse == 0)
            }
        }
        .navigationTitle("Sync-Debug-Modus")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeTeilen) {
            SyncDebugLogTeilenView(urls: SyncDebugLogger.exportURLs)
        }
        .onAppear {
            logGroesse = SyncDebugLogger.gesamtGroesse()
        }
    }
}

/// UIKit-Brücke für das Teilen der Debug-Log-Dateien per Share Sheet — analog
/// zum privaten Gegenstück in `DatabaseDebugSettingsView.swift`.
private struct SyncDebugLogTeilenView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        SyncDebugSettingsView()
    }
}
