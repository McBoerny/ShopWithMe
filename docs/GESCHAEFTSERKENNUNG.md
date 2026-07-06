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
- Ein „x“-Button verwirft den Vorschlag ohne Aktion.

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
