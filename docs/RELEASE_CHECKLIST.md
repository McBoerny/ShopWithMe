# Release-Checkliste (Minor/Major-Versionssprung)

Standardplan für jeden Minor- oder Major-Versionssprung (Änderung von `X.Y` in
`VERSION`/`MARKETING_VERSION`, siehe `docs/BUILD_WORKFLOW.md`). Ergänzt den dort
beschriebenen Checkpoint-Workflow (Changelog, DocC, Build-Nummer) um Review-,
Test- und Doku-Punkte.

## Bei jedem Minor- und Major-Bump

- [ ] **Code-Review** — `/code-review` über den Diff seit letztem Versionssprung
      laufen lassen (Korrektheit + Wiederverwendung/Simplify-Cleanups).
- [ ] **Leichter Security-Check** — manuell: keine Secrets/Keys im Code, neue
      Berechtigungen in `Info.plist` minimal und begründet, keine unsichere
      Datenablage außerhalb des SwiftData-Standardpfads bzw. des vom Nutzer
      gewählten Ordners (siehe `docs/ARCHITECTURE.md` → Datenbank-Speicherort).
- [ ] **Build-Sauberkeit** — `xcodegen generate` läuft sauber durch,
      `xcodebuild build` ohne neue Warnungen.
- [ ] **Automatisierte Tests** — `xcodebuild test` (Swift Testing), keine
      roten oder übersprungenen Tests.
- [ ] **Manueller UI-Test / Golden Path** — Kernflows durchklicken: Einkaufen,
      Artikel-/Geschäfte-/Abteilungen-Verwaltung, Belegscan, KI-Artikelvorschlag.
- [ ] **SwiftData-Migrationscheck** — falls sich das Datenmodell geändert hat:
      Store aus der vorherigen Version mit dem neuen Schema öffnen und auf
      Crash/Datenverlust prüfen (bekannte Fallen siehe
      `docs/BUILD_WORKFLOW.md`).
- [ ] **Dokumentationsabgleich** — `ARCHITECTURE.md`, `ROADMAP.md`,
      `PRODUCT_SPEC.md`, `DECISIONS.md`, `CHANGELOG.md` auf aktuellen Stand
      bringen (bereits Pflicht laut Checkpoint-Workflow).
- [ ] **Versions-/Signing-Check** — `MARKETING_VERSION`/`VERSION`-Datei
      konsistent, `DEVELOPMENT_TEAM` unverändert (`CBYLYH36PT`), Geräte-Build
      (`generic/platform=iOS`) einmal verifiziert.

## Zusätzlich nur bei Major-Bumps

- [ ] **Voller Security-Review** — `/security-review` über den gesamten Diff
      seit letztem Major-Release.
- [ ] **Vollständiger Regressionstest** — alle dokumentierten Sonderfälle
      gezielt durchspielen (z.B. Artikel ohne Abteilung, mehrere
      Einkaufslisten, abgehaktes Rückgängigmachen, Belegscan in beiden
      Kontexten — siehe Memory/`docs/DECISIONS.md`), nicht nur Golden Path.
- [ ] **Accessibility-Vollcheck** — VoiceOver-Durchlauf + Dynamic-Type-Extremwerte
      auf allen (nicht nur den geänderten) zentralen Views.
- [ ] **DocC-Vollständigkeitscheck** — Stichprobe über alle öffentlichen APIs,
      nicht nur die im aktuellen Diff neu hinzugekommenen.
- [ ] **App-Store/TestFlight-Vorbereitung** — Metadaten/Screenshots aktuell,
      Privacy-Nutrition-Label geprüft (insbesondere Kamera-/FoundationModels-
      Nutzung), Export-Compliance-Angabe geprüft.

## Warum diese Staffelung

Die App hat kein Backend (lokale SwiftData-Speicherung, FoundationModels/Vision
laufen on-device) — ein voller Security-Review bei jedem kleinen Minor-Bump
steht in keinem Verhältnis zur tatsächlichen Angriffsfläche. Ebenso wäre ein
kompletter Regressionstest aller Sonderfälle bei jedem kleinen Fix
unverhältnismäßig. Aufwendigere Punkte sind daher Major-Bumps vorbehalten;
Build/Tests/Kern-Doku bleiben bei jedem Versionssprung Pflicht.

Entschieden 2026-07-06 (interaktive Abstimmung, siehe Session-Memory).
