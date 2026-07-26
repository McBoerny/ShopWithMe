import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen von Artikeln zu ``einkaufsliste``.
///
/// Bietet eine Suche über alle bereits angelegten Artikel an, alphabetisch nach
/// Anfangsbuchstaben gruppiert — bei vielen Artikeln zeigt iOS dafür automatisch
/// eine A–Z-Sprungleiste am rechten Rand, wie im Adressbuch (GitHub #8). Ein Tap
/// auf einen Artikel fügt ihn sofort zu ``einkaufsliste`` hinzu, ganz ohne
/// zusätzlichen Bestätigungsschritt — die Zeile zeigt danach „Auf Liste“ und ist
/// nicht mehr antippbar. Findet die Suche keinen exakten Treffer, kann der
/// gesuchte Artikel direkt hier angelegt werden — er landet danach ebenfalls
/// sofort auf der Liste (GitHub #6).
struct ArtikelHinzufuegenView: View {
    let einkaufsliste: Einkaufsliste

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var suchtext = ""
    /// Explizit auf `false` initialisiert und an `.searchable(isPresented:)`
    /// gebunden, damit das Suchfeld beim Öffnen dieses Sheets garantiert
    /// unfokussiert startet (GitHub #23) — unabhängig von der genauen Ursache
    /// eines gelegentlichen automatischen Aktivierens durch SwiftUI.
    @State private var sucheAktiv = false
    @State private var neuerArtikelEntwurf: Artikel?
    // SwiftUI setzt die an `.sheet(item:)` gebundene Property bereits vor dem
    // Aufruf von `onDismiss` auf `nil` zurück — ``nachNeuanlageAufraeumen`` braucht
    // daher eine eigene, davon unabhängige Referenz auf den zuletzt angelegten
    // Entwurf, um ihn nach dem Schließen des Editier-Sheets noch verarbeiten zu können.
    @State private var zuletztAngelegterEntwurf: Artikel?

    private var getrimmterSuchtext: String {
        suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gefilterteArtikel: [Artikel] {
        guard !getrimmterSuchtext.isEmpty else { return alleArtikel }
        return alleArtikel.filter { $0.name.localizedCaseInsensitiveContains(getrimmterSuchtext) }
    }

    private var existiertGenau: Bool {
        alleArtikel.contains {
            $0.name.localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame
        }
    }

    /// ``gefilterteArtikel`` gruppiert nach Anfangsbuchstaben, alphabetisch — die
    /// Grundlage für die automatische A–Z-Sprungleiste (GitHub #8).
    private var gruppierteArtikel: [(buchstabe: String, artikel: [Artikel])] {
        let gruppen = Dictionary(grouping: gefilterteArtikel) { artikel -> String in
            guard let erstesZeichen = artikel.name.first else { return "#" }
            return String(erstesZeichen).uppercased()
        }
        return gruppen.keys.sorted().map { buchstabe in (buchstabe, gruppen[buchstabe] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !getrimmterSuchtext.isEmpty && !existiertGenau {
                    Section {
                        Button {
                            neuenArtikelAnlegen()
                        } label: {
                            Label("„\(getrimmterSuchtext)“ neu anlegen", systemImage: "plus.circle.fill")
                        }
                    }
                }

                ForEach(gruppierteArtikel, id: \.buchstabe) { gruppe in
                    Section(gruppe.buchstabe) {
                        ForEach(gruppe.artikel) { artikel in
                            let bereitsAufListe = einkaufsliste.enthaelt(artikel)
                            Button {
                                hinzufuegen(artikel)
                            } label: {
                                ArtikelAuswahlZeile(artikel: artikel, bereitsAufListe: bereitsAufListe)
                            }
                            .buttonStyle(.plain)
                            .disabled(bereitsAufListe)
                        }
                    }
                }

                if gefilterteArtikel.isEmpty && getrimmterSuchtext.isEmpty {
                    ContentUnavailableView(
                        "Keine Artikel",
                        systemImage: "carrot.fill",
                        description: Text("Lege deinen ersten Artikel über die Suche an.")
                    )
                }
            }
            .searchable(text: $suchtext, isPresented: $sucheAktiv, prompt: "Artikel suchen oder anlegen")
            .navigationTitle("Artikel hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(item: $neuerArtikelEntwurf, onDismiss: nachNeuanlageAufraeumen) { entwurf in
                ArtikelEditView(artikel: entwurf, istNeu: true)
            }
        }
    }

    private func hinzufuegen(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                einkaufsliste.artikelHinzufuegen(artikel, context: modelContext)
            }
        }
    }

    private func neuenArtikelAnlegen() {
        let entwurf = Artikel(
            name: getrimmterSuchtext,
            symbolName: SymbolPalette.alle[0],
            farbeHex: Color.artikelPalette[0]
        )
        neuerArtikelEntwurf = entwurf
        zuletztAngelegterEntwurf = entwurf
    }

    /// Wurde der Entwurf tatsächlich gesichert (also in den Model-Context
    /// eingefügt), landet er sofort auf ``einkaufsliste`` (GitHub #6) — ohne
    /// zusätzlichen Tap auf „Hinzufügen”. Die Zeile zeigt danach automatisch „Auf
    /// Liste” (``ArtikelAuswahlZeile``/``bereitsAufListe``).
    private func nachNeuanlageAufraeumen() {
        defer { zuletztAngelegterEntwurf = nil }
        guard let entwurf = zuletztAngelegterEntwurf, entwurf.modelContext != nil else { return }
        hinzufuegen(entwurf)
        suchtext = ""
    }
}

/// Eine kompakte Zeile in der Artikelsuche: Kategorie-Icon/Farbe, Name und —
/// falls der Artikel bereits auf der aktuellen Einkaufsliste steht — ein Hinweis
/// statt der Möglichkeit, ihn erneut hinzuzufügen (GitHub #8).
private struct ArtikelAuswahlZeile: View {
    let artikel: Artikel
    let bereitsAufListe: Bool

    private var kategorie: ArtikelKategorie? { artikel.kategorien.first }

    var body: some View {
        HStack(spacing: 10) {
            GlassSymbolBadge(
                symbolName: kategorie?.standardSymbol ?? "shippingbox.fill",
                farbe: Color(hex: kategorie?.standardFarbeHex ?? "#8E8E93"),
                groesse: 28
            )

            Text(artikel.name)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if bereitsAufListe {
                Text("Auf Liste")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    ArtikelHinzufuegenView(einkaufsliste: Einkaufsliste(name: "Einkaufsliste"))
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
