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
/// Modell) — aktuell nur für ``Artikel`` befüllt (der einzige Bereich-B-Typ,
/// der sowohl namensbasiert gematcht wird als auch von Bereich-A-Events
/// referenziert wird), aber ohne Mehraufwand auf weitere Typen erweiterbar,
/// falls das künftig nötig wird.
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

    /// Registriert, dass `fremdeID` künftig als `lokaleID` aufzulösen ist — ohne
    /// Wirkung, falls beide identisch sind (kein Alias nötig) oder bereits ein
    /// Alias für `fremdeID` existiert.
    static func registriere(entitaetsArt art: String, fremdeID: UUID, lokaleID: UUID, context: ModelContext) {
        guard fremdeID != lokaleID else { return }
        guard aufgeloesteID(fuer: fremdeID, art: art, context: context) == fremdeID else { return }
        context.insert(SyncEntitaetsAlias(entitaetsArt: art, fremdeID: fremdeID, lokaleID: lokaleID))
    }
}
