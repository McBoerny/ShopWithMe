# ShopWithMe — Bedienungsanleitung

Kompakter Überblick, wie du mit ShopWithMe einkaufst und die App einrichtest — ein
Abschnitt je Funktionsbereich, kein Schritt-für-Schritt für jedes einzelne
UI-Element. Für die technische Spezifikation siehe [PRODUCT_SPEC.md](PRODUCT_SPEC.md),
für die Versionshistorie [CHANGELOG.md](CHANGELOG.md).

Diese Anleitung ist die maßgebliche, vollständige Quelle — die kuratierte In-App-Hilfe
(„Hilfe & Anleitungen“ in den Einstellungen) deckt bewusst nur eine Auswahl der
komplexeren Funktionen ab und darf dieser Anleitung inhaltlich nicht widersprechen.

## Die drei Bereiche der App

Die App startet immer direkt mit der Einkaufsliste.

- **Einkaufen** — die eigentliche Einkaufsliste, Standort-Erkennung, Abhaken.
- **Scannen** — direkter Belegscan ohne vorherige Geschäftswahl, jederzeit über den
  mittleren Tab erreichbar (siehe „Belegscan & Preisschild-Scan“ unten). Ergänzt,
  ersetzt aber nicht die weiteren Belegscan-Wege aus dem Einkaufen-Tab bzw. aus der
  Geschäfts-Detailansicht.
- **Einstellungen** — Hilfe, Artikel- und Geschäfte-Verwaltung (inkl. Regale,
  Kategorien pro Geschäft), Datenbank-Speicherort.

## Artikel

Jeder Artikel hat einen Namen, eine oder mehrere Kategorien (z.B. Obst,
Milchprodukte — Mehrfachauswahl beim Bearbeiten), eine Einheit (Stück, kg, g, l,
ml) und eine Standardmenge — die zugleich die Schrittweite ist, um die die Menge
beim Einkaufen erhöht/verringert wird. Hat ein Artikel mehrere Kategorien,
entscheidet pro Geschäft automatisch eine davon über seine Regal-Zuordnung beim
Einkaufen (die mit eigenem Regal in diesem Geschäft, sonst die im Geschäft
verfügbare). Neue Artikel legst du meist direkt beim Einkaufen an (landen dann
automatisch auf der Liste); in der Artikel-Verwaltung (Einstellungen) per „+“
angelegte Artikel landen nicht automatisch auf der Liste. Beim Anlegen schlägt
Apple Intelligence (sofern auf deinem Gerät verfügbar) automatisch eine passende
Kategorie vor, sobald du einen Namen eingibst — eine bereits von dir gewählte
Kategorie wird dabei nie überschrieben. Ist Apple
Intelligence nicht verfügbar, bleibt die manuelle Auswahl jederzeit möglich.

## Geschäfte

Ein Geschäft hat einen oder mehrere Typen (Lebensmittel, Drogerie, Baumarkt,
Apotheke, …, z.B. Drogerie + Lebensmittel bei einem dm — Mehrfachauswahl beim
Bearbeiten der Stammdaten) und optional eine Adresse. Kategorien sind der primäre Weg, Artikel für ein Geschäft
verfügbar zu machen — direkt im Geschäft zuordenbar, ganz ohne Regal. Regale sind
zusätzlich optional und dienen vor allem dazu, die Reihenfolge beim Einkaufen zu
organisieren; du kannst ihnen ebenfalls Kategorien zuordnen. Die Regal-Reihenfolge
legst du entweder manuell per Drag & Drop fest, oder die App lernt sie automatisch
aus deinen tatsächlichen Einkäufen (nach 5 Einkäufen in diesem Geschäft angeboten,
deine manuelle Reihenfolge bleibt so lange bestehen, bis du den Vorschlag explizit
übernimmst).

**Standort-Erkennung:** Beim Öffnen des Einkaufen-Tabs prüft die App per einmaliger
Standortabfrage, ob du dich in der Nähe eines bekannten oder von Apple Maps
erkannten Ladens befindest, und schlägt ihn in einem Banner vor — direkt zur
Auswahl (bekannt) oder zum Anlegen mit vorausgefüllten Daten (unbekannt). Über das
„…“-Menü des Banners lässt sich ein Vorschlag dauerhaft ignorieren oder „Alle
Geschäfte in der Nähe“ öffnen (zeigt auch ignorierte, mit Möglichkeit zum
Wiederaufnehmen). Ein neues Geschäft lässt sich davon unabhängig jederzeit rein
manuell anlegen — die Standort-Erkennung ist nur eine Ergänzung. Fehlen einem
Geschäft noch Koordinaten, fragt dich die App beim nächsten Auswählen, ob sie den
aktuellen Standort oder eine (ggf. neu eingegebene) Adresse dafür verwenden soll.

## Einkaufen

Die Einkaufsliste ist global, nicht an ein Geschäft gebunden. Wählst du zusätzlich
ein Geschäft, wird sie nach dessen Regal-Reihenfolge gruppiert; Artikel ohne
passende Kategorie/Regal-Zuordnung erscheinen trotzdem, in einer eigenen
„Sonstige“-Sektion. Ein Einkauf startet automatisch beim Öffnen des Tabs, kein
manueller Start nötig.

- **Tap** auf eine Zeile erhöht die Menge, **Doppel-Tap** verringert sie (nie unter
  die Schrittweite). **Langes Drücken** öffnet ein Sheet für eine exakte Menge und
  eine temporäre Notiz.
