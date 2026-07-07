# ShopWithMe — Standort-basierte Ladenerkennung & Geschäftsverwaltung

Status: **Umgesetzt** (`Services/GeschaeftErkennungService.swift`,
`GeschaeftVorschlagBanner` in `Views/Einkaufen/EinkaufenView.swift`).

## Ausgangslage

Bislang musste das Geschäft beim Einkaufen immer manuell über den Picker in
`EinkaufenView` ausgewählt werden. `Geschaeft.breitengrad`/`laengengrad` existierten
zwar bereits am Modell, waren aber ungenutzt (siehe `docs/ROADMAP.md`, „Zukünftig“ vor
diesem Checkpoint).

## Verhalten

- **Wo:** Ein Banner (`GeschaeftVorschlagBanner`) oben in `EinkaufenView`, das nur
  erscheint, wenn tatsächlich ein relevanter Laden in der Nähe erkannt wurde — an
  Orten ohne bekannten Laden (z.B. zu Hause) wird bewusst nichts angezeigt.
- **Wann:** Einmalig beim Öffnen der Ansicht (`onAppear`), kein Hintergrund-Tracking.
  Wird kein bereits ausgewähltes Geschäft erneut vorgeschlagen.
- **Standort-Scope:** Ausschließlich `NSLocationWhenInUseUsageDescription`
  („Bei Nutzung erlauben“) — kein „Immer“-Zugriff, keine Hintergrundüberwachung, keine
  Push-Benachrichtigungen. Bewusste Entscheidung für minimalen Datenschutz-/
  Akku-Impact statt proaktivem Hintergrund-Erkennen.

## `GeschaeftErkennungService`

1. `EinmaligerStandortAbruf` (privat): kapselt eine einmalige `CLLocationManager`-
   Standortabfrage inkl. Berechtigungsanfrage (falls `.notDetermined`) hinter einer
   `async`-Schnittstelle, über `CheckedContinuation`.
2. `MKLocalPointsOfInterestRequest` (Radius `suchradius`, 150m) mit
   `MKPointOfInterestFilter` auf die für Einzelhandel relevanten
   `MKPointOfInterestCategory`-Werte (`relevanteKategorien`: `.foodMarket`, `.store`,
   `.pharmacy`, `.bakery`, `.winery`, `.brewery`) — bewusst ohne Restaurants, Museen,
   Tankstellen usw.
3. `passendenVorschlag(aus:standort:vorhandeneGeschaefte:)` (Matching-Logik, `internal`
   statt `private` für direkte Testbarkeit ohne echtes CoreLocation/MapKit):
   sortiert Treffer nach Entfernung, prüft zuerst auf ein bereits bekanntes
   `Geschaeft` (`istBekannterTreffer`: Namensübereinstimmung ODER Koordinaten
   innerhalb `koordinatenTreffertoleranz`, 75m — deckt eine spätere Umbenennung in der
   App ab), sonst wird der nächstgelegene Treffer als `.unbekannt(MKMapItem)`
   vorgeschlagen.

## UI-Fluss

- **Bekanntes Geschäft** (`.bekannt(Geschaeft)`): Banner-Button „Auswählen“ setzt es
  direkt als `ausgewaehltesGeschaeft` in `EinkaufenView`.
- **Unbekannter Laden** (`.unbekannt(MKMapItem)`): Banner-Button „Hinzufügen“ baut
  über `GeschaeftErkennungService.entwurf(aus:)` einen Geschäfts-Entwurf (Name,
  geschätzter `GeschaeftTyp` anhand der Apple-Maps-Kategorie, Adresse aus
  `MKPlacemark/title`, Koordinaten) und öffnet den bestehenden
  `GeschaeftStammdatenEditView`-Anlage-Flow (`istNeu: true`, wie bereits in
  `GeschaeftListView`). Neuer optionaler `onGespeichert`-Callback dort übernimmt das
  frisch angelegte Geschäft automatisch als `ausgewaehltesGeschaeft`.
- Ein „…“-Menü (`ellipsis.circle`) bietet drei Optionen: „Verwerfen“ (Banner
  verschwindet ohne Aktion, wird beim nächsten Aufruf ggf. erneut vorgeschlagen),
  „Diesen Laden ignorieren“ (siehe unten) und „Alle Geschäfte in der Nähe…“ (siehe
  unten).

## Vorschlag ignorieren

**Status: Umgesetzt** (`IgnorierterGeschaeftsVorschlag`, `Models/IgnorierterGeschaeftsVorschlag.swift`).

Manche in der Nähe erkannten Läden will der Anwender nie als Vorschlag sehen (z.B.
ein als `.store` kategorisierter Kiosk direkt neben der Wohnung). Anders als
„Verwerfen“ (nur für diesen einen Aufruf) ist „Ignorieren“ dauerhaft:

- Neues, eigenständiges Modell `IgnorierterGeschaeftsVorschlag` (`name`,
  optional `breitengrad`/`laengengrad`, `ignoriertAm`) — bewusst **ohne**
  Relationship zu `Geschaeft`, da auch noch nicht angelegte, per Apple Maps
  erkannte Läden (`.unbekannt(MKMapItem)`) ignoriert werden können. Additiv zu
  `SchemaV1.models` ergänzt (neue Modell-Klasse ohne Datentransformation
  bestehender Zeilen → keine neue `SchemaVN`/`MigrationStage` nötig, siehe
  `docs/DECISIONS.md`).
