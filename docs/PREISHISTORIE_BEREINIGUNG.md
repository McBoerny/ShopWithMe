# ShopWithMe — Automatische Bereinigung der Preishistorie

Status: **Umgesetzt** (`Services/PreisHistorieBereinigungService.swift`,
`Views/Einstellungen/PreisHistorieSettingsView.swift`).

## Ausgangslage

Jeder Belegscan und jedes Abhaken auf der Einkaufsliste erzeugt einen dauerhaften
`KaufEintrag` (siehe `docs/BELEGSCAN.md`). Ohne Aufräummechanismus wächst diese
Preishistorie unbegrenzt — für Nutzer, die keinen Wert auf eine unbegrenzte Historie
legen, bietet die App deshalb eine automatische, konfigurierbare Löschung alter
Einträge an.

## Verhalten

- **Aufbewahrungsfrist** (`PreisHistorieAufbewahrung`): 30 Tage / 3 Monate / 6 Monate /
  1 Jahr / Nie / eigene Anzahl Tage. Wird über `UserDefaults` persistiert
  (`PreisHistorieBereinigungService.aktuelleAufbewahrung`), einstellbar in
  `PreisHistorieSettingsView` (Einstellungen → „Preishistorie“).
- **Standard: „Nie“** — bewusste Entscheidung, damit ein App-Update bei bestehenden
  Nutzern nicht ungefragt Preishistorie löscht. Der Nutzer muss die automatische
  Bereinigung aktiv einschalten.
- **Automatischer Trigger**: `RootView` ruft
  `PreisHistorieBereinigungService.automatischBereinigenFallsFaellig(context:)` bei
  App-Start sowie bei jedem Wechsel von `scenePhase` auf `.active` auf. Ein internes
  Mindestintervall (`automatischesIntervall`, 24h) verhindert, dass bei jedem
  Vordergrund-Wechsel erneut gefetcht wird.
- **Manueller Trigger**: Button „Jetzt bereinigen“ in `PreisHistorieSettingsView`, zeigt
  Zeitpunkt der letzten Bereinigung sowie die Anzahl zuletzt gelöschter Einträge.
- **Schutz laufender Einkäufe**: `PreisHistorieBereinigungService.bereinigen(context:
  aufbewahrung:jetzt:)` lässt `KaufEintrag`e eines noch nicht abgeschlossenen
  `Einkaufsvorgang`s (`istAbgeschlossen == false`) immer unangetastet, unabhängig vom
  Alter — ein noch laufender Einkauf darf dadurch nie kaputtgehen.
- Löschungen laufen über `DatabaseLeaseService.performMicroLease`, wie jeder andere
  Schreibzugriff auch (siehe `docs/DATABASE_CONCURRENCY.md`).

Es entsteht bewusst **kein separater Store/keine Archivierung** — gelöschte Einträge
sind endgültig weg. Für Nutzer, die die volle Historie behalten möchten, bleibt „Nie“
die Standardeinstellung.
