import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen einer ``Abteilung`` zu einem ``Geschaeft``, aufrufbar
/// aus ``GeschaeftAbteilungenSektion``.
///
/// Eine Abteilung wird beim Antippen direkt diesem Geschäft zugeordnet
/// (``Geschaeft/abteilungen``) und damit sofort verfügbar — nutzt die generische
/// ``AuswahlSheet`` (GitHub #130) im Mehrfachauswahl-Modus. Die eigentliche
/// Zuordnung passiert bewusst NICHT direkt im Binding-Setter, sondern
/// verzögert über ``onChange(of:)`` (``geradeAusgewaehlt``) — eine
/// SwiftData-Modellmutation synchron aus dem Setter eines `Binding` heraus
/// (der noch während des Auswahl-Antippens von ``AuswahlSheet`` läuft) hat
/// dort zu einem Auf-und-Zu-Flackern des ganzen Sheets geführt (Live-Fund,
/// vermutlich re-entrante Zustandsänderung mitten in der SwiftUI-Transaktion).
/// Danach wird die Auswahlmenge sofort zurückgesetzt: der Eintrag verschwindet
/// aus der Liste (``nichtVerfuegbareAbteilungen``), ein dauerhafter Haken wäre
/// irreführend.
struct AbteilungHinzufuegenSheet: View {
    let geschaeft: Geschaeft

    @Query(sort: \Abteilung.sortIndex) private var alleAbteilungen: [Abteilung]
    @State private var geradeAusgewaehlt: Set<Abteilung.ID> = []

    /// Abteilungen, die in diesem Geschäft noch nicht verfügbar sind — Abteilungen,
    /// die bereits über den Geschäftstyp automatisch verfügbar sind (siehe
    /// ``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)``), werden hier nicht
    /// nochmal zum manuellen Hinzufügen angeboten.
    private var nichtVerfuegbareAbteilungen: [Abteilung] {
        let verfuegbareIDs = Set(geschaeft.verfuegbareAbteilungen(alleAbteilungen: alleAbteilungen).map(\.persistentModelID))
        return alleAbteilungen.filter { !verfuegbareIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        SessionLeaseGate { auswahlSheet }
    }

    private var auswahlSheet: some View {
        AuswahlSheet(
            titel: "Abteilung hinzufügen",
            items: nichtVerfuegbareAbteilungen,
            name: \.name,
            modus: .mehrfach($geradeAusgewaehlt),
            suchPrompt: "Abteilung suchen",
            symbol: \.standardSymbol,
            neuAnlegenTitel: { _ in "Neue Abteilung anlegen" },
            neuAnlegenNurBeiFehlendemTreffer: false,
            neuAnlegenInhalt: { _, gesichert in
                NeueAbteilungSheet(naechsterSortIndex: (alleAbteilungen.map(\.sortIndex).max() ?? -1) + 1) { abteilung in
                    abteilungHinzufuegen(abteilung)
                    gesichert(abteilung)
                }
            }
        )
        .onChange(of: geradeAusgewaehlt) { _, neu in
            guard !neu.isEmpty else { return }
            for id in neu {
                if let abteilung = nichtVerfuegbareAbteilungen.first(where: { $0.id == id }) {
                    abteilungHinzufuegen(abteilung)
                }
            }
            geradeAusgewaehlt = []
        }
    }

    private func abteilungHinzufuegen(_ abteilung: Abteilung) {
        geschaeft.abteilungen.append(abteilung)
        // Falls die Abteilung zuvor als automatisch-über-Geschäftstyp
        // ausgeschlossen war (GitHub #43): Ausschluss aufräumen, da sie jetzt
        // ohnehin direkt zugeordnet ist — sonst bliebe ein wirkungsloser,
        // verwaister Eintrag in `ausgeschlosseneAbteilungen` stehen.
        geschaeft.ausgeschlosseneAbteilungen.removeAll { $0 == abteilung }
    }
}

#Preview {
    AbteilungHinzufuegenSheet(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Abteilung.self], inMemory: true)
}
