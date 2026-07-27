import SwiftUI
import SwiftData

/// Anlegen/Bearbeiten eines ``Artikel``s.
///
/// Bei einem neuen Artikel (`istNeu == true`) wird er erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft ihn folgenlos). Die Kategorien
/// (Mehrfachauswahl möglich) sind sowohl beim Anlegen als auch danach frei
/// wählbar.
struct ArtikelEditView: View {
    @Bindable var artikel: Artikel
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var kategorien: [ArtikelKategorie]
    @Query private var kaufHistorie: [KaufEintrag]

    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?
    @State private var zeigeNeueKategorie = false

    init(artikel: Artikel, istNeu: Bool) {
        self.artikel = artikel
        self.istNeu = istNeu
        let artikelID = artikel.persistentModelID
        _kaufHistorie = Query(
            filter: #Predicate<KaufEintrag> { $0.artikel?.persistentModelID == artikelID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

    var body: some View {
        if istNeu {
            navigationInhalt
        } else {
            SessionLeaseGate { navigationInhalt }
        }
    }

    private var navigationInhalt: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $artikel.name)
                        .font(.title3)
                }

                Section {
                    ForEach(kategorien) { kategorie in
                        Button {
                            kategorieToggeln(kategorie)
                        } label: {
                            HStack {
                                Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if artikel.kategorien.contains(kategorie) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        zeigeNeueKategorie = true
                    } label: {
                        Label("Neue Kategorie anlegen", systemImage: "plus")
                    }

                    if kiVorschlagLaeuft {
                        HStack {
                            ProgressView()
                            Text("Apple Intelligence schlägt eine Kategorie vor…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let kiFehlermeldung {
                        Text(kiFehlermeldung)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Mehrfachauswahl möglich. Ohne Auswahl landet der Artikel automatisch in „Sonstiges“.")
                }

                Section("Menge & Einheit") {
                    Picker("Einheit", selection: $artikel.einheit) {
                        ForEach(Einheit.allCases) { einheit in
                            Text(einheit.anzeigename).tag(einheit)
                        }
                    }
                    HStack {
                        Text("Standardmenge")
                        Spacer()
                        TextField("Menge", value: $artikel.mengenSchritt, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(artikel.einheit.kurzform)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notiz") {
                    TextField(
                        "Optionale Notiz, z.B. bevorzugte Marke",
                        text: Binding(
                            get: { artikel.notiz ?? "" },
                            set: { artikel.notiz = $0.isEmpty ? nil : $0 }
                        ),
                        axis: .vertical
                    )
                }

                if !istNeu && !kaufHistorie.isEmpty {
                    Section("Preishistorie") {
                        ForEach(kaufHistorie) { eintrag in
                            PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: false)
                        }
                    }
                }
            }
            .navigationTitle(istNeu ? "Neuer Artikel" : artikel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if istNeu {
                            Task {
                                await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                    modelContext.insert(artikel)
                                }
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(artikel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task(id: artikel.name) {
                await kategorieAutomatischVorschlagen()
            }
            .sheet(isPresented: $zeigeNeueKategorie) {
                NeueKategorieSheet(naechsterSortIndex: (kategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                    artikel.kategorien.append(kategorie)
                }
            }
        }
    }

    private func kategorieToggeln(_ kategorie: ArtikelKategorie) {
        var aktuelle = artikel.kategorien
        if let index = aktuelle.firstIndex(of: kategorie) {
            aktuelle.remove(at: index)
        } else {
            aktuelle.append(kategorie)
        }
        artikel.kategorien = aktuelle
    }

    /// Bestimmt automatisch (ohne manuellen Anstoß) eine Kategorie für einen neuen
    /// Artikel, sobald Apple Intelligence verfügbar ist — entprellt um 600ms, damit
    /// nicht bei jedem Tastenanschlag ein KI-Aufruf losgeschickt wird. SwiftUI
    /// storniert diesen Task automatisch, sobald sich `artikel.name` erneut ändert
    /// (`.task(id:)`). Überschreibt niemals eine bereits (manuell oder von einem
    /// vorherigen Durchlauf) gesetzte Kategorie.
    private func kategorieAutomatischVorschlagen() async {
        guard istNeu, AISuggestionService.istVerfuegbar, artikel.kategorien.isEmpty else { return }
        let name = artikel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, artikel.kategorien.isEmpty else { return }

        kiVorschlagLaeuft = true
        kiFehlermeldung = nil
        defer { kiVorschlagLaeuft = false }

        do {
            let vorschlag = try await AISuggestionService.vorschlag(
                fuerArtikelName: name,
                bekannteKategorien: kategorien.map(\.name)
            )
            guard !Task.isCancelled, artikel.kategorien.isEmpty else { return }

            if let passendeKategorie = kategorien.first(where: {
                $0.name.localizedCaseInsensitiveCompare(vorschlag.kategorieName) == .orderedSame
            }) {
                artikel.kategorien = [passendeKategorie]
            }
        } catch {
            kiFehlermeldung = "KI-Vorschlag nicht verfügbar: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ArtikelEditView(
        artikel: Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA"),
        istNeu: true
    )
    .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
