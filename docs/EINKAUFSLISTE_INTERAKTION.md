# Einkaufsliste — Interaktionsmodell (Menge & Sektions-Header)

Status: **Umgesetzt** (`Views/Einkaufen/EinkaufenView.swift`).

## Ausgangslage

`EinkaufslistenSektionHeader` zeigte bislang neben dem Regal-/Kategorienamen
zusätzlich einen Fortschrittszähler `abgehakt/gesamt` je Sektion.
`ArtikelAbhakZeile` änderte die Menge eines Artikels über eine Tap-Gesten-
Kaskade auf der ganzen Zeile (Einfach-Tap = erhöhen, Doppel-Tap = verringern,
Long-Press = Sheet für exakte Menge + Notiz).

## Entscheidung

- **Sektions-Zähler entfernt.** `EinkaufslistenSektionHeader` zeigt nur noch
  Titel (und bei Kategorie-Sektionen Icon/Farbe), keine `abgehakt/gesamt`-
  Anzeige mehr.
- **Tap auf die Mengenangabe öffnet direkt `MengenNotizSheet`** (exakte Menge +
  temporäre Notiz) — statt vorher per Long-Press auf die ganze Zeile.
- **Swipe nach links (trailing) erhöht die Menge**, **Swipe nach rechts
  (leading) verringert sie** — ersetzt die bisherige Einfach-/Doppel-Tap-
  Kaskade auf der ganzen Zeile.
- Die bestehende Aktion „Dauerhaft entfernen" für bereits abgehakte Artikel
  bleibt auf der Trailing-Seite neben „Menge erhöhen" erhalten; die
  Trailing-Seite hat dafür `allowsFullSwipe: false`, damit ein vollständiger
  Swipe nicht versehentlich den destruktiven Button auslöst.

## Begründung

| Aspekt | Begründung |
|---|---|
| Zähler entfernt | Der Sektions-Fortschritt (`abgehakt/gesamt`) lieferte beim tatsächlichen Einkaufen wenig Mehrwert gegenüber dem visuellen Bild der durchgestrichenen Zeilen selbst — reine Vereinfachung der Kopfzeile auf explizite Anforderung. |
| Tap auf Menge statt Long-Press | Ein einzelner, kurzer Tap direkt auf das Element, das geändert wird (die Mengenangabe), ist entdeckbarer und schneller als ein Long-Press auf die ganze Zeile, der zudem mit den bisherigen Einfach-/Doppel-Tap-Gesten kollidierte (SwiftUI muss den Einfach-Tap sonst künstlich verzögern, um einen möglichen Doppel-Tap abzuwarten). |
| Swipe statt Tap-Kaskade für +/- | Swipe-Gesten sind für Mengenänderungen in Listen ein etabliertes iOS-Muster (vgl. Mail/Erinnerungen) und eindeutig (links/rechts statt „wie oft tippen"), ohne mit dem Tap auf die Mengenangabe oder der Checkbox-Aktion zum Abhaken zu kollidieren. |
| `allowsFullSwipe: false` (trailing) | Trailing enthält jetzt zwei Aktionen (Menge erhöhen + destruktives Entfernen); ohne diese Einstellung würde eine der beiden Aktionen implizit zur „Vollständiger-Swipe"-Aktion, was bei einer destruktiven Aktion ein Risiko für versehentliches Auslösen wäre. |

## Bekannte Grenzen

- Die Checkbox zum Abhaken bleibt unverändert ein eigenständiger Button am
  Zeilenende (kein Tap auf die restliche Zeile mehr nötig oder möglich).
- Für Geschäfte ohne aktiven Sektions-Fortschritt gibt es aktuell keine
  Ersatzanzeige des Gesamtfortschritts (z.B. auf Ebene des gesamten
  Einkaufsvorgangs) — bei Bedarf wäre das ein separater, künftiger Punkt.
