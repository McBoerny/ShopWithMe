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
    var body: some View {
        List(GeschaeftTyp.allCases) { typ in
            NavigationLink {
                GeschaeftsTypKategorienView(typ: typ)
            } label: {
                Label(typ.anzeigename, systemImage: typ.symbolName)
            }
        }
        .navigationTitle("Geschäftstypen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Toggle-Liste aller ``ArtikelKategorie``n für einen ``GeschaeftTyp`` — Checkmark
/// markiert die aktuell zugeordneten Standard-Warengruppen, analog dem
/// Mehrfachauswahl-Muster in ``ArtikelEditView``.
private struct GeschaeftsTypKategorienView: View {
    let typ: GeschaeftTyp

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var zeigeNeueKategorie = false
    @State private var kiVorschlagLaeuft = false
    @State private var kiFehlermeldung: String?

    var body: some View {
        SessionLeaseGate { formInhalt }
    }

    private var formInhalt: some View {
        Form {
            Section {
                ForEach(alleKategorien) { kategorie in
                    Button {
                        kategorieToggeln(kategorie)
                    } label: {
                        HStack {
                            Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                .foregroundStyle(.primary)
                            Spacer()
                            if kategorie.geschaeftsTypen.contains(typ) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
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
                Text("Markierte Warengruppen sind automatisch in jedem Geschäft mit diesem Typ verfügbar, ohne sie dort einzeln zuzuordnen. Mehrfachauswahl möglich.")
            }
        }
        .navigationTitle(typ.anzeigename)
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

    /// Fragt ``AISuggestionService/vorschlag(fuerGeschaeftsTyp:bekannteKategorien:)``
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
                    fuerGeschaeftsTyp: typ,
                    bekannteKategorien: alleKategorien.map(\.name)
                )
                for name in vorschlag.kategorieNamen {
                    let getrimmt = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !getrimmt.isEmpty else { continue }
                    if let bestehende = alleKategorien.first(where: {
                        $0.name.localizedCaseInsensitiveCompare(getrimmt) == .orderedSame
                    }) {
                        if !bestehende.geschaeftsTypen.contains(typ) {
                            bestehende.geschaeftsTypen = bestehende.geschaeftsTypen + [typ]
                        }
                    } else {
                        let naechsterIndex = (alleKategorien.map(\.sortIndex).max() ?? -1) + 1
                        let neue = ArtikelKategorie(
                            name: getrimmt,
                            standardSymbol: "shippingbox.fill",
                            standardFarbeHex: Color.artikelPalette[0],
                            sortIndex: naechsterIndex
                        )
                        neue.geschaeftsTypen = [typ]
                        modelContext.insert(neue)
                    }
                }
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
    .modelContainer(for: [ArtikelKategorie.self, Geschaeft.self], inMemory: true)
}
