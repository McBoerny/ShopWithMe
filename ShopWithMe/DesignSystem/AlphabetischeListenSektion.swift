import SwiftUI

/// Zeigt bereits sortierte `items` innerhalb eines `List`-Kontexts alphabetisch:
/// - bei ≥ `sektionSchwelle` Einträgen als buchstabengegliederte `Section`en
///   mit `sectionIndexLabel` — iOS zeigt daraufhin eine A–Z-Sidebar wie im Adressbuch,
/// - darunter als flache `ForEach`-Reihe (optional mit Fußzeile in einer Section).
///
/// Die Items müssen **bereits alphabetisch sortiert** übergeben werden —
/// die Komponente übernimmt nur das Buchstaben-Grouping, keine Sortierung.
/// Muss innerhalb eines `List { }` eingesetzt werden.
struct AlphabetischeListenSektion<Item: Identifiable, RowContent: View>: View {
    private let items: [Item]
    private let name: (Item) -> String
    private let sektionSchwelle: Int
    private let loeschen: ((IndexSet, [Item]) -> Void)?
    private let fusszeile: String?
    private let zeile: (Item) -> RowContent

    /// - Parameters:
    ///   - items: Bereits alphabetisch sortierte Einträge.
    ///   - name: Liefert den Anzeigenamen eines Eintrags — Grundlage für den Anfangsbuchstaben.
    ///   - sektionSchwelle: Ab dieser Anzahl werden Buchstaben-Sektionen angezeigt (Standard: 50).
    ///   - loeschen: Callback für Wischgeste; erhält `IndexSet` und die zugehörige Gruppe.
    ///   - fusszeile: Optionaler Erklärungstext, der im flachen Modus als Section-Footer erscheint.
    ///   - zeile: View-Builder für den Inhalt einer einzelnen Zeile.
    init(
        _ items: [Item],
        name: @escaping (Item) -> String,
        sektionSchwelle: Int = 50,
        loeschen: ((IndexSet, [Item]) -> Void)? = nil,
        fusszeile: String? = nil,
        @ViewBuilder zeile: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.name = name
        self.sektionSchwelle = sektionSchwelle
        self.loeschen = loeschen
        self.fusszeile = fusszeile
        self.zeile = zeile
    }

    private var buchstabenGruppen: [(buchstabe: String, eintraege: [Item])] {
        let gruppen = Dictionary(grouping: items) { name($0).alphabetischerAnfangsbuchstabe }
        return gruppen.keys.sorted().map { b in (b, gruppen[b] ?? []) }
    }

    var body: some View {
        if items.count >= sektionSchwelle {
            ForEach(buchstabenGruppen, id: \.buchstabe) { gruppe in
                Section(gruppe.buchstabe) {
                    ForEach(gruppe.eintraege) { item in
                        zeile(item)
                    }
                    .onDelete(perform: loeschen.map { fn in { fn($0, gruppe.eintraege) } })
                }
                .sectionIndexLabel(Text(gruppe.buchstabe))
            }
        } else if let fusszeile {
            Section {
                ForEach(items) { item in zeile(item) }
                .onDelete(perform: loeschen.map { fn in { fn($0, items) } })
            } footer: {
                Text(fusszeile)
            }
        } else {
            ForEach(items) { item in zeile(item) }
            .onDelete(perform: loeschen.map { fn in { fn($0, items) } })
        }
    }
}
