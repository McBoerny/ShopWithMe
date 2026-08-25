import Foundation
import SwiftData

/// Löst einen ``Artikel`` zugunsten eines anderen auf — entweder als
/// zusätzlichen alternativen Namen (Alias) oder als konkretes ``Produkt`` des
/// primären Artikels (GitHub #133, Vorschlagsview siehe
/// ``ArtikelDuplikatVorschlaegeView``).
///
/// Beide Funktionen sind reine, synchrone SwiftData-Mutationen — wie
/// ``ArtikelListView/artikelLoeschen(_:)``/`BelegScanView.uebernehmen()` für den
/// Aufruf innerhalb von ``DatabaseLeaseService/performMicroLease(context:mutate:)``
/// gedacht, mit bereits über ``ModelReference`` sicher aufgelösten Objekten.
///
/// **Sync-Sicherheit:** Beide Funktionen registrieren vor dem Löschen einen
/// ``SyncEntitaetsAlias`` (`zuLoeschender.id` → primärer Artikel), damit ein
/// künftiges Bereich-A-``SyncEvent`` eines Peers, der die alte ID noch
/// referenziert, korrekt auf den primären Artikel auflöst — derselbe
/// Mechanismus, den `SyncSnapshotImportService.mergeArtikel` bereits nutzt,
/// wenn zwei namensgleiche Artikel aus unterschiedlichen Quellen
/// zusammengeführt werden. Der anschließende ``SyncTombstone`` lässt Peers
/// ihre eigene Kopie beim nächsten Sync entfernen — identisches Risikoprofil
/// wie eine gewöhnliche Artikel-Löschung, nichts Neues.
enum ArtikelZusammenfuehrungsService {
    /// Löst `zuLoeschender` auf: sein Name (und seine bisherigen alternativen
    /// Namen) werden ``Artikel/alternativenNamenLernen(_:)`` zufolge zu
    /// zusätzlichen alternativen Namen von `primaerArtikel`, alle Referenzen
    /// (Produkte, Käufe, Einkaufslisten-Mitgliedschaften, Verfügbarkeits-/
    /// Listen-Fakten) wandern zu `primaerArtikel`, `zuLoeschender` wird
    /// anschließend per Tombstone gelöscht.
    @MainActor
    static func alsAliasAufloesen(_ zuLoeschender: Artikel, in primaerArtikel: Artikel, context: ModelContext) {
        guard zuLoeschender.persistentModelID != primaerArtikel.persistentModelID else { return }

        primaerArtikel.alternativenNamenLernen(zuLoeschender.name)
        for name in zuLoeschender.alternativeNamen {
            primaerArtikel.alternativenNamenLernen(name)
        }

        // Standard-Produkt-Kollision: existiert bereits auf beiden Seiten ein
        // Platzhalter-Produkt, wird das umgehängte zu einem normalen benannten
        // Produkt, statt die Ein-Standard-Produkt-Invariante von `primaerArtikel`
        // zu verletzen (siehe `Produkt.bestehendesStandardProdukt(fuer:context:)`).
        let primaerHatBereitsStandard = Produkt.bestehendesStandardProdukt(fuer: primaerArtikel, context: context) != nil
        for produkt in zuLoeschender.produkte {
            if produkt.istStandard && primaerHatBereitsStandard {
                produkt.istStandard = false
            }
            produkt.artikel = primaerArtikel
        }

        referenzenUmhaengen(von: zuLoeschender, auf: primaerArtikel, context: context)

        SyncEntitaetsAliasService.registriere(
            entitaetsArt: SyncEntitaetsArt.artikel, fremdeID: zuLoeschender.id, lokaleID: primaerArtikel.id, context: context
        )
        SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.artikel, id: zuLoeschender.id, context: context)
        context.delete(zuLoeschender)
    }

    /// Wandelt `zuKonvertierender` in ein konkretes ``Produkt`` von
    /// `primaerArtikel` um: sein vorhandenes Standard-Platzhalterprodukt (falls
    /// vorhanden) oder ein neu angelegtes Produkt gleichen Namens übernimmt
    /// seine Preishistorie/Namen, übrige eigene Produkte wandern als flache
    /// Geschwister mit an `primaerArtikel`. Alle sonstigen Referenzen wandern
    /// wie bei ``alsAliasAufloesen(_:in:context:)``, `zuKonvertierender` wird
    /// anschließend per Tombstone gelöscht.
    @MainActor
    static func alsProduktKonvertieren(_ zuKonvertierender: Artikel, unter primaerArtikel: Artikel, context: ModelContext) {
        guard zuKonvertierender.persistentModelID != primaerArtikel.persistentModelID else { return }

        // Vor jeder Umhängung sichern — `standard.artikel = primaerArtikel`
        // unten entfernt `standard` sonst bereits aus dieser Liste, bevor die
        // Schleife es überspringen könnte.
        let bisherigeProdukte = zuKonvertierender.produkte

        let konvertiertesProdukt: Produkt
        if let standard = Produkt.bestehendesStandardProdukt(fuer: zuKonvertierender, context: context) {
            standard.istStandard = false
            standard.artikel = primaerArtikel
            konvertiertesProdukt = standard
        } else {
            let neu = Produkt(name: zuKonvertierender.name, artikel: primaerArtikel)
            context.insert(neu)
            konvertiertesProdukt = neu
        }
        for produkt in bisherigeProdukte where produkt.persistentModelID != konvertiertesProdukt.persistentModelID {
            produkt.artikel = primaerArtikel
        }

        konvertiertesProdukt.alternativenKlarnamenLernen(zuKonvertierender.name)
        for name in zuKonvertierender.alternativeNamen {
            konvertiertesProdukt.alternativenKlarnamenLernen(name)
        }

        referenzenUmhaengen(von: zuKonvertierender, auf: primaerArtikel, context: context, produktFuerLeereEintraege: konvertiertesProdukt)

        SyncEntitaetsAliasService.registriere(
            entitaetsArt: SyncEntitaetsArt.artikel, fremdeID: zuKonvertierender.id, lokaleID: primaerArtikel.id, context: context
        )
        SyncTombstoneService.markiereGeloescht(art: SyncEntitaetsArt.artikel, id: zuKonvertierender.id, context: context)
        context.delete(zuKonvertierender)
    }

    /// Hängt alle Nicht-Produkt-Referenzen von `quelle` auf `ziel` um — geteilte
    /// Grundlage beider Zusammenführungsfunktionen. `produktFuerLeereEintraege`
    /// (nur bei ``alsProduktKonvertieren(_:unter:context:)`` gesetzt) füllt bei
    /// einem ``EinkaufslistenEintrag`` ohne eigenes ``EinkaufslistenEintrag/produkt``
    /// das neu entstandene/wiederverwendete Produkt ein, statt den Eintrag ohne
    /// Produktbezug auf `ziel` zurückfallen zu lassen.
    private static func referenzenUmhaengen(
        von quelle: Artikel, auf ziel: Artikel, context: ModelContext, produktFuerLeereEintraege: Produkt? = nil
    ) {
        for kauf in quelle.kaufEintraege {
            kauf.artikel = ziel
        }

        // `EinkaufslistenEintrag.einkaufsliste`/`ArtikelListenKauf.einkaufsliste`
        // sind ohne `inverse`-Deklaration referenziert (wie
        // `ArtikelGeschaeftVerfuegbarkeit`) — eine andernorts (z.B. nebenläufig
        // durch einen Sync-Zyklus) bereits gelöschte Einkaufsliste bleibt hier
        // eine "baumelnde" `PersistentIdentifier`-only-Referenz, auf der nur
        // `persistentModelID` sicher lesbar ist, siehe
        // `ArtikelListenKauf.alleEintraege(context:)`. Einmal vorab einsammeln
        // statt pro Eintrag zu raten.
        let gueltigeEinkaufslistenIDs = Set(((try? context.fetch(FetchDescriptor<Einkaufsliste>())) ?? []).map(\.persistentModelID))

        for eintrag in quelle.einkaufslistenEintraege {
            if let produktFuerLeereEintraege, eintrag.produkt == nil {
                eintrag.produkt = produktFuerLeereEintraege
            }
            if let liste = eintrag.einkaufsliste, gueltigeEinkaufslistenIDs.contains(liste.persistentModelID),
               liste.enthaelt(ziel, produkt: eintrag.produkt) {
                // `ziel` hat auf derselben Liste bereits denselben (Produkt-)Eintrag
                // — dieser hier würde eine Dublette erzeugen, bleibt also bei
                // `quelle` und verschwindet gleich mit dessen Löschung (cascade).
                continue
            }
            eintrag.artikel = ziel
        }

        let quelleID = quelle.persistentModelID
        let verfuegbarkeiten = (try? context.fetch(FetchDescriptor<ArtikelGeschaeftVerfuegbarkeit>(
            predicate: #Predicate { $0.artikel?.persistentModelID == quelleID }
        ))) ?? []
        for verfuegbarkeit in verfuegbarkeiten {
            if let geschaeft = verfuegbarkeit.geschaeft {
                ArtikelVerfuegbarkeitService.vermerkeGekauft(artikel: ziel, geschaeft: geschaeft, context: context)
            }
            context.delete(verfuegbarkeit)
        }

        let listenKaeufe = (try? context.fetch(FetchDescriptor<ArtikelListenKauf>(
            predicate: #Predicate { $0.artikel?.persistentModelID == quelleID }
        ))) ?? []
        if !listenKaeufe.isEmpty {
            var bekannt = ArtikelListenKaufService.alleEintraege(context: context)
            for kauf in listenKaeufe {
                if let einkaufsliste = kauf.einkaufsliste, gueltigeEinkaufslistenIDs.contains(einkaufsliste.persistentModelID) {
                    ArtikelListenKaufService.vermerkeAbgehaktFallsNoetig(
                        artikel: ziel, produkt: kauf.produkt, einkaufsliste: einkaufsliste, am: kauf.zuletztAbgehaktAm,
                        bekannt: &bekannt, context: context
                    )
                    ArtikelListenKaufService.vermerkeHinzugefuegtFallsNoetig(
                        artikel: ziel, produkt: kauf.produkt, einkaufsliste: einkaufsliste, am: kauf.zuletztHinzugefuegtAm,
                        bekannt: &bekannt, context: context
                    )
                }
                context.delete(kauf)
            }
        }
    }
}
