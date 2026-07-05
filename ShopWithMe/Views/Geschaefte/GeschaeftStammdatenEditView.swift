import SwiftUI
import SwiftData

/// Anlegen/Bearbeiten der Stammdaten (Name, Typ, Adresse) eines ``Geschaeft``s.
///
/// Bei einem neuen Geschäft (`istNeu == true`) wird es erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft es folgenlos).
struct GeschaeftStammdatenEditView: View {
    @Bindable var geschaeft: Geschaeft
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if istNeu {
            navigationInhalt
        } else {
            SessionLeaseGate { navigationInhalt }
        }
    }

    private var navigationInhalt: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $geschaeft.name)
                    Picker("Typ", selection: $geschaeft.typ) {
                        ForEach(GeschaeftTyp.allCases) { typ in
                            Label(typ.anzeigename, systemImage: typ.symbolName).tag(typ)
                        }
                    }
                }

                Section("Adresse (optional)") {
                    TextField(
                        "Adresse",
                        text: Binding(
                            get: { geschaeft.adresse ?? "" },
                            set: { geschaeft.adresse = $0.isEmpty ? nil : $0 }
                        ),
                        axis: .vertical
                    )
                }
            }
            .navigationTitle(istNeu ? "Neues Geschäft" : "Geschäft bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if istNeu {
                            Task {
                                await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                    modelContext.insert(geschaeft)
                                }
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(geschaeft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    GeschaeftStammdatenEditView(geschaeft: Geschaeft(name: "Rewe", typ: .lebensmittel), istNeu: true)
        .modelContainer(for: [Geschaeft.self], inMemory: true)
}
