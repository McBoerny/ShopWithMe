import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Importiert eine MilkForUs-Textexport-Datei (siehe `docs/MILKFORUS_IMPORT.md`):
/// Datei wählen oder — vom Aufrufer vorbefüllten Text (siehe ``initialText``, von der
/// Share Extension übergeben) — direkt verarbeiten, dann parsen, für jede darin
/// vorkommende Kategorie eine ``KategorieZuordnung`` vorschlagen, in einer Vorschau
/// prüfen/korrigieren lassen und abschließend auf eine gewählte ``Einkaufsliste``
/// übernehmen.
struct MilkForUsImportView: View {
    /// Vorbefüllter Dateiinhalt — überspringt den Datei-Picker-Schritt. Wird gesetzt,
    /// wenn der Import über die Teilen-Funktion (``ShopWithMeShareExtension``) statt
    /// über den manuellen Datei-Picker angestoßen wurde.
    var initialText: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Query(sort: \Einkaufsliste.erstelltAm) private var alleListen: [Einkaufsliste]

    @State private var zeigeDateiPicker = false
    @State private var laedt = false
    @State private var uebernimmt = false
    /// Fortschritt der jeweils laufenden Phase (Kategorieabgleich ODER
    /// Übernehmen) — `nil` außerhalb beider Phasen bzw. kurz vor dem allerersten
    /// Fortschritts-Callback (siehe ``MilkForUsImportService``).
    @State private var fortschritt: (erledigt: Int, gesamt: Int)?
    @State private var fehlermeldung: String?
    @State private var gruppen: [MilkForUsKategorieGruppe]?
    @State private var zielListe: Einkaufsliste?

    private var kannUebernehmen: Bool {
        !uebernimmt && zielListe != nil && !(gruppen?.allSatisfy { $0.artikelNamen.isEmpty } ?? true)
    }

    var body: some View {
        NavigationStack {
            Group {
                if uebernimmt {
                    FortschrittsAnsicht(titel: "Artikel werden übernommen…", fortschritt: fortschritt)
                } else if let gruppen {
                    VorschauListe(
                        gruppen: Binding(get: { gruppen }, set: { self.gruppen = $0 }),
                        bestehendeKategorien: alleKategorien,
                        bestehendeArtikelNamen: Set(alleArtikel.map { $0.name.lowercased() }),
                        alleListen: alleListen,
                        zielListe: $zielListe
                    )
                } else {
                    StartAnsicht(laedt: laedt, fortschritt: fortschritt, fehlermeldung: fehlermeldung) {
                        zeigeDateiPicker = true
                    }
                }
            }
            .navigationTitle("MilkForUs importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .disabled(uebernimmt)
                }
                if gruppen != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Importieren", action: uebernehmen)
                            .disabled(!kannUebernehmen)
                    }
                }
            }
        }
        .fileImporter(isPresented: $zeigeDateiPicker, allowedContentTypes: [.plainText]) { ergebnis in
            switch ergebnis {
            case .success(let url):
                lade(von: url)
            case .failure(let error):
                fehlermeldung = error.localizedDescription
            }
        }
        .task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                zielListe = Einkaufsliste.standard(context: modelContext)
            }
            if let initialText {
                verarbeite(text: initialText)
            }
        }
    }

    private func lade(von url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            fehlermeldung = "Die Datei konnte nicht gelesen werden."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            verarbeite(text: text)
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }

    private func verarbeite(text: String) {
        laedt = true
        fehlermeldung = nil
        fortschritt = nil
        Task {
            defer {
                laedt = false
                fortschritt = nil
            }
            let eintraege = MilkForUsParser.parsen(text: text)
            guard !eintraege.isEmpty else {
                fehlermeldung = "In dieser Datei wurden keine Artikel gefunden."
                return
            }
            gruppen = await MilkForUsImportService.gruppenMitVorschlag(
                aus: eintraege,
                bestehendeKategorien: alleKategorien
            ) { erledigt, gesamt in
                fortschritt = (erledigt, gesamt)
            }
        }
    }

    private func uebernehmen() {
        guard let gruppen, let zielListe else { return }
        // Live-Fund EinkaufenView (Build 308, `DatabaseLeaseService/gehoertZuAktuellemContext(_:context:)`).
        guard DatabaseLeaseService.gehoertZuAktuellemContext(zielListe, context: modelContext) else { return }
        uebernimmt = true
        fortschritt = nil
        Task {
            await MilkForUsImportService.uebernehmen(
                gruppen: gruppen,
                in: zielListe,
                context: modelContext
            ) { erledigt, gesamt in
                fortschritt = (erledigt, gesamt)
            }
            dismiss()
        }
    }
}

