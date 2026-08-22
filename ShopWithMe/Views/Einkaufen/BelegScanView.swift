import SwiftUI
import SwiftData
import PhotosUI
import VisionKit
import UniformTypeIdentifiers

/// Kontext, in dem ein Kassenbon gescannt wird.
///
/// Während eines laufenden ``Einkaufsvorgang``s werden erkannte Preise bereits
/// abgehakten ``KaufEintrag``en zugeordnet (Namensabgleich). Unabhängig davon lässt
/// sich ein Beleg auch direkt für ein ``Geschaeft`` scannen — dort entsteht für jede
/// erkannte Position ein neuer, eigenständiger ``Preispunkt``, standardmäßig mit dem
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

/// Scannt einen Kassenbon und trägt die erkannten Einzelpreise als ``Preispunkt``e
/// ein — siehe ``BelegScanKontext`` für die beiden möglichen Aufrufsituationen.
///
/// Neben den bestehenden Sheet-Einstiegspunkten (Einkaufen-Menü, nach
/// Einkaufsabschluss, Geschäfts-Detail, geschäftsloser Scan in `GeschaeftListView`)
/// ist diese Ansicht seit 2026-07-21 zusätzlich als eigener Tab in ``RootView``
/// dauerhaft eingebettet (``istEigenerTab``, immer im ``BelegScanKontext/unbekannt``-
/// Kontext) — alle bisherigen Zugänge bleiben unverändert bestehen, der Tab ist nur
/// ein zusätzlicher, schnellerer Weg.
///
/// Erkannte Positionen, die sich keinem bestehenden ``Artikel`` zuordnen lassen,
/// werden übersprungen — ein ``Preispunkt`` braucht seit der Produkt-Pflicht
/// (siehe ``Preispunkt``-Typ-Doku) immer ein aufgelöstes ``Produkt``, es gibt
/// keinen Freitext-Fall ohne Zuordnung mehr. Kassenbons weisen bei mehreren
/// Stück oft nur einen Gesamtpreis aus; übernommen wird ausschließlich der
/// von der KI berechnete Einzelpreis (siehe ``BelegPosition``), keine
/// Mengenangabe.
///
/// Das Einkaufsdatum wird von der KI aus dem Beleg erkannt (Vorbelegung), lässt sich
/// vor dem Übernehmen aber jederzeit manuell korrigieren (``ErgebnisListe``). Benennt
/// der Anwender eine Position zwecks Zuordnung auf einen bestehenden, ggf.
/// generischen ``Artikel`` um (z.B. „Colgate Total“ → „Zahnpasta“), bleibt der
/// ursprünglich erkannte Produktname über ``Preispunkt/produktName`` erhalten —
/// so lassen sich verschiedene Marken desselben generischen Artikels weiterhin
/// getrennt in der Preishistorie nachverfolgen.
///
/// **Automatische Artikel-Zuordnung (``ArtikelZuordnungsService``, GitHub #123):**
/// Beim Einlesen wird jede erkannte Position dreistufig verarbeitet: (1) Text-Abgleich
/// (``Produktname`` und Artikel-Teilstring/``Artikel/alternativeNamen``) mit dem rohen
/// Bon-Text, (2) Klarname-Ableitung — bei Treffer aus dem Produktnamen, sonst
/// KI-Vorschlag (``AISuggestionService/produktKlarname``),
/// (3) KI-Artikel-Match (``AISuggestionService/artikelMatch``) auf Basis des Klarnamens
/// statt des rohen Bon-Texts. ``PositionsZeile`` zeigt den Klarname dominant (editierbar)
/// und den generischen ``Artikel`` als antippe-baren Button — Antippen öffnet
/// ``ArtikelAuswahlSheet`` zur Auswahl oder Neuanlage. Bleibt jede Stufe erfolglos,
/// gilt die Position als „neu erkannt”. Siehe `docs/BELEGSCAN.md`.
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
    /// `true`, wenn diese Ansicht als dauerhafter Tab-Inhalt eingebettet ist
    /// (``RootView``) statt als Sheet/FullScreenCover — dann gibt es nichts zu
    /// „dismissen“ (`@Environment(\.dismiss)` liefe ohne umgebende Präsentation
    /// ins Leere): Abbrechen/erfolgreiches Übernehmen setzen stattdessen den
    /// internen Zustand über ``zuruecksetzen()`` zurück, damit der Tab sofort
    /// wieder bereit für den nächsten Scan ist. `false` (Standard) an allen
    /// bestehenden Sheet-Einstiegspunkten unverändert.
    var istEigenerTab = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Geschaeft.name) private var alleGeschaefte: [Geschaeft]
    @Query(sort: \Artikel.name) private var alleArtikel: [Artikel]
    @Query private var alleIgnoriertenArtikel: [IgnorierterArtikel]

    @State private var ausgewaehltesFoto: PhotosPickerItem?
    @State private var zeigeKamera = false
    @State private var zeigeDateiAuswahl = false
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
    /// nachträglich zuhause gescannt wird, oder dauerhaft über den Scannen-Tab
    /// (``istEigenerTab``). Siehe ``geschaeftAbgleichNoetig``.
    init(istEigenerTab: Bool = false) {
        self.kontext = .unbekannt
        self.istEigenerTab = istEigenerTab
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
                        artikelDauerhaftIgnorieren: artikelDauerhaftIgnorieren,
                        uebernehmen: uebernehmen
                    )
                } else {
                    AufnahmeAnsicht(
                        laeuft: laeuft,
                        fehlermeldung: fehlermeldung,
                        geschaeftName: kontext.geschaeft.flatMap { modelContext.existiertNochImStore($0) ? $0.name : nil } ?? "",
                        ausgewaehltesFoto: $ausgewaehltesFoto,
                        kameraOeffnen: { zeigeKamera = true },
                        dateiAuswahlOeffnen: { zeigeDateiAuswahl = true }
                    )
                }
            }
            .navigationTitle("Beleg scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !istEigenerTab {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                } else if bearbeitbarePositionen != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Verwerfen") { zuruecksetzen() }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $zeigeKamera) {
            DokumentScanView(
                onBild: { bild in
                    zeigeKamera = false
                    verarbeite(bild: bild)
                },
                onAbbruch: { zeigeKamera = false }
            )
            .ignoresSafeArea()
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
        .fileImporter(isPresented: $zeigeDateiAuswahl, allowedContentTypes: [.image]) { ergebnis in
            guard let url = try? ergebnis.get() else { return }
            let zugriffErlaubt = url.startAccessingSecurityScopedResource()
            defer { if zugriffErlaubt { url.stopAccessingSecurityScopedResource() } }
            if let daten = try? Data(contentsOf: url), let bild = UIImage(data: daten) {
                verarbeite(bild: bild)
            } else {
                fehlermeldung = "Die gewählte Datei konnte nicht als Bild gelesen werden."
            }
        }
    }

    private func verarbeite(bild rohesBild: UIImage) {
        laeuft = true
        fehlermeldung = nil
        // S&W als Standard (GitHub #61) — genauere Texterkennung als am rohen Farbfoto.
        let bild = rohesBild.schwarzWeissGefiltert()
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
                // GitHub #47, Schritt 5/5 — geschäftsabhängiger Produktname-Abgleich,
                // siehe ``ArtikelZuordnungsService``.
                let bekannteProduktnamen = (try? modelContext.fetch(FetchDescriptor<Produktname>())) ?? []
                var neuePositionen: [BearbeitbarePosition] = []
                for position in ergebnis.positionen {
                    if IgnorierterArtikel.istIgnoriert(position.artikelName, geschaeft: erkanntesGeschaeft, unter: alleIgnoriertenArtikel) {
                        continue
                    }
                    // Stage 1+2: text-based matching with OCR text (Produktname + Substring).
                    let textTreffer = ArtikelZuordnungsService.textBasierteZuordnung(
                        erkannterName: position.artikelName,
                        alleArtikel: alleArtikel,
                        geschaeft: erkanntesGeschaeft,
                        bekannteProduktnamen: bekannteProduktnamen
                    )
                    // Klarname (GitHub #121, #123): Produktname-Treffer → direkt;
                    // sonst KI aus erkanntem Bon-Text.
                    let produktKlarname: String
                    if let produkt = textTreffer?.produkt {
                        produktKlarname = produkt.name
                    } else if AISuggestionService.istVerfuegbar {
                        let bekannteKlarnamen = textTreffer?.artikel?.produkte.filter { !$0.istStandard }.map { $0.name } ?? []
                        let vorschlag = try? await AISuggestionService.produktKlarname(
                            fuerErkannterName: position.artikelName,
                            bekannteKlarnamen: bekannteKlarnamen
                        )
                        produktKlarname = vorschlag?.klarname ?? ""
                    } else {
                        produktKlarname = ""
                    }
                    // Stage 3: AI article match using Klarname (not OCR text) —
                    // only when stages 1+2 found nothing (GitHub #123).
                    let zuordnung: (artikel: Artikel?, produkt: Produkt?, quelle: ArtikelZuordnungsService.Quelle?)
                    if let treffer = textTreffer {
                        zuordnung = (treffer.artikel, treffer.produkt, treffer.quelle)
                    } else if AISuggestionService.istVerfuegbar {
                        let matchInput = produktKlarname.isEmpty ? position.artikelName : produktKlarname
                        let kiVorschlag = try? await AISuggestionService.artikelMatch(fuerName: matchInput, bekannteArtikel: alleArtikel.map(\.name))
                        let passend = kiVorschlag?.passenderArtikel ?? ""
                        let kiArtikel = passend.isEmpty ? nil : alleArtikel.first { $0.name.localizedCaseInsensitiveCompare(passend) == .orderedSame }
                        zuordnung = (kiArtikel, nil, kiArtikel != nil ? .ki : nil)
                    } else {
                        zuordnung = (nil, nil, nil)
                    }
                    // Tages-Kollisionsprüfung (GitHub #76-Folgearbeit): existiert für
                    // den zugeordneten Artikel bereits ein Preispunkt vom selben
                    // Kalendertag mit abweichendem Preis, bekommt der Anwender die
                    // Wahl, ihn zu ersetzen (Standard) oder zu behalten — siehe
                    // ``PositionsZeile``/``uebernehmen()``. Nur möglich, wenn bereits
                    // eine Artikel-Zuordnung UND ein Geschäft feststehen.
                    var bestehenderPreisHeute: Decimal?
                    if let artikel = zuordnung.artikel, let erkanntesGeschaeft,
                       let produktFuerPruefung = zuordnung.produkt ?? Produkt.bestehendesStandardProdukt(fuer: artikel, context: modelContext) {
                        bestehenderPreisHeute = PreispunktService.vorhandenerPunktHeute(
                            produkt: produktFuerPruefung, geschaeft: erkanntesGeschaeft, amDatum: belegDatum, context: modelContext
                        )?.preis
                        if bestehenderPreisHeute == position.einzelpreis { bestehenderPreisHeute = nil }
                    }
                    neuePositionen.append(BearbeitbarePosition(
                        erkannterName: position.artikelName,
                        // artikelName zeigt jetzt immer den generischen Artikel, nicht den Alias
                        // (der wandert in produktKlarname — GitHub #121).
                        artikelName: zuordnung.artikel.flatMap { modelContext.existiertNochImStore($0) ? $0.name : nil } ?? position.artikelName,
                        produktKlarname: produktKlarname,
                        preisText: "\(position.einzelpreis.aufCentGerundet)",
                        zugeordneterArtikel: zuordnung.artikel,
                        zugeordnetesProdukt: zuordnung.produkt,
                        zuordnungsQuelle: zuordnung.quelle,
                        boundingBox: scanErgebnis.ocrZeilen.boundingBox(fuerArtikelName: position.artikelName),
                        bestehenderPreisHeute: bestehenderPreisHeute
                    ))
                }
                bearbeitbarePositionen = neuePositionen
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
        // Geschäfts-Pflicht: ohne Geschäft entsteht kein Preispunkt (siehe
        // `docs/ARTIKEL_PRODUKT_MODELL.md`) — der Button ist zwar bereits
        // `.disabled`, dieser Guard schützt zusätzlich den Aufrufpfad selbst.
        guard erkanntesGeschaeft != nil else { return }
        // Nur Identitäten über die `await`-Grenzen hinweg sichern (siehe
        // ``ModelReference``) — zwischen jetzt und der eigentlichen Zuweisung
        // im Lease-Block (nach Geocoding-Warten UND Lease-Erwerb, zwei
        // `await`-Punkte) kann ein nebenläufiger Sync-Zyklus jedes dieser
        // Objekte (per Tombstone eines Peers) gelöscht haben.
        let erkanntesGeschaeftReferenz = ModelReference(erkanntesGeschaeft)
        let einkaufsvorgangReferenz: ModelReference<Einkaufsvorgang>? = {
            guard case .einkaufsvorgang(let einkaufsvorgang) = kontext else { return nil }
            return ModelReference(einkaufsvorgang)
        }()
        let positionen = bearbeitbarePositionen ?? []
        let positionsArtikelReferenzen = positionen.map { ModelReference($0.effektivZugeordneterArtikel) }
        // GitHub #47, Schritt 5/5 — analog `positionsArtikelReferenzen`.
        let positionsProduktReferenzen = positionen.map { ModelReference($0.effektivZugeordnetesProdukt) }
        // GitHub #121 — reiner String, keine `ModelReference` nötig.
        let positionsKlarnamen = positionen.map { $0.produktKlarname.trimmingCharacters(in: .whitespacesAndNewlines) }

        Task {
            // Geocoding braucht Netzwerk (async) und muss daher vor dem
            // (synchronen) Micro-Lease abgeschlossen sein — analog
            // `GeschaeftWahlSheet.neuesGeschaeftAnlegen()`.
            let getrimmteErkannteAdresse = erkannteGeschaeftAdresse.trimmingCharacters(in: .whitespacesAndNewlines)
            var gelernteKoordinaten: (breitengrad: Double, laengengrad: Double)?
            if let erkanntesGeschaeft, erkanntesGeschaeft.adresse == nil, !getrimmteErkannteAdresse.isEmpty {
                gelernteKoordinaten = await GeschaeftErkennungService.koordinaten(fuerAdresse: getrimmteErkannteAdresse)
            }

            // Ein Micro-Lease um den gesamten Beleg-Vorgang statt pro Position —
            // fachlich eine einzige Aktion (siehe `docs/DATABASE_CONCURRENCY.md` →
            // „Vollständiger Schreibvorgang-Katalog“).
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                let erkanntesGeschaeftFrisch = erkanntesGeschaeftReferenz?.resolved(in: modelContext)
                let einkaufsvorgangFrisch = einkaufsvorgangReferenz?.resolved(in: modelContext)

                if !erkannterGeschaeftName.isEmpty {
                    erkanntesGeschaeftFrisch?.alternativenNamenLernen(erkannterGeschaeftName)
                }
                // Hat das zugeordnete Geschäft noch keine Adresse, wird die auf dem
                // Beleg erkannte übernommen (GitHub #19) — unabhängig davon, ob das
                // Geschäft automatisch oder manuell über `GeschaeftWahlSheet`
                // zugeordnet wurde.
                if let erkanntesGeschaeftFrisch, erkanntesGeschaeftFrisch.adresse == nil, !getrimmteErkannteAdresse.isEmpty {
                    erkanntesGeschaeftFrisch.adresse = getrimmteErkannteAdresse
                    if let gelernteKoordinaten {
                        erkanntesGeschaeftFrisch.breitengrad = gelernteKoordinaten.breitengrad
                        erkanntesGeschaeftFrisch.laengengrad = gelernteKoordinaten.laengengrad
                    }
                }

                if let einkaufsvorgangFrisch, einkaufsvorgangFrisch.geschaeft == nil {
                    einkaufsvorgangFrisch.geschaeft = erkanntesGeschaeftFrisch
                }

                for (index, position) in positionen.enumerated() {
                    let name = position.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let erkannterName = position.erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let getrimmterProduktKlarname = positionsKlarnamen[index]
                    let produktName: String? = erkannterName.isEmpty ? nil : erkannterName
                    // Klarname als alternativerName → in `Preispunkt.anzeigeName` gegenüber dem
                    // abgekürzten Bon-Text (`produktName`) bevorzugt (GitHub #121).
                    let neuerAlternativerName = leiteAlternativenNamenAb(
                        eingegeben: getrimmterProduktKlarname.isEmpty ? erkannterName : getrimmterProduktKlarname,
                        erkannt: erkannterName
                    )
                    guard !name.isEmpty,
                          let preis = Decimal(string: position.preisText.replacingOccurrences(of: ",", with: "."))
                    else { continue }
                    let artikel = positionsArtikelReferenzen[index]?.resolved(in: modelContext)
                    var produkt = positionsProduktReferenzen[index]?.resolved(in: modelContext)

                    let geschaeftFuerPreispunkt: Geschaeft
                    switch kontext {
                    case .einkaufsvorgang:
                        // Der Einkaufsvorgang selbst kann inzwischen gelöscht worden
                        // sein (siehe oben) — dann fehlt jeder Bezug für diese
                        // Position, sie wird übersprungen statt einen losgelösten
                        // Kaufeintrag anzulegen. Ebenso, falls das soeben zugewiesene
                        // Geschäft zwischenzeitlich gelöscht wurde (Geschäfts-Pflicht).
                        guard let einkaufsvorgangFrisch, let vorgangGeschaeft = einkaufsvorgangFrisch.geschaeft else { continue }
                        geschaeftFuerPreispunkt = vorgangGeschaeft
                        // Nur die operative Buchungszeile: existiert bereits ein
                        // passender ``KaufEintrag`` (Artikel wurde auf der Liste
                        // abgehakt), bleibt er unverändert bis auf das vom Beleg
                        // erkannte Datum — die Preisrolle übernimmt ausschließlich
                        // ``PreispunktService`` unten. Kein Treffer → neuer,
                        // rein operativer Eintrag ohne Preisfelder (z.B. Spontankauf,
                        // der nicht auf der Liste stand).
                        if let vorhandenerEintrag = einkaufsvorgangFrisch.kaufEintraege.first(where: { passtZu(name: name, eintrag: $0) }) {
                            vorhandenerEintrag.datum = belegDatum
                        } else {
                            let neuerEintrag = KaufEintrag(
                                artikel: artikel,
                                geschaeft: einkaufsvorgangFrisch.geschaeft,
                                kategorie: artikel?.fuehrendeKategorie(inGeschaeft: einkaufsvorgangFrisch.geschaeft, context: modelContext),
                                datum: belegDatum
                            )
                            neuerEintrag.artikelNameSnapshot = artikel?.name ?? name
                            modelContext.insert(neuerEintrag)
                            neuerEintrag.einkaufsvorgang = einkaufsvorgangFrisch
                        }
                    case .geschaeft, .unbekannt:
                        // Kein laufender Einkauf, also keine operative Rolle — hier
                        // entsteht ausschließlich ein ``Preispunkt``, kein ``KaufEintrag``.
                        // Geschäfts-Pflicht: ohne (noch aufgelöstes) Geschäft keine Position.
                        guard let erkanntesGeschaeftFrisch else { continue }
                        geschaeftFuerPreispunkt = erkanntesGeschaeftFrisch
                    }

                    // Folgearbeit zu GitHub #47/#116: nur ein bereits bekannter
                    // Produktname-Treffer bringt an dieser Stelle schon ein
                    // `produkt` mit (siehe ``ArtikelZuordnungsService``). Bei
                    // Substring-/KI-Treffer oder manueller Artikel-Zuweisung ohne
                    // Produktwahl sonst automatisch ein neues, eigenständiges
                    // Produkt auflösen/anlegen statt im geteilten Standardprodukt
                    // des Artikels zu landen — siehe `docs/ARTIKEL_PRODUKT_MODELL.md`
                    // → „Automatische Neuanlage beim Belegscan”. Legt bei Bedarf
                    // auch gleich den passenden ``Produktname`` an (GitHub #128) —
                    // ersetzt das frühere separate ``ArtikelAlias/lernen(...)``.
                    if produkt == nil, let artikel {
                        let klarname = getrimmterProduktKlarname.isEmpty ? erkannterName : getrimmterProduktKlarname
                        produkt = Produkt.aufgeloestesOderNeuesProdukt(
                            klarname: klarname, erkannterName: erkannterName, artikel: artikel,
                            geschaeft: geschaeftFuerPreispunkt, context: modelContext
                        )
                    }
                    // Produkt-Pflicht (siehe ``Preispunkt``-Typ-Doku): ohne Artikel-
                    // Zuordnung entsteht kein Produkt, also auch kein Preispunkt für
                    // diese Position — die operative ``KaufEintrag``-Buchungszeile
                    // oben bleibt davon unberührt.
                    guard let produktFuerPreispunkt = produkt else { continue }

                    // Tages-Kollision (GitHub #76-Folgearbeit): Anwender hat „Bisherigen
                    // behalten" gewählt → kein neuer Preispunkt für diese Position.
                    // Sonst (Standard „wird ersetzt") den bestehenden Tagespunkt zuerst
                    // entfernen, statt beide nebeneinander bestehen zu lassen.
                    let behalteBestehenden = position.bestehenderPreisHeute != nil && position.behalteBestehendenPreisHeute
                    if position.bestehenderPreisHeute != nil, !behalteBestehenden,
                       let vorhandenerPunkt = PreispunktService.vorhandenerPunktHeute(
                           produkt: produktFuerPreispunkt, geschaeft: geschaeftFuerPreispunkt, amDatum: belegDatum, context: modelContext
                       ) {
                        PreispunktService.ersetzeVorhandenenPunkt(vorhandenerPunkt, context: modelContext)
                    }
                    if !behalteBestehenden {
                        PreispunktService.erfassen(
                            preis: preis, produkt: produktFuerPreispunkt, geschaeft: geschaeftFuerPreispunkt, datum: belegDatum,
                            produktName: produktName, alternativerName: neuerAlternativerName, context: modelContext
                        )
                    }
                }
            }
            if istEigenerTab {
                zuruecksetzen()
            } else {
                dismiss()
            }
        }
    }

    /// Setzt den kompletten Scan-Zustand zurück auf ``AufnahmeAnsicht`` — Ersatz für
    /// `dismiss()` im Tab-Kontext (``istEigenerTab``), sowohl nach „Verwerfen“ als
    /// auch nach erfolgreichem ``uebernehmen()``.
    private func zuruecksetzen() {
        bearbeitbarePositionen = nil
        erfasstesBild = nil
        ausgewaehltesFoto = nil
        fehlermeldung = nil
        erkanntesGeschaeft = nil
        erkannterGeschaeftName = ""
        erkannteGeschaeftAdresse = ""
        belegDatum = .now
    }

    /// Der Text im „Artikel“-Feld weicht vom rohen erkannten Namen ab (manuell
    /// korrigiert) → als ``Preispunkt/alternativerName`` übernehmen, damit die
    /// Preishistorie den vom Nutzer bestätigten Namen statt des rohen Bon-Texts
    /// anzeigt (siehe ``Preispunkt/anzeigeName``).
    private func leiteAlternativenNamenAb(eingegeben: String, erkannt: String) -> String? {
        guard !erkannt.isEmpty, eingegeben.localizedCaseInsensitiveCompare(erkannt) != .orderedSame else { return nil }
        return eingegeben
    }

    private func passtZu(name: String, eintrag: KaufEintrag) -> Bool {
        let artikelName = eintrag.artikelNameSicher
        guard !artikelName.isEmpty else { return false }
        return artikelName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(artikelName)
    }

    /// Entfernt `position` sofort aus der Prüf-Ansicht und merkt sich ihren
    /// erkannten Namen dauerhaft als ignoriert für ``erkanntesGeschaeft`` (siehe
    /// ``IgnorierterArtikel``) — künftige Scans desselben Geschäfts zeigen diese
    /// Position dann gar nicht erst an. Diskrete Einzelaktion → Micro-Lease (siehe
    /// `docs/DATABASE_CONCURRENCY.md`).
    private func artikelDauerhaftIgnorieren(_ position: BearbeitbarePosition) {
        let name = position.erkannterName
        let geschaeft = erkanntesGeschaeft
        bearbeitbarePositionen?.removeAll { $0.id == position.id }
        Task {
            await DatabaseLeaseService.performMicroLease(context: modelContext) {
                // Live-Fund EinkaufenView (Build 308, `DatabaseLeaseService/gehoertZuAktuellemContext(_:context:)`).
                guard DatabaseLeaseService.gehoertZuAktuellemContext(geschaeft, context: modelContext) else { return }
                modelContext.insert(IgnorierterArtikel(erkannterName: name, geschaeft: geschaeft))
            }
        }
    }
}

