import SwiftUI
import SwiftData

/// Protokoll aller abgeschlossenen Einkaufsbesuche in einem Geschäft — Zeitpunkt
/// und Dauer, direkt aus den ohnehin vorhandenen ``Einkaufsvorgang``-Daten
/// (``Einkaufsvorgang/startZeit``/``Einkaufsvorgang/endZeit``) abgeleitet, ohne
/// eigenes Datenmodell (GitHub #32) — jeder abgeschlossene Einkaufsvorgang in
/// diesem Geschäft *ist* bereits ein Besuchsprotokoll-Eintrag.
struct GeschaeftBesuchsProtokollView: View {
    let geschaeft: Geschaeft
    @Query private var einkaufsvorgaenge: [Einkaufsvorgang]

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
        let geschaeftID = geschaeft.persistentModelID
        _einkaufsvorgaenge = Query(
            filter: #Predicate<Einkaufsvorgang> {
                $0.geschaeft?.persistentModelID == geschaeftID && $0.endZeit != nil
            },
            sort: [SortDescriptor(\.startZeit, order: .reverse)]
        )
    }

    private static let datumsFormat: Date.FormatStyle = .dateTime.day().month().year().hour().minute()

    private static let dauerFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    var body: some View {
        List {
            ForEach(einkaufsvorgaenge) { vorgang in
                if let endZeit = vorgang.endZeit {
                    HStack {
                        Text(vorgang.startZeit, format: Self.datumsFormat)
                        Spacer()
                        Text(dauerText(von: vorgang.startZeit, bis: endZeit))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if einkaufsvorgaenge.isEmpty {
                ContentUnavailableView(
                    "Noch keine Einkäufe",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Abgeschlossene Einkäufe erscheinen hier mit Zeitpunkt und Dauer.")
                )
            }
        }
        .navigationTitle("Besuchsprotokoll")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Formatierte Dauer zwischen `start` und `ende` (z.B. „23 Min.“ oder „1 Std.
    /// 5 Min.“) — leerer String im (praktisch nicht vorkommenden) Fall, dass der
    /// Formatter keinen Text liefert.
    private func dauerText(von start: Date, bis ende: Date) -> String {
        Self.dauerFormatter.string(from: start, to: ende) ?? ""
    }
}

#Preview {
    NavigationStack {
        GeschaeftBesuchsProtokollView(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Einkaufsvorgang.self], inMemory: true)
}
