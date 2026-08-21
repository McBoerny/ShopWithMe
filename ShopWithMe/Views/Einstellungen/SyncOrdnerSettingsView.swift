import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

/// Einstellung für den geteilten Sync-Ordner (Datensynchronisation, GitHub #39).
///
/// Hier wird nur ein zusätzlicher Ordner referenziert, in den eigene Änderungen
/// als Events exportiert werden (``SyncExportService``) — die lokale Datenbank
/// bleibt unangetastet am Standardpfad. Siehe
/// `docs/DATENSYNCHRONISATION_VERLAUF.md`.
///
/// Ein erster Sync-Zyklus läuft automatisch direkt beim Verknüpfen eines
/// Ordners (Bootstrap, GitHub #39 Phase 5), danach übernimmt adaptives
/// Polling (``SyncPollingService``) periodisch und unabhängig von
/// Nutzerinteraktion. Ein manueller Trigger existiert nur noch als
/// „Erneut versuchen“ direkt neben einer Fehlermeldung — im Normalfall ist
/// hier bewusst kein Button sichtbar, siehe ``jetztSynchronisieren()``.
struct SyncOrdnerSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncPollingService: SyncPollingService
    @EnvironmentObject private var multipeerSyncService: MultipeerSyncService

    @State private var zeigeOrdnerauswahl = false
    @State private var fehlermeldung: String?
    @State private var ausgewaehlterOrdner: URL? = SyncOrdnerService.gewaehlterOrdner()
    /// Initialisiert aus ``SyncErsetzenService/ausstehendeAktion`` statt aus
    /// einem eigenen, separat zu pflegenden Flag (Single Source of Truth) —
    /// übersteht dadurch auch ein Verlassen/erneutes Öffnen dieser View, ohne
    /// dass zwischenzeitlich neu gestartet wurde. Siehe ``planeUndZeigeNeustartHinweis(_:)``.
    @State private var neustartAusstehend = SyncErsetzenService.ausstehendeAktion != nil
    /// `true` während ein Live-Austausch (``ModelContainerController/ersetzeLiveMitNeuemStore(befuellen:)``)
    /// läuft — deaktiviert dieselben Bedienelemente wie ``neustartAusstehend``,
    /// aber nur für die kurze Dauer des Austauschs selbst, kein Neustart nötig.
    @State private var wirdErsetzt = false
    @State private var wirdSynchronisiert = false
    /// GitHub #92 (experimentell): kurz einen Dokumenten-Picker auf den
    /// Sync-Ordner einblenden, siehe ``ICloudSyncTriggerPicker``.
    @State private var zeigeSyncTriggerPicker = false

    @State private var zeigeBeitrittsWahl = false
    @State private var zeigeAustrittsWahl = false
    @State private var zeigeNeustartHinweis = false
    @State private var zeigeBackupWiederherstellenBestaetigung = false

    /// Nutzer-Einstellung für den Multipeer-Kanal (GitHub #127) — separat von
    /// ``MultipeerSyncService/aktiv`` (View-Sichtbarkeits-Flag von
    /// `EinkaufenView`): dieser Schalter entscheidet, ob `EinkaufenView`
    /// `aktiv` überhaupt setzen darf. In `@State` gespiegelt, damit die
    /// `Toggle`-Bindung unten funktioniert; einzige Quelle der Wahrheit bleibt
    /// ``MultipeerSyncService/vonNutzerAktiviert`` (UserDefaults).
    @State private var multipeerAktiviert = MultipeerSyncService.vonNutzerAktiviert

    /// Beim laufenden Hintergrund-Sync zurückgestellte Merge-Kandidaten
    /// (Geschäft/Artikel/Einkaufsliste) — siehe Ambiguitäts-Rückstellung in
    /// `SyncSnapshotImportService.mergeGeschaefte`/`mergeArtikel`/
    /// `mergeEinkaufslisten`. Anders als ``beitrittsKandidaten`` (einmaliger,
    /// transienter Scan vor dem Beitritts-Merge) eine dauerhafte, per
    /// `@Query` live nachgeführte Warteschlange.
    @Query(sort: \SyncAbgleichKandidat.erkanntAm) private var abgleichWarteschlange: [SyncAbgleichKandidat]
    @State private var zeigeAbgleichWarteschlange = false

    var body: some View {
        Form {
            EigenerGeraeteNameSection()

            if ausgewaehlterOrdner != nil {
                BekannteSyncPeersSection()
            }

            if neustartAusstehend {
                Section {
                    Label("Ein Neustart der App steht noch aus, um den letzten Vorgang abzuschließen. Die Synchronisierung ist bis dahin pausiert.", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
            }
            if wirdErsetzt {
                Section {
                    Label {
                        Text("Datenbestand wird ersetzt…")
                    } icon: {
                        ProgressView()
                    }
                }
            }

            Section {
                Button {
                    zeigeOrdnerauswahl = true
                } label: {
                    LabeledContent("Sync-Ordner") {
                        Text(ausgewaehlterOrdner?.lastPathComponent ?? "wählen…")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(neustartAusstehend || wirdErsetzt)
                .swipeActions(edge: .trailing) {
                    if ausgewaehlterOrdner != nil {
                        Button("Deaktivieren", role: .destructive) {
                            deaktivierenGetappt()
                        }
                        .disabled(neustartAusstehend || wirdErsetzt)
                    }
                }
            } footer: {
                Text("Ein geteilter Ordner (z.B. iCloud Drive oder Synology Drive), über den mehrere Geräte ihre Einkaufslisten-Änderungen austauschen. Die lokale Datenbank bleibt dabei unverändert am Standardort. Zum Deaktivieren nach links wischen.")
            }

            Section {
                Toggle("Multipeer-Sync", isOn: $multipeerAktiviert)
                    .onChange(of: multipeerAktiviert) { _, neuerWert in
                        MultipeerSyncService.vonNutzerAktiviert = neuerWert
                        if !neuerWert {
                            multipeerSyncService.aktiv = false
                        }
                    }
            } footer: {
                Text("Zusätzlicher Direktkanal zum Sync-Ordner: gleicht Änderungen sofort mit anderen Geräten in der Nähe ab, während gemeinsam eingekauft wird. Ohne diesen Kanal werden Änderungen weiterhin über den Sync-Ordner ausgetauscht, nur etwas verzögert.")
            }

            if !abgleichWarteschlange.isEmpty {
                Section {
                    Button {
                        zeigeAbgleichWarteschlange = true
                    } label: {
                        Label("\(abgleichWarteschlange.count) mögliche Duplikate prüfen", systemImage: "exclamationmark.triangle")
                    }
                } footer: {
                    Text("Diese Einträge konnten beim automatischen Sync nicht eindeutig einem vorhandenen Geschäft, Artikel oder einer Liste zugeordnet werden und warten auf deine Entscheidung.")
                }
            }

            if let backup = SyncErsetzenService.vorhandenesBackup() {
                Section {
                    LabeledContent("Erstellt am") {
                        Text("\(backup.erstelltAm.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(backup.groesseBytes), countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }
                    Button("Backup wiederherstellen", role: .destructive) {
                        zeigeBackupWiederherstellenBestaetigung = true
                    }
                    .disabled(wirdErsetzt)
                } header: {
                    Text("Lokales Backup")
                } footer: {
                    Text("Ein lokales Backup deines Datenbestands von vor dem letzten „Ersetzen“ beim Sync-Beitritt. Wiederherstellen überschreibt den aktuellen Datenbestand mit diesem Stand.")
                }
            }

            if ausgewaehlterOrdner != nil && !neustartAusstehend {
                Section {
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(letzterOrdnerSyncText)
                        multipeerStatusZeile
                    }
                    .font(.footnote)
                }
            }

            if let fehlermeldung {
                Section {
                    Label(fehlermeldung, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    if ausgewaehlterOrdner != nil {
                        Button {
                            // GitHub #92 (experimentell): nur bei diesem
                            // expliziten Nutzer-Tap, nicht bei den übrigen
                            // internen Aufrufstellen von ``jetztSynchronisieren()``
                            // (Bootstrap nach Ordnerauswahl, Beitritts-Abgleich) —
                            // siehe Accessibility-/Review-Erwägung in #92.
                            zeigeSyncTriggerPicker = true
                            jetztSynchronisieren()
                        } label: {
                            if wirdSynchronisiert {
                                ProgressView()
                            } else {
                                Text("Erneut versuchen")
                            }
                        }
                        .disabled(wirdSynchronisiert)
                    }
                }
            }
        }
        .navigationTitle("Synchronisation")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $zeigeOrdnerauswahl, allowedContentTypes: [.folder]) { ergebnis in
            switch ergebnis {
            case .success(let ordner):
                ordnerFestlegen(ordner)
            case .failure(let error):
                fehlermeldung = error.localizedDescription
            }
        }
        // GitHub #63: der gewählte Ordner enthält bereits Daten anderer
        // Geräte — die frühere „Zusammenführen"-Wahl (GitHub #86, Teil 2)
        // wurde entfernt (siehe `docs/DATENSYNCHRONISATION_VERLAUF.md`
        // Abschnitt 48), „Ersetzen" ist jetzt der einzige Weg, einer
        // bestehenden Gruppe beizutreten.
        .confirmationDialog("Bestehende Daten gefunden", isPresented: $zeigeBeitrittsWahl) {
            Button("Ersetzen", role: .destructive) {
                ersetzenGetappt()
            }
            Button("Abbrechen", role: .cancel) {
                Task { await SyncOrdnerService.ordnerEntfernenUndPeersVergessen(context: modelContext) }
                ausgewaehlterOrdner = nil
            }
        } message: {
            Text("In diesem Ordner sind bereits Daten anderer Geräte vorhanden. „Ersetzen“ sichert deine lokalen Daten (wiederherstellbar bei Austritt) und übernimmt danach ausschließlich den Stand der anderen Geräte.")
        }
        .confirmationDialog("Synchronisierung deaktivieren", isPresented: $zeigeAustrittsWahl) {
            Button("Vorherigen Stand wiederherstellen") {
                wiederherstellenUndDeaktivieren()
            }
            Button("Ohne Wiederherstellung deaktivieren", role: .destructive) {
                Task { await SyncOrdnerService.ordnerEntfernenUndPeersVergessen(context: modelContext) }
                ausgewaehlterOrdner = nil
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Es ist ein lokales Backup von vor dem letzten Beitritt/Ersetzen vorhanden. Möchtest du deinen damaligen Stand wiederherstellen?")
        }
        .confirmationDialog("Backup wiederherstellen", isPresented: $zeigeBackupWiederherstellenBestaetigung) {
            Button("Wiederherstellen", role: .destructive) {
                backupWiederherstellenGetappt()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der aktuelle Datenbestand wird durch das lokale Backup ersetzt.")
        }
        .alert("Neustart nötig", isPresented: $zeigeNeustartHinweis) {
            Button("OK") {}
        } message: {
            Text("Bitte schließe die App jetzt vollständig (nicht nur in den Hintergrund legen) und öffne sie erneut, um den Vorgang abzuschließen.")
        }
        .sheet(isPresented: $zeigeAbgleichWarteschlange) {
            // Laufender Sync: der Remote-Eintrag wurde bereits aktiv
            // zurückgehalten (kein automatischer Merge) — „unterschiedlich"
            // muss ihn hier deshalb aktiv freigeben, sonst bliebe er
            // dauerhaft unsynchronisiert.
            AbgleichKandidatenSheet(
                kandidaten: abgleichWarteschlange.map { kandidat in
                    AbgleichAnzeige(
                        id: kandidat.id, lokalerName: kandidat.lokalerName, fremderName: kandidat.fremderName,
                        aufGleich: { gewaehlterName in
                            SyncSnapshotImportService.abgleichKandidatBestaetigen(kandidat, gewaehlterName: gewaehlterName, context: modelContext)
                        },
                        aufUnterschiedlich: {
                            SyncSnapshotImportService.abgleichKandidatAlsUnterschiedlichBestaetigen(kandidat, context: modelContext)
                        }
                    )
                },
                onFertig: {}
            )
        }
        // GitHub #92 (experimentell, unbelegt — siehe Issue-Kommentar zur
        // Recherche): kein `.fileImporter` wie bei der Ordnerauswahl oben,
        // weil der hier bewusst NICHT zur Auswahl gedacht ist, sondern nur
        // kurz erscheinen und automatisch wieder verschwinden soll.
        .sheet(isPresented: $zeigeSyncTriggerPicker) {
            if let ausgewaehlterOrdner {
                ICloudSyncTriggerPicker(ordner: ausgewaehlterOrdner, isPresented: $zeigeSyncTriggerPicker)
            }
        }
    }

    private var letzterOrdnerSyncText: String {
        guard let zeitpunkt = SyncAktualitaetsService.zuletztErfolgreichSynchronisiertAm else {
            return "noch nicht synchronisiert"
        }
        return "zuletzt \(zeitpunkt.formatted(.relative(presentation: .named)))"
    }

    /// Rein additive Statuszeile zum Multipeer-Kanal (GitHub #49) — ``aktiv``
    /// spiegelt, ob gerade `EinkaufenView` sichtbar ist, ``verbundenePeerNamen``,
    /// ob dabei tatsächlich schon eine Verbindung zustande kam.
    @ViewBuilder
    private var multipeerStatusZeile: some View {
        if !multipeerSyncService.aktiv {
            Label("Multipeer inaktiv (nur beim Einkaufen)", systemImage: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
        } else if multipeerSyncService.verbundenePeerNamen.isEmpty {
            Label("Multipeer sucht nach Geräten…", systemImage: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
        } else {
            Label("Multipeer verbunden: \(multipeerSyncService.verbundenePeerNamen.joined(separator: ", "))", systemImage: "bolt.horizontal.circle.fill")
                .foregroundStyle(.green)
        }
    }

    /// Legt den Ordner fest. Enthält er bereits Daten anderer Geräte (GitHub
    /// #63), fragt eine Bestätigung für „Ersetzen" (die frühere
    /// „Zusammenführen"-Alternative wurde entfernt, siehe
    /// `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 48) — sonst löst das
    /// direkt einen ersten Sync-Zyklus aus (GitHub #39, Phase 5
    /// „Gruppen-Setup"), statt dass die Person erst noch manuell auf „Jetzt
    /// synchronisieren" tippen muss.
    private func ordnerFestlegen(_ ordner: URL) {
        do {
            try SyncOrdnerService.ordnerFestlegen(ordner)
            ausgewaehlterOrdner = ordner
            fehlermeldung = nil
            // Vor dem ersten Sync-Zyklus mit diesem Ordner: ein lokal noch
            // offener Einkaufsvorgang aus der Zeit vor dem (Wieder-)Beitritt
            // darf nicht unverändert stehen bleiben — sonst matcht ihn
            // `SyncSnapshotImportService.mergeEinkaufsvorgaenge`s
            // `offenerTreffer`-Zweig blind gegen einen tatsächlich aktiven
            // Vorgang eines Peers und vermischt dessen eigene, u.U. längst
            // veraltete Käufe in die listenweite Anzeige (siehe
            // ``EinkaufsvorgangAbschlussService/schliesseAlleOffenenEinkaufsvorgaenge(context:)``).
            EinkaufsvorgangAbschlussService.schliesseAlleOffenenEinkaufsvorgaenge(context: modelContext)
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
        fehlermeldung = nil
        wirdSynchronisiert = true
        Task {
            let erfolgreich = await syncPollingService.syncZyklus()
            wirdSynchronisiert = false
            if !erfolgreich {
                fehlermeldung = "Zugriff auf den Sync-Ordner fehlgeschlagen. Bitte Ordner erneut auswählen oder Berechtigung prüfen."
            }
        }
    }

    /// Ersetzt den lokalen Datenbestand SOFORT durch den Stand des Peers —
    /// kein Neustart mehr nötig (zweiter Live-Anlauf, siehe
    /// ``ModelContainerController``). Stoppt den Hintergrund-Sync (Polling-
    /// Loop inkl. iCloud-Beobachter sowie Multipeer-Kanal) VOR dem Austausch,
    /// damit kein Zyklus mehr mit dem gleich verlassenen Context arbeitet —
    /// `.task(id:)` in `ShopWithMeApp` startet ihn nach dem Umhängen auf dem
    /// neuen Context automatisch neu.
    ///
    /// Fällt auf den alten Neustart-Mechanismus zurück, falls
    /// ``ModelContainerController/aktuell`` `nil` ist (sollte im laufenden
    /// Betrieb nicht vorkommen — nur zur Absicherung, z.B. exotische
    /// Test-Konfigurationen ohne echten `ModelContainerController`).
    private func ersetzenGetappt() {
        guard let controller = ModelContainerController.aktuell else {
            planeErsetzenDurchPeerFallback()
            return
        }
        syncPollingService.stoppen()
        multipeerSyncService.stoppen()
        wirdErsetzt = true
        Task {
            do {
                try await SyncErsetzenService.fuehreErsetzenDurchPeerLive(controller: controller)
            } catch {
                fehlermeldung = error.localizedDescription
            }
            wirdErsetzt = false
        }
    }

    /// Fallback: sichert den aktuellen Stand und merkt „Ersetzen" nur für den
    /// nächsten App-Start vor — nur falls kein ``ModelContainerController``
    /// verfügbar ist, siehe ``ersetzenGetappt()``.
    private func planeErsetzenDurchPeerFallback() {
        do {
            try SyncErsetzenService.planeErsetzenDurchPeer(context: modelContext)
            neustartAusstehendMachen()
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }

    private func neustartAusstehendMachen() {
        syncPollingService.stoppen()
        multipeerSyncService.stoppen()
        neustartAusstehend = true
        zeigeNeustartHinweis = true
    }

    private func deaktivierenGetappt() {
        if SyncErsetzenService.vorhandenesBackup() != nil {
            zeigeAustrittsWahl = true
        } else {
            Task { await SyncOrdnerService.ordnerEntfernenUndPeersVergessen(context: modelContext) }
            ausgewaehlterOrdner = nil
        }
    }

    private func wiederherstellenUndDeaktivieren() {
        guard let controller = ModelContainerController.aktuell else {
            do {
                try SyncErsetzenService.planeWiederherstellenAusBackup()
                Task { await SyncOrdnerService.ordnerEntfernenUndPeersVergessen(context: modelContext) }
                ausgewaehlterOrdner = nil
                neustartAusstehendMachen()
            } catch {
                fehlermeldung = error.localizedDescription
            }
            return
        }
        Task { await SyncOrdnerService.ordnerEntfernenUndPeersVergessen(context: modelContext) }
        ausgewaehlterOrdner = nil
        syncPollingService.stoppen()
        multipeerSyncService.stoppen()
        wirdErsetzt = true
        Task {
            do {
                try await SyncErsetzenService.fuehreWiederherstellenAusBackupLive(controller: controller)
            } catch {
                fehlermeldung = error.localizedDescription
            }
            wirdErsetzt = false
        }
    }

    /// Eigenständige Wiederherstellung ohne Sync-Ordner-Austritt (GitHub #63)
    /// — z.B. für die Korruptions-Recovery-Verwendung von ``SyncErsetzenService``,
    /// bei der der Sync-Ordner weiterhin verknüpft bleiben soll.
    private func backupWiederherstellenGetappt() {
        guard let controller = ModelContainerController.aktuell else {
            do {
                try SyncErsetzenService.planeWiederherstellenAusBackup()
                neustartAusstehendMachen()
            } catch {
                fehlermeldung = error.localizedDescription
            }
            return
        }
        syncPollingService.stoppen()
        multipeerSyncService.stoppen()
        wirdErsetzt = true
        Task {
            do {
                try await SyncErsetzenService.fuehreWiederherstellenAusBackupLive(controller: controller)
            } catch {
                fehlermeldung = error.localizedDescription
            }
            wirdErsetzt = false
        }
    }
}

/// Entkoppeltes Anzeige-/Aktions-Modell für ``AbgleichKandidatenSheet`` —
/// bewusst nicht direkt an ``SyncAbgleichKandidat`` (persistierte
/// Warteschlange) gekoppelt, der Aufrufer übersetzt seine Kandidaten in
/// `AbgleichAnzeige` und übergibt die passenden Aktions-Closures. Ursprünglich
/// (GitHub #86, Teil 2) auch vom einmaligen Sync-Ordner-Beitritts-Abgleich
/// genutzt — diese zweite Quelle wurde entfernt (siehe
/// `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 48), die Entkopplung
/// bleibt trotzdem bestehen, da sie die Sheet-View unabhängig vom konkreten
/// Kandidaten-Typ hält.
private struct AbgleichAnzeige: Identifiable {
    let id: UUID
    let lokalerName: String
    let fremderName: String
    /// Nutzer wählt „gleich", Parameter ist der beizubehaltende Name
    /// (lokaler oder fremder, je nach getroffener Wahl).
    let aufGleich: (String) -> Void
    /// Nutzer wählt „unterschiedlich" (auch der Standard bei
    /// Nicht-Entscheidung) — legt das zurückgehaltene Objekt aktiv an.
    let aufUnterschiedlich: () -> Void
}

/// Aktive Rückfrage für mehrdeutige Bereich-B-Merge-Kandidaten (Geschäft/
/// Artikel/Einkaufsliste) aus der laufenden, persistierten
/// ``SyncAbgleichKandidat``-Warteschlange. Pro Kandidat: „gleich" (mit Wahl,
/// welcher Name bleibt) oder „unterschiedlich" (Standard bei
/// Nicht-Entscheidung) — beide bleiben dann als getrennte Einträge bestehen
/// und lassen sich bei Bedarf später manuell per Löschen bereinigen, siehe
/// `docs/GESCHAEFTSERKENNUNG.md`.
private struct AbgleichKandidatenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kandidaten: [AbgleichAnzeige]
    let onFertig: () -> Void

    private enum Entscheidung: Hashable {
        case unterschiedlich
        case gleichLokalerName
        case gleichFremderName
    }

    @State private var entscheidungen: [UUID: Entscheidung] = [:]

    var body: some View {
        NavigationStack {
            List(kandidaten) { kandidat in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("„\(kandidat.lokalerName)“").bold()
                        Text("könnte identisch sein mit „\(kandidat.fremderName)“ vom anderen Gerät")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Entscheidung", selection: entscheidungBinding(fuer: kandidat)) {
                        Text("Unterschiedlich").tag(Entscheidung.unterschiedlich)
                        Text("Gleich – „\(kandidat.lokalerName)“ behalten").tag(Entscheidung.gleichLokalerName)
                        Text("Gleich – „\(kandidat.fremderName)“ übernehmen").tag(Entscheidung.gleichFremderName)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Mögliche Duplikate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", action: fertig)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Diese Einträge wurden unterschiedlich benannt oder stimmen nicht exakt überein — deshalb fragt die App hier nach, statt automatisch zu entscheiden. Unentschieden bleibt: getrennte Einträge.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .interactiveDismissDisabled()
    }

    private func entscheidungBinding(fuer kandidat: AbgleichAnzeige) -> Binding<Entscheidung> {
        Binding(
            get: { entscheidungen[kandidat.id] ?? .unterschiedlich },
            set: { entscheidungen[kandidat.id] = $0 }
        )
    }

    private func fertig() {
        for kandidat in kandidaten {
            switch entscheidungen[kandidat.id] ?? .unterschiedlich {
            case .unterschiedlich:
                kandidat.aufUnterschiedlich()
            case .gleichLokalerName:
                kandidat.aufGleich(kandidat.lokalerName)
            case .gleichFremderName:
                kandidat.aufGleich(kandidat.fremderName)
            }
        }
        dismiss()
        onFertig()
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

/// Listet alle jemals per Sync gesehenen Peer-Geräte (``SyncPeerInfo``) mit
/// Zuletzt-gesehen-Zeitpunkt: Geräte, die die App nicht mehr nutzen (z.B. nach
/// einer Neuinstallation mit neuer Geräte-ID), lassen sich hier manuell
/// entfernen — löscht sowohl den lokalen Merkposten als auch den Peer-Ordner
/// im Sync-Ordner selbst, damit sein letzter bekannter Stand nicht mehr
/// zurückgespielt wird.
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
        let entfernte = offsets.map { peers[$0] }
        guard let syncOrdner = SyncOrdnerService.gewaehlterOrdner() else {
            Task {
                await DatabaseLeaseService.performMicroLease(context: modelContext) {
                    for peer in entfernte { modelContext.delete(peer) }
                }
            }
            return
        }
        Task {
            for peer in entfernte {
                await SyncOrdnerService.entfernePeer(peer, in: syncOrdner, context: modelContext)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SyncOrdnerSettingsView()
    }
    .environmentObject(SyncPollingService())
    .environmentObject(MultipeerSyncService())
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, SyncPeerInfo.self], inMemory: true)
}
