import SwiftUI

/// Ausklappbare Anleitungen für die komplexeren Funktionen der App.
struct HelpView: View {
    var body: some View {
        List {
            Section {
                ForEach(HilfeThema.alle) { thema in
                    DisclosureGroup(thema.titel) {
                        Text(thema.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Hilfe & Anleitungen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ein einzelnes Hilfe-Thema.
private struct HilfeThema: Identifiable {
    let id = UUID()
    let titel: String
    let text: String

    static let alle: [HilfeThema] = [
        HilfeThema(
            titel: "Kategorien & Regale pro Geschäft",
            text: """
            Im Geschäfte-Tab kannst du einem Geschäft direkt Kategorien zuordnen \
            („Kategorien“-Abschnitt → „Kategorie hinzufügen“) — ganz ohne ein Regal \
            anzulegen. Nur zugeordnete Kategorien gelten in diesem Geschäft als \
            verfügbar und tauchen beim Einkaufen dort auf. So zeigt dir die App im \
            Baumarkt keine Milchprodukte an. Regale sind optional und dienen nur \
            dazu, die Reihenfolge beim Einkaufen zu organisieren — du kannst ihnen \
            zusätzlich Kategorien zuordnen (Regal antippen), musst es aber nicht.
            """
        ),
        HilfeThema(
            titel: "Automatische Regal-Reihenfolge",
            text: """
            Du kannst die Reihenfolge der Regale eines Geschäfts jederzeit manuell \
            per Drag & Drop festlegen (Geschäfte-Tab → Geschäft → „Bearbeiten“). \
            Zusätzlich merkt sich die App, in welcher Reihenfolge du beim Einkaufen \
            tatsächlich durch die Regale läufst. Nach 5 abgeschlossenen Einkäufen in \
            einem Geschäft bietet sie dir eine automatische Reihenfolge an — deine \
            manuelle Reihenfolge bleibt aber so lange bestehen, bis du den Vorschlag \
            explizit übernimmst.
            """
        ),
        HilfeThema(
            titel: "KI-Artikelvorschläge",
            text: """
            Beim Anlegen eines neuen Artikels kann dir Apple Intelligence (sofern auf \
            deinem Gerät aktiviert) automatisch ein passendes Symbol, eine Farbe und \
            eine Kategorie vorschlagen. Tippe dazu im Anlegen-Formular auf „Mit Apple \
            Intelligence vorschlagen“, nachdem du einen Namen eingegeben hast. Ist \
            Apple Intelligence auf deinem Gerät nicht verfügbar, wird diese \
            Schaltfläche einfach nicht angezeigt — du kannst Artikel jederzeit auch \
            komplett manuell anlegen.
            """
        ),
        HilfeThema(
            titel: "Belegscan & Preishistorie",
            text: """
            Nach dem Abschließen eines Einkaufs bietet dir die App an, den \
            Kassenbon zu scannen (Foto aufnehmen oder aus der Mediathek wählen). \
            Lokale KI erkennt Artikel und Preise auf dem Beleg und trägt sie in \
            die passenden Positionen deines Einkaufs ein — Positionen, die sich \
            keinem Artikel zuordnen lassen, werden trotzdem mit Namen und Preis \
            gespeichert. Die erfassten Preise findest du als Preishistorie in der \
            Artikel- bzw. Geschäfts-Detailansicht.
            """
        ),
        HilfeThema(
            titel: "Datenbank-Speicherort ändern",
            text: """
            In den Einstellungen unter „Datenbank & Speicherort“ kannst du einen \
            eigenen Ordner für deine Daten wählen, z.B. einen lokal gespiegelten \
            Cloud-Ordner. Das ist kein automatischer iCloud-Sync über mehrere Geräte \
            — wenn du einen Cloud-Sync-Ordner wählst, solltest du die App nur auf \
            einem Gerät gleichzeitig aktiv benutzen, um Konflikte zu vermeiden. Die \
            Änderung wird erst nach einem Neustart der App wirksam.
            """
        ),
    ]
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
