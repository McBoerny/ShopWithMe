import SwiftUI
import SwiftData
import MapKit

/// Einstiegspunkt zum Einkaufen: zeigt sofort beim Öffnen die Einkaufsliste der
/// ausgewählten ``Einkaufsliste`` an — optional gruppiert nach Regal eines
/// gewählten Geschäfts. Ein passender ``Einkaufsvorgang`` (für die Kombination aus
/// gewählter Liste und gewähltem Geschäft) wird dafür automatisch angelegt, sobald
/// keiner läuft; ein manueller "Start" ist nicht nötig, Artikel lassen sich
/// jederzeit abhaken.
///
/// Prüft beim Öffnen zusätzlich per ``GeschaeftErkennungService``, ob sich der
/// Anwender in der Nähe eines bekannten Ladens befindet, und zeigt dafür ggf. ein
/// ``GeschaeftVorschlagBanner`` an — siehe `docs/GESCHAEFTSERKENNUNG.md`. Unabhängig
/// davon lässt sich im Geschäft-Menü der Toolbar jederzeit manuell ein neues
/// Geschäft anlegen (analog ``GeschaeftListView``) oder „Geschäfte in der Nähe“
/// öffnen — die Standort-Erkennung ist also nie der einzige Weg.
///
/// Das Geschäft-Menü zeigt die meistgenutzten Geschäfte
/// (``GeschaeftHaeufigkeitService``, GitHub #31) vorab in einer eigenen
/// „Favoriten“-Sektion, bevor die übrigen Geschäfte folgen.
struct EinkaufenView: View {
    @Query(sort: \Geschaeft.name) private var geschaefte: [Geschaeft]
    @Query(sort: \Einkaufsliste.erstelltAm) private var einkaufslisten: [Einkaufsliste]
    @Query(filter: #Predicate<Einkaufsvorgang> { $0.endZeit == nil })
    private var offeneEinkaufsvorgaenge: [Einkaufsvorgang]
    @Query(filter: #Predicate<Einkaufsvorgang> { $0.endZeit != nil })
    private var abgeschlosseneEinkaufsvorgaenge: [Einkaufsvorgang]
    @Query(sort: \IgnorierterGeschaeftsVorschlag.ignoriertAm, order: .reverse)
    private var ignorierteVorschlaege: [IgnorierterGeschaeftsVorschlag]
    @Environment(\.modelContext) private var modelContext

    @State private var ausgewaehltesGeschaeft: Geschaeft?
    @State private var ausgewaehlteListe: Einkaufsliste?
    @State private var zeigeNeueListe = false
    @State private var geschaeftVorschlag: GeschaeftVorschlag?
    @State private var geschaeftEntwurfAusVorschlag: Geschaeft?
    @State private var zeigeAlleInDerNaehe = false
    /// Treibt die Nachfrage „Standort für <Name> speichern?“ nach Auswahl eines
    /// Geschäfts ohne Koordinaten (siehe ``pruefeStandortErgaenzung(fuer:)``).
    @State private var geschaeftFuerStandortErgaenzung: Geschaeft?
    @State private var geschaeftFuerAdresseEingabe: Geschaeft?
    @State private var zeigeStandortErgaenzenFehler = false

    private var aktuellerEinkauf: Einkaufsvorgang? {
        guard let ausgewaehlteListe else { return nil }
        return offeneEinkaufsvorgaenge.first {
            $0.geschaeft == ausgewaehltesGeschaeft && $0.einkaufsliste == ausgewaehlteListe
        }
    }

    /// Meistgenutzte Geschäfte für die priorisierte Anzeige im Geschäfts-Menü
    /// (GitHub #31).
    private var favoritenGeschaefte: [Geschaeft] {
        GeschaeftHaeufigkeitService.favoriten(aus: abgeschlosseneEinkaufsvorgaenge)
    }

    /// ``geschaefte`` ohne die bereits in ``favoritenGeschaefte`` gezeigten — damit
    /// das Menü keine Dubletten zeigt.
    private var uebrigeGeschaefte: [Geschaeft] {
        let favoritenIDs = Set(favoritenGeschaefte.map(\.persistentModelID))
        return geschaefte.filter { !favoritenIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        NavigationStack {
            hauptinhalt
                .safeAreaInset(edge: .top) { vorschlagBanner }
                .navigationTitle("Einkaufen")
                .toolbar { einkaufenToolbar }
        }
        .onAppear {
            Task {
                await listeSicherstellen()
                await einkaufSicherstellen()
            }
            Task {
                await geschaeftErkennungPruefen()
            }
        }
        .onChange(of: ausgewaehltesGeschaeft) { _, neu in
            Task { await einkaufSicherstellen() }
            pruefeStandortErgaenzung(fuer: neu)
        }
        .onChange(of: ausgewaehlteListe) { _, _ in Task { await einkaufSicherstellen() } }
        // Reagiert darauf, dass ein Einkaufsvorgang abgeschlossen wurde (verschwindet
        // dadurch aus `offeneEinkaufsvorgaenge`): legt sofort den nächsten an, damit die
        // gerade abgehakten Artikel des beendeten Einkaufs aus der Ansicht verschwinden,
        // statt bis zum nächsten Tab-Wechsel als "ProgressView" hängen zu bleiben.
        .onChange(of: offeneEinkaufsvorgaenge.count) { _, _ in Task { await einkaufSicherstellen() } }
        .sheet(isPresented: $zeigeNeueListe) {
            NeueEinkaufslisteSheet { liste in
                ausgewaehlteListe = liste
            }
        }
        .sheet(item: $geschaeftEntwurfAusVorschlag) { entwurf in
            GeschaeftStammdatenEditView(geschaeft: entwurf, istNeu: true) { neuesGeschaeft in
                ausgewaehltesGeschaeft = neuesGeschaeft
            }
        }
        .sheet(isPresented: $zeigeAlleInDerNaehe) {
            GeschaeftAlleInDerNaeheSheet(
                vorhandeneGeschaefte: geschaefte,
                ignorierteVorschlaege: ignorierteVorschlaege,
                auswaehlen: { geschaeft in ausgewaehltesGeschaeft = geschaeft },
                hinzufuegen: { mapItem in
                    geschaeftEntwurfAusVorschlag = GeschaeftErkennungService.entwurf(aus: mapItem, context: modelContext)
                },
                hinzufuegenMitStandort: { entwurf in geschaeftEntwurfAusVorschlag = entwurf },
                wiederAufnehmen: { vorschlag in wiederAufnehmenVorschlag(vorschlag) }
            )
        }
        .confirmationDialog(
            "Standort für „\(geschaeftFuerStandortErgaenzung?.name ?? "")“ speichern?",
            isPresented: Binding(
                get: { geschaeftFuerStandortErgaenzung != nil },
                set: { neu in if !neu { geschaeftFuerStandortErgaenzung = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Aktuellen Standort verwenden") {
                guard let ziel = geschaeftFuerStandortErgaenzung else { return }
                Task { await standortFuerGeschaeftUebernehmen(ziel) }
            }
            if let ziel = geschaeftFuerStandortErgaenzung, ziel.adresse != nil {
                Button("Aus hinterlegter Adresse ermitteln") {
                    guard let adresse = ziel.adresse else { return }
                    Task { await adresseGeocodierenUndUebernehmen(adresse, fuer: ziel) }
                }
            } else {
                Button("Adresse eingeben") {
                    geschaeftFuerAdresseEingabe = geschaeftFuerStandortErgaenzung
                }
            }
            Button("Nicht jetzt", role: .cancel) {}
        } message: {
            Text("Für die automatische Ladenerkennung an diesem Ort fehlen noch Koordinaten.")
        }
        .sheet(item: $geschaeftFuerAdresseEingabe) { geschaeft in
            AdresseEingebenSheet(geschaeft: geschaeft)
        }
        .alert("Standort nicht verfügbar", isPresented: $zeigeStandortErgaenzenFehler) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Der Standort konnte nicht ermittelt werden. Prüfe den Standortzugriff bzw. die hinterlegte Adresse.")
        }
    }

    @ViewBuilder
    private var hauptinhalt: some View {
        if let ausgewaehlteListe, let einkauf = aktuellerEinkauf {
            EinkaufslisteView(geschaeft: ausgewaehltesGeschaeft, einkaufsliste: ausgewaehlteListe, einkaufsvorgang: einkauf)
        } else {
            ProgressView()
        }
    }

    /// Reaktion auf einen Tipp auf „Hinzufügen“ im ``GeschaeftVorschlagBanner`` für
    /// einen noch unbekannten Apple-Maps-Laden — als eigene Methode ausgelagert
    /// (statt inline im Banner-Closure), damit der Swift-Typchecker den
    /// umgebenden `body` noch in angemessener Zeit auflösen kann.
    private func vorschlagHinzufuegen(_ mapItem: MKMapItem) {
        geschaeftEntwurfAusVorschlag = GeschaeftErkennungService.entwurf(aus: mapItem, context: modelContext)
        geschaeftVorschlag = nil
    }

    @ViewBuilder
    private var vorschlagBanner: some View {
        if let geschaeftVorschlag {
            GeschaeftVorschlagBanner(
                vorschlag: geschaeftVorschlag,
                aktivieren: { geschaeft in
                    ausgewaehltesGeschaeft = geschaeft
                    self.geschaeftVorschlag = nil
                },
                hinzufuegen: { mapItem in vorschlagHinzufuegen(mapItem) },
                verwerfen: { self.geschaeftVorschlag = nil },
                ignorieren: {
                    ignorierenVorschlag(geschaeftVorschlag)
                    self.geschaeftVorschlag = nil
                },
                alleInDerNaeheAnzeigen: {
                    self.geschaeftVorschlag = nil
                    zeigeAlleInDerNaehe = true
                }
            )
        }
    }

    @ToolbarContentBuilder
    private var einkaufenToolbar: some ToolbarContent {
        if !einkaufslisten.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                einkaufslistenMenu
            }
        }
        ToolbarItem(placement: .principal) {
            geschaeftMenu
        }
    }

    /// Inhalt des Geschäft-Auswahl-`Picker`s im Toolbar-`Menu` — als eigene
    /// `@ViewBuilder`-Property ausgelagert (statt inline im `Menu`-Closure), damit
    /// der Swift-Typchecker die Toolbar-Verschachtelung noch in angemessener Zeit
    /// auflösen kann (sonst „unable to type-check this expression in reasonable
    /// time“).
    @ViewBuilder
    private var geschaeftPicker: some View {
        if !geschaefte.isEmpty {
            Picker("Geschäft", selection: $ausgewaehltesGeschaeft) {
                Text("Kein Geschäft").tag(Optional<Geschaeft>.none)
                if !favoritenGeschaefte.isEmpty {
                    Section("Favoriten") {
                        ForEach(favoritenGeschaefte) { geschaeft in
                            Text(geschaeft.name).tag(geschaeft as Geschaeft?)
                        }
                    }
                }
                ForEach(uebrigeGeschaefte) { geschaeft in
                    Text(geschaeft.name).tag(geschaeft as Geschaeft?)
                }
            }
        }
    }

    /// Das Einkaufslisten-Auswahl-`Menu` im Toolbar (`.topBarLeading`-Platzierung)
    /// — als eigene `@ViewBuilder`-Property ausgelagert, siehe ``geschaeftPicker``
    /// für die Begründung (Typchecker-Timeout bei zu tief verschachteltem
    /// Toolbar-Inhalt).
    @ViewBuilder
    private var einkaufslistenMenu: some View {
        Menu {
            Picker("Einkaufsliste", selection: $ausgewaehlteListe) {
                ForEach(einkaufslisten) { liste in
                    Text(liste.name).tag(liste as Einkaufsliste?)
                }
            }
            Button {
                zeigeNeueListe = true
            } label: {
                Label("Neue Liste …", systemImage: "plus")
            }
        } label: {
            Label(ausgewaehlteListe?.name ?? "Liste", systemImage: "checklist")
        }
    }

    /// Das Geschäft-Auswahl-`Menu` im Toolbar (`.principal`-Platzierung) — als
    /// eigene `@ViewBuilder`-Property ausgelagert, siehe ``geschaeftPicker`` für die
    /// Begründung (Typchecker-Timeout bei zu tief verschachteltem Toolbar-Inhalt).
    @ViewBuilder
    private var geschaeftMenu: some View {
        Menu {
            geschaeftPicker
            Button {
                geschaeftEntwurfAusVorschlag = neuerLeererGeschaeftsEntwurf()
            } label: {
                Label("Neues Geschäft hinzufügen", systemImage: "plus")
            }
            Button {
                zeigeAlleInDerNaehe = true
            } label: {
                Label("Geschäfte in der Nähe…", systemImage: "location.magnifyingglass")
            }
        } label: {
            // Explizites HStack statt `Label(_:systemImage:)`, damit der
            // Geschäftsname zuverlässig direkt neben dem Icon erscheint (ein
            // `Label` in `.principal`-Platzierung zeigt je nach verfügbarem Platz
            // sonst nur das Icon an, siehe GitHub #16).
            HStack(spacing: 4) {
                Image(systemName: "cart.fill")
                Text(ausgewaehltesGeschaeft?.name ?? "Geschäft")
            }
        }
    }

    /// Baut einen leeren Geschäfts-Entwurf mit dem Standard-Typ „Lebensmittel“ für
    /// den „Neues Geschäft hinzufügen“-Menüeintrag. Als eigene Funktion ausgelagert
    /// (statt inline im Button-Closure), damit der Swift-Typchecker die umgebende
    /// `Menu`/`ViewBuilder`-Verschachtelung im Toolbar noch in angemessener Zeit
    /// auflösen kann.
    private func neuerLeererGeschaeftsEntwurf() -> Geschaeft {
        Geschaeft(name: "", typen: [GeschaeftTyp.mitNamen("Lebensmittel", symbolName: "cart.fill", context: modelContext)])
    }

    /// Fragt ``GeschaeftErkennungService`` nach einem Vorschlag für den aktuellen
    /// Standort. Schlägt kein bereits als ``ausgewaehltesGeschaeft`` gewähltes
    /// Geschäft erneut vor. Bereits ignorierte Vorschläge (``ignorierteVorschlaege``)
    /// werden vom Service selbst aussortiert.
    private func geschaeftErkennungPruefen() async {
        guard let vorschlag = await GeschaeftErkennungService.vorschlag(
            vorhandeneGeschaefte: geschaefte,
            ignorierteVorschlaege: ignorierteVorschlaege
        ) else {
            geschaeftVorschlag = nil
            return
        }
        if case .bekannt(let geschaeft) = vorschlag, geschaeft == ausgewaehltesGeschaeft {
            geschaeftVorschlag = nil
            return
        }
        geschaeftVorschlag = vorschlag
    }

    /// Merkt sich `vorschlag` dauerhaft als ignoriert (siehe
    /// ``IgnorierterGeschaeftsVorschlag``). Diskrete Einzelaktion → Micro-Lease
    /// (siehe `docs/DATABASE_CONCURRENCY.md` → „Vollständiger Schreibvorgang-Katalog“).
    private func ignorierenVorschlag(_ vorschlag: GeschaeftVorschlag) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                let koordinaten = vorschlag.koordinaten
                let ignoriert = IgnorierterGeschaeftsVorschlag(
                    name: vorschlag.name,
                    breitengrad: koordinaten?.breitengrad,
                    laengengrad: koordinaten?.laengengrad
                )
                modelContext.insert(ignoriert)
            }
        }
    }

    /// Entfernt alle zu `vorschlag` passenden ``IgnorierterGeschaeftsVorschlag``-
    /// Einträge wieder — macht ``ignorierenVorschlag(_:)`` rückgängig, aufgerufen aus
    /// „Alle Geschäfte in der Nähe“.
    private func wiederAufnehmenVorschlag(_ vorschlag: GeschaeftVorschlag) {
        let treffer = GeschaeftErkennungService.ignorierteEintraege(fuer: vorschlag, in: ignorierteVorschlaege)
        guard !treffer.isEmpty else { return }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                for eintrag in treffer { modelContext.delete(eintrag) }
            }
        }
    }

    /// Prüft nach jeder Auswahl eines Geschäfts (Toolbar-Picker, Standort-Vorschlag,
    /// „Alle Geschäfte in der Nähe“ oder direkt nach dem Anlegen über
    /// ``GeschaeftStammdatenEditView``), ob dafür noch keine Koordinaten hinterlegt
    /// sind, und bietet in diesem Fall über ``geschaeftFuerStandortErgaenzung`` eine
    /// Nachfrage an, sie nachträglich zu ergänzen — siehe
    /// `docs/GESCHAEFTSERKENNUNG.md`.
    private func pruefeStandortErgaenzung(fuer geschaeft: Geschaeft?) {
        guard let geschaeft, geschaeft.breitengrad == nil else { return }
        geschaeftFuerStandortErgaenzung = geschaeft
    }

    /// Übernimmt den aktuellen GPS-Standort als Koordinaten für ein bereits
    /// bestehendes Geschäft (im Unterschied zu ``GeschaeftErkennungService/entwurfAusAktuellemStandort()``,
    /// das einen neuen Entwurf baut). Diskrete Einzelaktion → Micro-Lease.
    private func standortFuerGeschaeftUebernehmen(_ geschaeft: Geschaeft) async {
        guard let koordinaten = await GeschaeftErkennungService.koordinatenAusAktuellerPosition() else {
            zeigeStandortErgaenzenFehler = true
            return
        }
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            geschaeft.breitengrad = koordinaten.breitengrad
            geschaeft.laengengrad = koordinaten.laengengrad
        }
    }

    /// Geocodiert eine bereits am Geschäft hinterlegte Adresse und übernimmt die
    /// ermittelten Koordinaten. Diskrete Einzelaktion → Micro-Lease.
    private func adresseGeocodierenUndUebernehmen(_ adresse: String, fuer geschaeft: Geschaeft) async {
        guard let koordinaten = await GeschaeftErkennungService.koordinaten(fuerAdresse: adresse) else {
            zeigeStandortErgaenzenFehler = true
            return
        }
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            geschaeft.breitengrad = koordinaten.breitengrad
            geschaeft.laengengrad = koordinaten.laengengrad
        }
    }

    /// Stellt sicher, dass ``ausgewaehlteListe`` gesetzt ist: übernimmt die erste
    /// vorhandene ``Einkaufsliste``, oder legt (falls noch keine existiert) über
    /// ``Einkaufsliste/standard(context:)`` eine erste an.
    private func listeSicherstellen() async {
        guard ausgewaehlteListe == nil else { return }
        if let erste = einkaufslisten.first {
            ausgewaehlteListe = erste
            return
        }
        var neue: Einkaufsliste?
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            neue = Einkaufsliste.standard(context: modelContext)
        }
        ausgewaehlteListe = neue
    }

    /// Legt bei Bedarf einen neuen ``Einkaufsvorgang`` für die aktuell gewählte
    /// Kombination aus Liste und Geschäft an, damit die Einkaufsliste immer sofort
    /// angezeigt wird. Diskrete Einzelaktion → Micro-Lease (siehe
    /// `docs/DATABASE_CONCURRENCY.md` → „Vollständiger Schreibvorgang-Katalog“).
    private func einkaufSicherstellen() async {
        guard let ausgewaehlteListe, aktuellerEinkauf == nil else { return }
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            let vorgang = Einkaufsvorgang(geschaeft: ausgewaehltesGeschaeft, einkaufsliste: ausgewaehlteListe)
            modelContext.insert(vorgang)
        }
    }
}

