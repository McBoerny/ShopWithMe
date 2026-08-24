import SwiftUI
import SwiftData

/// Detailansicht eines ``Geschaeft``s: Stammdaten, Abteilungen-Verwaltung
/// (``GeschaeftAbteilungenSektion``) sowie Kaufbeleg- und Preisschild-Scan.
///
/// „Kaufbeleg scannen“ öffnet ``BelegScanView`` im ``BelegScanKontext/geschaeft(_:)``-
/// Kontext — unabhängig von einem laufenden ``Einkaufsvorgang``, z.B. um Preise für
/// einen älteren oder nachträglich gefundenen Kassenbon zu erfassen.
///
/// „Preisschild scannen“ öffnet ``PreisschildScanView`` — erfasst den Preis eines
/// einzelnen fotografierten Regal-Preisschilds direkt als ``KaufEintrag`` mit
/// heutigem Datum, unabhängig davon, ob der Artikel tatsächlich gekauft wird (z.B.
/// zum Preisvergleich vor der Kaufentscheidung). Siehe `docs/PREISSCHILD_SCAN.md`.
///
/// „Preisübersicht“ ist ein eigener View (``GeschaeftPreisUebersichtView``,
/// GitHub #20) mit der Preisspanne pro Artikel sowie Positionen ohne
/// Artikel-Zuordnung — siehe `docs/BELEGSCAN.md`.
///
/// „Besuchsprotokoll“ (``GeschaeftBesuchsProtokollView``, GitHub #32) zeigt
/// Zeitpunkt und Dauer aller abgeschlossenen ``Einkaufsvorgang``e in diesem
/// Geschäft — ohne eigenes Datenmodell, direkt aus dessen `startZeit`/`endZeit`.
/// Navigationsziele der beiden letzten Zeilen in ``GeschaeftDetailView``, die auf
/// keinem konkreten Datenwert basieren — als eigenes `Hashable`-Werteziel für
/// `NavigationLink(value:)`/`.navigationDestination(for:)`, statt der älteren
/// closure-basierten `NavigationLink { destination } label: {}`-Variante. Letztere
/// konstruiert ihre Destination-View eager bei **jedem** Rendern von
/// `GeschaeftDetailView`, nicht erst beim tatsächlichen Antippen — bei
/// `GeschaeftPreisUebersichtView` (eigenes `@Query`) führte das zu einer
/// Endlosschleife mit dessen verschachtelten Destinations (GitHub #33).
private enum GeschaeftDetailNavigationsziel: Hashable {
    case preisuebersicht
    case besuchsprotokoll
}

struct GeschaeftDetailView: View {
    @Bindable var geschaeft: Geschaeft
    @Environment(\.modelContext) private var modelContext
    @State private var zeigeStammdatenEdit = false
    @State private var zeigeBelegScan = false
    @State private var zeigePreisschildScan = false

    init(geschaeft: Geschaeft) {
        self.geschaeft = geschaeft
    }

    var body: some View {
        SessionLeaseGate { listInhalt }
    }

    private var listInhalt: some View {
        List {
            Section {
                Button {
                    zeigeStammdatenEdit = true
                } label: {
                    HStack(spacing: 16) {
                        GlassSymbolBadge(symbolName: geschaeft.fuehrenderTyp?.symbolName ?? "shippingbox.fill", farbe: .accentColor, groesse: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(geschaeft.name)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text(geschaeft.typen.map(\.name).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                            if let adresse = geschaeft.adresse, !adresse.isEmpty {
                                Text(adresse)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            GeschaeftAbteilungenSektion(geschaeft: geschaeft)

            Section {
                Button {
                    zeigeBelegScan = true
                } label: {
                    Label("Kaufbeleg scannen", systemImage: "doc.text.viewfinder")
                }
                Button {
                    zeigePreisschildScan = true
                } label: {
                    Label("Preisschild scannen", systemImage: "text.viewfinder")
                }
            } footer: {
                Text("Erfasse Preise für dieses Geschäft direkt von einem Kassenbon, auch ohne laufenden Einkauf. „Preisschild scannen“ erfasst den Preis eines einzelnen Regal-Preisschilds, auch ohne Kauf — z.B. zum Preisvergleich.")
            }

            Section {
                NavigationLink(value: GeschaeftDetailNavigationsziel.preisuebersicht) {
                    Label("Preisübersicht", systemImage: "chart.line.uptrend.xyaxis")
                }
                NavigationLink(value: GeschaeftDetailNavigationsziel.besuchsprotokoll) {
                    Label("Besuchsprotokoll", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle(geschaeft.name.isEmpty ? "Geschäft" : geschaeft.name)
        .navigationDestination(for: GeschaeftDetailNavigationsziel.self) { ziel in
            switch ziel {
            case .preisuebersicht:
                GeschaeftPreisUebersichtView(geschaeft: geschaeft)
            case .besuchsprotokoll:
                GeschaeftBesuchsProtokollView(geschaeft: geschaeft)
            }
        }
        .sheet(isPresented: $zeigeStammdatenEdit) {
            GeschaeftStammdatenEditView(geschaeft: geschaeft, istNeu: false)
        }
        .sheet(isPresented: $zeigeBelegScan) {
            BelegScanView(geschaeft: geschaeft)
        }
        .sheet(isPresented: $zeigePreisschildScan) {
            PreisschildScanView(geschaeft: geschaeft)
        }
    }
}

#Preview {
    NavigationStack {
        GeschaeftDetailView(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
    }
    .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Abteilung.self], inMemory: true)
}
