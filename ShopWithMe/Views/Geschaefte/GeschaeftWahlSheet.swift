import SwiftUI
import SwiftData

/// Sheet zur Auswahl eines Geschäfts für einen Beleg-/Preisschild-Scan, dessen
/// Geschäft nicht automatisch über ``Geschaeft/passendes(fuerErkannterName:unter:)``
/// zugeordnet werden konnte — siehe `docs/BELEGSCAN.md` → „Automatischer
/// Geschäfts-Abgleich“.
///
/// Existiert das gewünschte Geschäft noch nicht, lässt es sich direkt hier über die
/// bestehende ``GeschaeftStammdatenEditView`` anlegen (vorausgefüllt mit dem
/// erkannten Namen) und wird danach automatisch ausgewählt — analog
/// ``KaufEintragZuordnenSheet``s Artikel-Neuanlage.
struct GeschaeftWahlSheet: View {
    /// Der auf dem Beleg/Preisschild erkannte Geschäftsname, falls vorhanden — nur
    /// zur Anzeige und als Vorbelegung der Suche/Neuanlage.
    let erkannterName: String
    let onAuswahl: (Geschaeft?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Geschaeft.name) private var alleGeschaefte: [Geschaeft]
    @State private var suchtext: String
    @State private var neuesGeschaeftEntwurf: Geschaeft?

    init(erkannterName: String, onAuswahl: @escaping (Geschaeft?) -> Void) {
        self.erkannterName = erkannterName
        self.onAuswahl = onAuswahl
        _suchtext = State(initialValue: erkannterName)
    }

    private var getrimmterSuchtext: String {
        suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gefilterteGeschaefte: [Geschaeft] {
        guard !getrimmterSuchtext.isEmpty else { return alleGeschaefte }
        return alleGeschaefte.filter { $0.name.localizedCaseInsensitiveContains(getrimmterSuchtext) }
    }

    private var existiertGenau: Bool {
        alleGeschaefte.contains {
            $0.name.localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !erkannterName.isEmpty {
                    Section {
                        Text("Auf dem Foto erkannt: „\(erkannterName)“")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        onAuswahl(nil)
                        dismiss()
                    } label: {
                        Text("Kein Geschäft")
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    if !getrimmterSuchtext.isEmpty && !existiertGenau {
                        Button {
                            neuesGeschaeftAnlegen()
                        } label: {
                            Label("„\(getrimmterSuchtext)“ neu anlegen", systemImage: "plus.circle.fill")
                        }
                    }

                    ForEach(gefilterteGeschaefte) { geschaeft in
                        Button {
                            onAuswahl(geschaeft)
                            dismiss()
                        } label: {
                            Text(geschaeft.name)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Der ausgewählte Name wird für künftige Scans als Alias für dieses Geschäft gemerkt.")
                }
            }
            .searchable(text: $suchtext, prompt: "Geschäft suchen oder anlegen")
            .navigationTitle("Geschäft wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .sheet(item: $neuesGeschaeftEntwurf) { entwurf in
                GeschaeftStammdatenEditView(geschaeft: entwurf, istNeu: true) { neuesGeschaeft in
                    onAuswahl(neuesGeschaeft)
                    dismiss()
                }
            }
        }
    }

    private func neuesGeschaeftAnlegen() {
        neuesGeschaeftEntwurf = Geschaeft(name: getrimmterSuchtext, typ: .lebensmittel)
    }
}

#Preview {
    GeschaeftWahlSheet(erkannterName: "REWE Center Musterstadt") { _ in }
        .modelContainer(for: [Geschaeft.self], inMemory: true)
}
