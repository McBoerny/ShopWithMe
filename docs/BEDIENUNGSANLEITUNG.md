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
- **Einstellungen** — Hilfe, Artikel- und Geschäfte-Verwaltung (inkl. Warengruppen
  pro Geschäft), Geschäftstypen-Verwaltung, Datenbank-Speicherort,
  Datensynchronisation.

## Artikel

Jeder Artikel hat einen Namen, eine oder mehrere Warengruppen (z.B. Obst,
Milchprodukte — Mehrfachauswahl beim Bearbeiten), eine Einheit (Stück, kg, g, l,
ml) und eine Standardmenge — die zugleich die Schrittweite ist, um die die Menge
beim Einkaufen erhöht/verringert wird. Hat ein Artikel mehrere Warengruppen (z.B.
Ohropax unter „Drogerie" und „Reisebedarf"), erscheint er beim Einkaufen
gleichzeitig in allen zugehörigen Abschnitten — abgehakt wird er dabei überall
auf einmal. Aus welchem Abschnitt du ihn tatsächlich abhakst, merkt sich die App
pro Geschäft: so lernt sie z.B., dass Sojasauce bei Edeka unter „Soßen", bei
Aldi aber unter „Asia" steht. Neue Artikel legst du meist direkt beim Einkaufen an (landen dann
automatisch auf der Liste); in der Artikel-Verwaltung (Einstellungen) per „+“
angelegte Artikel landen nicht automatisch auf der Liste. Beim Anlegen schlägt
Apple Intelligence (sofern auf deinem Gerät verfügbar) automatisch eine passende
Warengruppe vor, sobald du einen Namen eingibst — eine bereits von dir gewählte
Warengruppe wird dabei nie überschrieben. Ist Apple
Intelligence nicht verfügbar, bleibt die manuelle Auswahl jederzeit möglich.

## Geschäfte

Ein Geschäft hat einen oder mehrere Typen (Lebensmittel, Drogerie, Baumarkt,
Apotheke, …, z.B. Drogerie + Lebensmittel bei einem dm — Mehrfachauswahl beim
Bearbeiten der Stammdaten) und optional eine Adresse. Warengruppen sind der primäre Weg, Artikel für ein Geschäft
verfügbar zu machen — direkt im Geschäft zuordenbar. Zusätzlich
macht jeder Geschäftstyp automatisch seine in den Einstellungen hinterlegten
Standard-Warengruppen verfügbar (siehe „Geschäftstypen“ unten) — ganz ohne sie dem
einzelnen Geschäft manuell zuzuordnen; wählst du später dort noch weitere
Warengruppen manuell aus, betrifft das nur dieses eine Geschäft, nicht generell den
Geschäftstyp. Die Reihenfolge, in der die Warengruppen beim Einkaufen erscheinen,
legst du nicht manuell fest — die App lernt sie automatisch aus deinem
Abhakverhalten (siehe „Einkaufen“ unten).

In der Detailansicht eines Geschäfts siehst du alle verfügbaren Warengruppen
gemeinsam, alphabetisch — automatisch über den Geschäftstyp verfügbare sind mit
„Automatisch über Geschäftstyp“ gekennzeichnet. Per Wischgeste lässt sich eine
solche automatische Warengruppe für dieses eine Geschäft ausschließen, ohne sie
generell vom Geschäftstyp zu entfernen — sie taucht danach wieder unter
„Warengruppe hinzufügen“ auf, falls du sie doch wieder brauchst. Manuell
zugeordnete Warengruppen entfernst du wie gewohnt per Wischgeste.

**Standort beim Anlegen/Bearbeiten:** Sobald ein Geschäft Koordinaten hat, zeigt
das Bearbeiten-Formular eine kleine Karte mit einem Pin — durch Antippen der
Karte lässt sich der Standort exakt setzen (die Adresse wird dabei automatisch
nachgetragen, falls noch keine hinterlegt ist). Alternativ füllt „Aktuellen
Standort verwenden“ Adresse und Koordinaten direkt aus deinem GPS-Standort, oder
du tippst eine Adresse ein und bestätigst mit der Eingabetaste — die Koordinaten
werden dann automatisch ermittelt, solange noch kein Standort gesetzt ist.