- `GeschaeftErkennungService.istIgnoriert(_:ignorierte:)` prüft Namens- ODER
  Koordinatenübereinstimmung (`koordinatenTreffertoleranz`, 75m) — analog
  `istBekannterTreffer(_:fuer:)`.
- `vorschlag(vorhandeneGeschaefte:ignorierteVorschlaege:)` sortiert ignorierte
  Treffer vor dem Matching aus, damit sie nie mehr automatisch als Banner
  erscheinen.
- `EinkaufenView.ignorierenVorschlag(_:)` legt beim Antippen den Eintrag an
  (`GeschaeftVorschlag/name`/`koordinaten` liefern die dafür nötigen Rohdaten aus
  beiden Fällen, bekannt wie unbekannt).

## Alle Geschäfte in der Nähe

**Status: Umgesetzt** (`GeschaeftAlleInDerNaeheSheet` in `Views/Einkaufen/EinkaufenView.swift`).

Damit „Ignorieren“ nicht endgültig ist und der Anwender auch unabhängig vom
automatischen Vorschlag (der z.B. verworfen wurde oder mangels GPS-Genauigkeit gar
nicht erschien) manuell wählen kann, gibt es eine zweite, umfassendere Ansicht:

- **Radius:** `GeschaeftErkennungService.alleInDerNaeheRadius`, **100m** — bewusst
  enger als der `suchradius` (150m) des automatischen Einzelvorschlags, da der
  Anwender hier gezielt in einer kurzen, überschaubaren Liste stöbert statt einen
  einzelnen automatischen Treffer zu bekommen.
- `alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:)` liefert **alle**
  Treffer im Radius, nach Entfernung sortiert, je als `GeschaeftInDerNaeheEintrag`
  (`vorschlag: GeschaeftVorschlag`, `istIgnoriert: Bool`) — anders als beim
  automatischen Vorschlag werden ignorierte Treffer hier bewusst **nicht**
  aussortiert, sondern mit sichtbarem Ignoriert-Status geliefert.
- Ignorierte Einträge zeigen statt „Auswählen“/„Hinzufügen“ einen Button „Wieder
  aufnehmen“, der die passenden `IgnorierterGeschaeftsVorschlag`-Einträge über
  `GeschaeftErkennungService.ignorierteEintraege(fuer:in:)` (gleiche Namens-/
  Koordinaten-Logik) löscht.
- **Zugriff:** Sowohl aus dem „…“-Menü des Banners als auch — für den Fall, dass
  gerade kein Banner sichtbar ist — dauerhaft aus dem Geschäft-Menü in der
  `EinkaufenView`-Toolbar (`principal`-Platzierung, gemeinsam mit dem bestehenden
  Geschäft-Picker), damit der Anwender jederzeit „nachträglich“ manuell auswählen
  oder ignorierte Läden reaktivieren kann.
- **Deduplizierung:** Apple Maps liefert für denselben physischen Laden gelegentlich
  mehrere `MKMapItem`-Treffer (z.B. unter leicht unterschiedlichen POI-Kategorien) —
  ohne Gegenmaßnahme erschien z.B. ein ignoriertes Geschäft doppelt in der Liste, weil
  beide Treffer unabhängig voneinander auf dasselbe `Geschaeft` gemappt wurden.
  `GeschaeftErkennungService.dedupliziert(_:)` (aufgerufen am Ende von
  `alleInDerNaehe`) entfernt solche Duplikate: gleiches `Geschaeft`
  (`persistentModelID`) bei zwei `.bekannt`-Treffern, sonst Namens- ODER
  Koordinatenübereinstimmung (analog `istBekannterTreffer(_:fuer:)`) — behält jeweils
  den nächstgelegenen Eintrag, da `treffer` vorher nach Entfernung sortiert wird.
  `internal` statt `private`, direkt getestet ohne echtes CoreLocation/MapKit
  (`GeschaeftErkennungServiceTests`).

## Geschäftsverwaltung in den Einstellungen

`SettingsView` bekommt einen neuen Eintrag „Geschäfte“, der auf dieselbe
`GeschaeftListView` verlinkt wie der gleichnamige Tab (`RootView`) — volle
Verwaltung (Bearbeiten/Anlegen/Löschen) war dort bereits vorhanden, nur ohne
eigenen Einstiegspunkt in den Einstellungen. Dafür musste `GeschaeftListView` seinen
eigenen `NavigationStack` verlieren (verschachtelte `NavigationStack`s sind in
SwiftUI problematisch): `RootView` umschließt den Tab-Aufruf jetzt selbst mit einem
`NavigationStack`, `SettingsView` verlinkt per `NavigationLink` in ihren bereits
vorhandenen `NavigationStack` hinein — analog zu `KategorienVerwaltungView`/
`EinkaufslistenVerwaltungView`.

## Löschen eines Geschäfts löscht seine Preishistorie

`Geschaeft` bekommt eine neue `@Relationship(deleteRule: .cascade, inverse:
\KaufEintrag.geschaeft) var kaufEintraege: [KaufEintrag]`. Vorher war
`KaufEintrag.geschaeft` eine reine, richtungslose Referenz ohne deklarierte
Kaskade — beim Löschen eines Geschäfts blieben zugehörige `KaufEintrag`e (Preis-
historie) verwaist bestehen. Additive Änderung ohne neue `SchemaVN`/`MigrationStage`
(siehe `docs/DECISIONS.md`/`docs/BUILD_WORKFLOW.md`): die zugrundeliegende Spalte
(`KaufEintrag.geschaeft`) existierte bereits, es ändert sich nur die deklarierte
Kaskadenregel, keine Datentransformation nötig.
