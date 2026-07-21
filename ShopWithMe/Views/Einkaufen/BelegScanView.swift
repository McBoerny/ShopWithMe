import SwiftUI
import SwiftData
import PhotosUI

/// Kontext, in dem ein Kassenbon gescannt wird.
///
/// Während eines laufenden ``Einkaufsvorgang``s werden erkannte Preise bereits
/// abgehakten ``KaufEintrag``en zugeordnet (Namensabgleich). Unabhängig davon lässt
/// sich ein Beleg auch direkt für ein ``Geschaeft`` scannen — dort entsteht für jede
/// erkannte Position ein neuer, eigenständiger ``KaufEintrag``, standardmäßig mit dem
/// heutigen Datum (vom Anwender bei Bedarf überschreibbar, siehe ``BelegScanView``).
///
/// ``unbekannt`` deckt den Fall ab, dass der Beleg nachträglich (z.B. zuhause) ohne
/// vorherige Geschäftswahl gescannt wird — dafür versucht ``BelegScanView`` das
/// Geschäft automatisch über ``Geschaeft/passendes(fuerErkannterName:unter:)``
/// zuzuordnen bzw. fragt über ``GeschaeftWahlSheet`` nach, siehe `docs/BELEGSCAN.md`.
enum BelegScanKontext {
    case einkaufsvorgang(Einkaufsvorgang)
    case geschaeft(Geschaeft)
    case unbekannt

    /// Das bereits feststehende Geschäft dieses Kontexts — `nil`, wenn es (noch)
    /// automatisch erkannt oder vom Anwender gewählt werden muss (``unbekannt``, oder
    /// ein ``einkaufsvorgang`` ohne gewähltes Geschäft).
    var geschaeft: Geschaeft? {
        switch self {
        case .einkaufsvorgang(let einkaufsvorgang): einkaufsvorgang.geschaeft
        case .geschaeft(let geschaeft): geschaeft
        case .unbekannt: nil
        }
    }
}