**Erkennungsradius:** Unter der Karte legt ein Schieberegler (20–500m) fest, in
welchem Umkreis um den Standort-Pin die App dieses Geschäft automatisch erkennt
— als Kreis direkt auf der Karte eingezeichnet. Die Karte zoomt dabei bewusst
nicht automatisch mit (weder beim Verschieben des Pins noch beim Ändern des
Radius) — Zoom/Ausschnitt bestimmst du selbst per Fingergeste. Standardmäßig
75m; bei einem großen Gelände (z.B. Baumarkt mit großem Parkplatz) lohnt sich
ein größerer Radius, bei mehreren dicht benachbarten Geschäften ein kleinerer,
um Verwechslungen zu vermeiden.

**Favoriten:** Sowohl in der Geschäfte-Übersicht (Einstellungen) als auch in der
Geschäftsauswahl beim Einkaufen erscheinen deine meistgenutzten Geschäfte vorab in
einer eigenen „Favoriten“-Sektion — ermittelt aus abgeschlossenen Einkäufen
innerhalb eines Zeitfensters (Standard: 30 Tage). Anzahl und Zeitfenster stellst du
über den Stern-Button in der Geschäfte-Übersicht ein. Jedes Geschäft zeigt
außerdem in seiner Detailansicht (Bearbeiten) einen Zähler abgeschlossener
Einkäufe, den du dort separat zurücksetzen kannst, sowie ein „Besuchsprotokoll“
mit Zeitpunkt und Dauer jedes Einkaufs.

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
Zusätzlich zu den Buttons/dem Menü lässt sich das Banner auch per Wischgeste
bedienen: nach rechts wischen entspricht dem Haupt-Button (auswählen/anlegen),
nach links dauerhaftem Ignorieren, nach oben dem einmaligen Verwerfen.

## Einkaufen

Die Einkaufsliste ist global, nicht an ein Geschäft gebunden. Wählst du zusätzlich
ein Geschäft, wird sie nach Warengruppe gruppiert. Ein Einkauf startet
automatisch beim Öffnen des Tabs, kein manueller Start nötig.

Der Bildschirmtitel zeigt neben dem Listennamen deinen Fortschritt für diesen
Einkauf, Format „<Name> (<abgehakt>/<gesamt>)“, z.B. „Wocheneinkauf (3/8)“.

Die Liste sortiert sich mit der Zeit selbst: ShopWithMe lernt aus der
Reihenfolge, in der du Artikel abhakst, welche Warengruppen in diesem Geschäft
nah beieinanderliegen, und passt die Reihenfolge nach jeder Abhakung automatisch
an deinen aktuellen Standort in der Liste an — ganz ohne Ladenplan oder
Standortfreigabe. Ein kleiner Hinweis oben zeigt, ob die Reihenfolge schon
optimiert ist oder noch lernt; bei einem erkannten Ladenumbau erscheint nach
dem Abschließen ein kurzer Hinweis, dass sich die App automatisch anpasst.

- **Wischen nach rechts** verringert die Menge, **Wischen nach links** erhöht sie
  (nie unter die Schrittweite) — bei noch offenen Artikeln löst ein vollständiger
  Wisch die Aktion direkt aus, ganz ohne zusätzlichen Bestätigungs-Tap. **Tap auf
  die Mengenangabe** öffnet ein Sheet für eine exakte Menge, die Mengeneinheit und
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
  bleiben einfach auf der globalen Liste. Der „Einkauf abschließen“-Button zeigt
  dabei die Anzahl bereits abgehakter Artikel und färbt sich in der Akzentfarbe,
  sobald mindestens einer abgehakt wurde.
- Die Geschäftsauswahl wird automatisch auf „Kein Geschäft“ zurückgesetzt —
  sowohl nach dem Abschließen eines Einkaufs als auch nach 3 Stunden ohne
  Interaktion mit der Einkaufsliste, damit ein neuer Einkauf nicht versehentlich
  am zuletzt genutzten Geschäft weiterläuft. Der Einkauf selbst wird dabei
  automatisch mit abgeschlossen (kein manuelles Antippen von
  „Einkauf abschließen“ nötig), damit er später von der Preishistorie-Bereinigung
  erreicht werden kann (siehe Einstellungen → „Preishistorie“ unten). Ohne
  gewähltes Geschäft — etwa wenn du über mehrere Tage verteilt nach Bedarf
  abhakst, ohne je aktiv abzuschließen — gilt eine deutlich großzügigere Frist
  von 24 Stunden, damit dieser Anwendungsfall nicht unterbrochen wird.
