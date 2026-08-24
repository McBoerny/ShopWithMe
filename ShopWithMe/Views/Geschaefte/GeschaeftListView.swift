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
/// Geschäfte mit einem gemeinsamen ``Geschaeft/markenname`` werden als aufklappbare
/// Gruppe zusammengefasst — sinnvoll, wenn mehrere Filialen derselben Kette erfasst
/// sind. Einzelne oder markennamen-lose Geschäfte erscheinen als eigenständige Zeilen.
///
/// Zeigt zusätzlich eine „Favoriten"-Sektion mit den meistgenutzten Geschäften
/// (``GeschaeftHaeufigkeitService``, GitHub #31) vor der vollständigen Liste —
/// konfigurierbar über den Stern-Button im Toolbar.
struct GeschaeftListView: View {
    @Query private var geschaefte: [Geschaeft]
    @Query private var einkaufsvorgaenge: [Einkaufsvorgang]
    @Environment(\.modelContext) private var modelContext

    @State private var neuesGeschaeftEntwurf: Geschaeft?
    @State private var zeigeBelegScan = false
    @State private var zeigeFavoritenEinstellungen = false
    @State private var aufgeklappteMarken: Set<String> = []

    private var namenMitDuplikaten: Set<String> {
        Geschaeft.namenMitDuplikaten(unter: geschaefte)
    }

    private var favoriten: [Geschaeft] {
        GeschaeftHaeufigkeitService.favoriten(aus: einkaufsvorgaenge)
    }

    /// Gruppiert alle Geschäfte in eine gemischte, alphabetisch sortierte Liste:
    /// Geschäfte mit ``Geschaeft/markenname`` werden — sofern mehrere Filialen
    /// unter derselben Marke bekannt sind — als ``GeschaeftListEintrag/markenGruppe``
    /// zusammengefasst; alle anderen erscheinen als ``GeschaeftListEintrag/einzeln``.
    private var listenEintraege: [GeschaeftListEintrag] {
        var einzel: [Geschaeft] = []
        var markiert: [String: [Geschaeft]] = [:]

        for g in geschaefte {
            let marke = g.markenname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !marke.isEmpty {
                markiert[marke, default: []].append(g)
            } else {
                einzel.append(g)
            }
        }

        var result: [GeschaeftListEintrag] = einzel.map { .einzeln($0) }
        for (marke, filialen) in markiert {
            let sortiert = filialen.sorted { $0.name.vergleicheAlphabetisch(mit: $1.name) == .orderedAscending }
            if sortiert.count == 1, let einzige = sortiert.first {
                result.append(.einzeln(einzige))
            } else {
                result.append(.markenGruppe(markenname: marke, filialen: sortiert))
            }
        }

        return result.sorted { $0.sortierschluessel.vergleicheAlphabetisch(mit: $1.sortierschluessel) == .orderedAscending }
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

            ForEach(listenEintraege) { eintrag in
                switch eintrag {
                case .einzeln(let g):
                    NavigationLink(value: g) {
                        GeschaeftZeile(geschaeft: g, istDuplikat: namenMitDuplikaten.contains(g.name.lowercased()))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Löschen", role: .destructive) {
                            geschaeftLoeschen(g)
                        }
                    }
                case .markenGruppe(let markenname, let filialen):
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { aufgeklappteMarken.contains(markenname) },
                            set: { offen in
                                if offen { aufgeklappteMarken.insert(markenname) }
                                else { aufgeklappteMarken.remove(markenname) }
                            }
                        )
                    ) {
                        ForEach(filialen) { filiale in
                            NavigationLink(value: filiale) {
                                GeschaeftZeile(geschaeft: filiale, istDuplikat: true)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Löschen", role: .destructive) {
                                    geschaeftLoeschen(filiale)
                                }
                            }
                        }
                    } label: {
                        GeschaeftMarkenZeile(markenname: markenname, filialen: filialen)
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

    private func geschaeftLoeschen(_ geschaeft: Geschaeft) {
        let referenz = ModelReference(geschaeft)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                guard let eintrag = referenz.resolved(in: modelContext) else { return }
                SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.geschaeft, id: eintrag.id, context: modelContext)
                modelContext.delete(eintrag)
            }
        }
    }
}

/// Listeneintrag in ``GeschaeftListView``: entweder ein einzelnes ``Geschaeft``
/// (ohne ``Geschaeft/markenname`` oder als einzige Filiale seiner Marke) oder
/// eine aufklappbare Gruppe gleichnamiger Filialen.
private enum GeschaeftListEintrag: Identifiable {
    case einzeln(Geschaeft)
    case markenGruppe(markenname: String, filialen: [Geschaeft])

    var id: String {
        switch self {
        case .einzeln(let g): return "e:\(g.id.uuidString)"
        case .markenGruppe(let m, _): return "m:\(m)"
        }
    }

    var sortierschluessel: String {
        switch self {
        case .einzeln(let g): return g.name
        case .markenGruppe(let m, _): return m
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

/// Kopfzeile einer Filialgruppe in ``GeschaeftListView``: zeigt den Markennamen
/// und die Anzahl der zugehörigen Filialen.
private struct GeschaeftMarkenZeile: View {
    let markenname: String
    let filialen: [Geschaeft]

    var body: some View {
        HStack(spacing: 12) {
            GlassSymbolBadge(
                symbolName: filialen.first?.fuehrenderTyp?.symbolName ?? "shippingbox.fill",
                farbe: .accentColor
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(markenname)
                Text("\(filialen.count) Filialen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Eine Zeile in der Geschäfte-Liste. Zeigt zusätzlich die Kurzadresse
/// (``Geschaeft/kurzeAdresse``), wenn ``istDuplikat`` gesetzt ist — d.h. mindestens
/// ein weiteres Geschäft denselben Namen trägt oder die Zeile innerhalb einer
/// Filialgruppe angezeigt wird.
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
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Abteilung.self, Einkaufsvorgang.self], inMemory: true)
}
