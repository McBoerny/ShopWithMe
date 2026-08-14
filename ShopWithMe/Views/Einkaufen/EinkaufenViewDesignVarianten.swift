import SwiftUI

// MARK: - Mock-Daten

private let mockGeschaefte = ["Rewe", "Edeka", "Aldi", "Lidl", "DM"]
private let mockListen     = ["Wocheneinkauf", "Baumarkt", "Drogerie"]

// MARK: - Platzhalter für EinkaufslisteView

/// Repräsentiert die echte EinkaufslisteView in allen Layout-Varianten.
private struct EinkaufslistePlatzhalter: View {
    let geschaeft: String?
    let liste: String

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checklist")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary.opacity(0.3))
                Text(liste).font(.headline).foregroundStyle(.secondary)
                if let g = geschaeft {
                    Label(g, systemImage: "cart.fill")
                        .font(.subheadline).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Layout 1: Toolbar (Referenz – aktuelles Design)

/// Aktuelles Design: Liste führend links, Geschäft zentriert als Menü.
private struct EinkaufenLayout01Toolbar: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]

    var body: some View {
        EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
            .navigationTitle("Einkaufen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Liste", selection: $liste) {
                            ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Label(liste, systemImage: "checklist")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Geschäft", selection: $geschaeft) {
                            Text("Kein Geschäft").tag(String?.none)
                            ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cart.fill")
                            Text(geschaeft ?? "Geschäft")
                        }
                    }
                }
            }
    }
}

// MARK: - Layout 2: Bottom-Bar

/// Liste und Geschäft werden in einer permanenten Bottom-Bar gewählt.
private struct EinkaufenLayout02BottomBar: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]

    var body: some View {
        EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
            .navigationTitle(liste)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Menu {
                        Picker("Liste", selection: $liste) {
                            ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "checklist").font(.title3)
                            Text(liste).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }

                    Divider().frame(height: 40)

                    Menu {
                        Picker("Geschäft", selection: $geschaeft) {
                            Text("Kein Geschäft").tag(String?.none)
                            ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "cart.fill")
                                .font(.title3)
                                .foregroundStyle(geschaeft != nil ? Color.accentColor : Color.secondary)
                            Text(geschaeft ?? "Kein Geschäft")
                                .font(.caption2).lineLimit(1)
                                .foregroundStyle(geschaeft != nil ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                }
                .background(.bar)
            }
    }
}

// MARK: - Layout 3: Inline-Header (kein Navigationstitel)

