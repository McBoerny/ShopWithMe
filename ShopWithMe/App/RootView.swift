import SwiftUI
import SwiftData

/// Wurzel-Ansicht der App: Tab-Navigation zwischen den Hauptbereichen.
///
/// Die App startet immer direkt auf „Einkaufen“ (erster Tab) — Artikel- und
/// Geschäfte-Verwaltung sind bewusst keine eigenen Tabs mehr, sondern nur noch über
/// ``SettingsView`` erreichbar (GitHub #1). „Scannen“ (mittlerer Tab) bettet
/// ``BelegScanView`` dauerhaft ein (``BelegScanView/istEigenerTab``) — zusätzlich zu
/// den weiterhin bestehenden, kontextspezifischen Sheet-Einstiegspunkten (Einkaufen-
/// Menü, nach Einkaufsabschluss, Geschäfts-Detail, Geschäfte-Liste), siehe
/// `docs/BELEGSCAN.md`.
///
/// Stößt außerdem bei jedem App-Start und Rückkehr aus dem Hintergrund die
/// automatische Preishistorie-Bereinigung (nutzerkonfigurierbar, Standard "Nie",
/// siehe ``PreisHistorieBereinigungService/automatischBereinigenFallsFaellig(context:)``)
/// sowie die automatische Bereinigung bereits verarbeiteter, operativer
/// `KaufEintrag`e (immer aktiv, kurze feste Frist, siehe
/// ``KaufEintragBereinigungService/automatischBereinigenFallsFaellig(context:)``) und
/// die automatische Verdichtung alter Preispunkte (immer aktiv, siehe
/// ``PreispunktVerdichtungService/automatischVerdichtenFallsFaellig(context:)``) an.
///
/// Reagiert außerdem auf `shopwithme://milkforus-import`, geöffnet von der
/// ``ShopWithMeShareExtension`` nachdem sie eine geteilte MilkForUs-Datei über
/// ``MilkForUsPendingImportStore`` bereitgelegt hat, und präsentiert dafür direkt
/// ``MilkForUsImportView`` — siehe `docs/MILKFORUS_IMPORT.md`.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var syncPollingService: SyncPollingService
    @State private var ausstehenderMilkForUsImport: AusstehenderImport?
    @State private var zeigeAusDerZeitGefallenDialog = false
    @State private var zeigeNeustartHinweisNachVollAbgleich = false

    var body: some View {
        TabView {
            Tab("Einkaufen", systemImage: "checklist") {
                EinkaufenView()
            }
            Tab("Scannen", systemImage: "camera.viewfinder") {
                BelegScanView(istEigenerTab: true)
            }
            Tab("Einstellungen", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .task {
            await PreisHistorieBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
            await KaufEintragBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
            await PreispunktVerdichtungService.automatischVerdichtenFallsFaellig(context: modelContext)
            await SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()
            pruefeAusDerZeitGefallen()
        }
        .onChange(of: scenePhase) { _, neuePhase in
            guard neuePhase == .active else { return }
            Task {
                await PreisHistorieBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
                await KaufEintragBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
                await PreispunktVerdichtungService.automatischVerdichtenFallsFaellig(context: modelContext)
                await SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()
                pruefeAusDerZeitGefallen()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "shopwithme", url.host == "milkforus-import",
                  let text = MilkForUsPendingImportStore.abholen()
            else { return }
            ausstehenderMilkForUsImport = AusstehenderImport(text: text)
        }
        .sheet(item: $ausstehenderMilkForUsImport) { eintrag in
            MilkForUsImportView(initialText: eintrag.text)
        }
        // GitHub #89: bewusst kein Zusammenführen-Angebot — additive Merges
        // (auch das Bereich-A-Sicherheitsnetz) können nur hinzufügen, nie
        // entfernen, ein bereits etabliertes Gerät mit potenziell veralteten
        // lokalen Karteileichen bräuchte einen echten Ersatz, siehe
        // ``SyncAktualitaetsService``.
        .confirmationDialog("Sync-Abgleich nötig", isPresented: $zeigeAusDerZeitGefallenDialog) {
            Button("Jetzt abgleichen") {
                vollAbgleichAusloesen()
            }
            Button("Später erinnern", role: .cancel) {}
        } message: {
            Text("Dieses Gerät war länger als 30 Tage nicht erfolgreich synchronisiert. Damit Änderungen anderer Geräte sicher übernommen werden, muss der Datenbestand einmal komplett neu abgeglichen werden. Deine eigenen, noch nicht übertragenen Änderungen werden vorher gesichert.")
        }
        .alert("Neustart nötig", isPresented: $zeigeNeustartHinweisNachVollAbgleich) {
            Button("OK") {}
        } message: {
            Text("Bitte schließe die App jetzt vollständig (nicht nur in den Hintergrund legen) und öffne sie erneut, um den Abgleich abzuschließen.")
        }
    }

    private func pruefeAusDerZeitGefallen() {
        guard SyncAktualitaetsService.istAusDerZeitGefallen(context: modelContext) else { return }
        if SyncDebugLogger.istAktiv {
            let zuletzt = SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm.map { "\($0)" } ?? "nil"
            SyncDebugLogger.log(.ausDerZeitGefallenErkannt, details: "zuletztErfolgreichAm=\(zuletzt)")
        }
        zeigeAusDerZeitGefallenDialog = true
    }

    /// Sichert zuerst per einem echten Sync-Zyklus die eigenen, noch nicht
    /// hochgeladenen Änderungen (kritische Voraussetzung, siehe
    /// ``SyncAktualitaetsService``-Typ-Doku), plant dann „Ersetzen durch
    /// Peer" für den nächsten Start. Schlägt der Export fehl (z.B. kein
    /// Ordnerzugriff), wird NICHTS geplant — die Prüfung greift beim
    /// nächsten Vordergrund-Wechsel einfach erneut, statt eigene Änderungen
    /// zu riskieren.
    private func vollAbgleichAusloesen() {
        Task {
            let exportErfolgreich = await syncPollingService.syncZyklus()
            guard exportErfolgreich else { return }
            do {
                try SyncErsetzenService.planeErsetzenDurchPeer(context: modelContext)
                if SyncDebugLogger.istAktiv {
                    SyncDebugLogger.log(.vollAbgleichEingeleitet, details: "")
                }
                zeigeNeustartHinweisNachVollAbgleich = true
            } catch {
                // Seltener Fehlerfall (z.B. eigener Snapshot-Export
                // schlägt lokal fehl) — beim nächsten Vordergrund-Wechsel
                // erneut versucht, kein stiller Datenverlust möglich, da
                // noch nichts geplant wurde.
            }
        }
    }
}

/// Macht den von der Share Extension übergebenen Text `.sheet(item:)`-fähig.
private struct AusstehenderImport: Identifiable {
    let id = UUID()
    let text: String
}

#Preview {
    RootView()
        .environmentObject(SyncPollingService())
        .environmentObject(MultipeerSyncService())
}
