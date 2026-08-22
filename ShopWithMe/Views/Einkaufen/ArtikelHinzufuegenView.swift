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
/// Artikel wieder zu entfernen (echtes An-/Abwähl-Toggle, GitHub #45). Hat ein
/// Artikel Produkte, erscheint ein Chevron — Tippen klappt die Produktliste
/// inline aus, sodass ein konkretes Produkt direkt in der Liste gewählt werden
/// kann. Sucht man nach einem Produktnamen (z.B. „Sebamed"), erscheint der
/// zugehörige Artikel automatisch aufgeklappt. Findet die Suche keinen
/// exakten Treffer, kann der gesuchte Artikel direkt hier angelegt werden —
/// er landet danach ebenfalls sofort auf der Liste (GitHub #6).
/// Für bereits auf der Liste stehende Artikel (ohne spezifisches Produkt) und
/// für ausgewählte Produktzeilen zeigt ein Tap auf die Mengenangabe links vom
/// Haken ``MengenNotizSheet`` — identisch zur Funktion beim Einkaufen (GitHub #124).
struct ArtikelHinzufuegenView: View {
    let einkaufsliste: Einkaufsliste

    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Query private var alleProdukte: [Produkt]
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
    /// Auf `true` initialisiert, damit die Tastatur beim Öffnen des Sheets
    /// sofort erscheint und der Nutzer direkt tippen kann.
    @State private var sucheAktiv = true
    @State private var neuerArtikelEntwurf: Artikel?
    /// SwiftUI setzt die an `.sheet(item:)` gebundene Property bereits vor dem
    /// Aufruf von `onDismiss` auf `nil` zurück — ``nachNeuanlageAufraeumen`` braucht
    /// daher eine eigene, davon unabhängige Referenz auf den zuletzt angelegten
    /// Entwurf, um ihn nach dem Schließen des Editier-Sheets noch verarbeiten zu können.
    @State private var zuletztAngelegterEntwurf: Artikel?
    /// Steuert das inline Aufklappen der Produktliste je Artikel. XOR-Verknüpfung
    /// mit dem Auto-Aufklapp-Zustand (``trefferNurUeberProdukt(_:)``): ein Eintrag
    /// hier kehrt den jeweiligen Standardzustand um — manuell aufklappen wenn
    /// kein Produkttreffer, manuell zuklappen wenn Produkttreffer.
    @State private var umgeklappteArtikel: Set<UUID> = []
    /// Der Eintrag, dessen Menge/Notiz gerade per ``MengenNotizSheet`` bearbeitet
    /// wird — `nil` wenn kein Sheet offen (GitHub #124).
    @State private var zuVerfeinernderEintrag: EinkaufslistenEintrag?
    @State private var zeigeVerfeinerungsSheet = false

