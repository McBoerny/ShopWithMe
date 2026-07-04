import SwiftUI
import SwiftData

/// Anlegen/Bearbeiten eines ``Artikel``s.
///
/// Bei einem neuen Artikel (`istNeu == true`) ist die Kategorie frei wählbar und wird
/// erst beim Sichern in den Model-Context eingefügt (Abbrechen verwirft ihn
/// folgenlos). Bei einem bestehenden Artikel ist die Kategorie schreibgeschützt, da
/// sie sich nach Anlage fachlich nicht mehr ändert.
struct ArtikelEditView: View {
    @Bindable var artikel: Artikel
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtikelKategorie.sortIndex) private var kategorien: [ArtikelKategorie]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: artikel.symbolName, farbe: Color(hex: artikel.farbeHex), groesse: 56)
                        TextField("Name", text: $artikel.name)
                            .font(.title3)
                    }
                    SymbolFarbAuswahlZeile(symbolName: $artikel.symbolName, farbeHex: $artikel.farbeHex)
                }

                Section("Kategorie") {
                    if istNeu {
                        Picker("Kategorie", selection: $artikel.kategorie) {
                            Text("Keine Auswahl").tag(ArtikelKategorie?.none)
                            ForEach(kategorien) { kategorie in
                                Label(kategorie.name, systemImage: kategorie.standardSymbol)
                                    .tag(Optional(kategorie))
                            }
                        }
                    } else {
                        HStack {
                            Text("Kategorie")
                            Spacer()
                            Text(artikel.kategorie?.name ?? "–")
                                .foregroundStyle(.secondary)
                        }
                        Text("Die Kategorie kann nach dem Anlegen nicht mehr geändert werden.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notiz") {
                    TextField(
                        "Optionale Notiz, z.B. bevorzugte Marke",
                        text: Binding(
                            get: { artikel.notiz ?? "" },
                            set: { artikel.notiz = $0.isEmpty ? nil : $0 }
                        ),
                        axis: .vertical
                    )
                }

                Section {
                    Toggle("Auf Einkaufsliste", isOn: $artikel.istAufEinkaufsliste)
                }
            }
            .navigationTitle(istNeu ? "Neuer Artikel" : artikel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if istNeu {
                            modelContext.insert(artikel)
                        }
                        dismiss()
                    }
                    .disabled(
                        artikel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || artikel.kategorie == nil
                    )
                }
            }
        }
    }
}

#Preview {
    ArtikelEditView(
        artikel: Artikel(name: "Vollmilch", symbolName: "refrigerator.fill", farbeHex: "#5AC8FA"),
        istNeu: true
    )
    .modelContainer(for: [Artikel.self, ArtikelKategorie.self], inMemory: true)
}