/// Eine editierbare Kopie einer erkannten Belegposition, solange der Anwender sie
/// noch prüfen/korrigieren kann.
///
/// Drei Namens-Ebenen (GitHub #121): `erkannterName` ist der unveränderliche
/// Roh-Bon-Text (z.B. „SEBAMED UR”) — wird als ``Preispunkt/produktName`` und
/// ggf. als ``Produktname`` (geschäftsspezifisch) übernommen. `artikelName`
/// (editierbar) verknüpft die Position mit einem generischen ``Artikel`` (z.B.
/// „Shampoo”). `produktKlarname` (editierbar, GitHub #121) benennt das konkrete
/// Produkt menschenlesbar (z.B. „Sebamed Urea 5%”) — von der KI vorbelegt oder
/// leer. `zugeordneterArtikel` ist bereits beim Einlesen über
/// ``ArtikelZuordnungsService/textBasierteZuordnung(erkannterName:alleArtikel:geschaeft:bekannteProduktnamen:)``
/// ermittelt (siehe ``BelegScanView/verarbeite(bild:)``).
private struct BearbeitbarePosition: Identifiable {
    let id = UUID()
    let erkannterName: String
    var artikelName: String
    /// Menschenlesbarer Klarname des konkreten Produkts, z.B. „Sebamed Urea 5%” für
    /// den Bon-Text „SEBAMED UR” — von der KI vorbelegt (GitHub #121), editierbar.
    /// Wird als ``Produkt/name`` beim automatischen Anlegen/Suchen verwendet und als
    /// ``Preispunkt/alternativerName``, sofern er vom `erkannterName` abweicht.
    var produktKlarname: String
    var preisText: String
    var zugeordneterArtikel: Artikel?
    /// Über ``Produktname`` erkanntes konkretes Produkt (GitHub #47, Schritt
    /// 5/5) — `nil`, solange nur der generische Artikel (Stufe 1/3 des
    /// Zuordnungs-Abgleichs) getroffen wurde. Siehe ``effektivZugeordnetesProdukt``
    /// für die tatsächlich beim Speichern verwendete, gegen manuelle
    /// Korrekturen abgesicherte Fassung.
    var zugeordnetesProdukt: Produkt?
    /// Welche Zuordnungsstufe ``zugeordneterArtikel`` geliefert hat (`nil` ohne
    /// automatischen Treffer, z.B. nach manueller Zuweisung/Neuanlage über
    /// ``PositionsZeile/artikelZuweisen(_:)``) — Grundlage für die
    /// automatische Produkt-Neuanlage in ``BelegScanView/uebernehmen()``, siehe
    /// ``ArtikelZuordnungsService/Quelle``.
    var zuordnungsQuelle: ArtikelZuordnungsService.Quelle?
    /// Position dieser Zeile im Original-Beleg (Visions normalisiertes
    /// Koordinatensystem), ermittelt über ``ErkannteZeile/boundingBox(fuerArtikelName:)``
    /// — `nil`, wenn sich keine OCR-Zeile eindeutig zuordnen ließ (dann bietet
    /// ``ErgebnisListe`` für diese Zeile keinen „im Beleg zeigen“-Button an).
    var boundingBox: CGRect?
    /// Preis eines bereits am selben Kalendertag für diesen Artikel/dieses Geschäft
    /// erfassten ``Preispunkt``s, falls vorhanden und abweichend vom neu erkannten
    /// Preis — Grundlage für die Tages-Kollisionsabfrage (GitHub #76-Folgearbeit).
    /// `nil`, wenn keine Kollision vorliegt oder noch kein Artikel/Geschäft feststeht.
    var bestehenderPreisHeute: Decimal? = nil
    /// Nutzerentscheidung bei einer Tages-Kollision: `true` behält den bestehenden
    /// Preispunkt unverändert (der neu erkannte Preis wird verworfen), `false`
    /// (Standard) ersetzt ihn durch den neu erkannten. Ohne Wirkung, solange
    /// ``bestehenderPreisHeute`` `nil` ist.
    var behalteBestehendenPreisHeute = false

