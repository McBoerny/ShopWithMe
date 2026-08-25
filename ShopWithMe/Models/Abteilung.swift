import Foundation
import SwiftData

/// Eine Abteilung fasst gleichartige Artikel zusammen, z.B. „Obst & Gemüse“.
///
/// Abteilungen sind global und geschäftsunabhängig. Ob eine Abteilung in einem
/// bestimmten Geschäft verfügbar ist, ergibt sich direkt über ``geschaefte``
/// (``Geschaeft/abteilungen``) — siehe `docs/DECISIONS.md`.
@Model
final class Abteilung {
    /// Eindeutige Kennung.
    var id: UUID
    /// Anzeigename der Abteilung, z.B. "Obst & Gemüse".
    var name: String
    /// Standard-SF-Symbol, das neuen ``Artikel``n dieser Abteilung vorgeschlagen wird.
    var standardSymbol: String
    /// Standardfarbe als Hex-String (z.B. `"#34C759"`), die neuen ``Artikel``n dieser
    /// Abteilung vorgeschlagen wird.
    var standardFarbeHex: String
    /// Reihenfolge für die Anzeige in Auswahllisten.
    var sortIndex: Int

    /// Artikel, die dieser Abteilung über das alte, einzelwertige ``Artikel/abteilung``
    /// zugeordnet sind — Migrations-Fallback, seit Einführung der Mehrfachzuordnung
    /// nicht mehr die maßgebliche Quelle (siehe ``zugeordneteArtikel``).
    @Relationship(deleteRule: .nullify, inverse: \Artikel.abteilung)
    var artikel: [Artikel] = []
    /// Artikel, die dieser Abteilung über ``Artikel/abteilungen`` (Mehrfachzuordnung)
    /// zugeordnet sind — die maßgebliche Quelle. Inverse wird auf der
    /// ``Artikel/abteilungenRaw``-Seite deklariert (analog ``geschaefte`` unten, die
    /// ebenfalls nur einseitig `inverse:` trägt).
    var zugeordneteArtikel: [Artikel] = []

    /// Geschäfte, in denen diese Abteilung verfügbar ist — siehe
    /// ``Geschaeft/abteilungen``.
    var geschaefte: [Geschaeft] = []
    /// Geschäfte, die diese Abteilung individuell ausgeschlossen haben —
    /// inverse zu ``Geschaeft/ausgeschlosseneAbteilungen``. Ohne diese
    /// `inverse`-Deklaration bliebe der Ausschluss-Eintrag beim Löschen der
    /// Abteilung eine "baumelnde" Referenz (Absturzrisiko wie bei
    /// ``Geschaeft/einkaufsvorgaenge`` beschrieben) statt automatisch aus dem
    /// Array entfernt zu werden.
    @Relationship(inverse: \Geschaeft.ausgeschlosseneAbteilungen)
    var geschaefteMitAusschluss: [Geschaeft] = []

