import Foundation
import os

/// Geordnete Protokoll-Verbositätsstufe, gemeinsam von ``SyncDebugLogger`` und
/// ``DatabaseDebugLogger`` genutzt (siehe `docs/LOGGING.md` — Live-Fund:
/// ein einzelner anhaltender Fehler erzeugte 1065 identische Protokollzeilen,
/// während die überwiegende Mehrheit des restlichen Volumens aus
/// unveränderten „nichts geschehen"-Zeilen bestand, die für die meisten
/// Fragestellungen nicht gebraucht werden). Jedes Ereignis eines Mechanismus
/// trägt seine eigene ``mindestStufe`` — protokolliert wird, wenn die
/// eingestellte Stufe die des Ereignisses erreicht oder übersteigt
/// (`konfiguriert >= ereignis.mindestStufe`).
enum Protokollstufe: Int, Comparable, CaseIterable, Hashable {
    /// Nichts wird protokolliert.
    case aus = 0
    /// Nur Fehler und seltene, für sich schon bedeutsame Zustandsübergänge
    /// (z.B. ein tatsächlicher Schreibvorgang, ein endgültig aufgegebenes
    /// Event) — Ereignisse, die unabhängig von der Zyklus-/Poll-Frequenz nur
    /// auftreten, wenn etwas Bemerkenswertes passiert.
    case fehler = 1
    /// Zusätzlich die normale, wiederkehrende Grundaktivität (ein Ereignis
    /// pro Zyklus/Aktion, z.B. Zyklus-Start/Ende, empfangene Peer-Snapshots,
    /// Lease-Erwerb) — bisheriges Standardverhalten ohne die lautesten
    /// Detail-Zeilen.
    case standard = 2
    /// Zusätzlich hochfrequente Detail-Ereignisse, die mehrfach pro Zyklus
    /// unbedingt feuern (z.B. je Teilbereich ein „unverändert"-Eintrag) oder
    /// nur für eine gezielte Tiefenanalyse gedacht sind (z.B. die
    /// Security-Scope-Zugriffsdiagnose) — nur für eine konkrete
    /// Fragestellung gezielt einschalten, nicht dauerhaft.
    case ausfuehrlich = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Kurzer, für die Einstellungen-UI gedachter Anzeigename (siehe
    /// `DebuggingView`).
    var anzeigename: String {
        switch self {
        case .aus: return "Aus"
        case .fehler: return "Fehler"
        case .standard: return "Standard"
        case .ausfuehrlich: return "Ausführlich"
        }
    }
}

/// Unterdrückt exakt wiederholte Ereignisse (gleicher Ereignistyp + gleicher
/// Detail-Text) zugunsten eines periodischen Lebenszeichens, statt jede
/// einzelne Wiederholung zu protokollieren — siehe `docs/LOGGING.md`,
/// Live-Fund vom 2026-08-02 (ein einziger anhaltender
/// `sync_ordner_zugriff_fehlgeschlagen`-Zustand erzeugte binnen 27 Minuten
/// 1065 identische Zeilen). Ändert sich der Inhalt (andere Details, z.B. weil
/// der Fehler behoben wurde oder ein anderer Teilbereich betroffen ist),
/// wird sofort wieder normal protokolliert — nur exakt unveränderte
/// Wiederholungen werden gedrosselt.
///
/// **Schlüsselbildung:** Ereignistyp + erstes Wort des Detail-Texts (das in
/// den bestehenden Detail-Formaten üblicherweise der stabile Bezugspunkt ist,
/// z.B. der Funktionsname bei `sync_ordner_zugriff_fehlgeschlagen` oder der
/// Teilbereichsname bei `sync_snapshot_unveraendert_uebersprungen`) — nicht
/// der komplette Detail-Text, da dieser bei manchen Ereignissen (z.B.
/// `alter_sekunden=…`) bei jedem Aufruf einen neuen, sich ständig ändernden
/// Wert enthält und sonst nie zwei Aufrufe denselben Schlüssel träfen. Der
/// volle Inhalt wird trotzdem für den eigentlichen Änderungs-Vergleich
/// herangezogen — nur die Gruppierung erfolgt über das erste Wort.
/// `@unchecked Sendable`, weil der gesamte veränderliche Zustand
/// (`zustandJeSchluessel`) ausschließlich unter ``sperre`` gelesen/
/// geschrieben wird — vom Compiler nicht automatisch verifizierbar, aber
/// durch die `NSLock`-Kapselung in ``pruefe(ereignis:details:jetzt:)``
/// tatsächlich sicher, analog dem `nonisolated(unsafe)`-Caching-Muster der
/// Logger-Schalter in derselben Datei.
final class WiederholungsFilter: @unchecked Sendable {
    private struct Zustand {
        var letzterInhalt: String
        var ersterZeitpunkt: Date
        var letzterProtokollierterZeitpunkt: Date
        var unterdrueckteAnzahl = 0
    }

    private let lebenszeichenIntervall: TimeInterval
    private let sperre = NSLock()
    private var zustandJeSchluessel: [String: Zustand] = [:]

    init(lebenszeichenIntervall: TimeInterval = 60) {
        self.lebenszeichenIntervall = lebenszeichenIntervall
    }

