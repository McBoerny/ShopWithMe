# Beleg-Testfälle

Dieser Ordner enthält echte Kassenbon-Fotos mit zugehörigen Soll-Zustand-Dateien für
die Integration-Tests des Belegscans (`BelegScanIntegrationTests`).

## Dateiformat

Pro Testfall zwei Dateien mit identischem Basisnamen:

- `<name>.jpg` (oder `.jpeg`, `.png`) — Foto des Kassenbons
- `<name>.json` — erwartetes Scan-Ergebnis (Soll-Zustand)

### JSON-Format

```json
{
  "beschreibung": "REWE Markt, 2026-03-24 — 12 Positionen",
  "sollErgebnis": {
    "geschaeftName": "REWE",
    "datum": "2026-03-24",
    "positionen": [
      { "artikelName": "Vollmilch 3,5%", "einzelpreis": "1.29" },
      { "artikelName": "Butter mild", "einzelpreis": "1.99" }
    ]
  },
  "mindestPositionenTrefferQuote": 0.75
}
```

### Felder

| Feld | Bedeutung |
| --- | --- |
| `beschreibung` | Freitext-Beschreibung für den Test-Report |
| `sollErgebnis.geschaeftName` | Erwarteter Geschäftsname (Teilstring-Abgleich, leer = nicht geprüft) |
| `sollErgebnis.datum` | Erwartetes Datum `JJJJ-MM-TT`, leer = nicht geprüft |
| `sollErgebnis.positionen[].artikelName` | Erwarteter Artikelname (Teilstring-Abgleich) |
| `sollErgebnis.positionen[].einzelpreis` | Erwarteter Einzelpreis, Dezimalpunkt `.` (exakter Cent-Abgleich) |
| `mindestPositionenTrefferQuote` | Anteil der Positionen, der erkannt werden muss (0.0–1.0, z.B. 0.75 = 75 %) |

## Datenschutz

Keine vollständigen Kaufdetails (Kundenkarte, Zahlungsart, personenbezogene Daten)
im JSON hinterlegen. Das Foto selbst enthält nur Kassenbon-Inhalt — prüfen, ob
Bon-Zeilen auf persönliche Daten hinweisen, bevor er eingecheckt wird.
