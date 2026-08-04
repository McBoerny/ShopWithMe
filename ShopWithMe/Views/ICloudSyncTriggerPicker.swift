import SwiftUI
import UIKit

/// Kurzes, automatisch wieder ausgeblendetes Einblenden eines
/// `UIDocumentPickerViewController` auf den Sync-Ordner (GitHub #92,
/// **experimentell, unbelegt**). Testidee: das Öffnen des Sync-Ordners in
/// der Files-App löst nachweislich einen iCloud-Abgleich aus
/// (`docs/DATENSYNCHRONISATION_VERLAUF.md` §39/42) — ein Picker nutzt
/// dieselbe File-Provider-Enumeration wie die Files-App. Weder Apple-Doku
/// noch Entwicklerforen bestätigen oder widerlegen den Effekt (siehe
/// Recherche-Kommentar an Issue #92) — ob das überhaupt etwas bewirkt, muss
/// der Live-Test zeigen.
///
/// Bewusst nur hinter einer expliziten Nutzeraktion (manueller
/// "Jetzt synchronisieren"-Button in ``SyncOrdnerSettingsView``, Pull-to-
/// Refresh in der Einkaufsliste), nie im automatischen Hintergrund-Poll: ein
/// Sheet, das ohne Nutzerinteraktion von selbst wieder verschwindet, ist nur
/// als Reaktion auf eine explizite Nutzeraktion vertretbar (Accessibility-/
/// App-Review-Risiko sonst).
struct ICloudSyncTriggerPicker: UIViewControllerRepresentable {
    let ordner: URL
    @Binding var isPresented: Bool

    /// Wie lange der Picker sichtbar bleibt, bevor er sich selbst wieder
    /// schließt — kurz genug, um als "Flash" statt als echte UI wahrgenommen
    /// zu werden, aber lang genug, um dem System eine Chance zu geben, die
    /// Ordner-Enumeration tatsächlich anzustoßen.
    private static let automatischSchliessenNach: TimeInterval = 0.4

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = ordner
        picker.delegate = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.automatischSchliessenNach) {
            isPresented = false
        }
        SyncDebugLogger.log(.iCloudPickerTriggerAusgeloest, details: "")
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    /// Reagiert nur auf den unwahrscheinlichen Fall, dass der Picker vor dem
    /// automatischen Schließen doch noch eine Nutzerinteraktion bekommt
    /// (Abbrechen-Tap) — schließt dann sofort statt auf den Timer zu warten.
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        @Binding var isPresented: Bool

        init(isPresented: Binding<Bool>) {
            self._isPresented = isPresented
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            isPresented = false
        }
    }
}