/// Scannt einen Kassenbon und trägt die erkannten Einzelpreise als ``KaufEintrag``e
/// ein — siehe ``BelegScanKontext`` für die beiden möglichen Aufrufsituationen.
///
/// Erkannte Positionen, die sich keinem bestehenden ``Artikel`` zuordnen lassen,
/// werden trotzdem als eigenständiger ``KaufEintrag`` ohne ``Artikel``-Verknüpfung
/// gespeichert — der Artikelname bleibt über `artikelNameSnapshot` trotzdem in der
/// Preishistorie lesbar. Kassenbons weisen bei mehreren Stück oft nur einen
/// Gesamtpreis aus; übernommen wird ausschließlich der von der KI berechnete
/// Einzelpreis (siehe ``BelegPosition``), keine Mengenangabe.
///
/// Das Einkaufsdatum wird von der KI aus dem Beleg erkannt (Vorbelegung), lässt sich
/// vor dem Übernehmen aber jederzeit manuell korrigieren (``ErgebnisListe``). Benennt
/// der Anwender eine Position zwecks Zuordnung auf einen bestehenden, ggf.
/// generischen ``Artikel`` um (z.B. „Colgate Total“ → „Zahnpasta“), bleibt der
/// ursprünglich erkannte Produktname über ``KaufEintrag/produktName`` erhalten —
/// so lassen sich verschiedene Marken desselben generischen Artikels weiterhin
/// getrennt in der Preishistorie nachverfolgen.
///
/// **Mitlernen:** Wurde eine erkannte Position schon einmal (in einem früheren Beleg
/// oder über ``KaufEintragZuordnenSheet``) mit einem Alias-Namen und/oder einem
/// ``Artikel`` versehen, schlägt ``KaufEintrag/gelernteZuordnung(fuerErkannterName:in:)``
/// beides bereits beim Einlesen vor: das Textfeld zeigt direkt den Alias statt des
/// rohen Kassenbon-Texts, und die Position wird beim Übernehmen automatisch mit dem
/// gelernten ``Artikel`` verknüpft — siehe `docs/BELEGSCAN.md`.
///
/// **Originalbeleg prüfen:** Solange die Ergebnis-Prüfung läuft, bleibt das
/// aufgenommene Foto in-memory verfügbar (``erfasstesBild``, nie persistiert) und
/// wird direkt inline oben in ``ErgebnisListe`` angezeigt (zoom-/schwenkbar,
/// ``ZoombareBildAnsicht``) — kein separater Bildschirm. Das Lupen-Symbol je
/// Position scrollt zu dieser Vorschau und hebt die per Textabgleich zugeordnete
/// OCR-Zeile darin hervor (``ErkannteZeile/boundingBox(fuerArtikelName:)``), um die
/// KI-Erkennung visuell zu verifizieren.
struct BelegScanView: View {
    let kontext: BelegScanKontext

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Geschaeft.name) private var alleGeschaefte: [Geschaeft]

    @State private var ausgewaehltesFoto: PhotosPickerItem?
    @State private var zeigeKamera = false
    @State private var laeuft = false
    @State private var fehlermeldung: String?
    @State private var bearbeitbarePositionen: [BearbeitbarePosition]?
    /// Das gescannte Originalfoto, ausschließlich in-memory für die Dauer dieser
    /// Prüf-Ansicht gehalten (nie auf Platte oder ins SwiftData-Model geschrieben) —
    /// wird direkt inline über ``ZoombareBildAnsicht`` in ``ErgebnisListe`` angezeigt.
    @State private var erfasstesBild: UIImage?
    @State private var belegDatum: Date
    /// Das für die Übernahme zu verwendende Geschäft — bei ``BelegScanKontext/geschaeft(_:)``
    /// sofort feststehend, sonst nach dem Scan automatisch erkannt
    /// (``Geschaeft/passendes(fuerErkannterName:unter:)``) oder vom Anwender über
    /// ``GeschaeftWahlSheet`` gewählt. Siehe ``geschaeftAbgleichNoetig``.
    @State private var erkanntesGeschaeft: Geschaeft?
    /// Der auf dem Beleg erkannte, rohe Geschäftsname (``BelegErgebnis/geschaeftName``)
    /// — Grundlage sowohl für den automatischen Abgleich als auch fürs Mitlernen
    /// (``Geschaeft/alternativenNamenLernen(_:)``) beim Übernehmen.
    @State private var erkannterGeschaeftName = ""
    /// Die auf dem Beleg erkannte, rohe Geschäftsadresse (``BelegErgebnis/geschaeftAdresse``)
    /// — Tie-Breaker bei mehreren namensgleichen Geschäften (``Geschaeft/passendes(fuerErkannterName:erkannteAdresse:unter:)``)
    /// und Vorbelegung beim „neu anlegen“ in ``GeschaeftWahlSheet``.
    @State private var erkannteGeschaeftAdresse = ""
    @State private var zeigeGeschaeftWahl = false

    private let scanner: ReceiptScanService = VisionFoundationModelsReceiptScanner()

    /// Muss das Geschäft dieses Scans erst noch bestimmt werden (automatisch oder per
    /// Anwenderauswahl)? Nur der Fall, wenn der ``kontext`` noch kein Geschäft
    /// feststehend mitbringt — bei ``BelegScanKontext/geschaeft(_:)`` bleibt das
    /// bisherige Verhalten unverändert.
    private var geschaeftAbgleichNoetig: Bool { kontext.geschaeft == nil }

    init(einkaufsvorgang: Einkaufsvorgang) {
        self.kontext = .einkaufsvorgang(einkaufsvorgang)
        _belegDatum = State(initialValue: einkaufsvorgang.startZeit)
    }

    init(geschaeft: Geschaeft) {
        self.kontext = .geschaeft(geschaeft)
        _belegDatum = State(initialValue: .now)
    }

    /// Scannt einen Beleg, ohne vorher ein Geschäft festzulegen — z.B. wenn der Beleg
    /// nachträglich zuhause gescannt wird. Siehe ``geschaeftAbgleichNoetig``.
    init() {
        self.kontext = .unbekannt
        _belegDatum = State(initialValue: .now)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let bearbeitbarePositionen {
                    ErgebnisListe(
                        positionen: Binding(
                            get: { bearbeitbarePositionen },
                            set: { self.bearbeitbarePositionen = $0 }
                        ),
                        belegDatum: $belegDatum,
                        geschaeftAbgleichNoetig: geschaeftAbgleichNoetig,
                        erkanntesGeschaeft: erkanntesGeschaeft,
                        belegFoto: erfasstesBild,
                        geschaeftWaehlen: { zeigeGeschaeftWahl = true },
                        uebernehmen: uebernehmen
                    )
                } else {
                    AufnahmeAnsicht(
                        laeuft: laeuft,
                        fehlermeldung: fehlermeldung,
                        geschaeftName: kontext.geschaeft?.name ?? "",
                        ausgewaehltesFoto: $ausgewaehltesFoto,
                        kameraOeffnen: { zeigeKamera = true }
                    )
                }
            }
            .navigationTitle("Beleg scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $zeigeKamera) {
            KameraAufnahmeView { bild in
                zeigeKamera = false
                verarbeite(bild: bild)
            }
        }
        .sheet(isPresented: $zeigeGeschaeftWahl) {
            GeschaeftWahlSheet(erkannterName: erkannterGeschaeftName, erkannteAdresse: erkannteGeschaeftAdresse) { gewaehlt in
                erkanntesGeschaeft = gewaehlt
            }
        }
        .onChange(of: ausgewaehltesFoto) { _, neuesFoto in
            guard let neuesFoto else { return }
            Task {
                if let daten = try? await neuesFoto.loadTransferable(type: Data.self),
                   let bild = UIImage(data: daten) {
                    verarbeite(bild: bild)
                }
            }
        }
    }

    private func verarbeite(bild: UIImage) {
        laeuft = true
        fehlermeldung = nil
        Task {
            defer { laeuft = false }
            do {
                let scanErgebnis = try await scanner.auswerten(bild: bild)
                let ergebnis = scanErgebnis.ergebnis
                erfasstesBild = bild
                if let erkanntesDatum = ergebnis.erkanntesDatum {
                    belegDatum = erkanntesDatum
                }
                geschaeftAbgleichen(erkannterName: ergebnis.geschaeftName, erkannteAdresse: ergebnis.geschaeftAdresse)
                let bekannterVerlauf = (try? modelContext.fetch(FetchDescriptor<KaufEintrag>())) ?? []
                bearbeitbarePositionen = ergebnis.positionen.map { position in
                    let gelernt = KaufEintrag.gelernteZuordnung(
                        fuerErkannterName: position.artikelName,
                        in: bekannterVerlauf
                    )
                    return BearbeitbarePosition(
                        erkannterName: position.artikelName,
                        artikelName: gelernt?.alias ?? position.artikelName,
                        preisText: "\(position.einzelpreis)",
                        gelernterArtikel: gelernt?.artikel,
                        boundingBox: scanErgebnis.ocrZeilen.boundingBox(fuerArtikelName: position.artikelName)
                    )
                }
            } catch {
                fehlermeldung = error.localizedDescription
            }
        }
    }

    /// Bestimmt ``erkanntesGeschaeft`` nach dem Scan: bei bereits feststehendem
    /// ``kontext``-Geschäft unverändert übernommen, sonst per
    /// ``Geschaeft/passendes(fuerErkannterName:erkannteAdresse:unter:)`` gegen alle
    /// vorhandenen Geschäfte (inkl. gelernter ``Geschaeft/alternativeNamen``, inkl.
    /// Adress-Tie-Break bei mehreren namensgleichen Geschäften) abgeglichen. Ohne
    /// Treffer öffnet sich sofort ``GeschaeftWahlSheet`` (weiterhin abbrechbar, dann
    /// bleibt ``erkanntesGeschaeft`` `nil` — wie bisher bei Käufen ohne Geschäft).
    private func geschaeftAbgleichen(erkannterName: String, erkannteAdresse: String) {
        erkannterGeschaeftName = erkannterName
        erkannteGeschaeftAdresse = erkannteAdresse
        guard geschaeftAbgleichNoetig else {
            erkanntesGeschaeft = kontext.geschaeft
            return
        }
        if let treffer = Geschaeft.passendes(fuerErkannterName: erkannterName, erkannteAdresse: erkannteAdresse, unter: alleGeschaefte) {
            erkanntesGeschaeft = treffer
        } else {
            erkanntesGeschaeft = nil
            zeigeGeschaeftWahl = true
        }
    }

    private func uebernehmen() {
        Task {
            // Ein Micro-Lease um den gesamten Beleg-Vorgang statt pro Position —
            // fachlich eine einzige Aktion (siehe `docs/DATABASE_CONCURRENCY.md` →
            // „Vollständiger Schreibvorgang-Katalog“).
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                if !erkannterGeschaeftName.isEmpty {
                    erkanntesGeschaeft?.alternativenNamenLernen(erkannterGeschaeftName)
                }

                if case .einkaufsvorgang(let einkaufsvorgang) = kontext, einkaufsvorgang.geschaeft == nil {
                    einkaufsvorgang.geschaeft = erkanntesGeschaeft
                }

                for position in bearbeitbarePositionen ?? [] {
                    let name = position.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let erkannterName = position.erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let produktName: String? = erkannterName.isEmpty ? nil : erkannterName
                    let neuerAlternativerName = leiteAlternativenNamenAb(eingegeben: name, erkannt: erkannterName)
                    guard !name.isEmpty,
                          let preis = Decimal(string: position.preisText.replacingOccurrences(of: ",", with: "."))
                    else { continue }

                    switch kontext {
                    case .einkaufsvorgang(let einkaufsvorgang):
                        if let vorhandenerEintrag = einkaufsvorgang.kaufEintraege.first(where: { passtZu(name: name, eintrag: $0) }) {
                            vorhandenerEintrag.preis = preis
                            vorhandenerEintrag.datum = belegDatum
                            vorhandenerEintrag.produktName = produktName
                            vorhandenerEintrag.alternativerName = neuerAlternativerName
                        } else {
                            let artikel = position.gelernterArtikel
                            let neuerEintrag = KaufEintrag(
                                artikel: artikel,
                                geschaeft: einkaufsvorgang.geschaeft,
                                kategorie: artikel?.kategorie,
                                preis: preis,
                                datum: belegDatum
                            )
                            neuerEintrag.artikelNameSnapshot = artikel?.name ?? name
                            neuerEintrag.produktName = produktName
                            neuerEintrag.alternativerName = neuerAlternativerName
                            modelContext.insert(neuerEintrag)
                            neuerEintrag.einkaufsvorgang = einkaufsvorgang
                        }
                    case .geschaeft, .unbekannt:
                        let artikel = position.gelernterArtikel ?? passendesArtikel(fuer: name)
                        let neuerEintrag = KaufEintrag(
                            artikel: artikel,
                            geschaeft: erkanntesGeschaeft,
                            kategorie: artikel?.kategorie,
                            preis: preis,
                            datum: belegDatum
                        )
                        neuerEintrag.artikelNameSnapshot = artikel?.name ?? name
                        neuerEintrag.produktName = produktName
                        neuerEintrag.alternativerName = neuerAlternativerName
                        modelContext.insert(neuerEintrag)
                    }
                }
            }
            dismiss()
        }
    }

    /// Der Text im „Artikel“-Feld weicht vom rohen erkannten Namen ab (manuell
    /// korrigiert oder aus ``KaufEintrag/gelernteZuordnung(fuerErkannterName:in:)``
    /// vorbelegt) → als ``KaufEintrag/alternativerName`` übernehmen, damit spätere
    /// Belegscans desselben Produkts ihn wiederfinden (siehe `docs/BELEGSCAN.md`).
    private func leiteAlternativenNamenAb(eingegeben: String, erkannt: String) -> String? {
        guard !erkannt.isEmpty, eingegeben.localizedCaseInsensitiveCompare(erkannt) != .orderedSame else { return nil }
        return eingegeben
    }

    private func passtZu(name: String, eintrag: KaufEintrag) -> Bool {
        let artikelName = eintrag.artikel?.name ?? eintrag.artikelNameSnapshot
        guard !artikelName.isEmpty else { return false }
        return artikelName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(artikelName)
    }

    /// Sucht unter allen vorhandenen Artikeln einen, dessen Name zum erkannten
    /// Belegtext passt, damit ein beim Geschäft-Scan (ohne laufenden Einkauf) neu
    /// angelegter ``KaufEintrag`` in der Preishistorie dieses ``Artikel``s auftaucht
    /// statt nur als Namens-Schnappschuss zu existieren.
    private func passendesArtikel(fuer name: String) -> Artikel? {
        let alleArtikel = (try? modelContext.fetch(FetchDescriptor<Artikel>())) ?? []
        return alleArtikel.first {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }
    }
}

