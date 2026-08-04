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
            titel: "Abteilungen pro Geschäft",
            text: """
            Unter Einstellungen → Geschäfte kannst du einem Geschäft direkt Abteilungen \
            zuordnen („Abteilungen“-Abschnitt → „Abteilung hinzufügen“). Zusammen mit \
            den unter Einstellungen → Geschäftstypen hinterlegten Standard-Abteilungen \
            des Geschäftstyps ergibt das die verfügbaren Abteilungen, die beim Einkaufen \
            dort auftauchen. So zeigt dir die App im Baumarkt keine Milchprodukte an.
            """
        ),
        HilfeThema(
            titel: "Geschäftstypen & Standard-Abteilungen",
            text: """
            Unter Einstellungen → Geschäftstypen legst du je Geschäftstyp (z.B. \
            Drogerie) fest, welche Abteilungen dort typischerweise geführt werden. \
            Jedes Geschäft mit diesem Typ macht diese Abteilungen automatisch \
            verfügbar, ganz ohne sie dem einzelnen Geschäft manuell zuzuordnen. Ist \
            Apple Intelligence verfügbar, schlägt „KI-Vorschlag“ passende \
            Abteilungen vor.
            """
        ),
        HilfeThema(
            titel: "Automatische Einkaufsreihenfolge",
            text: """
            Die App merkt sich beim Abhaken, in welcher Reihenfolge du typischerweise \
            durch ein Geschäft läufst, und sortiert deine Einkaufsliste danach — ganz \
            ohne Ladenplan oder Standortfreigabe, allein aus deinem bisherigen \
            Abhakverhalten gelernt. Ein Hinweis oben in der Liste zeigt an, ob die \
            Reihenfolge schon optimiert ist oder noch lernt; nach jeder Abhakung wird \
            die verbleibende Liste automatisch neu sortiert. Ändert sich die \
            Anordnung im Geschäft, erkennt die App das und passt sich mit den \
            nächsten Einkäufen automatisch an.
            """
        ),
        HilfeThema(
            titel: "KI-Artikelvorschläge",
            text: """
            Beim Anlegen eines neuen Artikels kann dir Apple Intelligence (sofern auf \
            deinem Gerät aktiviert) automatisch ein passendes Symbol, eine Farbe und \
            eine Abteilung vorschlagen. Tippe dazu im Anlegen-Formular auf „Mit Apple \
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
            gespeichert. Über „Beleg anzeigen“ kannst du das Original-Foto zoombar \
            prüfen; das Lupen-Symbol neben einer Position zeigt die erkannte Stelle \
            direkt im Beleg. Die erfassten Preise findest du als Preishistorie in \
            der Artikel- bzw. Geschäfts-Detailansicht.
            """
        ),
        HilfeThema(
            titel: "MilkForUs-Textimport",
            text: """
            In den Einstellungen unter „Einkaufslisten“ kannst du über „MilkForUs \
            importieren“ eine aus der Shopping-App „MilkForUs“ exportierte Textdatei \
            einlesen — per Datei-Auswahl oder direkt über die Teilen-Funktion eines \
            anderen Apps (z.B. eine per Chat empfangene Datei). Abteilungen werden \
            automatisch mit deinem Bestand abgeglichen (exakter Name oder \
            KI-Vorschlag); in der Vorschau kannst du das vor dem Übernehmen noch \
            ändern oder einzelne Artikel ausschließen.
            """
        ),
    ]
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
