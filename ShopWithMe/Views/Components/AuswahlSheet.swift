import SwiftUI

/// Generische Sheet-Komponente für Einfach- oder Mehrfachauswahl aus einer
/// reinen Liste (GitHub #130) — für Auswahl-Sheets, die keine
/// domänenspezifische Zusatzlogik (Geocoding, Duplikat-Sonderfälle etc.)
/// brauchen. Deckt ab:
/// - Ganze Zeile auswählbar (nicht nur der Text).
/// - Suchfeld, immer eingeblendet — bewusst NICHT abhängig von der
///   Eintragsanzahl. Ein bedingtes `.searchable(...)`, dessen An-/Abwesenheit
///   von einem live per `@Query` befüllten Zähler abhing, hat dazu geführt,
///   dass sich das ganze Sheet beim allerersten Öffnen (leeres `@Query` beim
///   ersten Rendern, kurz danach befüllt → Bedingung kippt mitten in der
///   ersten Darstellung) sofort wieder schloss (Live-Fund,
///   `AbteilungHinzufuegenSheet`). `.searchable` strukturell dynamisch an-/
///   abzuhängen gilt allgemein als SwiftUI-Stolperfalle für genau solche
///   Navigationsartefakte.
/// - Schnellnavigation an der rechten Kante analog der `UITableView`-
///   Sektions-Indexleiste (SwiftUI bietet dafür kein natives Äquivalent),
///   automatisch ab ``schnellnavigationAbAnzahl`` Einträgen (Default 100).
/// - Optionale Mehrfachauswahl (``Auswahlmodus/mehrfach(_:)``) — dann
///   erscheint ein Haken-Button oben rechts zum Schließen (Issue-Vorgabe:
///   bei Einfachauswahl schließt bereits der Tap auf eine Zeile, ein
///   zusätzlicher Haken wäre dort redundant).
/// - Optionale „+"-Neuanlage-Zeile, wenn kein Eintrag zum Suchtext passt
///   (``neuAnlegenTitel``/``neuAnlegenInhalt``) — der Aufrufer liefert die
///   Neuanlage-Ansicht als eigenen View-Typ und ruft beim erfolgreichen
///   Sichern den übergebenen Completion-Callback auf; das Sheet wählt den
///   neuen Eintrag dann automatisch aus und schließt sich.
///
/// Erster Verwender: ``ArtikelAuswahlSheet`` (GitHub #123). Bewusst NICHT für
/// Sheets mit substanzieller Sonderlogik wie `GeschaeftWahlSheet` (Geocoding,
/// Filial-Sonderfall) — dort bliebe der Nutzen einer generischen Hülle
/// gering gegenüber dem Umbaurisiko.
struct AuswahlSheet<Item: Identifiable & Hashable, NeuAnlegenContent: View>: View {
    /// Einfachauswahl schließt bei Zeilen-Tap sofort automatisch;
    /// Mehrfachauswahl bleibt offen, bis der Haken-Button oben rechts
    /// getippt wird.
    enum Auswahlmodus {
        case einzel(Binding<Item?>)
        case mehrfach(Binding<Set<Item.ID>>)
    }

    let titel: String
    let items: [Item]
    /// Anzeigename je Eintrag — Grundlage für Zeilentext, Suche und
    /// alphabetische Gruppierung der Schnellnavigation.
    let name: (Item) -> String
    let modus: Auswahlmodus
    var suchPrompt: String = "Suchen"
    /// Ab dieser Eintragsanzahl erscheint die alphabetische
    /// Schnellnavigation an der rechten Kante (Issue-Vorgabe: „größer 100
    /// Einträgen").
    var schnellnavigationAbAnzahl: Int = 100
    /// Optionales SF-Symbol je Eintrag (z.B. `ArtikelKategorie/standardSymbol`)
    /// — `nil` (Default) zeigt reinen Text ohne Icon.
    var symbol: ((Item) -> String?)? = nil
    /// Zusätzliche, kleinere Sekundärzeile je Eintrag (z.B. Kurzadresse) —
    /// optional, Default keine.
    var zusatzZeile: ((Item) -> String?)? = nil
    var zeigeAbbrechen = false
    /// Label für die „+"-Neuanlage-Zeile, erhält den getrimmten Suchtext.
    /// `nil` blendet die Zeile grundsätzlich aus.
    var neuAnlegenTitel: ((String) -> String)? = nil
    /// Ob die „+"-Neuanlage-Zeile nur bei nicht-leerer Suche ohne exakten
    /// Treffer erscheint (Default, wie ``ArtikelAuswahlSheet``) oder immer
    /// sichtbar ist (z.B. für die Abteilungs-Zuordnungs-Sheets, deren „Neue
    /// Abteilung anlegen"-Zeile unabhängig vom Suchtext immer angeboten wird).
    var neuAnlegenNurBeiFehlendemTreffer = true
    /// Baut die Neuanlage-Ansicht für den getrimmten Suchtext. Die Ansicht
    /// ruft den übergebenen Callback mit dem fertig gesicherten Eintrag auf
    /// — das Sheet übernimmt danach Auswahl + Dismiss selbst.
    @ViewBuilder var neuAnlegenInhalt: (String, @escaping (Item) -> Void) -> NeuAnlegenContent
    /// Überschrift im Leerzustand (kein Eintrag, keine Neuanlage-Option
    /// sichtbar) — `nil` verwendet den generischen Standardtext.
    var leerTitel: String? = nil
    var leerBeschreibung: Text? = nil
    var leerSymbolName = "list.bullet"

