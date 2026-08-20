import SwiftUI
import SwiftData

/// Globale, durchsuchbare Verwaltung aller ``Produkt``e über alle ``Artikel``
/// hinweg (GitHub #118) — aufrufbar aus ``SettingsView``.
///
/// Anders als die "Produkte"-Sektion in ``ArtikelEditView`` (nur die Produkte
/// eines einzelnen Artikels, mit Anlegen/Löschen) zeigt diese Ansicht Produkte
/// artikelübergreifend. Neuanlage ist per „+"-Toolbar-Button möglich und erfordert
/// die Auswahl eines Artikels, da ein Produkt ohne Artikel-Kontext fachlich
/// bedeutungslos wäre. Automatisch angelegte Platzhalter-Produkte
/// (``Produkt/istStandard``) sind ausgeblendet, da sie kein vom Nutzer benanntes,
/// echtes Produkt darstellen.
///
/// Kein SessionLeaseGate auf Listenebene — die Liste ist rein lesend; das Lease
/// übernimmt ProduktEditView beim Öffnen als Sheet selbst.
struct ProduktVerwaltungView: View {
    @Query private var alleProdukte: [Produkt]
    @State private var suchtext = ""
    @State private var bearbeitetesProdukt: Produkt?
    @State private var zeigeNeuAnlage = false

    private var produkte: [Produkt] {
        let echte = alleProdukte
            .filter { !$0.istStandard }
            .sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
        guard !suchtext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return echte }
        return echte.filter { $0.name.localizedCaseInsensitiveContains(suchtext) }
    }

    var body: some View {
        List {
            // Sektionen nur ohne aktive Suche — bei Suche ist die gefilterte
            // Flachliste übersichtlicher als wenige Buchstaben-Sektionen.
            AlphabetischeListenSektion(
                produkte,
                name: \.name,
                sektionSchwelle: suchtext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 50 : .max
            ) { produkt in
                produktZeile(produkt)
            }
        }
        .searchable(text: $suchtext, prompt: "Produkt suchen")
        .overlay {
            if produkte.isEmpty {
                ContentUnavailableView(
                    suchtext.isEmpty ? "Keine Produkte" : "Keine Treffer",
                    systemImage: "shippingbox",
                    description: Text(
                        suchtext.isEmpty
                            ? "Tippe auf \u{201E}+\u{201C}, um ein neues Produkt anzulegen."
                            : "Kein Produkt passt zu \u{201E}\(suchtext)\u{201C}."
                    )
                )
            }
        }
        .navigationTitle("Produkte")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeuAnlage = true
                } label: {
                    Label("Neues Produkt", systemImage: "plus")
                }
            }
        }
        .sheet(item: $bearbeitetesProdukt) { produkt in
            ProduktEditView(produkt: produkt, istNeu: false)
        }
        .sheet(isPresented: $zeigeNeuAnlage) {
            NeuesProduktSheet()
        }
    }

    @ViewBuilder
    private func produktZeile(_ produkt: Produkt) -> some View {
        Button {
            bearbeitetesProdukt = produkt
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(produkt.name)
                        .foregroundStyle(.primary)
                    if let artikelName = produkt.artikel?.name {
                        Text(artikelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sheet zum manuellen Anlegen eines neuen ``Produkt``s — wählbar aus
/// ``ProduktVerwaltungView``. Erfordert Artikel-Auswahl, da ``Produkt/artikel``
/// eine Pflichtbeziehung für die Preishistorie und Einkaufsliste darstellt.
private struct NeuesProduktSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]

    @State private var gewaehlterArtikel: Artikel?
    @State private var produktName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Artikel") {
                    Picker("Artikel", selection: $gewaehlterArtikel) {
                        Text("Bitte wählen").tag(nil as Artikel?)
                        ForEach(alleArtikel) { artikel in
                            Text(artikel.name).tag(artikel as Artikel?)
                        }
                    }
                }
                Section {
                    TextField("Name", text: $produktName)
                } footer: {
                    Text("Menschenlesbarer Klarname des Produkts, z.\u{202F}B. \u{201E}Paradontol Zahncreme\u{201C} — unabh\u{00E4}ngig vom gesch\u{00E4}ftsspezifischen Bon-Text.")
                }
            }
            .navigationTitle("Neues Produkt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        guard let artikel = gewaehlterArtikel else { return }
                        let name = produktName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let neuesProdukt = Produkt(name: name, artikel: artikel)
                        Task {
                            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                modelContext.insert(neuesProdukt)
                            }
                            dismiss()
                        }
                    }
                    .disabled(
                        gewaehlterArtikel == nil
                            || produktName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProduktVerwaltungView()
    }
    .modelContainer(for: [Artikel.self, Produkt.self, Produktname.self, Geschaeft.self, GeschaeftTyp.self, Preispunkt.self], inMemory: true)
}
