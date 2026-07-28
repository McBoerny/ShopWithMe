import SwiftUI
import UniformTypeIdentifiers

/// Einstellung für den geteilten Sync-Ordner (Datensynchronisation, GitHub #39).
///
/// Bewusst getrennt von ``DatabaseLocationSettingsView``: Dort wird die aktive
/// Datenbankdatei selbst verlagert (Einzelnutzer-Fall). Hier wird nur ein
/// zusätzlicher Ordner referenziert, in den eigene Änderungen als Events
/// exportiert werden (``SyncExportService``) — die lokale Datenbank bleibt
/// unangetastet am Standardpfad. Siehe
/// `docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`.
///
/// Ein erster Sync-Zyklus läuft automatisch direkt beim Verknüpfen eines
/// Ordners (Bootstrap, GitHub #39 Phase 5) — „Jetzt synchronisieren“ danach
/// weiterhin manuell auslösbar. Ein automatisches, periodisches Auslösen
/// unabhängig von Nutzerinteraktion (abhängig davon, ob z.B. gerade
/// eingekauft wird) ist erst Phase 4 des Plans („adaptives Polling“).
struct SyncOrdnerSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncPollingService: SyncPollingService

    @State private var zeigeOrdnerauswahl = false
    @State private var fehlermeldung: String?
    @State private var ausgewaehlterOrdner: URL? = SyncOrdnerService.gewaehlterOrdner()
    @State private var wirdSynchronisiert = false
    @State private var letzterSyncErfolgreich = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Sync-Ordner") {
                    Text(ausgewaehlterOrdner != nil ? "Festgelegt" : "Nicht festgelegt")
                        .foregroundStyle(.secondary)
                }
                if let ordner = ausgewaehlterOrdner {
                    Text(ordner.lastPathComponent)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Ordner wählen…") {
                    zeigeOrdnerauswahl = true
                }
                if ausgewaehlterOrdner != nil {
                    Button("Synchronisierung deaktivieren", role: .destructive) {
                        SyncOrdnerService.ordnerEntfernen()
                        ausgewaehlterOrdner = nil
                    }
                }
            } footer: {
                Text("Ein geteilter Ordner (z.B. iCloud Drive oder Synology Drive), über den mehrere Geräte ihre Einkaufslisten-Änderungen austauschen. Die lokale Datenbank bleibt dabei unverändert am Standardort.")
            }

            if ausgewaehlterOrdner != nil {
                Section {
                    Button {
                        jetztSynchronisieren()
                    } label: {
                        if wirdSynchronisiert {
                            ProgressView()
                        } else {
                            Text("Jetzt synchronisieren")
                        }
                    }
                    .disabled(wirdSynchronisiert)

                    if letzterSyncErfolgreich {
                        Label("Synchronisiert.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            if let fehlermeldung {
                Section {
                    Label(fehlermeldung, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Datensynchronisation")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $zeigeOrdnerauswahl, allowedContentTypes: [.folder]) { ergebnis in
            switch ergebnis {
            case .success(let ordner):
                ordnerFestlegen(ordner)
            case .failure(let error):
                fehlermeldung = error.localizedDescription
            }
        }
    }

    /// Legt den Ordner fest und löst sofort einen ersten Sync-Zyklus aus
    /// (GitHub #39, Phase 5 „Gruppen-Setup") — enthält bereits vorhandene
    /// Peer-Daten im gewählten Ordner, wird ihr Bestand direkt beim
    /// Verknüpfen gemergt (``SyncSnapshotImportService``), statt dass die
    /// Person erst noch manuell auf „Jetzt synchronisieren" tippen muss.
    private func ordnerFestlegen(_ ordner: URL) {
        do {
            try SyncOrdnerService.ordnerFestlegen(ordner)
            ausgewaehlterOrdner = ordner
            fehlermeldung = nil
            jetztSynchronisieren()
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }

    /// Nutzt denselben Sync-Zyklus wie ``SyncPollingService`` (statt die vier
    /// Schritte hier zu duplizieren), damit z.B. die Diagnose-Protokollierung
    /// (``SyncDebugLogger``) an einer einzigen Stelle passiert.
    private func jetztSynchronisieren() {
        letzterSyncErfolgreich = false
        wirdSynchronisiert = true
        Task {
            await syncPollingService.syncZyklus()
            wirdSynchronisiert = false
            letzterSyncErfolgreich = true
        }
    }
}

#Preview {
    NavigationStack {
        SyncOrdnerSettingsView()
    }
    .environmentObject(SyncPollingService())
}
