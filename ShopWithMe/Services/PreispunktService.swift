import Foundation
import SwiftData

/// Zentrale Schreiblogik für ``Preispunkt`` (GitHub #76): legt einen neuen
/// Preispunkt nur an, wenn sich der Preis gegenüber dem zuletzt bekannten
/// Preispunkt für dasselbe (``Artikel``, ``Geschaeft``)-Paar tatsächlich
/// unterscheidet (Slowly-Changing-Dimension-Muster „nur Änderungen", analog
/// dem Fingerabdruck-Skip in `SyncSnapshotExportService`) — bei unverändertem
/// Preis wird stattdessen nur `datum` des bestehenden Punkts aktualisiert
/// („zuletzt gesehen"). Ohne ``artikel`` (keine bestehende Zuordnung) entsteht
/// immer ein neuer, eigenständiger Punkt, da es dann keinen sinnvollen
/// Vergleichsschlüssel gibt (siehe „Ohne Artikel-Zuordnung" in
/// `GeschaeftPreisUebersichtView`).
enum PreispunktService {
    /// `nameFallback` wird nur verwendet, wenn `artikel` `nil` ist (analog dem
    /// früheren `neuerEintrag.artikelNameSnapshot = artikel?.name ?? name` in
    /// ``BelegScanView``/``PreisschildScanView``) — mit ``artikel`` leitet
    /// ``Preispunkt/init(artikel:geschaeft:preis:datum:produktName:alternativerName:)``
    /// den Schnappschuss-Namen selbst ab.
    @discardableResult
    @MainActor
    static func erfassen(
        preis: Decimal,
        artikel: Artikel?,
        geschaeft: Geschaeft?,
        datum: Date,
        produktName: String?,
        alternativerName: String?,
        nameFallback: String = "",
        context: ModelContext
    ) -> Preispunkt {
        if let artikel, let letzter = letzterPreispunkt(fuerArtikel: artikel, geschaeft: geschaeft, context: context) {
            if letzter.preis == preis {
                letzter.datum = datum
                return letzter
            }
        }
        let neuer = Preispunkt(
            artikel: artikel, geschaeft: geschaeft, preis: preis, datum: datum,
            produktName: produktName, alternativerName: alternativerName
        )
        if artikel == nil {
            neuer.artikelNameSnapshot = nameFallback
        }
        context.insert(neuer)
        return neuer
    }

    /// Bewusst nur nach **einer** Beziehung (``Artikel``) live gefetcht, die
    /// zweite Bedingung (``Geschaeft``, kann `nil` sein) läuft in Swift —
    /// dasselbe defensive Muster wie in `ArtikelPreisVerlaufView`, siehe dort
    /// für die Begründung (GitHub #33).
    @MainActor
    private static func letzterPreispunkt(fuerArtikel artikel: Artikel, geschaeft: Geschaeft?, context: ModelContext) -> Preispunkt? {
        let artikelID = artikel.persistentModelID
        let deskriptor = FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.artikel?.persistentModelID == artikelID })
        let geschaeftID = geschaeft?.persistentModelID
        return ((try? context.fetch(deskriptor)) ?? [])
            .filter { $0.geschaeft?.persistentModelID == geschaeftID }
            .max { $0.datum < $1.datum }
    }

    /// Der aktuell bekannte Preispunkt für (`artikel`, `geschaeft`), falls sein
    /// `datum` auf denselben Kalendertag wie `amDatum` fällt — Grundlage für die
    /// interaktive Tages-Kollisionsabfrage beim Scannen (siehe `BelegScanView`/
    /// `PreisschildScanView`, GitHub #76-Folgearbeit). `nil` ohne `artikel` (kein
    /// sinnvoller Vergleichsschlüssel) oder ohne Treffer am selben Tag.
    @MainActor
    static func vorhandenerPunktHeute(artikel: Artikel?, geschaeft: Geschaeft?, amDatum: Date, context: ModelContext) -> Preispunkt? {
        guard let artikel, let letzter = letzterPreispunkt(fuerArtikel: artikel, geschaeft: geschaeft, context: context)
        else { return nil }
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