/// Eine editierbare Kopie einer erkannten Belegposition, solange der Anwender sie
/// noch prüfen/korrigieren kann.
///
/// `artikelName` ist editierbar, damit der Anwender die Position zwecks Zuordnung
/// auf einen bestehenden (ggf. generischen) ``Artikel`` umbenennen kann — z.B.
/// „Colgate Total“ → „Zahnpasta“. `erkannterName` bleibt dabei unverändert der
/// ursprünglich erkannte Produktname und wird als ``KaufEintrag/produktName``
/// übernommen, damit die Preishistorie weiterhin nach Marke/Produkt unterscheidet.
/// `gelernterArtikel` ist bereits beim Einlesen aus einer früheren, gleichartigen
/// Position übernommen (siehe ``BelegScanView/verarbeite(bild:)``) und wird beim
/// Übernehmen direkt verknüpft, ohne erneut über den Namen abgeglichen zu werden.
private struct BearbeitbarePosition: Identifiable {
    let id = UUID()
    let erkannterName: String
    var artikelName: String
    var preisText: String
    var gelernterArtikel: Artikel?
    /// Position dieser Zeile im Original-Beleg (Visions normalisiertes
    /// Koordinatensystem), ermittelt über ``ErkannteZeile/boundingBox(fuerArtikelName:)``
    /// — `nil`, wenn sich keine OCR-Zeile eindeutig zuordnen ließ (dann bietet
    /// ``ErgebnisListe`` für diese Zeile keinen „im Beleg zeigen“-Button an).
    var boundingBox: CGRect?
}

