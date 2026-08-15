import SwiftUI

/// Fließ-Layout für Chip-Darstellungen: ordnet Subviews zeilenweise an und
/// bricht automatisch um, wenn die verfügbare Breite erschöpft ist.
/// Wird von ``EinkaufslisteDarstellungsView`` für die Chip-Anzeigetypen genutzt.
struct ChipFlowLayout: Layout {
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
