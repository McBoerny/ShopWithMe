import Foundation
import SwiftData

/// Merkt sich den zuletzt bekannten Anzeigenamen (``DatabaseLeaseService/geraeteName``)
/// eines Peer-Geräts, aktualisiert bei jedem ``SyncSnapshotImportService``-Lauf
/// aus dem jeweiligen `export.json` (siehe ``SyncSnapshot/geraeteName``).
///
/// Einziger Zweck: `SyncEvent.autorGeraeteID` (eine reine UUID) in eine
/// menschenlesbare Form auflösen, z.B. für den Überkauf-Hinweis (GitHub #48,
/// „Bereits von {Gerätename} abgehakt"). Bewusst kein Bereich-B-Stammdatum
/// (nicht Teil von ``SyncSnapshot`` selbst, sondern nebenläufig aus dessen
/// `geraeteID`/`geraeteName`-Feldern abgeleitet) — eine rein lokale,
/// nicht synchronisierte Zwischenablage.
@Model
final class SyncPeerInfo {
    var id: UUID
    var peerGeraeteID: String
    var geraeteName: String
    /// Zeitpunkt des zuletzt erfolgreich importierten Snapshots dieses Peers
    /// (dessen ``SyncSnapshot/erzeugtAm``, nicht der lokale Import-Zeitpunkt) —
    /// Grundlage für ``SyncSnapshotImportService/maximalesSnapshotAlter``:
    /// verwaiste Peer-Ordner aus früheren Testinstallationen (jede
    /// Neuinstallation erzeugt eine neue Geräte-ID) sollen nach hinreichend
    /// langer Inaktivität nicht mehr für immer alte Daten zurückspielen.
    /// Optional, damit vor dieser Ergänzung angelegte Datensätze nicht
    /// abstürzen — `nil` wird wie „schon lange nicht mehr gesehen" behandelt.
    var zuletztGesehenRaw: Date?

    init(peerGeraeteID: String, geraeteName: String, zuletztGesehen: Date = Date()) {
        self.id = UUID()
        self.peerGeraeteID = peerGeraeteID
        self.geraeteName = geraeteName
        self.zuletztGesehenRaw = zuletztGesehen
    }
}

extension SyncPeerInfo {
    var zuletztGesehen: Date {
        zuletztGesehenRaw ?? .distantPast
    }

    /// Peer-Lebenszyklus: Grundlage für eine sichtbare Warnung/bestätigte
    /// Entfernung lange nicht mehr gesehener Geräte — dieselbe Schwelle wie
    /// der bereits bestehende Ignorier-Mechanismus
    /// (``SyncSnapshotImportService/maximalesSnapshotAlter``, 30 Tage), kein
    /// neuer, eigenständiger Wert: ein Peer jenseits dieser Grenze wird beim
    /// Import ohnehin schon ignoriert, die Warnung fällt einfach mit diesem
    /// bereits bestehenden Verhalten zusammen.
    @MainActor
    var istWahrscheinlichTot: Bool {
        Date().timeIntervalSince(zuletztGesehen) > SyncSnapshotImportService.maximalesSnapshotAlter
    }

    /// Grobe Auflösung für das Nachführen von ``zuletztGesehenRaw`` — der Wert
    /// dient einzig der 30-Tage-Alters-Schwelle
    /// (``SyncSnapshotImportService/maximalesSnapshotAlter``), die keine
    /// Sekundengenauigkeit braucht. Ohne diese Schwelle würde
    /// ``aktualisiere(peerGeraeteID:geraeteName:zuletztGesehen:context:)`` bei
    /// **jedem** Sync-Zyklus (5s/60s) eine echte SwiftData-Änderung erzwingen,
    /// weil der übergebene `zuletztGesehen`-Wert (``SyncSnapshot/erzeugtAm``
    /// des Peers) bei unbedingtem Export bislang bei jedem Zyklus neu war —
    /// unabhängig davon, ob sich am eigentlichen Datenbestand etwas geändert
    /// hat. Diese unnötige, wiederkehrende Store-Mutation war eine der
    /// Ursachen für GitHub #60 (Flackern) und #70 (häufige Schreibzugriffe).
    private static let zuletztGesehenAufloesung: TimeInterval = 60 * 60

    /// Merkt sich (oder aktualisiert) Anzeigenamen und Zuletzt-gesehen-Zeitpunkt
    /// von `peerGeraeteID` — schreibt beide Felder nur bei tatsächlicher
    /// Änderung (Name) bzw. bei Überschreiten der groben Auflösung
    /// (Zuletzt-gesehen), siehe ``zuletztGesehenAufloesung``.
    static func aktualisiere(peerGeraeteID: String, geraeteName: String, zuletztGesehen: Date, context: ModelContext) {
        var deskriptor = FetchDescriptor<SyncPeerInfo>(
            predicate: #Predicate { $0.peerGeraeteID == peerGeraeteID }
        )
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            if bestehende.geraeteName != geraeteName {
                bestehende.geraeteName = geraeteName
            }
            if abs(zuletztGesehen.timeIntervalSince(bestehende.zuletztGesehen)) >= zuletztGesehenAufloesung {
                bestehende.zuletztGesehenRaw = zuletztGesehen
            }
        } else {
            context.insert(SyncPeerInfo(peerGeraeteID: peerGeraeteID, geraeteName: geraeteName, zuletztGesehen: zuletztGesehen))
        }
    }

    /// Der zuletzt bekannte Anzeigename von `peerGeraeteID`, `nil` falls noch
    /// nie ein Snapshot dieses Geräts importiert wurde (z.B. direkt nach dem
    /// Verbinden eines Sync-Ordners, bevor der erste Sync-Zyklus lief) oder
    /// falls die ID dem eigenen Gerät entspricht (kein Eintrag nötig).
    static func geraeteName(fuer peerGeraeteID: String, context: ModelContext) -> String? {
        var deskriptor = FetchDescriptor<SyncPeerInfo>(
            predicate: #Predicate { $0.peerGeraeteID == peerGeraeteID }
        )
        deskriptor.fetchLimit = 1
        return try? context.fetch(deskriptor).first?.geraeteName
    }
}