/// Aufforderung, ein Beleg-Foto aufzunehmen oder aus der Mediathek zu wählen.
private struct AufnahmeAnsicht: View {
    let laeuft: Bool
    let fehlermeldung: String?
    let geschaeftName: String
    @Binding var ausgewaehltesFoto: PhotosPickerItem?
    let kameraOeffnen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if laeuft {
                ProgressView("Beleg wird ausgewertet…")
            } else {
                ContentUnavailableView {
                    Label("Beleg scannen", systemImage: "doc.text.viewfinder")
                } description: {
                    Text(geschaeftName.isEmpty
                         ? "Fotografiere den Kassenbon oder wähle ein Foto aus deiner Mediathek. Das Geschäft wird nach Möglichkeit automatisch erkannt."
                         : "Fotografiere den Kassenbon von „\(geschaeftName)“ oder wähle ein Foto aus deiner Mediathek.")
                } actions: {
                    VStack(spacing: 12) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Foto aufnehmen", action: kameraOeffnen)
                                .buttonStyle(.glass)
                        }
                        PhotosPicker("Aus Fotomediathek wählen", selection: $ausgewaehltesFoto, matching: .images)
                            .buttonStyle(.glass)
                    }
                }
                if let fehlermeldung {
                    Text(fehlermeldung)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }
}