/// Sheet zum Anlegen einer neuen ``Einkaufsliste`` — aufrufbar direkt aus dem
/// Listen-Menü in ``EinkaufenView`` für schnellen Zugriff während des Einkaufens.
private struct NeueEinkaufslisteSheet: View {
    let onErstellt: (Einkaufsliste) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, z.B. \"Wocheneinkauf\"", text: $name)
                    .font(.title3)
            }
            .navigationTitle("Neue Liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let liste = Einkaufsliste(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task {
                            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                                modelContext.insert(liste)
                            }
                            onErstellt(liste)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Sheet zum Eingeben einer Adresse für ein bereits bestehendes ``Geschaeft`` ohne
/// Koordinaten (siehe ``EinkaufenView/pruefeStandortErgaenzung(fuer:)``) —
/// geocodiert die eingegebene Adresse (``GeschaeftErkennungService/koordinaten(fuerAdresse:)``)
/// und übernimmt bei Erfolg sowohl die Adresse als auch die ermittelten
/// Koordinaten. Arbeitet mit lokalem Entwurfs-Zustand (analog
/// `NeueEinkaufslisteSheet`), Übernahme erst bei „Sichern“ in einem Micro-Lease.
private struct AdresseEingebenSheet: View {
    let geschaeft: Geschaeft

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var adresse = ""
    @State private var ermittleKoordinaten = false
    @State private var zeigeFehler = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Adresse, z.B. „Marktstraße 1, 12345 Musterstadt“", text: $adresse, axis: .vertical)
            }
            .navigationTitle(geschaeft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        Task { await sichern() }
                    }
                    .disabled(adresse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ermittleKoordinaten)
                }
            }
            .alert("Adresse nicht gefunden", isPresented: $zeigeFehler) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Für diese Adresse konnten keine Koordinaten ermittelt werden. Bitte prüfe die Eingabe.")
            }
        }
    }

    private func sichern() async {
        ermittleKoordinaten = true
        defer { ermittleKoordinaten = false }
        let getrimmteAdresse = adresse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let koordinaten = await GeschaeftErkennungService.koordinaten(fuerAdresse: getrimmteAdresse) else {
            zeigeFehler = true
            return
        }
        await DatabaseLeaseService.performMicroLease(context: modelContext) {
            geschaeft.adresse = getrimmteAdresse
            geschaeft.breitengrad = koordinaten.breitengrad
            geschaeft.laengengrad = koordinaten.laengengrad
        }
        dismiss()
    }
}

