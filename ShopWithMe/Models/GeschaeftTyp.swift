import Foundation
import SwiftData

/// Ein Geschäftstyp (z.B. „Lebensmittel“, „Drogerie“) — bis GitHub #25 ein festes
/// Swift-`enum`, jetzt ein eigenes Modell, damit der Anwender in
/// ``GeschaeftsTypenVerwaltungView``/``GeschaeftStammdatenEditView`` auch eigene,
/// benutzerdefinierte Geschäftstypen anlegen kann. Die zehn bisherigen Typen
/// werden weiterhin beim ersten Start vorinstalliert (``SeedData/standardGeschaeftsTypen``).
@Model
final class GeschaeftTyp {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename, z.B. „Lebensmittel“ — zugleich das eindeutige Merkmal für
    /// ``mitNamen(_:symbolName:context:)`` (fetch-or-create).
    var name: String
    /// Standard-SF-Symbol für diesen Geschäftstyp.
    var symbolName: String
    /// Reihenfolge für die Anzeige in Auswahllisten.
    var sortIndex: Int
    /// Geschäfte, die diesem Typ zugeordnet sind — inverse zu ``Geschaeft/typen``.
    var geschaefte: [Geschaeft] = []
    /// Abteilungen, die für diesen Typ als Standard gelten — inverse zu
    /// ``Abteilung/geschaeftsTypen`` (GitHub #5).
    var standardAbteilungen: [Abteilung] = []
    /// Rohspeicher für ``farbeHex`` — additiv optional, damit vor GitHub #40
    /// angelegte Geschäftstypen (inkl. der zehn vorinstallierten Standardtypen)
    /// ohne Migration einen sinnvollen Fallback erhalten.
    private var farbeHexRaw: String?
    /// Anzeigefarbe dieses Geschäftstyps (GitHub #40) — frei wählbar, fällt ohne
    /// explizite Wahl auf eine neutrale Standardfarbe zurück.
    var farbeHex: String {
        get { farbeHexRaw ?? "#8E8E93" }
        set { farbeHexRaw = newValue }
    }
    /// Rohspeicher für ``lamportZaehler`` — additiv optional, damit vor diesem
    /// Feature angelegte Geschäftstypen ohne Migration bei `0` starten (siehe
    /// ``markiereGeaendert()``).
    private var lamportZaehlerRaw: UInt64?
    /// Logischer Zeitstempel der letzten Änderung an ``name``/``symbolName``/
    /// ``farbeHex`` (nicht an ``standardAbteilungen``/``geschaefte`` — diese
    /// bleiben additiv gemergt). Grundlage dafür, dass eine Umbenennung/
    /// Farbänderung auf einem Gerät auch bereits synchronisierte Geräte
    /// erreicht (`SyncSnapshotImportService.mergeGeschaeftsTypen`) — ohne
    /// diesen Zähler wären diese Felder nach der Erstanlage für immer
    /// eingefroren (siehe `docs/DATENSYNCHRONISATION.md` §4.1-Nachtrag).
    /// Denselben globalen ``LamportClock`` wie Bereich A wiederverwendet,
    /// nicht domänenspezifisch — vergleichbar ist der Wert ohnehin nur
    /// innerhalb desselben Objekts (`lokal.lamportZaehler` vs.
    /// `eintrag.lamportZaehler`), nie geräte- oder typübergreifend.
    var lamportZaehler: UInt64 { LamportVersionierung.stand(lamportZaehlerRaw) }

    init(name: String, symbolName: String, farbeHex: String? = nil, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.symbolName = symbolName
        self.farbeHexRaw = farbeHex
        self.sortIndex = sortIndex
    }

    /// Aufgerufen, wenn der Anwender ``name``/``symbolName``/``farbeHex``
    /// dieses bereits bestehenden Geschäftstyps ändert (siehe
    /// `GeschaeftsTypenVerwaltungView`) — nie bei bloßer Neuanlage (dort
    /// startet der Zähler bewusst bei `0`, ein frisch angelegter, noch nie
    /// synchronisierter Typ soll keinen anderswo bereits bekannten,
    /// gleichnamigen Typ überschreiben können).
    func markiereGeaendert() {
        LamportVersionierung.markiereGeaendert(&lamportZaehlerRaw)
    }

    /// Übernimmt beim Sync-Merge einen vom sendenden Peer mitgebrachten,
    /// tatsächlich neueren Zählerstand (siehe `SyncSnapshotImportService.mergeGeschaeftsTypen`)
    /// — im Unterschied zu ``markiereGeaendert()`` kein neuer eigener Tick,
    /// sondern die Übernahme des bereits vom Absender vergebenen Werts, damit
    /// dieses Gerät bei einem künftigen Merge korrekt erkennt, dass es diesen
    /// Stand bereits kennt.
    func uebernehmeLamportZaehler(_ fremderZaehler: UInt64) {
        LamportVersionierung.uebernehmeFremdenStand(&lamportZaehlerRaw, fremderZaehler: fremderZaehler)
    }
}

extension GeschaeftTyp {
    static let sonstigesName = "Sonstiges"

    /// Findet einen ``GeschaeftTyp`` mit exakt passendem ``name`` oder legt ihn mit
    /// `symbolName` an, falls er noch nicht existiert — Grundlage für das Anlegen
    /// benutzerdefinierter Typen (GitHub #25) und die einmalige Migration alter
    /// enum-Rohwerte (``legacyName(fuerRohwert:)``).
    static func mitNamen(_ name: String, symbolName: String = "shippingbox", context: ModelContext) -> GeschaeftTyp {
        var deskriptor = FetchDescriptor<GeschaeftTyp>(predicate: #Predicate { $0.name == name })
        deskriptor.fetchLimit = 1
        if let bestehender = try? context.fetch(deskriptor).first {
            return bestehender
        }
        let naechsterIndex = ((try? context.fetch(FetchDescriptor<GeschaeftTyp>()))?.map(\.sortIndex).max() ?? -1) + 1
        let neuer = GeschaeftTyp(name: name, symbolName: symbolName, sortIndex: naechsterIndex)
        context.insert(neuer)
        return neuer
    }

    /// Findet die „Sonstiges“-Abteilung (wird normalerweise über ``SeedData``
    /// angelegt) oder legt sie an, falls sie ausnahmsweise noch nicht existiert.
    static func sonstiges(context: ModelContext) -> GeschaeftTyp {
        mitNamen(sonstigesName, context: context)
    }

    /// Bildet einen alten, vor GitHub #25 gespeicherten enum-Rohwert (z.B.
    /// `"lebensmittel"`, `"buchUndSchreibwaren"`) auf den Anzeigenamen des
    /// entsprechenden vorinstallierten ``GeschaeftTyp`` ab — Grundlage für
    /// ``Geschaeft/typenMigrierenFallsNoetig(context:)`` und
    /// ``Abteilung/geschaeftsTypenMigrierenFallsNoetig(context:)``. `nil`
    /// bei unbekanntem Rohwert.
    static func legacyName(fuerRohwert rohwert: String) -> String? {
        legacyRohwerteZuNamen[rohwert]
    }

    private static let legacyRohwerteZuNamen: [String: String] = [
        "lebensmittel": "Lebensmittel",
        "drogerie": "Drogerie",
        "baumarkt": "Baumarkt",
        "apotheke": "Apotheke",
        "elektronik": "Elektronik",
        "bekleidung": "Bekleidung",
        "getraenkemarkt": "Getränkemarkt",
        "tierbedarf": "Tierbedarf",
        "buchUndSchreibwaren": "Bücher & Schreibwaren",
        "sonstiges": sonstigesName,
    ]
}
