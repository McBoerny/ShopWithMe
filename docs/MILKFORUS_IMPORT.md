# MilkForUs-Textimport

Importiert eine aus der Shopping-App "MilkForUs" exportierte Textdatei (Kategorien +
Artikel) in den ShopWithMe-Bestand und auf eine gewählte `Einkaufsliste`. Zwei
Einstiegspunkte führen zum selben Ablauf: manuelle Dateiauswahl in den Einstellungen,
oder die iOS-Teilen-Funktion (z.B. direkt aus einem Chat heraus) über eine eigene
Share Extension.

## Beteiligte Dateien

- `ShopWithMe/Services/MilkForUsImportService.swift` — `MilkForUsParser` (Textformat
  → Einträge), `KategorieZuordnung`, Kategorie-Abgleich, Übernahme in den Bestand.
- `ShopWithMe/Services/AISuggestionService.swift` — `kategorieMatch(fuerName:bekannteKategorien:)`,
  KI-basierter Best-Match für den Kategorie-Abgleich (gleiches Muster wie der
  Artikel-Kategorie-Vorschlag).
- `ShopWithMe/Views/Einstellungen/MilkForUsImportView.swift` — Datei-Picker, Vorschau/
  Korrektur, Zielisten-Wahl, Übernahme.
- `ShopWithMe/Views/Einstellungen/EinkaufslistenVerwaltungView.swift` — Einstiegspunkt
  („MilkForUs importieren“ in der Toolbar).
- `ShopWithMe/Services/MilkForUsPendingImportStore.swift` — Übergabe des geteilten
  Texts von der Share Extension an die Haupt-App über eine App-Group-Containerdatei.
  Quelle für **beide** Targets (siehe `project.yml`).
- `ShopWithMeShareExtension/` — eigenes Extension-Target (`ShareViewController.swift`,
  `ShareExtensionView.swift`).
- `ShopWithMe/App/RootView.swift` — `.onOpenURL` für `shopwithme://milkforus-import`.
- `ShopWithMeTests/MilkForUsImportServiceTests.swift`.

## Textformat

```
Kategoriename
- Artikel 1
- Artikel 2

Andere Kategorie
- Artikel 3
```

Kategorienamen stehen allein auf einer Zeile, Artikel darunter mit `- `-Präfix,
Blöcke durch Leerzeilen getrennt. `MilkForUsParser.parsen(text:)` ist rein
zeilenbasiert: eine nicht-leere Zeile ohne `-`-Präfix startet eine neue Kategorie,
Leerzeilen werden ignoriert. Artikel vor der ersten Kategorie-Überschrift bekommen
den leeren Kategorienamen `""`.

## Ablauf

1. **Text erhalten** — entweder über einen `.fileImporter` (`MilkForUsImportView`,
   UTType `.plainText`) oder vorbefüllt über `initialText`, gesetzt von `RootView`
   nachdem die Share Extension einen Text bereitgelegt hat (siehe unten).
2. **Parsen** (`MilkForUsParser.parsen(text:)`) → `[MilkForUsEintrag]`.
3. **Gruppieren + Kategorie-Abgleich** (`MilkForUsImportService.gruppenMitVorschlag(aus:bestehendeKategorien:fortschritt:)`):
   pro distinktem Kategorienamen (Reihenfolge des ersten Auftretens in der Datei)
   wird eine `KategorieZuordnung` vorgeschlagen. Der KI-Abgleich (Schritt 2 unten)
   läuft für bis zu 4 Kategorien gleichzeitig statt streng nacheinander (siehe
   „Performance“ unten); `fortschritt` (optional) meldet nach jeder fertigen
   Kategorie `(erledigt, gesamt)`:
   1. Exakter, Groß-/Kleinschreibung ignorierender Namenstreffer gegen bestehende
      `ArtikelKategorie`n → `.bestehend`.
   2. Sonst, falls `AISuggestionService.istVerfuegbar`: KI-Best-Match
      (`AISuggestionService.kategorieMatch(fuerName:bekannteKategorien:)`) gegen die
      bestehenden Kategorienamen — z.B. bildet das MilkForUs-"Brot" auf das
      bestehende "Brot & Backwaren" ab, statt eine Dublette anzulegen. Antwortet die
      KI mit keinem Treffer aus der Liste → `.neuAnlegen`.
   3. Ohne KI-Verfügbarkeit direkt `.neuAnlegen`.
   4. Leerer Kategoriename (siehe oben) → immer sofort `.sonstige`, nie
      `.neuAnlegen(name: "")`.
4. **Vorschau/Korrektur** (`MilkForUsImportView`, `VorschauListe`): eine Section pro
   Kategorie-Gruppe, Header mit Menü zum Umstellen der Zuordnung (bestehende
   Kategorie / neu anlegen / Sonstiges), Artikel-Zeilen mit „vorhanden“/„neu“-Badge
   (Abgleich gegen `Artikel.name`, case-insensitive), Swipe-to-delete zum Ausschließen
   einzelner Artikel. Picker zur Ziel-`Einkaufsliste` (Default:
   `Einkaufsliste.standard(context:)`). Der „Importieren“-Button sitzt in der
   Navigationsleiste oben rechts (`.confirmationAction`), nicht mehr am unteren
   Bildschirmrand.
