import Foundation

/// Lokales, nicht mit Peers geteiltes Backup-Format für ``SyncErsetzenService``
/// (GitHub #63) — wrapt einen ``SyncSnapshot`` (das Peer-Wire-Format)
/// zusätzlich um gerätelokale Daten, die nicht Teil von ``SyncSnapshot`` sind
/// (z.B. ``IgnorierterGeschaeftsVorschlag``), damit ein Restore aus dem
/// eigenen Backup wirklich vollständig ist statt diese stillschweigend zu
/// verlieren. Das Peer-Wire-Format (``SyncSnapshot/formatVersion``) bleibt
/// dadurch unangetastet.
struct SyncErsetzenBackup: Codable {
    static let aktuelleFormatVersion = 1

    var formatVersion: Int
    var erstelltAm: Date
    var snapshot: SyncSnapshot
    var ignorierteGeschaeftsVorschlaege: [IgnorierterGeschaeftsVorschlagSnapshot]
}

struct IgnorierterGeschaeftsVorschlagSnapshot: Codable {
    var name: String
    var breitengrad: Double?
    var laengengrad: Double?
    var ignoriertAm: Date
}
