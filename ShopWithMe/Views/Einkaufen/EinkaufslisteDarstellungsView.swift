import SwiftUI
import SwiftData

// MARK: - Dispatcher

/// Wählt je nach ``DarstellungsKey/modus``-Einstellung den passenden Renderer
/// für den Artikelbereich der Einkaufsliste und leitet alle Daten weiter.
///
/// **Erweiterung für neue Varianten:**
/// 1. Neuen `case` in ``EinkaufslisteDarstellungsModus`` ergänzen
/// 2. Renderer-Sub-View anlegen (analog ``ListenInhaltView`` / ``KachelInhaltView``)
/// 3. switch-Fall in ``body`` ergänzen
/// 4. Einstellungs-Section in ``EinkaufslisteDarstellungsSettingsView`` ergänzen
struct EinkaufslisteDarstellungsView: View {
    let gruppen: [KategorieGruppe]
    let offeneEintraegeAnzahl: Int
    let abgehakteArtikel: [Artikel]
    let einkaufslistenName: String
    let istAbgehakt: (KategorieGruppe.Element) -> Bool
    let menge: (KategorieGruppe.Element) -> Double
    let mehrfachKategorisiert: (KategorieGruppe.Element) -> Bool
    let abhaken: (KategorieGruppe.Element, ArtikelKategorie) -> Void
    let mengeErhoehen: (KategorieGruppe.Element) -> Void
    let mengeVerringern: (KategorieGruppe.Element) -> Void
    let dauerhaftEntfernen: (KategorieGruppe.Element) -> Void

    @AppStorage(DarstellungsKey.modus) private var modus = EinkaufslisteDarstellungsModus.liste

    var body: some View {
        Group {
            switch modus {
            case .liste:
                ListenInhaltView(
                    gruppen: gruppen,
                    offeneEintraegeAnzahl: offeneEintraegeAnzahl,
                    abgehakteArtikel: abgehakteArtikel,
                    einkaufslistenName: einkaufslistenName,
                    istAbgehakt: istAbgehakt,
                    menge: menge,
                    mehrfachKategorisiert: mehrfachKategorisiert,
                    abhaken: abhaken,
                    mengeErhoehen: mengeErhoehen,
                    mengeVerringern: mengeVerringern,
                    dauerhaftEntfernen: dauerhaftEntfernen
                )
            case .kacheln:
                KachelInhaltView(
                    gruppen: gruppen,
                    offeneEintraegeAnzahl: offeneEintraegeAnzahl,
                    abgehakteArtikel: abgehakteArtikel,
                    einkaufslistenName: einkaufslistenName,
                    istAbgehakt: istAbgehakt,
                    menge: menge,
                    abhaken: abhaken
                )
            }
        }
    }
}

// MARK: - Listen-Renderer

/// Rendert die Artikelliste in den Untertypen Klassisch, Chips groß und
/// Chips klein — jeweils wahlweise mit Akkordeon, Fortschrittsbalken und
/// Farbstreifen (nur Klassisch).
private struct ListenInhaltView: View {
    let gruppen: [KategorieGruppe]
    let offeneEintraegeAnzahl: Int
    let abgehakteArtikel: [Artikel]
    let einkaufslistenName: String
    let istAbgehakt: (KategorieGruppe.Element) -> Bool
    let menge: (KategorieGruppe.Element) -> Double
    let mehrfachKategorisiert: (KategorieGruppe.Element) -> Bool
    let abhaken: (KategorieGruppe.Element, ArtikelKategorie) -> Void
    let mengeErhoehen: (KategorieGruppe.Element) -> Void
    let mengeVerringern: (KategorieGruppe.Element) -> Void
    let dauerhaftEntfernen: (KategorieGruppe.Element) -> Void

    @AppStorage(DarstellungsKey.listenTyp)    private var listenTyp        = ListenAnzeigeTyp.klassisch
    @AppStorage(DarstellungsKey.akkordeon)    private var akkordeon        = false
    @AppStorage(DarstellungsKey.fortschritt)  private var zeigeFortschritt = false
    @AppStorage(DarstellungsKey.farbstreifen) private var zeigeFarbstreifen = false

    /// Speichert geschlossene Kategorien; leere Menge = alle Kategorien offen (Startzustand).
    @State private var geschlosseneKategorien: Set<PersistentIdentifier> = []

    private var fortschrittswert: Double {
        let total = offeneEintraegeAnzahl + abgehakteArtikel.count
        guard total > 0 else { return 0 }
        return Double(abgehakteArtikel.count) / Double(total)
    }

