import SwiftUI
import UniformTypeIdentifiers

/// Einstellung für den Speicherort der SwiftData-Datenbank.
///
/// Erlaubt, die Datenbankdatei in einen vom Anwender gewählten Ordner zu verlegen
/// (z.B. einen lokal gespiegelten Cloud-Ordner). Bewusst kein iCloud-/CloudKit-Sync —
/// reine Dateiverlagerung, siehe ``DatabaseLocationService``.
struct DatabaseLocationSettingsView: View {
    @State private var zeigeOrdnerauswahl = false
    @State private var fehlermeldung: String?
    @State private var erfolgreichGeaendert = false
    @State private var ausgewaehlterOrdner: URL? = DatabaseLocationService.gewaehlterOrdner()

    var body: some View {
        Form {
            Section {
                LabeledContent("Aktueller Speicherort") {
                    Text(ausgewaehlterOrdner != nil ? "Eigener Ordner" : "Standard (App-Speicher)")
                        .foregroundStyle(.secondary)
                }
                if let ordner = ausgewaehlterOrdner {
                    Text(ordner.lastPathComponent)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Anderen Ordner wählen…") {
                    zeigeOrdnerauswahl = true
                }
                if ausgewaehlterOrdner != nil {
                    Button("Auf Standard zurücksetzen", role: .destructive) {
                        DatabaseLocationService.aufStandardZuruecksetzen()
                        ausgewaehlterOrdner = nil
                        erfolgreichGeaendert = true
                    }
                }
            } footer: {
                Text("Änderungen werden erst nach einem Neustart der App wirksam. Bei Cloud-Sync-Ordnern (z.B. Dropbox) sollte immer nur ein Gerät gleichzeitig aktiv auf die Datenbank zugreifen — es gibt (noch) kein Konfliktmanagement wie bei iCloud-Sync.")
            }

            if erfolgreichGeaendert {
                Section {
                    Label("Gespeichert. Starte die App neu, damit die Änderung wirksam wird.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let fehlermeldung {
                Section {
                    Label(fehlermeldung, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Datenbank & Speicherort")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $zeigeOrdnerauswahl, allowedContentTypes: [.folder]) { ergebnis in
            switch ergebnis {
            case .success(let ordner):
                ordnerFestlegen(ordner)
            case .failure(let error):
                fehlermeldung = error.localizedDescription
            }
        }
    }

    private func ordnerFestlegen(_ ordner: URL) {
        do {
            let aktuelleStoreURL = DatabaseLocationService.aktiveStoreURL(schema: SchemaDefinition.schema)
            try DatabaseLocationService.ordnerFestlegen(ordner, aktuelleStoreURL: aktuelleStoreURL)
            ausgewaehlterOrdner = ordner
            erfolgreichGeaendert = true
            fehlermeldung = nil
        } catch {
            fehlermeldung = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        DatabaseLocationSettingsView()
    }
}
