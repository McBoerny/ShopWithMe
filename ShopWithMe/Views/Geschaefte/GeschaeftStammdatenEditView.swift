import SwiftUI
import SwiftData

/// Anlegen/Bearbeiten der Stammdaten (Name, Typ, Adresse) eines ``Geschaeft``s.
///
/// Bei einem neuen Geschäft (`istNeu == true`) wird es erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft es folgenlos).
struct GeschaeftStammdatenEditView: View {
    @Bindable var geschaeft: Geschaeft
    let istNeu: Bool
    /// Wird nach erfolgreichem Sichern eines neuen Geschäfts (`istNeu == true`)
    /// aufgerufen — z.B. um es in ``EinkaufenView`` nach dem per Ladenerkennung
    /// angebotenen Hinzufügen automatisch als aktives Geschäft zu übernehmen.
    var onGespeichert: ((Geschaeft) -> Void)? = nil

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
                }

                Section {
                    ForEach(GeschaeftTyp.allCases) { typ in
                        Button {
                            typToggeln(typ)
                        } label: {
                            HStack {
                                Label(typ.anzeigename, systemImage: typ.symbolName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if geschaeft.typen.contains(typ) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Typ")
                } footer: {
                    Text("Mehrfachauswahl möglich, z.B. Drogerie + Lebensmittel. Mindestens ein Typ muss gewählt sein.")
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
                                onGespeichert?(geschaeft)
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(geschaeft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || geschaeft.typen.isEmpty)
                }
            }
        }
    }

    private func typToggeln(_ typ: GeschaeftTyp) {
        var aktuelle = geschaeft.typen
        if let index = aktuelle.firstIndex(of: typ) {
            aktuelle.remove(at: index)
        } else {
            aktuelle.append(typ)
        }
        geschaeft.typen = aktuelle
    }
}

#Preview {
    GeschaeftStammdatenEditView(geschaeft: Geschaeft(name: "Rewe", typen: [.lebensmittel]), istNeu: true)
        .modelContainer(for: [Geschaeft.self], inMemory: true)
}