    var body: some View {
        if gruppen.isEmpty {
            leerzustandView
        } else {
            switch listenTyp {
            case .klassisch:
                klassischView
            case .chipsGross:
                chipsScrollView(gross: true)
            case .chipsKlein:
                chipsScrollView(gross: false)
            }
        }
    }

    // MARK: Klassisch-Variante

    private var klassischView: some View {
        List {
            if akkordeon {
                ForEach(gruppen) { gruppe in
                    akkordeonSektion(gruppe: gruppe)
                }
            } else {
                ForEach(gruppen) { gruppe in
                    flacheSektion(gruppe: gruppe)
                }
            }
        }
        .safeAreaInset(edge: .top) { fortschrittHeader }
    }

    @ViewBuilder
    private func flacheSektion(gruppe: KategorieGruppe) -> some View {
        let kategorie = gruppe.kategorie
        Section {
            ForEach(gruppe.elemente) { element in
                ArtikelAbhakZeile(
                    artikel: element.artikel,
                    eintrag: element.eintrag,
                    mengeAnzeige: menge(element),
                    istAbgehakt: istAbgehakt(element),
                    mehrfachKategorisiert: mehrfachKategorisiert(element),
                    kategoriefarbe: zeigeFarbstreifen ? Color(hex: kategorie.standardFarbeHex) : nil,
                    abhaken: { abhaken(element, kategorie) },
                    mengeErhoehen: { mengeErhoehen(element) },
                    mengeVerringern: { mengeVerringern(element) },
                    dauerhaftEntfernen: istAbgehakt(element) ? { dauerhaftEntfernen(element) } : nil
                )
            }
        } header: {
            EinkaufslistenSektionHeader(kategorie: gruppe.kategorie)
        }
    }

    @ViewBuilder
    private func akkordeonSektion(gruppe: KategorieGruppe) -> some View {
        let kategorie = gruppe.kategorie
        let offenCount = gruppe.elemente.filter { $0.eintrag != nil }.count
        DisclosureGroup(
            isExpanded: Binding(
                get: { !geschlosseneKategorien.contains(kategorie.persistentModelID) },
                set: { offen in
                    if offen {
                        geschlosseneKategorien.remove(kategorie.persistentModelID)
                    } else {
                        geschlosseneKategorien.insert(kategorie.persistentModelID)
                    }
                }
            )
        ) {
            ForEach(gruppe.elemente) { element in
                ArtikelAbhakZeile(
                    artikel: element.artikel,
                    eintrag: element.eintrag,
                    mengeAnzeige: menge(element),
                    istAbgehakt: istAbgehakt(element),
                    mehrfachKategorisiert: mehrfachKategorisiert(element),
                    kategoriefarbe: zeigeFarbstreifen ? Color(hex: kategorie.standardFarbeHex) : nil,
                    abhaken: { abhaken(element, kategorie) },
                    mengeErhoehen: { mengeErhoehen(element) },
                    mengeVerringern: { mengeVerringern(element) },
                    dauerhaftEntfernen: istAbgehakt(element) ? { dauerhaftEntfernen(element) } : nil
                )
            }
        } label: {
            akkordeonHeader(kategorie: kategorie, offenCount: offenCount)
        }
    }

