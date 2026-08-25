---
name: shopwithme-conventions
description: ShopWithMe-spezifische Vorgaben — Projektüberblick/Domänenmodell, Checkpoint-/Versionierungs-Workflow, Bedienungsanleitung, Doku-Konvention, Release-Checkliste, Code-Signing-Team dieses Projekts. Nutze dies bei jeder Arbeit im ShopWithMe-Repo zusätzlich zum generischen ios-swift-engineering-Skill.
---

# ShopWithMe — projektspezifische Vorgaben

Generische iOS/Swift/SwiftData-Praxis (Signing-Auswahlverfahren, Migrationsentscheidung,
Deprecated-API-Disziplin, Verifikationsumfang) steht im projektübergreifenden Skill
`ios-swift-engineering`. Hier stehen nur die für **dieses** Projekt konkreten Werte
und Workflows.

## Projektüberblick

ShopWithMe ist eine iOS-only SwiftUI-App (kein macOS-Target) zum täglichen Einkaufen:
Artikel mit Kategorien, Geschäfte mit direkt zugeordneten Kategorien (das
frühere separate `Regal`-Modell wurde entfernt, GitHub #35 — Kategorien werden
seither direkt am Geschäft geführt), eine aus dem Abhakverhalten lernende
Kategorie-Reihenfolge (``AbteilungsDistanzService``), KI-gestützte
Artikelanlage (FoundationModels), Belegscan mit Preishistorie, mehrere benannte
Einkaufslisten, sowie eine event-basierte Mehrgeräte-Datensynchronisation über
einen geteilten Ordner (GitHub #39, kein CloudKit/eigener Server).

**Maßgebliche, aktuelle Quelle für Architektur/Spezifikation:** `docs/PRODUCT_SPEC.md`,
`docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md` im Repo — bei
inhaltlichen Fragen zum Domänenmodell dort nachlesen, nicht raten.

**Tech-Entscheidungen:** SwiftData (kein Core Data/iCloud), XcodeGen statt
Hand-`.xcodeproj`, Bundle-ID `com.made4me.ShopWithMe`, min. iOS 26 (Liquid Glass +
FoundationModels), Swift Testing (nicht XCTest) für Unit-Tests.

## Code-Signing

`DEVELOPMENT_TEAM: CBYLYH36PT` (in `project.yml` für `ShopWithMe`/`ShopWithMeTests`,
`CODE_SIGN_STYLE: Automatic`). Dasselbe Team wie im Schwesterprojekt ImmoHunter
(gleicher Apple-Account). Auswahlverfahren bei Unsicherheit/Änderung: siehe
generischer Skill `ios-swift-engineering`, Abschnitt Code-Signing — nicht neu raten.

## Checkpoint-/Versionierungs-Workflow

Das allgemeine Versionsnummern-Prinzip (manuelle Major/Minor, automatische
Build-Nummer, nie eigenmächtig Minor/Major erhöhen) steht projektübergreifend im
Skill `ios-swift-engineering`, Abschnitt "Versionsnummern". Die konkrete Umsetzung
in diesem Repo (Checkpoint-Ablauf, Versionsschema, Ablage von Major.Minor/
Build-Nummer, Git-Hook-Aktivierung) steht **vollständig und maßgeblich** in
`docs/BUILD_WORKFLOW.md` — dort bei Änderungen aktualisieren, nicht hier
duplizieren (vormals an beiden Stellen fast wortgleich gepflegt, seit 2026-07-21
aufgelöst).

Bei jedem inhaltlich größeren Änderungsblock automatisch nach diesem Ablauf einen
Git-Checkpoint erzeugen, ohne explizit danach gefragt zu werden.

## Release-Checkliste

Bei jedem Minor-/Major-Versionssprung zusätzlich die gestaffelte Checkliste in
`docs/RELEASE_CHECKLIST.md` abarbeiten (Code-Review, leichter Security-Check,
Build/Tests, Migrationscheck, Doku-Abgleich bei jedem Bump; voller Security-Review,
kompletter Regressionstest, Accessibility-Vollcheck, App-Store/TestFlight-Vorbereitung
zusätzlich nur bei Major). Bei künftigen Änderungen an diesem Standardplan dort
direkt aktualisieren, nicht in diesem Skill duplizieren.

## Bedienungsanleitung

Datei: `docs/BEDIENUNGSANLEITUNG.md` — kompakte End-Nutzer-Anleitung, ein Abschnitt
je Funktionsbereich (Artikel, Geschäfte, Einkaufen, Belegscan/Preisschild-Scan,
Einstellungen), bewusst kein Schritt-für-Schritt für jedes einzelne UI-Element. Bei
jedem neuen Feature/jeder für den Anwender sichtbaren Funktionsänderung im selben
Arbeitsschritt aktualisieren (siehe generischer Skill `ios-swift-engineering`,
Abschnitt „Nutzer-Bedienungsanleitung im selben Arbeitsschritt pflegen“).

**Maßgeblich gegenüber der In-App-Hilfe** (`HelpView.swift`, aktuell 5 kuratierte
Themen zu den komplexeren Funktionen): Abweichungen zwischen beiden zugunsten der
Bedienungsanleitung auflösen. `HelpView.swift` muss nicht jedes Detail der
Anleitung enthalten (bleibt bewusst eine kuratierte Kurzfassung), darf ihr aber
inhaltlich nicht widersprechen.

`README.md` verlinkt sowohl auf `docs/CHANGELOG.md` als auch auf
`docs/BEDIENUNGSANLEITUNG.md`.

## Typografische Anführungszeichen in Swift-Dateien — VERBOTENE FEHLERQUELLE

**Das Edit-Tool konvertiert ASCII-`"` (U+0022) in typografische Curly-Quotes `"` / `"` (U+201C/D), wenn der neue Text Standard-Anführungszeichen enthält.** Das bricht Swift-String-Literale sofort, weil der Swift-Compiler U+201C/D als illegale String-Delimiter behandelt und Fehler wie „Unterminated string literal", „Cannot find 'X' in scope" oder „Invalid character in source file" wirft. Dreimal in diesem Projekt passiert.

**Pflichtregeln:**

1. **Nach jedem Edit mit String-Literalen sofort `XcodeRefreshCodeIssuesInFile` aufrufen** — nicht erst beim vollständigen Build.

2. **Im `old_string` des Edit-Tools: typografische Quotes so übernehmen, wie sie in der Datei stehen** (also `"` / `"` statt `"`), damit das Tool keine Konvertierung vornimmt. Mit `cat -v` oder Python prüfen, welcher Byte-Wert tatsächlich in der Datei steht.

3. **Im `new_string`: niemals `"` (U+201D) oder `"` (U+201C) als String-Delimiter** schreiben. Quoted Terms in Swift-Strings mit `\"...\"`  oder `\u{201E}...\u{201D}` formulieren.

4. **Fix, wenn es trotzdem passiert:** Python-Byte-Ersetzung auf den betroffenen Zeilen:
   - `\xe2\x80\x9c` (U+201C) → `\x22` (ASCII `"`)
   - `\xe2\x80\x9d` (U+201D) bei Paaren (U+201D gefolgt von U+201D): erstes behalten (Inhalt), zweites → `\x22`
   - `\xe2\x80\x9d` (U+201D) allein → `\x22`
   - Zeilen außerhalb des bearbeiteten Bereichs **nicht** anfassen (dort können U+201D korrekte Inhalts-Zeichen sein).

Gilt auch für `@Guide`-Macro-Attribute in `@Generable`-Structs.

## Belegscan-Integrationstests: Fixture-Regeln

Fixture-Dateien in `ShopWithMeTests/Belege/*.json` repräsentieren die autoritären
Zielerwartungen des Scanners. Für die KI gelten folgende Regeln:

- **Fixtures nie selbst ändern.** Weder Erwartungswerte abschwächen (Trefferquote
  senken, Datum/Adresse anpassen) noch Items entfernen, um einen Test grün zu machen.
- **Änderungen nur durch den User.** Die KI darf jedoch Korrekturen *vorschlagen*,
  wenn offensichtliche Authoring-Fehler entdeckt werden (z.B. Copy-Paste-Datum,
  falsches Dezimaltrennzeichen).
- **Codeverbesserung steht im Vordergrund.** Schlägt ein Test fehl, wird der
  Scanner-Code (`ReceiptScanService.swift`) oder die Test-Matching-Logik
  (`BelegScanIntegrationTests.swift`) verbessert — nicht das Fixture.
- **Typische Verbesserungsansätze:**
  - `@Guide`/`anweisungen` im Scanner präzisieren (Datum, Mengen, Markennamen vs.
    Firmenname, Abkürzungen)
  - Adress-/Namensvergleich im Test normalisieren (Umlaute: ü↔ue, ß↔ss) um
    KI-korrekte UTF-8-Ausgaben gegen ASCII-Fixtures matchen zu können
  - OCR-Parameter tunen (z.B. `minimumTextHeight`, Sprache)

## Suchleisten-Konvention (GitHub #144)

Listenansichten verwenden für die Suche einheitlich `.searchable(text:prompt:)`
direkt auf der `List` — Referenzmuster: `ProduktVerwaltungView.swift`. Ein
eigenes, dauerhaft sichtbares Suchfeld statt `.searchable(...)` ist nur zulässig,
wenn die Abweichung im Code explizit begründet dokumentiert ist — Referenz:
`ArtikelHinzufuegenView.swift` (`.searchable(..., placement:
.navigationBarDrawer(displayMode: .always), ...)` kombiniert mit
`.searchFocused(_:)` statt `isPresented:` — siehe
`docs/ARTIKEL_HINZUFUEGEN_INTERAKTION.md` —, sofort sichtbar und fokussiert
statt per Pull-to-Search, weil beim Artikel-hinzufügen-Sheet sofortige
Sucheingabe erwartet wird).

## Icon-Farben-Konvention (GitHub #142)

Content-Icons neben Text (Symbole, die einen Sachverhalt illustrieren, keine
Auswahl-/Statusindikatoren) werden einheitlich in der Textfarbe dargestellt
(`.foregroundStyle(.primary)` bzw. implizit über umgebende Textfarbe), nicht in
`Color.accentColor`. Ausnahme: eine fachlich vorgegebene explizite Farbe, z.B.
`Color(hex: abteilung.standardFarbeHex)` bei Abteilungssymbolen, oder
Statusfarben mit eigener Bedeutung (grün=erledigt, orange=Warnung). Reine
Auswahl-Checkmarks (Standard-iOS-Muster für "ausgewählt") und
Kartenoverlays fallen nicht unter diese Regel.

## Doku-Konvention

Neue, substanzielle Design-/Architekturentscheidungen bekommen eine eigene
`docs/*.md`-Datei (Großschreibung, Unterstriche, z.B. `docs/THEMA.md`), statt als
weiterer Abschnitt an `docs/DECISIONS.md` angehängt zu werden. Von
`docs/ARCHITECTURE.md` (und ggf. `docs/ROADMAP.md`) mit einem kurzen Verweis darauf
verlinken, statt den vollen Inhalt zu duplizieren — Muster wie `docs/BELEGSCAN.md`,
`docs/DATABASE_CONCURRENCY.md`, `docs/LOGGING.md`, `docs/BUILD_WORKFLOW.md`.
`docs/DECISIONS.md` bleibt nur für kleinere, kurze Einzelentscheidungen (z.B.
Bundle-ID, Git-Autor).

## Sync-Merge-Existenzprüfungen — bekannte Fehlerquelle (GitHub #175)

Vor jeder neuen/geänderten Existenzprüfung („gibt es dafür schon eine Zeile")
in einer `mergeX`-Funktion (`SyncSnapshotImportService.swift`, aufgerufen aus
`mergePaket`/`importiereSnapshots`): **`docs/DATENSYNCHRONISATION.md` §4.9
lesen.** Kurzfassung: `mergePaket` läuft einmal pro Peer-Ordner, sequentiell,
in einem `ModelContext`, `context.save()` erst nach der kompletten
Peer-Schleife — eine Existenzprüfung über eine `@Relationship`-Sammlung
(z.B. `liste.eintraege`) sieht einen soeben von einem ANDEREN, bereits
abgeschlossenen Peer-Aufruf eingefügten Datensatz nicht zuverlässig (live
bestätigt: zwei Peers meldeten denselben Artikelnamen im selben Importlauf,
beide legten eine Zeile an). Pflicht stattdessen: `context.fetch(...)` oder
ein `inout`-nachgeführtes Dictionary/Set. Gegenregel für rein lokale
Einzelaktionen (kein Merge, kein zweiter Peer) steht ebenfalls dort —
`context.fetch` ist NICHT pauschal die sicherere Wahl.
