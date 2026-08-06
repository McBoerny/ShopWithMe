import SwiftUI
import SwiftData

/// Anlegen/Bearbeiten eines ``Produkt``s (GitHub #47, Schritt 4/5) — analog
/// ``ArtikelEditView``.
///
/// Bei einem neuen Produkt (`istNeu == true`) wird es erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft es folgenlos). Verwaltet
/// zusätzlich die geschäftsabhängigen ``Produktname``n dieses Produkts sowie
/// dessen eigene Preishistorie. Rekursion (``Produkt/unterProdukte``, z.B.
/// Packungsgrößen) hat bewusst noch keine UI, siehe
/// `docs/ARTIKEL_PRODUKT_MODELL.md`.
struct ProduktEditView: View {
    @Bindable var produkt: Produkt
    let istNeu: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Geschaeft.name) private var alleGeschaefte: [Geschaeft]
    @Query private var produktnamen: [Produktname]
    @Query private var preisHistorie: [Preispunkt]

    @State private var neuerProduktnameText = ""
    @State private var neuerProduktnameGeschaeft: Geschaeft?
    @State private var produktnameFehlermeldung: String?

    init(produkt: Produkt, istNeu: Bool) {
        self.produkt = produkt
        self.istNeu = istNeu
        let produktID = produkt.persistentModelID
        _produktnamen = Query(
            filter: #Predicate<Produktname> { $0.produkt?.persistentModelID == produktID },
            sort: [SortDescriptor(\.name)]
        )
        _preisHistorie = Query(
            filter: #Predicate<Preispunkt> { $0.produkt?.persistentModelID == produktID },
            sort: [SortDescriptor(\.datum, order: .reverse)]
        )
    }

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
                    TextField("Name", text: $produkt.name)
                        .font(.title3)
                } footer: {
                    Text("Der konkrete Produktname, z.B. \"Paradontol Zahncreme\".")
                }

                if !istNeu {
                    Section {
                        ForEach(produktnamen) { eintrag in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(eintrag.name)
                                Text(eintrag.geschaeft?.name ?? "Unbekanntes Geschäft")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: produktnameEntfernen)

                        Picker("Geschäft", selection: $neuerProduktnameGeschaeft) {
                            Text("Bitte wählen").tag(nil as Geschaeft?)
                            ForEach(alleGeschaefte) { geschaeft in
                                Text(geschaeft.name).tag(geschaeft as Geschaeft?)
                            }
                        }
                        HStack {
                            TextField("Name in diesem Geschäft, z.B. \"Parad Zahncr\"", text: $neuerProduktnameText)
                                .onSubmit(produktnameHinzufuegen)
                            Button("Hinzufügen", action: produktnameHinzufuegen)
                                .disabled(
                                    neuerProduktnameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || neuerProduktnameGeschaeft == nil
                                )
                        }

                        if let produktnameFehlermeldung {
                            Text(produktnameFehlermeldung)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Produktnamen je Geschäft")
                    } footer: {
                        Text("Derselbe Produktname kann je Geschäft unterschiedlich lauten, z.B. \"Parad Zahncr\" in Geschäft A, \"Paradontol Zahn\" in Geschäft B.")
                    }
                }

                if !istNeu && !preisHistorie.isEmpty {
                    Section("Preishistorie") {
                        ForEach(preisHistorie) { eintrag in
                            PreisHistorieZeile(eintrag: eintrag, zeigeArtikel: false)
                        }
                    }
                }
            }
            .navigationTitle(istNeu ? "Neues Produkt" : produkt.name)
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
                                    modelContext.insert(produkt)
                                }
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(produkt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Legt einen neuen ``Produktname`` für ``produkt`` an — verhindert nur
    /// exakte Duplikate (dasselbe Geschäft, derselbe Name), keine
    /// Kollisionsprüfung über Produkte hinweg nötig (anders als
    /// ``ArtikelAlias/manuellHinzufuegen(name:zu:alle:context:)``): ein
    /// Produktname ist bereits durch ``produkt``+``Produktname/geschaeft``
    /// eindeutig gescoped.
    private func produktnameHinzufuegen() {
        produktnameFehlermeldung = nil
        guard let geschaeft = neuerProduktnameGeschaeft else { return }
        let name = neuerProduktnameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !produktnamen.contains(where: {
            $0.geschaeft == geschaeft && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            produktnameFehlermeldung = "„\(name)“ ist für \(geschaeft.name) bereits hinterlegt."
            return
        }
        let neuer = Produktname(name: name, produkt: produkt, geschaeft: geschaeft)
        modelContext.insert(neuer)
        neuerProduktnameText = ""
        neuerProduktnameGeschaeft = nil
    }

    private func produktnameEntfernen(at indexSet: IndexSet) {
        for index in indexSet {
            modelContext.delete(produktnamen[index])
        }
    }
}

#Preview {
    ProduktEditView(
        produkt: Produkt(name: "Paradontol Zahncreme", artikel: Artikel(name: "Zahnpasta", symbolName: "sparkles", farbeHex: "#AF52DE")),
        istNeu: true
    )
    .modelContainer(for: [Artikel.self, Produkt.self, Produktname.self, Geschaeft.self, GeschaeftTyp.self, Preispunkt.self], inMemory: true)
}
