# ShopWithMe — Entscheidungen

## Persistenz: SwiftData statt Core Data

SwiftData passt nativ zu SwiftUI (`@Model`, `@Query`), unterstützt benutzerdefinierte
`ModelConfiguration(url:)` — wichtig für die Anforderung, den Datenbank-Speicherort zu
wechseln — ohne den Overhead von Core Data + NSPersistentCloudKitContainer, den wir
aktuell (kein iCloud-Sync) ohnehin nicht brauchen.

## Projekt-Tooling: XcodeGen statt handgepflegtem `.xcodeproj`

Ein `.xcodeproj` ist eine fehleranfällige XML-Struktur, die außerhalb von Xcode schwer
korrekt von Hand zu pflegen ist. `project.yml` ist textuell diffbar, wird versioniert;
das generierte `.xcodeproj` wird bewusst **nicht** committet (`.gitignore`) und per
`xcodegen generate` reproduziert.

## Bundle-ID & Ziel-OS

- Bundle-ID: `com.made4me.ShopWithMe` (Nutzervorgabe).
- Min. Deployment-Target iOS 26.0 — das ist die erste Version mit Liquid Glass und dem
  FoundationModels-Framework, beides zentrale Anforderungen. Kein macOS-Target.
- Build-Umgebung: Xcode 26.6 / iOS-SDK 26.5, angesteuert über die Umgebungsvariable
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` statt einer systemweiten
  `xcode-select -s`-Umstellung (vermeidet sudo/Passwort-Interaktion, kein Nebeneffekt
  außerhalb dieses Projekts).

## Kategorien wichtiger als Regale: direkte Geschäft-Kategorie-Zuordnung (ab v0.1, Build 23)

**Ursprüngliche Entscheidung (bis Build 22):** Kein separates "Kategorie pro Geschäft
verfügbar"-Modell — die Zuordnung Kategorie → Regal (pro Geschäft) implizierte bereits
die Verfügbarkeit der Kategorie in diesem Geschäft, um Inkonsistenzen zu vermeiden
(z.B. Kategorie am Regal, aber nicht separat als "verfügbar" markiert).

**Korrektur (Nutzervorgabe):** Regale sind optional, Kategorien nicht. Ein Geschäft
kann Kategorien jetzt direkt zugeordnet bekommen (`Geschaeft.kategorien`), unabhängig
davon, ob überhaupt ein Regal existiert. `Geschaeft.verfuegbareKategorien` ist die
Vereinigung aus dieser direkten Zuordnung und den über Regale zugeordneten Kategorien
(`Regal.kategorien`). Ein Regal organisiert damit nur noch, in welcher Reihenfolge
bereits verfügbare Kategorien beim Einkaufen abgelaufen werden — es ist keine
Voraussetzung mehr für Verfügbarkeit. Die eingangs befürchtete Inkonsistenz
(Kategorie doppelt als verfügbar markiert, direkt und über ein Regal) ist unkritisch,
da `verfuegbareKategorien` dedupliziert.

## "iOS 27"-Funktionen

Zum Zeitpunkt der Umsetzung (Juli 2026) ist kein iOS-27-SDK auf der Entwicklungsmaschine
installiert, und es liegen keine verifizierten API-Namen für eine mögliche künftige,
spezialisierte On-Device-Beleg-Scan-API vor. Der Belegscan wird daher auf bekannten,
realen iOS-26-APIs (Vision + FoundationModels) gebaut, gekapselt hinter dem
`ReceiptScanService`-Protokoll, damit ein Austausch später ohne UI-Änderungen möglich
ist.

## Git-Checkpoint-Workflow

Siehe [ROADMAP.md](ROADMAP.md) für die Checkpoint-Liste. Regel: bei jedem inhaltlich
größeren Commit bekommt `docs/CHANGELOG.md` einen Eintrag, und alle neuen
öffentlichen Swift-APIs erhalten `///`-DocC-Kommentare, bevor committet wird.
`.xcodeproj` wird nie committet (siehe oben).

## Versionsschema: manuelle Major/Minor-Version, automatische Build-Nummer (ab v0.1)

Bis v1.6 wurde die Version als einzelner Zähler geführt, der pro Checkpoint um `0.1`
erhöht wurde (0.1 → 0.2 → … → 1.6). Ab sofort (Nutzervorgabe) gilt ein
zweigeteiltes Schema, Format `vMajor.Minor (Build N)`:

- **Major.Minor** (`MARKETING_VERSION` in `project.yml`, gespiegelt in der
  `VERSION`-Datei) wird ausschließlich manuell vom Nutzer festgelegt — keine
  Automatik erhöht diese Zahl mehr.
