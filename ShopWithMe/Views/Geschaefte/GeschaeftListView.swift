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
///
/// Gruppiert alphabetisch nach Anfangsbuchstaben — bei vielen Geschäften zeigt iOS
/// dafür automatisch eine A–Z-Sprungleiste wie im Adressbuch (GitHub #29).
///
/// Zeigt zusätzlich eine „Favoriten“-Sektion mit den meistgenutzten Geschäften
/// (``GeschaeftHaeufigkeitService``, GitHub #31) vor der vollständigen,
/// alphabetischen Liste — konfigurierbar über den Zähler-Button im Toolbar.
struct GeschaeftListView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Query private var einkaufsvorgaenge: [Einkaufsvorgang]
    @Environment(\.modelContext) private var modelContext

    @State private var neuesGeschaeftEntwurf: Geschaeft?
    @State private var zeigeBelegScan = false
    @State private var zeigeFavoritenEinstellungen = false

    /// Namen, die mehrfach vorkommen — steuert, ob ``GeschaeftZeile`` zusätzlich die
    /// Kurzadresse anzeigt, um namensgleiche Geschäfte unterscheidbar zu machen
    /// (analog `GeschaeftWahlSheet`, siehe `docs/BELEGSCAN.md`).
    private var namenMitDuplikaten: Set<String> {
        Geschaeft.namenMitDuplikaten(unter: geschaefte)
    }

    private var favoriten: [Geschaeft] {
        GeschaeftHaeufigkeitService.favoriten(aus: einkaufsvorgaenge)
    }

    /// ``geschaefte`` gruppiert nach Anfangsbuchstaben, alphabetisch.
    private var gruppierteGeschaefte: [(buchstabe: String, geschaefte: [Geschaeft])] {
        let gruppen = Dictionary(grouping: geschaefte) { geschaeft -> String in
            guard let erstesZeichen = geschaeft.name.first else { return "#" }
            return String(erstesZeichen).uppercased()
        }
        return gruppen.keys.sorted().map { buchstabe in (buchstabe, gruppen[buchstabe] ?? []) }
    }

    var body: some View {
        List {
            if !favoriten.isEmpty {
                Section("Favoriten") {
                    ForEach(favoriten) { geschaeft in
                        NavigationLink(value: geschaeft) {
                            GeschaeftZeile(geschaeft: geschaeft, istDuplikat: namenMitDuplikaten.contains(geschaeft.name.lowercased()))
                        }
                    }
                }
            }

            ForEach(gruppierteGeschaefte, id: \.buchstabe) { gruppe in
                Section(gruppe.buchstabe) {
                    ForEach(gruppe.geschaefte) { geschaeft in
                        NavigationLink(value: geschaeft) {
                            GeschaeftZeile(geschaeft: geschaeft, istDuplikat: namenMitDuplikaten.contains(geschaeft.name.lowercased()))
                        }
                    }
                    .onDelete { offsets in
                        geschaeftLoeschen(gruppe.geschaefte, at: offsets)
                    }
                }
            }
        }
        .navigationDestination(for: Geschaeft.self) { geschaeft in
            GeschaeftDetailView(geschaeft: geschaeft)
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
                    neuesGeschaeftEntwurf = Geschaeft(
                        name: "",
                        typen: [GeschaeftTyp.mitNamen("Lebensmittel", symbolName: "cart.fill", context: modelContext)]
                    )
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    zeigeFavoritenEinstellungen = true
                } label: {
                    Label("Favoriten-Einstellungen", systemImage: "star")
                }
            }
        }
        .sheet(item: $neuesGeschaeftEntwurf) { entwurf in
            GeschaeftStammdatenEditView(geschaeft: entwurf, istNeu: true)
        }
        .sheet(isPresented: $zeigeBelegScan) {
            BelegScanView()
        }
        .sheet(isPresented: $zeigeFavoritenEinstellungen) {
            GeschaeftFavoritenEinstellungenSheet()
        }
    }

    private func geschaeftLoeschen(_ geschaefte: [Geschaeft], at offsets: IndexSet) {
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

/// Sheet zum Einstellen von ``GeschaeftHaeufigkeitService/anzahlFavoriten`` und
/// ``GeschaeftHaeufigkeitService/zeitfensterTage`` (GitHub #31).
private struct GeschaeftFavoritenEinstellungenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var anzahl = GeschaeftHaeufigkeitService.anzahlFavoriten
    @State private var zeitfensterTage = GeschaeftHaeufigkeitService.zeitfensterTage

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Anzahl Favoriten: \(anzahl)", value: $anzahl, in: 1...20)
                } footer: {
                    Text("Wie viele der meistgenutzten Geschäfte oben als Favoriten angezeigt werden.")
                }
                Section {
                    Stepper("Zeitfenster: \(zeitfensterTage) Tage", value: $zeitfensterTage, in: 1...365, step: 5)
                } footer: {
                    Text("Nur Einkäufe innerhalb dieses Zeitraums zählen für die Favoriten-Ermittlung.")
                }
            }
            .navigationTitle("Favoriten-Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        GeschaeftHaeufigkeitService.anzahlFavoriten = anzahl
                        GeschaeftHaeufigkeitService.zeitfensterTage = zeitfensterTage
                        dismiss()
                    }
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
            GlassSymbolBadge(symbolName: geschaeft.fuehrenderTyp?.symbolName ?? "shippingbox.fill", farbe: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(geschaeft.name.isEmpty ? "Unbenannt" : geschaeft.name)
                Text(geschaeft.typen.map(\.name).joined(separator: ", "))
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
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, ArtikelKategorie.self, Einkaufsvorgang.self], inMemory: true)
}
