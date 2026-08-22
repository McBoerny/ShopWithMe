import Foundation
import SwiftData

/// Zentrale Schreiblogik für ``Preispunkt`` (GitHub #76): legt einen neuen
/// Preispunkt nur an, wenn sich der Preis gegenüber dem zuletzt bekannten
/// Preispunkt für dasselbe (``Produkt``, ``Geschaeft``)-Paar tatsächlich
/// unterscheidet (Slowly-Changing-Dimension-Muster „nur Änderungen", analog
/// dem Fingerabdruck-Skip in `SyncSnapshotExportService`) — bei unverändertem
/// Preis wird stattdessen nur `datum` des bestehenden Punkts aktualisiert
/// („zuletzt gesehen").
///
/// **Produkt-Pflicht:** ``erfassen(preis:produkt:geschaeft:datum:produktName:alternativerName:context:)``
/// verlangt ein bereits aufgelöstes ``Produkt`` — anders als früher gibt es
/// keinen Freitext-Fall mehr, der einen ``Preispunkt`` ganz ohne
/// Produkt-Zuordnung anlegt. Die Aufrufer (`BelegScanView`/
/// `PreisschildScanView`) müssen ein Produkt vor dem Aufruf auflösen (z.B.
/// über ``Produkt/standardProdukt(fuer:context:)``) oder die Position
/// überspringen, wenn keine Zuordnung möglich ist.
enum PreispunktService {
    /// Fließt in den SCD-Vergleichsschlüssel von
    /// ``letzterPreispunkt(fuerProdukt:geschaeft:context:)`` ein, damit zwei
    /// echte Produkte desselben Artikels+Geschäfts (z.B. „Odol" und
    /// „Paradontol" für „Zahnpasta") unabhängige Preishistorien behalten,
    /// statt sich gegenseitig zu überschreiben.
    @discardableResult
    @MainActor
    static func erfassen(
        preis: Decimal,
        produkt: Produkt,
        geschaeft: Geschaeft,
        datum: Date,
        produktName: String?,
        alternativerName: String?,
        context: ModelContext
    ) -> Preispunkt {
        if let letzter = letzterPreispunkt(fuerProdukt: produkt, geschaeft: geschaeft, context: context), letzter.preis == preis {
            letzter.datum = datum
            return letzter
        }
        let neuer = Preispunkt(
            produkt: produkt, geschaeft: geschaeft, preis: preis, datum: datum,
            produktName: produktName, alternativerName: alternativerName
        )
        context.insert(neuer)
        return neuer
    }

    /// Bewusst nur nach **einer** Beziehung (``Produkt``) live gefetcht, die
    /// übrige Bedingung (``Geschaeft``, `nil`-fähig) läuft in Swift —
    /// dasselbe defensive Muster wie in `ArtikelPreisVerlaufView`, siehe dort
    /// für die Begründung (GitHub #33).
    @MainActor
    private static func letzterPreispunkt(fuerProdukt produkt: Produkt, geschaeft: Geschaeft, context: ModelContext) -> Preispunkt? {
        let produktID = produkt.persistentModelID
        let deskriptor = FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.produkt?.persistentModelID == produktID })
        let geschaeftID = geschaeft.persistentModelID
        return ((try? context.fetch(deskriptor)) ?? [])
            .filter { $0.geschaeft?.persistentModelID == geschaeftID }
            .max { $0.datum < $1.datum }
    }

    /// Der aktuell bekannte Preispunkt für (`produkt`, `geschaeft`), falls
    /// sein `datum` auf denselben Kalendertag wie `amDatum` fällt —
    /// Grundlage für die interaktive Tages-Kollisionsabfrage beim Scannen
    /// (siehe `BelegScanView`/`PreisschildScanView`, GitHub #76-Folgearbeit).
    @MainActor
    static func vorhandenerPunktHeute(produkt: Produkt, geschaeft: Geschaeft, amDatum: Date, context: ModelContext) -> Preispunkt? {
        guard let letzter = letzterPreispunkt(fuerProdukt: produkt, geschaeft: geschaeft, context: context) else { return nil }
        return Calendar.current.isDate(letzter.datum, inSameDayAs: amDatum) ? letzter : nil
    }

    /// Löscht `punkt` mit Tombstone — für den Fall, dass der Anwender bei einer
    /// Tages-Kollision „neuen übernehmen" wählt (Standard) und der bestehende
    /// Punkt vor dem Anlegen des neuen entfernt werden muss, statt beide
    /// nebeneinander bestehen zu lassen (das würde erst die nächste
    /// ``PreispunktVerdichtungService``-Verdichtung aufräumen).
    @MainActor
    static func ersetzeVorhandenenPunkt(_ punkt: Preispunkt, context: ModelContext) {
        SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.preispunkt, id: punkt.id, context: context)
        context.delete(punkt)
    }
}
