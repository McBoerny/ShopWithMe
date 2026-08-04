import SwiftUI
import SwiftData

/// Protokoll aller abgeschlossenen Einkaufsbesuche in einem Geschäft — Zeitpunkt,
/// Dauer und Produktanzahl aus ``GeschaeftBesuch`` (seit 2026-08-04, siehe
/// `docs/GESCHAEFTS_AGGREGATE.md`; vormals direkt aus ``Einkaufsvorgang``
/// abgeleitet, GitHub #32) — dauerhaft, unabhängig davon, ob die
/// ``Einkaufsliste`` des ursprünglichen Einkaufs noch existiert.
struct GeschaeftBesuchsProtokollView: View {
    let geschaeft: Geschaeft
    @Query private var besuche: [GeschaeftBesuch]

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
        let geschaeftID = geschaeft.persistentModelID
        _besuche = Query(
            filter: #Predicate<GeschaeftBesuch> { $0.geschaeft?.persistentModelID == geschaeftID },
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
            ForEach(besuche) { besuch in
                HStack {
                    VStack(alignment: .leading) {
                        Text(besuch.startZeit, format: Self.datumsFormat)
                        Text("\(besuch.anzahlProdukte) Produkte")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(dauerText(von: besuch.startZeit, bis: besuch.endZeit))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if besuche.isEmpty {
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
    /// 5 Min.“). Unter einer Minute (z.B. Einkauf versehentlich sofort wieder
    /// abgeschlossen) rundet ``dauerFormatter`` sowohl Stunden als auch Minuten auf
    /// 0 und liefert wegen `zeroFormattingBehavior = .dropAll` gar keinen Text —
    /// das wird hier gesondert abgefangen, statt eine leere Zeile anzuzeigen.
    private func dauerText(von start: Date, bis ende: Date) -> String {
        guard ende.timeIntervalSince(start) >= 60 else { return "< 1 Min." }
        return Self.dauerFormatter.string(from: start, to: ende) ?? "< 1 Min."
    }
}

#Preview {
    NavigationStack {
        GeschaeftBesuchsProtokollView(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, GeschaeftBesuch.self], inMemory: true)
}
