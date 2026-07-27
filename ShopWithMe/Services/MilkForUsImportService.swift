import Foundation
import SwiftUI
import SwiftData

/// Ein einzelner Artikel-Eintrag aus einer MilkForUs-Textexport-Datei, zusammen mit
/// dem Namen der Kategorie, unter der er in der Datei stand.
struct MilkForUsEintrag: Equatable {
    let kategorieName: String
    let artikelName: String
}

/// Parst das einfache Textformat des MilkForUs-Exports: Kategorienamen stehen allein
/// auf einer Zeile, darunter folgen `- Artikel`-Zeilen, Blöcke sind durch Leerzeilen
/// getrennt (siehe `docs/MILKFORUS_IMPORT.md`).
enum MilkForUsParser {
    /// Zerlegt `text` in einzelne Artikel-Einträge. Leere Zeilen werden ignoriert.
    /// Artikel, die vor der ersten Kategorie-Überschrift stehen, bekommen den leeren
    /// Kategorienamen `""` (wird beim Import auf "Sonstiges" abgebildet).
    static func parsen(text: String) -> [MilkForUsEintrag] {
        var ergebnis: [MilkForUsEintrag] = []
        var aktuelleKategorie = ""
        for rohzeile in text.components(separatedBy: .newlines) {
            let zeile = rohzeile.trimmingCharacters(in: .whitespaces)
            guard !zeile.isEmpty else { continue }
            if zeile.hasPrefix("-") {
                let name = zeile.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                ergebnis.append(MilkForUsEintrag(kategorieName: aktuelleKategorie, artikelName: name))
            } else {
                aktuelleKategorie = zeile
            }
        }
        return ergebnis
    }
}

/// Wie eine importierte MilkForUs-Kategorie auf den ShopWithMe-Kategoriebestand
/// abgebildet wird.
enum KategorieZuordnung: Equatable {
    /// Eine bereits vorhandene Kategorie wird verwendet (exakter Namenstreffer oder
    /// ein von der KI vorgeschlagener bzw. vom Nutzer gewählter Treffer).
    case bestehend(ArtikelKategorie)
    /// Es wird beim Übernehmen eine neue Kategorie mit diesem Namen angelegt.
    case neuAnlegen(name: String)
    /// Die Artikel dieser Gruppe werden ``ArtikelKategorie/sonstige(context:)`` zugeordnet.
    case sonstige

    static func == (lhs: KategorieZuordnung, rhs: KategorieZuordnung) -> Bool {
        switch (lhs, rhs) {
        case let (.bestehend(a), .bestehend(b)): return a.id == b.id
        case let (.neuAnlegen(a), .neuAnlegen(b)): return a == b
        case (.sonstige, .sonstige): return true
        default: return false
        }
    }
}

/// Eine Gruppe von importierten Artikeln, die in der MilkForUs-Datei unter demselben
/// Kategorienamen standen, zusammen mit dem aktuellen Zuordnungsvorschlag. Sowohl
/// ``zuordnung`` als auch ``artikelNamen`` sind von der Vorschau-UI editierbar,
/// bevor ``MilkForUsImportService/uebernehmen(gruppen:in:context:)`` aufgerufen wird.
struct MilkForUsKategorieGruppe: Identifiable {
    var id: String { kategorieName }
    let kategorieName: String
    var zuordnung: KategorieZuordnung
    var artikelNamen: [String]
}

/// Kernlogik des MilkForUs-Textimports: Kategorie-Abgleich (exakt, dann KI-Best-Match,
/// dann "neu anlegen") und die abschließende Übernahme in den Datenbestand.
enum MilkForUsImportService {
    /// Baut aus den geparsten Einträgen Gruppen je (distinktem) Kategorienamen, in
    /// der Reihenfolge ihres ersten Auftretens in der Datei, und schlägt für jede
    /// Gruppe eine ``KategorieZuordnung`` vor.
    @MainActor
    static func gruppenMitVorschlag(
        aus eintraege: [MilkForUsEintrag],
        bestehendeKategorien: [ArtikelKategorie]
    ) async -> [MilkForUsKategorieGruppe] {
        var reihenfolge: [String] = []
        var artikelNachKategorie: [String: [String]] = [:]
        for eintrag in eintraege {
            if artikelNachKategorie[eintrag.kategorieName] == nil {
                reihenfolge.append(eintrag.kategorieName)
                artikelNachKategorie[eintrag.kategorieName] = []
            }
            artikelNachKategorie[eintrag.kategorieName]?.append(eintrag.artikelName)
        }

        var gruppen: [MilkForUsKategorieGruppe] = []
        for name in reihenfolge {
            let zuordnung = await vorschlag(fuerKategorieName: name, bestehendeKategorien: bestehendeKategorien)
            gruppen.append(MilkForUsKategorieGruppe(
                kategorieName: name,
                zuordnung: zuordnung,
                artikelNamen: artikelNachKategorie[name] ?? []
            ))
        }
        return gruppen
    }

