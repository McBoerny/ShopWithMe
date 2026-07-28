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
Kategorie-Reihenfolge (``WarengruppenDistanzService``), KI-gestützte
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

## Doku-Konvention

Neue, substanzielle Design-/Architekturentscheidungen bekommen eine eigene
`docs/*.md`-Datei (Großschreibung, Unterstriche, z.B. `docs/THEMA.md`), statt als
weiterer Abschnitt an `docs/DECISIONS.md` angehängt zu werden. Von
`docs/ARCHITECTURE.md` (und ggf. `docs/ROADMAP.md`) mit einem kurzen Verweis darauf
verlinken, statt den vollen Inhalt zu duplizieren — Muster wie `docs/BELEGSCAN.md`,
`docs/DATABASE_CONCURRENCY.md`, `docs/LOGGING.md`, `docs/BUILD_WORKFLOW.md`.
`docs/DECISIONS.md` bleibt nur für kleinere, kurze Einzelentscheidungen (z.B.
Bundle-ID, Git-Autor).