- **Build N** (`CURRENT_PROJECT_VERSION` in `project.yml`) wird automatisch bei
  jedem Commit um 1 erhöht, über den Git-Hook `.githooks/pre-commit`. Der Hook
  trägt die neue Build-Nummer zusätzlich in die oberste Überschrift von
  `docs/CHANGELOG.md` ein (`## vX.Y (Build N) — Titel`), damit jeder Commit über
  seine Build-Nummer eindeutig einem Changelog-Eintrag zuzuordnen ist.
- Aktivierung ist lokal pro Klon nötig (Git versioniert `core.hooksPath` nicht):
  `git config core.hooksPath .githooks`.
- Mit der Umstellung wurde die Version einmalig auf `0.1` zurückgesetzt; die
  Build-Nummer knüpft an die Anzahl bisheriger Commits an, statt bei 1 neu zu
  beginnen.

## `KaufEintrag.preis` ist optional

Ursprünglich (v0.1) war `preis: Decimal` ein Pflichtfeld. Beim Bau des
Einkaufen-Flows (v0.4) wurde klar: Ein `KaufEintrag` entsteht bereits beim Abhaken auf
der Einkaufsliste — der Preis ist an dieser Stelle noch unbekannt und wird erst durch
den späteren Belegscan (v0.7) nachgetragen. `preis` wurde daher auf `Decimal?`
geändert. Zusätzlich wurde `KaufEintrag.regal` ergänzt, damit die Regal-Zuordnung zum
Kaufzeitpunkt dauerhaft festgehalten wird (unabhängig von späteren Änderungen der
Regal-Kategorie-Zuordnung) — Grundlage für den Lern-Algorithmus (v0.5).

## KI-Regalvorschlag ist rein informativ

`ArtikelVorschlag.regalName` (FoundationModels-Ausgabe) wird nicht automatisch in ein
Datenmodell geschrieben, weil ``Regal`` immer zu genau einem ``Geschaeft`` gehört —
ein neu angelegter, noch keinem Geschäft zugeordneter Artikel kann kein konkretes
Regal referenzieren. Der Hinweis wird daher nur als Text angezeigt, den der Anwender
später in der Geschäfte-Verwaltung selbst umsetzen kann.

## Datenbank-Speicherort: reine Dateiverlagerung, kein Hot-Swap

Ein Wechsel des Speicherorts kopiert die SwiftData-Store-Dateien in den gewählten
Ordner und hinterlegt ein Security-Scoped-Bookmark; wirksam wird das erst beim
nächsten App-Start (`ShopWithMeApp.init()` liest das Bookmark und baut den
`ModelContainer` mit der neuen `ModelConfiguration(url:)` auf). Ein Hot-Swap des
laufenden `ModelContainer` wurde bewusst nicht umgesetzt — das SwiftUI-Setup bindet
den Container einmalig über `.modelContainer(_:)` an die Scene, ein Laufzeitwechsel
wäre unverhältnismäßig riskant (offene `ModelContext`-Referenzen, laufende Queries)
für den Nutzen gegenüber einem einfachen Neustart-Hinweis.

## Explizite SwiftData-Migrationslogik (`SchemaMigrationPlan`) ab v1.5

Auslöser: In v1.4 crashte die App beim Öffnen eines vor v1.4 angelegten Geschäfts,
weil ein neues nicht-optionales Attribut (`Geschaeft.regalSortierModus`) auf einem
bestehenden Modell ergänzt wurde und SwiftDatas automatische Lightweight-Migration
den fehlenden Spaltenwert bestehender Datensätze nicht sauber auf das Enum casten
konnte (`Could not cast value of type 'Swift.Optional<Any>' to 'RegalSortierModus'`).
Reproduziert über ein eigenständiges Migrationsexperiment außerhalb der (immer
frischen, In-Memory-)Unit-Tests.

Statt uns weiterhin auf implizites Lightweight-Migrationsverhalten zu verlassen,
gibt es ab jetzt einen expliziten `SchemaMigrationPlan` (`Models/SchemaDefinition.swift`:
`SchemaV1`, `ShopWithMeMigrationPlan`), über den der `ModelContainer` in
`ShopWithMeApp.swift` aufgebaut wird.

**Regel: Jede künftige Datenmodell-Änderung (neues Attribut, neues Modell, geänderter
Typ, Umbenennung, …) bekommt eine neue `SchemaVN` samt `MigrationStage`** —
Vorgehen und Kriterien (wann `.lightweight` reicht vs. wann `.custom` mit explizitem
Daten-Backfill nötig ist) sind ausführlich in der DocC-Dokumentation von
`ShopWithMeMigrationPlan` beschrieben. Zusätzlich bleibt die defensive Regel aus dem
v1.4-Vorfall bestehen: neue gespeicherte Attribute auf bestehenden Modellen als
optionalen Rohwert speichern und über ein Computed-Property mit sicherem Fallback
kapseln (siehe `Geschaeft.regalSortierModus`) — das fängt auch Fälle ab, die die
Migrationsstufe selbst nicht abdeckt.

