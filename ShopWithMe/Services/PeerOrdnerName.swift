import Foundation

/// Ordnername für den eigenen Peer-Ordner unter `peers/` (GitHub #81): trägt
/// den vom Anwender vergebenen Gerätenamen, damit sich Peer-Ordner im
/// geteilten Sync-Ordner (Finder/Dateien-App) auf einen Blick einem Gerät
/// zuordnen lassen, statt nur eine rohe UUID zu zeigen. Ein kurzes, aus
/// `geraeteID` abgeleitetes Suffix ist IMMER Teil des Ordnernamens — nicht
/// nur bei tatsächlicher Namensgleichheit —, dadurch entfällt jede
/// Kollisionsprüfung: Eindeutigkeit kommt strukturell aus dem Suffix, der
/// Gerätename ist reine Lesehilfe.
///
/// **Wichtig:** Der Ordnername ist rein kosmetisch. Die alleinige interne
/// Peer-Identität bleibt `DatabaseLeaseService.geraeteID`
/// (`SyncEvent.autorGeraeteID`, `SyncPeerInfo.peerGeraeteID`,
/// `SyncPeerZaehlerStand.peerGeraeteID`) — nirgends darf ein aus diesem Typ
/// abgeleiteter Ordnername anstelle der echten `geraeteID` als Identität
/// verwendet werden (siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 2).
enum PeerOrdnerName {
    /// Sechs Hex-Zeichen aus `geraeteID` (Bindestriche entfernt) — kurz genug
    /// für einen lesbaren Ordnernamen, kollisionsarm genug für die
    /// realistische Anzahl Geräte eines Haushalts (1 : 16 Mio. je Gerätepaar).
    static func kurzeID(_ geraeteID: String) -> String {
        String(geraeteID.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    /// `geraeteName`, bereinigt um dateisystem-unsichere Zeichen: nur
    /// Buchstaben/Ziffern bleiben erhalten, alles andere wird zu `-`,
    /// mehrfache `-` werden zusammengefasst, führende/abschließende `-`
    /// entfernt, auf 40 Zeichen begrenzt. Ein danach leerer Name fällt auf
    /// "Geraet" zurück (z.B. bei einem rein aus Emoji bestehenden Namen).
    static func bereinigterName(_ geraeteName: String) -> String {
        var bereinigt = String(geraeteName.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while bereinigt.contains("--") {
            bereinigt = bereinigt.replacingOccurrences(of: "--", with: "-")
        }
        bereinigt = bereinigt.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if bereinigt.count > 40 {
            bereinigt = String(bereinigt.prefix(40))
        }
        return bereinigt.isEmpty ? "Geraet" : bereinigt
    }

    /// Ordnername dieses (oder eines beliebigen) Geräts unter `peers/`.
    static func name(geraeteID: String, geraeteName: String) -> String {
        "\(bereinigterName(geraeteName))_\(kurzeID(geraeteID))"
    }

    /// Ob ein tatsächlicher Unterordnername unter `peers/` zu `geraeteID`
    /// gehört — erkennt sowohl das neue Schema (`{Name}_{kurzeID}`) als auch
    /// alte, noch nicht umbenannte Ordner von vor GitHub #81 (Ordnername ==
    /// rohe `geraeteID`).
    static func gehoertZu(_ ordnerName: String, geraeteID: String) -> Bool {
        ordnerName == geraeteID || ordnerName.hasSuffix("_\(kurzeID(geraeteID))")
    }
}