- **Gemeinsam einkaufen (Datensynchronisation aktiv, siehe unten):** Hakt ein
  anderes Gerät einen Artikel ab, bevor du selbst dazu kommst, zeigt ein kurzer,
  sich von selbst wieder ausblendender Hinweis („Bereits von {Gerätename}
  abgehakt“), dass es sich erledigt hat — kein Dialog zum Wegklicken nötig.
- **„Artikel hinzufügen“** zeigt unter dem Titel zusätzlich den Namen der
  Einkaufsliste. Die Suche erkennt Singular und Plural gleichermaßen (z.B.
  findet „Äpfel“ auch den Artikel „Apfel“). Bereits auf der Liste stehende
  Artikel sind mit dem Abhak-Symbol markiert — erneutes Antippen nimmt sie
  wieder von der Liste.

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

Neben dem Namen erkennt die App auch die Geschäftsadresse vom Bon — hat ein
bekanntes Geschäft dieselbe Adresse, wird es auch dann automatisch zugeordnet,
wenn der Name auf dem Bon unklar oder abweichend ist. Fehlt einem so
zugeordneten Geschäft noch eine Adresse, wird die erkannte automatisch
übernommen. Wird das Geschäft auf dem Bon nicht erkannt (oder gibt es mehrere
Geschäfte mit demselben Namen und passt auch die Adresse nicht eindeutig),
fragt dich die App danach, ggf. mit Kurzadresse zur Unterscheidung
namensgleicher Filialen — hat ein bereits vorhandenes, namensgleiches Geschäft
eine andere Adresse als die erkannte, kannst du dort trotzdem eine neue,
zweite Filiale mit der erkannten Adresse anlegen.

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
du je MilkForUs-Kategorie, ob eine bestehende Warengruppe automatisch erkannt wurde
(exakter Name oder KI-Vorschlag), oder ob eine neue angelegt würde — per Antippen
lässt sich das auf eine andere bestehende Warengruppe oder „Sonstiges“ umstellen.
Bereits vorhandene Artikel werden nur auf die gewählte Liste gesetzt, nie
dupliziert; einzelne Artikel lassen sich vor dem Übernehmen per Wischgeste aus dem
Import ausschließen.

## Datensynchronisation (gemeinsam einkaufen)

Über einen geteilten Ordner (z.B. iCloud Drive oder Synology Drive) gleichen
sich mehrere Geräte gegenseitig ab — Einkaufslisten-Änderungen, Abhaken,
Geschäfte, Artikel, Kaufhistorie und die gelernte Warengruppen-Reihenfolge.
Anders als bei „Datenbank & Speicherort“ (siehe unten) bleibt dabei die
eigentliche Datenbank jedes Geräts unverändert an ihrem Ort — nur Änderungen
werden ausgetauscht.

- **Einrichten:** Einstellungen → „Datensynchronisation“ → „Ordner wählen…“.
  Enthält der gewählte Ordner bereits Daten anderer Geräte (z.B. weil ein
  Mitnutzer schon eingerichtet hat), werden sie beim Verknüpfen mit deinem
  eigenen Bestand zusammengeführt. Erkennt die App dabei Geschäfte, die
  möglicherweise identisch sind (ähnlicher Name und/oder ganz in der Nähe),
  fragt sie vor dem Zusammenführen einmalig nach: „Gleicher Laden“ (mit Wahl,
  welcher der beiden Namen bleibt) oder „Unterschiedliche Läden“. Ohne
  Entscheidung bleiben beide als getrennte Geschäfte bestehen.
- **Läuft automatisch,** solange die App im Vordergrund ist — kein manueller
  Sync-Tap nötig. Ein zusätzlicher „Jetzt synchronisieren“-Button steht für den
  seltenen Fall bereit, dass du sofort statt in ein paar Sekunden abgleichen
  möchtest.