/// Banner in ``EinkaufenView``, das einen per ``GeschaeftErkennungService`` in der
/// Nähe erkannten Laden vorschlägt. Erscheint nur, wenn tatsächlich ein relevanter
/// Laden erkannt wurde (z.B. nicht zu Hause) — siehe `docs/GESCHAEFTSERKENNUNG.md`.
private struct GeschaeftVorschlagBanner: View {
    let vorschlag: GeschaeftVorschlag
    let aktivieren: (Geschaeft) -> Void
    let hinzufuegen: (MKMapItem) -> Void
    let verwerfen: () -> Void
    /// Merkt sich den Vorschlag dauerhaft als ignoriert (``IgnorierterGeschaeftsVorschlag``)
    /// — anders als ``verwerfen`` erscheint er danach nicht mehr automatisch, bis der
    /// Anwender ihn über „Alle Geschäfte in der Nähe“ wieder aufnimmt.
    let ignorieren: () -> Void
    /// Öffnet die Liste aller Läden im Umkreis (``GeschaeftErkennungService/alleInDerNaeheRadius``),
    /// inkl. bereits ignorierter — zum nachträglichen manuellen Auswählen oder
    /// Wiederaufnehmen.
    let alleInDerNaeheAnzeigen: () -> Void

    private var untertitel: String {
        switch vorschlag {
        case .bekannt: return "Als Geschäft für diesen Einkauf auswählen?"
        case .unbekannt: return "Noch nicht in deiner Geschäfte-Liste."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("In der Nähe: \(vorschlag.name)")
                    .font(.subheadline.bold())
                Text(untertitel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(vorschlag.aktionsTitel, action: aktion)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Menu {
                Button("Verwerfen", action: verwerfen)
                Button {
                    ignorieren()
                } label: {
                    Label("Diesen Laden ignorieren", systemImage: "eye.slash")
                }
                Button {
                    alleInDerNaeheAnzeigen()
                } label: {
                    Label("Alle Geschäfte in der Nähe…", systemImage: "location.magnifyingglass")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard()
        .padding(.horizontal)
    }

    private func aktion() {
        switch vorschlag {
        case .bekannt(let geschaeft): aktivieren(geschaeft)
        case .unbekannt(let mapItem): hinzufuegen(mapItem)
        }
    }
}

/// Sheet „Alle Geschäfte in der Nähe“ (``GeschaeftErkennungService/alleInDerNaeheRadius``,
/// 100m) — Ergänzung zum automatischen Einzelvorschlag (``GeschaeftVorschlagBanner``):
/// zeigt alle Läden im Umkreis, inkl. bereits ignorierter (mit Möglichkeit, sie
/// wieder aufzunehmen), damit der Anwender nachträglich manuell auswählen kann, auch
/// wenn der automatische Vorschlag verworfen, ignoriert wurde oder gar nicht
/// erschienen ist.
private struct GeschaeftAlleInDerNaeheSheet: View {
    let vorhandeneGeschaefte: [Geschaeft]
    let ignorierteVorschlaege: [IgnorierterGeschaeftsVorschlag]
    let auswaehlen: (Geschaeft) -> Void
    let hinzufuegen: (MKMapItem) -> Void
    /// Übernimmt einen per ``GeschaeftErkennungService/entwurfAusAktuellemStandort()``
    /// gebauten leeren Entwurf mit den aktuellen Standort-Koordinaten — für den Fall,
    /// dass hier kein Laden gefunden wurde, siehe Leer-Zustand unten in ``body``.
    let hinzufuegenMitStandort: (Geschaeft) -> Void
    let wiederAufnehmen: (GeschaeftVorschlag) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var eintraege: [GeschaeftInDerNaeheEintrag]?
    @State private var laeuft = true
    @State private var ermittleStandort = false
    @State private var zeigeStandortFehler = false

    var body: some View {
        NavigationStack {
            Group {
                if laeuft {
                    ProgressView("Suche in der Nähe…")
                } else if let eintraege, !eintraege.isEmpty {
                    List(eintraege) { eintrag in
                        GeschaeftInDerNaeheZeile(
                            eintrag: eintrag,
                            auswaehlen: {
                                switch eintrag.vorschlag {
                                case .bekannt(let geschaeft): auswaehlen(geschaeft)
                                case .unbekannt(let mapItem): hinzufuegen(mapItem)
                                }
                                dismiss()
                            },
                            wiederAufnehmen: {
                                wiederAufnehmen(eintrag.vorschlag)
                                // Optimistisches lokales Update: `eintraege` ist ein
                                // einmaliger Snapshot (siehe `.task` unten), löst also
                                // nicht automatisch neu auf, wenn `wiederAufnehmen` den
                                // zugrundeliegenden `IgnorierterGeschaeftsVorschlag`
                                // async löscht. Ohne dieses Update bliebe die Zeile bis
                                // zum erneuten Öffnen des Sheets fälschlich auf
                                // "Ignoriert"/"Wieder aufnehmen" stehen.
                                if let index = self.eintraege?.firstIndex(where: { $0.id == eintrag.id }) {
                                    self.eintraege?[index].istIgnoriert = false
                                }
                            }
                        )
                    }
                } else {
                    ContentUnavailableView {
                        Label("Keine Geschäfte gefunden", systemImage: "location.slash")
                    } description: {
                        Text("Im Umkreis von 100m wurde kein Laden gefunden. Prüfe, ob der Standortzugriff erlaubt ist.")
                    } actions: {
                        Button("Diesen Ort als neues Geschäft anlegen") {
                            Task { await neuesGeschaeftAnAktuellemStandort() }
                        }
                        .disabled(ermittleStandort)
                    }
                }
            }
            .navigationTitle("Geschäfte in der Nähe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task {
            eintraege = await GeschaeftErkennungService.alleInDerNaehe(
                vorhandeneGeschaefte: vorhandeneGeschaefte,
                ignorierteVorschlaege: ignorierteVorschlaege
            )
            laeuft = false
        }
        .alert("Standort nicht verfügbar", isPresented: $zeigeStandortFehler) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Der aktuelle Standort konnte nicht ermittelt werden. Prüfe, ob der Standortzugriff für ShopWithMe erlaubt ist.")
        }
    }

    /// Ermittelt den aktuellen Standort erneut (unabhängig vom Ergebnis der Suche
    /// oben) und übergibt einen leeren Geschäfts-Entwurf mit dessen Koordinaten an
    /// ``hinzufuegenMitStandort`` — für den Fall, dass an diesem Ort kein Laden über
    /// Apple Maps gefunden wurde, der Anwender ihn aber trotzdem protokollieren und
    /// manuell anlegen möchte. Zeigt bei fehlender Standortberechtigung/-ermittlung
    /// einen Hinweis statt still nichts zu tun.
    private func neuesGeschaeftAnAktuellemStandort() async {
        ermittleStandort = true
        defer { ermittleStandort = false }
        guard let entwurf = await GeschaeftErkennungService.entwurfAusAktuellemStandort(context: modelContext) else {
            zeigeStandortFehler = true
            return
        }
        hinzufuegenMitStandort(entwurf)
        dismiss()
    }
}

/// Eine Zeile in ``GeschaeftAlleInDerNaeheSheet``: ignorierte Einträge zeigen statt
/// der Auswählen/Hinzufügen-Aktion einen „Wieder aufnehmen“-Button.
private struct GeschaeftInDerNaeheZeile: View {
    let eintrag: GeschaeftInDerNaeheEintrag
    let auswaehlen: () -> Void
    let wiederAufnehmen: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(eintrag.vorschlag.name)
                if eintrag.istIgnoriert {
                    Text("Ignoriert")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if eintrag.istIgnoriert {
                Button("Wieder aufnehmen", action: wiederAufnehmen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(eintrag.vorschlag.aktionsTitel, action: auswaehlen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

/// Die Einkaufsliste einer ``Einkaufsliste`` für einen laufenden Einkaufsvorgang —
/// bei gewähltem Geschäft nach Regal gruppiert, sonst flach.
private struct EinkaufslisteView: View {
    let geschaeft: Geschaeft?
    let einkaufsliste: Einkaufsliste
    let einkaufsvorgang: Einkaufsvorgang

    @Environment(\.modelContext) private var modelContext

    @State private var zeigeBelegScanAngebot = false
    @State private var zeigeBelegScan = false
    @State private var zeigeArtikelHinzufuegen = false
    /// Beleg-/Preisschild-Scan direkt für das aktuell gewählte ``geschaeft`` über den
    /// Toolbar-Button — unabhängig vom Abschluss-Angebot (``zeigeBelegScanAngebot``),
    /// das an den laufenden ``einkaufsvorgang`` gebunden ist.
    @State private var zeigeBelegScanFuerGeschaeft = false
    @State private var zeigePreisschildScanFuerGeschaeft = false
    /// Blendet zusätzlich zu den offenen auch die in diesem Einkauf bereits
    /// abgehakten Artikel ein (durchgestrichen) — per kurzem Tap auf die
    /// Schnellauswahl (``SchnellauswahlButton``) umschaltbar.
    @State private var zeigeAbgehakteArtikel = false
    /// Übergeht für diesen Einkauf den Verfügbarkeitsfilter (siehe
    /// ``verfuegbarkeitsgefiltert(_:)``) und zeigt alle Artikel der Einkaufsliste,
    /// auch bislang nicht als verfügbar geltende — zum Entdecken/Abhaken bislang
    /// unbekannter Artikel, wodurch sie für dieses Geschäft als verfügbar gelernt
    /// werden (siehe ``ArtikelVerfuegbarkeitService``). Per langem Tap auf die
    /// Schnellauswahl umschaltbar (Lernmodus); gilt nur für diesen Einkaufsvorgang.
    @State private var zeigeAlleArtikel = false
    /// Zeigt nach ``einkaufAbschliessen()`` einmalig den Hinweis, dass
    /// ``WarengruppenDistanzService`` eine deutliche Abweichung von der gelernten
    /// Warengruppen-Reihenfolge festgestellt hat (``Geschaeft/umbauVerdacht``,
    /// Architekturvorschlag Abschnitt 4.4/7).
    @State private var zeigeUmbauHinweis = false

    private var abgehakteArtikelIDs: Set<PersistentIdentifier> {
        Set(einkaufsvorgang.kaufEintraege.compactMap { $0.artikel?.persistentModelID })
    }

    /// Artikel, die noch auf ``einkaufsliste`` stehen.
    private var offeneArtikel: [Artikel] {
        einkaufsliste.eintraege.compactMap(\.artikel)
    }

    /// Artikel, die in diesem Einkaufsvorgang bereits abgehakt wurden.
    private var abgehakteArtikel: [Artikel] {
        einkaufsvorgang.kaufEintraege.compactMap(\.artikel).filter { abgehakteArtikelIDs.contains($0.persistentModelID) }
    }

    /// Der „Einkauf abschließen“-Button am unteren Bildschirmrand: zeigt die Anzahl
    /// bereits abgehakter Artikel im Label und wechselt von neutral (kein Artikel
    /// abgehakt) zu akzentfarben (mindestens einer abgehakt), damit auf einen
    /// Blick erkennbar ist, ob ein Abschließen bereits sinnvoll ist (GitHub #26).
    /// Zwei Zweige statt eines gemeinsamen `.buttonStyle(...)`-Ausdrucks, da
    /// `.glass`/`.glassProminent` unterschiedliche konkrete Typen sind.
    @ViewBuilder
    private var einkaufAbschliessenButton: some View {
        let titel = abgehakteArtikel.isEmpty
            ? "Einkauf abschließen"
            : "Einkauf abschließen (\(abgehakteArtikel.count))"
        if abgehakteArtikel.isEmpty {
            Button(titel, action: einkaufAbschliessen)
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                .padding()
        } else {
            Button(titel, action: einkaufAbschliessen)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private func einkaufAbschliessen() {
        Task {
            // Abschließen + Lernschritt sind fachlich eine Aktion → ein
            // gemeinsamer Micro-Lease statt zwei getrennter (siehe
            // `docs/DATABASE_CONCURRENCY.md` → „Gebündelte Aktionen“).
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                einkaufsvorgang.abschliessen()
                ShelfOrderLearningService.lernenAus(einkaufsvorgang, context: modelContext)
                WarengruppenDistanzService.verarbeiteEinkauf(einkaufsvorgang, context: modelContext)
            }
            zeigeUmbauHinweis = geschaeft?.umbauVerdacht ?? false
            zeigeBelegScanAngebot = true
        }
    }

    /// Ist ein Geschäft gewählt, blendet dies standardmäßig Artikel aus, die darin
    /// (noch) nicht als verfügbar gelten (siehe ``ArtikelVerfuegbarkeitService``).
    /// Per ``zeigeAlleArtikel`` kann der Anwender diesen Filter für den laufenden
    /// Einkauf übergehen.
    private func verfuegbarkeitsgefiltert(_ artikel: [Artikel]) -> [Artikel] {
        guard let geschaeft, !zeigeAlleArtikel else { return artikel }
        return artikel.filter { ArtikelVerfuegbarkeitService.istVerfuegbar($0, in: geschaeft, context: modelContext) }
    }

    /// Die aktuell darzustellenden Artikel — abhängig von ``zeigeAbgehakteArtikel``.
    private var artikelAufListe: [Artikel] {
        let basis = zeigeAbgehakteArtikel ? offeneArtikel + abgehakteArtikel : offeneArtikel
        return verfuegbarkeitsgefiltert(basis)
    }

    private struct Gruppe: Identifiable {
        let regal: Regal
        var artikel: [Artikel]
        var id: PersistentIdentifier { regal.persistentModelID }
    }

    /// Eine Gruppe von Artikeln derselben Artikelkategorie, die sich keinem Regal
    /// zuordnen lässt — z.B. weil das Geschäft keine Regale besitzt oder die
    /// Kategorie darin keinem Regal zugeordnet ist. Artikel ohne eigene Kategorie
    /// fallen dabei automatisch in die Kategorie "Sonstiges".
    private struct KategorieGruppe: Identifiable {
        let kategorie: ArtikelKategorie
        var artikel: [Artikel]
        var id: PersistentIdentifier { kategorie.persistentModelID }
    }

    /// Die für ``geschaeft`` führende Kategorie eines Artikels (siehe
    /// ``Artikel/fuehrendeKategorie(inGeschaeft:context:)``) — hat ein Artikel
    /// mehrere Kategorien, entscheidet das (nicht eine Duplizierung über mehrere
    /// Regal-Bereiche), welchem Regal/welcher Sektion er beim Einkaufen zugeordnet
    /// wird.
    private func effektiveKategorie(fuer artikel: Artikel) -> ArtikelKategorie {
        artikel.fuehrendeKategorie(inGeschaeft: geschaeft, context: modelContext)
    }

    /// Artikel, die sich keinem Regal zuordnen lassen (kein Geschäft gewählt oder
    /// die Kategorie darin keinem Regal zugeordnet) — werden dennoch angezeigt, nur
    /// eben in nach Kategorie gruppierten Sektionen.
    private var sonstigeArtikel: [Artikel] {
        guard let geschaeft else { return artikelAufListe }
        return artikelAufListe.filter { geschaeft.regal(fuer: effektiveKategorie(fuer: $0)) == nil }
    }

    private var gruppen: [Gruppe] {
        guard let geschaeft else { return [] }
        var nachRegal: [PersistentIdentifier: Gruppe] = [:]
        for artikel in artikelAufListe {
            guard let regal = geschaeft.regal(fuer: effektiveKategorie(fuer: artikel)) else { continue }
            nachRegal[regal.persistentModelID, default: Gruppe(regal: regal, artikel: [])].artikel.append(artikel)
        }
        let reihenfolge = ShelfOrderLearningService.effektiveReihenfolge(fuer: geschaeft, context: modelContext)
        let position = Dictionary(uniqueKeysWithValues: reihenfolge.enumerated().map { ($1.persistentModelID, $0) })
        return nachRegal.values.sorted {
            (position[$0.regal.persistentModelID] ?? .max) < (position[$1.regal.persistentModelID] ?? .max)
        }
    }

    /// ``sonstigeArtikel``, gruppiert nach Artikelkategorie und sortiert über
    /// ``WarengruppenDistanzService`` — der gelernten, paarweisen Warengruppen-
    /// Distanzmatrix dieses Geschäfts (Architekturvorschlag Abschnitt 4.2/4.3,
    /// GitHub #36). Das ist insbesondere für Geschäfte ohne Regale die alleinige
    /// Sortiergrundlage. Startpunkt der Sortierung ist ``zuletztAbgehakteKategorie``
    /// — die verbleibende Liste wird so nach jeder Abhakung dynamisch neu
    /// sortiert, ausgehend vom aktuellen (impliziten) Standort. Ohne genügend
    /// gelernte Daten (``WarengruppenDistanzService/genuegendDatenVerfuegbar(fuer:)``)
    /// bleibt es bei alphabetischer Reihenfolge.
    private var sonstigeGruppen: [KategorieGruppe] {
        var nachKategorie: [PersistentIdentifier: KategorieGruppe] = [:]
        for artikel in sonstigeArtikel {
            let kategorie = effektiveKategorie(fuer: artikel)
            nachKategorie[kategorie.persistentModelID, default: KategorieGruppe(kategorie: kategorie, artikel: [])].artikel.append(artikel)
        }
        let alphabetisch = nachKategorie.values.map(\.kategorie).sorted { $0.name < $1.name }
        guard let geschaeft else {
            return nachKategorie.values.sorted { $0.kategorie.name < $1.kategorie.name }
        }
        let sortiert = WarengruppenDistanzService.sortierteReihenfolge(
            offeneKategorien: alphabetisch,
            startpunkt: zuletztAbgehakteKategorie,
            in: geschaeft,
            context: modelContext
        )
        let position = Dictionary(uniqueKeysWithValues: sortiert.enumerated().map { ($1.persistentModelID, $0) })
        return nachKategorie.values.sorted {
            (position[$0.kategorie.persistentModelID] ?? .max) < (position[$1.kategorie.persistentModelID] ?? .max)
        }
    }

    /// Die Kategorie des zuletzt (nach Zeitstempel) abgehakten Artikels dieses
    /// Einkaufsvorgangs — impliziter aktueller Standort für die dynamische
    /// Neusortierung (Architekturvorschlag Abschnitt 4.3). `nil` vor dem ersten
    /// Abhaken.
    private var zuletztAbgehakteKategorie: ArtikelKategorie? {
        einkaufsvorgang.kaufEintraege.max { $0.datum < $1.datum }?.kategorie
    }

    /// Statusbanner über den Sortierzustand dieses Geschäfts (Architekturvorschlag
    /// Abschnitt 7) — nur sichtbar, wenn es überhaupt kategoriebasiert sortierte
    /// Abschnitte gibt.
    @ViewBuilder
    private var sortierStatusHinweis: some View {
        if let geschaeft, !sonstigeGruppen.isEmpty {
            HStack(spacing: 6) {
                if WarengruppenDistanzService.genuegendDatenVerfuegbar(fuer: geschaeft) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Reihenfolge optimiert")
                } else {
                    Image(systemName: "brain")
                    Text("Lernt noch – Reihenfolge unoptimiert")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    /// Die momentan für die Anzeige relevante Menge eines Artikels: solange er noch
    /// auf ``einkaufsliste`` steht, dessen ``EinkaufslistenEintrag/menge``, sonst
    /// (bereits abgehakt) die im ``KaufEintrag`` festgehaltene Menge.
    private func menge(fuer artikel: Artikel) -> Double {
        if let eintrag = einkaufsliste.eintrag(fuer: artikel) { return eintrag.menge }
        return kaufEintrag(fuer: artikel)?.menge ?? artikel.mengenSchritt
    }

    private func kaufEintrag(fuer artikel: Artikel) -> KaufEintrag? {
        einkaufsvorgang.kaufEintraege.first { $0.artikel == artikel }
    }

    var body: some View {
        List {
            ForEach(gruppen) { gruppe in
                Section {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            eintrag: einkaufsliste.eintrag(fuer: artikel),
                            mengeAnzeige: menge(fuer: artikel),
                            istAbgehakt: istAbgehakt(artikel),
                            abhaken: { umschalten(artikel) },
                            mengeErhoehen: { mengeErhoehen(artikel) },
                            mengeVerringern: { mengeVerringern(artikel) },
                            dauerhaftEntfernen: istAbgehakt(artikel) ? { entferneDauerhaft(artikel) } : nil
                        )
                    }
                } header: {
                    EinkaufslistenSektionHeader(titel: gruppe.regal.name, kategorie: nil)
                }
            }

            ForEach(sonstigeGruppen) { gruppe in
                Section {
                    ForEach(gruppe.artikel) { artikel in
                        ArtikelAbhakZeile(
                            artikel: artikel,
                            eintrag: einkaufsliste.eintrag(fuer: artikel),
                            mengeAnzeige: menge(fuer: artikel),
                            istAbgehakt: istAbgehakt(artikel),
                            abhaken: { umschalten(artikel) },
                            mengeErhoehen: { mengeErhoehen(artikel) },
                            mengeVerringern: { mengeVerringern(artikel) },
                            dauerhaftEntfernen: istAbgehakt(artikel) ? { entferneDauerhaft(artikel) } : nil
                        )
                    }
                } header: {
                    EinkaufslistenSektionHeader(titel: gruppe.kategorie.name, kategorie: gruppe.kategorie)
                }
            }

            if artikelAufListe.isEmpty {
                if !offeneArtikel.isEmpty {
                    ContentUnavailableView(
                        "Keine verfügbaren Artikel",
                        systemImage: "checklist",
                        description: Text("Halte die Schnellauswahl oben gedrückt und aktiviere den Lernmodus, um bislang unbekannte Artikel abzuhaken.")
                    )
                } else if abgehakteArtikel.isEmpty {
                    ContentUnavailableView(
                        "Einkaufsliste ist leer",
                        systemImage: "checklist",
                        description: Text("Füge oben rechts Artikel zu „\(einkaufsliste.name)“ hinzu.")
                    )
                } else {
                    ContentUnavailableView(
                        "Alles erledigt",
                        systemImage: "checkmark.circle.fill",
                        description: Text("Tippe oben auf die Schnellauswahl, um auch abgehakte Artikel zu sehen.")
                    )
                }
            }
        }
        .safeAreaInset(edge: .top) { sortierStatusHinweis }
        .safeAreaInset(edge: .bottom) { einkaufAbschliessenButton }
        // Zeigt bewusst immer den Listennamen, nicht den Geschäftsnamen — der
        // erscheint stattdessen direkt neben dem Einkaufswagen-Icon im
        // `EinkaufenView`-Toolbar (siehe dort, GitHub #16).
        .navigationTitle(einkaufsliste.name)
        .toolbar {
            if geschaeft != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            zeigeBelegScanFuerGeschaeft = true
                        } label: {
                            Label("Beleg scannen", systemImage: "doc.text.viewfinder")
                        }
                        Button {
                            zeigePreisschildScanFuerGeschaeft = true
                        } label: {
                            Label("Preisschild scannen", systemImage: "text.viewfinder")
                        }
                    } label: {
                        Label("Scannen", systemImage: "camera.viewfinder")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SchnellauswahlButton(
                    zeigeAbgehakteArtikel: $zeigeAbgehakteArtikel,
                    zeigeAlleArtikel: $zeigeAlleArtikel,
                    lernmodusVerfuegbar: geschaeft != nil
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zeigeArtikelHinzufuegen = true
                } label: {
                    Label("Artikel hinzufügen", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $zeigeArtikelHinzufuegen) {
            ArtikelHinzufuegenView(einkaufsliste: einkaufsliste)
        }
        .sheet(isPresented: $zeigeBelegScanFuerGeschaeft) {
            if let geschaeft {
                BelegScanView(geschaeft: geschaeft)
            }
        }
        .sheet(isPresented: $zeigePreisschildScanFuerGeschaeft) {
            if let geschaeft {
                PreisschildScanView(geschaeft: geschaeft)
            }
        }
        .confirmationDialog(
            "Einkauf abgeschlossen",
            isPresented: $zeigeBelegScanAngebot,
            titleVisibility: .visible
        ) {
            Button("Beleg jetzt scannen") { zeigeBelegScan = true }
            Button("Später", role: .cancel) {}
        } message: {
            Text("Möchtest du den Kassenbon scannen, um die Preise für diesen Einkauf zu erfassen?")
        }
        .sheet(isPresented: $zeigeBelegScan) {
            BelegScanView(einkaufsvorgang: einkaufsvorgang)
        }
        .alert("Hat sich im Laden etwas verändert?", isPresented: $zeigeUmbauHinweis) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Reihenfolge weicht deutlich von der bisherigen Erfahrung ab. Wir passen uns mit den nächsten Einkäufen automatisch an.")
        }
    }

    private func istAbgehakt(_ artikel: Artikel) -> Bool {
        einkaufsvorgang.kaufEintraege.contains { $0.artikel == artikel }
    }

    private func umschalten(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if istAbgehakt(artikel) {
                    einkaufsvorgang.artikelAbwaehlen(artikel, context: modelContext)
                } else {
                    einkaufsvorgang.artikelAbhaken(artikel, context: modelContext)
                }
            }
        }
    }

    private func entferneDauerhaft(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                einkaufsvorgang.artikelDauerhaftEntfernen(artikel, context: modelContext)
            }
        }
    }

    /// Diskrete Einzelaktion wie das Abhaken (``umschalten``) — jeder Tap ist ein
    /// abgeschlossener Schreibvorgang und wird deshalb ebenso per Micro-Lease
    /// abgesichert (siehe `docs/DATABASE_CONCURRENCY.md` → „Vollständiger
    /// Schreibvorgang-Katalog“). Solange der Artikel noch auf ``einkaufsliste``
    /// steht, wirkt sich das auf dessen ``EinkaufslistenEintrag/menge`` aus, danach
    /// (bereits abgehakt) auf die im ``KaufEintrag`` festgehaltene Menge.
    private func mengeErhoehen(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if let eintrag = einkaufsliste.eintrag(fuer: artikel) {
                    eintrag.mengeErhoehen()
                } else if let kauf = kaufEintrag(fuer: artikel) {
                    kauf.menge += artikel.mengenSchritt
                }
            }
        }
    }

    private func mengeVerringern(_ artikel: Artikel) {
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if let eintrag = einkaufsliste.eintrag(fuer: artikel) {
                    eintrag.mengeVerringern()
                } else if let kauf = kaufEintrag(fuer: artikel) {
                    kauf.menge = max(artikel.mengenSchritt, kauf.menge - artikel.mengenSchritt)
                }
            }
        }
    }
}

/// Schnellauswahl in der Toolbar neben „Artikel hinzufügen“, die zwei unabhängige
/// Anzeige-Entscheidungen in einem einzigen Button bündelt:
/// - Kurzer Tap: schaltet zwischen „Nur offene“ und „Auch abgehakte Artikel“ um
///   (``zeigeAbgehakteArtikel``).
/// - Langer Tap (Kontextmenü): schaltet den Lernmodus (``zeigeAlleArtikel``) um, der
///   für diesen Einkauf auch nicht als verfügbar geltende Artikel einblendet — siehe
///   ``EinkaufslisteView/verfuegbarkeitsgefiltert(_:)``. Nur verfügbar, wenn ein
///   Geschäft gewählt ist (``lernmodusVerfuegbar``), da der Verfügbarkeitsfilter sonst
///   ohnehin nicht greift.
private struct SchnellauswahlButton: View {
    @Binding var zeigeAbgehakteArtikel: Bool
    @Binding var zeigeAlleArtikel: Bool
    let lernmodusVerfuegbar: Bool

    private var symbolName: String {
        if zeigeAlleArtikel { return "graduationcap.fill" }
        return zeigeAbgehakteArtikel ? "checkmark.circle.fill" : "circle"
    }

    private var beschreibung: String {
        if zeigeAlleArtikel { return "Lernmodus aktiv: Alle Artikel werden angezeigt" }
        return zeigeAbgehakteArtikel ? "Auch abgehakte Artikel werden angezeigt" : "Nur offene Artikel werden angezeigt"
    }

    var body: some View {
        // `Button` + `.contextMenu` löst den langen Tap nicht zuverlässig aus, da der
        // `.glass`-Stil ein `PrimitiveButtonStyle` mit eigener Gestenerkennung ist, die
        // dem `.contextMenu`-Long-Press-Recognizer die Touches wegnimmt. `Menu` mit
        // `primaryAction` ist der dafür vorgesehene SwiftUI-Baustein: kurzer Tap löst
        // `primaryAction` aus, langer Tap öffnet zuverlässig das Menü.
        Menu {
            if lernmodusVerfuegbar {
                Button {
                    zeigeAlleArtikel.toggle()
                } label: {
                    Label(
                        zeigeAlleArtikel ? "Lernmodus beenden" : "Lernmodus: alle Artikel anzeigen",
                        systemImage: zeigeAlleArtikel ? "graduationcap.fill" : "graduationcap"
                    )
                }
            }
        } label: {
            Image(systemName: symbolName)
                .font(.title2)
                .frame(width: 44, height: 44)
        } primaryAction: {
            zeigeAbgehakteArtikel.toggle()
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(beschreibung)
    }
}

/// Kopfzeile einer Einkaufslisten-Sektion (Regal oder Kategorie). Bei
/// Kategorie-Sektionen (``kategorie`` gesetzt) wird zusätzlich deren Icon/Farbe
/// (``ArtikelKategorie/standardSymbol``/``standardFarbeHex``) angezeigt — Regal-
/// Sektionen bleiben ohne Icon, da ein Regal mehrere Kategorien bündeln kann.
private struct EinkaufslistenSektionHeader: View {
    let titel: String
    let kategorie: ArtikelKategorie?

    var body: some View {
        HStack(spacing: 6) {
            if let kategorie {
                Image(systemName: kategorie.standardSymbol)
                    .foregroundStyle(Color(hex: kategorie.standardFarbeHex))
            }
            Text(titel)
            Spacer()
        }
    }
}

/// Eine Zeile zum Erhöhen/Verringern der Menge eines Artikels beim Einkaufen — Abhaken
/// geschieht über die eigenständige Checkbox am Zeilenende:
/// - Tap auf die Mengenangabe (nur solange noch offen, ``eintrag`` gesetzt): öffnet
///   ``MengenNotizSheet`` für eine exakte Menge + temporäre Notiz.
/// - Swipe nach links (trailing): erhöht die Menge um ``Artikel/mengenSchritt``.
/// - Swipe nach rechts (leading): verringert die Menge um ``Artikel/mengenSchritt``.
///
/// Beide Wischgesten lösen bei vollständigem Swipe die jeweilige Aktion direkt aus
/// (kein zusätzliches Bestätigen nötig, siehe GitHub #11) — **außer** bei bereits
/// abgehakten Artikeln: dort bietet die Trailing-Swipe-Aktion zusätzlich an, den
/// Artikel dauerhaft aus dieser Ansicht zu entfernen (``dauerhaftEntfernen``, `nil`
/// bei noch offenen Artikeln), und ein voller Swipe löst dann bewusst **nicht**
/// automatisch aus — sonst könnte ein schnelles Wischen versehentlich dauerhaft
/// löschen statt nur die Menge zu erhöhen.
private struct ArtikelAbhakZeile: View {
    let artikel: Artikel
    /// Der offene Einkaufslisten-Eintrag dieses Artikels — `nil`, wenn er bereits
    /// abgehakt wurde (dann gibt es keinen Eintrag mehr, siehe ``mengeAnzeige``).
    let eintrag: EinkaufslistenEintrag?
    let mengeAnzeige: Double
    let istAbgehakt: Bool
    let abhaken: () -> Void
    let mengeErhoehen: () -> Void
    let mengeVerringern: () -> Void
    var dauerhaftEntfernen: (() -> Void)?

    @State private var zeigeMengenSheet = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artikel.name)
                    .strikethrough(istAbgehakt)
                    .foregroundStyle(istAbgehakt ? .secondary : .primary)
                if let notiz = eintrag?.notiz, !notiz.isEmpty {
                    Text(notiz)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(mengeAnzeige.formatted()) \(artikel.einheit.kurzform)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { if eintrag != nil { zeigeMengenSheet = true } }
            Button(action: abhaken) {
                Image(systemName: istAbgehakt ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(istAbgehakt ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .leading) {
            Button(action: mengeVerringern) {
                Label("Menge verringern", systemImage: "minus")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: dauerhaftEntfernen == nil) {
            if let dauerhaftEntfernen {
                Button(role: .destructive, action: dauerhaftEntfernen) {
                    Label("Dauerhaft entfernen", systemImage: "trash")
                }
            }
            Button(action: mengeErhoehen) {
                Label("Menge erhöhen", systemImage: "plus")
            }
            .tint(.blue)
        }
        .sheet(isPresented: $zeigeMengenSheet) {
            if let eintrag {
                MengenNotizSheet(eintrag: eintrag)
            }
        }
    }
}

/// Sheet zum exakten Vorgeben der Menge, der Mengeneinheit und einer temporären
/// Notiz für einen ``EinkaufslistenEintrag`` (Tap auf die Mengenangabe in
/// ``ArtikelAbhakZeile``). Arbeitet mit lokalem Entwurfs-Zustand (analog
/// `NeueKategorieSheet`) — die Übernahme ins Modell geschieht erst bei „Sichern“,
/// gekapselt in einem einzelnen Micro-Lease.
///
/// Die Einheit ist (anders als Menge/Notiz) kein Feld von
/// ``EinkaufslistenEintrag``, sondern von ``Artikel/einheit`` — eine Änderung
/// hier wirkt sich also, wie beim direkten Bearbeiten in ``ArtikelEditView``, auf
/// den Artikel insgesamt aus, nicht nur auf diesen einen Eintrag (GitHub #12).
private struct MengenNotizSheet: View {
    let eintrag: EinkaufslistenEintrag

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var mengeText: String
    @State private var notizText: String
    @State private var einheitAuswahl: Einheit

    init(eintrag: EinkaufslistenEintrag) {
        self.eintrag = eintrag
        _mengeText = State(initialValue: eintrag.menge.formatted())
        _notizText = State(initialValue: eintrag.notiz ?? "")
        _einheitAuswahl = State(initialValue: eintrag.artikel?.einheit ?? .stueck)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Menge") {
                    HStack {
                        TextField("Menge", text: $mengeText)
                            .keyboardType(.decimalPad)
                        if eintrag.artikel != nil {
                            Picker("Einheit", selection: $einheitAuswahl) {
                                ForEach(Einheit.allCases) { einheit in
                                    Text(einheit.kurzform).tag(einheit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
                Section("Notiz") {
                    TextField(
                        "Temporäre Notiz, z.B. \"diesmal die große Packung\"",
                        text: $notizText,
                        axis: .vertical
                    )
                }
            }
            .navigationTitle(eintrag.artikel?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: sichern)
                }
            }
        }
    }

    private func sichern() {
        let neueMenge = Double(mengeText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let getrimmteNotiz = notizText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if let neueMenge, neueMenge > 0 {
                    eintrag.menge = neueMenge
                }
                eintrag.artikel?.einheit = einheitAuswahl
                eintrag.notiz = getrimmteNotiz.isEmpty ? nil : getrimmteNotiz
            }
            dismiss()
        }
    }
}

#Preview {
    EinkaufenView()
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Regal.self, ArtikelKategorie.self, Artikel.self, Einkaufsvorgang.self, Einkaufsliste.self, EinkaufslistenEintrag.self], inMemory: true)
}