5. **Übernahme** (`MilkForUsImportService.uebernehmen(gruppen:in:context:fortschritt:)`):
   legt neue Kategorien an (Default-Symbol/-Farbe wie `NeueKategorieSheet`), findet
   oder erstellt je Artikelname einen `Artikel` (bestehende Artikel bleiben inkl.
   ihrer Kategorie unangetastet), ruft `Einkaufsliste.artikelHinzufuegen(_:context:)`
   auf. Gruppen ohne verbliebene Artikel (z.B. alle in der Vorschau entfernt) werden
   übersprungen, damit keine ungenutzten neuen Kategorien entstehen. Läuft in Chunks
   à 25 Artikeln, je einem eigenen kurzen `DatabaseLeaseService.performMicroLease`
   (siehe „Performance“ unten); `fortschritt` (optional) meldet nach jedem Chunk
   `(erledigt, gesamt)` in Artikeln. Während dieser Phase zeigt `MilkForUsImportView`
   eine Fortschrittsansicht (Balken + Zähler) statt der Vorschauliste.

## Performance bei sehr großen Listen (Nutzerbericht 2026-08-24)

Zwei Engpässe behoben, die den Import bei vielen Kategorien/Artikeln spürbar
langsam machten:

- **KI-Kategorieabgleich parallelisiert:** `gruppenMitVorschlag` fragte vorher
  jede Kategorie einzeln nacheinander bei der KI an. Läuft jetzt mit bis zu 4
  Kategorien gleichzeitig über eine `TaskGroup` (`vorschlagsName(fuerKategorieName:bekannteKategorienNamen:)`,
  Sendable-sicher — arbeitet bewusst nur mit Kategorie-NAMEN statt
  `ArtikelKategorie`-Objekten, da SwiftData-`@Model`-Typen nicht `Sendable` sind).
- **Artikel-Zuordnung indiziert statt linear durchsucht:** `uebernehmen` suchte
  vorher für JEDEN importierten Artikelnamen per linearem Scan im kompletten
  bestehenden Artikelbestand (`alleArtikel.first { ... }`) — bei mehreren hundert
  bestehenden Artikeln O(n) pro Import-Artikel. Jetzt einmalig nach
  kleingeschriebenem Namen indiziert (`[String: Artikel]`).
- **Chunk-Verarbeitung statt eines einzigen Lease-Blocks:** zusätzlich zur
  Performance auch Grundlage für die Fortschrittsanzeige — ein einziger,
  durchgehend synchroner Micro-Lease-Block hätte weder Zeit für Zwischen-Renders
  gelassen noch dem Micro-Lease-Prinzip „nur Sekundenbruchteile halten“
  entsprochen (siehe `docs/DATABASE_CONCURRENCY.md`).

## Teilen-Funktion: `ShopWithMeShareExtension`

Damit eine per Chat empfangene MilkForUs-Datei direkt geteilt werden kann, ohne
Umweg über „Sichern“ + manuellen Datei-Picker:

1. **Empfang**: `ShareViewController` (Prinzipalklasse, `NSExtensionPointIdentifier
   com.apple.share-services`) liest die geteilten `NSExtensionItem`s. Aktivierungsregel
   (`NSExtensionActivationRule` in `ShopWithMeShareExtension/Info.plist`) akzeptiert
   sowohl geteilten Text (`NSExtensionActivationSupportsText`) als auch eine einzelne
   Datei (`NSExtensionActivationSupportsFileWithMaxCount: 1`) — bewusst weit gefasst;
   die eigentliche Filterung auf lesbaren Text passiert erst beim Laden.
2. **Lesen** (`ShareExtensionView.geteilterText(aus:)`): versucht der Reihe nach
   `public.plain-text`, `public.text`, dann eine Datei-URL als UTF-8-Text zu laden.
   Gelingt keines davon, zeigt die Extension einen Fehlerzustand statt stumm zu
   scheitern.
3. **Übergabe** (`MilkForUsPendingImportStore.speichern(_:)`): der gelesene Text wird
   in eine gemeinsame App-Group-Containerdatei geschrieben
   (`group.com.made4me.ShopWithMe`, Datei `MilkForUsPendingImport.txt`). **Die
   Extension hat keinen Zugriff auf den SwiftData-Store** — Parsen, Abgleich und
   Schreiben passieren ausschließlich in der Haupt-App. Der Store selbst bleibt an
   seinem bisherigen Speicherort (siehe „Datenbank-Speicherort“ in
   `docs/ARCHITECTURE.md`), keine Migration nötig.
4. **Öffnen der Haupt-App**: `extensionContext?.open(URL(string:
   "shopwithme://milkforus-import")!)`. Das URL-Schema `shopwithme` ist über
   `CFBundleURLTypes` in `project.yml` registriert.
5. **Abholen** (`RootView.onOpenURL`): bei passendem Host `milkforus-import` liest
   `MilkForUsPendingImportStore.abholen()` den Text (und löscht die Datei danach,
   damit sie nicht erneut aufgegriffen wird), `RootView` präsentiert daraufhin
   `MilkForUsImportView(initialText:)` als Sheet — identischer Ablauf wie beim
   manuellen Datei-Picker ab Schritt 2 oben.

## Bewusst nicht umgesetzt

- **Kein generisches Import-Format** für beliebige andere Shopping-Apps — nur das
  spezifische MilkForUs-Exportformat.
- **Keine Auftrennung von Namenszusätzen** in eine separate Notiz (z.B. "Müsli Karin"
  oder "Orangensaft Fairtrade Aldi/Lidl") — Artikelnamen werden unverändert
  übernommen.
- **Keine Mengen-/Einheiten-Übernahme** — das Textformat enthält keine; neue Artikel
  bekommen die Standardwerte (`Einheit.stueck`, `mengenSchritt == 1`).
- **Keine feste Alias-Liste** für den Kategorie-Abgleich — bewusst KI-Best-Match statt
  hartkodierter Zuordnungstabelle, damit sich der Abgleich automatisch an künftige,
  heute noch unbekannte MilkForUs-Kategorienamen anpasst.