- **Nur im Vordergrund:** Bei gesperrtem Gerät oder geschlossener App pausiert
  der automatische Abgleich — er läuft beim nächsten Öffnen sofort weiter.
- **„Synchronisierung deaktivieren“** trennt die Verbindung zum Ordner wieder,
  ohne bereits ausgetauschte Daten zu löschen.
- **„Sync-Abgleich nötig“:** War ein Gerät länger als 30 Tage nicht in
  Betrieb (Urlaub, App lange nicht geöffnet), erscheint beim nächsten Start
  eine Meldung, dass der Datenbestand einmal komplett neu abgeglichen werden
  muss — „Jetzt abgleichen“ sichert zuerst eigene, noch nicht übertragene
  Änderungen und fordert danach zu einem Neustart der App auf, um den
  Abgleich abzuschließen. „Später erinnern“ verschiebt die Meldung auf den
  nächsten App-Start.
- **Sync-Debug-Modus** (Einstellungen → „Debugging“) — zeichnet zur
  Fehlersuche/Optimierung lokal auf, wie lange ein Abgleich dauert und wie
  aktuell empfangene Änderungen waren; im Normalbetrieb nicht nötig.

## Einstellungen

- **Hilfe & Anleitungen** — kuratierte Kurzhilfe zu den komplexeren Funktionen
  (Ergänzung zu dieser Anleitung, siehe oben).
- **Artikel / Geschäfte / Warengruppen / Einkaufslisten** — die vollständige
  Verwaltung (Anlegen/Bearbeiten/Löschen); die App startet immer direkt mit der
  Einkaufsliste, Artikel und Geschäfte sind daher nur noch hier erreichbar.
- **Geschäftstypen** — legt je Geschäftstyp (Lebensmittel, Drogerie, …) fest,
  welche Warengruppen als Standard gelten und dadurch automatisch in
  jedem Geschäft dieses Typs verfügbar sind (siehe „Geschäfte“ oben). Name,
  Symbol und Farbe eines Geschäftstyps lassen sich in derselben Ansicht ändern.
  Ist Apple Intelligence verfügbar, schlägt ein „KI-Vorschlag“-Knopf passende
  Warengruppen vor, bevorzugt aus bereits vorhandenen Warengruppen — gerade
  vorgeschlagene Warengruppen sind für die Dauer der Sitzung zusätzlich mit
  „KI-Vorschlag“ markiert. Reicht die vorinstallierte Auswahl an Geschäftstypen
  nicht aus, lässt sich hier oder direkt beim Anlegen eines Geschäfts (Abschnitt
  „Typ“) ein neuer, eigener Geschäftstyp (inkl. Symbol/Farbe) anlegen.
- **Preishistorie** — Aufbewahrungsdauer/Bereinigung alter Preiseinträge; räumt ab
  derselben Frist zusätzlich alte, abgeschlossene Einkäufe ohne verbleibende
  Preiseinträge mit auf. Zusätzlich die Schwellwerte der automatischen
  Preishistorie-Verdichtung (wie viele Preispunkte pro Tag/Woche/Monat maximal
  aufgehoben werden) — läuft immer im Hintergrund, hier nur zum Nachjustieren.
- **Datenbank & Speicherort** — verlegt deine Daten in einen selbst gewählten
  Ordner, z.B. einen lokal gespiegelten Cloud-Ordner. Kein automatischer
  Mehrgeräte-Sync (kein iCloud-Sync) — bei einem Cloud-Ordner die App bewusst nur
  auf einem Gerät gleichzeitig aktiv nutzen, um Konflikte zu vermeiden. Wirkt erst
  nach einem Neustart der App.
- **Debugging** — bündelt alle Diagnose-Einstellungen in einer Ansicht; im
  Normalbetrieb nicht nötig. Ein gemeinsamer „Debug-Modus“-Abschnitt mit den
  Unteroptionen „Sync-Protokoll“ und „Datenbank-Protokoll“ (je einzeln
  ein-/ausschaltbar, gemeinsame Protokollgröße/Teilen/Leeren), sowie in
  Debug-Builds zusätzlich der Standort-Suchradius.
- **Datensynchronisation** — siehe eigener Abschnitt „Datensynchronisation
  (gemeinsam einkaufen)“ oben.
