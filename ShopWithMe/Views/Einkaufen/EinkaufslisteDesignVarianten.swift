import SwiftUI

// MARK: - Mock-Daten

private struct MockArtikel: Identifiable {
    let id = UUID()
    var name: String
    var menge: Double
    var einheit: String
    var kategorie: String
    var symbol: String
    var farbe: Color

    var mengenText: String {
        menge.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(menge)) \(einheit)"
            : String(format: "%.1f %@", menge, einheit)
    }
}

private struct MockKategorie: Identifiable {
    let id = UUID()
    var name: String
    var symbol: String
    var farbe: Color
    var artikel: [MockArtikel]
}

private let alleArtikel: [MockArtikel] = [
    .init(name: "Vollmilch",   menge: 2,   einheit: "l",    kategorie: "Getränke",      symbol: "drop.fill",   farbe: .blue),
    .init(name: "Orangensaft", menge: 1,   einheit: "l",    kategorie: "Getränke",      symbol: "drop.fill",   farbe: .cyan),
    .init(name: "Butter",      menge: 1,   einheit: "Stk.", kategorie: "Milchprodukte", symbol: "cube.fill",   farbe: .yellow),
    .init(name: "Joghurt",     menge: 3,   einheit: "Stk.", kategorie: "Milchprodukte", symbol: "cube.fill",   farbe: .yellow),
    .init(name: "Käse",        menge: 200, einheit: "g",    kategorie: "Milchprodukte", symbol: "square.fill", farbe: .orange),
    .init(name: "Äpfel",       menge: 6,   einheit: "Stk.", kategorie: "Obst & Gemüse", symbol: "leaf.fill",   farbe: .green),
    .init(name: "Bananen",     menge: 1,   einheit: "Bund", kategorie: "Obst & Gemüse", symbol: "leaf.fill",   farbe: .yellow),
    .init(name: "Tomaten",     menge: 4,   einheit: "Stk.", kategorie: "Obst & Gemüse", symbol: "circle.fill", farbe: .red),
    .init(name: "Brot",        menge: 1,   einheit: "Stk.", kategorie: "Backwaren",     symbol: "bag.fill",    farbe: .brown),
    .init(name: "Brötchen",    menge: 6,   einheit: "Stk.", kategorie: "Backwaren",     symbol: "bag",         farbe: .brown),
    .init(name: "Pasta",       menge: 500, einheit: "g",    kategorie: "Nudeln & Reis", symbol: "fork.knife",  farbe: .orange),
    .init(name: "Schokolade",  menge: 2,   einheit: "Stk.", kategorie: "Süßigkeiten",   symbol: "star.fill",   farbe: .pink),
]

private let alleKategorien: [MockKategorie] = {
    let reihenfolge = ["Getränke", "Milchprodukte", "Obst & Gemüse", "Backwaren", "Nudeln & Reis", "Süßigkeiten"]
    let meta: [String: (String, Color)] = [
        "Getränke":      ("drop.fill",  .blue),
        "Milchprodukte": ("cube.fill",  .yellow),
        "Obst & Gemüse": ("leaf.fill",  .green),
        "Backwaren":     ("bag.fill",   .brown),
        "Nudeln & Reis": ("fork.knife", .orange),
        "Süßigkeiten":   ("star.fill",  .pink),
    ]
    let gruppen = Dictionary(grouping: alleArtikel, by: \.kategorie)
    return reihenfolge.compactMap { name -> MockKategorie? in
        guard let art = gruppen[name] else { return nil }
        let (sym, farbe) = meta[name] ?? ("tag.fill", .gray)
        return MockKategorie(name: name, symbol: sym, farbe: farbe, artikel: art)
    }
}()

// MARK: - Gemeinsame Hilfs-Views

private struct FortschrittHeader: View {
    let fortschritt: Double
    let total: Int
    let abgehakt: Int

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: fortschritt).tint(.green).padding(.horizontal)
            HStack {
                Text("\(total - abgehakt) übrig")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fortschritt * 100)) %")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.green)
            }
            .padding(.horizontal).padding(.bottom, 6)
        }
        .padding(.top, 8).background(.bar)
    }
}

