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
größeren Commit wird die erste Nachkommastelle der Version erhöht (0.1 → 0.2 → …),
`docs/CHANGELOG.md` bekommt einen Eintrag, und alle neuen öffentlichen Swift-APIs
erhalten `///`-DocC-Kommentare, bevor committet wird. `.xcodeproj` wird nie committet
(siehe oben).

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

## Git-Autor (lokal, nur dieses Repo)

`user.name`/`user.email` wurden nur lokal für dieses Repo gesetzt (nicht global), da
kein globaler Git-Autor konfiguriert war. Bei Bedarf mit `git config user.name/email`
anpassen.
