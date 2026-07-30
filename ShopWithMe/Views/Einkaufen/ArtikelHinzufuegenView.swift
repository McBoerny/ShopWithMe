import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen von Artikeln zu ``einkaufsliste``.
///
/// Bietet eine Suche über alle bereits angelegten Artikel an (Singular/Plural-
/// unabhängig, siehe ``String/passtAlsSingularPluralZu(_:)``, GitHub #44),
/// alphabetisch nach Anfangsbuchstaben gruppiert — bei vielen Artikeln zeigt
/// iOS dafür automatisch eine A–Z-Sprungleiste am rechten Rand, wie im
/// Adressbuch (GitHub #8). Ein Tap auf einen Artikel fügt ihn sofort zu
/// ``einkaufsliste`` hinzu, ganz ohne zusätzlichen Bestätigungsschritt — die
/// Zeile zeigt danach das Standard-Abhak-Symbol und bleibt tappbar, um den
/// Artikel wieder zu entfernen (echtes An-/Abwähl-Toggle, GitHub #45). Findet
/// die Suche keinen exakten Treffer, kann der gesuchte Artikel direkt hier
/// angelegt werden — er landet danach ebenfalls sofort auf der Liste
/// (GitHub #6).
struct ArtikelHinzufuegenView: View {
    let einkaufsliste: Einkaufsliste

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var suchtext = ""
    /// Bleibt nach einer Artikel-Auswahl auf dem bisherigen Suchtext stehen,
    /// solange ``filterEinfrieren`` aktiv ist — verhindert, dass die Trefferliste
    /// sofort auf die volle unfilterte Ansicht zurückfällt, bevor der Nutzer das
    /// nächste Zeichen tippt (GitHub #64).
    @State private var wirksamerSuchtext = ""
    /// Unterdrückt genau eine Aktualisierung von ``wirksamerSuchtext`` — gesetzt
    /// unmittelbar bevor `suchtext` nach einer Auswahl programmatisch geleert wird.
    @State private var filterEinfrieren = false
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
        wirksamerSuchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Zusätzlich zum Teilstring-Vergleich auch Singular/Plural-unabhängig
    /// (GitHub #44, ``String/passtAlsSingularPluralZu(_:)``) — pro Wort des
    /// Artikelnamens, damit auch mehrteilige Namen (z.B. "Roter Apfel") erfasst
    /// werden, wenn nach "Äpfel" gesucht wird.
    private var gefilterteArtikel: [Artikel] {
        guard !getrimmterSuchtext.isEmpty else { return alleArtikel }
        return alleArtikel.filter { artikel in
            artikel.name.localizedCaseInsensitiveContains(getrimmterSuchtext)
                || artikel.name.split(separator: " ").contains {
                    String($0).passtAlsSingularPluralZu(getrimmterSuchtext)
                }
        }
    }

    private var existiertGenau: Bool {
        alleArtikel.contains {
            $0.name.localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame
        }
    }

    /// ``gefilterteArtikel`` gruppiert nach Anfangsbuchstaben, alphabetisch — die
    /// Grundlage für die automatische A–Z-Sprungleiste (GitHub #8). Umlaute
    /// einsortiert bei ihrem Basisbuchstaben (GitHub #34).
    private var gruppierteArtikel: [(buchstabe: String, artikel: [Artikel])] {
        let sortiert = gefilterteArtikel.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
        let gruppen = Dictionary(grouping: sortiert) { $0.name.alphabetischerAnfangsbuchstabe }
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
                                if bereitsAufListe {
                                    entfernen(artikel)
                                } else {
                                    hinzufuegen(artikel)
                                }
                                suchfeldFuerNaechsteEingabeZuruecksetzen()
                            } label: {
                                ArtikelAuswahlZeile(artikel: artikel, bereitsAufListe: bereitsAufListe)
                            }
                            .buttonStyle(.plain)
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
            .onChange(of: suchtext) { _, neuerText in
                if filterEinfrieren {
                    filterEinfrieren = false
                } else {
                    wirksamerSuchtext = neuerText
                }
            }
            .onChange(of: sucheAktiv) { _, aktiv in
                if !aktiv {
                    wirksamerSuchtext = suchtext
                }
            }
            .navigationTitle("Artikel hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Eigener zweizeiliger Titel (Name der Einkaufsliste darunter,
                // GitHub #45) statt des einzeiligen `.navigationTitle` —
                // `.navigationTitle` bleibt trotzdem gesetzt, dient hier nur noch
                // als Accessibility-Titel.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Artikel hinzufügen")
                            .font(.headline)
                        Text(einkaufsliste.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        // Nur die Identitäten über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — während des Micro-Lease-Erwerbs kann ein
        // nebenläufiger Sync-Zyklus Artikel oder Einkaufsliste gelöscht haben.
        let artikelReferenz = ModelReference(artikel)
        let einkaufslisteReferenz = ModelReference(einkaufsliste)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let artikelFrisch = artikelReferenz.resolved(in: modelContext),
                      let einkaufslisteFrisch = einkaufslisteReferenz.resolved(in: modelContext)
                else { return }
                einkaufslisteFrisch.artikelHinzufuegen(artikelFrisch, context: modelContext)
            }
        }
    }

    /// Nimmt `artikel` wieder von ``einkaufsliste`` — Gegenstück zu
    /// ``hinzufuegen(_:)``, macht die Zeile hier zu einem echten An-/Abwähl-
    /// Toggle statt eines einmaligen Hinzufügens (GitHub #45).
    private func entfernen(_ artikel: Artikel) {
        let artikelReferenz = ModelReference(artikel)
        let einkaufslisteReferenz = ModelReference(einkaufsliste)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let artikelFrisch = artikelReferenz.resolved(in: modelContext),
                      let einkaufslisteFrisch = einkaufslisteReferenz.resolved(in: modelContext)
                else { return }
                einkaufslisteFrisch.artikelEntfernen(artikelFrisch, context: modelContext)
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
    /// zusätzlichen Tap auf „Hinzufügen”. Die Zeile zeigt danach automatisch das
    /// Abhak-Symbol (``ArtikelAuswahlZeile``/``bereitsAufListe``).
    private func nachNeuanlageAufraeumen() {
        defer { zuletztAngelegterEntwurf = nil }
        guard let entwurf = zuletztAngelegterEntwurf, entwurf.modelContext != nil else { return }
        hinzufuegen(entwurf)
        suchfeldFuerNaechsteEingabeZuruecksetzen()
    }

    /// Leert `suchtext` nach einer Auswahl, friert aber ``wirksamerSuchtext`` auf
    /// dem bisherigen Wert ein — die Trefferliste bleibt so stehen, bis der
    /// Nutzer das nächste Zeichen tippt (GitHub #64).
    private func suchfeldFuerNaechsteEingabeZuruecksetzen() {
        filterEinfrieren = true
        suchtext = ""
    }
}

/// Eine kompakte Zeile in der Artikelsuche: Kategorie-Icon/Farbe, Name und das
/// App-weit einheitliche Abhak-Symbol (GitHub #8), das anzeigt, ob der Artikel
/// bereits auf der aktuellen Einkaufsliste steht — Tippen schaltet um
/// (GitHub #45).
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

            Image(systemName: bereitsAufListe ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(bereitsAufListe ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    ArtikelHinzufuegenView(einkaufsliste: Einkaufsliste(name: "Einkaufsliste"))
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
