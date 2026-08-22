# Artikel/Produkt/Produktname-Modell (GitHub #47)

**Status: vollständig umgesetzt** ([#112](https://github.com/McBoerny/ShopWithMe/issues/112)
Datenmodell + Migration, [#113](https://github.com/McBoerny/ShopWithMe/issues/113)
Sync-Integration, [#114](https://github.com/McBoerny/ShopWithMe/issues/114)
Preis-Aggregation, [#115](https://github.com/McBoerny/ShopWithMe/issues/115)
UI, [#116](https://github.com/McBoerny/ShopWithMe/issues/116)
Scan-Zuordnung) — alle 5 Schritte aus dem Umsetzungsplan in #47 fertig, plus
Schritt 6/6 ([#128](https://github.com/McBoerny/ShopWithMe/issues/128) —
Geschäfts-Pflicht bei `Preispunkt`, Ablösung von `ArtikelAlias`).
Präzisiert und ersetzt die ursprüngliche Formulierung in
[#47](https://github.com/McBoerny/ShopWithMe/issues/47) (dort noch
"Ausprägung" genannt) — siehe Diskussion vom 2026-08-06. Löst seit #128 auch
die vormals separaten Artikel-Alias-Namen
([#111](https://github.com/McBoerny/ShopWithMe/issues/111), v0.13) vollständig
in dieses Modell auf, siehe Schritt 6/6 unten.

**Schema-Historie zurückgesetzt (2026-08-22):** Die App befindet sich noch in
der Entwicklungsphase; der lokale Store wurde vollständig zurückgesetzt. Die
in den Schritten 1/5 und 6/6 unten beschriebene `VersionedSchema`-Migrations-
Mechanik (`SchemaV1`…`SchemaV4`, `SchemaMigrationPlan`, die zweiphasige
`liveSchema`-Notlösung) existiert im Code NICHT mehr — `Models/SchemaDefinition.swift`
definiert jetzt einen frischen `SchemaV1`-Ausgangspunkt mit dem aktuellen
Modell (inkl. `Produkt`/`Produktname`, `Artikel.alternativeNamen`/
`Produkt.alternativeKlarnamen`, ohne `ArtikelAlias`), ohne Migrationsplan. Die
folgenden Abschnitte beschreiben weiterhin korrekt die fachliche Herleitung
und Architektur-Entscheidungen — nur die konkret zitierten Dateinamen/
Migrationsschritte der SwiftData-Mechanik sind historisch. Erkenntnisse zur
Migrationsstrategie selbst (insbesondere: reich vernetzte Hub-Typen nie in
einer `VersionedSchema`-Stufe einfrieren) stehen dauerhaft im
`ios-swift-engineering`-Skill.

## Umsetzungsstand Schritt 1/5 (v0.14, historisch)

`Produkt`/`Produktname` existieren als neue `@Model`-Typen
(`Models/Produkt.swift`, `Models/Produktname.swift`); `Artikel`, `Preispunkt`
und `EinkaufslistenEintrag` haben die dafür nötigen neuen Relationships
(`Artikel/produkte`, `Preispunkt/produkt`, `EinkaufslistenEintrag/produkt`).

**Erste echte strukturelle SwiftData-Migration dieses Projekts:** `SchemaV1`
(`Models/SchemaV1Frozen.swift`) friert den kompletten Vorzustand aller 23
bisherigen Modelltypen verschachtelt ein, `SchemaV2`
(`Models/SchemaDefinition.swift`) referenziert die aktuellen, live
weiterentwickelten Typen. Eine `MigrationStage.custom` verknüpft jeden
bereits bestehenden `Preispunkt`/`EinkaufslistenEintrag` beim ersten Start
nach dem Update automatisch mit einem Platzhalter-Produkt seines Artikels
(`Produkt.standardProdukt(fuer:context:)`, markiert über `Produkt.istStandard`)
— bestehende Daten verlieren dadurch nichts, ohne dass der Nutzer manuell
etwas nachpflegen muss. Verifiziert mit einem echten, vor der
Modelländerung angelegten On-Disk-Store (`ProduktMigrationTests.swift`), nicht
nur mit einem frischen In-Memory-Store (siehe `docs/BUILD_WORKFLOW.md` zum
Unterschied).

**Bewusst noch keine sichtbare Funktionsänderung** — `Preispunkt.artikel`
bleibt zusätzlich zu `produkt` gepflegt (alle bestehenden, Artikel-zentrierten
Codestellen funktionieren unverändert weiter), UI/Scan-Zuordnung/Aggregation
über die neue Produkt-Ebene folgen in Schritt 3–5.

## Umsetzungsstand Schritt 2/5 (v0.14)

`Produkt`/`Produktname` sind jetzt Teil der geräteübergreifenden
Datensynchronisation (`docs/DATENSYNCHRONISATION.md`, `SyncSnapshot`-Version
8): `mergeProdukte` matcht wie `mergeArtikel` per ID/Alias, sonst per exaktem
Namen — bewusst **innerhalb desselben, bereits aufgelösten Artikels** statt
global, damit gleichnamige Produkte unter verschiedenen Artikeln nicht
fälschlich zusammenfallen. Rekursive `elternProdukt`-Zuordnung läuft in einem
zweiten Durchlauf, da ein Kind-Eintrag in der Sync-Liste vor seinem
Eltern-Eintrag stehen kann. `mergeProduktnamen` ist rein additiv (Union nach
Produkt/Geschäft/Name), analog `ArtikelAlias`.

Bewusst **ohne** die bei `mergeArtikel`/`mergeGeschaefte` vorhandene
Ambiguitäts-Rückstellung (`SyncAbgleichKandidat`) — Produkt hat noch keine
eigene Verwaltungs-UI (folgt in Schritt 4), ein gelegentlich doppelt
angelegtes, ähnlich benanntes Produkt ist ein geringeres Risiko als bei
Artikel/Geschäft. Kann bei Bedarf in einem späteren Schritt ergänzt werden.

`Preispunkt`/`EinkaufslistenEintrag` lösen ihr `Produkt` jetzt bevorzugt über
die echte, synchronisierte Zuordnung auf; nur wenn ein Peer noch keine
Produkt-Synchronisation kennt (oder keine `produktID` mitschickt), greift
weiterhin der Schritt-1-Fallback auf `Produkt.standardProdukt(fuer:context:)`.

## Umsetzungsstand Schritt 3/5 (v0.14)

`Produkt.minimum`/`.maximum` (über `preispunkteRekursiv`) implementieren jetzt
Regel 2 unten: ein Produkt mit `unterProdukte` kumuliert deren Preise (rekursiv,
beliebig tief), statt nur eigene `preispunkte` zu betrachten.

**Präzisierung gegenüber dem ursprünglichen Plan-Text:** Der Umsetzungsplan in
#47 nannte diesen Schritt "`ArtikelPreisSpanne` um Produkt-Ebene erweitern".
Bei der Umsetzung zeigte sich: `ArtikelPreisSpanne`
(`Models/ArtikelPreisSpanne.swift`, einzige Verwendung in
`GeschaeftPreisUebersichtView.swift`) gruppiert bereits alle `Preispunkt`e
eines Artikels unabhängig vom zugehörigen `Produkt` — bleibt dadurch
unabhängig von der Produkt-Hierarchie eine korrekte "Preisspanne über alles,
was unter diesem Artikel verkauft wurde"-Sicht und musste nicht geändert
werden. Die eigentliche Lücke lag allein auf `Produkt` selbst (nur
Doc-Kommentar zu Regel 2, keine Implementierung) — dort ist sie jetzt
geschlossen, `ArtikelPreisSpanne` bleibt unverändert.

## Umsetzungsstand Schritt 4/5 (v0.14)

Erste sichtbare UI dieses gesamten Features: `ArtikelEditView` bekommt eine
Sektion "Produkte" (nur oberste Ebene, ohne das automatisch angelegte
Platzhalter-Produkt), von dort per Tap navigierbar zur neuen
`ProduktEditView` (Name, Produktnamen je Geschäft, eigene Preishistorie —
analog `ArtikelEditView`). In `ArtikelHinzufuegenView` bekommt ein Artikel
mit mehr als einem eigenen Produkt zusätzlich einen Chevron-Button, der ein
Produktwahl-Sheet öffnet — der bestehende Sofort-Tap (GitHub #6/#45) bleibt
dabei bewusst unverändert (fügt weiterhin ohne festgelegtes Produkt hinzu).
Das gewählte Produkt erscheint danach klein unter dem Artikelnamen auf der
Einkaufsliste (`EinkaufenView`, gleiches Muster wie die bestehende
`notiz`-Anzeige).

**Nebenbei korrigiert:** `docs/BEDIENUNGSANLEITUNG.md` riet im
Alias-Namen-Abschnitt (aus #111, vor Existenz von `Produkt` geschrieben) für
unterschiedliche Marken fälschlich noch zu separaten **Artikeln** — das ist
jetzt auf **Produkte** korrigiert.

Details/vollständige Liste betroffener Dateien: [#115](https://github.com/McBoerny/ShopWithMe/issues/115).

## Umsetzungsstand Schritt 5/5 (v0.14) — Feature komplett

`ArtikelZuordnungsService` bekommt eine neue Matching-Stufe zwischen
gelerntem `ArtikelAlias` und dem generischen Artikel-Namens-Teilstring-
Abgleich: Abgleich gegen `Produktname` **innerhalb des erkannten
Geschäfts**. Ein erfolgreicher Treffer liefert sowohl den Artikel als auch
das konkrete `Produkt` — `BelegScanView` reicht dieses Produkt danach direkt
an `PreispunktService.erfassen` durch, statt wie zuvor immer nur beim
Platzhalter-Standardprodukt zu landen. `PreispunktService`s interne
Slowly-Changing-Dimension-Logik (`letzterPreispunkt`) berücksichtigt jetzt
zusätzlich das Produkt, damit zwei echte Produkte desselben Artikels+Geschäfts
(z.B. „Odol" und „Paradontol" für „Zahnpasta" bei Rewe) unabhängige
Preishistorien behalten, statt sich beim Scannen gegenseitig zu
überschreiben.

**Bewusst weiterhin ohne volle `ArtikelZuordnungsService`-Pipeline:**
`PreisschildScanView` ruft `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`
seit GitHub #128 zwar direkt auf (Nachfolge des vormaligen `ArtikelAlias.passend`),
nutzt aber weiterhin nicht die volle Substring-/KI-Kaskade von
`ArtikelZuordnungsService` — eigene, parallele Zuordnungslogik, siehe
`docs/ARCHITECTURE.md`. `KaufEintrag` bekommt weiterhin kein `produkt`-Feld
(seit GitHub #76 ohne Preisrolle).

Details: [#116](https://github.com/McBoerny/ShopWithMe/issues/116).

Damit sind alle 5 Schritte aus dem Umsetzungsplan in #47 abgeschlossen —
Artikel, Alias-Namen, Produkte, Produktnamen und deren Preise sind jetzt
vollständig modelliert, synchronisiert, aggregiert, verwaltbar und werden
beim Belegscan automatisch erkannt.

## Automatische Neuanlage beim Belegscan (Folgearbeit zu #47/#116)

**Status: umgesetzt (v0.14).** Schritt 5/5 deckte nur den Fall ab, dass für
den erkannten Bon-Text bereits ein ``Produktname`` existiert. In allen
anderen Fällen, in denen ``ArtikelZuordnungsService`` trotzdem einen
``Artikel`` liefert (Substring-Treffer, KI-Vorschlag, oder manuelle
Artikel-Zuweisung/-Neuanlage in der Prüf-Ansicht ohne Produktwahl), bekam
``PreispunktService.erfassen`` bislang `produkt: nil` und fiel dort
automatisch auf `Produkt.standardProdukt(fuer:context:)` zurück — das
geteilte Platzhalter-Produkt des Artikels. Mehrere tatsächlich
unterschiedliche, dem Nutzer noch nicht als eigenes ``Produkt`` bekannte
Marken landeten dadurch in derselben Preishistorie und überschrieben sich
gegenseitig (Slowly-Changing-Dimension-Vergleichsschlüssel schließt
`produkt` mit ein, siehe `PreispunktService.swift`).

**Bewusst ausgenommen: ein bereits über `Produktname` bekannter Treffer**
(`ArtikelZuordnungsService.Quelle.produktname`) — der bringt schon ein
`Produkt` mit, `aufgeloestesOderNeuesProdukt` läuft nur, wenn noch keins
vorliegt (Substring-/KI-Treffer, `.artikelSubstring`/`.ki`). Seit GitHub #128
(Ablösung von `ArtikelAlias`, siehe Schritt 6/6 unten) gibt es keine eigene
"Alias"-Quelle mehr — die frühere "dieselbe generische Sache in anderer
Schreibweise, kein eigenständiges Produkt"-Rolle deckt jetzt ein
`Produktname`-Eintrag ab, der auf das `istStandard`-Platzhalter-Produkt des
Artikels zeigt.

`Produkt.aufgeloestesOderNeuesProdukt(klarname:erkannterName:artikel:geschaeft:context:)`
(`Models/Produkt.swift`), aufgerufen aus `BelegScanView.uebernehmen()` nach
Auflösung von `geschaeftFuerPreispunkt`, aber vor dem eigentlichen
`PreispunktService.erfassen(...)`:

1. **Produktidentität bestimmen**: Das Artikel-Textfeld der Prüf-Ansicht
   zeigt standardmäßig den generischen Artikelnamen (nicht den Bon-Text,
   siehe `docs/BELEGSCAN.md`) — bleibt der vom Nutzer bestätigte Name
   (`klarname`) deshalb identisch zum Artikelnamen, trüge er keine
   unterscheidende Information. In diesem (häufigsten) Fall dient
   stattdessen der rohe erkannte Bon-Text (`erkannterName`) als
   Produktidentität. Weicht `klarname` bewusst vom Artikelnamen ab (Nutzer
   hat umbenannt, z.B. auf „Paradontol Zahncreme“), gilt er als Identität.
2. **Duplikat-Vermeidung**: Vor einer Neuanlage wird unter
   `artikel.produkte` (ohne das `istStandard`-Platzhalter-Produkt) nach
   einem beidseitigen Teilstring-Treffer auf die Produktidentität gesucht —
   findet sich eins (z.B. weil derselbe Klarname schon an einem anderen
   Geschäft verwendet wurde), wird es wiederverwendet statt dupliziert.
3. **Produktname nur mit Geschäft**: Ohne Treffer entsteht ein neues
   `Produkt(name: produktidentitaet, artikel:)`. Ist zusätzlich ein
   Geschäft bekannt, wird ergänzend ein `Produktname(name: erkannterName,
   produkt:, geschaeft:)` angelegt (sofern noch nicht vorhanden) — ohne
   Geschäft entsteht nur das `Produkt` selbst. Der `geschaeft`-Parameter
   bleibt aus Testbarkeits-/Flexibilitätsgründen optional, ist aber seit
   GitHub #128 (Geschäfts-Pflicht bei `Preispunkt`) an allen tatsächlichen
   Aufrufstellen (`BelegScanView`, `PreispunktZuordnenSheet`) immer gesetzt.

Tests: `ProduktTests.swift` (Namensfindung, Duplikat-Wiederverwendung,
Standardprodukt-Ausschluss, Verhalten ohne Geschäft),
`ArtikelZuordnungsServiceTests.swift` (`Quelle` je Zuordnungsstufe).

## Die drei Ebenen

**Seit GitHub #128 (siehe Schritt 6/6 unten) gibt es kein separates
`ArtikelAlias`-Modell mehr** — die frühere eigenständige vierte Entität ist zu
einem schlanken Feld auf `Artikel` geworden, und die geschäftsunabhängige
Rolle wandert in `Produktname` (dessen `geschaeft` schon immer optional war).

```
Artikel (generisch, KEIN eigener Preis)
  │
  ├─ [String] alternativeNamen      (Feld, GitHub #111/#128)
  │            generische Synonyme, z.B. "Zahncreme" für "Zahnpasta" —
  │            reine Textsuche (Substring-Matchstufe), kein eigenes Produkt
  │
  └─ 1:n → Produkt
             konkretes, kaufbares Ding — trägt den Preis
             │
             ├─ [String] alternativeKlarnamen   (Feld, GitHub #128)
             │            zusätzliche Anzeigenamen dieses Produkts,
             │            geschäftsunabhängig
             │
             ├─ 1:n → Produkt       (rekursiv, z.B. Packungsgrößen-Varianten)
             │
             └─ 1:n → Produktname   (pro Geschäft ein eigener Name, ODER
                                      geschäftsunabhängig bei geschaeft: nil —
                                      seit #128 auch die Rohtext-Rolle des
                                      früheren `ArtikelAlias`)
```

**Beispiel:**

- Artikel "Zahnpasta"
  - alternativeNamen: "Zahncreme", "Zahnreiniger"
  - Produkte: "Odol", "Paradontol Zahncreme", "Sebamed"
    - Produkt "Paradontol Zahncreme"
      - alternativeKlarnamen: "Paradontol (klassisch)"
      - Unter-Produkte (Packungsgrößen): "Paradontol 75ml", "Paradontol 125ml"
      - Produktnamen: Geschäft A → "Parad Zahncr", Geschäft B → "Paradontol Zahn",
        geschäftsunabhängig → "PARADONTOL" (z.B. gelernt ohne bekanntes Geschäft)

## Regeln

1. **Artikel hat nie einen eigenen Preis.** Der Artikel ist nur die generische
   Bezeichnung/Gruppierung (z.B. "Zahnpasta"), unter der beim Einkaufen gesucht
   und auf der Liste abgehakt wird.
2. **Produkt trägt den Preis** — aber nur, wenn es selbst keine Unter-Produkte
   hat (Blatt der Hierarchie). Hat ein Produkt Unter-Produkte, kumuliert es
   deren Preise (Minimum/Maximum über alle Blätter), trägt aber selbst keinen
   direkten `Preispunkt`. Gleiche Kumulierungslogik wie ursprünglich in #47 für
   den Artikel beschrieben, jetzt eine Ebene tiefer angesiedelt.
3. **Produktname kann geschäftsabhängig ODER geschäftsunabhängig sein**
   (`geschaeft: Geschaeft?`). Ein Produkt kann in Geschäft A unter einem
   anderen Namen im Kassenbon/Preisschild erscheinen als in Geschäft B — beide
   Namen gehören zum selben Produkt. Ein `Produktname` mit `geschaeft == nil`
   übernimmt seit GitHub #128 zusätzlich die frühere Rolle von `ArtikelAlias`:
   ein Rohtext, der unabhängig vom erkannten Geschäft wiedererkannt werden
   soll (z.B. gelernt in einem Scan ohne bekanntes Geschäft). Das
   `ArtikelZuordnungsService`-Matching sucht dafür immer zuerst
   geschäftsspezifisch, dann geschäftsunabhängig (siehe
   `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)`).
4. **Ein Nutzer darf jederzeit einen eigenständigen Artikel statt eines
   Produkts anlegen**, wenn er ein gefundenes Produkt lieber als eigenen
   Artikel führen will (Präzedenzfall aus der ursprünglichen #47-Formulierung
   für "Chinakohl" vs. "Salat" — gilt unverändert).

## Verhältnis zum bestehenden Code

**Status: umgesetzt** (Produkt-Pflicht bei `Preispunkt`, siehe Abschnitt
„Schritt 7/6" unten) — der folgende Absatz beschreibt den historischen
Vorzustand, in dem `Preispunkt` den Preis noch direkt am `Artikel` trug.

Vor der Produkt-Pflicht trug **`Preispunkt`** den Preis direkt am `Artikel`
(`var artikel: Artikel?`) und bildete den Produktnamen nur als loses
Textfeld ab (`produktName`, `alternativerName` — beide direkt am einzelnen
Preispunkt, nicht an einer wiederverwendbaren Entität). Da `Preispunkt`
bereits `artikel` **und** `geschaeft` trug, war die Geschäftsabhängigkeit des
Namens strukturell schon vorhanden — nur nicht als eigenständiges "Produkt",
das über mehrere Preispunkte/Geschäfte hinweg wiedererkannt würde.

Die Umsetzung machte `Preispunkt.artikel` zu einer abgeleiteten, read-only
Computed-Property (`produkt?.artikel`) statt eines eigenen gespeicherten
Felds — eine **strukturelle** Änderung im Sinne des SCD-Modells, aber ohne
neue `SchemaVN`/`MigrationStage` (siehe Hinweis „Schema-Historie
zurückgesetzt" ganz oben: kein Altbestand vorhanden, der eine Migration auf
synthetische "ein Produkt pro bisherigem Artikel"-Einträge gebraucht hätte —
das früher hier antizipierte Risiko entfiel dadurch).

`ArtikelPreisSpanne.gruppieren(_:)` gruppiert weiterhin nach `Preispunkt.artikel`
— funktioniert unverändert, da die Computed-Property dasselbe Verhalten für
lesenden Code liefert wie zuvor das gespeicherte Feld.

Verwandt: [#10](https://github.com/McBoerny/ShopWithMe/issues/10) (offene
Modellfrage, ob `produktName` als loses Feld reicht — durch dieses Konzept
beantwortet: nein, eine eigenständige `Produkt`-Entität ist nötig, damit
derselbe Produktname über mehrere Geschäfte/Preispunkte hinweg
wiedererkannt wird statt bei jedem Scan neu als Text zu entstehen).

## Schritt 6/6 (GitHub #128/#129, historisch) — Geschäfts-Pflicht bei Preispunkt, Ablösung von ArtikelAlias

**Status: umgesetzt, Migrationsmechanik seit 2026-08-22 überholt** (siehe
Hinweis „Schema-Historie zurückgesetzt" ganz oben) — der lokale Store wurde
zurückgesetzt, `ArtikelAlias` existiert im Code nicht mehr (auch nicht als
leere Altlast), `Preispunkt.geschaeft` ist Teil des frischen `SchemaV1`-
Ausgangspunkts. Der Abschnitt „Migration" unten dokumentiert weiterhin, WARUM
die naheliegenden Ansätze scheiterten (wertvoll für künftige strukturelle
Änderungen), beschreibt aber keinen mehr existierenden Code-Zustand. Ausgangspunkt war eine Architektur-Diskussion, ob das
geschäftsunabhängige `ArtikelAlias`-Modell durch `Produkt`/`Produktname`
ersetzt werden kann. Zwei strukturelle Einwände wurden dabei aufgelöst:

1. **„Ein `Preispunkt` konnte bisher ohne Geschäft entstehen"** (Standard-
   Scan-Tab `BelegScanKontext.unbekannt`, `Einkaufsvorgang` ohne gewähltes
   Geschäft) — behoben durch eine Geschäfts-Pflicht: `PreispunktService.erfassen(...)`
   verlangt jetzt zwingend ein `Geschaeft` als Funktionsparameter,
   `BelegScanView` deaktiviert „Preise übernehmen", solange keins feststeht,
   `GeschaeftWahlSheet` verliert die „Kein Geschäft"-Option.
2. **„`Produktname` unterscheidet nicht zwischen Schreibvariante und
   eigenständigem Produkt"** — aufgelöst, weil `Produktname` bereits mehrere
   Rohnamen pro Produkt UND pro Geschäft zulässt (nur exakte Duplikate werden
   geblockt) und `geschaeft: Geschaeft?` schon immer optional war: ein
   `Produktname` mit `geschaeft == nil`, der auf das `istStandard`-
   Platzhalter-Produkt zeigt, verhält sich exakt wie ein früherer
   Alias-Treffer (geteilte Preishistorie, keine neue Produktidentität).

**Zusätzlich identifiziert (Nutzer-Präzisierung):** Die frühere
`ArtikelAlias.alternativerName`-Rolle (generisches Synonym, z.B. „Zahncreme“
für „Zahnpasta“) ist ein drittes, von beidem unabhängiges Konzept auf
**Artikel**-Ebene — dafür kam `Artikel.alternativeNamen: [String]` dazu
(analog `Geschaeft.alternativeNamen`). Ergänzend, für Marken-/Varianten-
Anzeigenamen auf **Produkt**-Ebene (z.B. „Andechser Vollmilch fett“ für
„Andechser Milch 3,5%“): `Produkt.alternativeKlarnamen: [String]`.

### Umgesetzt

- `Artikel.alternativeNamen` / `Produkt.alternativeKlarnamen` — neue,
  additive `[String]`-Felder (`\n`-getrennter Rohstring hinter Computed
  Property, wie `Geschaeft.alternativeNamen`).
- `Produktname.passend(fuerErkannterName:bevorzugtesGeschaeft:in:)` — neue
  Matching-Stufe (`Models/Produktname.swift`), Nachfolge von
  `ArtikelAlias.passend`: sucht zuerst geschäftsspezifisch, dann
  geschäftsunabhängig (`geschaeft == nil`).
- `ArtikelZuordnungsService`: `Quelle.alias` entfällt, Stufe 1 nutzt
  `Produktname.passend(...)`, Stufe 2 (Artikel-Substring) prüft zusätzlich
  `Artikel.alternativeNamen`.
- `PreispunktService.erfassen(...)`/`vorhandenerPunktHeute(...)`: `geschaeft`
  non-optionaler Funktionsparameter — die Geschäfts-Pflicht wird bewusst NUR
  hier durchgesetzt, nicht am Modell (siehe „Migration" unten).
- `BelegScanView.uebernehmen()`/`PreisschildScanView.uebernehmen()`: das
  explizite `ArtikelAlias.lernen(...)` entfällt ersatzlos —
  `Produkt.aufgeloestesOderNeuesProdukt(...)` legt den passenden
  `Produktname` bereits automatisch an, sobald noch kein `Produkt` vorliegt.
- `ArtikelEditView`: Alias-Verwaltungssektion bleibt erhalten, verwaltet
  jetzt `Artikel.alternativeNamen` statt `ArtikelAlias`-Zeilen (einfache
  Zeichenketten-Liste, keine geräteweite Eindeutigkeitsprüfung mehr nötig).
- `ProduktEditView`: neue Sektion für `Produkt.alternativeKlarnamen`.
- `PreispunktZuordnenSheet`: löst über `Produkt.aufgeloestesOderNeuesProdukt(...)`
  statt `ArtikelAlias.lernen(...)` auf.
- `ModellIDDuplikatService`: prüft `ArtikelAlias` weiterhin auf doppelte IDs
  (Entität bleibt vorerst bestehen, siehe „Migration" unten).
- Sync-Export/-Import: `ArtikelAlias` wird NICHT (mehr) synchronisiert — seine
  Restrolle ist rein lokal/transitorisch (siehe unten), `Produktname`-Sync
  deckt die eigentliche Rohtext-Zuordnung bereits vollständig ab.

### Migration — kein `SchemaV5`, sondern zweiphasiger Container-Start + Datenfunktion

**Zwei Ansätze scheiterten hier reproduzierbar an SwiftData-internen Bugs,
bevor die jetzige, sichere Lösung gefunden wurde — dokumentiert, damit dieser
Weg nicht erneut versucht wird:**

1. `Preispunkt.geschaeft` non-optional machen UND parallel eine neue
   `VersionedSchema`-Stufe dafür einführen, ohne sonst etwas zu ändern:
   crasht mit `NSInvalidArgumentException: The current model reference and
   the next model reference cannot be equal` — SwiftData modelliert
   To-One-Relationships auf Storage-Ebene immer optional, ein Swift-seitig
   non-optionaler Typ erzeugt also keinen unterscheidbaren Schema-Checksum;
   zwei benachbarte Schema-Versionen mit identischem Checksum sind ungültig.
2. Als Reaktion darauf `ArtikelAlias`-Entfernung UND `Preispunkt.geschaeft`
   UND die neuen additiven Felder `Artikel.alternativeNamen`/
   `Produkt.alternativeKlarnamen` gemeinsam in einer `MigrationStage.custom`-
   Stufe `SchemaV4` → `SchemaV5`, mit `Artikel`/`Produkt`/`Preispunkt`/
   `ArtikelAlias` als eingefrorene, verschachtelte Typen (analog dem
   Muster von Schritt 1/5) — **crasht ebenfalls reproduzierbar**, mit
   `NSInvalidArgumentException: Duplicate version checksums detected`, sogar
   wenn NUR `Artikel`+`Produkt` (ohne `Preispunkt`/`ArtikelAlias`)
   verschachtelt werden. Per isoliertem Test verifiziert: derselbe
   vollständige ~25-Entitäten-Typkatalog als PLAINES `Schema([...])` (keine
   `VersionedSchema`) speichert denselben Fall (ein regulärer `Preispunkt`
   mit gesetztem `geschaeft`) klaglos — die Instabilität hängt also
   spezifisch am `VersionedSchema`-Verschachtelungsmechanismus für diese
   beiden reich vernetzten Hub-Typen, nicht an den Daten selbst. Zwei
   Apple-Developer-Forums-Threads (Suche „SwiftData duplicate version
   checksums" bzw. „current model reference cannot be equal") beschreiben
   strukturell verwandte, bislang ungelöste Fälle mit mehreren
   `VersionedSchema`-Stufen.

**Tatsächlich umgesetzte, sichere Lösung:** kein neues `VersionedSchema` für
diesen Schritt. Stattdessen:

- `SchemaDefinition.schema`/`.migrationPlan` bleiben **unverändert bei
  Version 4** (byte-identisch zum bereits monatelang produktiv laufenden
  Stand) — die Staged-Migration V1→V4 ist davon komplett unberührt, null
  zusätzliches Risiko für Bestandsnutzer.
- `SchemaDefinition.liveSchema` (neu): ein PLAINES `Schema([...])` mit dem
  vollständigen, aktuellen Typkatalog (inkl. der neuen
  `alternativeNamenRaw`/`alternativeKlarnamenRaw`-Felder auf `Artikel`/
  `Produkt`) — bewusst KEIN `Schema(versionedSchema:)`.
- `ShopWithMeApp.init()` öffnet den Store zweiphasig: zuerst kurz mit
  `schema`/`migrationPlan` (Phase 1, `migriereBisV4FallsNoetig(...)`) nur um
  eine anstehende Staged-Migration bis V4 auszulösen — der dabei entstehende
  `ModelContainer` wird sofort wieder fallengelassen (eigene Funktion, damit
  er vor Phase 2 garantiert dealloziert ist). Danach öffnet Phase 2 denselben
  Dateipfad separat mit `liveSchema`, OHNE Migrationsplan — SwiftData/
  CoreData übernimmt die beiden neuen optionalen Spalten automatisch
  (Lightweight-Inferenz über das gespeicherte Store-Metadaten-Modell, nicht
  über einen `VersionedSchema`-Vergleich).
- Die `ArtikelAlias`-Ablösung selbst läuft als reine, wiederholbare
  Datenfunktion NACH dem Öffnen: `ArtikelAlias.ueberfuehrenUndAufraeumenFallsNoetig(context:)`
  (analog `KaufEintrag.preisverlaufMigrierenFallsNoetig`, aufgerufen aus
  `ShopWithMeApp.init()`). Für jeden bestehenden `ArtikelAlias`-Eintrag:
  `erkannterName` → geschäftsunabhängiger `Produktname` am Standardprodukt
  des Artikels, `alternativerName` → `Artikel.alternativeNamen`, danach
  `context.delete(alias)`. Derselbe Durchlauf weist außerdem jedem
  bestehenden `Preispunkt` mit `geschaeft == nil` das Pseudo-Geschäft
  „Unbekannt" zu (`Geschaeft.unbekanntesGeschaeft(context:)` — find-or-create
  by Name, kein Sondermarkierungs-Feld im Modell). Idempotent (leerer
  zweiter Durchlauf legt nichts erneut an).
- **`ArtikelAlias` bleibt als `@Model` bestehen** (nur die Geschäftslogik
  wurde entfernt, siehe Doc-Kommentar an `ArtikelAlias.swift`) — dadurch
  ändert sich am Schema strukturell nichts, es ist also überhaupt keine neue
  `VersionedSchema`-Stufe nötig. Die Tabelle ist nach dem ersten Start dieser
  Version leer und bleibt es (nichts legt neue Zeilen an). Die tatsächliche
  Entfernung der Entität aus dem Schema ist als eigener, späterer,
  risikoarmer Schritt vorgesehen: sobald diese Version einmal gelaufen und
  die Tabelle nachweislich leer ist, eine reine additive/entfernende
  `.lightweight`-Stufe (kein Custom-Transform, keine Verschachtelung von
  `Artikel`/`Produkt` mehr nötig, da nichts mehr zu transformieren ist) —
  dasselbe bereits bewährte Muster wie `Produktname/barcode` zwischen V3→V4.

Verifiziert: `GeschaeftsPflichtMigrationTests.swift` (In-Memory-Context über
`SchemaDefinition.liveSchema`, deckt Pseudo-Geschäft-Zuweisung, `ArtikelAlias`
→ `Produktname`/`alternativeNamen`-Überführung und Idempotenz ab) sowie ein
manueller Simulator-Start (frischer Store, Zwei-Phasen-Öffnung ohne Absturz).

### Nicht Teil dieser Änderung

Die dritte, unabhängige Alias-Ebene (`Artikel.alternativeNamen`) war zuvor
kein separates Konzept — sie entstand erst durch diese Umstellung. Vorher
deckte `ArtikelAlias` sowohl die Rohtext- als auch die Artikel-Synonym-Rolle
gleichzeitig undifferenziert ab.

Details: [#128](https://github.com/McBoerny/ShopWithMe/issues/128).

## Schritt 7/6 — Produkt-Pflicht bei Preispunkt, `artikel` als abgeleitetes Feld

**Status: umgesetzt.** Löste die letzte verbliebene direkte
`Preispunkt`→`Artikel`-Kopplung auf, siehe „Verhältnis zum bestehenden Code"
oben:

- `Preispunkt.artikel`/`artikelNameSnapshot` als eigene gespeicherte Felder
  entfernt. `Preispunkt.artikel` ist seither eine abgeleitete Computed-Property
  (`produkt?.artikel`).
- `Preispunkt.produkt` ist die einzige tragende Zuordnung; ohne aufgelöstes
  `Produkt` entsteht seither kein `Preispunkt` mehr — der frühere Freitext-Fall
  „Ohne Artikel-Zuordnung" (`BelegScanView`/`PreisschildScanView` ohne
  Artikel-Treffer) entfällt ersatzlos, siehe `docs/BELEGSCAN.md`.
- `Produkt.preispunkte`-Löschregel geändert von `.nullify` auf `.cascade` —
  konsistent mit der bereits bestehenden `Artikel → Produkt`-Cascade (GitHub
  #47): löschen kaskadiert jetzt durchgängig von `Artikel` über `Produkt` bis
  `Preispunkt`, statt bei `Produkt` stehenzubleiben.
- `Preispunkt.geschaeftNameSnapshot` bleibt bewusst bestehen — anders als der
  Artikel-Bezug ist die `geschaeft`-Referenz strukturell (nicht nur durch
  Löschreihenfolge) verwundbar für baumelnde Referenzen aus dem Peer-Sync,
  siehe `docs/DATENSYNCHRONISATION.md` §4.5.
- Keine `SchemaVN`/`MigrationStage` nötig — Änderung direkt in `SchemaV1`, da
  zum Zeitpunkt der Umsetzung kein Altbestand existierte (siehe Hinweis
  „Schema-Historie zurückgesetzt" ganz oben).

## Offene Punkte / bewusst nicht Teil dieses Konzepts

- UI für die rekursive Ebene (Unter-Produkte) ist im ersten Schritt nicht
  vorgesehen, nur das Datenmodell soll das zulassen (wie ursprünglich in #47
  formuliert).
- Kein konkreter Implementierungsplan (Migrationsschritte, Testfälle) — das
  folgt erst, wenn die Umsetzung tatsächlich angegangen wird.
