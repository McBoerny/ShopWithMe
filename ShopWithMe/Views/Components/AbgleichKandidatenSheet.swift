import SwiftUI
import SwiftData

/// Entkoppeltes Anzeige-/Aktions-Modell für ``AbgleichKandidatenSheet`` —
/// bewusst nicht direkt an ``SyncAbgleichKandidat`` (persistierte
/// Warteschlange) gekoppelt, der Aufrufer übersetzt seine Kandidaten in
/// `AbgleichAnzeige` und übergibt die passenden Aktions-Closures. Ursprünglich
/// (GitHub #86, Teil 2) auch vom einmaligen Sync-Ordner-Beitritts-Abgleich
/// genutzt — diese zweite Quelle wurde entfernt (siehe
/// `docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitt 48), die Entkopplung
/// bleibt trotzdem bestehen, da sie die Sheet-View unabhängig vom konkreten
/// Kandidaten-Typ hält. Seit GitHub #151 aus `SyncOrdnerSettingsView` in eine
/// eigene Datei ausgelagert — ``RootView`` präsentiert dieselbe Sheet-View
/// jetzt zusätzlich direkt aus einer aktiven Rückfrage heraus, nicht mehr nur
/// über die passive Zeile in den Sync-Einstellungen.
struct AbgleichAnzeige: Identifiable {
    let id: UUID
    let lokalerName: String
    let fremderName: String
    /// Nutzer wählt „gleich", Parameter ist der beizubehaltende Name
    /// (lokaler oder fremder, je nach getroffener Wahl).
    let aufGleich: (String) -> Void
    /// Nutzer wählt „unterschiedlich" (auch der Standard bei
    /// Nicht-Entscheidung) — legt das zurückgehaltene Objekt aktiv an.
    let aufUnterschiedlich: () -> Void

    /// Übersetzt die laufende, persistierte ``SyncAbgleichKandidat``-Warteschlange
    /// in Anzeige-Modelle mit den passenden Aktions-Closures — einzige Stelle
    /// dieser Übersetzung (Single Source of Truth), von ``SyncOrdnerSettingsView``
    /// UND ``RootView`` gleichermaßen genutzt.
    @MainActor
    static func liste(aus kandidaten: [SyncAbgleichKandidat], context: ModelContext) -> [AbgleichAnzeige] {
        kandidaten.map { kandidat in
            AbgleichAnzeige(
                id: kandidat.id, lokalerName: kandidat.lokalerName, fremderName: kandidat.fremderName,
                aufGleich: { gewaehlterName in
                    SyncSnapshotImportService.abgleichKandidatBestaetigen(kandidat, gewaehlterName: gewaehlterName, context: context)
                },
                aufUnterschiedlich: {
                    SyncSnapshotImportService.abgleichKandidatAlsUnterschiedlichBestaetigen(kandidat, context: context)
                }
            )
        }
    }
}

/// Aktive Rückfrage für mehrdeutige Bereich-B-Merge-Kandidaten (Geschäft/
/// Artikel/Einkaufsliste) aus der laufenden, persistierten
/// ``SyncAbgleichKandidat``-Warteschlange. Pro Kandidat: „gleich" (mit Wahl,
/// welcher Name bleibt) oder „unterschiedlich" (Standard bei
/// Nicht-Entscheidung) — beide bleiben dann als getrennte Einträge bestehen
/// und lassen sich bei Bedarf später manuell per Löschen bereinigen, siehe
/// `docs/GESCHAEFTSERKENNUNG.md`.
struct AbgleichKandidatenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kandidaten: [AbgleichAnzeige]
    let onFertig: () -> Void

    private enum Entscheidung: Hashable {
        case unterschiedlich
        case gleichLokalerName
        case gleichFremderName
    }

    @State private var entscheidungen: [UUID: Entscheidung] = [:]

    var body: some View {
        NavigationStack {
            List(kandidaten) { kandidat in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("„\(kandidat.lokalerName)“").bold()
                        Text("könnte identisch sein mit „\(kandidat.fremderName)“ vom anderen Gerät")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Entscheidung", selection: entscheidungBinding(fuer: kandidat)) {
                        Text("Unterschiedlich").tag(Entscheidung.unterschiedlich)
                        Text("Gleich – „\(kandidat.lokalerName)“ behalten").tag(Entscheidung.gleichLokalerName)
                        Text("Gleich – „\(kandidat.fremderName)“ übernehmen").tag(Entscheidung.gleichFremderName)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Mögliche Duplikate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", action: fertig)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Diese Einträge wurden unterschiedlich benannt oder stimmen nicht exakt überein — deshalb fragt die App hier nach, statt automatisch zu entscheiden. Unentschieden bleibt: getrennte Einträge.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .interactiveDismissDisabled()
    }

    private func entscheidungBinding(fuer kandidat: AbgleichAnzeige) -> Binding<Entscheidung> {
        Binding(
            get: { entscheidungen[kandidat.id] ?? .unterschiedlich },
            set: { entscheidungen[kandidat.id] = $0 }
        )
    }

    private func fertig() {
        for kandidat in kandidaten {
            switch entscheidungen[kandidat.id] ?? .unterschiedlich {
            case .unterschiedlich:
                kandidat.aufUnterschiedlich()
            case .gleichLokalerName:
                kandidat.aufGleich(kandidat.lokalerName)
            case .gleichFremderName:
                kandidat.aufGleich(kandidat.fremderName)
            }
        }
        dismiss()
        onFertig()
    }
}
