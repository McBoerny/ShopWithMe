import SwiftUI
import SwiftData

/// Umschließt einen Bearbeitungs-Bildschirm mit kontinuierlicher Live-Bindung
/// (`@Bindable`) mit einem Session-Lease (siehe `docs/DATABASE_CONCURRENCY.md` →
/// „Zweite Lease-Strategie“): erwirbt den Lease beim Erscheinen, gibt ihn samt
/// explizitem Save beim Verschwinden wieder frei.
///
/// Ist der Lease bereits durch ein anderes Gerät belegt, wird der Inhalt
/// schreibgeschützt (deaktiviert) mit einem Hinweis-Banner angezeigt — der Nutzer
/// kann die Daten weiterhin ansehen, aber nicht bearbeiten.
struct SessionLeaseGate<Content: View>: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var lease = DatabaseLeaseService.SessionLease()
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if case .belegt(let geraet, let seit) = lease.status {
                Label(
                    "In Bearbeitung von \(geraet) seit \(seit.formatted(date: .omitted, time: .shortened))",
                    systemImage: "lock.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.15))
            }
            content()
                .disabled(lease.status != .gehalten)
        }
        .task {
            await lease.acquire()
        }
        .onDisappear {
            Task {
                await lease.release(context: modelContext)
            }
        }
    }
}