- **Abhaken** geschieht über die eigenständige Checkbox am Zeilenende.
- Standardmäßig zeigt die App nur im gewählten Geschäft verfügbare Artikel. Die
  Schnellauswahl (Symbol neben „Artikel hinzufügen“) bündelt zwei Anzeigeoptionen:
  kurzer Tap blendet zusätzlich bereits abgehakte Artikel ein (durchgestrichen,
  antippen macht das Abhaken rückgängig); langer Tap öffnet den Lernmodus, der alle
  Artikel der Liste einblendet, auch bislang nicht als verfügbar geltende — dadurch
  lernt die App sie für dieses Geschäft als verfügbar.
- Per Wischgeste lässt sich ein bereits abgehakter Artikel dauerhaft aus dieser
  Ansicht entfernen (landet dann nicht wieder auf der offenen Liste).
- Ein Einkauf lässt sich jederzeit abschließen, auch mit offenen Artikeln — die
  bleiben einfach auf der globalen Liste.

## Belegscan & Preisschild-Scan

Vier gleichwertige Wege zum Belegscan: nach dem Abschließen eines Einkaufs (Angebot,
den Kassenbon direkt zu scannen), über den **Scannen-Tab** (jederzeit, ohne
vorherige Geschäftswahl — nach dem Übernehmen bzw. „Verwerfen“ direkt wieder bereit
für den nächsten Scan), über das Scannen-Menü beim Einkaufen für das gerade
gewählte Geschäft, oder direkt in der Geschäfts-Detailansicht — z.B. für ältere,
nachträglich gefundene Bons.

Lokale KI erkennt Geschäft, Datum, Artikel und Preise (Foto oder aus der
Mediathek) und trägt sie in die passenden Positionen ein. Für jede Position
versucht die App automatisch, den auf dem Bon erkannten (oft abgekürzten) Namen
einem deiner vorhandenen Artikel zuzuordnen — gelingt das, zeigt das Feld den
generischen Namen (z.B. „Zahnpasta“) mit dem Original-Beleg-Text „COL-ZAH“ klein
darunter; gelingt es nicht, ist die Position als „Neu erkannt“ markiert. Tippst du
ins Namensfeld, schlägt dir die App passende vorhandene Artikel zum Antippen vor,
oder du legst über „„…“ neu anlegen“ direkt einen neuen Artikel an. Nicht
benötigte Positionen kannst du vor der Übernahme entfernen: Wischen nach links
löscht eine Position nur für diesen Scan, Wischen nach rechts ignoriert sie
dauerhaft für dieses Geschäft (z.B. für wiederkehrende Pfand-/Rabattzeilen).

Wird das Geschäft auf dem Bon nicht erkannt (oder gibt es mehrere Geschäfte mit
demselben Namen), fragt dich die App danach, ggf. mit Kurzadresse zur
Unterscheidung namensgleicher Filialen.

Das Original-Foto wird in der Prüf-Ansicht direkt oben angezeigt (zoom-/schwenkbar
per Pinch-/Zieh-Geste) — praktisch, um die KI-Erkennung visuell zu verifizieren.
Das Lupen-Symbol neben einer Position (falls vorhanden) scrollt dorthin und hebt
die erkannte Stelle im Beleg farblich hervor. „Abbrechen“ schließt die Prüf-Ansicht
immer sofort, ohne Rückfrage.

Der **Preisschild-Scan** (Geschäfts-Detailansicht oder während des Einkaufens)
erfasst stattdessen ein einzelnes Regal-Preisschild — nützlich für einen
Preisvergleich vor der Kaufentscheidung, ohne auf den Kassenbon zu warten.

Alle erfassten Preise findest du als Preishistorie in der Artikel- bzw.
Geschäfts-Detailansicht.

## MilkForUs-Textimport

In der Einkaufslisten-Verwaltung (Einstellungen) importierst du über „MilkForUs
importieren“ eine aus der Shopping-App „MilkForUs“ exportierte Textdatei — entweder
per Datei-Auswahl, oder direkt über die Teilen-Funktion eines anderen Apps (z.B.
eine per Chat empfangene Datei per „Teilen“ → „ShopWithMe“). In der Vorschau siehst
du je MilkForUs-Kategorie, ob eine bestehende Kategorie automatisch erkannt wurde
(exakter Name oder KI-Vorschlag), oder ob eine neue angelegt würde — per Antippen
lässt sich das auf eine andere bestehende Kategorie oder „Sonstiges“ umstellen.
Bereits vorhandene Artikel werden nur auf die gewählte Liste gesetzt, nie
dupliziert; einzelne Artikel lassen sich vor dem Übernehmen per Wischgeste aus dem
Import ausschließen.

## Einstellungen

- **Hilfe & Anleitungen** — kuratierte Kurzhilfe zu den komplexeren Funktionen
  (Ergänzung zu dieser Anleitung, siehe oben).
- **Artikel / Geschäfte / Kategorien / Einkaufslisten** — die vollständige
  Verwaltung (Anlegen/Bearbeiten/Löschen); die App startet immer direkt mit der
  Einkaufsliste, Artikel und Geschäfte sind daher nur noch hier erreichbar.
- **Preishistorie** — Aufbewahrungsdauer/Bereinigung alter Preiseinträge.
- **Datenbank & Speicherort** — verlegt deine Daten in einen selbst gewählten
  Ordner, z.B. einen lokal gespiegelten Cloud-Ordner. Kein automatischer
  Mehrgeräte-Sync (kein iCloud-Sync) — bei einem Cloud-Ordner die App bewusst nur
  auf einem Gerät gleichzeitig aktiv nutzen, um Konflikte zu vermeiden. Wirkt erst
  nach einem Neustart der App.
- **DB-Debug-Modus** — Diagnose-Protokollierung für den Mehrgeräte-Zugriff, im
  Normalbetrieb nicht nötig.
