import Foundation
import SwiftData

/// Vom Anwender bewusst ignorierter Vorschlag der Standort-basierten Ladenerkennung
/// (``GeschaeftErkennungService``) — verhindert, dass ``GeschaeftVorschlagBanner``
/// erneut für denselben Laden erscheint, bis der Anwender ihn über „Alle Geschäfte in
/// der Nähe“ wieder aufnimmt (siehe `docs/GESCHAEFTSERKENNUNG.md`).
///
/// Referenziert bewusst kein ``Geschaeft`` per Relationship, da auch noch nicht
/// angelegte, per Apple Maps erkannte Läden (``GeschaeftVorschlag/unbekannt(_:)``)
/// ignoriert werden können — Name und/oder Koordinaten genügen für den Abgleich
/// (siehe ``GeschaeftErkennungService/istIgnoriert(_:ignorierte:)``), analog zu
/// ``GeschaeftErkennungService/istBekannterTreffer(_:fuer:)``. Koordinaten sind
/// optional, da ein bereits angelegtes ``Geschaeft`` ohne gespeicherten Standort
/// (``Geschaeft/breitengrad``/``laengengrad``) trotzdem allein anhand des Namens
/// ignorierbar sein soll.
@Model
final class IgnorierterGeschaeftsVorschlag {
    var name: String
    var breitengrad: Double?
    var laengengrad: Double?
    var ignoriertAm: Date

    init(name: String, breitengrad: Double?, laengengrad: Double?) {
        self.name = name
        self.breitengrad = breitengrad
        self.laengengrad = laengengrad
        self.ignoriertAm = .now
    }
}
