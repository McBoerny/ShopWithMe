import SwiftUI
import SwiftData
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
    @EnvironmentObject private var containerController: ModelContainerController

    @State private var zeigeOrdnerauswahl = false
    @State private var fehlermeldung: String?
    @State private var ausgewaehlterOrdner: URL? = SyncOrdnerService.gewaehlterOrdner()
    @State private var wirdSynchronisiert = false
    @State private var letzterSyncErfolgreich = false

    @State private var zeigeBeitrittsWahl = false
    @State private var zeigeAustrittsWahl = false

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
                        deaktivierenGetappt()
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
        // GitHub #63: Alternative zum automatischen Zusammenführen, falls der
        // gewählte Ordner bereits Daten anderer Geräte enthält — z.B. für
        // private Kaufhistorie, die nicht additiv in eine geteilte
        // Gruppen-Historie einfließen soll (siehe ``SyncErsetzenService``).
        .confirmationDialog("Bestehende Daten gefunden", isPresented: $zeigeBeitrittsWahl) {
            Button("Zusammenführen") {
                jetztSynchronisieren()
            }
            Button("Ersetzen", role: .destructive) {
                ersetzenGetappt()
            }
            Button("Abbrechen", role: .cancel) {
                SyncOrdnerService.ordnerEntfernen()
                ausgewaehlterOrdner = nil
            }
        } message: {
            Text("In diesem Ordner sind bereits Daten anderer Geräte vorhanden. „Zusammenführen“ übernimmt sie zusätzlich zu deinen eigenen. „Ersetzen“ sichert deine lokalen Daten (wiederherstellbar bei Austritt) und übernimmt danach ausschließlich den Stand der anderen Geräte.")
        }
        .confirmationDialog("Synchronisierung deaktivieren", isPresented: $zeigeAustrittsWahl) {
            Button("Vorherigen Stand wiederherstellen") {
                wiederherstellenUndDeaktivieren()
            }
            Button("Ohne Wiederherstellung deaktivieren", role: .destructive) {
                SyncOrdnerService.ordnerEntfernen()
                ausgewaehlterOrdner = nil
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Es ist ein lokales Backup von vor dem letzten Beitritt/Ersetzen vorhanden. Möchtest du deinen damaligen Stand wiederherstellen?")
        }
    }

    /// Legt den Ordner fest. Enthält er bereits Daten anderer Geräte (GitHub
    /// #63), fragt eine Wahl zwischen Zusammenführen und Ersetzen — sonst
    /// löst das direkt einen ersten Sync-Zyklus aus (GitHub #39, Phase 5
    /// „Gruppen-Setup"), statt dass die Person erst noch manuell auf „Jetzt
    /// synchronisieren" tippen muss.
    private func ordnerFestlegen(_ ordner: URL) {
        do {
            try SyncOrdnerService.ordnerFestlegen(ordner)
            ausgewaehlterOrdner = ordner
            fehlermeldung = nil
            if SyncOrdnerService.hatVorhandenePeers(in: ordner) {
                zeigeBeitrittsWahl = true
            } else {
                jetztSynchronisieren()
            }
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

    /// Pausiert den Hintergrund-Timer für die Dauer des Austauschs (sonst
    /// könnte er mitten in den Container-Wechsel schreiben, siehe
    /// `docs/DATABASE_CONCURRENCY.md`) und startet ihn danach mit dem neuen
    /// Context neu.
    private func ersetzenGetappt() {
        letzterSyncErfolgreich = false
        wirdSynchronisiert = true
        syncPollingService.stoppen()
        Task {
            do {
                let neuerContext = try await SyncErsetzenService.ersetzenDurchPeer(containerController: containerController)
                syncPollingService.starten(context: neuerContext)
                letzterSyncErfolgreich = true
            } catch {
                fehlermeldung = error.localizedDescription
                syncPollingService.starten(context: containerController.modelContainer.mainContext)
            }
            wirdSynchronisiert = false
        }
    }

    private func deaktivierenGetappt() {
        if SyncErsetzenService.vorhandenesBackup() != nil {
            zeigeAustrittsWahl = true
        } else {
            SyncOrdnerService.ordnerEntfernen()
            ausgewaehlterOrdner = nil
        }
    }

    private func wiederherstellenUndDeaktivieren() {
        syncPollingService.stoppen()
        do {
            let neuerContext = try SyncErsetzenService.wiederherstellenAusBackup(containerController: containerController)
            SyncOrdnerService.ordnerEntfernen()
            ausgewaehlterOrdner = nil
            syncPollingService.starten(context: neuerContext)
        } catch {
            fehlermeldung = error.localizedDescription
            syncPollingService.starten(context: containerController.modelContainer.mainContext)
        }
    }
}

#Preview {
    let container = try! ModelContainer(for: SchemaDefinition.schema, configurations: .init(isStoredInMemoryOnly: true))
    NavigationStack {
        SyncOrdnerSettingsView()
    }
    .environmentObject(SyncPollingService())
    .environmentObject(ModelContainerController(modelContainer: container))
    .modelContainer(container)
}
