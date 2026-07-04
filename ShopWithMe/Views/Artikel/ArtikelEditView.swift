import SwiftUI
import SwiftData
import UIKit

/// Anlegen/Bearbeiten eines ``Artikel``s.
///
/// Bei einem neuen Artikel (`istNeu == true`) wird er erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft ihn folgenlos). Die Kategorie ist
/// sowohl beim Anlegen als auch danach frei wählbar.
struct ArtikelEditView: View {
    @Bindable var artikel: Artikel
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var kategorien: [ArtikelKategorie]
    @Query private var alleRegale: [Regal]
    @Query private var kaufHistorie: [KaufEintrag]

    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?
    @State private var kiRegalHinweis: String?

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
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: artikel.symbolName, farbe: Color(hex: artikel.farbeHex), groesse: 56)
                        TextField("Name", text: $artikel.name)
                            .font(.title3)
                    }
                    SymbolFarbAuswahlZeile(symbolName: $artikel.symbolName, farbeHex: $artikel.farbeHex)
                }

                if istNeu && AISuggestionService.istVerfuegbar {
                    Section {
                        Button {
                            kiVorschlagAnfordern()
                        } label: {
                            if kiVorschlagLaeuft {
                                HStack {
                                    ProgressView()
                                    Text("Apple Intelligence denkt nach…")
                                }
                            } else {
                                Label("Mit Apple Intelligence vorschlagen", systemImage: "sparkles")
                            }
                        }
                        .disabled(kiVorschlagLaeuft || artikel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let kiRegalHinweis {
                            Text(kiRegalHinweis)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let kiFehlermeldung {
                            Text(kiFehlermeldung)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Picker("Kategorie", selection: $artikel.kategorie) {
                        Text("Keine Auswahl").tag(ArtikelKategorie?.none)
                        ForEach(kategorien) { kategorie in
                            Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                .tag(Optional(kategorie))
                        }
                    }
                } footer: {
                    Text("Ohne Auswahl landet der Artikel automatisch in „Sonstiges“.")
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

                Section {
                    Toggle("Auf Einkaufsliste", isOn: $artikel.istAufEinkaufsliste)
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
                            modelContext.insert(artikel)
                        }
                        dismiss()
                    }
                    .disabled(artikel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func kiVorschlagAnfordern() {
        kiVorschlagLaeuft = true
        kiFehlermeldung = nil
        kiRegalHinweis = nil
        let name = artikel.name
        let bekannteKategorien = kategorien.map(\.name)
        let bekannteRegale = Set(alleRegale.map(\.name)).sorted()

        Task {
            defer { kiVorschlagLaeuft = false }
            do {
                let vorschlag = try await AISuggestionService.vorschlag(
                    fuerArtikelName: name,
                    bekannteKategorien: bekannteKategorien,
                    bekannteRegale: bekannteRegale
                )

                if UIImage(systemName: vorschlag.symbolName) != nil {
                    artikel.symbolName = vorschlag.symbolName
                }
                if vorschlag.farbeHex.count == 7, vorschlag.farbeHex.hasPrefix("#") {
                    artikel.farbeHex = vorschlag.farbeHex
                }
                if let passendeKategorie = kategorien.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(vorschlag.kategorieName) == .orderedSame
                }) {
                    artikel.kategorie = passendeKategorie
                }
                if !vorschlag.regalName.isEmpty {
                    kiRegalHinweis = "Vorschlag: Regal „\(vorschlag.regalName)“ — bitte in den Geschäften prüfen/zuordnen."
                }
            } catch {
                kiFehlermeldung = "KI-Vorschlag nicht verfügbar: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    ArtikelEditView(
        artikel: Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA"),
        istNeu: true
    )
    .modelContainer(for: [Artikel.self, ArtikelKategorie.self], inMemory: true)
}
