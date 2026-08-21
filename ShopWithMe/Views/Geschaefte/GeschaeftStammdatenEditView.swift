import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Anlegen/Bearbeiten der Stammdaten (Name, Typ, Adresse, Standort) eines
/// ``Geschaeft``s.
///
/// Bei einem neuen Geschäft (`istNeu == true`) wird es erst beim Sichern in den
/// Model-Context eingefügt (Abbrechen verwirft es folgenlos) — bis dahin lassen
/// sich auch die Abteilungen bereits verfeinern (``GeschaeftAbteilungenSektion``,
/// GitHub #56), z.B. beim Akzeptieren eines per Geolocation neu erkannten
/// Geschäfts. Bei einem bestehenden Geschäft bleibt das ``GeschaeftDetailView``
/// vorbehalten.
///
/// Der Standort-Abschnitt (GitHub #24) zeigt eine Karte mit dem aktuellen Pin,
/// sobald ``Geschaeft/koordinate`` gesetzt ist. Drei Wege dorthin: „Aktuellen
/// Standort verwenden” (GPS + Reverse-Geocoding füllt Adresse **und** Koordinaten),
/// Adresse eintippen und mit dem Return-Key bestätigen (Geocoding setzt Koordinaten
/// und zentriert die Karte — auch wenn bereits eine Koordinate gesetzt war,
/// GitHub #120), oder direkt auf die Karte tippen, um den Pin exakt zu setzen
/// (befüllt das Adressfeld nicht — Adresse ist nur per Texteingabe oder Scan
/// setzbar, GitHub #120). Ein Slider darunter setzt ``Geschaeft/erkennungsradius``
/// (GitHub #41, Grundlage für
/// ``GeschaeftErkennungService/istBekannterTreffer(_:fuer:)``) —
/// als `MapCircle` direkt auf der Karte eingezeichnet.
struct GeschaeftStammdatenEditView: View {
    @Bindable var geschaeft: Geschaeft
    let istNeu: Bool
    /// Wird nach erfolgreichem Sichern eines neuen Geschäfts (`istNeu == true`)
    /// aufgerufen — z.B. um es in ``EinkaufenView`` nach dem per Ladenerkennung
    /// angebotenen Hinzufügen automatisch als aktives Geschäft zu übernehmen.
    var onGespeichert: ((Geschaeft) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \GeschaeftTyp.sortIndex) private var alleTypen: [GeschaeftTyp]
    @State private var standortWirdErmittelt = false
    @State private var zeigeNeuerTyp = false
    @State private var kartenKameraPosition: MapCameraPosition = .automatic

    var body: some View {
        if istNeu {
            navigationInhalt
        } else {
            SessionLeaseGate { navigationInhalt }
        }
    }

