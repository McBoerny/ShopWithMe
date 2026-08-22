import SwiftUI
import SwiftData

/// Sheet zum Hinzufügen einer ``ArtikelKategorie`` zu einem ``Geschaeft``, aufrufbar
/// aus ``GeschaeftAbteilungenSektion``.
///
/// Eine Kategorie wird beim Antippen direkt diesem Geschäft zugeordnet
/// (``Geschaeft/kategorien``) und damit sofort verfügbar — nutzt die generische
/// ``AuswahlSheet`` (GitHub #130) im Mehrfachauswahl-Modus. Die eigentliche
/// Zuordnung passiert bewusst NICHT direkt im Binding-Setter, sondern
/// verzögert über ``onChange(of:)`` (``geradeAusgewaehlt``) — eine
/// SwiftData-Modellmutation synchron aus dem Setter eines `Binding` heraus
/// (der noch während des Auswahl-Antippens von ``AuswahlSheet`` läuft) hat
/// dort zu einem Auf-und-Zu-Flackern des ganzen Sheets geführt (Live-Fund,
/// vermutlich re-entrante Zustandsänderung mitten in der SwiftUI-Transaktion).
/// Danach wird die Auswahlmenge sofort zurückgesetzt: der Eintrag verschwindet
/// aus der Liste (``nichtVerfuegbareKategorien``), ein dauerhafter Haken wäre
/// irreführend.
struct AbteilungHinzufuegenSheet: View {
    let geschaeft: Geschaeft

    @Query(sort: \ArtikelKategorie.sortIndex) private var alleKategorien: [ArtikelKategorie]
    @State private var geradeAusgewaehlt: Set<ArtikelKategorie.ID> = []

    /// Kategorien, die in diesem Geschäft noch nicht verfügbar sind — Kategorien,
    /// die bereits über den Geschäftstyp automatisch verfügbar sind (siehe
    /// ``Geschaeft/verfuegbareKategorien(alleKategorien:)``), werden hier nicht
    /// nochmal zum manuellen Hinzufügen angeboten.
    private var nichtVerfuegbareKategorien: [ArtikelKategorie] {
        let verfuegbareIDs = Set(geschaeft.verfuegbareKategorien(alleKategorien: alleKategorien).map(\.persistentModelID))
        return alleKategorien.filter { !verfuegbareIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        SessionLeaseGate { auswahlSheet }
    }

    private var auswahlSheet: some View {
        AuswahlSheet(
            titel: "Abteilung hinzufügen",
            items: nichtVerfuegbareKategorien,
            name: \.name,
            modus: .mehrfach($geradeAusgewaehlt),
            suchPrompt: "Abteilung suchen",
            symbol: \.standardSymbol,
            neuAnlegenTitel: { _ in "Neue Abteilung anlegen" },
            neuAnlegenNurBeiFehlendemTreffer: false,
            neuAnlegenInhalt: { _, gesichert in
                NeueAbteilungSheet(naechsterSortIndex: (alleKategorien.map(\.sortIndex).max() ?? -1) + 1) { kategorie in
                    kategorieHinzufuegen(kategorie)
                    gesichert(kategorie)
                }
            }
        )
        .onChange(of: geradeAusgewaehlt) { _, neu in
            guard !neu.isEmpty else { return }
            for id in neu {
                if let kategorie = nichtVerfuegbareKategorien.first(where: { $0.id == id }) {
                    kategorieHinzufuegen(kategorie)
                }
            }
            geradeAusgewaehlt = []
        }
    }

    private func kategorieHinzufuegen(_ kategorie: ArtikelKategorie) {
        geschaeft.kategorien.append(kategorie)
        // Falls die Kategorie zuvor als automatisch-über-Geschäftstyp
        // ausgeschlossen war (GitHub #43): Ausschluss aufräumen, da sie jetzt
        // ohnehin direkt zugeordnet ist — sonst bliebe ein wirkungsloser,
        // verwaister Eintrag in `ausgeschlosseneKategorien` stehen.
        geschaeft.ausgeschlosseneKategorien.removeAll { $0 == kategorie }
    }
}

#Preview {
    AbteilungHinzufuegenSheet(geschaeft: Geschaeft(name: "Rewe", typen: [GeschaeftTyp(name: "Lebensmittel", symbolName: "cart.fill")]))
        .modelContainer(for: [Geschaeft.self, GeschaeftTyp.self, ArtikelKategorie.self], inMemory: true)
}