    /// ``zugeordneterArtikel``, aber nur solange ``artikelName`` noch exakt zu
    /// dessen Namen passt. Bearbeitet der Anwender das Textfeld frei weiter, ohne
    /// einen neuen Vorschlag/neu angelegten Artikel auszuwählen, gilt die Position
    /// wieder als „neu erkannt“ statt die ursprüngliche automatische Zuordnung
    /// stillschweigend beizubehalten — rein reaktiv über die Bindings, ohne
    /// `onChange`-Seiteneffekt. Sowohl die Anzeige (``PositionsZeile``) als auch
    /// das Speichern (``BelegScanView/uebernehmen()``) nutzen ausschließlich diese
    /// Property als Single Source of Truth für „ist zugeordnet“.
    var effektivZugeordneterArtikel: Artikel? {
        guard let zugeordneterArtikel,
              zugeordneterArtikel.name.localizedCaseInsensitiveCompare(artikelName) == .orderedSame
        else { return nil }
        return zugeordneterArtikel
    }

    /// ``zugeordnetesProdukt``, aber nur solange ``effektivZugeordneterArtikel``
    /// noch greift UND das Produkt tatsächlich zu diesem Artikel gehört
    /// (GitHub #47, Schritt 5/5) — schützt insbesondere gegen den Fall, dass
    /// der Anwender die automatische Artikel-Zuordnung manuell auf einen
    /// anderen Artikel korrigiert (``PositionsZeile/artikelZuweisen(_:)``),
    /// ohne dass ``zugeordnetesProdukt`` dabei separat zurückgesetzt wird.
    var effektivZugeordnetesProdukt: Produkt? {
        guard let effektivZugeordneterArtikel, let zugeordnetesProdukt,
              zugeordnetesProdukt.artikel == effektivZugeordneterArtikel
        else { return nil }
        return zugeordnetesProdukt
    }
}

