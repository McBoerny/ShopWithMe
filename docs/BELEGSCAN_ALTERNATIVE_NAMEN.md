# Belegscan — alternativer Anzeigename pro Position

## Ausgangslage

Der Belegscan (`ReceiptScanService`, `BelegScanView`) erkennt pro Kassenbon-Zeile
einen Namen (`BelegPosition.artikelName`) und einen Einzelpreis und legt daraus einen
`KaufEintrag` an bzw. aktualisiert einen bestehenden. Dieser `KaufEintrag` trägt bereits
zwei Namens-Felder, die beide den historisch tatsächlich erkannten/verwendeten Namen
unverändert festhalten:

- `artikelNameSnapshot: String` — Name zum Kaufzeitpunkt (Pflichtfeld, Fallback für
  gelöschte/umbenannte `Artikel`).
- `produktName: String?` — genauer, ggf. abweichender Kassenbon-/Markenname (z.B.
  „Colgate Total“ bei einem auf den generischen `Artikel` „Zahnpasta“ verlinkten
  Eintrag).

Bislang war die Anzeige-Priorität in `PreisHistorieZeile` fest verdrahtet:
`produktName ?? artikel?.name ?? artikelNameSnapshot`. Der auf dem Bon erkannte
Originalname hatte also immer Vorrang — er ließ sich vor dem Übernehmen im
Belegscan-Dialog zwar korrigieren, aber nicht nachträglich dauerhaft durch einen
frei wählbaren Anzeigenamen ersetzen, ohne die historischen Rohdaten zu überschreiben.

## Neues Feld: `KaufEintrag.alternativerName`

Ein rein additives, optionales Attribut auf `KaufEintrag`
(`ShopWithMe/Models/KaufEintrag.swift`):

```swift
var alternativerName: String?
```

Es speichert einen vom Nutzer frei vergebenen Anzeigenamen für **genau diese eine
Position** (nicht für den verknüpften `Artikel` insgesamt — andere Belegzeilen
desselben `Artikel`s bleiben unberührt). `artikelNameSnapshot` und `produktName`
werden dabei nicht verändert, damit die ursprünglich erkannten Rohdaten für Abgleich
und Nachvollziehbarkeit erhalten bleiben.

Da es sich um ein rein additives, optionales Attribut auf einem bestehenden `@Model`
handelt, ist gemäß der Projekt-Migrationsregel (siehe `docs/DECISIONS.md`,
„Duplicate version checksums“-Vorfall) **keine neue `SchemaVN`/`MigrationStage`**
nötig — `SchemaV1` bleibt unverändert, SwiftDatas Lightweight-Migration übernimmt die
neue Spalte automatisch.

## Anzeige-Priorität: `KaufEintrag.anzeigeName`

Neue Computed-Property, die die bisherige Priorisierungslogik kapselt und um den
alternativen Namen an oberster Stelle erweitert:

```swift
var anzeigeName: String {
    if let alternativerName, !alternativerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return alternativerName
    }
    let name = produktName ?? artikel?.name ?? artikelNameSnapshot
    return name.isEmpty ? "Unbekannter Artikel" : name
}
```

Priorität: **`alternativerName`** (falls gesetzt und nicht nur Leerzeichen) → sonst
wie bisher `produktName` → `artikel?.name` → `artikelNameSnapshot`.

Jede Stelle, die den Anzeigenamen einer Belegposition/eines Kaufeintrags zeigt, nutzt
`anzeigeName` statt die Priorisierung selbst nachzubilden. Aktuell ist das
`PreisHistorieZeile` (`ShopWithMe/Views/Historie/PreisHistorieZeile.swift`), verwendet
in:

- `GeschaeftDetailView` (Preishistorie-Sektion eines Geschäfts, `zeigeArtikel: true`)
- `ArtikelEditView` (Preishistorie-Sektion eines Artikels, `zeigeArtikel: false` —
  zeigt dort den Geschäftsnamen statt des Artikelnamens, `alternativerName` ist dort
  entsprechend nicht relevant für die sichtbare Spalte, bleibt aber am `KaufEintrag`
  gesetzt)

Der Belegscan-Abgleich beim Übernehmen neuer Positionen
(`BelegScanView.passtZu`/`passendesArtikel`) bleibt bewusst unverändert auf
`artikel?.name`/`artikelNameSnapshot` bezogen — der alternative Anzeigename
beeinflusst nur die Darstellung, nicht die Zuordnungslogik beim Scannen.

## UI: Alternativen Namen vergeben

`PreisHistorieZeile` bietet in der Artikel-Ansicht (`zeigeArtikel == true`) eine
Wisch-Aktion „Umbenennen“ (führende Kante, Stift-Symbol) an, die einen Alert mit
Texteingabe öffnet:

- **Speichern** setzt `eintrag.alternativerName` auf den (getrimmten) eingegebenen
  Text, oder `nil`, falls das Feld leer gelassen wurde.
- **Zurücksetzen** (nur sichtbar, wenn bereits ein alternativer Name gesetzt ist)
  löscht `alternativerName` wieder — die Anzeige fällt dann zurück auf
  `produktName`/`artikel?.name`/`artikelNameSnapshot`.
- **Abbrechen** verwirft die Eingabe.

Die Änderung wirkt sich sofort auf alle Anzeigen dieser Position aus (SwiftData
persistiert die Mutation über den üblichen Autosave-Mechanismus, kein expliziter
Save-Aufruf nötig — siehe bestehende Mutationsstellen wie
`Einkaufsvorgang.artikelAbhaken`).

## Bewusst nicht umgesetzt

- **Kein Alias auf `Artikel`-Ebene**: Der alternative Name hängt an der einzelnen
  `KaufEintrag`-Position, nicht am übergreifenden `Artikel`. Ein Alias auf
  `Artikel.name` selbst (der dann für *alle* zukünftigen Belege desselben Artikels
  gelten würde) ist eine andere, größere Änderung (u.a. Auswirkung auf
  `ArtikelListView`, `EinkaufenView`, KI-Vorschläge) und nicht Teil dieser Iteration.
- **Kein Rename-Einstieg direkt im Belegscan-Dialog** (`BelegScanView`/
  `ErgebnisListe`): Dort lässt sich der erkannte Name vor dem Übernehmen weiterhin nur
  zwecks Artikel-Zuordnung überschreiben (bestehendes Verhalten, wird als
  `produktName` archiviert). Der neue alternative Name wird bewusst erst *nach* dem
  Übernehmen, in der Preishistorie, vergeben — dort ist bereits klar, ob/welchem
  `Artikel` die Position zugeordnet wurde.