    /// Kaufeinträge, deren Abteilung-Schnappschuss auf diese Abteilung
    /// verweist — inverse zu ``KaufEintrag/abteilung``. Nullify: die
    /// Kaufhistorie bleibt bestehen, auch wenn die Abteilung später gelöscht
    /// wird (Absturzrisiko ohne diese `inverse`-Deklaration wie bei
    /// ``Geschaeft/einkaufsvorgaenge`` beschrieben).
    @Relationship(deleteRule: .nullify, inverse: \KaufEintrag.abteilung)
    var kaufEintraege: [KaufEintrag] = []
    /// Gelernte Abteilungs-Distanzen, an denen diese Abteilung als "erste"
    /// Seite beteiligt ist — inverse zu ``WarengruppenDistanz/abteilungA``.
    /// Kaskadierend: ohne die Abteilung ist der Distanz-Eintrag bedeutungslos.
    @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.abteilungA)
    var distanzenAlsAbteilungA: [WarengruppenDistanz] = []
    /// Wie ``distanzenAlsAbteilungA``, für die "zweite" Seite
    /// (``WarengruppenDistanz/abteilungB``) — zwei getrennte Inverse-Arrays,
    /// da es sich um zwei unabhängige Relationship-Kanten handelt.
    @Relationship(deleteRule: .cascade, inverse: \WarengruppenDistanz.abteilungB)
    var distanzenAlsAbteilungB: [WarengruppenDistanz] = []

    /// Rohwert für ``geschaeftsTypen`` von vor Einführung von ``GeschaeftTyp`` als
    /// eigenständigem SwiftData-Modell (GitHub #25) — enum-Rohwerte wie
    /// `"drogerie"`. Bleibt nach der einmaligen Migration
    /// (``geschaeftsTypenMigrierenFallsNoetig(context:)``) unverändert im
    /// Datensatz stehen (tote Altlast). Bewusst nicht `private`, damit Tests „alte“
    /// Datensätze simulieren können.
    var geschaeftsTypenRaw: [String]?
    /// Rohspeicher für ``geschaeftsTypen`` — bewusst `internal` (nicht `private`),
    /// damit ``GeschaeftTyp`` per `inverse:`-KeyPath darauf verweisen kann. Nicht
    /// direkt verwenden, stattdessen ``geschaeftsTypen``.
    @Relationship(inverse: \GeschaeftTyp.standardAbteilungen)
    var geschaeftsTypModelle: [GeschaeftTyp] = []
    /// Geschäftstypen, für die diese Abteilung als typische Abteilung gilt —
    /// unabhängig von einer tatsächlichen Zuordnung zu einem konkreten
    /// ``Geschaeft`` (siehe ``geschaefte``). Grundlage dafür, dass
    /// ``Geschaeft/verfuegbareAbteilungen(alleAbteilungen:)`` diese Abteilung für jedes
    /// Geschäft mit passendem Typ automatisch als verfügbar ansieht (GitHub #5),
    /// ohne sie in ``geschaefte`` zu persistieren.
    var geschaeftsTypen: [GeschaeftTyp] {
        get { geschaeftsTypModelle }
        set { geschaeftsTypModelle = newValue }
    }

    /// Rohspeicher für ``lamportZaehler`` — additiv optional, siehe
    /// ``GeschaeftTyp/lamportZaehler``.
    private var lamportZaehlerRaw: UInt64?
    /// Logischer Zeitstempel der letzten Änderung an ``name``/``standardSymbol``/
    /// ``standardFarbeHex`` — Grundlage dafür, dass eine Umbenennung/
    /// Farbänderung auch bereits synchronisierte Geräte erreicht
    /// (`SyncSnapshotImportService.mergeAbteilungen`), siehe
    /// ``GeschaeftTyp/lamportZaehler`` für die volle Begründung.
    var lamportZaehler: UInt64 { LamportVersionierung.stand(lamportZaehlerRaw) }

    init(name: String, standardSymbol: String, standardFarbeHex: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.standardSymbol = standardSymbol
        self.standardFarbeHex = standardFarbeHex
        self.sortIndex = sortIndex
    }

    /// Aufgerufen, wenn der Anwender ``name``/``standardSymbol``/
    /// ``standardFarbeHex`` dieser bereits bestehenden Abteilung ändert
    /// (siehe `AbteilungenVerwaltungView`) — nie bei bloßer Neuanlage, siehe
    /// ``GeschaeftTyp/markiereGeaendert()``.
    func markiereGeaendert() {
        LamportVersionierung.markiereGeaendert(&lamportZaehlerRaw)
    }

    /// Übernimmt beim Sync-Merge einen tatsächlich neueren Zählerstand, siehe
    /// ``GeschaeftTyp/uebernehmeLamportZaehler(_:)``.
    func uebernehmeLamportZaehler(_ fremderZaehler: UInt64) {
        LamportVersionierung.uebernehmeFremdenStand(&lamportZaehlerRaw, fremderZaehler: fremderZaehler)
    }
}

extension Abteilung {
    /// Name der Abteilung, in die unkategorisierte Artikel automatisch fallen
    /// (siehe ``Artikel/effektiveAbteilung(context:)``).
    static let sonstigesName = "Sonstiges"

    /// Findet die "Sonstiges"-Abteilung (wird normalerweise über
    /// ``SeedData`` angelegt) oder legt sie an, falls sie ausnahmsweise noch nicht
    /// existiert.
    static func sonstige(context: ModelContext) -> Abteilung {
        let name = sonstigesName
        var deskriptor = FetchDescriptor<Abteilung>(predicate: #Predicate { $0.name == name })
        deskriptor.fetchLimit = 1
        if let bestehende = try? context.fetch(deskriptor).first {
            return bestehende
        }
        let naechsterIndex = ((try? context.fetch(FetchDescriptor<Abteilung>()))?.map(\.sortIndex).max() ?? -1) + 1
        let neue = Abteilung(name: name, standardSymbol: "shippingbox.fill", standardFarbeHex: "#8E8E93", sortIndex: naechsterIndex)
        context.insert(neue)
        return neue
    }

    /// Migriert vor GitHub #25 angelegte Abteilungen (deren ``geschaeftsTypen`` noch
    /// leer ist, aber ``geschaeftsTypenRaw`` alte enum-Rohwerte gespeichert hat)
    /// einmalig auf die entsprechenden ``GeschaeftTyp``-Objekte. Wird beim
    /// App-Start für alle Abteilungen aufgerufen (siehe ``SeedData``).
    static func geschaeftsTypenMigrierenFallsNoetig(context: ModelContext) {
        let alle = (try? context.fetch(FetchDescriptor<Abteilung>())) ?? []
        for abteilung in alle {
            guard abteilung.geschaeftsTypen.isEmpty,
                  let rohwerte = abteilung.geschaeftsTypenRaw, !rohwerte.isEmpty else { continue }
            let namen = rohwerte.compactMap(GeschaeftTyp.legacyName(fuerRohwert:))
            guard !namen.isEmpty else { continue }
            abteilung.geschaeftsTypen = namen.map { GeschaeftTyp.mitNamen($0, context: context) }
        }
    }
}
