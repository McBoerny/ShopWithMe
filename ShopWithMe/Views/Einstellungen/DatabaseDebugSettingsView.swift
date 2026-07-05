import SwiftUI

/// Einstellung für den optionalen DB-Debug-Modus (siehe `docs/LOGGING.md`) —
/// protokolliert Probleme rund um den Mehrbenutzerzugriff auf die Datenbank (Sync,
/// Sperren, Öffnen, Speichern) lokal und zusätzlich im gemeinsamen Datenbank-Ordner,
/// damit sie nach einem Live-Test mit mehreren Geräten ausgewertet werden können.
/// Standardmäßig aus.
struct DatabaseDebugSettingsView: View {
    @State private var istAktiv = DatabaseDebugLogger.istAktiv
    @State private var logGroesse = DatabaseDebugLogger.gesamtGroesse()
    @State private var zeigeTeilen = false

    var body: some View {
        Form {
            Section {
                Toggle("Debug-Modus", isOn: $istAktiv)
                    .onChange(of: istAktiv) { _, neuerWert in
                        DatabaseDebugLogger.istAktiv = neuerWert
                    }
            } footer: {
                Text("Protokolliert Probleme rund um den Mehrbenutzerzugriff auf die Datenbank (Sync, Sperren, Öffnen, Speichern) lokal und zusätzlich im gemeinsamen Datenbank-Ordner, falls einer gewählt ist. Nur für gezielte Testphasen aktivieren.")
            }

            Section {
                LabeledContent("Protokollgröße", value: logGroesse.formatted(.byteCount(style: .file)))
                Button("Protokoll teilen…") {
                    zeigeTeilen = true
                }
                .disabled(logGroesse == 0)
                Button("Protokoll leeren", role: .destructive) {
                    DatabaseDebugLogger.leeren()
                    logGroesse = DatabaseDebugLogger.gesamtGroesse()
                }
                .disabled(logGroesse == 0)
            }
        }
        .navigationTitle("DB-Debug-Modus")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeTeilen) {
            DebugLogTeilenView(urls: DatabaseDebugLogger.exportURLs)
        }
        .onAppear {
            logGroesse = DatabaseDebugLogger.gesamtGroesse()
        }
    }
}

/// UIKit-Brücke für das Teilen der Debug-Log-Dateien per Share Sheet.
private struct DebugLogTeilenView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        DatabaseDebugSettingsView()
    }
}
