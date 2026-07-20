import UIKit
import SwiftUI

/// Prinzipalklasse der Share Extension (`NSExtensionPrincipalClass` in
/// `ShopWithMeShareExtension/Info.plist`). Liest den geteilten Inhalt (Text oder
/// Datei) über ``ShareExtensionView``, legt ihn für die Haupt-App über
/// ``MilkForUsPendingImportStore`` bereit und öffnet die Haupt-App über das
/// `shopwithme://milkforus-import`-URL-Schema — siehe `docs/MILKFORUS_IMPORT.md`.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let hosting = UIHostingController(
            rootView: ShareExtensionView(extensionItems: items) { [weak self] in
                self?.oeffneHauptAppUndSchliesse()
            }
        )
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    private func oeffneHauptAppUndSchliesse() {
        if let url = URL(string: "shopwithme://milkforus-import") {
            extensionContext?.open(url, completionHandler: nil)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
