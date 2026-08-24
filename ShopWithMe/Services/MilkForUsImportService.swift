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
    /// Sendable-sicheres Zwischenergebnis der Kategorie-Vorschlagslogik — trägt nur
    /// den Namen einer eventuell gefundenen bestehenden Kategorie, nicht das
    /// ``ArtikelKategorie``-Objekt selbst. Grundlage für ``vorschlagsName(fuerKategorieName:bekannteKategorienNamen:)``,
    /// das (anders als ``vorschlag(fuerKategorieName:bestehendeKategorien:)``) aus einer
    /// parallelen `Task`-Gruppe heraus aufgerufen werden kann — ``ArtikelKategorie``
    /// ist als SwiftData-`@Model`-Referenztyp nicht `Sendable` und dürfte eine
    /// Task-Grenze nicht direkt überqueren.
    private enum VorschlagsName: Sendable {
        case bestehenderName(String)
        case neuAnlegen(name: String)
        case sonstige
    }

    /// Bildet ein ``VorschlagsName``-Ergebnis auf die eigentliche ``KategorieZuordnung``
    /// mit dem `ArtikelKategorie`-Objekt ab — reiner Namens-Lookup in
    /// `bestehendeKategorien`, keine weitere `await`-Grenze.
    @MainActor
    private static func zuordnung(fuer ergebnis: VorschlagsName, in bestehendeKategorien: [ArtikelKategorie]) -> KategorieZuordnung {
        switch ergebnis {
        case .sonstige:
            return .sonstige
        case .neuAnlegen(let name):
            return .neuAnlegen(name: name)
        case .bestehenderName(let name):
            guard let treffer = bestehendeKategorien.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                return .neuAnlegen(name: name)
            }
            return .bestehend(treffer)
        }
    }

    /// Kern der Vorschlagslogik (siehe ``vorschlag(fuerKategorieName:bestehendeKategorien:)``
    /// für die vollständige Beschreibung) — arbeitet bewusst nur mit Kategorie-
    /// NAMEN statt `ArtikelKategorie`-Objekten, damit dieser Teil `nonisolated`
    /// bleiben und aus mehreren parallelen `Task`s gleichzeitig aufgerufen werden
    /// kann (siehe ``gruppenMitVorschlag(aus:bestehendeKategorien:fortschritt:)``).
    private static func vorschlagsName(
        fuerKategorieName name: String,
        bekannteKategorienNamen: [String]
    ) async -> VorschlagsName {
        guard !name.isEmpty else { return .sonstige }
        if let treffer = bekannteKategorienNamen.first(where: {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return .bestehenderName(treffer)
        }
        guard AISuggestionService.istVerfuegbar else {
            return .neuAnlegen(name: name)
        }
        guard let kiVorschlag = try? await AISuggestionService.kategorieMatch(
            fuerName: name,
            bekannteKategorien: bekannteKategorienNamen
        ) else {
            return .neuAnlegen(name: name)
        }
        if let treffer = bekannteKategorienNamen.first(where: {
            $0.localizedCaseInsensitiveCompare(kiVorschlag.passendeKategorie) == .orderedSame
        }) {
            return .bestehenderName(treffer)
        }
        return .neuAnlegen(name: name)
    }

    /// Baut aus den geparsten Einträgen Gruppen je (distinktem) Kategorienamen, in
    /// der Reihenfolge ihres ersten Auftretens in der Datei, und schlägt für jede
    /// Gruppe eine ``KategorieZuordnung`` vor.
    ///
    /// **Performance (Nutzerbericht 2026-08-24, sehr große MilkForUs-Listen):** die
    /// KI-Abfrage je Kategorie (``vorschlagsName(fuerKategorieName:bekannteKategorienNamen:)``)
    /// lief vorher streng sequenziell — bei vielen Abteilungen in einer großen
    /// Liste summierte sich das spürbar. Läuft jetzt mit bis zu `maxGleichzeitig`
    /// Kategorien parallel über eine `TaskGroup`, Ergebnis-Reihenfolge bleibt über
    /// den Index erhalten. `fortschritt` (optional) meldet nach jeder fertigen
    /// Kategorie `(erledigt, gesamt)` — Grundlage für die Fortschrittsanzeige in
    /// ``MilkForUsImportView``.
    @MainActor
    static func gruppenMitVorschlag(
        aus eintraege: [MilkForUsEintrag],
        bestehendeKategorien: [ArtikelKategorie],
        fortschritt: ((Int, Int) -> Void)? = nil
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

        let gesamt = reihenfolge.count
        guard gesamt > 0 else { return [] }
        fortschritt?(0, gesamt)

        let bekannteKategorienNamen = bestehendeKategorien.map(\.name)
        var ergebnisse = [VorschlagsName?](repeating: nil, count: gesamt)
        var erledigt = 0
        let maxGleichzeitig = 4
        await withTaskGroup(of: (Int, VorschlagsName).self) { group in
            var naechsterIndex = 0
            func naechstenStarten() {
                guard naechsterIndex < gesamt else { return }
                let index = naechsterIndex
                let name = reihenfolge[index]
                naechsterIndex += 1
                group.addTask {
                    (index, await vorschlagsName(fuerKategorieName: name, bekannteKategorienNamen: bekannteKategorienNamen))
                }
            }
            for _ in 0..<min(maxGleichzeitig, gesamt) { naechstenStarten() }
            while let (index, ergebnis) = await group.next() {
                ergebnisse[index] = ergebnis
                erledigt += 1
                fortschritt?(erledigt, gesamt)
                naechstenStarten()
            }
        }

        return reihenfolge.enumerated().map { index, name in
            MilkForUsKategorieGruppe(
                kategorieName: name,
                zuordnung: zuordnung(fuer: ergebnisse[index] ?? .neuAnlegen(name: name), in: bestehendeKategorien),
                artikelNamen: artikelNachKategorie[name] ?? []
            )
        }
    }

    /// Ermittelt die Zuordnung für einen einzelnen MilkForUs-Kategorienamen: exakter,
    /// Groß-/Kleinschreibung ignorierender Treffer zuerst, sonst — falls auf dem
    /// Gerät verfügbar — ein KI-basierter Best-Match gegen die bestehenden
    /// Kategorien (siehe ``AISuggestionService/kategorieMatch(fuerName:bekannteKategorien:)``),
    /// sonst der Vorschlag, die Kategorie neu anzulegen. Der Nutzer kann jeden
    /// Vorschlag in der Vorschau noch auf "Sonstiges" oder eine andere bestehende
    /// Kategorie umstellen. Dünner Wrapper um ``vorschlagsName(fuerKategorieName:bekannteKategorienNamen:)``
    /// — eigenständig gehalten (statt nur intern verwendet), weil bestehende Tests
    /// direkt gegen diese Signatur mit `KategorieZuordnung`-Rückgabewert prüfen.
    @MainActor
    static func vorschlag(
        fuerKategorieName name: String,
        bestehendeKategorien: [ArtikelKategorie]
    ) async -> KategorieZuordnung {
        let ergebnis = await vorschlagsName(fuerKategorieName: name, bekannteKategorienNamen: bestehendeKategorien.map(\.name))
        return zuordnung(fuer: ergebnis, in: bestehendeKategorien)
    }

    /// Ein einzelner Artikel innerhalb einer Gruppe, zusammen mit deren Identität
    /// (``MilkForUsKategorieGruppe/id``) und Kategorie-Zuordnung — Grundlage für
    /// die in ``uebernehmen(gruppen:in:context:fortschritt:)`` über alle Gruppen
    /// hinweg flach durchnummerierte, in Chunks verarbeitete Arbeitsliste.
    private struct Arbeitsschritt {
        let gruppenID: String
        let zuordnung: KategorieZuordnung
        let artikelName: String
    }

    /// Übernimmt die Gruppen (nach ggf. manueller Korrektur von ``zuordnung``/
    /// ``artikelNamen`` durch den Nutzer): legt neue Kategorien an (Default-Symbol/
    /// -Farbe, siehe ``NeueAbteilungSheet``), findet oder erstellt je Artikelname
    /// einen ``Artikel`` (bestehende Artikel bleiben inklusive ihrer Kategorie
    /// unangetastet und werden nur auf ``einkaufsliste`` gesetzt) und ruft dafür
    /// ``Einkaufsliste/artikelHinzufuegen(_:context:)`` auf. Gruppen ohne verbliebene
    /// Artikelnamen (z.B. weil der Nutzer alle in der Vorschau entfernt hat) werden
    /// übersprungen, damit keine ungenutzten neuen Kategorien entstehen.
    ///
    /// **Performance (Nutzerbericht 2026-08-24, sehr große MilkForUs-Listen):**
    /// vorher wurde für JEDEN importierten Artikelnamen der komplette bestehende
    /// Artikelbestand linear durchsucht (`alleArtikel.first { ... }`) — bei
    /// mehreren hundert bestehenden Artikeln und ebenso vielen zu importierenden
    /// spürbar langsam. Jetzt einmalig nach kleingeschriebenem Namen indiziert
    /// (dieselbe Normalisierung wie bereits in ``MilkForUsImportView`` für die
    /// „vorhanden"/„neu"-Anzeige verwendet) — O(1) statt O(n) Nachschlag je Artikel.
    ///
    /// **Chunking statt eines einzigen Lease-Blocks:** ein einziger Micro-Lease
    /// über eine sehr große Liste hinweg würde ihn entgegen seinem eigentlichen
    /// Zweck ("Sekundenbruchteile", siehe `docs/DATABASE_CONCURRENCY.md`) unnötig
    /// lange halten — und die Fortschrittsanzeige könnte nie zwischenzeitlich neu
    /// zeichnen, da der komplette Schreibvorgang sonst ohne einen einzigen
    /// Suspension-Point synchron durchliefe. Läuft daher in Chunks à
    /// `chunkGroesse` Artikeln, je einem eigenen kurzen Micro-Lease — `fortschritt`
    /// (optional) meldet nach jedem Chunk `(erledigt, gesamt)` in Artikeln.
    @MainActor
    static func uebernehmen(
        gruppen: [MilkForUsKategorieGruppe],
        in einkaufsliste: Einkaufsliste,
        context: ModelContext,
        fortschritt: ((Int, Int) -> Void)? = nil
    ) async {
        let arbeit: [Arbeitsschritt] = gruppen.flatMap { gruppe in
            gruppe.artikelNamen.map { Arbeitsschritt(gruppenID: gruppe.id, zuordnung: gruppe.zuordnung, artikelName: $0) }
        }
        let gesamt = arbeit.count
        guard gesamt > 0 else { return }
        fortschritt?(0, gesamt)

        // Nur die Identität über die `await`-Grenze hinweg sichern (siehe
        // ``ModelReference``) — der Anwender kann zwischen Datei-Auswahl und
        // "Übernehmen" beliebig lange in der Vorschau verweilen, und über die
        // gesamte, jetzt in Chunks verteilte Dauer des Übernehmens hinweg könnte
        // die Zielliste anderweitig gelöscht werden.
        let einkaufslisteReferenz = ModelReference(einkaufsliste)
        var naechsterSortIndex = ((try? context.fetch(FetchDescriptor<ArtikelKategorie>()))?.map(\.sortIndex).max() ?? -1) + 1
        var artikelNachName: [String: Artikel] = Dictionary(
            ((try? context.fetch(FetchDescriptor<Artikel>())) ?? []).map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { erster, _ in erster }
        )
        // Pro Gruppe (Schlüssel ``MilkForUsKategorieGruppe/id``) einmalig
        // aufgelöste Kategorie — verhindert, dass eine `.neuAnlegen`-Gruppe, deren
        // Artikel sich über mehrere Chunks verteilen, dieselbe neue Kategorie
        // mehrfach anlegt.
        var kategorieProGruppenID: [String: ArtikelKategorie] = [:]

        let chunkGroesse = 25
        var erledigt = 0
        for start in stride(from: 0, to: gesamt, by: chunkGroesse) {
            let chunk = arbeit[start..<min(start + chunkGroesse, gesamt)]
            var listeVorhanden = false
            await DatabaseLeaseService.performMicroLease(context: context) {
                guard let einkaufslisteFrisch = einkaufslisteReferenz.resolved(in: context) else { return }
                listeVorhanden = true

                for schritt in chunk {
                    let kategorie: ArtikelKategorie
                    if let bestehende = kategorieProGruppenID[schritt.gruppenID] {
                        kategorie = bestehende
                    } else {
                        switch schritt.zuordnung {
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
                        kategorieProGruppenID[schritt.gruppenID] = kategorie
                    }

                    let schluessel = schritt.artikelName.lowercased()
                    let artikel = artikelNachName[schluessel] ?? {
                        let neuer = Artikel(
                            name: schritt.artikelName,
                            symbolName: SymbolPalette.alle[0],
                            farbeHex: Color.artikelPalette[0],
                            kategorien: [kategorie]
                        )
                        context.insert(neuer)
                        artikelNachName[schluessel] = neuer
                        return neuer
                    }()
                    einkaufslisteFrisch.artikelHinzufuegen(artikel, context: context)
                }
            }
            // Zielliste inzwischen gelöscht — wie im ursprünglichen Verhalten
            // (ein einzelner Lease-Block, dessen `guard` beim Fehlschlagen den
            // gesamten Rest überspringt) restliche Chunks nicht mehr verarbeiten,
            // statt fälschlich Fortschritt für nie geschriebene Artikel zu melden.
            guard listeVorhanden else { break }
            erledigt += chunk.count
            fortschritt?(erledigt, gesamt)
        }
    }
}