    @Environment(\.dismiss) private var dismiss
    @State private var suchtext = ""
    @State private var zeigeNeuAnlegen = false
    @State private var suchtextBeiNeuAnlage = ""

    private var getrimmterSuchtext: String {
        suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gefilterteItems: [Item] {
        guard !getrimmterSuchtext.isEmpty else { return items }
        return items.filter { name($0).localizedCaseInsensitiveContains(getrimmterSuchtext) }
    }

    private var zeigtNeuAnlegenOption: Bool {
        guard neuAnlegenTitel != nil else { return false }
        guard neuAnlegenNurBeiFehlendemTreffer else { return true }
        guard !getrimmterSuchtext.isEmpty else { return false }
        return !items.contains { name($0).localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame }
    }

    /// Erste Zeichen der Anzeigenamen, groß geschrieben, als Sektionsschlüssel
    /// — z.B. für Ziffern-/Sonderzeichen-Namen bewusst „#" statt Absturz bei
    /// leerem Namen.
    private func sektionsSchluessel(fuer item: Item) -> String {
        guard let erstesZeichen = name(item).first else { return "#" }
        return String(erstesZeichen).uppercased()
    }

    private var gruppierteItems: [(schluessel: String, eintraege: [Item])] {
        let gruppen = Dictionary(grouping: gefilterteItems, by: sektionsSchluessel)
        return gruppen.keys.sorted().map { ($0, gruppen[$0]!.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }) }
    }

    private func istAusgewaehlt(_ item: Item) -> Bool {
        switch modus {
        case .einzel(let binding): return binding.wrappedValue == item
        case .mehrfach(let binding): return binding.wrappedValue.contains(item.id)
        }
    }

    private func auswaehlen(_ item: Item) {
        switch modus {
        case .einzel(let binding):
            binding.wrappedValue = item
            dismiss()
        case .mehrfach(let binding):
            if binding.wrappedValue.contains(item.id) {
                binding.wrappedValue.remove(item.id)
            } else {
                binding.wrappedValue.insert(item.id)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ZStack(alignment: .trailing) {
                    List {
                        ForEach(gruppierteItems, id: \.schluessel) { gruppe in
                            Section {
                                ForEach(gruppe.eintraege) { item in
                                    zeile(fuer: item)
                                }
                            } header: {
                                if items.count >= schnellnavigationAbAnzahl {
                                    Text(gruppe.schluessel)
                                }
                            }
                            .id(gruppe.schluessel)
                        }
                        if zeigtNeuAnlegenOption, let neuAnlegenTitel {
                            Button {
                                suchtextBeiNeuAnlage = getrimmterSuchtext
                                zeigeNeuAnlegen = true
                            } label: {
                                Label(neuAnlegenTitel(getrimmterSuchtext), systemImage: "plus.circle.fill")
                            }
                            .foregroundStyle(.tint)
                        }
                    }
                    .overlay {
                        if gefilterteItems.isEmpty && !zeigtNeuAnlegenOption {
                            ContentUnavailableView(
                                leerTitel ?? (suchtext.isEmpty ? "Keine Einträge" : "Keine Treffer"),
                                systemImage: leerSymbolName,
                                description: leerBeschreibung ?? (suchtext.isEmpty ? nil : Text("Nichts passt zu \u{201E}\(suchtext)\u{201C}"))
                            )
                        }
                    }
                    if items.count >= schnellnavigationAbAnzahl {
                        schnellnavigationsleiste(scrollProxy: scrollProxy)
                    }
                }
            }
            .navigationTitle(titel)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $suchtext, prompt: suchPrompt)
            .toolbar {
                if zeigeAbbrechen {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                }
                if case .mehrfach = modus {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            .sheet(isPresented: $zeigeNeuAnlegen) {
                neuAnlegenInhalt(suchtextBeiNeuAnlage) { neuerEintrag in
                    zeigeNeuAnlegen = false
                    auswaehlen(neuerEintrag)
                }
            }
        }
    }

    @ViewBuilder
    private func zeile(fuer item: Item) -> some View {
        Button {
            auswaehlen(item)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let symbolName = symbol?(item) {
                        Label(name(item), systemImage: symbolName)
                            .foregroundStyle(.primary)
                    } else {
                        Text(name(item))
                            .foregroundStyle(.primary)
                    }
                    if let zusatz = zusatzZeile?(item) {
                        Text(zusatz)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if istAusgewaehlt(item) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Schmale, alphabetische Schnellnavigationsleiste an der rechten Kante
    /// — SwiftUI bietet anders als `UITableView` kein natives
    /// `sectionIndexTitles`-Äquivalent. Ein Drag über die Leiste scrollt live
    /// zur jeweiligen Sektion.
    private func schnellnavigationsleiste(scrollProxy: ScrollViewProxy) -> some View {
        let schluessel = gruppierteItems.map(\.schluessel)
        return GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(schluessel, id: \.self) { schluessel in
                    Text(schluessel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { wert in
                        guard !schluessel.isEmpty else { return }
                        let anteil = min(max(wert.location.y / geo.size.height, 0), 0.9999)
                        let index = Int(anteil * CGFloat(schluessel.count))
                        withAnimation(.linear(duration: 0.05)) {
                            scrollProxy.scrollTo(schluessel[index], anchor: .top)
                        }
                    }
            )
        }
        .frame(width: 20)
        .padding(.trailing, 2)
    }
}
