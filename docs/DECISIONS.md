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

## Kein separates "Kategorie pro Geschäft verfügbar"-Modell

Die Zuordnung Kategorie → Regal (pro Geschäft) impliziert bereits die Verfügbarkeit der
Kategorie in diesem Geschäft. Ein zusätzliches Zuordnungsmodell hätte zu Inkonsistenzen
führen können (z.B. Kategorie am Regal, aber nicht separat als "verfügbar" markiert).

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

## Git-Autor (lokal, nur dieses Repo)

`user.name`/`user.email` wurden nur lokal für dieses Repo gesetzt (nicht global), da
kein globaler Git-Autor konfiguriert war. Bei Bedarf mit `git config user.name/email`
anpassen.
