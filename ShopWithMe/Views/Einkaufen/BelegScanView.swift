import SwiftUI
import SwiftData
import PhotosUI
import VisionKit

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
/// Neben den bestehenden Sheet-Einstiegspunkten (Einkaufen-Menü, nach
/// Einkaufsabschluss, Geschäfts-Detail, geschäftsloser Scan in `GeschaeftListView`)
/// ist diese Ansicht seit 2026-07-21 zusätzlich als eigener Tab in ``RootView``
/// dauerhaft eingebettet (``istEigenerTab``, immer im ``BelegScanKontext/unbekannt``-
/// Kontext) — alle bisherigen Zugänge bleiben unverändert bestehen, der Tab ist nur
/// ein zusätzlicher, schnellerer Weg.
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
/// **Automatische Artikel-Zuordnung (``ArtikelZuordnungsService``):** Beim Einlesen
/// wird jede erkannte Position dreistufig einem bestehenden, generischen ``Artikel``
/// zugeordnet — gelernter Alias, sonst Teilstring-Abgleich, sonst (nur falls lokale
/// KI verfügbar) ein KI-Best-Match. Das Textfeld zeigt dabei den gefundenen
/// generischen Namen, der ursprüngliche Beleg-Text bleibt zusätzlich sichtbar
/// (``ErgebnisListe``). Bleibt jede Stufe erfolglos, gilt die Position als „neu
/// erkannt“ — der Anwender kann dann per Autocomplete einen bestehenden Artikel
/// wählen oder direkt einen neuen anlegen. Siehe `docs/BELEGSCAN.md`.
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
                        alleArtikel: alleArtikel,
                        geschaeftWaehlen: { zeigeGeschaeftWahl = true },
                        artikelDauerhaftIgnorieren: artikelDauerhaftIgnorieren,
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
                var neuePositionen: [BearbeitbarePosition] = []
                for position in ergebnis.positionen {
                    if IgnorierterArtikel.istIgnoriert(position.artikelName, geschaeft: erkanntesGeschaeft, unter: alleIgnoriertenArtikel) {
                        continue
                    }
                    let zuordnung = await ArtikelZuordnungsService.zuordnen(
                        erkannterName: position.artikelName,
                        bekannterVerlauf: bekannterVerlauf,
                        alleArtikel: alleArtikel
                    )
                    neuePositionen.append(BearbeitbarePosition(
                        erkannterName: position.artikelName,
                        artikelName: zuordnung.alias ?? zuordnung.artikel?.name ?? position.artikelName,
                        preisText: "\(position.einzelpreis.aufCentGerundet)",
                        zugeordneterArtikel: zuordnung.artikel,
                        boundingBox: scanErgebnis.ocrZeilen.boundingBox(fuerArtikelName: position.artikelName)
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
                if !erkannterGeschaeftName.isEmpty {
                    erkanntesGeschaeft?.alternativenNamenLernen(erkannterGeschaeftName)
                }
                // Hat das zugeordnete Geschäft noch keine Adresse, wird die auf dem
                // Beleg erkannte übernommen (GitHub #19) — unabhängig davon, ob das
                // Geschäft automatisch oder manuell über `GeschaeftWahlSheet`
                // zugeordnet wurde.
                if let erkanntesGeschaeft, erkanntesGeschaeft.adresse == nil, !getrimmteErkannteAdresse.isEmpty {
                    erkanntesGeschaeft.adresse = getrimmteErkannteAdresse
                    if let gelernteKoordinaten {
                        erkanntesGeschaeft.breitengrad = gelernteKoordinaten.breitengrad
                        erkanntesGeschaeft.laengengrad = gelernteKoordinaten.laengengrad
                    }
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
                            let artikel = position.effektivZugeordneterArtikel
                            let neuerEintrag = KaufEintrag(
                                artikel: artikel,
                                geschaeft: einkaufsvorgang.geschaeft,
                                kategorie: artikel?.fuehrendeKategorie(inGeschaeft: einkaufsvorgang.geschaeft, context: modelContext),
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
                        let artikel = position.effektivZugeordneterArtikel
                        let neuerEintrag = KaufEintrag(
                            artikel: artikel,
                            geschaeft: erkanntesGeschaeft,
                            kategorie: artikel?.fuehrendeKategorie(inGeschaeft: erkanntesGeschaeft, context: modelContext),
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
                modelContext.insert(IgnorierterArtikel(erkannterName: name, geschaeft: geschaeft))
            }
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
/// `zugeordneterArtikel` ist bereits beim Einlesen über
/// ``ArtikelZuordnungsService/zuordnen(erkannterName:bekannterVerlauf:alleArtikel:)``
/// ermittelt (siehe ``BelegScanView/verarbeite(bild:)``).
private struct BearbeitbarePosition: Identifiable {
    let id = UUID()
    let erkannterName: String
    var artikelName: String
    var preisText: String
    var zugeordneterArtikel: Artikel?
    /// Position dieser Zeile im Original-Beleg (Visions normalisiertes
    /// Koordinatensystem), ermittelt über ``ErkannteZeile/boundingBox(fuerArtikelName:)``
    /// — `nil`, wenn sich keine OCR-Zeile eindeutig zuordnen ließ (dann bietet
    /// ``ErgebnisListe`` für diese Zeile keinen „im Beleg zeigen“-Button an).
    var boundingBox: CGRect?

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
                         ? "Scanne den Kassenbon oder wähle ein Foto aus deiner Mediathek. Das Geschäft wird nach Möglichkeit automatisch erkannt."
                         : "Scanne den Kassenbon von „\(geschaeftName)“ oder wähle ein Foto aus deiner Mediathek.")
                } actions: {
                    VStack(spacing: 12) {
                        if VNDocumentCameraViewController.isSupported {
                            Button("Beleg scannen", action: kameraOeffnen)
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
    /// Grundlage für die Autocomplete-Vorschläge in ``PositionsZeile``.
    let alleArtikel: [Artikel]
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
                        PositionsZeile(position: $position, alleArtikel: alleArtikel) { boundingBox in
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
                    Text("Prüfe Name und Preis, bevor du übernimmst. Bereits bekannte Produkte werden automatisch dem passenden Artikel zugeordnet. Wischen nach links löscht eine Position nur für diesen Scan, nach rechts ignoriert sie dauerhaft für dieses Geschäft. Das Lupen-Symbol markiert die erkannte Stelle im Beleg-Foto oben, sofern eindeutig zuordenbar.")
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

/// Eine Zeile in ``ErgebnisListe`` für eine einzelne erkannte Belegposition —
/// Artikel-/Preisfeld, Original-Beleg-Name (falls abweichend), Zuordnungs-Status
/// sowie Inline-Autocomplete gegen ``alleArtikel``, solange das Artikelfeld
/// fokussiert ist. Tippen auf einen Vorschlag oder Neuanlegen eines Artikels
/// (``ArtikelEditView``, identisches Muster wie `KaufEintragZuordnenSheet`)
/// aktualisiert `position` direkt — siehe `docs/BELEGSCAN.md` → „Automatische
/// Artikel-Zuordnung“.
private struct PositionsZeile: View {
    @Binding var position: BearbeitbarePosition
    let alleArtikel: [Artikel]
    let belegFotoAnzeigen: (CGRect) -> Void

    @FocusState private var istFokussiert: Bool
    @State private var neuerArtikelEntwurf: Artikel?

    private var getrimmterName: String {
        position.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bis zu 5 nach Teilstring gefilterte Vorschläge — kompakt gehalten, damit die
    /// Liste nicht unübersichtlich wird.
    private var vorschlaege: [Artikel] {
        guard !getrimmterName.isEmpty else { return [] }
        return Array(alleArtikel.filter { $0.name.localizedCaseInsensitiveContains(getrimmterName) }.prefix(5))
    }

    private var zeigtNeuAnlegenOption: Bool {
        guard !getrimmterName.isEmpty else { return false }
        return !alleArtikel.contains { $0.name.localizedCaseInsensitiveCompare(getrimmterName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Artikel", text: $position.artikelName)
                        .focused($istFokussiert)
                    if !position.erkannterName.isEmpty,
                       position.artikelName.localizedCaseInsensitiveCompare(position.erkannterName) != .orderedSame {
                        Text("Original: „\(position.erkannterName)“")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                TextField("Preis", text: $position.preisText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("€")
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

            if let artikel = position.effektivZugeordneterArtikel {
                Label("Wird verknüpft mit „\(artikel.name)“", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Neu erkannt", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if istFokussiert, position.effektivZugeordneterArtikel == nil, !vorschlaege.isEmpty || zeigtNeuAnlegenOption {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vorschlaege) { artikel in
                        Button {
                            artikelZuweisen(artikel)
                        } label: {
                            Text(artikel.name)
                        }
                        .buttonStyle(.plain)
                    }
                    if zeigtNeuAnlegenOption {
                        Button {
                            neuenArtikelAnlegen()
                        } label: {
                            Label("„\(getrimmterName)“ neu anlegen", systemImage: "plus.circle.fill")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
        }
        .sheet(item: $neuerArtikelEntwurf, onDismiss: nachNeuanlageAufraeumen) { entwurf in
            ArtikelEditView(artikel: entwurf, istNeu: true)
        }
    }

    private func artikelZuweisen(_ artikel: Artikel) {
        position.artikelName = artikel.name
        position.zugeordneterArtikel = artikel
        istFokussiert = false
    }

    private func neuenArtikelAnlegen() {
        neuerArtikelEntwurf = Artikel(
            name: getrimmterName,
            symbolName: SymbolPalette.alle[0],
            farbeHex: Color.artikelPalette[0]
        )
    }

    /// Wurde der Entwurf tatsächlich gesichert (also in den Model-Context
    /// eingefügt), übernimmt diese Zeile ihn direkt als Zuordnung — siehe
    /// `KaufEintragZuordnenSheet.nachNeuanlageAufraeumen()` für dasselbe Muster.
    private func nachNeuanlageAufraeumen() {
        guard let entwurf = neuerArtikelEntwurf, entwurf.modelContext != nil else {
            neuerArtikelEntwurf = nil
            return
        }
        artikelZuweisen(entwurf)
        neuerArtikelEntwurf = nil
    }
}
