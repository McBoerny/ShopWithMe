import SwiftUI
import SwiftData

/// Globale, durchsuchbare Verwaltung aller ``Produkt``e über alle ``Artikel``
/// hinweg (GitHub #118) — aufrufbar aus ``SettingsView``.
///
/// Anders als die "Produkte"-Sektion in ``ArtikelEditView`` (nur die Produkte
/// eines einzelnen Artikels, mit Anlegen/Löschen) ist diese Ansicht rein
/// such-/bearbeitungsorientiert und zeigt Produkte artikelübergreifend.
/// Anlegen und Löschen bleiben bewusst exklusiv bei ``ArtikelEditView`` — ein
/// Produkt ohne Artikel-Kontext anzulegen ergibt fachlich keinen Sinn.
/// Automatisch angelegte Platzhalter-Produkte (``Produkt/istStandard``) sind
/// ausgeblendet, da sie kein vom Nutzer benanntes, echtes Produkt darstellen.
///
/// Kein SessionLeaseGate auf Listenebene — die Liste ist rein lesend; das Lease
/// übernimmt ProduktEditView beim Öffnen als Sheet selbst.
struct ProduktVerwaltungView: View {
    @Query(sort: \Produkt.name) private var alleProdukte: [Produkt]
    @State private var suchtext = ""
    @State private var bearbeitetesProdukt: Produkt?

    private var produkte: [Produkt] {
        let echte = alleProdukte.filter { !$0.istStandard }
        guard !suchtext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return echte }
        return echte.filter { $0.name.localizedCaseInsensitiveContains(suchtext) }
    }

    var body: some View {
        List {
            ForEach(produkte) { produkt in
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
        .searchable(text: $suchtext, prompt: "Produkt suchen")
        .overlay {
            if produkte.isEmpty {
                ContentUnavailableView(
                    suchtext.isEmpty ? "Keine Produkte" : "Keine Treffer",
                    systemImage: "shippingbox",
                    description: Text(
                        suchtext.isEmpty
                            ? "Produkte werden je Artikel angelegt."
                            : "Kein Produkt passt zu \u{201E}\(suchtext)\u{201D}."
                    )
                )
            }
        }
        .navigationTitle("Produkte")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $bearbeitetesProdukt) { produkt in
            ProduktEditView(produkt: produkt, istNeu: false)
        }
    }
}

#Preview {
    NavigationStack {
        ProduktVerwaltungView()
    }
    .modelContainer(for: [Artikel.self, Produkt.self, Produktname.self, Geschaeft.self, GeschaeftTyp.self, Preispunkt.self], inMemory: true)
}
