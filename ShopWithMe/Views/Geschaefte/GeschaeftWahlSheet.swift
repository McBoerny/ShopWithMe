import SwiftUI
import SwiftData

/// Sheet zur Auswahl eines Geschäfts für einen Belegscan, dessen Geschäft nicht
/// automatisch über ``Geschaeft/passendes(fuerErkannterName:erkannteAdressen:unter:)``
/// zugeordnet werden konnte — siehe `docs/BELEGSCAN.md` → „Automatischer
/// Geschäfts-Abgleich“.
///
/// Existiert das gewünschte Geschäft noch nicht, lässt es sich direkt hier über die
/// bestehende ``GeschaeftStammdatenEditView`` anlegen (vorausgefüllt mit dem
/// erkannten Namen und der erkannten Adresse, deren Koordinaten dafür automatisch
/// geocodiert werden) und wird danach automatisch ausgewählt — analog
/// ``KaufEintragZuordnenSheet``s Artikel-Neuanlage. Existiert bereits ein exakt
/// namensgleiches Geschäft mit einer **anderen** Adresse als der erkannten, bleibt
/// „neu anlegen“ trotzdem verfügbar (``zweiteFilialeMoeglich``) — für den Fall
/// einer zweiten Filiale derselben Kette (GitHub #19).
struct GeschaeftWahlSheet: View {
    /// Der auf dem Beleg erkannte Geschäftsname, falls vorhanden — nur zur Anzeige
    /// und als Vorbelegung der Suche/Neuanlage.
    let erkannterName: String
    /// Alle auf dem Beleg erkannten Geschäftsadressen (GitHub #132, z.B. Filiale UND
    /// Betreiber-/Zentraladresse) — bei mehr als einer bietet das Sheet eine Auswahl
    /// an, deren Ergebnis (``gewaehlteAdresse``) die Vorbelegung für „neu anlegen“
    /// liefert (siehe ``neuesGeschaeftAnlegen()``).
    let erkannteAdressen: [String]
    /// Geschäfts-Pflicht (siehe `docs/ARTIKEL_PRODUKT_MODELL.md`): non-optional
    /// statt vormals `Geschaeft?` — dieses Sheet bietet seit der Geschäfts-Pflicht
    /// keine „Kein Geschäft"-Option mehr an, jeder Aufruf von `onAuswahl` liefert
    /// ein tatsächliches Geschäft (bestehend oder neu angelegt).
    let onAuswahl: (Geschaeft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Geschaeft.name) private var alleGeschaefte: [Geschaeft]
    @State private var suchtext: String
    @State private var neuesGeschaeftEntwurf: Geschaeft?
    @State private var erstelleGeschaeft = false
    /// Vom Anwender gewählte Adresse, falls ``erkannteAdressen`` mehrere Kandidaten
    /// enthält — sonst automatisch die einzige (oder keine) erkannte Adresse.
    @State private var gewaehlteAdresse: String

    init(erkannterName: String, erkannteAdressen: [String] = [], onAuswahl: @escaping (Geschaeft) -> Void) {
        self.erkannterName = erkannterName
        self.erkannteAdressen = erkannteAdressen
        self.onAuswahl = onAuswahl
        _suchtext = State(initialValue: erkannterName)
        _gewaehlteAdresse = State(initialValue: erkannteAdressen.first ?? "")
    }

    /// Namen, die unter allen Geschäften mehrfach vorkommen — steuert, ob
    /// ``GeschaeftZeile`` (unten) zusätzlich die Kurzadresse anzeigt, um
    /// namensgleiche Geschäfte unterscheidbar zu machen.
    private var namenMitDuplikaten: Set<String> {
        Geschaeft.namenMitDuplikaten(unter: alleGeschaefte)
    }