/// UIKit-Brücke für die Kamera-Aufnahme eines Belegfotos.
private struct KameraAufnahmeView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let bild = info[.originalImage] as? UIImage {
                onImage(bild)
            }
        }
    }
}

/// Anker-ID für den ``ScrollViewReader`` in ``ErgebnisListe``, um beim Antippen des
/// Lupen-Symbols einer Position zur Beleg-Vorschau hochzuscrollen.
private let belegFotoAnkerID = "belegfoto"

/// Editierbare Liste der erkannten Positionen zur Kontrolle vor dem Übernehmen.
private struct ErgebnisListe: View {
    @Binding var positionen: [BearbeitbarePosition]
    @Binding var belegDatum: Date
    /// Nur `true`, wenn der ``BelegScanKontext`` kein Geschäft feststehend mitbringt
    /// (siehe ``BelegScanView/geschaeftAbgleichNoetig``) — blendet die
    /// Geschäfts-Zeile unten ein.
    let geschaeftAbgleichNoetig: Bool
    let erkanntesGeschaeft: Geschaeft?
    /// Das Originalfoto, direkt inline oben angezeigt (kein separater Bildschirm) —
    /// `nil`, falls (noch) kein Foto verfügbar (siehe ``BelegScanView/erfasstesBild``).
    let belegFoto: UIImage?
    let geschaeftWaehlen: () -> Void
    let uebernehmen: () -> Void

