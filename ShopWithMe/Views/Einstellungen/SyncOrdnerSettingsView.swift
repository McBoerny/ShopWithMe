import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Einstellung für den geteilten Sync-Ordner (Datensynchronisation, GitHub #39).
///
/// Hier wird nur ein zusätzlicher Ordner referenziert, in den eigene Änderungen
/// als Events exportiert werden (``SyncExportService``) — die lokale Datenbank
/// bleibt unangetastet am Standardpfad. Siehe
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

    @State private var zeigeBeitrittsWahl = false
    @State private var zeigeAustrittsWahl = false
    @State private var zeigeNeustartHinweis = false
    @State private var zeigeBackupWiederherstellenBestaetigung = false

    var body: some View {
        Form {
            EigenerGeraeteNameSection()

            Section {
                LabeledContent("Sync-Ordner") {
                    Text(ausgewaehlterOrdner?.lastPathComponent ?? "ohne")
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

            if let backup = SyncErsetzenService.vorhandenesBackup() {
                Section {
                    LabeledContent("Erstellt am") {
                        Text(backup.erstelltAm.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Größe") {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(backup.groesseBytes), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button("Backup wiederherstellen", role: .destructive) {
                        zeigeBackupWiederherstellenBestaetigung = true
                    }
                } header: {
                    Text("Lokales Backup")
                } footer: {
                    Text("Ein lokales Backup deines Datenbestands von vor dem letzten „Ersetzen“ beim Sync-Beitritt. Wiederherstellen überschreibt den aktuellen Datenbestand mit diesem Stand.")
                }
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
            Text("In diesem Ordner sind bereits Daten anderer Geräte vorhanden. „Zusammenführen“ übernimmt sie zusätzlich zu deinen eigenen. „Ersetzen“ sichert deine lokalen Daten (wiederherstellbar bei Austritt) und übernimmt danach ausschließlich den Stand der anderen Geräte — dafür muss die App danach einmal neu gestartet werden.")
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
            Text("Es ist ein lokales Backup von vor dem letzten Beitritt/Ersetzen vorhanden. Möchtest du deinen damaligen Stand wiederherstellen? Dafür muss die App danach einmal neu gestartet werden.")
        }
        .confirmationDialog("Backup wiederherstellen", isPresented: $zeigeBackupWiederherstellenBestaetigung) {
            Button("Wiederherstellen", role: .destructive) {
                backupWiederherstellenGetappt()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der aktuelle Datenbestand wird durch das lokale Backup ersetzt. Dafür muss die App danach einmal neu gestartet werden.")
        }
        .alert("Neustart nötig", isPresented: $zeigeNeustartHinweis) {
            Button("OK") {}
        } message: {
            Text("Bitte schließe die App jetzt vollständig (nicht nur in den Hintergrund legen) und öffne sie erneut, um den Vorgang abzuschließen.")
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
    /// (``SyncDebugLogger``) an einer einzigen Stelle passiert. Zeigt den
    /// tatsächlichen Rückgabewert an, statt wie zuvor unbedingt „erfolgreich"
    /// zu melden — ein fehlgeschlagener Ordnerzugriff (Berechtigung entzogen,
    /// externer Datenträger nicht verbunden) landet dadurch als echte
    /// Fehlermeldung statt unbemerkt zu verpuffen.
    private func jetztSynchronisieren() {
        letzterSyncErfolgreich = false
        fehlermeldung = nil
        wirdSynchronisiert = true
        Task {
            let erfolgreich = await syncPollingService.syncZyklus()
            wirdSynchronisiert = false
            if erfolgreich {
                letzterSyncErfolgreich = true
            } else {
                fehlermeldung = "Zugriff auf den Sync-Ordner fehlgeschlagen. Bitte Ordner erneut auswählen oder Berechtigung prüfen."
            }
        }
    }

    /// Sichert den aktuellen Stand und merkt „Ersetzen" nur für den nächsten
    /// App-Start vor (siehe Typ-Doku von ``SyncErsetzenService``, warum ein
    /// sofortiger Austausch zur Laufzeit auf einem echten Gerät abstürzte) —
    /// verändert selbst noch nichts am Datenbestand.
    private func ersetzenGetappt() {
        do {
            try SyncErsetzenService.planeErsetzenDurchPeer(context: modelContext)
            zeigeNeustartHinweis = true
        } catch {
            fehlermeldung = error.localizedDescription
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
        do {
            try SyncErsetzenService.planeWiederherstellenAusBackup()
            SyncOrdnerService.ordnerEntfernen()
            ausgewaehlterOrdner = nil
            zeigeNeustartHinweis = true
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }

    /// Eigenständige Wiederherstellung ohne Sync-Ordner-Austritt (GitHub #63)
    /// — z.B. für die Korruptions-Recovery-Verwendung von ``SyncErsetzenService``,
    /// bei der der Sync-Ordner weiterhin verknüpft bleiben soll.
    private func backupWiederherstellenGetappt() {
        do {
            try SyncErsetzenService.planeWiederherstellenAusBackup()
            zeigeNeustartHinweis = true
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }
}

/// Eigener Gerätename für die Peer-Anzeige beim Sync (GitHub #65) — ohne diesen
/// erscheinen alle Geräte schlicht als `UIDevice.current.name` (meist "iPhone"),
/// was sie beim gemeinsamen Einkaufen ununterscheidbar macht. Wirkt sich über
/// ``DatabaseLeaseService/geraeteName`` automatisch überall aus (Lease-Meldungen,
/// Sync-Snapshot-Export, Peer-Liste), ohne jede Verwendungsstelle einzeln
/// anzupassen.
private struct EigenerGeraeteNameSection: View {
    @State private var name: String

    init() {
        _name = State(initialValue: DatabaseLeaseService.eigenerGeraeteNameOverride ?? "")
    }

    var body: some View {
        Section {
            TextField(UIDevice.current.name, text: $name)
                .onChange(of: name) { _, neuerName in
                    DatabaseLeaseService.eigenerGeraeteNameOverride = neuerName
                }
        } header: {
            Text("Gerätename")
        } footer: {
            Text("Damit dieses Gerät bei anderen Peers nicht einfach als „\(UIDevice.current.name)“ erscheint. Leer lassen, um den Gerätenamen zu verwenden.")
        }
    }
}

#Preview {
    NavigationStack {
        SyncOrdnerSettingsView()
    }
    .environmentObject(SyncPollingService())
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
