import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen mehrerer Artikel zu ``einkaufsliste`` in einem Durchgang.
///
/// Bietet eine Suche über alle bereits angelegten Artikel an. Ein Tap auf einen
/// ganzen Artikeleintrag wählt ihn aus bzw. hebt die Auswahl wieder auf; erst
/// „Hinzufügen“ übernimmt alle ausgewählten Artikel auf einmal. Findet die Suche
/// keinen exakten Treffer, kann der gesuchte Artikel direkt hier angelegt werden —
/// er landet danach automatisch in der Auswahl.
struct ArtikelHinzufuegenView: View {
    let einkaufsliste: Einkaufsliste

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var suchtext = ""
    @State private var neuerArtikelEntwurf: Artikel?
    // SwiftUI setzt die an `.sheet(item:)` gebundene Property bereits vor dem
    // Aufruf von `onDismiss` auf `nil` zurück — ``nachNeuanlageAufraeumen`` braucht
    // daher eine eigene, davon unabhängige Referenz auf den zuletzt angelegten
    // Entwurf, um ihn nach dem Schließen des Editier-Sheets noch verarbeiten zu können.
    @State private var zuletztAngelegterEntwurf: Artikel?
    @State private var ausgewaehlteObjectIDs: Set<ObjectIdentifier> = []

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

                Section {
                    ForEach(gefilterteArtikel) { artikel in
                        let bereitsAufListe = einkaufsliste.enthaelt(artikel)
                        Button {
                            auswahlUmschalten(artikel)
                        } label: {
                            ArtikelAuswahlZeile(
                                artikel: artikel,
                                istAusgewaehlt: ausgewaehlteObjectIDs.contains(ObjectIdentifier(artikel)),
                                bereitsAufListe: bereitsAufListe
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(bereitsAufListe)
                        .listRowBackground(
                            ausgewaehlteObjectIDs.contains(ObjectIdentifier(artikel)) ? Color.accentColor.opacity(0.12) : nil
                        )
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
            .searchable(text: $suchtext, prompt: "Artikel suchen oder anlegen")
            .navigationTitle("Artikel hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        ausgewaehlteHinzufuegen()
                    } label: {
                        Text(ausgewaehlteObjectIDs.isEmpty ? "Hinzufügen" : "Hinzufügen (\(ausgewaehlteObjectIDs.count))")
                    }
                    .disabled(ausgewaehlteObjectIDs.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .sheet(item: $neuerArtikelEntwurf, onDismiss: nachNeuanlageAufraeumen) { entwurf in
                ArtikelEditView(artikel: entwurf, istNeu: true)
            }
        }
    }

    private func auswahlUmschalten(_ artikel: Artikel) {
        let id = ObjectIdentifier(artikel)
        if ausgewaehlteObjectIDs.contains(id) {
            ausgewaehlteObjectIDs.remove(id)
        } else {
            ausgewaehlteObjectIDs.insert(id)
        }
    }

    private func ausgewaehlteHinzufuegen() {
        let ausgewaehlteArtikel = alleArtikel.filter { ausgewaehlteObjectIDs.contains(ObjectIdentifier($0)) }
        guard !ausgewaehlteArtikel.isEmpty else { return }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                for artikel in ausgewaehlteArtikel {
                    einkaufsliste.artikelHinzufuegen(artikel, context: modelContext)
                }
            }
            dismiss()
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
    /// eingefügt), wandert er automatisch in die Auswahl — übernommen wird er wie
    /// jeder andere ausgewählte Artikel erst beim Tap auf „Hinzufügen“.
    private func nachNeuanlageAufraeumen() {
        defer { zuletztAngelegterEntwurf = nil }
        guard let entwurf = zuletztAngelegterEntwurf, entwurf.modelContext != nil else { return }
        ausgewaehlteObjectIDs.insert(ObjectIdentifier(entwurf))
        suchtext = ""
    }
}

/// Eine Zeile in der Artikelsuche: zeigt Kategorie-Icon/Farbe, den Auswahlstatus
/// (Kreis/Haken rechts) und — falls der Artikel bereits auf der aktuellen
/// Einkaufsliste steht — einen Hinweis statt der Auswahlmöglichkeit.
private struct ArtikelAuswahlZeile: View {
    let artikel: Artikel
    let istAusgewaehlt: Bool
    let bereitsAufListe: Bool

    private var kategorie: ArtikelKategorie? { artikel.kategorie }

    var body: some View {
        HStack(spacing: 12) {
            GlassSymbolBadge(
                symbolName: kategorie?.standardSymbol ?? "shippingbox.fill",
                farbe: Color(hex: kategorie?.standardFarbeHex ?? "#8E8E93"),
                groesse: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name)
                    .foregroundStyle(.primary)
                if let kategorie {
                    Text(kategorie.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if bereitsAufListe {
                Text("Auf Liste")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: istAusgewaehlt ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(istAusgewaehlt ? Color.accentColor : Color.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

#Preview {
    ArtikelHinzufuegenView(einkaufsliste: Einkaufsliste(name: "Einkaufsliste"))
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
