import Foundation
import SwiftData

/// Einmalige, manuell auslösbare Diagnose für GitHub #102: bevor
/// `@Attribute(.unique) var id: UUID` auf einem `@Model`-Typ eingeführt wird,
/// muss der reale Bestand auf bereits vorhandene doppelte `id`-Werte geprüft
/// werden — eine Unique-Constraint-Migration würde bei bestehenden
/// Duplikaten fehlschlagen/abstürzen (siehe `docs/DECISIONS.md`,
/// Migrations-Kriterium additiv-optional vs. strukturell).
///
/// **Bewusst rein aggregierend:** das Ergebnis nennt nur Typname und Anzahl
/// betroffener IDs/überzähliger Zeilen, nie die IDs oder Inhalte selbst — für
/// die Entscheidung "ist `.unique` sicher einführbar" genügt das, ein
/// Rohdaten-Export (Artikel-/Geschäftsnamen, Kaufhistorie) ist dafür nicht
/// nötig und würde unnötig private Daten offenlegen.
///
/// **Test-Fund beim Rollout von `@Attribute(.unique)` (GitHub #102):**
/// entgegen der ursprünglichen Annahme eines harten Abbruchs führt SwiftData
/// bei einem Speicherversuch mit bereits vergebenem eindeutigen Wert
/// (zumindest im getesteten In-Memory-Store) einen stillen Upsert durch
/// (Warnung „was remapped to a temporary identifier during save" im
/// Konsolen-Log, kein geworfener Fehler) statt abzustürzen — zwei separat
/// angelegte Objekte mit derselben `id` kollabieren dadurch selbst beim
/// `context.save()` zu einer Zeile. Für die eigentliche Diagnose hier bleibt
/// das ohne Belang (sie prüft den bereits gespeicherten Bestand, nicht das
/// Speichern selbst), ändert aber die Risikoeinschätzung für die Migration:
/// vermutlich kein Absturz bei bestehenden Duplikaten, eher ein stiller
/// Datenverlust (eines der beiden „Duplikate" verschwindet unbemerkt) —
/// weshalb die Prüfung hier trotzdem vor jeder Einführung sinnvoll bleibt.
enum ModellIDDuplikatService {
    struct Befund: Identifiable {
        let id = UUID()
        let typName: String
        let anzahlBetroffeneIDs: Int
        let anzahlUeberzaehligeZeilen: Int

        var beschreibung: String {
            "\(typName): \(anzahlBetroffeneIDs) doppelt vergebene ID\(anzahlBetroffeneIDs == 1 ? "" : "n"), \(anzahlUeberzaehligeZeilen) überzählige Zeile\(anzahlUeberzaehligeZeilen == 1 ? "" : "n")"
        }
    }

    /// Prüft einen einzelnen `@Model`-Typ auf doppelt vergebene `id`-Werte.
    /// `nil`, falls keine Duplikate gefunden wurden.
    private static func pruefeTyp<T: PersistentModel>(_ typName: String, id: KeyPath<T, UUID>, context: ModelContext) -> Befund? {
        let alle = (try? context.fetch(FetchDescriptor<T>())) ?? []
        let anzahlProID = Dictionary(grouping: alle, by: { $0[keyPath: id] }).mapValues(\.count)
        let betroffene = anzahlProID.values.filter { $0 > 1 }
        guard !betroffene.isEmpty else { return nil }
        return Befund(
            typName: typName,
            anzahlBetroffeneIDs: betroffene.count,
            anzahlUeberzaehligeZeilen: betroffene.reduce(0) { $0 + $1 - 1 }
        )
    }

    /// Prüft alle ~22 `@Model`-Typen mit einer app-eigenen `id: UUID`
    /// (siehe GitHub #102 für die vollständige Liste der betroffenen
    /// Merge-/Lookup-Stellen). Leeres Ergebnis heißt: keine Duplikate
    /// gefunden, `@Attribute(.unique)` wäre auf diesem Gerätestand sicher.
    @MainActor
    static func pruefe(context: ModelContext) -> [Befund] {
        [
            pruefeTyp("Artikel", id: \Artikel.id, context: context),
            pruefeTyp("ArtikelAlias", id: \ArtikelAlias.id, context: context),
            pruefeTyp("ArtikelGeschaeftVerfuegbarkeit", id: \ArtikelGeschaeftVerfuegbarkeit.id, context: context),
            pruefeTyp("ArtikelKategorie", id: \ArtikelKategorie.id, context: context),
            pruefeTyp("ArtikelListenKauf", id: \ArtikelListenKauf.id, context: context),
            pruefeTyp("Einkaufsliste", id: \Einkaufsliste.id, context: context),
            pruefeTyp("EinkaufslistenEintrag", id: \EinkaufslistenEintrag.id, context: context),
            pruefeTyp("Einkaufsvorgang", id: \Einkaufsvorgang.id, context: context),
            pruefeTyp("Geschaeft", id: \Geschaeft.id, context: context),
            pruefeTyp("GeschaeftBesuch", id: \GeschaeftBesuch.id, context: context),
            pruefeTyp("GeschaeftTyp", id: \GeschaeftTyp.id, context: context),
            pruefeTyp("KaufEintrag", id: \KaufEintrag.id, context: context),
            pruefeTyp("Preispunkt", id: \Preispunkt.id, context: context),
            pruefeTyp("SyncAbgleichKandidat", id: \SyncAbgleichKandidat.id, context: context),
            pruefeTyp("SyncEntitaetsAlias", id: \SyncEntitaetsAlias.id, context: context),
            pruefeTyp("SyncEvent", id: \SyncEvent.id, context: context),
            pruefeTyp("SyncPeerInfo", id: \SyncPeerInfo.id, context: context),
            pruefeTyp("SyncPeerZaehlerStand", id: \SyncPeerZaehlerStand.id, context: context),
            pruefeTyp("SyncTombstone", id: \SyncTombstone.id, context: context),
            pruefeTyp("WarengruppenDistanz", id: \WarengruppenDistanz.id, context: context),
            pruefeTyp("WarengruppenDistanzPeerZaehlerStand", id: \WarengruppenDistanzPeerZaehlerStand.id, context: context),
        ].compactMap { $0 }
    }
}