    private var getrimmterSuchtext: String {
        wirksamerSuchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Zusätzlich zum Teilstring-Vergleich auch Singular/Plural-unabhängig
    /// (GitHub #44, ``String/passtAlsSingularPluralZu(_:)``) — pro Wort des
    /// Artikelnamens, damit auch mehrteilige Namen (z.B. "Roter Apfel") erfasst
    /// werden, wenn nach "Äpfel" gesucht wird. Zusätzlich über gepflegte
    /// ``Artikel/alternativeNamen`` (GitHub #111/#128, z.B. "Zahncreme" für
    /// "Zahnpasta") und über Produktnamen (z.B. "Sebamed" für "Shampoo") —
    /// derselbe Artikel bleibt dabei einmalig in der Ergebnisliste.
    private var gefilterteArtikel: [Artikel] {
        guard !getrimmterSuchtext.isEmpty else { return alleArtikel }
        return alleArtikel.filter { artikel in
            artikel.name.localizedCaseInsensitiveContains(getrimmterSuchtext)
                || artikel.name.split(separator: " ").contains {
                    String($0).passtAlsSingularPluralZu(getrimmterSuchtext)
                }
                || artikel.alternativeNamen.contains {
                    $0.localizedCaseInsensitiveContains(getrimmterSuchtext)
                }
                || alleProdukte.contains {
                    $0.artikel == artikel && !$0.istStandard && $0.elternProdukt == nil
                        && $0.name.localizedCaseInsensitiveContains(getrimmterSuchtext)
                }
        }
    }

    /// Eigene, oberste-Ebene-Produkte von `artikel` (GitHub #47) — ohne das
    /// automatisch angelegte Platzhalter-Produkt (``Produkt/istStandard``) und
    /// ohne Unter-Produkte (keine Rekursions-UI, siehe ``ProduktEditView``).
    private func produkte(fuer artikel: Artikel) -> [Produkt] {
        alleProdukte.filter { $0.artikel == artikel && !$0.istStandard && $0.elternProdukt == nil }
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

    /// `true` wenn `artikel` in ``gefilterteArtikel`` ausschließlich über einen
    /// Produktnamen taucht — Grundlage für das automatische Aufklappen der
    /// Produktliste, damit der Treffer sofort sichtbar ist.
    private func trefferNurUeberProdukt(_ artikel: Artikel) -> Bool {
        guard !getrimmterSuchtext.isEmpty else { return false }
        let direktTreffer = artikel.name.localizedCaseInsensitiveContains(getrimmterSuchtext)
            || artikel.name.split(separator: " ").contains { String($0).passtAlsSingularPluralZu(getrimmterSuchtext) }
            || artikel.alternativeNamen.contains { $0.localizedCaseInsensitiveContains(getrimmterSuchtext) }
        return !direktTreffer
    }

    /// Ob die Produktliste für `artikel` gerade aufgeklappt ist. XOR aus
    /// Auto-Aufklapp-Zustand (``trefferNurUeberProdukt(_:)``) und
    /// ``umgeklappteArtikel``: ein Eintrag dort kehrt den Standardzustand um.
    private func istAufgeklappt(_ artikel: Artikel) -> Bool {
        trefferNurUeberProdukt(artikel) != umgeklappteArtikel.contains(artikel.id)
    }

    /// Formatiert ``EinkaufslistenEintrag/menge`` mit ``Artikel/einheit`` zur
    /// kompakten Anzeige links vom Haken (GitHub #124).
    private func mengeText(fuer eintrag: EinkaufslistenEintrag) -> String {
        "\(eintrag.menge.formatted()) \(eintrag.artikel?.einheit.kurzform ?? Einheit.stueck.kurzform)"
    }

    var body: some View {
        NavigationStack {
            List {
                if !getrimmterSuchtext.isEmpty && !existiertGenau {
                    Section {
                        Button {
                            neuenArtikelAnlegen()
                        } label: {
                            Label("\u{201E}\(getrimmterSuchtext)\u{201C} neu anlegen", systemImage: "plus.circle.fill")
                        }
                    }
                }

                ForEach(gruppierteArtikel, id: \.buchstabe) { gruppe in
                    Section(gruppe.buchstabe) {
                        ForEach(gruppe.artikel) { artikel in
                            let bereitsAufListe = !einkaufsliste.alleEintraege(fuer: artikel).isEmpty
                            let produkteDesArtikels = produkte(fuer: artikel)
                            let aufgeklappt = istAufgeklappt(artikel)
                            let gewaehltesProduktnamen: String? = {
                                let namen = einkaufsliste.alleEintraege(fuer: artikel).compactMap(\.produkt?.name)
                                guard !namen.isEmpty else { return nil }
                                return namen.count == 1 ? namen[0] : "\(namen[0]) +\(namen.count - 1)"
                            }()

                            // Hauptzeile: Toggle-Button füllt verfügbare Breite, rechts
                            // davon optionale Mengenanzeige (nur wenn auf Liste und keine
                            // benannten Produkte), Haken und ggf. Chevron (GitHub #124).
                            HStack(spacing: 0) {
                                Button {
                                    if bereitsAufListe {
                                        entfernen(artikel)
                                    } else {
                                        hinzufuegen(artikel)
                                    }
                                    suchfeldFuerNaechsteEingabeZuruecksetzen()
                                } label: {
                                    ArtikelAuswahlZeile(
                                        artikel: artikel,
                                        gewaehltesProduktnamen: gewaehltesProduktnamen
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if bereitsAufListe && produkteDesArtikels.isEmpty,
                                   let eintrag = einkaufsliste.eintrag(fuer: artikel) {
                                    Button {
                                        zuVerfeinernderEintrag = eintrag
                                        zeigeVerfeinerungsSheet = true
                                    } label: {
                                        Text(mengeText(fuer: eintrag))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 8)
                                }

                                Image(systemName: bereitsAufListe ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(bereitsAufListe ? Color.accentColor : .secondary)

                                if !produkteDesArtikels.isEmpty {
                                    Button {
                                        withAnimation {
                                            umgeklappteArtikel.formSymmetricDifference([artikel.id])
                                        }
                                    } label: {
                                        Image(systemName: aufgeklappt ? "chevron.down.circle" : "chevron.right.circle")
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(aufgeklappt ? "Produkte zuklappen" : "Produkt wählen")
                                }
                            }

                            if aufgeklappt && !produkteDesArtikels.isEmpty {
                                let nilEintrag = einkaufsliste.eintrag(fuer: artikel, produkt: nil)
                                let nilGewaehlt = nilEintrag != nil
                                HStack(spacing: 0) {
                                    Button {
                                        produktWaehlen(nil, fuer: artikel)
                                        suchfeldFuerNaechsteEingabeZuruecksetzen()
                                    } label: {
                                        ProduktSubZeile(name: "Kein bestimmtes Produkt", istGewaehlt: nilGewaehlt)
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    if nilGewaehlt, let eintrag = nilEintrag {
                                        Button {
                                            zuVerfeinernderEintrag = eintrag
                                            zeigeVerfeinerungsSheet = true
                                        } label: {
                                            Text(mengeText(fuer: eintrag))
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 8)
                                    }

                                    Image(systemName: nilGewaehlt ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(nilGewaehlt ? Color.accentColor : .secondary)
                                }

                                ForEach(produkteDesArtikels) { produkt in
                                    let istGewaehlt = einkaufsliste.enthaelt(artikel, produkt: produkt)
                                    let produktEintrag = einkaufsliste.eintrag(fuer: artikel, produkt: produkt)
                                    HStack(spacing: 0) {
                                        Button {
                                            produktWaehlen(produkt, fuer: artikel)
                                            suchfeldFuerNaechsteEingabeZuruecksetzen()
                                        } label: {
                                            ProduktSubZeile(name: produkt.name, istGewaehlt: istGewaehlt)
                                        }
                                        .buttonStyle(.plain)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        if istGewaehlt, let eintrag = produktEintrag {
                                            Button {
                                                zuVerfeinernderEintrag = eintrag
                                                zeigeVerfeinerungsSheet = true
                                            } label: {
                                                Text(mengeText(fuer: eintrag))
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, 8)
                                        }

                                        Image(systemName: istGewaehlt ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(istGewaehlt ? Color.accentColor : .secondary)
                                    }
                                }
                            }
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
            // `.navigationBarDrawer(displayMode: .always)` hält Titel und „Fertig"-Button
            // dauerhaft sichtbar — bei `.automatic` (Standard) ersetzt der aktive Suchbalken
            // die gesamte Navigationsleiste und versteckt beide Elemente.
            .searchable(text: $suchtext, isPresented: $sucheAktiv, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artikel oder Produkt suchen")
            .onChange(of: suchtext) { _, neuerText in
                if filterEinfrieren {
                    filterEinfrieren = false
                } else {
                    wirksamerSuchtext = neuerText
                    umgeklappteArtikel = []
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
            .sheet(isPresented: $zeigeVerfeinerungsSheet) {
                if let eintrag = zuVerfeinernderEintrag {
                    MengenNotizSheet(eintrag: eintrag)
                }
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

    /// Nimmt `artikel` mit ALLEN zugehörigen Einträgen (egal welches Produkt) von
    /// ``einkaufsliste`` — entfernt sowohl generische als auch produktspezifische
    /// Einträge auf einmal (Gegenstück zu ``hinzufuegen(_:)``, GitHub #45).
    private func entfernen(_ artikel: Artikel) {
        let artikelReferenz = ModelReference(artikel)
        let einkaufslisteReferenz = ModelReference(einkaufsliste)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let artikelFrisch = artikelReferenz.resolved(in: modelContext),
                      let einkaufslisteFrisch = einkaufslisteReferenz.resolved(in: modelContext)
                else { return }
                for eintrag in einkaufslisteFrisch.alleEintraege(fuer: artikelFrisch) {
                    einkaufslisteFrisch.artikelEntfernen(artikelFrisch, produkt: eintrag.produkt, context: modelContext)
                }
            }
        }
    }

    /// Schaltet den Eintrag `(artikel, produkt)` auf ``einkaufsliste`` um —
    /// fügt ihn hinzu, falls noch nicht vorhanden, entfernt ihn, falls bereits
    /// vorhanden. Jedes `(artikel, produkt)`-Paar ist ein unabhängiger Eintrag,
    /// sodass mehrere Produkte desselben Artikels gleichzeitig auf der Liste
    /// stehen können (GitHub #47 Erweiterung).
    private func produktWaehlen(_ produkt: Produkt?, fuer artikel: Artikel) {
        let artikelReferenz = ModelReference(artikel)
        let einkaufslisteReferenz = ModelReference(einkaufsliste)
        let produktReferenz = ModelReference(produkt)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let artikelFrisch = artikelReferenz.resolved(in: modelContext),
                      let einkaufslisteFrisch = einkaufslisteReferenz.resolved(in: modelContext)
                else { return }
                let produktFrisch = produktReferenz?.resolved(in: modelContext)
                if einkaufslisteFrisch.enthaelt(artikelFrisch, produkt: produktFrisch) {
                    einkaufslisteFrisch.artikelEntfernen(artikelFrisch, produkt: produktFrisch, context: modelContext)
                } else {
                    einkaufslisteFrisch.artikelHinzufuegen(artikelFrisch, produkt: produktFrisch, context: modelContext)
                }
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
    /// zusätzlichen Tap auf „Hinzufügen". Die Zeile zeigt danach automatisch den
    /// Haken.
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

/// Kompakter linker Teil einer Artikel-Auswahlzeile: Kategorie-Icon/Farbe, Name
/// und optionaler Produktname. Auswahlstatus (Haken) und Mengenanzeige werden
/// vom Aufrufer in der äußeren HStack gesetzt (GitHub #124).
private struct ArtikelAuswahlZeile: View {
    let artikel: Artikel
    var gewaehltesProduktnamen: String? = nil

    private var kategorie: ArtikelKategorie? { artikel.kategorien.first }

    var body: some View {
        HStack(spacing: 10) {
            GlassSymbolBadge(
                symbolName: kategorie?.standardSymbol ?? "shippingbox.fill",
                farbe: Color(hex: kategorie?.standardFarbeHex ?? "#8E8E93"),
                groesse: 28
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(artikel.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let pname = gewaehltesProduktnamen {
                    Text(pname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Eingerückte Produktzeile unterhalb einer Artikel-Hauptzeile — zeigt den
/// Produktnamen. Auswahlstatus (Haken) und Mengenanzeige werden vom Aufrufer
/// in der äußeren HStack gesetzt (GitHub #124).
private struct ProduktSubZeile: View {
    let name: String
    let istGewaehlt: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.tertiary)
                .padding(.leading, 38)

            Text(name)
                .foregroundStyle(istGewaehlt ? .primary : .secondary)
                .lineLimit(1)
        }
    }
}

#Preview {
    ArtikelHinzufuegenView(einkaufsliste: Einkaufsliste(name: "Einkaufsliste"))
        .modelContainer(for: [Artikel.self, ArtikelKategorie.self, GeschaeftTyp.self, Einkaufsliste.self, EinkaufslistenEintrag.self, Produkt.self, Produktname.self], inMemory: true)
}
