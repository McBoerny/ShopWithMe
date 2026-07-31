import Foundation
import SwiftData

/// Gelernte Zuordnung eines auf einem Kassenbon/Preisschild erkannten
/// Rohnamens zu einem Anzeige-Alias und/oder einem bestehenden ``Artikel`` —
/// ersetzt die frühere Suche über die komplette ``KaufEintrag``-Historie
/// (vormals `KaufEintrag.gelernteZuordnung`, siehe ``ArtikelZuordnungsService``,
/// GitHub #76). Pro ``erkannterName`` genau ein Eintrag (Upsert bei erneuter
/// Bestätigung desselben Rohnamens, ``lernen(erkannterName:alternativerName:artikel:context:)``),
/// daher ein O(1)-Nachschlagen statt einer linearen Suche über die wachsende
/// Kaufhistorie.
@Model
final class ArtikelAlias {
    /// Eindeutige Kennung.
    var id: UUID
    /// Vom Kassenbon/Preisschild erkannter Rohname — Vergleichsschlüssel.
    var erkannterName: String
    /// Vom Nutzer vergebener Anzeigename, `nil` falls nur eine Artikel-
    /// Zuordnung ohne eigenen Alias gelernt wurde.
    var alternativerName: String?
    /// Der übergreifende Artikel, dem `erkannterName` zugeordnet wurde.
    var artikel: Artikel?

    init(erkannterName: String, alternativerName: String?, artikel: Artikel?) {
        self.id = UUID()
        self.erkannterName = erkannterName
        self.alternativerName = alternativerName
        self.artikel = artikel
    }
}

extension ArtikelAlias {
    /// Legt für `erkannterName` einen neuen ``ArtikelAlias`` an oder
    /// aktualisiert den bestehenden (exakter, case-insensitiver Abgleich) —
    /// wird sowohl bei jeder manuellen Zuordnung (`PreispunktZuordnenSheet`)
    /// als auch beim automatischen Umbenennen während des Belegscans
    /// aufgerufen. Ohne Wirkung, wenn weder `alternativerName` noch `artikel`
    /// gesetzt ist (kein Lernsignal).
    static func lernen(
        erkannterName: String, alternativerName: String?, artikel: Artikel?, context: ModelContext
    ) {
        let name = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, alternativerName != nil || artikel != nil else { return }
        let bestehender = ((try? context.fetch(FetchDescriptor<ArtikelAlias>())) ?? [])
            .first { $0.erkannterName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        if let bestehender {
            bestehender.alternativerName = alternativerName
            bestehender.artikel = artikel
        } else {
            context.insert(ArtikelAlias(erkannterName: name, alternativerName: alternativerName, artikel: artikel))
        }
    }

    /// Sucht in `alle` zunächst einen exakten (case-insensitiven) Treffer für
    /// `erkannterName`, sonst einen beidseitigen Teilstring-Abgleich (analog
    /// der früheren `KaufEintrag.gelernteZuordnung`-Fuzzy-Logik) — Stufe 1 von
    /// ``ArtikelZuordnungsService``.
    static func passend(fuerErkannterName erkannterName: String, in alle: [ArtikelAlias]) -> (alias: String?, artikel: Artikel?)? {
        let name = erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let exakt = alle.first(where: { $0.erkannterName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return (exakt.alternativerName, exakt.artikel)
        }
        guard let treffer = alle.first(where: {
            $0.erkannterName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.erkannterName)
        }) else { return nil }
        return (treffer.alternativerName, treffer.artikel)
    }
}