    @ViewBuilder
    private func akkordeonHeader(kategorie: ArtikelKategorie, offenCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kategorie.standardSymbol)
                .foregroundStyle(Color(hex: kategorie.standardFarbeHex))
                .frame(width: 20)
            Text(kategorie.name).font(.headline)
            Spacer()
            if offenCount > 0 {
                Text("\(offenCount)")
                    .font(.caption.bold()).foregroundStyle(Color.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(hex: kategorie.standardFarbeHex))
                    .clipShape(Capsule())
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.green).font(.callout)
            }
        }
    }

    // MARK: Chips-Variante

    private func chipsScrollView(gross: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(gruppen) { gruppe in
                    chipsSektion(gruppe: gruppe, gross: gross)
                }
            }
            .padding()
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top) { fortschrittHeader }
    }

    @ViewBuilder
    private func chipsSektion(gruppe: KategorieGruppe, gross: Bool) -> some View {
        let kategorie = gruppe.kategorie
        let farbe = Color(hex: kategorie.standardFarbeHex)
        VStack(alignment: .leading, spacing: 8) {
            if akkordeon {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { !geschlosseneKategorien.contains(kategorie.persistentModelID) },
                        set: { offen in
                            if offen {
                                geschlosseneKategorien.remove(kategorie.persistentModelID)
                            } else {
                                geschlosseneKategorien.insert(kategorie.persistentModelID)
                            }
                        }
                    )
                ) {
                    chipFlow(gruppe: gruppe, farbe: farbe, gross: gross)
                        .padding(.top, 4)
                } label: {
                    chipSektionLabel(kategorie: kategorie, farbe: farbe)
                }
            } else {
                chipSektionLabel(kategorie: kategorie, farbe: farbe)
                chipFlow(gruppe: gruppe, farbe: farbe, gross: gross)
            }
        }
    }

    private func chipSektionLabel(kategorie: ArtikelKategorie, farbe: Color) -> some View {
        Label(kategorie.name, systemImage: kategorie.standardSymbol)
            .font(.subheadline.bold())
            .foregroundStyle(farbe)
    }

    private func chipFlow(gruppe: KategorieGruppe, farbe: Color, gross: Bool) -> some View {
        ChipFlowLayout(abstand: 8) {
            ForEach(gruppe.elemente) { element in
                let erledigt = istAbgehakt(element)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        abhaken(element, gruppe.kategorie)
                    }
                } label: {
                    if gross {
                        grosserChip(element: element, farbe: farbe, erledigt: erledigt)
                    } else {
                        kleinerChip(element: element, farbe: farbe, erledigt: erledigt)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func kleinerChip(element: KategorieGruppe.Element, farbe: Color, erledigt: Bool) -> some View {
        HStack(spacing: 5) {
            if erledigt { Image(systemName: "checkmark").font(.caption2.bold()) }
            Text(element.artikel.name).font(.subheadline).strikethrough(erledigt)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(farbe.opacity(erledigt ? 0.12 : 0.07))
        .foregroundStyle(erledigt ? Color.secondary : farbe)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(farbe.opacity(erledigt ? 0.2 : 0.4), lineWidth: 1))
    }

    // Großer Chip bewusst OHNE Kategorie-Icon — bessere Lesbarkeit bei mehreren Chips
    // pro Zeile; das Abhak-Symbol übernimmt die Statuskommunikation.
    private func grosserChip(element: KategorieGruppe.Element, farbe: Color, erledigt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(element.artikel.name)
                .font(.subheadline.weight(.medium))
                .strikethrough(erledigt)
                .foregroundStyle(erledigt ? Color.secondary : Color.primary)
            Text("\(menge(element).formatted()) \(element.artikel.einheit.kurzform)")
                .font(.caption2).foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(erledigt ? Color.secondary.opacity(0.08) : farbe.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(erledigt ? Color.secondary.opacity(0.15) : farbe.opacity(0.25), lineWidth: 1))
        .opacity(erledigt ? 0.6 : 1)
    }

    // MARK: Gemeinsame Elemente

    @ViewBuilder
    private var fortschrittHeader: some View {
        if zeigeFortschritt {
            let total = offeneEintraegeAnzahl + abgehakteArtikel.count
            let wert = total > 0 ? Double(abgehakteArtikel.count) / Double(total) : 0.0
            VStack(spacing: 4) {
                ProgressView(value: wert).tint(.green).padding(.horizontal)
                HStack {
                    Text("\(offeneEintraegeAnzahl) übrig")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(wert * 100)) %")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                }
                .padding(.horizontal).padding(.bottom, 6)
            }
            .padding(.top, 8).background(.bar)
        }
    }

    @ViewBuilder
    private var leerzustandView: some View {
        if offeneEintraegeAnzahl > 0 {
            ContentUnavailableView(
                "Keine verfügbaren Artikel",
                systemImage: "checklist",
                description: Text("Halte die Schnellauswahl oben gedrückt und aktiviere den Lernmodus, um bislang unbekannte Artikel abzuhaken.")
            )
        } else if abgehakteArtikel.isEmpty {
            ContentUnavailableView(
                "Einkaufsliste ist leer",
                systemImage: "checklist",
                description: Text("Füge oben rechts Artikel zu \"\(einkaufslistenName)\" hinzu.")
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

// MARK: - Kachel-Renderer

/// Rendert alle Artikel als 2- oder 3-spaltiges Kachel-Raster — flat ohne
/// Kategoriesektionen, wahlweise mit Kategorie-Farbhintergrund.
private struct KachelInhaltView: View {
    let gruppen: [KategorieGruppe]
    let offeneEintraegeAnzahl: Int
    let abgehakteArtikel: [Artikel]
    let einkaufslistenName: String
    let istAbgehakt: (KategorieGruppe.Element) -> Bool
    let menge: (KategorieGruppe.Element) -> Double
    let abhaken: (KategorieGruppe.Element, ArtikelKategorie) -> Void

    @AppStorage(DarstellungsKey.spalten) private var spaltenRaw = KachelSpaltenanzahl.zwei.rawValue
    @AppStorage(DarstellungsKey.farbig)  private var farbig = false

    private struct KachelItem: Identifiable {
        let element: KategorieGruppe.Element
        let kategorie: ArtikelKategorie
        let farbe: Color
        let symbol: String
        var id: PersistentIdentifier { element.id }
    }

    private var kachelArtikel: [KachelItem] {
        var gesehen = Set<PersistentIdentifier>()
        return gruppen.flatMap { gruppe in
            gruppe.elemente.compactMap { element in
                guard gesehen.insert(element.artikel.persistentModelID).inserted else { return nil }
                return KachelItem(
                    element: element,
                    kategorie: gruppe.kategorie,
                    farbe: Color(hex: gruppe.kategorie.standardFarbeHex),
                    symbol: gruppe.kategorie.standardSymbol
                )
            }
        }
    }

    private var dreispaltig: Bool { KachelSpaltenanzahl(rawValue: spaltenRaw) == .drei }

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: dreispaltig ? 3 : 2)
    }

    var body: some View {
        if kachelArtikel.isEmpty {
            leerzustandView
        } else {
            ScrollView {
                LazyVGrid(columns: spalten, spacing: dreispaltig ? 8 : 12) {
                    ForEach(kachelArtikel) { item in
                        let erledigt = istAbgehakt(item.element)
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                abhaken(item.element, item.kategorie)
                            }
                        } label: {
                            kachelLabel(item: item, erledigt: erledigt)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(dreispaltig ? 12 : 16)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    @ViewBuilder
    private func kachelLabel(item: KachelItem, erledigt: Bool) -> some View {
        VStack(spacing: dreispaltig ? 6 : 10) {
            Image(systemName: erledigt ? (dreispaltig ? "checkmark.circle.fill" : "checkmark") : item.symbol)
                .font(dreispaltig ? .title3 : .system(size: 30))
                .foregroundStyle(erledigt ? .green : (farbig ? Color.white : item.farbe))
                .frame(height: dreispaltig ? 28 : 40)
            Text(item.element.artikel.name)
                .font(dreispaltig ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .strikethrough(erledigt)
                .foregroundStyle(erledigt ? Color.secondary : (farbig ? Color.white : Color.primary))
                .multilineTextAlignment(.center)
                .lineLimit(dreispaltig ? 2 : nil)
            Text("\(menge(item.element).formatted()) \(item.element.artikel.einheit.kurzform)")
                .font(.caption2)
                .foregroundStyle(farbig ? Color.white.opacity(0.75) : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: dreispaltig ? 80 : nil)
        .padding(.vertical, dreispaltig ? 8 : 16)
        .padding(.horizontal, 8)
        .background(kachelHintergrund(farbe: item.farbe, erledigt: erledigt))
        .clipShape(RoundedRectangle(cornerRadius: dreispaltig ? 12 : 16, style: .continuous))
        .overlay(kachelRahmen(erledigt: erledigt))
        .opacity(erledigt ? (dreispaltig ? 0.65 : 0.7) : 1)
    }

    private func kachelHintergrund(farbe: Color, erledigt: Bool) -> Color {
        if farbig {
            return erledigt ? Color.gray.opacity(0.35) : farbe.opacity(0.75)
        }
        return erledigt ? Color.green.opacity(0.08) : Color(.secondarySystemGroupedBackground)
    }

    @ViewBuilder
    private func kachelRahmen(erledigt: Bool) -> some View {
        let radius: CGFloat = dreispaltig ? 12 : 16
        if farbig {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(erledigt ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private var leerzustandView: some View {
        if offeneEintraegeAnzahl > 0 {
            ContentUnavailableView(
                "Keine verfügbaren Artikel",
                systemImage: "checklist",
                description: Text("Halte die Schnellauswahl oben gedrückt und aktiviere den Lernmodus, um bislang unbekannte Artikel abzuhaken.")
            )
        } else if abgehakteArtikel.isEmpty {
            ContentUnavailableView(
                "Einkaufsliste ist leer",
                systemImage: "checklist",
                description: Text("Füge oben rechts Artikel zu \"\(einkaufslistenName)\" hinzu.")
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
