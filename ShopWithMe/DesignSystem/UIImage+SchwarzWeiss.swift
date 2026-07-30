import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Schwarz/Weiß-Konvertierung für Kassenbon-Scans (GitHub #61) — Graustufen mit
/// leicht angehobenem Kontrast liefert bei Vision-Texterkennung zuverlässiger
/// lesbare Ergebnisse als das rohe Farbfoto, unabhängig davon ob der Scan über
/// ``DokumentScanView`` (Kamera) oder die Fotobibliothek reinkam —
/// `VNDocumentCameraViewController` bietet dafür keine eigene, öffentliche
/// Filter-Option (im Unterschied zur privaten Scan-Implementierung der Notizen-App).
extension UIImage {
    /// Einmalig angelegter `CIContext` — Neuanlage pro Aufruf wäre unnötig teuer.
    private static let filterKontext = CIContext()

    /// Liefert eine Graustufen-/Hochkontrast-Version dieses Bilds, oder `self`
    /// unverändert, falls die Filterung aus irgendeinem Grund fehlschlägt.
    func schwarzWeissGefiltert() -> UIImage {
        guard let ciImage = CIImage(image: self) else { return self }

        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.saturation = 0
        filter.contrast = 1.1

        guard let ausgabe = filter.outputImage,
              let cgImage = Self.filterKontext.createCGImage(ausgabe, from: ciImage.extent)
        else { return self }

        return UIImage(cgImage: cgImage, scale: scale, orientation: imageOrientation)
    }
}
