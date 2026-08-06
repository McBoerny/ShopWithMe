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
   innerhalb der Trefftoleranz — Standard `koordinatenTreffertoleranz`, 75m, deckt
   eine spätere Umbenennung in der App ab), sonst wird der nächstgelegene Treffer
   als `.unbekannt(MKMapItem)` vorgeschlagen.

### Behobener Absturz: veraltete `Geschaeft`-Referenz nach Standort-/MapKit-Wartezeit

`vorschlag(vorhandeneGeschaefte:ignorierteVorschlaege:context:)` und
`alleInDerNaehe(vorhandeneGeschaefte:ignorierteVorschlaege:context:)` bekommen
`vorhandeneGeschaefte` als Parameter (typischerweise aus einem `@Query` am
Aufrufort) und durchlaufen danach zwei `await`-Wartepunkte, die in der Praxis
mehrere Sekunden dauern können (Standortermittlung inkl. ggf.
Berechtigungsdialog, MapKit-Suche). Wurde in dieser Zeitspanne ein
`Geschaeft` aus `vorhandeneGeschaefte` gelöscht (durch den Nutzer selbst in
`GeschaeftListView`, oder — seit der Datensynchronisation, GitHub #39 — durch
einen automatischen `SyncPollingService`-Zyklus im Hintergrund, der zwar
selbst nie ein `Geschaeft` löscht, aber durch die zusätzliche
Hintergrundaktivität die Wahrscheinlichkeit erhöht, dass sich eine
Nutzeraktion zeitlich mit einer laufenden Standorterkennung überschneidet),
crashte der anschließende Zugriff auf eine Eigenschaft dieses `Geschaeft`
(z.B. `.name`, `.erkennungsradius`) mit einem SwiftData-Fatal-Error
(„backing data could no longer be found").

**Fix:** Beide Funktionen laden `vorhandeneGeschaefte` nach den
`await`-Wartepunkten frisch aus dem jetzt zusätzlich übergebenen
`ModelContext` neu (`context.fetch(FetchDescriptor<Geschaeft>())`), statt die
zu Beginn übergebenen, potenziell veralteten Objekte weiterzuverwenden.
`effektiverSuchradius(basis:vorhandeneGeschaefte:)` wird bewusst VOR dem
ersten `await` berechnet (zu diesem Zeitpunkt noch garantiert frische
Objekte, da die Funktion bis dahin nicht pausiert hat).

## Individueller Erkennungsradius pro Geschäft

**Status: Umgesetzt** (GitHub #41).

Die feste 75m-Trefftoleranz passt nicht für jedes Geschäft — ein Baumarkt mit
großem Parkplatz braucht einen größeren Radius, dicht benachbarte kleine Läden in
einer Fußgängerzone eher einen kleineren, um Verwechslungen zu vermeiden.

- `Geschaeft.erkennungsradius: Double` (additiv-optionaler Rohwert
  `erkennungsradiusRaw`, Fallback auf `koordinatenTreffertoleranz`) ersetzt in
  `istBekannterTreffer(_:fuer:)` die feste globale Toleranz für dieses eine
  Geschäft — `istGleicherOrt(...)` bekam dafür einen `toleranz`-Parameter.
- Einstellbar per Slider (20–500m) in `GeschaeftStammdatenEditView`, direkt unter
  der Karte — ein `MapCircle`-Overlay zeichnet den gewählten Radius um den
  Standort-Pin ein. Die anfängliche Kartenregion (`kartenRegion(fuer:radius:)`,
  mindestens das Dreifache des Radius als Kantenlänge, sonst 500m) berücksichtigt
  den beim Öffnen bereits gesetzten Radius, zoomt aber bewusst **nicht** erneut
  automatisch mit, wenn Pin oder Radius danach geändert werden (`initialPosition`
  statt einer gebundenen, live nachgeführten Kameraposition) — der Nutzer soll
  die Karte frei zoomen/verschieben können, ohne dass das überschrieben wird
  (GitHub #42, Korrektur einer ursprünglich automatisch nachzentrierenden
  Fassung).
- **Wichtig — Suchradius muss mitwachsen:** `MKLocalPointsOfInterestRequest`
  sucht nur innerhalb von `suchradius`/`alleInDerNaeheRadius` (150m/100m) um den
  *aktuellen Standort* — ein größerer individueller Erkennungsradius eines
  Geschäfts würde sonst wirkungslos bleiben, weil Apple Maps den betreffenden
  Laden bei größerer Entfernung als der Suchradius gar nicht erst zurückliefert,
  bevor `istBekannterTreffer` überhaupt geprüft werden kann.
  `effektiverSuchradius(basis:vorhandeneGeschaefte:)` erweitert den Suchradius
  deshalb vor jeder Anfrage auf `max(basis, größter individueller Radius unter
  allen Geschäften)`.
  Andere Aufrufer von `istGleicherOrt(...)` (`istSelberLaden`, `istIgnoriert`,
  `ignorierteEintraege`) betreffen kein konkretes `Geschaeft` und bleiben beim
  globalen Standardwert.

## Strengere Regel für den automatischen Sync-Merge (GitHub #86)

**Status: Umgesetzt.**

`istGleicherOrt(...)` ist für die oben beschriebenen, interaktiven Fälle
bewusst großzügig (Name exakt ODER Teilstring ODER Koordinaten allein) — der
Nutzer sieht den Vorschlag und kann ihn ablehnen. Für den automatischen
Sync-Merge (`SyncSnapshotImportService.mergeGeschaefte`) ist das zu riskant:
er läuft ohne Bestätigung im Hintergrund und ignorierte dabei zusätzlich den
individuellen `erkennungsradius` (immer nur der globale 75m-Standardwert).

Zwei konkrete Fehlerbilder waren dadurch möglich:
- Zwei dicht benachbarte, aber unterschiedlich benannte Läden (Bäckerei/
  Blumenladen in einem Einkaufszentrum) wurden rein über die Koordinaten
  fälschlich zusammengeführt — der individuelle, engere Radius griff nicht.
- Zwei gleich oder überlappend benannte, aber tatsächlich unterschiedliche
  Filialen derselben Kette an unterschiedlichen Orten wurden bereits über den
  Namensvergleich zusammengeführt, noch bevor die Koordinaten überhaupt
  geprüft wurden.

`GeschaeftErkennungService.istGleicherOrtFuerSyncMerge(...)` ersetzt den
Aufruf in `mergeGeschaefte` durch eine strengere UND-Regel statt der
bisherigen ODER-Kette: Name muss EXAKT übereinstimmen (case-insensitive, kein
Teilstring) UND beide Koordinaten müssen vorhanden UND innerhalb der
strengeren (kleineren) der beiden individuellen `erkennungsradius`-Werte
liegen. Ohne Koordinaten auf einer Seite: kein automatischer Merge.

Bewusster Kompromiss: dadurch können gelegentlich zwei Geräte, die
unabhängig voneinander (z.B. zeitgleich, vor dem nächsten Sync-Zyklus)
denselben, leicht unterschiedlich benannten Laden anlegen, zwei getrennte
`Geschaeft`-Einträge behalten — sichtbar und vom Nutzer selbst per normaler
Löschfunktion bereinigbar (Tombstone propagiert die Löschung an alle Geräte),
statt wie vorher unsichtbar und potenziell falsch automatisch vereint zu
werden.

### Aktive Rückfrage jetzt auch im laufenden Hintergrund-Sync

**Status: Umgesetzt.**

Ursprünglich galt die aktive Rückfrage unten („Aktive Rückfrage beim
Sync-Ordner-Beitritt") nur für den einmaligen Beitritts-Moment — im
laufenden Betrieb entstand bei einem koordinatenlosen `Geschaeft` (z.B. rein
manuell angelegt, nie „Standort ergänzen" bestätigt) weiterhin eine stille
Dublette, weil die strenge Regel oben ohne Koordinaten auf einer Seite nie
matcht. `SyncSnapshotImportService.mergeGeschaefte` prüft deshalb vor dem
Neuanlage-Zweig zusätzlich `istMehrdeutigerBeitrittsKandidat` (dieselbe
Funktion wie beim Beitritt) und stellt einen Treffer als ``SyncAbgleichKandidat``
zurück, statt sofort ein zweites Geschäft anzulegen — sichtbar über ein
Badge in `SyncOrdnerSettingsView`, Auflösung über dieselbe generalisierte
`AbgleichKandidatenSheet`-Ansicht wie beim Beitritt. Dasselbe Muster (dort
mit einem reinen Teilstring- statt Koordinaten-Kriterium, da keine zweite
Vergleichsdimension existiert) gilt seither auch für `Artikel` und
`Einkaufsliste` — Details siehe `docs/DATENSYNCHRONISATION.md` Abschnitt 4.2.

## Aktive Rückfrage beim Sync-Ordner-Beitritt (GitHub #86, Teil 2)

**Status: Entfernt (v0.14).**

Ursprünglich eine aktive Rückfrage analog zum Abschnitt oben, aber für den
einmaligen „Zusammenführen"-Moment beim Beitritt zu einem Sync-Ordner mit
bestehenden Peer-Daten. Die „Zusammenführen"-Wahl selbst wurde entfernt
(`SyncOrdnerSettingsView`, Nutzerentscheidung nach einem Live-Fund mit
Endlosschleifen-Risiko rund um „Ersetzen" — siehe
`docs/DATENSYNCHRONISATION_VERLAUF.md` Abschnitte 47/48): der Beitritt zu
einer Gruppe mit bestehenden Daten läuft jetzt ausschließlich über
„Ersetzen" (sichert den lokalen Stand, übernimmt danach ausschließlich den
Gruppenstand). Damit entfiel auch der dazugehörige Vorprüfungs-Mechanismus
(`SyncSnapshotImportService.mehrdeutigeGeschaeftsKandidatenBeimBeitritt(context:)`,
`GeschaeftsAbgleichKandidat`, `geschaeftsKandidatBestaetigen(_:gewaehlterName:context:)`)
vollständig — er hatte ohnehin nur den jetzt nicht mehr existierenden
Merge-Pfad abgesichert.

`GeschaeftErkennungService.istMehrdeutigerBeitrittsKandidat(...)` selbst
bleibt bestehen — sie wird weiterhin vom Abschnitt oben (laufender
Hintergrund-Sync, ``SyncAbgleichKandidat``-Warteschlange) genutzt.

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
- **Wischgesten** (GitHub #73, zusätzlich zu den obigen Buttons/dem Menü):
  `GeschaeftVorschlagBanner.wischGesteAusgewertet(_:)` wertet ein `DragGesture`
  (`minimumDistance: 24`, hoch genug um einen Tap auf Button/Menü nicht als
  Wisch misszuverstehen) nach dominanter Achse aus — rechts ruft dieselbe
  `aktion()` wie der Haupt-Button auf, links `ignorieren()` (dauerhaft), hoch
  `verwerfen()` (einmalig). Keine neuen Aktionen, nur ein zusätzlicher, zu den
  bestehenden Buttons paralleler Eingabeweg.

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
  Koordinaten-Logik) löscht. `GeschaeftAlleInDerNaeheSheet` holt die Liste nur einmal
  in `.task` (kein Live-`@Query`) — „Wieder aufnehmen“ aktualisiert deshalb zusätzlich
  lokal `istIgnoriert` auf dem betroffenen `GeschaeftInDerNaeheEintrag` (jetzt `var`
  statt `let`), sonst bliebe die Zeile bis zum erneuten Öffnen des Sheets fälschlich
  auf „Ignoriert“ stehen.
- **Zugriff:** Sowohl aus dem „…“-Menü des Banners als auch — für den Fall, dass
  gerade kein Banner sichtbar ist — dauerhaft aus dem Geschäft-Menü in der
  `EinkaufenView`-Toolbar (`principal`-Platzierung, gemeinsam mit dem bestehenden
  Geschäft-Picker), damit der Anwender jederzeit „nachträglich“ manuell auswählen
  oder ignorierte Läden reaktivieren kann.
- **„Neues Geschäft hinzufügen“ bleibt zusätzlich rein manuell möglich**: dasselbe
  Geschäft-Menü bietet immer (unabhängig von Standort/Apple Maps) einen eigenen
  Button, der einen leeren `Geschaeft`-Entwurf (`name: "", typ: .lebensmittel`) über
  denselben `GeschaeftStammdatenEditView`-Anlage-Flow öffnet wie der Vorschlags-Banner
  (`onGespeichert` übernimmt das neue Geschäft automatisch als
  `ausgewaehltesGeschaeft`) — analog zum „+“ in `GeschaeftListView`. Die
  Standort-Erkennung ersetzt die manuelle Anlage also nie, sie ergänzt sie nur
  (relevant z.B. ohne Standortberechtigung oder wenn Apple Maps den Laden nicht
  kennt).
- **Deduplizierung:** Apple Maps liefert für denselben physischen Laden gelegentlich
  mehrere `MKMapItem`-Treffer (z.B. unter leicht unterschiedlichen POI-Kategorien) —
  ohne Gegenmaßnahme erschien z.B. ein ignoriertes Geschäft doppelt in der Liste, weil
  beide Treffer unabhängig voneinander auf dasselbe `Geschaeft` gemappt wurden.
  `GeschaeftErkennungService.dedupliziert(_:)` (aufgerufen am Ende von
  `alleInDerNaehe`) entfernt solche Duplikate: gleiches `Geschaeft`
  (`persistentModelID`) bei zwei `.bekannt`-Treffern, sonst Namens- ODER
  Koordinatenübereinstimmung — behält jeweils den nächstgelegenen Eintrag, da
  `treffer` vorher nach Entfernung sortiert wird. `internal` statt `private`, direkt
  getestet ohne echtes CoreLocation/MapKit (`GeschaeftErkennungServiceTests`).
- **Zentrales Matching (`istGleicherOrt`):** `istBekannterTreffer(_:fuer:)`,
  `istIgnoriert(_:ignorierte:)`, `istSelberLaden(_:_:)` (Dedup) und
  `ignorierteEintraege(fuer:in:)` teilen sich seit einem Refactor eine gemeinsame
  private Namens-/Koordinaten-Vergleichsfunktion, statt vier fast identische
  Implementierungen zu pflegen. Das behebt nebenbei eine echte Lücke: vorher prüfte
  nur `istBekannterTreffer` Namens-Teilstrings (z.B. Apple-Maps-„REWE“ vs. selbst
  vergebenem „Rewe am Markt“) — `istSelberLaden` verglich Namen nur exakt und konnte
  dadurch ein manuell angelegtes Geschäft ohne gespeicherte Koordinaten nicht mit
  einem abweichend benannten Apple-Maps-Treffer für denselben Laden deduplizieren
  (`GeschaeftAlleInDerNaeheSheet` hätte ihn doppelt gelistet). Jetzt nutzen alle vier
  Stellen dieselbe (Teilstring-fähige) Logik.

## Suchradius im Debug-Build testweise überschreibbar

**Status: Umgesetzt** (`Services/DebugEinstellungen.swift`,
`Views/Einstellungen/DebugEinstellungenView.swift`).

Beide Radien (`standardSuchradius`, 150m; `standardAlleInDerNaeheRadius`, 100m) sind
in der Praxis unbequem zu testen, wenn man während der Entwicklung nicht direkt neben
einem echten Apple-Maps-Laden steht. Deshalb:

- `GeschaeftErkennungService.suchradius`/`alleInDerNaeheRadius` sind keine `static
  let`-Konstanten mehr, sondern `static var`: in Debug-Builds (`#if DEBUG`) liefern
  sie `DebugEinstellungen.sucheRadiusUeberschreibung ?? standardXYZ`, in
  Release-Builds unbedingt den festen Standardwert (`#if DEBUG`/`#else` direkt im
  Getter, kein Laufzeit-Flag) — die Überschreibung existiert in einem
  Release-/App-Store-Build gar nicht erst im Binary.
- `DebugEinstellungen` (nur innerhalb `#if DEBUG` deklariert) kapselt die
  Überschreibung in `UserDefaults`; `DebugEinstellungenView` (neuer Eintrag
  „Debug-Einstellungen“ in `SettingsView`, ebenfalls `#if DEBUG`) bietet dafür einen
  Toggle + Stepper (100–5000m). Eine Überschreibung gilt für **beide** Radien
  gemeinsam, da ein Entwickler beim Testen typischerweise beide gleichzeitig
  vergrößern möchte.
- Ist die Überschreibung deaktiviert (Standard), gelten unverändert
  `standardSuchradius`/`standardAlleInDerNaeheRadius`.

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

## Neues Geschäft ohne Apple-Maps-Treffer am aktuellen Ort protokollieren

**Status: Umgesetzt** (`GeschaeftErkennungService.entwurfAusAktuellemStandort()`,
Leer-Zustand in `GeschaeftAlleInDerNaeheSheet`).

Findet „Alle Geschäfte in der Nähe“ im 100m-Umkreis keinen Treffer (z.B. weil Apple
Maps den Laden nicht kennt oder gar keine Standortberechtigung erteilt wurde), bot der
Leer-Zustand bislang keine Möglichkeit, den aktuellen Ort trotzdem festzuhalten — nur
die vom Standort komplett unabhängige „Neues Geschäft hinzufügen“-Aktion (ohne
Koordinaten) stand zur Verfügung.

- `GeschaeftErkennungService.entwurfAusAktuellemStandort()` fragt (analog
  `vorschlag`/`alleInDerNaehe`) einmalig den aktuellen Standort ab und baut daraus
  einen leeren `Geschaeft`-Entwurf (`name: ""`, `typ: .lebensmittel`) mit gesetzten
  `breitengrad`/`laengengrad` — ohne dass dafür ein `MKMapItem` vorliegen muss.
  Liefert `nil` ohne Standortberechtigung/-ermittlung.
- Der Leer-Zustand („Keine Geschäfte gefunden“) in `GeschaeftAlleInDerNaeheSheet`
  bietet dafür einen zusätzlichen Button „Diesen Ort als neues Geschäft anlegen“
  (`ContentUnavailableView` mit `actions`-Closure). Erfolgreich ermittelt, öffnet sich
  darüber derselbe `GeschaeftStammdatenEditView`-Anlage-Flow wie bei allen anderen
  Wegen; die Koordinaten stehen von Anfang an für künftiges Koordinaten-Matching
  (`koordinatenTreffertoleranz`) zur Verfügung. Schlägt die Standortermittlung fehl,
  erscheint statt eines stillen No-Ops ein Hinweis-Alert.

## Standort nachträglich für ein bereits genutztes Geschäft ergänzen

**Status: Umgesetzt** (`EinkaufenView.pruefeStandortErgaenzung(fuer:)`,
`GeschaeftErkennungService.koordinatenAusAktuellerPosition()`/`koordinaten(fuerAdresse:)`).

Geschäfte, die ohne Standortbezug angelegt wurden (z.B. über „Neues Geschäft
hinzufügen“ oder den „neu anlegen“-Weg beim Belegscan, `GeschaeftWahlSheet`),
blieben bislang dauerhaft unsichtbar für die automatische Ladenerkennung, auch wenn
der Anwender später tatsächlich dort einkauft — bewusst wird der Standort dafür
NICHT automatisch beim Belegscan erfasst (der Scan passiert oft nicht am Ort des
Ladens), sondern erst nachgefragt, sobald der Anwender ein solches Geschäft beim
Einkaufen tatsächlich auswählt.

- `EinkaufenView.onChange(of: ausgewaehltesGeschaeft)` prüft nach jeder Auswahl
  (Toolbar-Picker, Standort-Vorschlag, „Alle Geschäfte in der Nähe“, direkt nach dem
  Anlegen) über `pruefeStandortErgaenzung(fuer:)`, ob `breitengrad` fehlt, und zeigt
  in diesem Fall ein `.confirmationDialog` „Standort für „<Name>“ speichern?“.
- **Ohne hinterlegte `adresse`:** „Aktuellen Standort verwenden“ (über neues
  `GeschaeftErkennungService.koordinatenAusAktuellerPosition()`, dünner Wrapper um
  dieselbe private Standort-Hilfsfunktion wie `entwurfAusAktuellemStandort()`) oder
  „Adresse eingeben“ (öffnet `AdresseEingebenSheet`, ein kleines Sheet mit
  Entwurfs-Zustand analog `NeueEinkaufslisteSheet`, das die eingegebene Adresse
  geocodiert und bei Erfolg sowohl `adresse` als auch die Koordinaten übernimmt).
- **Mit bereits hinterlegter `adresse`, aber ohne Koordinaten:** „Aktuelle Position
  verwenden“ oder „Aus hinterlegter Adresse ermitteln“ (geocodiert direkt, kein
  Textfeld nötig) — für den Fall, dass keine Standortberechtigung erteilt werden
  soll.
- „Nicht jetzt“ (Cancel) schließt ohne dauerhaftes Merken — erscheint bei erneuter
  Auswahl desselben Geschäfts wieder, da die Nachfrage nur bei bewusster Auswahl
  ausgelöst wird (kein Hintergrund-Nerv-Faktor).
- **Geocoding:** `GeschaeftErkennungService.koordinaten(fuerAdresse:)` nutzt
  `MKGeocodingRequest` (MapKit) statt des seit iOS 26 deprecateten `CLGeocoder` —
  kein Standortzugriff nötig, nur Netzwerk. `nil` bei leerem Text, ohne Treffer oder
  bei Geocoding-Fehler.
- `Geschaeft.adresse` bleibt bewusst ein optionales Feld — keine neue Pflichtangabe
  in `GeschaeftStammdatenEditView` oder anderen Anlage-Flows, nur über diese
  Nachfrage opportunistisch eingesammelt.
- Fehlschläge (keine Standortberechtigung/-ermittlung, Geocoding ohne Treffer)
  zeigen einen Alert statt eines stillen No-Ops.

## Löschen eines Geschäfts löscht seine Preishistorie

`Geschaeft` bekommt eine neue `@Relationship(deleteRule: .cascade, inverse:
\KaufEintrag.geschaeft) var kaufEintraege: [KaufEintrag]`. Vorher war
`KaufEintrag.geschaeft` eine reine, richtungslose Referenz ohne deklarierte
Kaskade — beim Löschen eines Geschäfts blieben zugehörige `KaufEintrag`e (Preis-
historie) verwaist bestehen. Additive Änderung ohne neue `SchemaVN`/`MigrationStage`
(siehe `docs/DECISIONS.md`/`docs/BUILD_WORKFLOW.md`): die zugrundeliegende Spalte
(`KaufEintrag.geschaeft`) existierte bereits, es ändert sich nur die deklarierte
Kaskadenregel, keine Datentransformation nötig.