/// Auswahl-Leiste direkt oberhalb der Liste; kein Navigationstitel.
private struct EinkaufenLayout03InlineHeader: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Picker("Liste", selection: $liste) {
                        ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(liste, systemImage: "checklist")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Menu {
                    Picker("Geschäft", selection: $geschaeft) {
                        Text("Kein Geschäft").tag(String?.none)
                        ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                    }
                } label: {
                    Label(geschaeft ?? "Kein Geschäft", systemImage: "cart.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(geschaeft != nil ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Layout 4: Aufklappbare Auswahl-Leiste

/// Ein schmaler Streifen zeigt die aktuelle Auswahl; Tipp klappt den Picker aus.
private struct EinkaufenLayout04AufklappLeiste: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]
    @State private var ausgeklappt = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3)) { ausgeklappt.toggle() }
            } label: {
                HStack {
                    Label(liste, systemImage: "checklist").font(.subheadline)
                    Spacer()
                    Label(geschaeft ?? "Kein Geschäft", systemImage: "cart.fill")
                        .font(.subheadline)
                        .foregroundStyle(geschaeft != nil ? Color.primary : Color.secondary)
                    Image(systemName: ausgeklappt ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.vertical, 10)
                .background(.bar)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { Divider() }

            if ausgeklappt {
                VStack(spacing: 0) {
                    Picker("Liste", selection: $liste) {
                        ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.vertical, 8)
                    Divider()
                    Picker("Geschäft", selection: $geschaeft) {
                        Text("Kein Geschäft").tag(String?.none)
                        ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120).clipped()
                }
                .background(Color(.secondarySystemBackground))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
        }
        .navigationTitle("Einkaufen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Layout 5: Geschäft zuerst (Onboarding-Karte)

/// Ohne Geschäftswahl erscheint eine Auswahl-Karte; danach öffnet die Liste.
private struct EinkaufenLayout05GeschaeftZuerst: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]
    @State private var gestartet = false

    var body: some View {
        Group {
            if gestartet {
                EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
            } else {
                geschaeftAuswahlKarte
            }
        }
        .navigationTitle(gestartet ? liste : "Wo kaufst du ein?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if gestartet {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Liste", selection: $liste) {
                            ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Label(liste, systemImage: "checklist") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.4)) { gestartet = false; geschaeft = nil }
                    } label: {
                        Image(systemName: "cart.badge.questionmark")
                    }
                }
            }
        }
    }

    private var geschaeftAuswahlKarte: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "storefront.fill")
                        .font(.system(size: 52)).foregroundStyle(.secondary)
                    Text("In welchem Geschäft kaufst du ein?")
                        .font(.headline).multilineTextAlignment(.center)
                    Text("Die Liste wird nach dem Sortiment geordnet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(spacing: 0) {
                    ForEach(mockGeschaefte, id: \.self) { g in
                        if g != mockGeschaefte.first { Divider().padding(.leading, 52) }
                        Button {
                            withAnimation(.spring(response: 0.4)) { geschaeft = g; gestartet = true }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "cart.fill")
                                    .foregroundStyle(Color.accentColor).frame(width: 24)
                                Text(g).foregroundStyle(Color.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                            .padding(.horizontal).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

                Button {
                    withAnimation(.spring(response: 0.4)) { gestartet = true }
                } label: {
                    Text("Ohne Geschäft starten")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - Layout 6: Schwebende Pille

/// Die Liste füllt den gesamten Screen; eine Pille am unteren Rand zeigt Kontext.
private struct EinkaufenLayout06SchwebendePille: View {
    @State private var geschaeft: String? = "Rewe"
    @State private var liste = mockListen[0]
    @State private var zeigeSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
                .ignoresSafeArea()

            Button { zeigeSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                    Text(liste).lineLimit(1)
                    Divider().frame(height: 16)
                    Image(systemName: "cart.fill")
                    Text(geschaeft ?? "Kein Geschäft").lineLimit(1)
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 28)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $zeigeSheet) {
            NavigationStack {
                Form {
                    Picker("Einkaufsliste", selection: $liste) {
                        ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Geschäft", selection: $geschaeft) {
                        Text("Kein Geschäft").tag(String?.none)
                        ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                    }
                }
                .navigationTitle("Auswahl").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { zeigeSheet = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Layout 7: Großer Titel + Geschäft-Badge

/// Der Listenname steht als Large Title; das Geschäft erscheint als Badge darunter.
private struct EinkaufenLayout07GrosserTitel: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]

    var body: some View {
        EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
            .safeAreaInset(edge: .top) {
                if let g = geschaeft {
                    HStack {
                        Label(g, systemImage: "cart.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                        Spacer()
                        Button { geschaeft = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(.bar)
                }
            }
            .navigationTitle(liste)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Liste", selection: $liste) {
                            ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Image(systemName: "text.badge.checkmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Geschäft", selection: $geschaeft) {
                            Text("Kein Geschäft").tag(String?.none)
                            ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                        }
                    } label: { Image(systemName: "cart") }
                }
            }
    }
}

// MARK: - Layout 8: Zweizeilen-Header

/// Zwei tippbare Menü-Zeilen – oben die Liste, darunter das Geschäft – ersetzen die Toolbar.
private struct EinkaufenLayout08ZweiZeilen: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Liste", selection: $liste) {
                    ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack {
                    Image(systemName: "checklist").foregroundStyle(Color.accentColor).frame(width: 24)
                    Text(liste).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.vertical, 10)
                .background(.bar).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 44)

            Menu {
                Picker("Geschäft", selection: $geschaeft) {
                    Text("Kein Geschäft").tag(String?.none)
                    ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                }
            } label: {
                HStack {
                    Image(systemName: "cart.fill")
                        .foregroundStyle(geschaeft != nil ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                    Text(geschaeft ?? "Kein Geschäft")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(geschaeft != nil ? Color.primary : Color.secondary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.vertical, 10)
                .background(.bar).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Layout 9: Segmented-Control für Listenwahl

/// Segmented-Control oben für die Listenwahl; Geschäft bleibt in der Toolbar.
private struct EinkaufenLayout09SegmentListen: View {
    @State private var geschaeft: String?
    @State private var listenIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Liste", selection: $listenIndex) {
                ForEach(Array(mockListen.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: mockListen[listenIndex])
        }
        .navigationTitle("Einkaufen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Picker("Geschäft", selection: $geschaeft) {
                        Text("Kein Geschäft").tag(String?.none)
                        ForEach(mockGeschaefte, id: \.self) { Text($0).tag($0 as String?) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cart.fill")
                        Text(geschaeft ?? "Geschäft")
                    }
                }
            }
        }
    }
}

// MARK: - Layout 10: Seitenleiste

/// Ein Burger-Knopf öffnet ein Seitenblatt zur Geschäftsauswahl.
private struct EinkaufenLayout10Seitenleiste: View {
    @State private var geschaeft: String?
    @State private var liste = mockListen[0]
    @State private var seitenleisteSichtbar = false

    var body: some View {
        ZStack(alignment: .leading) {
            EinkaufslistePlatzhalter(geschaeft: geschaeft, liste: liste)

            if seitenleisteSichtbar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) { seitenleisteSichtbar = false }
                    }
                    .zIndex(1)

                seitenleistenPanel.zIndex(2)
            }
        }
        .animation(.spring(response: 0.3), value: seitenleisteSichtbar)
        .navigationTitle(liste)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.spring(response: 0.3)) { seitenleisteSichtbar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Liste", selection: $liste) {
                        ForEach(mockListen, id: \.self) { Text($0).tag($0) }
                    }
                } label: { Image(systemName: "checklist") }
            }
        }
    }

    private var seitenleistenPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Geschäft wählen").font(.headline).padding()
            Divider()

            Button {
                withAnimation { geschaeft = nil; seitenleisteSichtbar = false }
            } label: {
                HStack {
                    Image(systemName: "xmark.circle").frame(width: 24).foregroundStyle(.secondary)
                    Text("Kein Geschäft").foregroundStyle(.secondary)
                    Spacer()
                    if geschaeft == nil {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .padding().contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(mockGeschaefte, id: \.self) { g in
                Divider().padding(.leading, 56)
                Button {
                    withAnimation { geschaeft = g; seitenleisteSichtbar = false }
                } label: {
                    HStack {
                        Image(systemName: "cart.fill")
                            .foregroundStyle(Color.accentColor).frame(width: 24)
                        Text(g).foregroundStyle(Color.primary)
                        Spacer()
                        if geschaeft == g {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding().contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(width: 260)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .transition(.move(edge: .leading))
    }
}

// MARK: - Preview

#Preview("EinkaufenView – Layout-Varianten") {
    NavigationStack {
        List {
            Section("Toolbar") {
                NavigationLink("1 – Toolbar (Referenz, aktuelles Design)") { EinkaufenLayout01Toolbar() }
                NavigationLink("7 – Großer Titel + Geschäft-Badge")        { EinkaufenLayout07GrosserTitel() }
                NavigationLink("9 – Segmented-Control für Listenwahl")     { EinkaufenLayout09SegmentListen() }
            }
            Section("Header-Streifen") {
                NavigationLink("3 – Inline-Header")       { EinkaufenLayout03InlineHeader() }
                NavigationLink("4 – Aufklappbare Leiste") { EinkaufenLayout04AufklappLeiste() }
                NavigationLink("8 – Zweizeilen-Header")   { EinkaufenLayout08ZweiZeilen() }
            }
            Section("Bottom & Floating") {
                NavigationLink("2 – Bottom-Bar")       { EinkaufenLayout02BottomBar() }
                NavigationLink("6 – Schwebende Pille") { EinkaufenLayout06SchwebendePille() }
            }
            Section("Navigation") {
                NavigationLink("5 – Geschäft zuerst") { EinkaufenLayout05GeschaeftZuerst() }
                NavigationLink("10 – Seitenleiste")   { EinkaufenLayout10Seitenleiste() }
            }
        }
        .navigationTitle("Layout-Varianten")
    }
}
