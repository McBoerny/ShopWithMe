import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen/Entfernen einer ``Abteilung`` in einem ``Geschaeft``,
/// aufrufbar aus ``GeschaeftAbteilungenSektion``.
///
/// Zeigt bewusst ALLE Abteilungen an, nicht nur die noch nicht verfügbaren
/// (GitHub #174 — vorher verschwand eine Abteilung sofort aus der Liste,
/// sobald sie verfügbar war, was Nutzer verwirrte, weil unklar blieb, ob sie
/// bereits zugeordnet ist). Bereits verfügbare Abteilungen (direkt zugeordnet
/// oder automatisch über den Geschäftstyp, siehe
/// ``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)``) erscheinen
/// angehakt; ein erneuter Tap entfernt sie wieder — direkt zugeordnete über
/// ``Geschaeft/abteilungen``, automatisch über den Geschäftstyp verfügbare
/// über ``Geschaeft/ausgeschlosseneAbteilungen`` (GitHub #43), analog den
/// Wisch-Aktionen „Entfernen"/„Ausschließen" in ``GeschaeftAbteilungenSektion``.
///
/// Nutzt die generische ``AuswahlSheet`` (GitHub #130) im
/// Mehrfachauswahl-Modus, deren Haken-Anzeige direkt dem tatsächlichen
/// Verfügbarkeits-Zustand entspricht (``verfuegbareIDs``, initial über
/// `.onAppear` in ``ausgewaehlt`` gespiegelt). Die eigentliche
/// Modellmutation passiert bewusst NICHT direkt im Binding-Setter, sondern
/// verzögert über ``onChange(of:)`` — eine SwiftData-Modellmutation synchron
/// aus dem Setter eines `Binding` heraus (der noch während des
/// Auswahl-Antippens von ``AuswahlSheet`` läuft) hat dort zu einem
/// Auf-und-Zu-Flackern des ganzen Sheets geführt (Live-Fund, vermutlich
/// re-entrante Zustandsänderung mitten in der SwiftUI-Transaktion).
struct AbteilungHinzufuegenSheet: View {
    let geschaeft: Geschaeft

    @Query(sort: \Abteilung.sortIndex) private var alleAbteilungen: [Abteilung]
    @State private var ausgewaehlt: Set<Abteilung.ID> = []

    /// IDs der aktuell in diesem Geschäft verfügbaren Abteilungen — direkt
    /// zugeordnet oder automatisch über den Geschäftstyp (siehe
    /// ``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)``). Immer frisch aus
    /// dem Modell berechnet statt zwischengespeichert, damit ``onChange(of:)``
    /// verlässlich den tatsächlichen Vorher-Zustand kennt — auch wenn die
    /// Zuordnung (z.B. beim Anlegen einer neuen Abteilung) bereits vor der
    /// Aktualisierung von ``ausgewaehlt`` erfolgt ist.
    private var verfuegbareIDs: Set<Abteilung.ID> {
        Set(geschaeft.verfuegbareAbteilungen(alleAbteilungen: alleAbteilungen).map(\.id))
    }

    var body: some View {
        SessionLeaseGate { auswahlSheet }
    }

    private var auswahlSheet: some View {
        AuswahlSheet(
            titel: "Abteilung hinzufügen",
            items: alleAbteilungen,
            name: \.name,
            modus: .mehrfach($ausgewaehlt),
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
        .onAppear { ausgewaehlt = verfuegbareIDs }
        .onChange(of: ausgewaehlt) { _, neu in
            let alt = verfuegbareIDs
            for id in neu.subtracting(alt) {
                if let abteilung = alleAbteilungen.first(where: { $0.id == id }) {
                    abteilungHinzufuegen(abteilung)
                }
            }
            for id in alt.subtracting(neu) {
                if let abteilung = alleAbteilungen.first(where: { $0.id == id }) {
                    abteilungEntfernen(abteilung)
                }
            }
            // Nach der Mutation mit dem tatsächlichen Modellzustand
            // abgleichen statt blind zu vertrauen — z.B. landet eine über
            // „Neue Abteilung anlegen" hinzugefügte Abteilung bereits vor
            // diesem Aufruf in `geschaeft.abteilungen` (siehe
            // `neuAnlegenInhalt` oben), sodass hier nichts mehr zu tun ist.
            let aktuell = verfuegbareIDs
            if neu != aktuell { ausgewaehlt = aktuell }
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

    /// Entfernt eine bereits verfügbare Abteilung wieder — bei direkt
    /// zugeordneten aus ``Geschaeft/abteilungen``, bei nur automatisch über
    /// den Geschäftstyp verfügbaren über einen individuellen Ausschluss
    /// (GitHub #43), analog den Wisch-Aktionen in
    /// ``GeschaeftAbteilungenSektion``.
    private func abteilungEntfernen(_ abteilung: Abteilung) {
        if geschaeft.abteilungen.contains(abteilung) {
            geschaeft.abteilungen.removeAll { $0 == abteilung }
        } else if !geschaeft.ausgeschlosseneAbteilungen.contains(abteilung) {
            geschaeft.ausgeschlosseneAbteilungen.append(abteilung)
        }
    }
}

#Preview {
    AbteilungHinzufuegenSheet(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, Abteilung.self], inMemory: true)
}
