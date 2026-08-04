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
    @State private var fehlermeldung: String?
    @State private var gruppen: [MilkForUsKategorieGruppe]?
    @State private var zielListe: Einkaufsliste?

    var body: some View {
        NavigationStack {
            Group {
                if let gruppen {
                    VorschauListe(
                        gruppen: Binding(get: { gruppen }, set: { self.gruppen = $0 }),
                        bestehendeKategorien: alleKategorien,
                        bestehendeArtikelNamen: Set(alleArtikel.map { $0.name.lowercased() }),
                        alleListen: alleListen,
                        zielListe: $zielListe,
                        uebernehmen: uebernehmen
                    )
                } else {
                    StartAnsicht(laedt: laedt, fehlermeldung: fehlermeldung) {
                        zeigeDateiPicker = true
                    }
                }
            }
            .navigationTitle("MilkForUs importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
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
        Task {
            defer { laedt = false }
            let eintraege = MilkForUsParser.parsen(text: text)
            guard !eintraege.isEmpty else {
                fehlermeldung = "In dieser Datei wurden keine Artikel gefunden."
                return
            }
            gruppen = await MilkForUsImportService.gruppenMitVorschlag(aus: eintraege, bestehendeKategorien: alleKategorien)
        }
    }

    private func uebernehmen() {
        guard let gruppen, let zielListe else { return }
        Task {
            await MilkForUsImportService.uebernehmen(gruppen: gruppen, in: zielListe, context: modelContext)
            dismiss()
        }
    }
}

/// Aufforderung, eine MilkForUs-Textdatei auszuwählen.
private struct StartAnsicht: View {
    let laedt: Bool
    let fehlermeldung: String?
    let dateiWaehlen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if laedt {
                ProgressView("Datei wird verarbeitet…")
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
    let uebernehmen: () -> Void

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
        .safeAreaInset(edge: .bottom) {
            Button("Importieren", action: uebernehmen)
                .buttonStyle(.glass)
                .padding()
                .disabled(zielListe == nil || gruppen.allSatisfy { $0.artikelNamen.isEmpty })
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
