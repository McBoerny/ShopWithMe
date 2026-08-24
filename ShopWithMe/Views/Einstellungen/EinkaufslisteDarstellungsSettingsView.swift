import SwiftUI

/// Einstellungen für die konfigurierbare Artikellisten-Darstellung beim Einkaufen.
/// Lässt sich aus der ``SettingsView`` über den Eintrag „Listendarstellung" erreichen.
///
/// Alle Werte werden über ``DarstellungsKey``-``AppStorage``-Einträge persistent
/// gespeichert und direkt von ``EinkaufslisteDarstellungsView`` ohne zusätzliche
/// Übergabe gelesen — eine Änderung hier wirkt sofort in der Einkaufs-Ansicht.
struct EinkaufslisteDarstellungsSettingsView: View {
    @AppStorage(DarstellungsKey.modus)        private var modus        = EinkaufslisteDarstellungsModus.liste
    @AppStorage(DarstellungsKey.listenTyp)    private var listenTyp    = ListenAnzeigeTyp.klassisch
    @AppStorage(DarstellungsKey.akkordeon)    private var akkordeon    = false
    @AppStorage(DarstellungsKey.fortschritt)  private var fortschritt  = false
    @AppStorage(DarstellungsKey.farbstreifen) private var farbstreifen = false
    @AppStorage(DarstellungsKey.spalten)      private var spaltenRaw   = KachelSpaltenanzahl.zwei.rawValue
    @AppStorage(DarstellungsKey.farbig)       private var farbig       = false

    var body: some View {
        Form {
            Section {
                Picker("Modus", selection: $modus) {
                    ForEach(EinkaufslisteDarstellungsModus.allCases, id: \.self) { m in
                        Text(m.bezeichnung).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } header: {
                Text("Darstellungsmodus")
            } footer: {
                switch modus {
                case .liste:
                    Text("Artikel in Abteilungsektionen, wahlweise als Zeilen oder Chips.")
                case .kacheln:
                    Text("Alle Artikel als Kachelraster ohne Abteilungsektionen.")
                }
            }

            if modus == .liste {
                Section("Liste") {
                    Picker("Anzeigetyp", selection: $listenTyp) {
                        ForEach(ListenAnzeigeTyp.allCases, id: \.self) { typ in
                            Label(typ.bezeichnung, systemImage: typ.systemImage).tag(typ)
                        }
                    }

                    Toggle(isOn: $akkordeon) {
                        Label("Akkordeon", systemImage: "chevron.up.chevron.down")
                    }

                    Toggle(isOn: $fortschritt) {
                        Label("Fortschrittsbalken", systemImage: "chart.bar.fill")
                    }

                    if listenTyp == .klassisch {
                        Toggle(isOn: $farbstreifen) {
                            Label("Farbiger Streifen je Artikel", systemImage: "rectangle.leadinghalf.filled")
                        }
                    }
                }
            }

            if modus == .kacheln {
                Section("Kacheln") {
                    Picker("Spalten", selection: $spaltenRaw) {
                        ForEach(KachelSpaltenanzahl.allCases, id: \.rawValue) { s in
                            Text(s.bezeichnung).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $farbig) {
                        Label("Abteilung-Farbhintergrund", systemImage: "paintpalette.fill")
                    }
                }
            }
        }
        .navigationTitle("Listendarstellung")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        EinkaufslisteDarstellungsSettingsView()
    }
}