private struct ArtikelFarbbalkenZeile: View {
    let artikel: MockArtikel
    let farbe: Color
    let erledigt: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(erledigt ? Color.green : farbe)
                .frame(width: 4)
            HStack(spacing: 10) {
                Image(systemName: erledigt ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(erledigt ? Color.green : Color.secondary)
                    .font(.title3)
                Text(artikel.name)
                    .strikethrough(erledigt)
                    .foregroundStyle(erledigt ? Color.secondary : Color.primary)
                Spacer()
                Text(artikel.mengenText)
                    .font(.caption2).foregroundStyle(Color.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.vertical, 10)
            .padding(.leading, 12)
        }
    }
}

private struct ErledigtStatusLeiste: View {
    let abgehakt: Int
    let total: Int

    var body: some View {
        Text("\(abgehakt) von \(total) erledigt")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8).background(.bar)
    }
}

// MARK: - Variante 1: Klassisch + Farbbalken + Menge-Badge + Fortschritt

/// Klassische Gruppenliste mit Kategorie-Farbbalken links, Menge als Capsule-Badge
/// und Gesamtfortschrittsbalken oben.
private struct Variante01Klassisch: View {
    @State private var abgehakt: Set<UUID> = []

    private var fortschritt: Double {
        alleArtikel.isEmpty ? 0 : Double(abgehakt.count) / Double(alleArtikel.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            FortschrittHeader(fortschritt: fortschritt, total: alleArtikel.count, abgehakt: abgehakt.count)

            List {
                ForEach(alleKategorien) { kategorie in
                    Section {
                        ForEach(kategorie.artikel) { artikel in
                            let erledigt = abgehakt.contains(artikel.id)
                            Button {
                                if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                            } label: {
                                ArtikelFarbbalkenZeile(artikel: artikel, farbe: kategorie.farbe, erledigt: erledigt)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                        }
                    } header: {
                        Label(kategorie.name, systemImage: kategorie.symbol)
                            .foregroundStyle(kategorie.farbe)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Variante 10: Akkordeon + Farbbalken + Fortschritt

/// Akkordeon-Kategorien mit Gesamtfortschrittsbalken oben und Kategorie-Farbbalken
/// in jeder Zeile.
private struct Variante10Akkordeon: View {
    @State private var abgehakt: Set<UUID> = []
    @State private var geoffnet: Set<UUID> = Set(alleKategorien.map(\.id))

    private var fortschritt: Double {
        alleArtikel.isEmpty ? 0 : Double(abgehakt.count) / Double(alleArtikel.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            FortschrittHeader(fortschritt: fortschritt, total: alleArtikel.count, abgehakt: abgehakt.count)

            List {
                ForEach(alleKategorien) { kategorie in
                    let offen = kategorie.artikel.filter { !abgehakt.contains($0.id) }.count
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { geoffnet.contains(kategorie.id) },
                            set: { neu in if neu { geoffnet.insert(kategorie.id) } else { geoffnet.remove(kategorie.id) } }
                        )
                    ) {
                        ForEach(kategorie.artikel) { artikel in
                            let erledigt = abgehakt.contains(artikel.id)
                            Button {
                                if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                            } label: {
                                ArtikelFarbbalkenZeile(artikel: artikel, farbe: kategorie.farbe, erledigt: erledigt)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                        }
                    } label: {
                        akkordeonHeader(kategorie, offenCount: offen)
                    }
                }
            }
        }
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func akkordeonHeader(_ kategorie: MockKategorie, offenCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kategorie.symbol).foregroundStyle(kategorie.farbe).frame(width: 20)
            Text(kategorie.name).font(.headline)
            Spacer()
            if offenCount > 0 {
                Text("\(offenCount)")
                    .font(.caption.bold()).foregroundStyle(Color.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(kategorie.farbe).clipShape(Capsule())
            } else {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green).font(.callout)
            }
        }
    }
}

// MARK: - Variante 2: Kachel-Raster (2-spaltig)

/// 2-spaltiges Kachel-Raster — Symbol oben, Name mittig, Menge unten.
private struct Variante02KachelRaster: View {
    @State private var abgehakt: Set<UUID> = []
    private let spalten = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: spalten, spacing: 12) {
                ForEach(alleArtikel) { artikel in
                    let erledigt = abgehakt.contains(artikel.id)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                        }
                    } label: {
                        kachelLabel(artikel, erledigt: erledigt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func kachelLabel(_ artikel: MockArtikel, erledigt: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: erledigt ? "checkmark" : artikel.symbol)
                .font(.system(size: 30))
                .foregroundStyle(erledigt ? Color.green : artikel.farbe)
                .frame(height: 40)
            Text(artikel.name)
                .font(.subheadline.weight(.medium))
                .strikethrough(erledigt)
                .foregroundStyle(erledigt ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
            Text(artikel.mengenText)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16).padding(.horizontal, 8)
        .background(erledigt ? Color.green.opacity(0.08) : Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(erledigt ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1.5))
        .opacity(erledigt ? 0.7 : 1)
    }
}

// MARK: - Variante 2b: Drei-Spalten-Raster

/// Engeres 3-Spalten-Raster — mehr Artikel auf einmal sichtbar.
private struct Variante02bDreiSpalten: View {
    @State private var abgehakt: Set<UUID> = []
    private let spalten = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: spalten, spacing: 8) {
                ForEach(alleArtikel) { artikel in
                    let erledigt = abgehakt.contains(artikel.id)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                        }
                    } label: {
                        dreiSpaltenKachel(artikel, erledigt: erledigt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func dreiSpaltenKachel(_ artikel: MockArtikel, erledigt: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: erledigt ? "checkmark.circle.fill" : artikel.symbol)
                .font(.title3)
                .foregroundStyle(erledigt ? Color.green : artikel.farbe)
                .frame(height: 28)
            Text(artikel.name)
                .font(.caption.weight(.medium))
                .strikethrough(erledigt)
                .foregroundStyle(erledigt ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(artikel.mengenText)
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(8)
        .background(erledigt ? Color.green.opacity(0.07) : Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(erledigt ? 0.65 : 1)
    }
}

// MARK: - Variante 2c: Farb-Kacheln

/// Jede Kachel hat den Farbhintergrund ihrer Kategorie — bunte, visuelle Orientierung.
private struct Variante02cFarbKacheln: View {
    @State private var abgehakt: Set<UUID> = []
    private let spalten = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: spalten, spacing: 10) {
                ForEach(alleArtikel) { artikel in
                    let erledigt = abgehakt.contains(artikel.id)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                        }
                    } label: {
                        farbKachelLabel(artikel, farbe: artikel.farbe, erledigt: erledigt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func farbKachelLabel(_ artikel: MockArtikel, farbe: Color, erledigt: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: erledigt ? "checkmark" : artikel.symbol)
                .font(.system(size: 28))
                .foregroundStyle(erledigt ? Color.white.opacity(0.7) : Color.white)
                .frame(height: 36)
            Text(artikel.name)
                .font(.subheadline.weight(.semibold))
                .strikethrough(erledigt)
                .foregroundStyle(erledigt ? Color.white.opacity(0.5) : Color.white)
                .multilineTextAlignment(.center)
            Text(artikel.mengenText)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14).padding(.horizontal, 8)
        .background(erledigt ? Color.gray.opacity(0.35) : farbe.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Variante 7: Chip-Auswahl (Flow-Layout)

/// Artikel als anklickbare Chips im Fließ-Layout, nach Kategorie gruppiert.
private struct Variante07ChipAuswahl: View {
    @State private var abgehakt: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(alleKategorien) { kategorie in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(kategorie.name, systemImage: kategorie.symbol)
                            .font(.subheadline.bold())
                            .foregroundStyle(kategorie.farbe)
                        ChipFlowLayout(abstand: 8) {
                            ForEach(kategorie.artikel) { artikel in
                                let erledigt = abgehakt.contains(artikel.id)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if erledigt { Image(systemName: "checkmark").font(.caption2.bold()) }
                                        Text(artikel.name).font(.subheadline).strikethrough(erledigt)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(kategorie.farbe.opacity(erledigt ? 0.12 : 0.07))
                                    .foregroundStyle(erledigt ? Color.secondary : kategorie.farbe)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(kategorie.farbe.opacity(erledigt ? 0.2 : 0.4), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding().padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom) {
            ErledigtStatusLeiste(abgehakt: abgehakt.count, total: alleArtikel.count)
        }
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Variante 7d: Große Symbol-Chips nach Kategorie gruppiert

/// Größere Chips mit Kategorie-Symbol und Mengenzeile, nach Kategorie gruppiert.
private struct Variante07dGrosseChips: View {
    @State private var abgehakt: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(alleKategorien) { kategorie in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(kategorie.name, systemImage: kategorie.symbol)
                            .font(.subheadline.bold())
                            .foregroundStyle(kategorie.farbe)
                        ChipFlowLayout(abstand: 8) {
                            ForEach(kategorie.artikel) { artikel in
                                let erledigt = abgehakt.contains(artikel.id)
                                Button {
                                    withAnimation(.spring(response: 0.25)) {
                                        if erledigt { abgehakt.remove(artikel.id) } else { abgehakt.insert(artikel.id) }
                                    }
                                } label: {
                                    grosserChipLabel(artikel, farbe: kategorie.farbe, erledigt: erledigt)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding().padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom) {
            ErledigtStatusLeiste(abgehakt: abgehakt.count, total: alleArtikel.count)
        }
        .navigationTitle("Wocheneinkauf")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func grosserChipLabel(_ artikel: MockArtikel, farbe: Color, erledigt: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: erledigt ? "checkmark.circle.fill" : artikel.symbol)
                .font(.body)
                .foregroundStyle(erledigt ? Color.green : farbe)
            VStack(alignment: .leading, spacing: 1) {
                Text(artikel.name)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(erledigt)
                    .foregroundStyle(erledigt ? Color.secondary : Color.primary)
                Text(artikel.mengenText)
                    .font(.caption2).foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(erledigt ? Color.secondary.opacity(0.08) : farbe.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(erledigt ? Color.secondary.opacity(0.15) : farbe.opacity(0.25), lineWidth: 1))
        .opacity(erledigt ? 0.6 : 1)
    }
}

// MARK: - ChipFlowLayout

private struct ChipFlowLayout: Layout {
    var abstand: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        berechne(subviews: subviews, breite: proposal.replacingUnspecifiedDimensions().width).gesamtGroesse
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let info = berechne(subviews: subviews, breite: bounds.width)
        for (view, frame) in zip(subviews, info.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: .init(frame.size))
        }
    }

    private struct Info { var frames: [CGRect]; var gesamtGroesse: CGSize }

    private func berechne(subviews: Subviews, breite: CGFloat) -> Info {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, zeilenHoehe: CGFloat = 0
        for subview in subviews {
            let g = subview.sizeThatFits(.unspecified)
            if x + g.width > breite, x > 0 { y += zeilenHoehe + abstand; x = 0; zeilenHoehe = 0 }
            frames.append(CGRect(origin: .init(x: x, y: y), size: g))
            x += g.width + abstand
            zeilenHoehe = max(zeilenHoehe, g.height)
        }
        return Info(frames: frames, gesamtGroesse: CGSize(width: breite, height: y + zeilenHoehe))
    }
}

// MARK: - Preview

#Preview("Einkaufsliste – Design-Varianten") {
    NavigationStack {
        List {
            Section("Liste") {
                NavigationLink("1 – Klassisch + Farbbalken + Badge + Fortschritt") { Variante01Klassisch() }
                NavigationLink("10 – Akkordeon + Farbbalken + Fortschritt")         { Variante10Akkordeon() }
            }
            Section("Kacheln") {
                NavigationLink("2 – 2-spaltiges Raster")    { Variante02KachelRaster() }
                NavigationLink("2b – 3-spaltiges Raster")   { Variante02bDreiSpalten() }
                NavigationLink("2c – Farbige Kacheln")      { Variante02cFarbKacheln() }
            }
            Section("Chips") {
                NavigationLink("7 – Chips nach Kategorie")  { Variante07ChipAuswahl() }
                NavigationLink("7d – Große Symbol-Chips")   { Variante07dGrosseChips() }
            }
        }
        .navigationTitle("Design-Varianten")
    }
}
