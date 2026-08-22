# ShopWithMe — Bedienungsanleitung

Kompakter Überblick, wie du mit ShopWithMe einkaufst und die App einrichtest — ein
Abschnitt je Funktionsbereich, kein Schritt-für-Schritt für jedes einzelne
UI-Element. Für die technische Spezifikation siehe [PRODUCT_SPEC.md](PRODUCT_SPEC.md),
für die Versionshistorie [CHANGELOG.md](CHANGELOG.md).

Diese Anleitung ist die maßgebliche, vollständige Quelle — die kuratierte In-App-Hilfe
(„Hilfe & Anleitungen" in den Einstellungen) deckt bewusst nur eine Auswahl der
komplexeren Funktionen ab und darf dieser Anleitung inhaltlich nicht widersprechen.

## Die drei Bereiche der App

Die App startet immer direkt mit der Einkaufsliste.

- **Einkaufen** — die eigentliche Einkaufsliste, Standort-Erkennung, Abhaken.
- **Scannen** — direkter Belegscan ohne vorherige Geschäftswahl, jederzeit über den
  mittleren Tab erreichbar (siehe „Belegscan & Preisschild-Scan" unten). Ergänzt,
  ersetzt aber nicht die weiteren Belegscan-Wege aus dem Einkaufen-Tab bzw. aus der
  Geschäfts-Detailansicht.
- **Einstellungen** — Hilfe, Artikel- und Geschäfte-Verwaltung (inkl. Abteilungen
  pro Geschäft), Geschäftstypen-Verwaltung, Datenbank-Speicherort,
  Datensynchronisation.

## Artikel

Jeder Artikel hat einen Namen, eine oder mehrere Abteilungen (z.B. Obst,
Milchprodukte — Mehrfachauswahl beim Bearbeiten), eine Einheit (Stück, kg, g, l,
ml) und eine Standardmenge — die zugleich die Schrittweite ist, um die die Menge
beim Einkaufen erhöht/verringert wird. Hat ein Artikel mehrere Abteilungen (z.B.
Ohropax unter „Drogerie" und „Reisebedarf"), erscheint er beim Einkaufen
gleichzeitig in allen zugehörigen Abschnitten — abgehakt wird er dabei überall
auf einmal. Aus welchem Abschnitt du ihn tatsächlich abhakst, merkt sich die App
pro Geschäft: so lernt sie z.B., dass Sojasauce bei Edeka unter „Soßen", bei
Aldi aber unter „Asia" steht. Neue Artikel legst du meist direkt beim Einkaufen an (landen dann
automatisch auf der Liste); in der Artikel-Verwaltung (Einstellungen) per „+"
angelegte Artikel landen nicht automatisch auf der Liste. Beim Anlegen schlägt
Apple Intelligence (sofern auf deinem Gerät verfügbar) automatisch eine passende
Abteilung vor, sobald du einen Namen eingibst — eine bereits von dir gewählte
Abteilung wird dabei nie überschrieben. Ist Apple
Intelligence nicht verfügbar, bleibt die manuelle Auswahl jederzeit möglich.
Gibt es bereits einen Artikel mit exakt demselben Namen, erscheint beim
Anlegen ein orangener Warnhinweis darunter — das Anlegen wird dadurch nicht
blockiert, verhindert aber versehentliche Dubletten (z.B. „Milch" zweimal
unabhängig voneinander angelegt), die sich sonst nicht von selbst
zusammenführen.
In der Artikel-Bearbeitung zeigt die Abteilungs-Sektion nur die bereits
zugeordneten Abteilungen (zum Entfernen nach links wischen); über „Abteilung
hinzufügen" öffnet sich eine durchsuchbare Liste aller übrigen Abteilungen zur
Auswahl, mit der Möglichkeit, dort direkt eine neue Abteilung anzulegen.

Einem bereits angelegten Artikel kannst du in der Artikel-Bearbeitung beliebig
viele **alternative Namen** geben — weitere Suchbegriffe, unter denen du beim
Hinzufügen zur Einkaufsliste denselben Artikel findest (z.B. „Zahncreme" oder
„Zahnreiniger" als alternativer Name für „Zahnpasta"). Ein alternativer Name
ist kein eigenes Produkt, sondern nur ein zusätzlicher Suchbegriff für den
bestehenden Artikel — für tatsächlich unterschiedliche Produkte (z.B. „Odol",
„Paradontol", „Sebamed" als konkrete Zahnpasta-Marken) leg stattdessen
**Produkte** an (siehe unten).

In derselben Artikel-Bearbeitung kannst du außerdem beliebig viele
**Produkte** anlegen — konkrete, kaufbare Dinge mit eigenem Preis, die zu
diesem Artikel gehören (z.B. „Odol", „Paradontol Zahncreme", „Sebamed" für
„Zahnpasta"). Tippe auf ein Produkt, um es zu bearbeiten: dort kannst du ihm
ebenfalls beliebig viele **alternative Namen** geben (zusätzliche
Anzeigenamen für dasselbe Produkt, z.B. „Andechser Vollmilch fett" für
„Andechser Milch 3,5%") sowie je Geschäft einen eigenen **Produktnamen**
(derselbe Artikel kann in Geschäft A anders auf dem Preisschild stehen als in
Geschäft B) und siehst seine eigene Preishistorie. Hat ein Artikel mindestens
ein Produkt, zeigt „Artikel hinzufügen" beim entsprechenden Eintrag
zusätzlich einen kleinen Chevron-Pfeil — Antippen klappt die Produktliste
direkt in der Suche aus, sodass du das gewünschte Produkt sofort antippen
kannst; der Name erscheint danach klein unter dem Artikel auf der
Einkaufsliste. Ohne diese Auswahl (einfacher Tap wie bisher) landet der
Artikel weiterhin ohne festgelegtes Produkt auf der Liste.

## Geschäfte

Ein Geschäft hat einen oder mehrere Typen (Lebensmittel, Drogerie, Baumarkt,
Apotheke, …, z.B. Drogerie + Lebensmittel bei einem dm — Mehrfachauswahl beim
Bearbeiten der Stammdaten) und optional eine Adresse. Abteilungen sind der primäre Weg, Artikel für ein Geschäft
verfügbar zu machen — direkt im Geschäft zuordenbar. Zusätzlich
macht jeder Geschäftstyp automatisch seine in den Einstellungen hinterlegten
Standard-Abteilungen verfügbar (siehe „Geschäftstypen" unten) — ganz ohne sie dem
einzelnen Geschäft manuell zuzuordnen; wählst du später dort noch weitere
Abteilungen manuell aus, betrifft das nur dieses eine Geschäft, nicht generell den
Geschäftstyp. Die Reihenfolge, in der die Abteilungen beim Einkaufen erscheinen,
legst du nicht manuell fest — die App lernt sie automatisch aus deinem
Abhakverhalten (siehe „Einkaufen" unten).

**Filialen / Ketten:** Gehören mehrere Geschäfte zur selben Kette (z.B. „Rewe
Maisach" und „Rewe Sendling" zu „Rewe"), kannst du beim Anlegen oder Bearbeiten
eines Geschäfts im Feld „Marke / Kette" denselben Markennamen hinterlegen (z.B.
„Rewe"). In der Geschäfte-Liste werden alle Filialen dieser Marke dann unter
einer aufklappbaren Zeile mit dem Markennamen zusammengefasst — antippen klappt
die einzelnen Filialen aus. Geschäfte ohne Markennamen bleiben eigenständige
Einträge.

In der Detailansicht eines Geschäfts siehst du alle verfügbaren Abteilungen
gemeinsam, alphabetisch — automatisch über den Geschäftstyp verfügbare sind mit
„Automatisch über Geschäftstyp" gekennzeichnet. Per Wischgeste lässt sich eine
solche automatische Abteilung für dieses eine Geschäft ausschließen, ohne sie
generell vom Geschäftstyp zu entfernen — sie taucht danach wieder unter
„Abteilung hinzufügen" auf, falls du sie doch wieder brauchst. Manuell
zugeordnete Abteilungen entfernst du wie gewohnt per Wischgeste.

**Standort beim Anlegen/Bearbeiten:** Sobald ein Geschäft Koordinaten hat, zeigt
das Bearbeiten-Formular eine kleine Karte mit einem Pin — durch Antippen der
Karte lässt sich der Standort exakt setzen (die Adresse wird dabei **nicht**
befüllt; sie ist ausschließlich per Texteingabe oder Belegscan setzbar).
Alternativ füllt „Aktuellen Standort verwenden" Adresse und Koordinaten direkt
aus deinem GPS-Standort, oder du tippst eine Adresse ein und bestätigst mit der
Eingabetaste — die Koordinaten werden dann automatisch ermittelt und die Karte
darauf zentriert, auch wenn bereits ein Standort gesetzt war.

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
einer eigenen „Favoriten"-Sektion — ermittelt aus abgeschlossenen Einkäufen
innerhalb eines Zeitfensters (Standard: 30 Tage). Anzahl und Zeitfenster stellst du
über den Stern-Button in der Geschäfte-Übersicht ein. Jedes Geschäft zeigt
außerdem in seiner Detailansicht (Bearbeiten) einen Zähler abgeschlossener
Einkäufe, den du dort separat zurücksetzen kannst, sowie ein „Besuchsprotokoll"
mit Zeitpunkt, Dauer und Produktanzahl jedes Einkaufs — bleibt auch erhalten,
wenn du später die Einkaufsliste löschst, aus der heraus damals eingekauft
wurde.

**Standort-Erkennung:** Beim Öffnen des Einkaufen-Tabs prüft die App per einmaliger
Standortabfrage, ob du dich in der Nähe eines bekannten oder von Apple Maps
erkannten Ladens befindest, und schlägt ihn in einem Banner vor — direkt zur
Auswahl (bekannt) oder zum Anlegen mit vorausgefüllten Daten (unbekannt). Über das
„…"-Menü des Banners lässt sich ein Vorschlag dauerhaft ignorieren oder „Alle
Geschäfte in der Nähe" öffnen (zeigt auch ignorierte, mit Möglichkeit zum
Wiederaufnehmen). Ein neues Geschäft lässt sich davon unabhängig jederzeit rein
manuell anlegen — die Standort-Erkennung ist nur eine Ergänzung. Fehlen einem
Geschäft noch Koordinaten, fragt dich die App beim nächsten Auswählen, ob sie den
aktuellen Standort oder eine (ggf. neu eingegebene) Adresse dafür verwenden soll.
Zusätzlich zu den Buttons/dem Menü lässt sich das Banner auch per Wischgeste
bedienen: nach rechts wischen entspricht dem Haupt-Button (auswählen/anlegen),
nach links dauerhaftem Ignorieren, nach oben dem einmaligen Verwerfen.

## Einkaufen

Die Einkaufsliste ist global, nicht an ein Geschäft gebunden. Wählst du zusätzlich
ein Geschäft, wird sie nach Abteilung gruppiert. Ein Einkauf startet
automatisch beim Öffnen des Tabs, kein manueller Start nötig.

Der Bildschirmtitel zeigt neben dem Listennamen deinen Fortschritt für diesen
Einkauf, Format „<Name> (<abgehakt>/<gesamt>)", z.B. „Wocheneinkauf (3/8)".

Ein Artikel, der mehreren Kategorien zugeordnet ist, erscheint zunächst in
jedem passenden Abschnitt der Liste — erkennbar am kleinen Symbol neben dem
Namen. Der Fortschritt im Titel zählt jeden Artikel trotzdem nur einmal; die
Anzahl sichtbarer Zeilen kann in diesem Fall also höher sein als die Zahl
nach dem Schrägstrich. Sobald du diesen Artikel in einem bestimmten Geschäft
überwiegend aus derselben Kategorie abgehakt hast, merkt sich die App das und
zeigt ihn dort künftig nur noch in dieser einen Kategorie — das Symbol
verschwindet dann wieder. Kauf ihn dort später doch mal aus einem anderen
Abschnitt, blendet sich die Mehrfachanzeige bei Bedarf automatisch wieder
ein. Im Lernmodus (siehe unten) siehst du immer alle zugeordneten
Kategorien, auch wenn die App sich schon auf eine festgelegt hat — praktisch,
um eine falsch gelernte Zuordnung zu korrigieren.

Die Liste sortiert sich mit der Zeit selbst: ShopWithMe lernt aus der
Reihenfolge, in der du Artikel abhakst, welche Abteilungen in diesem Geschäft
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
  Schnellauswahl (Symbol neben „Artikel hinzufügen") bündelt zwei Anzeigeoptionen:
  kurzer Tap blendet zusätzlich bereits abgehakte Artikel ein (durchgestrichen,
  antippen macht das Abhaken rückgängig); langer Tap öffnet den Lernmodus, der alle
  Artikel der Liste einblendet, auch bislang nicht als verfügbar geltende — dadurch
  lernt die App sie für dieses Geschäft als verfügbar.
- Per Wischgeste lässt sich ein bereits abgehakter Artikel dauerhaft aus dieser
  Ansicht entfernen (landet dann nicht wieder auf der offenen Liste).
- Ein Einkauf lässt sich jederzeit abschließen, auch mit offenen Artikeln — die
  bleiben einfach auf der globalen Liste. Der „Einkauf abschließen"-Button zeigt
  dabei die Anzahl bereits abgehakter Artikel und färbt sich in der Akzentfarbe,
  sobald mindestens einer abgehakt wurde.
- Die Geschäftsauswahl wird automatisch auf „Kein Geschäft" zurückgesetzt —
  sowohl nach dem Abschließen eines Einkaufs als auch nach 3 Stunden ohne
  Interaktion mit der Einkaufsliste, damit ein neuer Einkauf nicht versehentlich
  am zuletzt genutzten Geschäft weiterläuft. Der Einkauf selbst wird dabei
  automatisch mit abgeschlossen (kein manuelles Antippen von
  „Einkauf abschließen" nötig), damit er später von der Preishistorie-Bereinigung
  erreicht werden kann (siehe Einstellungen → „Preishistorie" unten). Ohne
  gewähltes Geschäft — etwa wenn du über mehrere Tage verteilt nach Bedarf
  abhakst, ohne je aktiv abzuschließen — gilt eine deutlich großzügigere Frist
  von 24 Stunden, damit dieser Anwendungsfall nicht unterbrochen wird.
- **Gemeinsam einkaufen (Datensynchronisation aktiv, siehe unten):** Hakt ein
  anderes Gerät einen Artikel ab, bevor du selbst dazu kommst, zeigt ein kurzer,
  sich von selbst wieder ausblendender Hinweis („Bereits von {Gerätename}
  abgehakt"), dass es sich erledigt hat — kein Dialog zum Wegklicken nötig.
- **„Artikel hinzufügen"** zeigt unter dem Titel zusätzlich den Namen der
  Einkaufsliste. Die Suche erkennt Singular und Plural gleichermaßen (z.B.
  findet „Äpfel" auch den Artikel „Apfel") und findet Artikel auch über
  Produktnamen (z.B. findet „Sebamed" den Artikel „Shampoo", der dann
  automatisch mit aufgeklappter Produktliste erscheint). Bereits auf der
  Liste stehende Artikel sind mit dem Abhak-Symbol markiert — erneutes
  Antippen nimmt sie wieder von der Liste. Links vom Abhak-Symbol steht
  die aktuelle Menge; Antippen öffnet dasselbe Blatt zum Anpassen von
  Menge, Einheit und Notiz wie beim Einkaufen selbst.
- **Darstellung anpassen:** Einstellungen → „Listendarstellung" — wählt zwischen
  klassischer Gruppenliste, Chips (groß oder klein) und Kacheln (2 oder 3 Spalten).
  Je Modus konfigurierbar: Akkordeon-Kategorien, Fortschrittsbalken und
  Kategorie-Farbstreifen (nur klassisch) lassen sich einzeln ein- oder ausschalten;
  Kacheln können farbig nach Kategorie hinterlegt werden.

## Belegscan & Preisschild-Scan

Vier gleichwertige Wege zum Belegscan: nach dem Abschließen eines Einkaufs (Angebot,
den Kassenbon direkt zu scannen), über den **Scannen-Tab** (jederzeit, ohne
vorherige Geschäftswahl — nach dem Übernehmen bzw. „Verwerfen" direkt wieder bereit
für den nächsten Scan), über das Scannen-Menü beim Einkaufen für das gerade
gewählte Geschäft, oder direkt in der Geschäfts-Detailansicht — z.B. für ältere,
nachträglich gefundene Bons.

**Geschäft ist Pflicht:** „Preise übernehmen" lässt sich erst antippen, wenn ein
Geschäft feststeht — automatisch erkannt oder von dir gewählt (siehe unten). Kennt
die App das Geschäft (noch) nicht, leg es direkt im Auswahl-Dialog neu an (auch mit
einem selbst gewählten Namen wie „Unbekannt", falls du es nicht genauer zuordnen
willst) — Preise ganz ohne Geschäftsbezug gibt es seitdem nicht mehr.

Lokale KI erkennt Geschäft, Datum, Artikel und Preise (Foto, aus der
Fotomediathek oder aus den Dateien) und trägt sie in die passenden Positionen ein. Jede Position zeigt
oben einen editierbaren **Produktnamen** (konkreter Klarname, z.B. „Sebamed
Urea 5%" — von der KI vorbelegt) und darunter einen antippe-baren
**Artikel-Button** (generische Kategorie, z.B. „Shampoo"). Der auf dem Bon
gedruckte, oft abgekürzte Originaltext bleibt separat erhalten und erscheint klein
darunter, sofern er vom Produktnamen abweicht. Für jede Position versucht die App
automatisch, den Bon-Text einem deiner vorhandenen Artikel zuzuordnen — gelingt
das, zeigt der Artikel-Button den generischen Namen; gelingt es nicht, ist die
Position als „Neu erkannt — Artikel zuordnen" markiert. Antippen des Artikel-Buttons
öffnet eine durchsuchbare Liste aller Artikel — wähle einen aus oder lege mit dem
„Neu anlegen"-Button direkt einen neuen an. Den Produktnamen kannst du jederzeit
anpassen oder leer lassen — dann dient der Bon-Text als Produktname. Verschiedene
Marken desselben Artikels (z.B. „Odol" und „Paradontol" für „Zahnpasta") erhalten
dadurch von Anfang an getrennte Preishistorien, auch ohne vorherige manuelle Anlage. Nicht
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
die erkannte Stelle im Beleg farblich hervor. „Abbrechen" schließt die Prüf-Ansicht
immer sofort, ohne Rückfrage.

Der **Preisschild-Scan** (Geschäfts-Detailansicht oder während des Einkaufens)
erfasst stattdessen ein einzelnes Regal-Preisschild — nützlich für einen
Preisvergleich vor der Kaufentscheidung, ohne auf den Kassenbon zu warten.

Alle erfassten Preise findest du als Preishistorie in der Artikel- bzw.
Geschäfts-Detailansicht.

## MilkForUs-Textimport

In der Einkaufslisten-Verwaltung (Einstellungen) importierst du über „MilkForUs
importieren" eine aus der Shopping-App „MilkForUs" exportierte Textdatei — entweder
per Datei-Auswahl, oder direkt über die Teilen-Funktion eines anderen Apps (z.B.
eine per Chat empfangene Datei per „Teilen" → „ShopWithMe"). In der Vorschau siehst
du je MilkForUs-Kategorie, ob eine bestehende Abteilung automatisch erkannt wurde
(exakter Name oder KI-Vorschlag), oder ob eine neue angelegt würde — per Antippen
lässt sich das auf eine andere bestehende Abteilung oder „Sonstiges" umstellen.
Bereits vorhandene Artikel werden nur auf die gewählte Liste gesetzt, nie
dupliziert; einzelne Artikel lassen sich vor dem Übernehmen per Wischgeste aus dem
Import ausschließen.

## Datensynchronisation (gemeinsam einkaufen)

Über einen geteilten Ordner (z.B. iCloud Drive oder Synology Drive) gleichen
sich mehrere Geräte gegenseitig ab — Einkaufslisten-Änderungen, Abhaken,
Geschäfte, Artikel, Kaufhistorie und die gelernte Abteilungs-Reihenfolge.
Anders als bei „Datenbank & Speicherort" (siehe unten) bleibt dabei die
eigentliche Datenbank jedes Geräts unverändert an ihrem Ort — nur Änderungen
werden ausgetauscht.

- **Einrichten:** Einstellungen → „Synchronisation" → „Ordner wählen…".
  Ist der gewählte Ordner noch leer (niemand sonst hat ihn bisher verwendet),
  startet direkt der erste Abgleich. Enthält er bereits Daten anderer Geräte
  (z.B. weil ein Mitnutzer schon eingerichtet hat), fragt die App vor dem
  Verknüpfen nach Bestätigung für „Ersetzen": dein bisheriger lokaler Bestand
  wird zuerst lokal gesichert (wiederherstellbar über „Backup
  wiederherstellen", solange die Synchronisierung aktiv bleibt) und danach
  sofort — ohne App-Neustart — vollständig durch den Stand der anderen Geräte
  ersetzt. „Abbrechen" verwirft die Ordnerauswahl wieder, ohne etwas zu
  ändern.
- **Läuft automatisch,** solange die App im Vordergrund ist — kein manueller
  Sync-Tap nötig. Für den seltenen Fall, dass du sofort statt in ein paar
  Sekunden abgleichen möchtest, gibt es zwei gleichwertige manuelle Auslöser:
  den „Jetzt synchronisieren"-Button in den Sync-Einstellungen, sowie —
  direkt beim Einkaufen, ohne Umweg über die Einstellungen — ein Ziehen nach
  unten (Pull-to-Refresh) ganz oben in der Einkaufsliste. Beide lösen
  denselben Abgleich aus; dabei blitzt kurz ein Dateiauswahl-Fenster auf den
  Sync-Ordner auf und schließt sich von selbst wieder — ein experimenteller
  Versuch, den Systemabgleich zusätzlich anzustoßen, keine Fehlfunktion.
- **Nur im Vordergrund:** Bei gesperrtem Gerät oder geschlossener App pausiert
  der automatische Abgleich — er läuft beim nächsten Öffnen sofort weiter.
- **„Datenbestand wird ersetzt…":** Während eine Aktion, die einen
  kompletten Neuaufbau des Datenbestands auslöst (z.B. „Ersetzen" beim
  Verknüpfen eines bereits von anderen Geräten genutzten Ordners,
  Wiederherstellen aus einem Backup), gerade läuft, sind „Ordner wählen…",
  „Synchronisierung deaktivieren" und „Backup wiederherstellen" kurz
  deaktiviert und ein Fortschritts-Hinweis erscheint — kein Neustart nötig,
  der Austausch ist normalerweise binnen weniger Sekunden abgeschlossen.
- **Schnellerer Abgleich in der Nähe:** Öffnest du gemeinsam mit einer anderen
  Person, die dieselbe Liste eingerichtet hat, gleichzeitig den
  Einkaufen-Bildschirm, tauscht die App Häkchen/neue Artikel zusätzlich direkt
  zwischen den Geräten aus (WLAN/Bluetooth in der Nähe) — spürbar schneller
  als der reguläre Abgleich über den geteilten Ordner. Dafür fragt iOS beim
  ersten gemeinsamen Einkaufen nach dieser Funktion einmalig nach der
  Berechtigung „Im lokalen Netzwerk suchen" — ohne diese Berechtigung
  funktioniert weiterhin alles, nur eben etwas langsamer über den geteilten
  Ordner. Über den Schalter „Multipeer-Sync" in den Sync-Einstellungen lässt
  sich dieser Nahbereich-Kanal komplett abschalten (Standard: an) — der
  Abgleich über den geteilten Ordner läuft davon unabhängig weiter.
- **Sichtbarer Sync-Status:** Einstellungen → „Synchronisation" zeigt
  jederzeit, wann der Ordner-Abgleich zuletzt erfolgreich lief und ob gerade
  zusätzlich eine schnellere Nahbereich-Verbindung zu anderen Geräten besteht
  (und mit welchen). Während des gemeinsamen Einkaufens erscheint bei
  bestehender Nahbereich-Verbindung außerdem eine kleine Statuszeile
  („N Geräte verbunden") linksbündig unter dem Listennamen im
  Einkaufen-Bildschirm.
- **„N mögliche Duplikate prüfen":** Erkennt der laufende Abgleich ein
  Geschäft, einen Artikel oder eine Einkaufsliste, die einem bereits
  vorhandenen Eintrag ähneln, aber nicht eindeutig zugeordnet werden können,
  wird nichts automatisch zusammengeführt oder verworfen — stattdessen
  erscheint dieses Badge in den Sync-Einstellungen. Antippen zeigt eine
  „Gleich"/„Unterschiedlich"-Wahl; unentschiedene Einträge bleiben einfach in
  der Liste stehen, bis du reagierst.
- **„Synchronisierung deaktivieren"** trennt die Verbindung zum Ordner wieder,
  ohne bereits ausgetauschte Daten zu löschen.
- **„Sync-Abgleich nötig":** War ein Gerät länger als 30 Tage nicht in
  Betrieb (Urlaub, App lange nicht geöffnet), erscheint beim nächsten Start
  eine Meldung, dass der Datenbestand einmal komplett neu abgeglichen werden
  muss — „Jetzt abgleichen" sichert zuerst eigene, noch nicht übertragene
  Änderungen und fordert danach zu einem Neustart der App auf, um den
  Abgleich abzuschließen. „Später erinnern" verschiebt die Meldung auf den
  nächsten App-Start.
- **„Gerät seit langem nicht gesehen":** Erkennt die App bei App-Start/
  Rückkehr aus dem Hintergrund ein Gerät in der Gruppe, das seit mehr als 30
  Tagen nicht mehr synchronisiert hat, fragt sie aktiv nach, ob es entfernt
  werden soll (z.B. weil es nicht mehr genutzt wird) — „Entfernen" löscht
  seinen Beitrag vollständig aus dem Sync-Ordner, „Später erinnern"
  verschiebt die Frage auf den nächsten App-Start. Dasselbe lässt sich auch
  jederzeit manuell einsehen/auslösen: Einstellungen → „Synchronisation" →
  „Bekannte Geräte", dort per Wischen.
- **„Aus der Sync-Gruppe entfernt":** Wurde dieses Gerät von einem anderen
  Mitglied der Gruppe auf die oben beschriebene Art entfernt, erkennt es das
  selbst beim nächsten Start und trennt sich automatisch vom Sync-Ordner —
  dabei entsteht immer zuerst ein lokales Backup des bisherigen Bestands. Die
  anschließende Meldung bietet „Alleine weitermachen" (nichts weiter zu tun)
  oder „Wieder beitreten" (öffnet die Sync-Einstellungen, um erneut einen
  Ordner zu wählen — der eigene Bestand wird dabei durch den aktuellen
  Gruppenstand ersetzt).
- **Sync-Debug-Modus** (Einstellungen → „Debugging") — zeichnet zur
  Fehlersuche/Optimierung lokal auf, wie lange ein Abgleich dauert und wie
  aktuell empfangene Änderungen waren; im Normalbetrieb nicht nötig. Dort
  zeigt der Abschnitt „Multipeer-Kanal" zusätzlich denselben Nahbereich-Status
  wie in den Sync-Einstellungen.

## Einstellungen

- **Hilfe & Anleitungen** — kuratierte Kurzhilfe zu den komplexeren Funktionen
  (Ergänzung zu dieser Anleitung, siehe oben).
- **Artikel / Geschäfte / Abteilungen / Einkaufslisten** — die vollständige
  Verwaltung (Anlegen/Bearbeiten/Löschen); die App startet immer direkt mit der
  Einkaufsliste, Artikel und Geschäfte sind daher nur noch hier erreichbar.
- **Produkte** — durchsuchbare Übersicht aller Produkte artikelübergreifend
  (z.B. um schnell „Paradontol" zu finden, ohne vorher zu wissen, dass es unter
  „Zahnpasta" hängt). Zeigt zu jedem Produkt den zugehörigen Artikel und
  navigiert zur Bearbeitungsansicht. In der Detailansicht:
  - **Artikel** neu zuordnen — Antippen der Artikel-Zeile öffnet das Auswahlsheet.
  - **Bekannte Namen** (Akkordeon) — zeigt alle je Geschäft bekannten Bon-Namen,
    jeweils mit zugehörigem Geschäft und, falls vorhanden, Barcode. Der
    Akkordeon-Titel nennt die Anzahl der bekannten Geschäfte. Nach links wischen
    entfernt einen Namen.
  - **Preishistorie** — ein Liniendiagramm zeigt die Preisentwicklung; der Button
    „Datenpunkte" öffnet eine vollständige Liste aller gespeicherten Preise, in
    der einzelne Einträge durch Wischen nach links gelöscht werden können.
  Mit „+" oben rechts ein neues Produkt anlegen. Wischen nach links in der
  Übersichtsliste löscht ein Produkt direkt.
- **Geschäftstypen** — legt je Geschäftstyp (Lebensmittel, Drogerie, …) fest,
  welche Abteilungen als Standard gelten und dadurch automatisch in
  jedem Geschäft dieses Typs verfügbar sind (siehe „Geschäfte" oben). Name,
  Symbol und Farbe eines Geschäftstyps lassen sich in derselben Ansicht ändern.
  Ist Apple Intelligence verfügbar, schlägt ein „KI-Vorschlag"-Knopf passende
  Abteilungen vor, bevorzugt aus bereits vorhandenen Abteilungen — gerade
  vorgeschlagene Abteilungen sind für die Dauer der Sitzung zusätzlich mit
  „KI-Vorschlag" markiert. Reicht die vorinstallierte Auswahl an Geschäftstypen
  nicht aus, lässt sich hier oder direkt beim Anlegen eines Geschäfts (Abschnitt
  „Typ") ein neuer, eigener Geschäftstyp (inkl. Symbol/Farbe) anlegen.
- **Listendarstellung** — wählt den Anzeigemodus der Einkaufsliste: klassische
  Gruppenliste, Chips (groß oder klein) oder Kacheln (2 oder 3 Spalten). Jeder
  Modus ist separat konfigurierbar (Akkordeon, Fortschrittsbalken, Farbstreifen
  bzw. Spaltenanzahl und Kategorie-Farbhintergrund bei Kacheln).
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
  Normalbetrieb nicht nötig. Ein gemeinsamer „Debug-Modus"-Abschnitt mit den
  Unteroptionen „Sync-Protokoll" und „Datenbank-Protokoll" (je einzeln
  ein-/ausschaltbar, gemeinsame Protokollgröße/Teilen/Leeren), eine
  „Datei-I/O-Statistik" (Anzahl geöffneter/erstellter Dateien sowie gelesene/
  geschriebene Datenmenge des Sync-Ordners seit dem letzten Zurücksetzen, mit
  eigenem Reset-Button), sowie in Debug-Builds zusätzlich der
  Standort-Suchradius.
- **Synchronisation** — siehe eigener Abschnitt „Datensynchronisation
  (gemeinsam einkaufen)" oben, inkl. des Schalters „Multipeer-Sync" für den
  optionalen Nahbereich-Kanal.