/// Fortschrittsanzeige für beide (potenziell lange) Import-Phasen — Kategorieabgleich
/// und abschließendes Übernehmen (GitHub-Nutzerbericht 2026-08-24, sehr große
/// MilkForUs-Listen). Solange `fortschritt` noch `nil` ist (kurzes Zeitfenster vor
/// dem allerersten Callback, siehe ``MilkForUsImportService``), erscheint ein
/// unbestimmter Spinner statt eines Balkens bei 0%.
private struct FortschrittsAnsicht: View {
    let titel: String
    let fortschritt: (erledigt: Int, gesamt: Int)?

    var body: some View {
        VStack(spacing: 16) {
            if let fortschritt, fortschritt.gesamt > 0 {
                ProgressView(value: Double(fortschritt.erledigt), total: Double(fortschritt.gesamt))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
                Text("\(fortschritt.erledigt) von \(fortschritt.gesamt)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(titel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Aufforderung, eine MilkForUs-Textdatei auszuwählen.
private struct StartAnsicht: View {
    let laedt: Bool
    let fortschritt: (erledigt: Int, gesamt: Int)?
    let fehlermeldung: String?
    let dateiWaehlen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if laedt {
                FortschrittsAnsicht(titel: "Kategorien werden abgeglichen…", fortschritt: fortschritt)
            } else {
                ContentUnavailableView {
                    Label("MilkForUs-Liste importieren", systemImage: "square.and.arrow.down.on.square")
                } description: {
                    Text("Wähle eine aus MilkForUs exportierte Textdatei — Artikel und Abteilungen werden automatisch mit deinem Bestand abgeglichen.")
                } actions: {
                    Button("Datei auswählen", action: dateiWaehlen)
                        .buttonStyle(.glass)
                }
                if let fehlermeldung {
                    Text(fehlermeldung)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }
}

/// Editierbare Vorschau der geparsten Kategorien/Artikel zur Kontrolle vor dem
/// Übernehmen — analog zur ``BelegScanView``-`ErgebnisListe`.
private struct VorschauListe: View {
    @Binding var gruppen: [MilkForUsKategorieGruppe]
    let bestehendeKategorien: [ArtikelKategorie]
    let bestehendeArtikelNamen: Set<String>
    let alleListen: [Einkaufsliste]
    @Binding var zielListe: Einkaufsliste?

    var body: some View {
        List {
            ForEach($gruppen) { $gruppe in
                Section {
                    ForEach(gruppe.artikelNamen, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Text(bestehendeArtikelNamen.contains(name.lowercased()) ? "vorhanden" : "neu")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { gruppe.artikelNamen.remove(atOffsets: $0) }
                } header: {
                    KategorieZuordnungsMenu(gruppe: $gruppe, bestehendeKategorien: bestehendeKategorien)
                }
            }

            Section {
                Picker("Zielliste", selection: $zielListe) {
                    ForEach(alleListen) { liste in
                        Text(liste.name).tag(Optional(liste))
                    }
                }
            } footer: {
                Text("Abteilung antippen, um sie einer bestehenden Abteilung oder „Sonstiges“ zuzuordnen, statt eine neue anzulegen. Nicht benötigte Artikel nach links wischen.")
            }
        }
    }
}

/// Menü im Section-Header zum Umstellen der ``KategorieZuordnung`` einer Gruppe.
private struct KategorieZuordnungsMenu: View {
    @Binding var gruppe: MilkForUsKategorieGruppe
    let bestehendeKategorien: [ArtikelKategorie]

    var body: some View {
        Menu {
            if !gruppe.kategorieName.isEmpty {
                Button {
                    gruppe.zuordnung = .neuAnlegen(name: gruppe.kategorieName)
                } label: {
                    Label("Neu anlegen: „\(gruppe.kategorieName)“", systemImage: "plus")
                }
            }
            Button {
                gruppe.zuordnung = .sonstige
            } label: {
                Label("Sonstiges verwenden", systemImage: "shippingbox")
            }
            if !bestehendeKategorien.isEmpty {
                Divider()
                ForEach(bestehendeKategorien) { kategorie in
                    Button(kategorie.name) {
                        gruppe.zuordnung = .bestehend(kategorie)
                    }
                }
            }
        } label: {
            HStack {
                Text(gruppe.kategorieName.isEmpty ? "Ohne Abteilung" : gruppe.kategorieName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                Spacer()
                Text(zuordnungsLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    private var zuordnungsLabel: String {
        switch gruppe.zuordnung {
        case .bestehend(let kategorie): kategorie.name
        case .neuAnlegen(let name): "neu: \(name)"
        case .sonstige: "Sonstiges"
        }
    }
}
