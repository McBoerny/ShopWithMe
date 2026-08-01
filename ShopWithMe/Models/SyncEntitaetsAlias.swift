import Foundation
import SwiftData

/// Merkt sich, dass eine von einem Peer empfangene Entitäts-`UUID` (z.B. eines
/// ``Artikel``) einer ANDEREN, bereits lokal existierenden `UUID` entspricht —
/// nötig, weil Bereich-B-Matching (`SyncSnapshotImportService`, Phase 3) für
/// manche Modelltypen bewusst über Namens-/Koordinatenabgleich statt über die
/// ID läuft (zwei unabhängig angelegte "Milch"-Artikel sollen zu einem
/// verschmelzen, siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2).
///
/// Ohne diese Tabelle würden künftige Bereich-A-``SyncEvent``s desselben Peers
/// (die weiterhin dessen ursprüngliche `artikelID` referenzieren) beim
/// ``SyncImportService`` dauerhaft ins Leere laufen, weil unter dieser ID
/// lokal kein Objekt mehr existiert (es wurde ja mit einem namensgleichen
/// lokalen Objekt zusammengeführt statt selbst angelegt zu werden).
///
/// Bewusst generisch über `entitaetsArt` gehalten (nicht ein eigener Typ pro
/// Modell) — befüllt für jeden namensbasiert gematchten Bereich-B-Typ
/// (``ArtikelKategorie``, ``Geschaeft``, ``Artikel``, ``Einkaufsliste``,
/// ``Einkaufsvorgang``, siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2),
/// nicht nur für ``Artikel``.
@Model
final class SyncEntitaetsAlias {
    var id: UUID
    var entitaetsArt: String
    var fremdeID: UUID
    var lokaleID: UUID

    init(entitaetsArt: String, fremdeID: UUID, lokaleID: UUID) {
        self.id = UUID()
        self.entitaetsArt = entitaetsArt
        self.fremdeID = fremdeID
        self.lokaleID = lokaleID
    }
}

enum SyncEntitaetsArt {
    static let artikel = "Artikel"
    static let einkaufsliste = "Einkaufsliste"
    static let geschaeft = "Geschaeft"
    static let einkaufsvorgang = "Einkaufsvorgang"
    static let artikelKategorie = "ArtikelKategorie"
    static let geschaeftTyp = "GeschaeftTyp"
    static let kaufEintrag = "KaufEintrag"
    static let preispunkt = "Preispunkt"
}

enum SyncEntitaetsAliasService {
    /// Löst `fremdeID` auf die lokale ID auf, falls ein Alias existiert — sonst
    /// `fremdeID` selbst (kein Alias nötig, ID stimmt direkt überein).
    static func aufgeloesteID(fuer fremdeID: UUID, art: String, context: ModelContext) -> UUID {
        var deskriptor = FetchDescriptor<SyncEntitaetsAlias>(
            predicate: #Predicate { $0.entitaetsArt == art && $0.fremdeID == fremdeID }
        )
        deskriptor.fetchLimit = 1
        return (try? context.fetch(deskriptor).first?.lokaleID) ?? fremdeID
    }

    /// Alle lokal bekannten Aliase, gruppiert nach `entitaetsArt` und je Art als
    /// Fremd-ID→Lokale-ID-Dictionary — lädt die komplette Alias-Tabelle EINMAL,
    /// statt für jede Auflösung einzeln zu fetchen (Muster wie
    /// ``SyncTombstoneService/geloeschteIDs(art:context:)``, hier über alle
    /// Arten gleichzeitig, weil z.B. `mergeTombstones` `entitaetsArt` pro
    /// Eintrag wechselt). Für wiederholte Auflösungen innerhalb eines
    /// Merge-Durchlaufs mit ``aufgeloesteID(fuer:art:in:)`` zu verwenden.
    static func alleAliaseNachArt(context: ModelContext) -> [String: [UUID: UUID]] {
        let alle = (try? context.fetch(FetchDescriptor<SyncEntitaetsAlias>())) ?? []
        return Dictionary(grouping: alle, by: \.entitaetsArt)
            .mapValues { eintraege in
                Dictionary(eintraege.map { ($0.fremdeID, $0.lokaleID) }, uniquingKeysWith: { erster, _ in erster })
            }
    }

    /// Wie ``aufgeloesteID(fuer:art:context:)``, aber gegen eine vorab per
    /// ``alleAliaseNachArt(context:)`` geladene Map statt eines einzelnen
    /// Fetches — für Merge-Schleifen, die dieselbe Art wiederholt auflösen.
    static func aufgeloesteID(fuer fremdeID: UUID, art: String, in aliase: [String: [UUID: UUID]]) -> UUID {
        aliase[art]?[fremdeID] ?? fremdeID
    }

    /// Registriert, dass `fremdeID` künftig als `lokaleID` aufzulösen ist — ohne
    /// Wirkung, falls beide identisch sind (kein Alias nötig) oder bereits ein
    /// Alias für `fremdeID` existiert.
    static func registriere(entitaetsArt art: String, fremdeID: UUID, lokaleID: UUID, context: ModelContext) {
        guard fremdeID != lokaleID else { return }
        guard aufgeloesteID(fuer: fremdeID, art: art, context: context) == fremdeID else { return }
        context.insert(SyncEntitaetsAlias(entitaetsArt: art, fremdeID: fremdeID, lokaleID: lokaleID))
    }
}
