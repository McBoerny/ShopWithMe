# ShopWithMe — Umgang mit Builds, Versionierung & Migrationen

Praktische Checkliste für jeden Checkpoint/Commit in diesem Projekt. Die Begründung
hinter den einzelnen Regeln steht in `docs/DECISIONS.md` — dieses Dokument ist bewusst
knapp und handlungsorientiert gehalten.

## Checkpoint-Ablauf (bei jedem inhaltlich größeren Änderungsblock)

1. `docs/CHANGELOG.md` um einen Eintrag ergänzen: Überschrift `## vX.Y — <Kurzbeschreibung>`
   (die Build-Nummer trägt der Pre-Commit-Hook automatisch ein, siehe unten).
2. Alle neuen/öffentlichen Swift-APIs mit `///`-DocC-Kommentaren versehen.
3. Bei Änderung eines `@Model`-Typs: Migrationsentscheidung treffen (siehe Abschnitt
   „SwiftData-Migration“ unten), **bevor** committet wird.
4. Bei Anhebung von **Major.Minor** (`X.Y`, nicht nur der Build-Nummer): zusätzlich die
   übrige Doku aktualisieren — mindestens `docs/ARCHITECTURE.md` und `docs/ROADMAP.md`,
   ggf. `docs/PRODUCT_SPEC.md` und feature-spezifische Docs (z.B. `docs/BELEGSCAN.md`),
   damit sie nicht hinter dem seit dem letzten Versions-Checkpoint erreichten Stand
   zurückbleiben.
5. Verifizieren: `xcodegen generate` + `xcodebuild build` (und wo sinnvoll `test`) —
   siehe „Build-Umgebung“ unten für das benötigte `DEVELOPER_DIR`.
6. Committen. Commit-Message-Format: `vX.Y: <Kurzbeschreibung>`.
7. `.xcodeproj` wird **nie** committet (siehe `.gitignore`) — nur `project.yml`.

## Versionsschema

Format `vMajor.Minor (Build N)`, seit 2026-07-04 (ab v0.1, Build 17):

- **Major.Minor** (`MARKETING_VERSION` in `project.yml`, gespiegelt in `VERSION`) wird
  ausschließlich **manuell vom Nutzer** festgelegt — keine Automatik erhöht diese Zahl.
- **Build N** (`CURRENT_PROJECT_VERSION`) wird automatisch bei jedem Commit über
  `.githooks/pre-commit` um 1 erhöht; derselbe Hook trägt die neue Build-Nummer in die
  oberste `docs/CHANGELOG.md`-Überschrift ein (`## vX.Y (Build N) — Titel`).
- Aktivierung pro Klon nötig, da `core.hooksPath` nicht versioniert wird:
  `git config core.hooksPath .githooks`.

## SwiftData-Migration: wann welche Schema-Version?

Modelle liegen in diesem Projekt als flache, einzige Klassen vor (`Models/*.swift`),
nicht pro Schema-Version eingefroren. Das hat eine wichtige Konsequenz (siehe
`Models/SchemaDefinition.swift` und `docs/DECISIONS.md` → „Duplicate version
checksums“-Vorfall):

- **Additiv-optionales Attribut** (Normalfall — z.B. `Geschaeft.regalSortierModus`,
  `KaufEintrag.produktName`/`alternativerName`): **keine** neue `SchemaVN`/
  `MigrationStage`. Nur als `private var xyzRaw: String?` (o.ä.) speichern und über ein
  Computed-Property mit sicherem Fallback kapseln (Vorbild:
  `Geschaeft.regalSortierModus`). SwiftDatas klassische Lightweight-Migration
  übernimmt die neue Spalte zuverlässig, `SchemaV1` bleibt unverändert.
- **Strukturelle Änderung** (geänderter Typ, Umbenennung, neues nicht-optionales
  Attribut ohne sinnvollen Default, Daten-Transformation bestehender Zeilen): **hier**
  eine neue `SchemaVN` + `MigrationStage` (`.custom` mit explizitem Backfill) in
  `Models/SchemaDefinition.swift` einführen — und dabei die betroffenen Modelltypen
  tatsächlich pro Version einfrieren/verschachteln statt dieselbe lebende Klasse
  mehrfach zu referenzieren (sonst „Duplicate version checksums“-Crash).

**Bestätigt (2026-07-05):** Diese Unterscheidung ist weiterhin maßgeblich — eine
pauschale Regel „jede Modelländerung bekommt ein neues Migrationsschema“ gilt
ausdrücklich **nicht** für additiv-optionale Attribute.

## Build-Umgebung

`xcode-select` zeigt auf dieser Maschine auf die Command-Line-Tools, nicht auf
Xcode.app. Für Builds/Tests immer `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
voranstellen statt `sudo xcode-select` zu verwenden (kein Passwort nötig, kein
systemweiter Nebeneffekt):

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ShopWithMe.xcodeproj -scheme ShopWithMe -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Bekannte Fallstricke

- **`ModelContext` hält den erzeugenden `ModelContainer` nicht stark.** Wird der
  Container nur lokal erzeugt und nur der Context zurückgegeben (z.B. in
  Test-Hilfsfunktionen), wird der Container deallokiert und spätere
  Context-Zugriffe crashen (SIGTRAP). Immer Container UND Context gemeinsam am Leben
  halten (siehe `ShopWithMeTests/ModelTests.swift`).
- **Neues nicht-optionales Attribut auf ausgeliefertem Modell crasht beim
  Lightweight-Migrate** (v1.4→v1.5-Vorfall), sobald ein *vor* der Änderung angelegter
  Datensatz das Attribut zum ersten Mal liest — auch mit Default-Wert in der
  Deklaration. Reproduzierbar nur außerhalb von Unit-Tests (die immer frische
  In-Memory-Stores nutzen). Fix-Pattern: siehe „SwiftData-Migration“ oben.
- **Zwei `VersionedSchema`s, die dieselben lebenden Modell-Typen referenzieren, haben
  denselben Prüfsummen-Hash** → `NSInvalidArgumentException: Duplicate version
  checksums detected` beim Öffnen eines bestehenden Stores. Siehe „SwiftData-Migration“
  oben.
