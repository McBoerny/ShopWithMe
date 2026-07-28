import SwiftUI
import SwiftData

/// Verwaltung der Standard-Warengruppen je ``GeschaeftTyp`` (GitHub #5) —
/// aufrufbar aus ``SettingsView``.
///
/// Eine hier markierte ``ArtikelKategorie`` gilt automatisch für jedes ``Geschaeft``
/// mit passendem Typ als verfügbar (siehe
/// ``Geschaeft/verfuegbareKategorien(alleKategorien:)``), ohne dass sie dem
/// einzelnen Geschäft manuell zugeordnet werden muss. Die manuelle Zuordnung
/// einzelner Kategorien zu einem konkreten Geschäft (``KategorieHinzufuegenSheet``)
/// bleibt davon unabhängig weiterhin möglich.
struct GeschaeftsTypenVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GeschaeftTyp.sortIndex) private var geschaeftsTypen: [GeschaeftTyp]
    @State private var zeigeNeuerTyp = false

    var body: some View {
        List {
            ForEach(geschaeftsTypen) { typ in
                NavigationLink {
                    GeschaeftsTypKategorienView(typ: typ)
                } label: {
                    Label(typ.name, systemImage: typ.symbolName)
                }
            }
            Button {
                zeigeNeuerTyp = true
            } label: {
                Label("Neuen Geschäftstyp anlegen", systemImage: "plus")
            }
        }
        .navigationTitle("Geschäftstypen")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeNeuerTyp) {
            NeuerGeschaeftsTypSheet(naechsterSortIndex: (geschaeftsTypen.map(\.sortIndex).max() ?? -1) + 1) { _ in }
        }
    }
}

/// Bearbeitet Name, Symbol und Farbe eines ``GeschaeftTyp`` (GitHub #40) sowie die
/// ihm zugeordneten Standard-Warengruppen — Checkmark markiert die aktuell
/// zugeordneten Kategorien, analog dem Mehrfachauswahl-Muster in
/// ``ArtikelEditView``. Zeigt die Liste alphabetisch, mit bereits ausgewählten
/// Kategorien zuerst (``sortierteKategorien``). Kategorien, die im laufenden
/// Aufruf von ``kiVorschlagAnfordern()`` markiert wurden, sind zusätzlich mit
/// „KI-Vorschlag" gekennzeichnet — bewusst nur für die Dauer dieser Sitzung
/// (``kiVorgeschlageneKategorieIDs``), kein zusätzliches persistentes Feld.
private struct GeschaeftsTypKategorienView: View {
    @Bindable var typ: GeschaeftTyp

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false
    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?
    @State private var kiVorgeschlageneKategorieIDs: Set<PersistentIdentifier> = []

    /// ``alleKategorien`` alphabetisch, aber mit den für ``typ`` bereits
    /// ausgewählten Kategorien zuerst — eine sich beim Umschalten sofort dynamisch
    /// anpassende Liste, in der auf einen Blick erkennbar ist, welche Warengruppen
    /// diesem Geschäftstyp bereits zugeordnet sind (GitHub #14).
    private var sortierteKategorien: [ArtikelKategorie] {
        let (ausgewaehlt, uebrige) = alleKategorien.reduce(into: ([ArtikelKategorie](), [ArtikelKategorie]())) { ergebnis, kategorie in
            if kategorie.geschaeftsTypen.contains(typ) {
                ergebnis.0.append(kategorie)
            } else {
                ergebnis.1.append(kategorie)
            }
        }
        func alphabetisch(_ kategorien: [ArtikelKategorie]) -> [ArtikelKategorie] {
            kategorien.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
        }
        return alphabetisch(ausgewaehlt) + alphabetisch(uebrige)
    }

    var body: some View {
        SessionLeaseGate { formInhalt }
    }

