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
/// Ordners (Bootstrap, GitHub #39 Phase 5) — „Jetzt synchronisieren“ danach
/// weiterhin manuell auslösbar. Ein automatisches, periodisches Auslösen
/// unabhängig von Nutzerinteraktion (abhängig davon, ob z.B. gerade
/// eingekauft wird) ist erst Phase 4 des Plans („adaptives Polling“).
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
    @State private var wirdSynchronisiert = false
    @State private var letzterSyncErfolgreich = false
    /// GitHub #92 (experimentell): kurz einen Dokumenten-Picker auf den
    /// Sync-Ordner einblenden, siehe ``ICloudSyncTriggerPicker``.
    @State private var zeigeSyncTriggerPicker = false

    @State private var zeigeBeitrittsWahl = false
    @State private var zeigeAustrittsWahl = false
    @State private var zeigeNeustartHinweis = false
    @State private var zeigeBackupWiederherstellenBestaetigung = false

    /// GitHub #86, Teil 2: mehrdeutige Geschäfts-Kandidaten, die vor dem
    /// eigentlichen Beitritts-Merge aktiv bestätigt werden sollen — leer,
    /// solange ``beitrittsAbgleichPruefenUndSynchronisieren()`` noch prüft
    /// oder keine gefunden wurden.
    @State private var beitrittsKandidaten: [SyncSnapshotImportService.GeschaeftsAbgleichKandidat] = []
    @State private var zeigeBeitrittsAbgleich = false
    @State private var pruefeBeitrittsAbgleich = false

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

            Section {
                LabeledContent("Sync-Ordner") {
                    Text(ausgewaehlterOrdner?.lastPathComponent ?? "ohne")
                        .foregroundStyle(.secondary)
                }
            }

            if ausgewaehlterOrdner != nil {
                Section {
                    LabeledContent("Ordner-Sync") {
                        Text(letzterOrdnerSyncText)
                            .foregroundStyle(.secondary)
                    }
                    multipeerStatusZeile
                } header: {
                    Text("Sync-Status")
                } footer: {
                    Text("Der Multipeer-Kanal beschleunigt die Übertragung zusätzlich über lokales WLAN/Bluetooth, solange gemeinsam eingekauft wird — der Ordner bleibt dabei immer die eigentliche Quelle der Wahrheit.")
                }
            }

            if neustartAusstehend {
                Section {
                    Label("Ein Neustart der App steht noch aus, um den letzten Vorgang abzuschließen. Die Synchronisierung ist bis dahin pausiert.", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Ordner wählen…") {
                    zeigeOrdnerauswahl = true
                }
                .disabled(neustartAusstehend)
                if ausgewaehlterOrdner != nil {
                    Button("Synchronisierung deaktivieren", role: .destructive) {
                        deaktivierenGetappt()
                    }
                    .disabled(neustartAusstehend)
                }
            } footer: {
                Text("Ein geteilter Ordner (z.B. iCloud Drive oder Synology Drive), über den mehrere Geräte ihre Einkaufslisten-Änderungen austauschen. Die lokale Datenbank bleibt dabei unverändert am Standardort.")
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

            if ausgewaehlterOrdner != nil && !neustartAusstehend {
                Section {
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
                beitrittsAbgleichPruefenUndSynchronisieren()
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
        .sheet(isPresented: $zeigeBeitrittsAbgleich) {
            // Beitritts-Moment: „unterschiedlich" bleibt bewusst wirkungslos
            // (leere `aufUnterschiedlich`-Closure) — der direkt anschließende
            // reguläre Merge (``jetztSynchronisieren``) legt ein neues
            // Geschäft ganz normal selbst an, keine doppelte Aktion nötig.
            AbgleichKandidatenSheet(
                kandidaten: beitrittsKandidaten.map { kandidat in
                    AbgleichAnzeige(
                        id: kandidat.id, lokalerName: kandidat.lokalerName, fremderName: kandidat.remoteName,
                        aufGleich: { gewaehlterName in
                            SyncSnapshotImportService.geschaeftsKandidatBestaetigen(kandidat, gewaehlterName: gewaehlterName, context: modelContext)
                        },
                        aufUnterschiedlich: {}
                    )
                },
                onFertig: jetztSynchronisieren
            )
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
        .overlay {
            if pruefeBeitrittsAbgleich {
                ProgressView("Prüfe auf mögliche gleiche Geschäfte…")
                    .padding()
                    .glassCard()
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

    /// Vor dem eigentlichen Beitritts-Merge (GitHub #86, Teil 2): prüft auf
    /// mehrdeutige Geschäfts-Kandidaten (großzügige, aber nicht strenge
    /// Übereinstimmung) und fragt bei Bedarf aktiv nach, statt sie der jetzt
    /// strengeren automatischen Merge-Regel stillschweigend zu überlassen —
    /// nur für diesen einmaligen, nutzerinitiierten Beitritts-Moment, nicht
    /// für den laufenden Hintergrund-Sync (siehe `docs/GESCHAEFTSERKENNUNG.md`).
    private func beitrittsAbgleichPruefenUndSynchronisieren() {
        pruefeBeitrittsAbgleich = true
        Task {
            let kandidaten = await SyncSnapshotImportService.mehrdeutigeGeschaeftsKandidatenBeimBeitritt(context: modelContext)
            pruefeBeitrittsAbgleich = false
            if kandidaten.isEmpty {
                jetztSynchronisieren()
            } else {
                beitrittsKandidaten = kandidaten
                zeigeBeitrittsAbgleich = true
            }
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
            neustartAusstehendMachen()
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }

    /// Stoppt den Hintergrund-Sync (Polling-Loop inkl. iCloud-Beobachter
    /// sowie den Multipeer-Kanal) SOFORT, sobald eine Ersetzen-/
    /// Wiederherstellen-Aktion vorgemerkt ist — nicht erst beim Neustart.
    ///
    /// **Warum nötig, obwohl der eigentliche Datenaustausch ohnehin erst beim
    /// nächsten Prozessstart passiert** (siehe Typ-Doku ``SyncErsetzenService``):
    /// der neue Sync-Ordner-Pfad selbst (`UserDefaults`-Bookmark) ist schon
    /// beim Verknüpfen aktiv, während der In-Memory-Datenbestand
    /// (``ModelContainer``) bis zum Neustart unverändert der ALTE bleibt.
    /// Ohne diesen Stopp würde ``SyncPollingService`` in dieser Lücke
    /// weiterhin periodisch (5s/60s) und reaktiv (``SyncICloudAenderungsBeobachter``)
    /// den neuen Ordner mit dem alten, gleich zu verwerfenden Bestand
    /// bedienen — je länger der Neustart auf sich warten lässt, desto mehr
    /// Zyklen laufen unnötig. Die drei UI-Buttons unten (``zeigeOrdnerauswahl``-
    /// Formular) werden zusätzlich deaktiviert, damit auch ein manuelles
    /// „Jetzt synchronisieren" in der Zwischenzeit nicht mehr möglich ist.
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
            SyncOrdnerService.ordnerEntfernen()
            ausgewaehlterOrdner = nil
        }
    }

    private func wiederherstellenUndDeaktivieren() {
        do {
            try SyncErsetzenService.planeWiederherstellenAusBackup()
            SyncOrdnerService.ordnerEntfernen()
            ausgewaehlterOrdner = nil
            neustartAusstehendMachen()
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
            neustartAusstehendMachen()
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }
}

/// Entkoppeltes Anzeige-/Aktions-Modell für ``AbgleichKandidatenSheet`` —
/// bewusst NICHT direkt an `SyncSnapshotImportService.GeschaeftsAbgleichKandidat`
/// (transienter Beitritts-Scan, nur Geschäfte) oder ``SyncAbgleichKandidat``
/// (persistierte Warteschlange, alle drei Bereich-B-Typen) gekoppelt, damit
/// eine einzige Sheet-View beide, strukturell unterschiedlichen Quellen
/// bedienen kann — der jeweilige Aufrufer übersetzt seine Kandidaten in
/// `AbgleichAnzeige` und übergibt die passenden Aktions-Closures.
private struct AbgleichAnzeige: Identifiable {
    let id: UUID
    let lokalerName: String
    let fremderName: String
    /// Nutzer wählt „gleich", Parameter ist der beizubehaltende Name
    /// (lokaler oder fremder, je nach getroffener Wahl).
    let aufGleich: (String) -> Void
    /// Nutzer wählt „unterschiedlich" (auch der Standard bei
    /// Nicht-Entscheidung). Beim Beitritts-Abgleich bewusst ein No-Op (der
    /// direkt anschließende reguläre Merge entscheidet ohnehin), bei der
    /// laufenden Warteschlange legt es das zurückgehaltene Objekt aktiv an.
    let aufUnterschiedlich: () -> Void
}

/// Aktive Rückfrage für mehrdeutige Bereich-B-Merge-Kandidaten (Geschäft/
/// Artikel/Einkaufsliste) — sowohl beim einmaligen Sync-Ordner-Beitritt
/// (GitHub #86, Teil 2) als auch bei der laufenden, persistierten
/// ``SyncAbgleichKandidat``-Warteschlange (``SyncOrdnerSettingsView``s zwei
/// `.sheet`-Aufrufstellen). Pro Kandidat: „gleich" (mit Wahl, welcher Name
/// bleibt) oder „unterschiedlich" (Standard bei Nicht-Entscheidung) — beide
/// bleiben dann als getrennte Einträge bestehen und lassen sich bei Bedarf
/// später manuell per Löschen bereinigen, siehe `docs/GESCHAEFTSERKENNUNG.md`.
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

#Preview {
    NavigationStack {
        SyncOrdnerSettingsView()
    }
    .environmentObject(SyncPollingService())
    .environmentObject(MultipeerSyncService())
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