    /// Ermittelt die Zuordnung für einen einzelnen MilkForUs-Kategorienamen: exakter,
    /// Groß-/Kleinschreibung ignorierender Treffer zuerst, sonst — falls auf dem
    /// Gerät verfügbar — ein KI-basierter Best-Match gegen die bestehenden
    /// Kategorien (siehe ``AISuggestionService/kategorieMatch(fuerName:bekannteKategorien:)``),
    /// sonst der Vorschlag, die Kategorie neu anzulegen. Der Nutzer kann jeden
    /// Vorschlag in der Vorschau noch auf "Sonstiges" oder eine andere bestehende
    /// Kategorie umstellen.
    @MainActor
    static func vorschlag(
        fuerKategorieName name: String,
        bestehendeKategorien: [ArtikelKategorie]
    ) async -> KategorieZuordnung {
        // Artikel ohne erkennbare Kategorie (z.B. vor der ersten Überschrift in der
        // Datei, siehe ``MilkForUsParser``) bekommen direkt "Sonstiges" statt einer
        // sinnlosen neuen Kategorie mit leerem Namen.
        guard !name.isEmpty else { return .sonstige }
        if let treffer = bestehendeKategorien.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return .bestehend(treffer)
        }
        guard AISuggestionService.istVerfuegbar else {
            return .neuAnlegen(name: name)
        }
        guard let kiVorschlag = try? await AISuggestionService.kategorieMatch(
            fuerName: name,
            bekannteKategorien: bestehendeKategorien.map(\.name)
        ) else {
            return .neuAnlegen(name: name)
        }
        if let treffer = bestehendeKategorien.first(where: {
            $0.name.localizedCaseInsensitiveCompare(kiVorschlag.passendeKategorie) == .orderedSame
        }) {
            return .bestehend(treffer)
        }
        return .neuAnlegen(name: name)
    }

    /// Übernimmt die Gruppen (nach ggf. manueller Korrektur von ``zuordnung``/
    /// ``artikelNamen`` durch den Nutzer) in einem einzigen Lease-geschützten
    /// Schreibvorgang: legt neue Kategorien an (Default-Symbol/-Farbe, siehe
    /// ``NeueKategorieSheet``), findet oder erstellt je Artikelname einen ``Artikel``
    /// (bestehende Artikel bleiben inklusive ihrer Kategorie unangetastet und werden
    /// nur auf ``einkaufsliste`` gesetzt) und ruft dafür
    /// ``Einkaufsliste/artikelHinzufuegen(_:context:)`` auf. Gruppen ohne verbliebene
    /// Artikelnamen (z.B. weil der Nutzer alle in der Vorschau entfernt hat) werden
    /// übersprungen, damit keine ungenutzten neuen Kategorien entstehen.
    @MainActor
    static func uebernehmen(
        gruppen: [MilkForUsKategorieGruppe],
        in einkaufsliste: Einkaufsliste,
        context: ModelContext
    ) async {
        await DatabaseLeaseService.performMicroLease(context: context) {
            var naechsterSortIndex = ((try? context.fetch(FetchDescriptor<ArtikelKategorie>()))?.map(\.sortIndex).max() ?? -1) + 1
            // `var` statt `let`: derselbe Artikelname kann in mehreren Gruppen
            // dieses Imports auftauchen — neu angelegte Artikel werden unten
            // sofort ergänzt, damit eine zweite Fundstelle im selben Aufruf sie
            // wiederverwendet statt ein Duplikat anzulegen.
            var alleArtikel = (try? context.fetch(FetchDescriptor<Artikel>())) ?? []

            for gruppe in gruppen where !gruppe.artikelNamen.isEmpty {
                let kategorie: ArtikelKategorie
                switch gruppe.zuordnung {
                case .bestehend(let bestehende):
                    kategorie = bestehende
                case .sonstige:
                    kategorie = ArtikelKategorie.sonstige(context: context)
                case .neuAnlegen(let name):
                    let neue = ArtikelKategorie(
                        name: name,
                        standardSymbol: "shippingbox.fill",
                        standardFarbeHex: Color.artikelPalette[0],
                        sortIndex: naechsterSortIndex
                    )
                    naechsterSortIndex += 1
                    context.insert(neue)
                    kategorie = neue
                }

                for artikelName in gruppe.artikelNamen {
                    let artikel = alleArtikel.first {
                        $0.name.localizedCaseInsensitiveCompare(artikelName) == .orderedSame
                    } ?? {
                        let neuer = Artikel(
                            name: artikelName,
                            symbolName: SymbolPalette.alle[0],
                            farbeHex: Color.artikelPalette[0],
                            kategorien: [kategorie]
                        )
                        context.insert(neuer)
                        alleArtikel.append(neuer)
                        return neuer
                    }()
                    einkaufsliste.artikelHinzufuegen(artikel, context: context)
                }
            }
        }
    }
}