    private var formInhalt: some View {
        Form {
            Section {
                TextField("Name", text: $typ.name)
                    .font(.title3)
                SymbolFarbAuswahlZeile(symbolName: $typ.symbolName, farbeHex: $typ.farbeHex)
            }

            Section {
                ForEach(sortierteKategorien) { kategorie in
                    Button {
                        kategorieToggeln(kategorie)
                    } label: {
                        HStack {
                            Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                .foregroundStyle(.primary)
                            if kiVorgeschlageneKategorieIDs.contains(kategorie.persistentModelID) {
                                Text("KI-Vorschlag")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if kategorie.geschaeftsTypen.contains(typ) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        // Ohne contentShape reagiert nur der sichtbare Inhalt auf
                        // Taps, nicht der leere Spacer-Bereich dazwischen (GitHub #38).
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    zeigeNeueKategorie = true
                } label: {
                    Label("Neue Kategorie anlegen", systemImage: "plus")
                }

                if AISuggestionService.istVerfuegbar {
                    Button {
                        kiVorschlagAnfordern()
                    } label: {
                        Label("KI-Vorschlag", systemImage: "sparkles")
                    }
                    .disabled(kiVorschlagLaeuft)
                }
                if kiVorschlagLaeuft {
                    HStack {
                        ProgressView()
                        Text("Apple Intelligence schlägt Warengruppen vor…")
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
                Text("Markierte Warengruppen sind automatisch in jedem Geschäft mit diesem Typ verfügbar, ohne sie dort einzeln zuzuordnen. Mehrfachauswahl möglich. Die „KI-Vorschlag“-Markierung gilt nur für die aktuelle Sitzung, zur Überprüfung des letzten Vorschlags.")
            }
        }
        .navigationTitle(typ.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zeigeNeueKategorie) {
            NeueKategorieSheet(naechsterSortIndex: (alleKategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                kategorie.geschaeftsTypen = kategorie.geschaeftsTypen + [typ]
            }
        }
    }

    private func kategorieToggeln(_ kategorie: ArtikelKategorie) {
        var aktuelle = kategorie.geschaeftsTypen
        if let index = aktuelle.firstIndex(of: typ) {
            aktuelle.remove(at: index)
        } else {
            aktuelle.append(typ)
        }
        kategorie.geschaeftsTypen = aktuelle
    }

    /// Fragt
    /// ``AISuggestionService/vorschlag(fuerGeschaeftsTypName:bekannteKategorien:)``
    /// an und markiert die vorgeschlagenen Kategorien für ``typ`` — vorhandene
    /// Namen werden wiederverwendet (case-insensitiver Abgleich), sonst wird eine
    /// neue ``ArtikelKategorie`` angelegt.
    private func kiVorschlagAnfordern() {
        kiFehlermeldung = nil
        kiVorschlagLaeuft = true
        Task {
            defer { kiVorschlagLaeuft = false }
            do {
                let vorschlag = try await AISuggestionService.vorschlag(
                    fuerGeschaeftsTypName: typ.name,
                    bekannteKategorien: alleKategorien.map(\.name)
                )
                // Lokale Kopie statt der `@Query`-Momentaufnahme direkt zu lesen:
                // die aktualisiert sich erst beim nächsten View-Update, nicht
                // synchron nach `modelContext.insert(...)` — bei einem doppelten
                // oder sehr ähnlichen Namen im KI-Vorschlag (nichts erzwingt
                // Eindeutigkeit) würde die zweite Fundstelle die gerade erst
                // angelegte Kategorie sonst nicht sehen und ein Duplikat anlegen.
                var bekannteKategorien = alleKategorien
                // Nur die Vorschläge DIESES Aufrufs markieren, nicht mit einer
                // eventuell früheren Markierung derselben Sitzung vermischen
                // (GitHub #40) — rein session-lokal, kein persistentes Feld.
                var neuVorgeschlagen: Set<PersistentIdentifier> = []
                for name in vorschlag.kategorieNamen {
                    let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !getrimmt.isEmpty else { continue }
                    if let bestehende = bekannteKategorien.first(where: {
                        $0.name.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame
                    }) {
                        if !bestehende.geschaeftsTypen.contains(typ) {
                            bestehende.geschaeftsTypen = bestehende.geschaeftsTypen + [typ]
                        }
                        neuVorgeschlagen.insert(bestehende.persistentModelID)
                    } else {
                        let naechsterIndex = (bekannteKategorien.map(\.sortIndex).max() ?? -1) + 1
                        let neue = ArtikelKategorie(
                            name: getrimmt,
                            standardSymbol: "shippingbox.fill",
                            standardFarbeHex: Color.artikelPalette[0],
                            sortIndex: naechsterIndex
                        )
                        neue.geschaeftsTypen = [typ]
                        modelContext.insert(neue)
                        bekannteKategorien.append(neue)
                        neuVorgeschlagen.insert(neue.persistentModelID)
                    }
                }
                kiVorgeschlageneKategorieIDs = neuVorgeschlagen
            } catch {
                kiFehlermeldung = "KI-Vorschlag fehlgeschlagen."
            }
        }
    }
}

#Preview {
    NavigationStack {
        GeschaeftsTypenVerwaltungView()
    }
    .modelContainer(for: [ArtikelKategorie.self, Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