**Korrektur (Kaufbeleg-Datum/Produktname-Feature):** Die Regel oben ist unvollständig
für dieses Projekt. Modelle werden hier als flache, einzige Klassen gepflegt (z.B.
`Models/KaufEintrag.swift`), nicht pro Schema-Version eingefroren/verschachtelt. Eine
zusätzliche `SchemaV2`, die dieselben lebenden Modell-Typen wie `SchemaV1`
referenziert, hat deshalb exakt denselben Prüfsummen-Hash — beim Testlauf crashte die
App reproduzierbar beim Öffnen des Stores mit
`NSInvalidArgumentException: Duplicate version checksums detected`, weil zwei
unterschiedlich deklarierte Versionen auf ein identisches Schema abbilden. Für rein
additive, optionale neue Attribute (wie `KaufEintrag.produktName`) bleibt es daher bei
der **einzigen** `SchemaV1` + der defensiven Optional-Regel — SwiftDatas klassische
automatische Lightweight-Migration (ohne expliziten Migrationsplan-Stage) übernimmt
die neue Spalte zuverlässig. Eine echte zusätzliche `SchemaVN` samt `MigrationStage`
ist erst gerechtfertigt, wenn bestehende Daten tatsächlich transformiert werden müssen
(`.custom`) — und würde dann zusätzlich verlangen, die betroffenen Modelltypen pro
Version einzufrieren/zu verschachteln, statt (wie hier vermieden) dieselbe lebende
Klasse mehrfach in verschiedenen `VersionedSchema`s zu referenzieren.