    /// Aktuell im Beleg-Foto hervorgehobene Position — `nil` bis der Anwender das
    /// Lupen-Symbol einer Position antippt (``positionMarkieren(_:proxy:)``).
    @State private var aktiveMarkierung: CGRect?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let belegFoto {
                    Section {
                        ZoombareBildAnsicht(bild: belegFoto, markierung: aktiveMarkierung)
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets())
                    }
                    .id(belegFotoAnkerID)
                }

                if geschaeftAbgleichNoetig {
                    Section {
                        Button(action: geschaeftWaehlen) {
                            HStack {
                                Text("Geschäft")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(erkanntesGeschaeft?.name ?? "Wählen")
                                    .foregroundStyle(erkanntesGeschaeft == nil ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text(erkanntesGeschaeft == nil
                             ? "Auf dem Beleg wurde kein bekanntes Geschäft erkannt — bitte auswählen, damit die Preise diesem Geschäft zugeordnet werden."
                             : "Automatisch anhand des Belegs erkannt. Bei Bedarf antippen, um ein anderes Geschäft zu wählen.")
                    }
                }

                Section {
                    DatePicker("Einkaufsdatum", selection: $belegDatum, displayedComponents: .date)
                } footer: {
                    Text("Von der KI erkannt, falls auf dem Bon vorhanden — bei Bedarf korrigieren.")
                }

                Section {
                    ForEach($positionen) { $position in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Artikel", text: $position.artikelName)
                                Spacer()
                                TextField("Preis", text: $position.preisText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                Text("€")
                                    .foregroundStyle(.secondary)
                                if let boundingBox = position.boundingBox {
                                    Button {
                                        positionMarkieren(boundingBox, proxy: proxy)
                                    } label: {
                                        Image(systemName: "viewfinder")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            if let artikel = position.gelernterArtikel {
                                Label("Wird verknüpft mit „\(artikel.name)“", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { positionen.remove(atOffsets: $0) }
                } header: {
                    Text("Erkannte Positionen")
                } footer: {
                    Text("Prüfe Name und Preis, bevor du übernimmst. Bereits bekannte Produkte werden automatisch dem passenden Artikel zugeordnet. Nicht benötigte Positionen kannst du löschen. Das Lupen-Symbol markiert die erkannte Stelle im Beleg-Foto oben, sofern eindeutig zuordenbar.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Preise übernehmen", action: uebernehmen)
                    .buttonStyle(.glass)
                    .padding()
            }
        }
    }

    /// Hebt `boundingBox` im inline angezeigten Beleg-Foto hervor und scrollt die
    /// Liste dorthin — Ersatz für das frühere Öffnen einer eigenen Vollbild-Ansicht.
    private func positionMarkieren(_ boundingBox: CGRect, proxy: ScrollViewProxy) {
        aktiveMarkierung = boundingBox
        withAnimation {
            proxy.scrollTo(belegFotoAnkerID, anchor: .top)
        }
    }
}
