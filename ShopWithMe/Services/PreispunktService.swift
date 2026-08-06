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
    /// `produkt` (GitHub #47, Schritt 5/5): optional bereits bekanntes,
    /// konkretes Produkt (z.B. per ``ArtikelZuordnungsService``-Produktname-
    /// Treffer) — ohne Angabe weiterhin Fallback auf
    /// ``Produkt/standardProdukt(fuer:context:)`` (Schritt 1/5). Fließt auch
    /// in den SCD-Vergleichsschlüssel von ``letzterPreispunkt(fuerArtikel:produkt:geschaeft:context:)``
    /// ein, damit zwei echte Produkte desselben Artikels+Geschäfts (z.B.
    /// „Odol" und „Paradontol" für „Zahnpasta") unabhängige Preishistorien
    /// behalten, statt sich gegenseitig zu überschreiben.
    @discardableResult
    @MainActor
    static func erfassen(
        preis: Decimal,
        artikel: Artikel?,
        produkt: Produkt? = nil,
        geschaeft: Geschaeft?,
        datum: Date,
        produktName: String?,
        alternativerName: String?,
        nameFallback: String = "",
        context: ModelContext
    ) -> Preispunkt {
        let aufgeloestesProdukt = produkt ?? artikel.map { Produkt.standardProdukt(fuer: $0, context: context) }
        if let artikel, let letzter = letzterPreispunkt(fuerArtikel: artikel, produkt: aufgeloestesProdukt, geschaeft: geschaeft, context: context) {
            if letzter.preis == preis {
                letzter.datum = datum
                letzter.produkt = aufgeloestesProdukt
                return letzter
            }
        }
        let neuer = Preispunkt(
            artikel: artikel, produkt: aufgeloestesProdukt, geschaeft: geschaeft, preis: preis, datum: datum,
            produktName: produktName, alternativerName: alternativerName
        )
        if artikel == nil {
            neuer.artikelNameSnapshot = nameFallback
        }
        context.insert(neuer)
        return neuer
    }

    /// Bewusst nur nach **einer** Beziehung (``Artikel``) live gefetcht, die
    /// übrigen Bedingungen (``Geschaeft``/``Produkt``, beide `nil`-fähig)
    /// laufen in Swift — dasselbe defensive Muster wie in
    /// `ArtikelPreisVerlaufView`, siehe dort für die Begründung (GitHub #33).
    @MainActor
    private static func letzterPreispunkt(fuerArtikel artikel: Artikel, produkt: Produkt?, geschaeft: Geschaeft?, context: ModelContext) -> Preispunkt? {
        let artikelID = artikel.persistentModelID
        let deskriptor = FetchDescriptor<Preispunkt>(predicate: #Predicate { $0.artikel?.persistentModelID == artikelID })
        let geschaeftID = geschaeft?.persistentModelID
        let produktID = produkt?.persistentModelID
        return ((try? context.fetch(deskriptor)) ?? [])
            .filter { $0.geschaeft?.persistentModelID == geschaeftID && $0.produkt?.persistentModelID == produktID }
            .max { $0.datum < $1.datum }
    }

    /// Der aktuell bekannte Preispunkt für (`artikel`, `produkt`, `geschaeft`),
    /// falls sein `datum` auf denselben Kalendertag wie `amDatum` fällt —
    /// Grundlage für die interaktive Tages-Kollisionsabfrage beim Scannen
    /// (siehe `BelegScanView`/`PreisschildScanView`, GitHub #76-Folgearbeit).
    /// `produkt: nil` (Default) matcht gegen das bereits **bestehende**
    /// Platzhalter-Standardprodukt des Artikels (``Produkt/bestehendesStandardProdukt(fuer:context:)``,
    /// legt bewusst keins an — reine Prüfung, kein Seiteneffekt). `nil` ohne
    /// `artikel` (kein sinnvoller Vergleichsschlüssel) oder ohne Treffer am
    /// selben Tag.
    @MainActor
    static func vorhandenerPunktHeute(
        artikel: Artikel?, produkt: Produkt? = nil, geschaeft: Geschaeft?, amDatum: Date, context: ModelContext
    ) -> Preispunkt? {
        guard let artikel else { return nil }
        let aufgeloestesProdukt = produkt ?? Produkt.bestehendesStandardProdukt(fuer: artikel, context: context)
        guard let letzter = letzterPreispunkt(fuerArtikel: artikel, produkt: aufgeloestesProdukt, geschaeft: geschaeft, context: context)
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
