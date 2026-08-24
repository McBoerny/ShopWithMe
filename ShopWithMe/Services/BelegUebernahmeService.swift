import Foundation
import SwiftData

/// Bündelt die Persistenz-Orchestrierung nach einem Kassenbon-Scan —
/// extrahiert aus `BelegScanView.uebernehmen()` (GitHub #107, Schritt 2/3,
/// #109). Entscheidet je nach ``BelegScanKontext``, ob ein ``KaufEintrag``
/// (laufender Einkauf) oder nur ein ``Preispunkt`` (Geschäfts-/unbekannter
/// Kontext) entsteht, löst pro Position Artikel/Produkt auf (inkl.
/// automatischer Produkt-Neuanlage) und behandelt Tages-Preis-Kollisionen
/// (GitHub #76-Folgearbeit).
///
/// Stateloser `enum`-Service nach dem in diesem Projekt etablierten Muster
/// (``EinkaufsvorgangAbschlussService``, Schritt 1/3) statt einer
/// `@Observable`/ViewModel-Klasse.
///
/// **Kritisch:** nimmt bewusst bereits fertig gebaute ``ModelReference``-Werte
/// entgegen statt sie selbst zu erzeugen. `ModelReference.init` liest `.id` —
/// wird das erst NACH einem `await` (Geocoding, Lease-Erwerb) getan, kann eine
/// zwischenzeitlich per Sync-Tombstone gelöschte Referenz zum SwiftData-
/// Fatal-Error führen (gleiche Bug-Klasse wie GitHub #100). Der Aufrufer
/// (``BelegScanView/uebernehmen()``) baut die Referenzen deshalb GANZ AM
/// ANFANG, vor jedem `await`, und ruft diese Funktion erst im
/// `DatabaseLeaseService.performMicroLease`-Block auf.
enum BelegUebernahmeService {
    /// Führt die eigentliche Übernahme durch — Aufrufer trägt die Verantwortung,
    /// dies innerhalb eines `DatabaseLeaseService.performMicroLease`-Blocks
    /// aufzurufen (siehe Typ-Doku).
    @MainActor
    static func uebernehmen(
        kontext: BelegScanKontext,
        erkanntesGeschaeftReferenz: ModelReference<Geschaeft>?,
        einkaufsvorgangReferenz: ModelReference<Einkaufsvorgang>?,
        erkannterGeschaeftName: String,
        getrimmteErkannteAdresse: String,
        gelernteKoordinaten: (breitengrad: Double, laengengrad: Double)?,
        belegDatum: Date,
        positionen: [BearbeitbarePosition],
        positionsArtikelReferenzen: [ModelReference<Artikel>?],
        positionsProduktReferenzen: [ModelReference<Produkt>?],
        positionsKlarnamen: [String],
        context: ModelContext
    ) {
        let erkanntesGeschaeftFrisch = erkanntesGeschaeftReferenz?.resolved(in: context)
        let einkaufsvorgangFrisch = einkaufsvorgangReferenz?.resolved(in: context)

        if !erkannterGeschaeftName.isEmpty {
            erkanntesGeschaeftFrisch?.alternativenNamenLernen(erkannterGeschaeftName)
        }
        // Hat das zugeordnete Geschäft noch keine Adresse, wird die auf dem
        // Beleg erkannte übernommen (GitHub #19) — unabhängig davon, ob das
        // Geschäft automatisch oder manuell über `GeschaeftWahlSheet`
        // zugeordnet wurde.
        if let erkanntesGeschaeftFrisch, erkanntesGeschaeftFrisch.adresse == nil, !getrimmteErkannteAdresse.isEmpty {
            erkanntesGeschaeftFrisch.adresse = getrimmteErkannteAdresse
            if let gelernteKoordinaten {
                erkanntesGeschaeftFrisch.breitengrad = gelernteKoordinaten.breitengrad
                erkanntesGeschaeftFrisch.laengengrad = gelernteKoordinaten.laengengrad
            }
        }

        if let einkaufsvorgangFrisch, einkaufsvorgangFrisch.geschaeft == nil {
            einkaufsvorgangFrisch.geschaeft = erkanntesGeschaeftFrisch
        }

        for (index, position) in positionen.enumerated() {
            let name = position.artikelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let erkannterName = position.erkannterName.trimmingCharacters(in: .whitespacesAndNewlines)
            let getrimmterProduktKlarname = positionsKlarnamen[index]
            let produktName: String? = erkannterName.isEmpty ? nil : erkannterName
            // Klarname als alternativerName → in `Preispunkt.anzeigeName` gegenüber dem
            // abgekürzten Bon-Text (`produktName`) bevorzugt (GitHub #121).
            let neuerAlternativerName = leiteAlternativenNamenAb(
                eingegeben: getrimmterProduktKlarname.isEmpty ? erkannterName : getrimmterProduktKlarname,
                erkannt: erkannterName
            )
            guard !name.isEmpty,
                  let preis = PreisEingabeFormat.decimal(ausText: position.preisText)
            else { continue }
            let artikel = positionsArtikelReferenzen[index]?.resolved(in: context)
            var produkt = positionsProduktReferenzen[index]?.resolved(in: context)

            let geschaeftFuerPreispunkt: Geschaeft
            switch kontext {
            case .einkaufsvorgang:
                // Der Einkaufsvorgang selbst kann inzwischen gelöscht worden
                // sein (siehe oben) — dann fehlt jeder Bezug für diese
                // Position, sie wird übersprungen statt einen losgelösten
                // Kaufeintrag anzulegen. Ebenso, falls das soeben zugewiesene
                // Geschäft zwischenzeitlich gelöscht wurde (Geschäfts-Pflicht).
                guard let einkaufsvorgangFrisch, let vorgangGeschaeft = einkaufsvorgangFrisch.geschaeft else { continue }
                geschaeftFuerPreispunkt = vorgangGeschaeft
                // Nur die operative Buchungszeile: existiert bereits ein
                // passender ``KaufEintrag`` (Artikel wurde auf der Liste
                // abgehakt), bleibt er unverändert bis auf das vom Beleg
                // erkannte Datum — die Preisrolle übernimmt ausschließlich
                // ``PreispunktService`` unten. Kein Treffer → neuer,
                // rein operativer Eintrag ohne Preisfelder (z.B. Spontankauf,
                // der nicht auf der Liste stand).
                if let vorhandenerEintrag = einkaufsvorgangFrisch.kaufEintraege.first(where: { passtZu(name: name, eintrag: $0) }) {
                    vorhandenerEintrag.datum = belegDatum
                } else {
                    let neuerEintrag = KaufEintrag(
                        artikel: artikel,
                        geschaeft: einkaufsvorgangFrisch.geschaeft,
                        kategorie: artikel?.fuehrendeKategorie(inGeschaeft: einkaufsvorgangFrisch.geschaeft, context: context),
                        datum: belegDatum
                    )
                    neuerEintrag.artikelNameSnapshot = artikel?.name ?? name
                    context.insert(neuerEintrag)
                    neuerEintrag.einkaufsvorgang = einkaufsvorgangFrisch
                }
            case .geschaeft, .unbekannt:
                // Kein laufender Einkauf, also keine operative Rolle — hier
                // entsteht ausschließlich ein ``Preispunkt``, kein ``KaufEintrag``.
                // Geschäfts-Pflicht: ohne (noch aufgelöstes) Geschäft keine Position.
                guard let erkanntesGeschaeftFrisch else { continue }
                geschaeftFuerPreispunkt = erkanntesGeschaeftFrisch
            }

            // Folgearbeit zu GitHub #47/#116: nur ein bereits bekannter
            // Produktname-Treffer bringt an dieser Stelle schon ein
            // `produkt` mit (siehe ``ArtikelZuordnungsService``). Bei
            // Substring-/KI-Treffer oder manueller Artikel-Zuweisung ohne
            // Produktwahl sonst automatisch ein neues, eigenständiges
            // Produkt auflösen/anlegen statt im geteilten Standardprodukt
            // des Artikels zu landen — siehe `docs/ARTIKEL_PRODUKT_MODELL.md`
            // → „Automatische Neuanlage beim Belegscan”. Legt bei Bedarf
            // auch gleich den passenden ``Produktname`` an (GitHub #128) —
            // ersetzt das frühere separate ``ArtikelAlias/lernen(...)``.
            if produkt == nil, let artikel {
                let klarname = getrimmterProduktKlarname.isEmpty ? erkannterName : getrimmterProduktKlarname
                produkt = Produkt.aufgeloestesOderNeuesProdukt(
                    klarname: klarname, erkannterName: erkannterName, artikel: artikel,
                    geschaeft: geschaeftFuerPreispunkt, context: context
                )
            }
            // Produkt-Pflicht (siehe ``Preispunkt``-Typ-Doku): ohne Artikel-
            // Zuordnung entsteht kein Produkt, also auch kein Preispunkt für
            // diese Position — die operative ``KaufEintrag``-Buchungszeile
            // oben bleibt davon unberührt.
            guard let produktFuerPreispunkt = produkt else { continue }

            // Tages-Kollision (GitHub #76-Folgearbeit): Anwender hat „Bisherigen
            // behalten" gewählt → kein neuer Preispunkt für diese Position.
            // Sonst (Standard „wird ersetzt") den bestehenden Tagespunkt zuerst
            // entfernen, statt beide nebeneinander bestehen zu lassen.
            let behalteBestehenden = position.bestehenderPreisHeute != nil && position.behalteBestehendenPreisHeute
            if position.bestehenderPreisHeute != nil, !behalteBestehenden,
               let vorhandenerPunkt = PreispunktService.vorhandenerPunktHeute(
                   produkt: produktFuerPreispunkt, geschaeft: geschaeftFuerPreispunkt, amDatum: belegDatum, context: context
               ) {
                PreispunktService.ersetzeVorhandenenPunkt(vorhandenerPunkt, context: context)
            }
            if !behalteBestehenden {
                PreispunktService.erfassen(
                    preis: preis, produkt: produktFuerPreispunkt, geschaeft: geschaeftFuerPreispunkt, datum: belegDatum,
                    produktName: produktName, alternativerName: neuerAlternativerName, context: context
                )
            }
        }
    }

    /// Der Text im „Artikel“-Feld weicht vom rohen erkannten Namen ab (manuell
    /// korrigiert) → als ``Preispunkt/alternativerName`` übernehmen, damit die
    /// Preishistorie den vom Nutzer bestätigten Namen statt des rohen Bon-Texts
    /// anzeigt (siehe ``Preispunkt/anzeigeName``).
    private static func leiteAlternativenNamenAb(eingegeben: String, erkannt: String) -> String? {
        guard !erkannt.isEmpty, eingegeben.localizedCaseInsensitiveCompare(erkannt) != .orderedSame else { return nil }
        return eingegeben
    }

    private static func passtZu(name: String, eintrag: KaufEintrag) -> Bool {
        let artikelName = eintrag.artikelNameSicher
        guard !artikelName.isEmpty else { return false }
        return artikelName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(artikelName)
    }
}
