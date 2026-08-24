import SwiftUI
import SwiftData

/// Verwaltung der Standard-Abteilungen je ``GeschaeftTyp`` (GitHub #5) —
/// aufrufbar aus ``SettingsView``.
///
/// Eine hier markierte ``Abteilung`` gilt automatisch für jedes ``Geschaeft``
/// mit passendem Typ als verfügbar (siehe
/// ``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)``), ohne dass sie dem
/// einzelnen Geschäft manuell zugeordnet werden muss. Die manuelle Zuordnung
/// einzelner Abteilungen zu einem konkreten Geschäft (``AbteilungHinzufuegenSheet``)
/// bleibt davon unabhängig weiterhin möglich.
struct GeschaeftsTypenVerwaltungView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var geschaeftsTypen: [GeschaeftTyp]
    @State private var zeigeNeuerTyp = false

    private var sortierteTypen: [GeschaeftTyp] {
        geschaeftsTypen.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            AlphabetischeListenSektion(sortierteTypen, name: \.name) { typ in
                NavigationLink {
                    GeschaeftsTypAbteilungenView(typ: typ)
                } label: {
                    Label(typ.name, systemImage: typ.symbolName)
                }
            }
        }
        .navigationTitle("Geschäftstypen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeNeuerTyp = true
                } label: {
                    Label("Neuen Geschäftstyp anlegen", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $zeigeNeuerTyp) {
            NeuerGeschaeftsTypSheet(naechsterSortIndex: (geschaeftsTypen.map(\.sortIndex).max() ?? -1) + 1) { _ in }
        }
    }
}

