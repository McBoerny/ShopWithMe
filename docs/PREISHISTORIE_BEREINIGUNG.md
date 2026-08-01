# ShopWithMe — Automatische Bereinigung: Preishistorie und KaufEintrag

Status: **Umgesetzt**, seit GitHub #76 aufgeteilt in zwei unabhängige Services mit
unterschiedlicher Philosophie:

| | `PreisHistorieBereinigungService` | `KaufEintragBereinigungService` |
| --- | --- | --- |
| Zielmodell | `Preispunkt` (echte Preishistorie) | `KaufEintrag` (operative Buchungszeile, seit #76 ohne Preisrolle) + leer gewordene `Einkaufsvorgang`e |
| Frist | nutzerkonfigurierbar, Standard „Nie“ | fest, kurz (`karenzzeit`, Standard 48h), nicht einstellbar |
| Sichtbar für Nutzer | ja (Einstellungen → „Preishistorie“) | nein, rein technisch |
| Warum überhaupt aufbewahren | der Nutzer will seine Preishistorie ggf. behalten | ein `KaufEintrag` hat nach Abschluss seines Einkaufsvorgangs **keine fachliche Funktion mehr** (siehe unten) — es gibt fachlich keinen Grund, ihn lange zu behalten |

## `PreisHistorieBereinigungService` (`Preispunkt`)

Jeder Belegscan/Preisschild-Scan mit erfasstem Preis erzeugt einen `Preispunkt`
(siehe `docs/BELEGSCAN.md`). Ohne Aufräummechanismus wächst diese Preishistorie
unbegrenzt — für Nutzer, die keinen Wert auf eine unbegrenzte Historie legen, bietet
die App deshalb eine automatische, konfigurierbare Löschung alter Einträge an.

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
- Löschungen hinterlassen einen `SyncTombstone` (siehe unten) und laufen über
  `DatabaseLeaseService.performMicroLease`, wie jeder andere Schreibzugriff auch
  (siehe `docs/DATABASE_CONCURRENCY.md`).
- Kein Schutz für „laufenden Einkauf“ nötig — `Preispunkt` hat keinen Bezug zu einem
  `Einkaufsvorgang`.

Es entsteht bewusst **kein separater Store/keine Archivierung** — gelöschte Einträge
sind endgültig weg. Für Nutzer, die die volle Historie behalten möchten, bleibt „Nie“
die Standardeinstellung.

## `KaufEintragBereinigungService` (`KaufEintrag` + leer gewordene `Einkaufsvorgang`e)

**Seit GitHub #76:** ein `KaufEintrag` verliert nach Abschluss seines
`Einkaufsvorgang`s jede fachliche Funktion — `WarengruppenDistanzService` hat seinen
Beitrag bereits synchron beim Abschluss verarbeitet
(`WarengruppenDistanzService.verarbeiteEinkauf(_:context:)`), die Preisrolle liegt
vollständig bei `Preispunkt`, und die Einkaufslisten-Mitgliedschaft wurde bereits beim
Abhaken entfernt. Es gibt deshalb fachlich keinen Grund für eine lange, gar
nutzerkonfigurierbare Aufbewahrung wie bei der Preishistorie — die Bereinigung läuft
**immer aktiv, ohne Einstellung**, mit einer festen, kurzen Karenzzeit
(`karenzzeit`, Standard 48h).

- **Warum überhaupt eine Karenzzeit statt sofortiger Löschung nach Abschluss:**
  ein nachträglicher Belegscan (`BelegScanView` im `.einkaufsvorgang`-Kontext,
  `passtZu`-Namensabgleich gegen `einkaufsvorgang.kaufEintraege`) muss den gerade
  abgeschlossenen Einkauf noch finden können, sonst legt er fälschlich neue,
  eigenständige `Preispunkt`e statt die bestehenden Buchungszeilen zu nutzen.
  48h ist dieselbe Größenordnung wie `SyncImportService.maximalesEventAlterFuerRetry`.
- **Verallgemeinerung gegenüber der früheren KaufEintrag-basierten Fassung dieses
  Services (vor GitHub #76, siehe Git-Historie):** löscht abgeschlossene Vorgänge
  unabhängig davon, ob sie (noch) eine `Einkaufsliste`-Zuordnung haben — anders als
  `DatenintegritaetsService.raeumeLeereListenloseVorgaengeAuf(context:)`, das nur den
  engeren, strukturellen Fall (listenlos UND leer) automatisch bei jedem App-Start
  bereinigt.
- **Beide Löschungen (KaufEintrag und Einkaufsvorgang) hinterlassen einen
  `SyncTombstone`** — ursprünglich bewusst unterlassen (siehe
  `docs/DATENSYNCHRONISATION_VERLAUF.md`, Abschnitt 11 „Bewusst nicht enthalten"),
  das machte die Bereinigung im Mehrgeräte-Fall aber faktisch wirkungslos: der
  additive Bereich-C-Merge (Union nach `id`, nie destruktiv) brachte einen lokal
  gelöschten Eintrag beim nächsten Sync von jedem Peer zurück, der ihn noch führte.
- **Schutz laufender Einkäufe**: `KaufEintragBereinigungService.bereinigen(context:jetzt:)`
  lässt `KaufEintrag`e eines noch nicht abgeschlossenen `Einkaufsvorgang`s
  (`istAbgeschlossen == false`) immer unangetastet, unabhängig vom Alter.
- **Bekannter, gefixter Stolperstein (GitHub #77):** ein `#Predicate` mit
  Force-Unwrap (`$0.endZeit! < stichtag`) lieferte in einem gezielten
  Isolationstest nachweislich keine Treffer, obwohl derselbe Vergleich in reinem
  Swift auf denselben Objekten korrekt `true` ergab — die Vorgang-Kandidaten werden
  deshalb über einen ungefilterten Fetch + Swift-seitigen `.filter` bestimmt, nicht
  über ein `#Predicate`. Außerdem wird „wird dieser Vorgang durch diesen Durchlauf
  leer" bewusst **vor** jeder Löschung berechnet (über die noch unveränderte
  `kaufEintraege`-Relationship), nicht danach — SwiftData aktualisiert diese inverse
  Relationship nachweislich erst bei/nach `context.save()`, nicht sofort bei
  `context.delete(...)`.
- Automatischer Trigger analog `PreisHistorieBereinigungService`, eigenes
  `UserDefaults`-Intervall (`kaufEintragBereinigungLetzteBereinigung`), aufgerufen in
  `RootView` direkt neben dem Preishistorie-Aufruf.

## Design-Entscheidung: kein separater DB-Store für die Preishistorie

**Historisch (vor GitHub #76) — die eigentliche Rollentrennung ist seitdem über
`Preispunkt` gelöst, siehe oben.** Der Abschnitt bleibt als Begründung stehen, warum
die Lösung ein **eigenständiges Model im selben Store** war, statt eines separaten
`.sqlite`-Stores (der bewusst verworfene Weg unten).

Ursprünglich angefragt war, die Preishistorie in eine **eigene, vom Hauptstore
getrennte Datenbank** auszulagern (eigene `.sqlite`-Datei), damit Aufbewahrung/Löschung
unabhängig vom übrigen Datenmodell verwaltet werden kann. Das wurde bewusst **nicht**
umgesetzt — nur die Lösch-Logik oben (damals noch auf `KaufEintrag`).

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
