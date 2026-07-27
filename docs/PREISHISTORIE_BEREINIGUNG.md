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

## Design-Entscheidung: kein separater DB-Store für die Preishistorie

Ursprünglich angefragt war, die Preishistorie in eine **eigene, vom Hauptstore
getrennte Datenbank** auszulagern (eigene `.sqlite`-Datei), damit Aufbewahrung/Löschung
unabhängig vom übrigen Datenmodell verwaltet werden kann. Das wurde bewusst **nicht**
umgesetzt — nur die Lösch-Logik oben.

**Grund:** `KaufEintrag` hat zwei Rollen gleichzeitig:

1. Preishistorie-Datensatz (Anzeige in `ArtikelEditView`/`PreisHistorieZeile`/
   `GeschaeftDetailView`).
2. Operative Grundlage des laufenden `Einkaufsvorgang`s — `artikel`, `geschaeft`,
   `kategorie` und `einkaufsvorgang` sind echte SwiftData-`@Relationship`s
   (`Einkaufsvorgang.kaufEintraege` z.B. mit `deleteRule: .cascade`).

SwiftData unterstützt keine `@Relationship`s, deren Zielobjekt in einem *anderen*
`ModelConfiguration`/Store liegt als das Quellobjekt — beide Seiten einer Beziehung
müssen im selben Store liegen. Ein zweiter Store für `KaufEintrag` (oder ein neues,
schlankeres Preis-Modell) hätte diese Relationships daher zwangsläufig durch reine
UUID-Referenzen mit manuellem Nachschlagen ersetzt — ein invasiver Eingriff quer durch
`Einkaufsvorgang`, `WarengruppenDistanzService`, `BelegScanView` und die zugehörigen
Tests, für einen Nutzen (unabhängige Aufbewahrungsfrist), der sich wie oben gezeigt
auch ohne Store-Trennung erreichen lässt.

**Erwogene Alternative (verworfen):** ein neues, eigenständiges Modell
`PreisEintrag` (nur Snapshot-Felder, keine Relationships) in einem zweiten Store,
zusätzlich zu `KaufEintrag.preis` befüllt, sobald ein Preis erfasst wird. Verworfen,
weil dadurch der Preis dauerhaft doppelt vorläge (`KaufEintrag.preis` **und**
`PreisEintrag.preis`) und beide Seiten synchron gehalten werden müssten — ein
Aufwand, der einer echten künftigen Store-Trennung vorbehalten bleiben sollte, falls
sie tatsächlich gebraucht wird (siehe `docs/ROADMAP.md`).
