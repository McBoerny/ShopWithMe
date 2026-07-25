import SwiftUI
import SwiftData

/// Zeigt alle Geschäfte als Liste und erlaubt Anlegen, Bearbeiten und Löschen —
/// erreichbar über die Geschäfte-Verwaltung in ``SettingsView`` (kein eigener Tab
/// mehr, siehe GitHub #1). Erwartet einen umgebenden `NavigationStack` beim
/// Aufrufer statt selbst einen anzulegen.
///
/// Bietet außerdem den geschäftslosen Scan-Einstieg für Belege, die nachträglich
/// (z.B. zuhause, ohne vorher ein Geschäft zu wählen) gescannt werden —
/// ``BelegScanView/init()`` erkennt das Geschäft dafür automatisch, siehe
/// `docs/BELEGSCAN.md`. Der Preisschild-Scan hat bewusst keinen geschäftslosen
/// Einstieg (siehe `docs/PREISSCHILD_SCAN.md`) und ist deshalb hier nicht verlinkt.
struct GeschaeftListView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Environment(\.modelContext) private var modelContext

    @State private var neuesGeschaeftEntwurf: Geschaeft?
    @State private var zeigeBelegScan = false

    /// Namen, die mehrfach vorkommen — steuert, ob ``GeschaeftZeile`` zusätzlich die
    /// Kurzadresse anzeigt, um namensgleiche Geschäfte unterscheidbar zu machen
    /// (analog `GeschaeftWahlSheet`, siehe `docs/BELEGSCAN.md`).
    private var namenMitDuplikaten: Set<String> {
        Geschaeft.namenMitDuplikaten(unter: geschaefte)
    }

    var body: some View {
        List {
            ForEach(geschaefte) { geschaeft in
                NavigationLink {
                    GeschaeftDetailView(geschaeft: geschaeft)
                } label: {
                    GeschaeftZeile(geschaeft: geschaeft, istDuplikat: namenMitDuplikaten.contains(geschaeft.name.lowercased()))
                }
            }
            .onDelete(perform: geschaeftLoeschen)
        }
        .overlay {
            if geschaefte.isEmpty {
                ContentUnavailableView(
                    "Keine Geschäfte",
                    systemImage: "cart.fill",
                    description: Text("Lege dein erstes Geschäft mit dem Plus-Symbol an.")
                )
            }
        }
        .navigationTitle("Geschäfte")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    neuesGeschaeftEntwurf = Geschaeft(name: "", typen: [.lebensmittel])
                } label: {
                    Label("Geschäft hinzufügen", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    zeigeBelegScan = true
                } label: {
                    Label("Beleg scannen", systemImage: "doc.text.viewfinder")
                }
            }
        }
        .sheet(item: $neuesGeschaeftEntwurf) { entwurf in
            GeschaeftStammdatenEditView(geschaeft: entwurf, istNeu: true)
        }
        .sheet(isPresented: $zeigeBelegScan) {
            BelegScanView()
        }
    }

    private func geschaeftLoeschen(at offsets: IndexSet) {
        let zuLoeschende = offsets.map { geschaefte[$0] }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                for eintrag in zuLoeschende {
                    modelContext.delete(eintrag)
                }
            }
        }
    }
}

/// Eine Zeile in der Geschäfte-Liste. Zeigt zusätzlich die Kurzadresse
/// (``Geschaeft/kurzeAdresse``), wenn ``istDuplikat`` gesetzt ist — d.h. mindestens
/// ein weiteres Geschäft denselben Namen trägt (siehe ``GeschaeftListView/namenMitDuplikaten``).
private struct GeschaeftZeile: View {
    let geschaeft: Geschaeft
    var istDuplikat: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            GlassSymbolBadge(symbolName: geschaeft.typ.symbolName, farbe: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(geschaeft.name.isEmpty ? "Unbenannt" : geschaeft.name)
                Text("\(geschaeft.typen.map(\.anzeigename).joined(separator: ", ")) · \(geschaeft.regale.count) Regal(e)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if istDuplikat, let kurzeAdresse = geschaeft.kurzeAdresse {
                    Text(kurzeAdresse)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        GeschaeftListView()
    }
    .modelContainer(for: [Geschaeft.self, Regal.self, ArtikelKategorie.self], inMemory: true)
}
