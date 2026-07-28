import SwiftUI
import VisionKit

/// UIKit-Brücke für die dokumentenoptimierte Kamera-Aufnahme (VisionKit,
/// `VNDocumentCameraViewController`) — dieselbe Technologie wie der
/// System-Dokumentenscanner in Notizen/Dateien. Erkennt automatisch die Kanten des
/// fotografierten Dokuments, korrigiert die Perspektive und optimiert Kontrast/
/// Belichtung, bevor das Bild an die Texterkennung geht — deutlich zuverlässiger
/// als ein rohes Kamerafoto (`UIImagePickerController`) bei schräg gehaltenen,
/// verknitterten oder schlecht beleuchteten Kassenbons.
///
/// Liefert nur die erste gescannte Seite — Kassenbons sind einseitig, ein
/// Mehrseiten-Scan ist hier nicht vorgesehen. Vor der Verwendung
/// ``VNDocumentCameraViewController/isSupported`` prüfen (im Simulator ohne
/// Kamera z.B. `false`, analog zur bisherigen
/// `UIImagePickerController.isSourceTypeAvailable(.camera)`-Prüfung).
struct DokumentScanView: UIViewControllerRepresentable {
    let onBild: (UIImage) -> Void
    let onAbbruch: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onBild: onBild, onAbbruch: onAbbruch)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onBild: (UIImage) -> Void
        let onAbbruch: () -> Void

        init(onBild: @escaping (UIImage) -> Void, onAbbruch: @escaping () -> Void) {
            self.onBild = onBild
            self.onAbbruch = onAbbruch
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                onAbbruch()
                return
            }
            onBild(scan.imageOfPage(at: 0))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onAbbruch()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onAbbruch()
        }
    }
}
