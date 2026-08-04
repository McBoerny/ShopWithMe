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
    @State private var zeigeAusGruppeEntferntDialog = false
    @State private var zeigeSyncOrdnerSettingsFuerBeitritt = false
    @State private var toterGruppenPeer: SyncPeerInfo?
    @State private var zeigeToterGruppenPeerDialog = false

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
            await SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context: modelContext)
            pruefeAusDerZeitGefallen()
            pruefeToteGruppenPeers()
        }
        .onChange(of: scenePhase) { _, neuePhase in
            guard neuePhase == .active else { return }
            Task {
                await PreisHistorieBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
                await KaufEintragBereinigungService.automatischBereinigenFallsFaellig(context: modelContext)
                await PreispunktVerdichtungService.automatischVerdichtenFallsFaellig(context: modelContext)
                await SyncExportService.raeumeAlteEigeneEventDateienAufFallsFaellig()
            await SyncTombstoneService.raeumeAlteTombstonesAufFallsFaellig(context: modelContext)
                pruefeAusDerZeitGefallen()
                pruefeToteGruppenPeers()
            }
        }
        .onChange(of: syncPollingService.wurdeAusGruppeEntfernt) { _, entfernt in
            guard entfernt else { return }
            zeigeAusGruppeEntferntDialog = true
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
        // Peer-Lebenszyklus, Rückkehrer-Fall: der eigene Peer-Ordner wurde von
        // der Gruppe entfernt — Backup + Sync-Ordner-Entfernung sind zu
        // diesem Zeitpunkt bereits automatisch erfolgt (``SyncPollingService/starten(context:)``),
        // dieser Dialog ist rein informativ, keine der beiden Optionen ist
        // zeitkritisch. Bewusst abweichender Text vom „Sync-Abgleich
        // nötig"-Dialog oben — anderer Fall (von der Gruppe ausgeschlossen,
        // nicht nur selbst zurückgefallen).
        .confirmationDialog("Aus der Sync-Gruppe entfernt", isPresented: $zeigeAusGruppeEntferntDialog) {
            Button("Wieder beitreten") {
                syncPollingService.wurdeAusGruppeEntfernt = false
                zeigeSyncOrdnerSettingsFuerBeitritt = true
            }
            Button("Alleine weitermachen", role: .cancel) {
                syncPollingService.wurdeAusGruppeEntfernt = false
            }
        } message: {
            Text("Deine Gruppe hat dieses Gerät entfernt, weil es seit längerer Zeit nicht gesehen wurde. Ein lokales Backup deines bisherigen Bestands wurde bereits erstellt. Du kannst allein weitermachen oder der Gruppe wieder beitreten (dabei wird dein Bestand durch den aktuellen Gruppenstand ersetzt).")
        }
        .sheet(isPresented: $zeigeSyncOrdnerSettingsFuerBeitritt) {
            NavigationStack {
                SyncOrdnerSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { zeigeSyncOrdnerSettingsFuerBeitritt = false }
                        }
                    }
            }
        }
        // Peer-Lebenszyklus, Sterblichkeits-Warnung: dieselbe 30-Tage-Schwelle
        // wie der bestehende Ignorier-Mechanismus beim Import
        // (``SyncSnapshotImportService/maximalesSnapshotAlter``, siehe
        // ``SyncPeerInfo/istWahrscheinlichTot``). Rein manuell/bestätigt —
        // kein automatisches Entfernen.
        .confirmationDialog(
            "Gerät seit langem nicht gesehen", isPresented: $zeigeToterGruppenPeerDialog, presenting: toterGruppenPeer
        ) { peer in
            Button("Entfernen", role: .destructive) { entferneToterGruppenPeer(peer) }
            Button("Später erinnern", role: .cancel) {}
        } message: { peer in
            Text("„\(peer.geraeteName)“ wurde seit \(peer.zuletztGesehen.formatted(date: .abbreviated, time: .omitted)) nicht mehr gesehen. Entfernen, wenn dieses Gerät die App nicht mehr nutzt.")
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

    /// Peer-Lebenszyklus: sucht den ersten lange nicht mehr gesehenen Peer
    /// und zeigt bei Fund den Entfernen-Dialog — pro Aufruf höchstens einer,
    /// weitere folgen bei erneutem Auslösen (`.task`/`scenePhase == .active`),
    /// analog ``pruefeAusDerZeitGefallen()``.
    private func pruefeToteGruppenPeers() {
        guard SyncOrdnerService.gewaehlterOrdner() != nil else { return }
        let alle = (try? modelContext.fetch(FetchDescriptor<SyncPeerInfo>())) ?? []
        guard let toter = alle.first(where: { $0.istWahrscheinlichTot }) else { return }
        toterGruppenPeer = toter
        zeigeToterGruppenPeerDialog = true
    }

    private func entferneToterGruppenPeer(_ peer: SyncPeerInfo) {
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else { return }
        Task {
            await SyncOrdnerService.entfernePeer(peer, in: syncOrdner, context: modelContext)
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
