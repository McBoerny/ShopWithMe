import SwiftUI

/// Frei zoom- und schwenkbare Vollbild-Ansicht eines Fotos (Pinch-to-Zoom + Ziehen,
/// Doppel-Tap setzt Zoom/Position zurück) — optional mit einem hervorgehobenen
/// Rechteck (``markierung``, Visions normalisiertes Koordinatensystem: Ursprung
/// unten links, 0–1). Genutzt vom Belegscan, um das Originalfoto zu einer erkannten
/// Position zu zeigen (siehe `docs/BELEGSCAN.md`) — bewusst ohne automatisches
/// Heran-Zoomen zur Markierung, der Anwender zoomt bei Bedarf selbst.
struct ZoombareBildAnsicht: View {
    let bild: UIImage
    var markierung: CGRect?

    @Environment(\.dismiss) private var dismiss
    @GestureState private var laufenderZoom: CGFloat = 1
    @GestureState private var laufenderVersatz: CGSize = .zero
    @State private var aktuellerZoom: CGFloat = 1
    @State private var versatz: CGSize = .zero

    private let minimalerZoom: CGFloat = 1
    private let maximalerZoom: CGFloat = 5

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                Image(uiImage: bild)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        if let markierung {
                            MarkierungsRechteck(markierung: markierung, bildGroesse: bild.size, containerGroesse: geo.size)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(aktuellerZoom * laufenderZoom)
                    .offset(x: versatz.width + laufenderVersatz.width, y: versatz.height + laufenderVersatz.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(magnificationGesture)
                    .simultaneousGesture(dragGesture)
                    .onTapGesture(count: 2) { zoomZuruecksetzen() }
            }
            .background(Color.black)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                        .tint(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($laufenderZoom) { wert, zustand, _ in
                zustand = wert
            }
            .onEnded { wert in
                aktuellerZoom = min(max(aktuellerZoom * wert, minimalerZoom), maximalerZoom)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($laufenderVersatz) { wert, zustand, _ in
                zustand = wert.translation
            }
            .onEnded { wert in
                versatz.width += wert.translation.width
                versatz.height += wert.translation.height
            }
    }

    private func zoomZuruecksetzen() {
        withAnimation {
            aktuellerZoom = 1
            versatz = .zero
        }
    }
}

/// Zeichnet ``markierung`` über der erkannten Bildzeile — konvertiert Visions
/// normalisierte Koordinaten (Ursprung unten links) in SwiftUI-Koordinaten unter
/// Berücksichtigung des Aspect-Fit-Scalings von `bildGroesse` in `containerGroesse`.
private struct MarkierungsRechteck: View {
    let markierung: CGRect
    let bildGroesse: CGSize
    let containerGroesse: CGSize

    var body: some View {
        let rechteck = umgerechnetesRechteck
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 3)
            .frame(width: rechteck.width, height: rechteck.height)
            .position(x: rechteck.midX, y: rechteck.midY)
    }

    private var umgerechnetesRechteck: CGRect {
        guard bildGroesse.width > 0, bildGroesse.height > 0,
              containerGroesse.width > 0, containerGroesse.height > 0
        else { return .zero }

        let bildSeitenverhaeltnis = bildGroesse.width / bildGroesse.height
        let containerSeitenverhaeltnis = containerGroesse.width / containerGroesse.height

        let angezeigteGroesse: CGSize
        if bildSeitenverhaeltnis > containerSeitenverhaeltnis {
            let breite = containerGroesse.width
            angezeigteGroesse = CGSize(width: breite, height: breite / bildSeitenverhaeltnis)
        } else {
            let hoehe = containerGroesse.height
            angezeigteGroesse = CGSize(width: hoehe * bildSeitenverhaeltnis, height: hoehe)
        }
        let xOffset = (containerGroesse.width - angezeigteGroesse.width) / 2
        let yOffset = (containerGroesse.height - angezeigteGroesse.height) / 2

        // Vision: Ursprung unten links, y wächst nach oben — SwiftUI: Ursprung oben
        // links, y wächst nach unten → y muss gespiegelt werden.
        let x = xOffset + markierung.minX * angezeigteGroesse.width
        let y = yOffset + (1 - markierung.maxY) * angezeigteGroesse.height
        let breite = markierung.width * angezeigteGroesse.width
        let hoehe = markierung.height * angezeigteGroesse.height
        return CGRect(x: x, y: y, width: breite, height: hoehe)
    }
}

#Preview {
    ZoombareBildAnsicht(
        bild: UIImage(systemName: "doc.text.viewfinder") ?? UIImage(),
        markierung: CGRect(x: 0.2, y: 0.6, width: 0.5, height: 0.08)
    )
}
