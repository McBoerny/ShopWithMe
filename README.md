# ShopWithMe

iOS-App (SwiftUI, iOS 26+) zum täglichen Einkaufen: Artikel, Geschäfte, Regale,
Kategorie-Zuordnung, lernende Regal-Reihenfolge, KI-gestützte Artikelanlage und
Belegscan mit Preishistorie.

Siehe [docs/BEDIENUNGSANLEITUNG.md](docs/BEDIENUNGSANLEITUNG.md) für die Bedienung
der App, [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md) für die vollständige
Spezifikation, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) für die technische
Umsetzung, [docs/ROADMAP.md](docs/ROADMAP.md) für den Checkpoint-Fortschritt und
[docs/CHANGELOG.md](docs/CHANGELOG.md) für die Versionshistorie.

## Projekt öffnen

```sh
brew install xcodegen   # falls noch nicht installiert
xcodegen generate
open ShopWithMe.xcodeproj
```

Falls `xcode-select` nicht auf eine vollständige Xcode-Installation zeigt:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## DocC-Dokumentation generieren

```sh
xcodebuild docbuild -scheme ShopWithMe -destination 'generic/platform=iOS'
```

(oder in Xcode: Product → Build Documentation)
