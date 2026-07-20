import SwiftUI
import UniformTypeIdentifiers

/// UI der Share Extension: liest den geteilten Inhalt asynchron, legt ihn bei Erfolg
/// über ``MilkForUsPendingImportStore`` bereit und meldet mit ``fertig`` den
/// Abschluss an ``ShareViewController``. Bewusst minimal — die eigentliche
/// Vorschau/Verarbeitung passiert erst in der Haupt-App (``MilkForUsImportView``).
struct ShareExtensionView: View {
    let extensionItems: [NSExtensionItem]
    let fertig: () -> Void

    private enum Status: Equatable {
        case laedt
        case bereit
        case fehler(String)
    }

    @State private var status: Status = .laedt

    var body: some View {
        VStack(spacing: 16) {
            switch status {
            case .laedt:
                ProgressView("Wird gelesen…")
            case .bereit:
                Label("Bereit für ShopWithMe", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("Öffne ShopWithMe, um den Import abzuschließen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Fertig", action: fertig)
                    .buttonStyle(.borderedProminent)
            case .fehler(let meldung):
                Label("Konnte nicht gelesen werden", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(meldung)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Schließen", action: fertig)
            }
        }
        .padding()
        .task {
            await laden()
        }
    }

    private func laden() async {
        guard let text = await Self.geteilterText(aus: extensionItems) else {
            status = .fehler("In diesem geteilten Inhalt wurde kein lesbarer Text gefunden.")
            return
        }
        MilkForUsPendingImportStore.speichern(text)
        status = .bereit
    }

    /// Sucht in allen geteilten Elementen zuerst nach reinem Text, dann nach einer
    /// Datei-URL, deren Inhalt sich als Text lesen lässt.
    private static func geteilterText(aus items: [NSExtensionItem]) async -> String? {
        for item in items {
            for provider in item.attachments ?? [] {
                if let text = await text(from: provider, typeIdentifier: UTType.plainText.identifier) {
                    return text
                }
                if let text = await text(from: provider, typeIdentifier: UTType.text.identifier) {
                    return text
                }
                if let text = await text(from: provider, typeIdentifier: UTType.fileURL.identifier) {
                    return text
                }
            }
        }
        return nil
    }

    private static func text(from provider: NSItemProvider, typeIdentifier: String) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier),
              let item = try? await provider.loadItem(forTypeIdentifier: typeIdentifier)
        else { return nil }
        if let text = item as? String { return text }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let url = item as? URL { return try? String(contentsOf: url, encoding: .utf8) }
        return nil
    }
}