**Korrektur (GitHub #119, "unknown model version"-Crash):** Mit der ersten
echten `MigrationStage` (`SchemaV1` → `SchemaV2`, GitHub #112, v0.14) zeigte
sich eine dritte Falle, zusätzlich zu den beiden oben: `SchemaV1Frozen.swift`
friert das Modell exakt zu EINEM Zeitpunkt ein (Commit `3f38616`). Jedes
Bestandsgerät, das zwischen einer früheren additiven Änderung (z.B. GitHub
#99/#102, beide rein additiv und bis dahin unkritisch unter der einzigen
`SchemaV1` gelaufen) und genau diesem eingefrorenen Zeitpunkt pausiert hatte,
trägt einen on-disk-Schema-Fingerabdruck, der weder `SchemaV1` noch
`SchemaV2` entspricht — die gestufte Migrations-Engine bricht dann mit
`Cannot use staged migration with an unknown model version` ab. Betrifft
praktisch jedes Gerät, das nicht exakt bis zum Einfrier-Commit mitgelaufen
ist, bevor die erste echte `MigrationStage` auf ein Gerät trifft.

**Fix:** ``ShopWithMeApp/oeffneContainer(schema:konfiguration:)`` fängt einen
gescheiterten `ModelContainer`-Öffnungsversuch ab und verwirft den nicht mehr
migrierbaren Store physisch
(``SyncErsetzenService/loescheUnlesbarenStoreUndPlaneWiederherstellung(url:)``).
Anders als beim regulären `SyncErsetzenService.planeErsetzenDurchPeer(context:)`
ist dabei kein Vorher-Backup möglich (der Store war beim Fehlschlag bereits
ungeöffnet) — jeder lokale, noch nicht synchronisierte Stand geht verloren.

**Korrektur 2 (kein In-Process-Retry):** Ein erster Entwurf versuchte nach dem
Verwerfen sofort erneut, im selben Prozess einen frischen `ModelContainer` zu
öffnen. Live-Test (GitHub #119) zeigte, dass dieser zweite Versuch zuverlässig
identisch scheitert — SwiftData/CoreData behält den
Staged-Migration-Manager-Zustand offenbar prozessweit bei, unabhängig davon,
ob die Store-Datei zwischenzeitlich gelöscht wurde (deckt sich mit Berichten im
Apple Developer Forum zu genau diesem Fehlerbild). Der Fix merkt den
Wiederaufbau deshalb nur vor (`SyncErsetzenService.ausstehendeAktion =
.ersetzenDurchPeer`) und lässt den ursprünglichen Fehler unverändert
weiterlaufen — ein einmaliger, unvermeidbarer Absturz, danach öffnet der
NÄCHSTE Prozessstart den (bereits gelöschten) Store frisch und
``SyncErsetzenService/fuehreAusstehendeAktionAus(context:)`` füllt ihn aus dem
Sync-Ordner wieder auf, exakt wie beim bereits bestehenden
Wipe-und-Neuaufbau-Mechanismus. Gilt für jede künftige `MigrationStage`
gleichermaßen, nicht nur für diesen einen Vorfall.

**Nachtrag (2026-08-22, GitHub #128/#129) — Schema-Historie zurückgesetzt:**
Bei der Ablösung von `ArtikelAlias` (Geschäfts-Pflicht bei `Preispunkt`) stieß
eine weitere, tiefere Falle auf: reich vernetzte "Hub"-Modelltypen (`Artikel`/
`Produkt`, viele Relationships zueinander und zu anderen Typen) crashen beim
Einfrieren in einer `VersionedSchema`-Stufe reproduzierbar — selbst wenn alle
oben genannten Regeln korrekt befolgt werden, sogar schon beim Speichern
eines ganz gewöhnlichen Objekts, nicht erst bei der Migration selbst. Details
und der sichere Workaround (zweiphasiger Container-Start statt einer neuen
`VersionedSchema`-Stufe) stehen dauerhaft im `ios-swift-engineering`-Skill.
Da sich die App noch in der Entwicklungsphase befand und der lokale Store zu
diesem Zeitpunkt ohnehin zurückgesetzt wurde, entschied sich das Projekt für
den pragmatischeren Weg: die komplette bisherige `VersionedSchema`-Historie
(`SchemaV1Frozen.swift`…`SchemaV4`, `ShopWithMeMigrationPlan`) wurde
ersatzlos gelöscht und durch einen frischen `SchemaV1`-Ausgangspunkt mit dem
aktuellen Modell ersetzt (`Models/SchemaDefinition.swift`, kein Migrationsplan
mehr). Die obigen Lektionen (additiv vs. strukturell, Checksum-Kollisionen,
"unknown model version") bleiben für **künftige** strukturelle Änderungen
weiterhin uneingeschränkt gültig — nur die konkret zitierten `SchemaV1`/
`SchemaV2`-Dateien von damals existieren nicht mehr.

## Git-Autor (lokal, nur dieses Repo)

`user.name`/`user.email` wurden nur lokal für dieses Repo gesetzt (nicht global), da
kein globaler Git-Autor konfiguriert war. Bei Bedarf mit `git config user.name/email`
anpassen.

## Regal-Entfernung: adaptive Sortierung ersetzt manuelle Zwischenschicht (v0.6, GitHub #35)

**Rückblick:** `Regal` wurde in v0.3 eingeführt, um Kategorien innerhalb eines
Geschäfts zu einer Sortiereinheit zu bündeln (manuelle Reihenfolge oder ab v0.5 ein
gelernter Durchschnittswert je Regal, `ShelfOrderLearningService`/
`KategorieBesuchsStatistik`). Die frühere Entscheidung oben („Kategorien wichtiger als
Regale“) hatte `Regal` bereits auf eine rein optionale Sortier-Hilfsstruktur reduziert,
ohne Einfluss auf Verfügbarkeit.

**Auslöser der Entfernung:** Mit der in Build 95 eingeführten
`AbteilungsDistanzService`-Sortierung (paarweise gelernte Distanz je
Kategorie-Paar und Geschäft statt eines einzelnen Skalars je Kategorie, siehe
`docs/ARCHITEKTURVORSCHLAG_ADAPTIVE_SORTIERUNG.md`) deckt die automatische Sortierung
dasselbe Problem feiner und ganz ohne manuellen Pflegeaufwand ab. `Regal` als
zusätzliche, vom Anwender anzulegende und zu benennende Zwischenschicht hatte damit
keinen Zweck mehr. Da `ShelfOrderLearningService` und `KategorieBesuchsStatistik`
ausschließlich von `Regal` aus aufgerufen wurden, waren beide nach dessen Entfernung
selbst verwaist und wurden im selben Zug entfernt (Nutzerentscheidung, alle drei
zusammen statt schrittweise zu entfernen).

**Konsequenz für bestehende Daten:** `Regal` und `KategorieBesuchsStatistik` wurden
aus `SchemaDefinition.swift`s Modell-Liste entfernt. SwiftDatas automatische
Lightweight-Migration verwirft dadurch beim nächsten Start jede bereits gespeicherte
Regal- bzw. Kategorie-Besuchsstatistik-Zeile unwiderruflich — anders als bei rein
additiven Attributänderungen (siehe Abschnitt oben) ist das hier bewusst in Kauf
genommen, da die entfernten Tabellen ohne die zugehörigen Modelltypen ohnehin nicht
mehr lesbar wären und ihr einziger Zweck (Regal-Zuordnung/-Reihenfolge) mit der
Entfernung selbst entfällt. `Geschaeft`/`ArtikelKategorie`/`KaufEintrag` und alle
sonstigen Daten bleiben unverändert erhalten.