    private var navigationInhalt: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $geschaeft.name)
                    TextField("Marke / Kette", text: Binding(
                        get: { geschaeft.markenname ?? "" },
                        set: { geschaeft.markenname = $0.isEmpty ? nil : $0 }
                    ))
                } footer: {
                    Text("Optionaler Markenname (z.B. Rewe), um Filialen in der Liste zu gruppieren.")
                }

                Section {
                    ForEach(alleTypen) { typ in
                        Button {
                            typToggeln(typ)
                        } label: {
                            HStack {
                                Label(typ.name, systemImage: typ.symbolName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if geschaeft.typen.contains(typ) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            // Ohne contentShape reagiert nur der sichtbare Inhalt
                            // (Label/Checkmark) auf Taps, nicht der leere
                            // Spacer-Bereich dazwischen (GitHub #38).
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        zeigeNeuerTyp = true
                    } label: {
                        Label("Neuen Geschäftstyp anlegen", systemImage: "plus")
                    }
                } header: {
                    Text("Typ")
                } footer: {
                    Text("Mehrfachauswahl möglich, z.B. Drogerie + Lebensmittel. Mindestens ein Typ muss gewählt sein. Ist ein Geschäftstyp noch nicht aufgeführt, kannst du hier auch einen neuen anlegen.")
                }

                // Nur beim erstmaligen Anlegen (GitHub #56) — bei einem bestehenden
                // Geschäft bleibt die Kategorien-Verwaltung ausschließlich in
                // ``GeschaeftDetailView``, um sie nicht doppelt anzuzeigen.
                if istNeu {
                    GeschaeftAbteilungenSektion(geschaeft: geschaeft)
                }

                Section("Adresse (optional)") {
                    TextField(
                        "Adresse",
                        text: Binding(
                            get: { geschaeft.adresse ?? "" },
                            set: { geschaeft.adresse = $0.isEmpty ? nil : $0 }
                        ),
                        axis: .vertical
                    )
                    .onSubmit {
                        Task { await adresseGeokodierenUndKarteZentrieren() }
                    }
                }

                Section {
                    if let koordinate = geschaeft.koordinate {
                        MapReader { proxy in
                            Map(position: $kartenKameraPosition) {
                                Marker(geschaeft.name.isEmpty ? "Geschäft" : geschaeft.name, coordinate: koordinate)
                                MapCircle(center: koordinate, radius: geschaeft.erkennungsradius)
                                    .foregroundStyle(Color.accentColor.opacity(0.15))
                                    .stroke(Color.accentColor, lineWidth: 1)
                            }
                            .frame(height: 200)
                            .onTapGesture { bildschirmPunkt in
                                guard let neueKoordinate = proxy.convert(bildschirmPunkt, from: .local) else { return }
                                pinSetzen(neueKoordinate)
                            }
                        }
                        .listRowInsets(EdgeInsets())

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Erkennungsradius: \(Int(geschaeft.erkennungsradius)) m")
                            Slider(value: $geschaeft.erkennungsradius, in: 20...500, step: 10)
                        }
                    }

                    Button {
                        Task { await aktuellenStandortVerwenden() }
                    } label: {
                        if standortWirdErmittelt {
                            ProgressView()
                        } else {
                            Label("Aktuellen Standort verwenden", systemImage: "location.fill")
                        }
                    }
                    .disabled(standortWirdErmittelt)
                } header: {
                    Text("Standort")
                } footer: {
                    Text(geschaeft.koordinate == nil
                         ? "Adresse eingeben und bestätigen oder den aktuellen Standort verwenden, um die Karte zu sehen."
                         : "Tippe auf die Karte, um den Standort-Pin exakt zu setzen. Der eingezeichnete Kreis zeigt den Umkreis, innerhalb dessen die App dieses Geschäft automatisch erkennt — bei einem großen Gelände (z.B. Baumarkt) größer wählen, bei dicht benachbarten Geschäften kleiner.")
                }

                if !istNeu {
                    Section {
                        LabeledContent("Abgeschlossene Einkäufe", value: "\(geschaeft.anzahlEinkaufsvorgaenge)")
                        if geschaeft.anzahlEinkaufsvorgaenge != 0 {
                            Button("Zähler zurücksetzen", role: .destructive) {
                                geschaeft.zaehlerZuruecksetzen(context: modelContext)
                            }
                        }
                    } footer: {
                        Text("Zählt, wie oft hier ein Einkauf abgeschlossen wurde. Das Zurücksetzen löscht nur den Zähler, nicht die Preishistorie.")
                    }
                }
            }
            .navigationTitle(istNeu ? "Neues Geschäft" : "Geschäft bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if istNeu {
                            // Live-Fund EinkaufenView (Build 308, `DatabaseLeaseService/gehoertZuAktuellemContext(_:context:)`).
                            guard DatabaseLeaseService.gehoertZuAktuellemContext(geschaeft, context: modelContext) else { return }
                            Task {
                                await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                    modelContext.insert(geschaeft)
                                }
                                onGespeichert?(geschaeft)
                                dismiss()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(geschaeft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || geschaeft.typen.isEmpty)
                }
            }
        }
        .onAppear {
            if let koordinate = geschaeft.koordinate {
                kartenKameraPosition = .region(kartenRegion(fuer: koordinate, radius: geschaeft.erkennungsradius))
            }
        }
        .sheet(isPresented: $zeigeNeuerTyp) {
            NeuerGeschaeftsTypSheet(naechsterSortIndex: (alleTypen.map(\.sortIndex).max() ?? -1) + 1) { typ in
                geschaeft.typen.append(typ)
            }
        }
    }

    private func typToggeln(_ typ: GeschaeftTyp) {
        var aktuelle = geschaeft.typen
        if let index = aktuelle.firstIndex(of: typ) {
            aktuelle.remove(at: index)
        } else {
            aktuelle.append(typ)
        }
        geschaeft.typen = aktuelle
    }

    /// Kartenregion, groß genug, um den ``MapCircle`` mit `radius` vollständig zu
    /// zeigen (GitHub #41) — mindestens 500m Kantenlänge, sonst das Dreifache des
    /// Radius. Wird an drei expliziten Stellen zur Kamerapositionierung genutzt
    /// (`.onAppear`, Adress-Geocoding, GPS-Button), aber nicht live an
    /// ``Geschaeft/koordinate`` gebunden — der Nutzer kann die Karte danach frei
    /// zoomen/verschieben (GitHub #42).
    private func kartenRegion(fuer koordinate: CLLocationCoordinate2D, radius: Double) -> MKCoordinateRegion {
        let spanne = max(500, radius * 3)
        return MKCoordinateRegion(center: koordinate, latitudinalMeters: spanne, longitudinalMeters: spanne)
    }

    /// Setzt den Standort-Pin auf `koordinate`. Befüllt das Adressfeld bewusst
    /// nicht per Reverse-Geocoding — die Adresse ist ausschließlich über manuelle
    /// Texteingabe oder Belegscan setzbar (GitHub #120).
    private func pinSetzen(_ koordinate: CLLocationCoordinate2D) {
        geschaeft.koordinate = koordinate
    }

    /// Geokodiert die eingegebene ``Geschaeft/adresse``, setzt die Koordinaten und
    /// zentriert die Karte auf das Ergebnis (GitHub #120) — auch dann, wenn bereits
    /// eine Koordinate gesetzt war (z.B. per GPS-Button). Wird beim Return-Key im
    /// Adressfeld ausgelöst.
    private func adresseGeokodierenUndKarteZentrieren() async {
        guard let adresse = geschaeft.adresse, !adresse.isEmpty else { return }
        guard let koordinatenPaar = await GeschaeftErkennungService.koordinaten(fuerAdresse: adresse) else { return }
        let koordinate = CLLocationCoordinate2D(latitude: koordinatenPaar.breitengrad, longitude: koordinatenPaar.laengengrad)
        geschaeft.koordinate = koordinate
        kartenKameraPosition = .region(kartenRegion(fuer: koordinate, radius: geschaeft.erkennungsradius))
    }

    /// Übernimmt den aktuellen GPS-Standort als Koordinaten **und** überschreibt
    /// die Adresse mit dem per Reverse-Geocoding ermittelten Ergebnis und zentriert
    /// die Karte — bewusst ohne Rückfrage, da der Anwender mit diesem Button
    /// explizit den aktuellen Standort übernehmen möchte.
    private func aktuellenStandortVerwenden() async {
        standortWirdErmittelt = true
        defer { standortWirdErmittelt = false }
        guard let koordinatenPaar = await GeschaeftErkennungService.koordinatenAusAktuellerPosition() else { return }
        let koordinate = CLLocationCoordinate2D(latitude: koordinatenPaar.breitengrad, longitude: koordinatenPaar.laengengrad)
        geschaeft.koordinate = koordinate
        kartenKameraPosition = .region(kartenRegion(fuer: koordinate, radius: geschaeft.erkennungsradius))
        if let adresse = await GeschaeftErkennungService.adresse(fuerKoordinaten: koordinate) {
            geschaeft.adresse = adresse
        }
    }
}

#Preview {
    GeschaeftStammdatenEditView(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]), istNeu: true)
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
