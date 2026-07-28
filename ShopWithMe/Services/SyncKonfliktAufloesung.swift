import Foundation

/// Konfliktauflösung für konkurrierende Bereich-A-``SyncEvent``s zum selben
/// (`bezugsID`, `artikelID`)-Paar (`docs/DATENSYNCHRONISATION_UMSETZUNGSPLAN.md`
/// Abschnitt 4.4, aus dem #39-Vorschlag §4.1 übernommen). Definiert eine
/// Prioritätsordnung unabhängig vom Lamport-Zähler für die drei
/// Einkaufsvorgang-Aktionen — „Entfernen schlägt alles", „Abwählen schlägt
/// Abhaken" (lieber ein Artikel versehentlich wieder offen als ein übersehener
/// Doppelkauf). Für alle übrigen Fälle (inkl. der beiden
/// Einkaufsliste-Mitgliedschafts-Arten, die kein Sonderfall dieser Regel sind)
/// entscheidet der höhere Lamport-Zähler.
///
/// Arbeitet bewusst auf dem leichtgewichtigen ``Kandidat``-Werttyp statt direkt
/// auf ``SyncEvent`` — der Vergleich soll auch für ein noch nicht in den
/// `ModelContext` eingefügtes, gerade erst empfangenes Event möglich sein (siehe
/// ``SyncImportService``), ohne es dafür vorab einfügen zu müssen.
enum SyncKonfliktAufloesung {
    struct Kandidat {
        var art: SyncEventArt
        var lamportZaehler: UInt64
    }

    static func gewinnt(_ a: Kandidat, ueber b: Kandidat) -> Bool {
        if a.art == .artikelDauerhaftEntfernt { return true }
        if b.art == .artikelDauerhaftEntfernt { return false }
        if a.art == .artikelAbgewaehlt, b.art == .artikelAbgehakt { return true }
        if b.art == .artikelAbgewaehlt, a.art == .artikelAbgehakt { return false }
        return a.lamportZaehler > b.lamportZaehler
    }
}
