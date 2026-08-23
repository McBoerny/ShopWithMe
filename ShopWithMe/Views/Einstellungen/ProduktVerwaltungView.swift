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
/// Kein SessionLeaseGate auf Listenebene — Lösch-Aktionen nutzen Micro-Leases;
/// das Session-Lease übernimmt ProduktEditView beim Öffnen als Sheet selbst.
struct ProduktVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
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
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            loeschen(produkt)
                        } label: {
                            Label("L\u{00F6}schen", systemImage: "trash")
                        }
                    }
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

    private func loeschen(_ produkt: Produkt) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                modelContext.delete(produkt)
            }
        }
    }
}

/// Sheet zum manuellen Anlegen eines neuen ``Produkt``s — wählbar aus
/// ``ProduktVerwaltungView``. Erfordert Artikel-Auswahl per ``ArtikelAuswahlSheet``,
/// da ``Produkt/artikel`` eine Pflichtbeziehung für Preishistorie und Einkaufsliste
/// darstellt.
private struct NeuesProduktSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var gewaehlterArtikel: Artikel?
    @State private var produktName = ""
    @State private var zeigeArtikelAuswahl = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Artikel") {
                    Button {
                        zeigeArtikelAuswahl = true
                    } label: {
                        HStack {
                            Text(gewaehlterArtikel?.name ?? "Bitte w\u{00E4}hlen")
                                .foregroundStyle(gewaehlterArtikel == nil ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    TextField("Name", text: $produktName)
                } footer: {
                    Text("Menschenlesbarer Klarname des Produkts, z.\u{202F}B. \u{201E}Paradontol Zahncreme\u{201C} \u{2014} unabh\u{00E4}ngig vom gesch\u{00E4}ftsspezifischen Bon-Text.")
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
                        // Live-Fund EinkaufenView (Build 308, `DatabaseLeaseService/gehoertZuAktuellemContext(_:context:)`):
                        // ein zwischenzeitliches Live-Ersetzen kann `artikel`
                        // (@State) vom aktuellen `modelContext` entkoppeln.
                        guard DatabaseLeaseService.gehoertZuAktuellemContext(artikel, context: modelContext) else { return }
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
            .sheet(isPresented: $zeigeArtikelAuswahl) {
                ArtikelAuswahlSheet(gewaehlterArtikel: $gewaehlterArtikel)
            }
        }
    }
}

/// Suchbares Auswahlsheet für einen ``Artikel`` — genutzt von ``NeuesProduktSheet``
/// und ``BelegScanView`` (GitHub #123). Zeigt bei Suchbegriffen ohne exakten Treffer
/// einen „Neu anlegen"-Button; nach dem Sichern schließt das Sheet und übergibt den
/// neuen Artikel an den Aufrufer.
///
/// Erster Verwender der generischen ``AuswahlSheet`` (GitHub #130) — reine
/// Wrapper-Konfiguration, keine eigene Listen-/Sheet-Logik mehr.
///
/// `onSelect` wird direkt beim Tippen auf einen Eintrag aufgerufen, noch vor dem
/// Dismiss — dadurch kommt die Zuweisung sicher an, auch wenn der Aufrufer sie
/// erst danach lesen würde (was Timing-Probleme verursachen kann).
struct ArtikelAuswahlSheet: View {
    @Binding var gewaehlterArtikel: Artikel?
    /// Optional ausgeschlossener Artikel (z.B. der gerade in
    /// ``ArtikelEditView`` bearbeitete, beim Zusammenführen mit einem
    /// anderen Artikel) — taucht nicht in der Auswahlliste auf.
    var ausschluss: Artikel? = nil
    /// Optionaler Callback, der bei jeder Auswahl (bestehender oder neu
    /// angelegter Artikel) aufgerufen wird. `NeuesProduktSheet` lässt diesen
    /// leer und wertet stattdessen die Binding aus. Bewusst letzter Parameter
    /// (Trailing-Closure-fähig), siehe ``ArtikelEditView``s Aufrufe.
    var onSelect: ((Artikel) -> Void)? = nil
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]

    private var waehlbareArtikel: [Artikel] {
        guard let ausschluss else { return alleArtikel }
        return alleArtikel.filter { $0.persistentModelID != ausschluss.persistentModelID }
    }

    var body: some View {
        AuswahlSheet(
            titel: "Artikel w\u{00E4}hlen",
            items: waehlbareArtikel,
            name: \.name,
            modus: .einzel(Binding(
                get: { gewaehlterArtikel },
                set: { neu in
                    gewaehlterArtikel = neu
                    if let neu { onSelect?(neu) }
                }
            )),
            suchPrompt: "Artikel suchen",
            neuAnlegenTitel: { "\u{201E}\($0)\u{201C} neu anlegen" },
            neuAnlegenInhalt: { suchtext, gesichert in
                NeuerArtikelInhalt(entwurfsname: suchtext, onGesichert: gesichert)
            }
        )
    }
}

/// Präsentiert ``ArtikelEditView`` für einen neuen ``Artikel``-Entwurf und
/// meldet den Callback erst, wenn tatsächlich gesichert wurde
/// (`entwurf.modelContext != nil` — beim bloßen Abbrechen bleibt der Entwurf
/// unverankert). Nötig, weil ``ArtikelEditView`` selbst keinen
/// Sicherungs-Callback anbietet, nur `istNeu`/eigenes `dismiss()`.
private struct NeuerArtikelInhalt: View {
    let entwurfsname: String
    let onGesichert: (Artikel) -> Void
    @State private var entwurf: Artikel?

    var body: some View {
        Group {
            if let entwurf {
                ArtikelEditView(artikel: entwurf, istNeu: true)
                    .onDisappear {
                        if entwurf.modelContext != nil {
                            onGesichert(entwurf)
                        }
                    }
            }
        }
        .onAppear {
            entwurf = Artikel(
                name: entwurfsname,
                symbolName: SymbolPalette.alle[0],
                farbeHex: Color.artikelPalette[0]
            )
        }
    }
}

#Preview {
    NavigationStack {
        ProduktVerwaltungView()
    }
    .modelContainer(for: [Artikel.self, Produkt.self, Produktname.self, Geschaeft.self, GeschaeftTyp.self, Preispunkt.self], inMemory: true)
}
