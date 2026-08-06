# Artikel/Produkt/Produktname-Modell (GitHub #47)

**Status: Schritte 1–3/5 umgesetzt** ([#112](https://github.com/McBoerny/ShopWithMe/issues/112)
Datenmodell + Migration, [#113](https://github.com/McBoerny/ShopWithMe/issues/113)
Sync-Integration, [#114](https://github.com/McBoerny/ShopWithMe/issues/114)
Preis-Aggregation) — Schritte 4–5 (UI, Scan-Zuordnung) noch offen, siehe
Umsetzungsplan in #47. Präzisiert und ersetzt die ursprüngliche Formulierung
in
[#47](https://github.com/McBoerny/ShopWithMe/issues/47) (dort noch
"Ausprägung" genannt) — siehe Diskussion vom 2026-08-06. Abgegrenzt von, aber
verwandt mit den bereits umgesetzten Artikel-Alias-Namen
([#111](https://github.com/McBoerny/ShopWithMe/issues/111), v0.13).

## Umsetzungsstand Schritt 1/5 (v0.14)

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

## Die drei Ebenen

```
Artikel (generisch, KEIN eigener Preis)
  │
  ├─ 1:n → Alias-Name              (umgesetzt, #111)
  │         reine Textsuche, immer derselbe Artikel, kein eigenes Produkt
  │
  └─ 1:n → Produkt                  (NEU, dieses Dokument)
             konkretes, kaufbares Ding — trägt den Preis
             │
             ├─ 1:n → Produkt       (rekursiv, z.B. Packungsgrößen-Varianten)
             │
             └─ 1:n → Produktname   (NEU, pro Geschäft ein eigener Name)
```

**Beispiel:**

- Artikel "Zahnpasta"
  - Alias-Namen: "Zahncreme", "Zahnreiniger"
  - Produkte: "Odol", "Paradontol Zahncreme", "Sebamed"
    - Produkt "Paradontol Zahncreme"
      - Unter-Produkte (Packungsgrößen): "Paradontol 75ml", "Paradontol 125ml"
      - Produktnamen: Geschäft A → "Parad Zahncr", Geschäft B → "Paradontol Zahn"

## Regeln

1. **Artikel hat nie einen eigenen Preis.** Der Artikel ist nur die generische
   Bezeichnung/Gruppierung (z.B. "Zahnpasta"), unter der beim Einkaufen gesucht
   und auf der Liste abgehakt wird.
2. **Produkt trägt den Preis** — aber nur, wenn es selbst keine Unter-Produkte
   hat (Blatt der Hierarchie). Hat ein Produkt Unter-Produkte, kumuliert es
   deren Preise (Minimum/Maximum über alle Blätter), trägt aber selbst keinen
   direkten `Preispunkt`. Gleiche Kumulierungslogik wie ursprünglich in #47 für
   den Artikel beschrieben, jetzt eine Ebene tiefer angesiedelt.
3. **Produktname ist geschäftsabhängig**, im Unterschied zum Artikel-Alias
   (der geschäftsunabhängig ist). Ein Produkt kann in Geschäft A unter einem
   anderen Namen im Kassenbon/Preisschild erscheinen als in Geschäft B — beide
   Namen gehören zum selben Produkt.
4. **Ein Nutzer darf jederzeit einen eigenständigen Artikel statt eines
   Produkts anlegen**, wenn er ein gefundenes Produkt lieber als eigenen
   Artikel führen will (Präzedenzfall aus der ursprünglichen #47-Formulierung
   für "Chinakohl" vs. "Salat" — gilt unverändert).

## Verhältnis zum bestehenden Code

Aktuell trägt **`Preispunkt`** (`Preispunkt.swift:16-60`) den Preis direkt am
`Artikel` (`var artikel: Artikel?`) und bildet den Produktnamen nur als loses
Textfeld ab (`produktName`, `alternativerName` — beide direkt am einzelnen
Preispunkt, nicht an einer wiederverwendbaren Entität). Da `Preispunkt`
bereits `artikel` **und** `geschaeft` trägt, ist die Geschäftsabhängigkeit des
Namens strukturell schon vorhanden — nur nicht als eigenständiges "Produkt",
das über mehrere Preispunkte/Geschäfte hinweg wiedererkannt würde.

Für die Umsetzung müsste `Preispunkt.artikel` zu `Preispunkt.produkt` werden
(Preis hängt am Produkt, nicht mehr direkt am Artikel) — eine **strukturelle**
SwiftData-Änderung (Relationship-Ziel wechselt den Typ), keine additive.
Bestehende `Preispunkt`-Daten bräuchten beim Rollout eine Migration auf
synthetische "ein Produkt pro bisherigem Artikel"-Einträge, damit nichts
verloren geht — vergleichbares Risikoprofil wie
[#88](https://github.com/McBoerny/ShopWithMe/issues/88).

`ArtikelPreisSpanne.gruppieren(_:)` (`ArtikelPreisSpanne.swift:23-36`)
gruppiert aktuell direkt nach Artikel — müsste um eine Produkt-Zwischenebene
ergänzt werden.

Verwandt: [#10](https://github.com/McBoerny/ShopWithMe/issues/10) (offene
Modellfrage, ob `produktName` als loses Feld reicht — durch dieses Konzept
beantwortet: nein, eine eigenständige `Produkt`-Entität ist nötig, damit
derselbe Produktname über mehrere Geschäfte/Preispunkte hinweg
wiedererkannt wird statt bei jedem Scan neu als Text zu entstehen).

## Offene Punkte / bewusst nicht Teil dieses Konzepts

- UI für die rekursive Ebene (Unter-Produkte) ist im ersten Schritt nicht
  vorgesehen, nur das Datenmodell soll das zulassen (wie ursprünglich in #47
  formuliert).
- Kein konkreter Implementierungsplan (Migrationsschritte, Testfälle) — das
  folgt erst, wenn die Umsetzung tatsächlich angegangen wird.