/// Aufforderung, ein Beleg-Foto aufzunehmen oder aus der Mediathek zu wählen.
private struct AufnahmeAnsicht: View {
    let laeuft: Bool
    let fehlermeldung: String?
    let geschaeftName: String
    @Binding var ausgewaehltesFoto: PhotosPickerItem?
    let kameraOeffnen: () -> Void
    let dateiAuswahlOeffnen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if laeuft {
                ProgressView("Beleg wird ausgewertet…")
            } else {
                ContentUnavailableView {
                    Label("Beleg scannen", systemImage: "doc.text.viewfinder")
                } description: {
                    Text(geschaeftName.isEmpty
                         ? "Scanne den Kassenbon, wähle ein Foto aus deiner Mediathek oder aus den Dateien. Das Geschäft wird nach Möglichkeit automatisch erkannt."
                         : "Scanne den Kassenbon von „\(geschaeftName)“, wähle ein Foto aus deiner Mediathek oder aus den Dateien.")
                } actions: {
                    VStack(spacing: 12) {
                        if VNDocumentCameraViewController.isSupported {
                            Button("Beleg scannen", action: kameraOeffnen)
                                .buttonStyle(.glass)
                        }
                        PhotosPicker("Aus Fotomediathek wählen", selection: $ausgewaehltesFoto, matching: .images)
                            .buttonStyle(.glass)
                        Button("Aus Dateien wählen", action: dateiAuswahlOeffnen)
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
    /// Wischen nach rechts auf einer Position (siehe ``PositionsZeile``) — nur
    /// verfügbar, solange ``erkanntesGeschaeft`` gesetzt ist (Skalierung braucht ein
    /// Geschäft, siehe ``IgnorierterArtikel``).
    let artikelDauerhaftIgnorieren: (BearbeitbarePosition) -> Void
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
                        PositionsZeile(position: $position) { boundingBox in
                            positionMarkieren(boundingBox, proxy: proxy)
                        }
                        .swipeActions(edge: .leading) {
                            if erkanntesGeschaeft != nil {
                                Button {
                                    artikelDauerhaftIgnorieren(position)
                                } label: {
                                    Label("Dauerhaft ignorieren", systemImage: "eye.slash")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .onDelete { positionen.remove(atOffsets: $0) }
                } header: {
                    Text("Erkannte Positionen")
                } footer: {
                    Text("Der Produktname ist der menschenlesbare Klarname \u{2013} von der KI vorbelegt, antippen zum Bearbeiten. Artikel ist die generische Kategorie \u{2013} antippen zum W\u{E4}hlen oder Neuanlegen. Wischen nach links l\u{F6}scht die Position f\u{FC}r diesen Scan, nach rechts ignoriert sie dauerhaft f\u{FC}r dieses Gesch\u{E4}ft. Das Lupen-Symbol markiert die erkannte Stelle im Beleg-Foto.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Preise übernehmen", action: uebernehmen)
                    .buttonStyle(.glass)
                    .disabled(erkanntesGeschaeft == nil)
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

/// Eine Zeile in ``ErgebnisListe`` für eine einzelne erkannte Belegposition —
/// Klarname (dominant, KI-vorbelegt, editierbar) plus Preis, darunter Bon-Text
/// (falls abweichend) und der generische Artikel als antippe-barer Button.
/// Tippen öffnet ``ArtikelAuswahlSheet`` zur Auswahl oder Neuanlage. GitHub #123.
private struct PositionsZeile: View {
    @Binding var position: BearbeitbarePosition
    let belegFotoAnzeigen: (CGRect) -> Void

    @State private var zeigeArtikelAuswahl = false
    @State private var artikelFuerSheet: Artikel?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Produktname", text: $position.produktKlarname)
                Spacer()
                TextField("Preis", text: $position.preisText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("\u{20AC}")
                    .foregroundStyle(.secondary)
                if let boundingBox = position.boundingBox {
                    Button {
                        belegFotoAnzeigen(boundingBox)
                    } label: {
                        Image(systemName: "viewfinder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            let getrimmterKlarname = position.produktKlarname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !position.erkannterName.isEmpty,
               getrimmterKlarname.isEmpty ||
               getrimmterKlarname.localizedCaseInsensitiveCompare(position.erkannterName) != .orderedSame {
                Text("Erkannt auf Bon: \u{201E}\(position.erkannterName)\u{201C}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                artikelFuerSheet = position.effektivZugeordneterArtikel
                zeigeArtikelAuswahl = true
            } label: {
                if let artikel = position.effektivZugeordneterArtikel {
                    Label("Artikel: \(artikel.name)", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Neu erkannt \u{2013} Artikel zuordnen", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .buttonStyle(.plain)
            if let bestehenderPreisHeute = position.bestehenderPreisHeute {
                TagesKollisionZeile(
                    bestehenderPreis: bestehenderPreisHeute,
                    behalteBestehenden: $position.behalteBestehendenPreisHeute
                )
            }
        }
        .sheet(isPresented: $zeigeArtikelAuswahl) {
            ArtikelAuswahlSheet(gewaehlterArtikel: $artikelFuerSheet, onSelect: artikelZuweisen)
        }
    }

    private func artikelZuweisen(_ artikel: Artikel) {
        // Single GET→SET to avoid stale-capture race: the custom Binding's
        // get closure captures bearbeitbarePositionen by value, so separate
        // property writes each read the same stale snapshot and overwrite
        // each other. Reading once and writing the fully-modified struct
        // atomically avoids this.
        var updated = position
        updated.artikelName = artikel.name
        updated.zugeordneterArtikel = artikel
        updated.zuordnungsQuelle = nil
        position = updated
    }
}
