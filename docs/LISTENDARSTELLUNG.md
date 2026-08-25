# ShopWithMe — Konfigurierbare Listendarstellung

Entscheidungsdokument und Architekturüberblick für das modulare
Darstellungssystem der Einkaufsliste (eingeführt v0.15).

## Ziel

Der feste `List/Section/ArtikelAbhakZeile`-Block in `EinkaufslisteView` wurde
durch ein konfigurierbares, via `@AppStorage` persistiertes Variantensystem ersetzt.
Neue Varianten lassen sich ohne Änderung an `EinkaufenView` ergänzen.

## Dateien

| Datei | Inhalt |
|---|---|
| `Views/Einkaufen/EinkaufslisteDarstellungsModus.swift` | Enums + `DarstellungsKey`-Konstanten |
| `Views/Einkaufen/EinkaufslisteDarstellungsView.swift` | Dispatcher + `ListenInhaltView` + `KachelInhaltView` |
| `Views/Einstellungen/EinkaufslisteDarstellungsSettingsView.swift` | Einstellungs-UI |
| `DesignSystem/ChipFlowLayout.swift` | Wiederverwendbares Flow-Layout für Chips |

## Darstellungsmodi

### Modus: Liste (`EinkaufslisteDarstellungsModus.liste`)

`ListenInhaltView` liest `@AppStorage(DarstellungsKey.listenTyp)` und wählt
zwischen drei Untertypen:

| `ListenAnzeigeTyp` | Rendering | Accordion | Farbstreifen |
|---|---|---|---|
| `.klassisch` | `List` + `Section` + `ArtikelAbhakZeile` | ✓ (via `DisclosureGroup`) | ✓ (4 px Balken links) |
| `.chipsGross` | `ScrollView` + `ChipFlowLayout` | ✓ (via `DisclosureGroup`) | — |
| `.chipsKlein` | `ScrollView` + `ChipFlowLayout` | ✓ (via `DisclosureGroup`) | — |

Große Chips verzichten **bewusst** auf ein Abteilung-Icon — mehr Chips pro Zeile
bei gleicher Lesbarkeit; das Abhak-Häkchen übernimmt die Statuskommunikation.

Der optionale Fortschrittsbalken wird als `.safeAreaInset(edge: .top)` eingehängt
(beide Varianten klassisch und Chips).

Akkordeon-Zustand: `@State private var geschlosseneAbteilungen: Set<PersistentIdentifier>`
(invertierte Logik: leer = alle offen), weil `gruppen` zur Initialisierungszeit
noch nicht zugänglich ist und `init()`-captures von `let`-Properties Compiler-Fehler
erzeugen würden.

### Modus: Kacheln (`EinkaufslisteDarstellungsModus.kacheln`)

`KachelInhaltView` rendert Artikel abteilung-übergreifend als flaches `LazyVGrid`
(2 oder 3 Spalten). Artikel, die mehreren `AbteilungGruppe`n angehören, werden
per `Set<PersistentIdentifier>` dedupliziert — jeder Artikel erscheint genau
einmal. Optionaler Abteilung-Farbhintergrund (`farbig`-Flag): weiße Schrift auf
Abteilung-Farbton statt neutralem Systemhintergrund.

## AppStorage-Schlüssel (`DarstellungsKey`)

```swift
static let modus        = "listendarst.modus"        // EinkaufslisteDarstellungsModus
static let listenTyp    = "listendarst.liste.typ"    // ListenAnzeigeTyp
static let akkordeon    = "listendarst.liste.akkordeon"    // Bool
static let fortschritt  = "listendarst.liste.fortschritt"  // Bool
static let farbstreifen = "listendarst.liste.farbstreifen" // Bool (nur klassisch)
static let spalten      = "listendarst.kacheln.spalten"    // KachelSpaltenanzahl.rawValue
static let farbig       = "listendarst.kacheln.farbig"     // Bool
```

Alle Defaults sind `false`/`.liste`/`.klassisch`/`.zwei`, damit ein Erststart ohne
gespeicherte Einstellungen identisch zur bisherigen klassischen Listenansicht aussieht.

## Farbstreifen + `listRowInsets`

Bei aktiviertem Farbstreifen (nur klassisch) erhält `ArtikelAbhakZeile` eine
`abteilungfarbe: Color?`-Property. Das äußere `body` der Zeile überschreibt in
diesem Fall `.listRowInsets(EdgeInsets(top:0, leading:0, bottom:0, trailing:16))`
damit der 4 px-Streifen bündig am linken Rand liegt. Der eigentliche
Row-Inhalt (`zeilenInhalt`) erhält dann `padding(.leading, 12)` als Ausgleich.

## Erweiterung für neue Varianten

1. Neuen `case` in `EinkaufslisteDarstellungsModus` ergänzen.
2. Renderer-Struct anlegen (analog `ListenInhaltView`/`KachelInhaltView`).
3. `switch`-Fall in `EinkaufslisteDarstellungsView.body` ergänzen.
4. Einstellungs-Section in `EinkaufslisteDarstellungsSettingsView` ergänzen.
5. Falls nötig: neuen `DarstellungsKey`-Eintrag ergänzen.

`EinkaufenView` selbst bleibt unberührt — der Dispatcher-Aufruf
`EinkaufslisteDarstellungsView(...)` ist der einzige Einstiegspunkt.

## Datenvertrag: `AbteilungGruppe`

```swift
struct AbteilungGruppe: Identifiable {
    struct Element: Identifiable {
        var id: PersistentIdentifier
        var artikel: Artikel
        var eintrag: EinkaufslistenEintrag?  // nil = bereits abgehakt
    }
    let abteilung: Abteilung
    var elemente: [Element]
    var id: PersistentIdentifier { abteilung.persistentModelID }
    var istVollstaendigAbgehakt: Bool { ... }  // siehe unten, GitHub #176
}
```

Definiert in `EinkaufenView.swift` (nicht `private`) und von
`EinkaufslisteDarstellungsView.swift` als Eingabe-Typ verwendet.
`ArtikelAbhakZeile` und `EinkaufslistenSektionHeader` sind ebenfalls auf
`internal`-Access-Level gehoben, damit der neue Renderer sie direkt nutzen kann.

## Artikel-Sortierung innerhalb einer Gruppe (GitHub #176)

`EinkaufslistenAnzeigeService.abteilungGruppen(...)` sortiert `elemente` je
Gruppe: offene Artikel vor bereits abgehakten, innerhalb beider Blöcke
alphabetisch (`String.vergleicheAlphabetisch(mit:)`). Zusätzlich wandert eine
Gruppe ohne verbleibenden offenen Artikel (`AbteilungGruppe.istVollstaendigAbgehakt`)
ans Ende der Gesamtliste — als stabiler Zusatzschritt NACH der eigentlichen
Bereichs-Sortierung (alphabetisch bzw. `AbteilungsDistanzService`-Distanzmatrix,
siehe `docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`), sodass deren
Reihenfolge unter den jeweils verbleibenden Gruppen unangetastet bleibt. Da
`EinkaufslisteDarstellungsView` `gruppe.elemente` nur unverändert rendert,
wirkt sich das automatisch auf alle Darstellungsmodi (Klassisch/Chips/Kacheln)
aus, ohne dass die Renderer selbst etwas davon wissen müssen.