/// Bearbeitet Name, Symbol und Farbe eines ``GeschaeftTyp`` (GitHub #40) sowie die
/// ihm zugeordneten Standard-Abteilungen — Checkmark markiert die aktuell
/// zugeordneten Abteilungen, analog dem Mehrfachauswahl-Muster in
/// ``ArtikelEditView``. Zeigt die Liste alphabetisch, mit bereits ausgewählten
/// Abteilungen zuerst (``sortierteAbteilungen``). Abteilungen, die im laufenden
/// Aufruf von ``kiVorschlagAnfordern()`` markiert wurden, sind zusätzlich mit
/// „KI-Vorschlag" gekennzeichnet — bewusst nur für die Dauer dieser Sitzung
/// (``kiVorgeschlageneAbteilungIDs``), kein zusätzliches persistentes Feld.
private struct GeschaeftsTypAbteilungenView: View {
    @Bindable var typ: GeschaeftTyp

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Abteilung.sortIndex) private var alleAbteilungen: [Abteilung]
    @State private var zeigeNeueAbteilung = false
    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?
    @State private var kiVorgeschlageneAbteilungIDs: Set<PersistentIdentifier> = []

    /// ``alleAbteilungen`` alphabetisch, aber mit den für ``typ`` bereits
    /// ausgewählten Abteilungen zuerst — eine sich beim Umschalten sofort dynamisch
    /// anpassende Liste, in der auf einen Blick erkennbar ist, welche Abteilungen
    /// diesem Geschäftstyp bereits zugeordnet sind (GitHub #14).
    private var sortierteAbteilungen: [Abteilung] {
        let (ausgewaehlt, uebrige) = alleAbteilungen.reduce(into: ([Abteilung](), [Abteilung]())) { ergebnis, abteilung in
            if abteilung.geschaeftsTypen.contains(typ) {
                ergebnis.0.append(abteilung)
            } else {
                ergebnis.1.append(abteilung)
            }
        }
        func alphabetisch(_ abteilungen: [Abteilung]) -> [Abteilung] {
            abteilungen.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
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
                ForEach(sortierteAbteilungen) { abteilung in
                    Button {
                        abteilungToggeln(abteilung)
                    } label: {
                        HStack {
                            Label(abteilung.name, systemImage: abteilung.standardSymbol)
                                .foregroundStyle(.primary)
                            if kiVorgeschlageneAbteilungIDs.contains(abteilung.persistentModelID) {
                                Text("KI-Vorschlag")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if abteilung.geschaeftsTypen.contains(typ) {
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
                    zeigeNeueAbteilung = true
                } label: {
                    Label("Neue Abteilung anlegen", systemImage: "plus")
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
                        Text("Apple Intelligence schlägt Abteilungen vor…")
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
                Text("Markierte Abteilungen sind automatisch in jedem Geschäft mit diesem Typ verfügbar, ohne sie dort einzeln zuzuordnen. Mehrfachauswahl möglich. Die \u{201E}KI-Vorschlag\u{201C}-Markierung gilt nur für die aktuelle Sitzung, zur Überprüfung des letzten Vorschlags.")
            }
        }
        .navigationTitle(typ.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: typ.name) { _, _ in typ.markiereGeaendert() }
        .onChange(of: typ.symbolName) { _, _ in typ.markiereGeaendert() }
        .onChange(of: typ.farbeHex) { _, _ in typ.markiereGeaendert() }
        .sheet(isPresented: $zeigeNeueAbteilung) {
            NeueAbteilungSheet(naechsterSortIndex: (alleAbteilungen.map(\.sortIndex).max() ?? -1) + 1) { abteilung in
                abteilung.geschaeftsTypen = abteilung.geschaeftsTypen + [typ]
            }
        }
    }

    private func abteilungToggeln(_ abteilung: Abteilung) {
        var aktuelle = abteilung.geschaeftsTypen
        if let index = aktuelle.firstIndex(of: typ) {
            aktuelle.remove(at: index)
        } else {
            aktuelle.append(typ)
        }
        abteilung.geschaeftsTypen = aktuelle
    }

    /// Fragt
    /// ``AISuggestionService/vorschlag(fuerGeschaeftsTypName:bekannteAbteilungen:)``
    /// an und markiert die vorgeschlagenen Abteilungen für ``typ`` — vorhandene
    /// Namen werden wiederverwendet (case-insensitiver Abgleich), sonst wird eine
    /// neue ``Abteilung`` angelegt.
    private func kiVorschlagAnfordern() {
        kiFehlermeldung = nil
        kiVorschlagLaeuft = true
        Task {
            defer { kiVorschlagLaeuft = false }
            do {
                let vorschlag = try await AISuggestionService.vorschlag(
                    fuerGeschaeftsTypName: typ.name,
                    bekannteAbteilungen: alleAbteilungen.map(\.name)
                )
                // Lokale Kopie statt der `@Query`-Momentaufnahme direkt zu lesen:
                // die aktualisiert sich erst beim nächsten View-Update, nicht
                // synchron nach `modelContext.insert(...)` — bei einem doppelten
                // oder sehr ähnlichen Namen im KI-Vorschlag (nichts erzwingt
                // Eindeutigkeit) würde die zweite Fundstelle die gerade erst
                // angelegte Abteilung sonst nicht sehen und ein Duplikat anlegen.
                var bekannteAbteilungen = alleAbteilungen
                // Nur die Vorschläge DIESES Aufrufs markieren, nicht mit einer
                // eventuell früheren Markierung derselben Sitzung vermischen
                // (GitHub #40) — rein session-lokal, kein persistentes Feld.
                var neuVorgeschlagen: Set<PersistentIdentifier> = []
                for name in vorschlag.abteilungNamen {
                    let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !getrimmt.isEmpty else { continue }
                    if let bestehende = bekannteAbteilungen.first(where: {
                        $0.name.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame
                    }) {
                        if !bestehende.geschaeftsTypen.contains(typ) {
                            bestehende.geschaeftsTypen = bestehende.geschaeftsTypen + [typ]
                        }
                        neuVorgeschlagen.insert(bestehende.persistentModelID)
                    } else {
                        let naechsterIndex = (bekannteAbteilungen.map(\.sortIndex).max() ?? -1) + 1
                        let neue = Abteilung(
                            name: getrimmt,
                            standardSymbol: "shippingbox.fill",
                            standardFarbeHex: Color.artikelPalette[0],
                            sortIndex: naechsterIndex
                        )
                        neue.geschaeftsTypen = [typ]
                        modelContext.insert(neue)
                        bekannteAbteilungen.append(neue)
                        neuVorgeschlagen.insert(neue.persistentModelID)
                    }
                }
                kiVorgeschlageneAbteilungIDs = neuVorgeschlagen
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
    .modelContainer(for: [Abteilung.self, Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