    private var getrimmterSuchtext: String {
        suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gefilterteGeschaefte: [Geschaeft] {
        guard !getrimmterSuchtext.isEmpty else { return alleGeschaefte }
        return alleGeschaefte.filter { $0.name.localizedCaseInsensitiveContains(getrimmterSuchtext) }
    }

    private var existiertGenau: Bool {
        alleGeschaefte.contains {
            $0.name.localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame
        }
    }

    private var getrimmteErkannteAdresse: String {
        gewaehlteAdresse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ob trotz eines exakt namensgleichen Geschäfts weiterhin „neu anlegen“
    /// angeboten wird — nur wenn dieses bestehende Geschäft bereits eine
    /// **andere**, nicht-leere Adresse hat als die auf dem Beleg erkannte (z.B.
    /// eine zweite Filiale derselben Kette, GitHub #19).
    private var zweiteFilialeMoeglich: Bool {
        guard !getrimmteErkannteAdresse.isEmpty,
              let bestehendes = alleGeschaefte.first(where: {
                  $0.name.localizedCaseInsensitiveCompare(getrimmterSuchtext) == .orderedSame
              }),
              let bestehendeAdresse = bestehendes.adresse, !bestehendeAdresse.isEmpty
        else { return false }
        return !bestehendeAdresse.localizedCaseInsensitiveContains(getrimmteErkannteAdresse)
            && !getrimmteErkannteAdresse.localizedCaseInsensitiveContains(bestehendeAdresse)
    }

    var body: some View {
        NavigationStack {
            List {
                if !erkannterName.isEmpty {
                    Section {
                        Text("Auf dem Foto erkannt: „\(erkannterName)“")
                            .foregroundStyle(.secondary)
                    }
                }

                if erkannteAdressen.count > 1 {
                    Section {
                        Picker("Adresse", selection: $gewaehlteAdresse) {
                            ForEach(erkannteAdressen, id: \.self) { adresse in
                                Text(adresse).tag(adresse)
                            }
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text("Mehrere Adressen erkannt")
                    } footer: {
                        Text("Für ein neu anzulegendes Geschäft wird die ausgewählte Adresse übernommen.")
                    }
                }

                Section {
                    if !getrimmterSuchtext.isEmpty && (!existiertGenau || zweiteFilialeMoeglich) {
                        Button {
                            neuesGeschaeftAnlegen()
                        } label: {
                            Label(
                                existiertGenau
                                    ? "„\(getrimmterSuchtext)“ mit dieser Adresse neu anlegen"
                                    : "„\(getrimmterSuchtext)“ neu anlegen",
                                systemImage: "plus.circle.fill"
                            )
                        }
                        .disabled(erstelleGeschaeft)
                    }

                    ForEach(gefilterteGeschaefte) { geschaeft in
                        Button {
                            onAuswahl(geschaeft)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(geschaeft.name)
                                    .foregroundStyle(.primary)
                                if namenMitDuplikaten.contains(geschaeft.name.lowercased()), let kurzeAdresse = geschaeft.kurzeAdresse {
                                    Text(kurzeAdresse)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Der ausgewählte Name wird für künftige Scans als Alias für dieses Geschäft gemerkt.")
                }
            }
            .searchable(text: $suchtext, prompt: "Geschäft suchen oder anlegen")
            .navigationTitle("Geschäft wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .sheet(item: $neuesGeschaeftEntwurf) { entwurf in
                GeschaeftStammdatenEditView(geschaeft: entwurf, istNeu: true) { neuesGeschaeft in
                    onAuswahl(neuesGeschaeft)
                    dismiss()
                }
            }
        }
    }

    /// Baut den Entwurf für ein neues Geschäft, vorbelegt mit dem Suchtext als Name
    /// und (falls vorhanden) der erkannten Adresse. Wurde eine Adresse erkannt, wird
    /// sie sofort geocodiert (``GeschaeftErkennungService/koordinaten(fuerAdresse:)``)
    /// — bewusst NICHT der aktuelle GPS-Standort des Anwenders, siehe
    /// `docs/BELEGSCAN.md`. Schlägt das Geocoding fehl, öffnet sich der Entwurf
    /// trotzdem, nur ohne Koordinaten (``Geschaeft/adresse`` bleibt optional).
    private func neuesGeschaeftAnlegen() {
        let getrimmteAdresse = gewaehlteAdresse.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            erstelleGeschaeft = true
            defer { erstelleGeschaeft = false }
            let entwurf = Geschaeft(
                name: getrimmterSuchtext,
                typen: [GeschaeftTyp.mitNamen("Lebensmittel", symbolName: "cart.fill", context: modelContext)],
                adresse: getrimmteAdresse.isEmpty ? nil : getrimmteAdresse
            )
            if !getrimmteAdresse.isEmpty,
               let koordinaten = await GeschaeftErkennungService.koordinaten(fuerAdresse: getrimmteAdresse) {
                entwurf.breitengrad = koordinaten.breitengrad
                entwurf.laengengrad = koordinaten.laengengrad
            }
            neuesGeschaeftEntwurf = entwurf
        }
    }
}

#Preview {
    GeschaeftWahlSheet(erkannterName: "REWE Center Musterstadt") { (_: Geschaeft) in }
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self], inMemory: true)
}