    /// Liefert den tatsächlich zu schreibenden Detail-Text, oder `nil`, wenn
    /// diese Wiederholung unterdrückt werden soll.
    func pruefe(ereignis: String, details: String, jetzt: Date = Date()) -> String? {
        let gruppenSchluessel = ereignis + "|" + (details.split(separator: " ").first.map(String.init) ?? "")
        sperre.lock()
        defer { sperre.unlock() }

        guard var zustand = zustandJeSchluessel[gruppenSchluessel], zustand.letzterInhalt == details else {
            zustandJeSchluessel[gruppenSchluessel] = Zustand(
                letzterInhalt: details, ersterZeitpunkt: jetzt, letzterProtokollierterZeitpunkt: jetzt
            )
            return details
        }

        guard jetzt.timeIntervalSince(zustand.letzterProtokollierterZeitpunkt) >= lebenszeichenIntervall else {
            zustand.unterdrueckteAnzahl += 1
            zustandJeSchluessel[gruppenSchluessel] = zustand
            return nil
        }

        let seitSekunden = Int(jetzt.timeIntervalSince(zustand.ersterZeitpunkt))
        let ergebnis = "\(details) (unverändert seit \(seitSekunden)s, \(zustand.unterdrueckteAnzahl) weitere unterdrückt)"
        zustand.letzterProtokollierterZeitpunkt = jetzt
        zustand.unterdrueckteAnzahl = 0
        zustandJeSchluessel[gruppenSchluessel] = zustand
        return ergebnis
    }
}

/// Generischer, mechanismus-unabhängiger Baustein für optionale Diagnose-Logs (siehe
/// `docs/LOGGING.md`). Kapselt Zwei-Datei-Rotation bei fester Größengrenze,
/// Spiegelung nach `os.Logger` und asynchrones Schreiben auf einem eigenen Actor,
/// damit das Protokollieren selbst die beobachteten Vorgänge nicht messbar
/// verlangsamt oder verfälscht.
///
/// Jeder konkrete Diagnose-Mechanismus (z.B. ``DatabaseDebugLogger``) ist ein dünner,
/// fachlicher Wrapper um eine Instanz dieses Typs.
actor DebugLogWriter {
    private let dateiURL: URL
    private let vorherigeDateiURL: URL
    private let maxGroesse: Int
    private let osLogger: Logger

    init(kategorie: String, dateiURL: URL, maxGroesse: Int = 1_000_000) {
        self.dateiURL = dateiURL
        self.vorherigeDateiURL = dateiURL.deletingPathExtension().appendingPathExtension("previous.log")
        self.maxGroesse = maxGroesse
        self.osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ShopWithMe", category: kategorie)
    }

    /// Schreibt ein Ereignis im projektweit einheitlichen Zeilenformat (siehe
    /// `docs/LOGGING.md` → „Gemeinsame Prinzipien“) sowohl in die Log-Datei als auch
    /// (zusätzlich, nicht als Ersatz) nach `os.Logger`.
    func protokolliere(ereignis: String, details: String, geraeteName: String) {
        let zeitstempel = ISO8601DateFormatter().string(from: Date())
        let zeile = "[\(zeitstempel)] [\(geraeteName)] [\(ereignis)] \(details)\n"
        osLogger.log("\(ereignis, privacy: .public): \(details, privacy: .public)")
        schreibeInDatei(zeile)
    }

    private func schreibeInDatei(_ zeile: String) {
        rotiereFallsNoetig()
        guard let daten = zeile.data(using: .utf8) else { return }
        let dateiManager = FileManager.default
        if !dateiManager.fileExists(atPath: dateiURL.path) {
            dateiManager.createFile(atPath: dateiURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: dateiURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: daten)
    }

    private func rotiereFallsNoetig() {
        let dateiManager = FileManager.default
        guard let groesse = (try? dateiManager.attributesOfItem(atPath: dateiURL.path))?[.size] as? Int,
              groesse >= maxGroesse else { return }
        try? dateiManager.removeItem(at: vorherigeDateiURL)
        try? dateiManager.moveItem(at: dateiURL, to: vorherigeDateiURL)
    }

    /// Aktuelle Gesamtgröße (aktuelle + vorherige Datei) in Byte, für die Anzeige in
    /// den Einstellungen. Greift nur auf unveränderliche Konstanten zu, daher sicher
    /// `nonisolated`.
    nonisolated func aktuelleGroesse() -> Int {
        let dateiManager = FileManager.default
        let groesseAktuell = (try? dateiManager.attributesOfItem(atPath: dateiURL.path))?[.size] as? Int ?? 0
        let groesseVorherige = (try? dateiManager.attributesOfItem(atPath: vorherigeDateiURL.path))?[.size] as? Int ?? 0
        return groesseAktuell + groesseVorherige
    }

    nonisolated func leere() {
        let dateiManager = FileManager.default
        try? dateiManager.removeItem(at: dateiURL)
        try? dateiManager.removeItem(at: vorherigeDateiURL)
    }

    nonisolated var exportURLs: [URL] {
        let dateiManager = FileManager.default
        return [dateiURL, vorherigeDateiURL].filter { dateiManager.fileExists(atPath: $0.path) }
    }
}
