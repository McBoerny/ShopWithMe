# ShopWithMe

iOS-App (SwiftUI, iOS 26+) zum täglichen Einkaufen: Artikel, Geschäfte, Regale,
Kategorie-Zuordnung, lernende Regal-Reihenfolge, KI-gestützte Artikelanlage und
Belegscan mit Preishistorie.

Siehe [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md) für die vollständige Spezifikation,
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) für die technische Umsetzung und
[docs/ROADMAP.md](docs/ROADMAP.md) für den Checkpoint-Fortschritt.

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
