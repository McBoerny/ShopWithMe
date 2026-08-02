import Foundation
import Testing
@testable import ShopWithMe

/// Tests für ``Protokollstufe`` selbst (Ordnung), die Migration vom alten
/// Bool-Schalter (``SyncDebugLogger``/``DatabaseDebugLogger``) sowie
/// stichprobenartige ``mindestStufe``-Einordnungen — siehe `docs/LOGGING.md`.
struct ProtokollstufeTests {
    @Test
    func stufenSindAufsteigendGeordnet() {
        #expect(Protokollstufe.aus < .fehler)
        #expect(Protokollstufe.fehler < .standard)
        #expect(Protokollstufe.standard < .ausfuehrlich)
    }

    // MARK: - Migration SyncDebugLogger

    private func isolierteDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test
    func syncMigrationOhneVorherigenWertErgibtAus() {
        let defaults = isolierteDefaults(#function)

        let stufe = SyncDebugLogger.ermittleMigrierteStartstufe(defaults: defaults)

        #expect(stufe == .aus)
        #expect(defaults.integer(forKey: SyncDebugLogger.stufeSchluessel) == Protokollstufe.aus.rawValue)
    }

    @Test
    func syncMigrationVonAlterAktivFlagErgibtStandard() {
        let defaults = isolierteDefaults(#function)
        defaults.set(true, forKey: SyncDebugLogger.alterAktivSchluessel)

        let stufe = SyncDebugLogger.ermittleMigrierteStartstufe(defaults: defaults)

        #expect(stufe == .standard)
    }

    @Test
    func syncMigrationVonAlterInaktivFlagErgibtAus() {
        let defaults = isolierteDefaults(#function)
        defaults.set(false, forKey: SyncDebugLogger.alterAktivSchluessel)

        let stufe = SyncDebugLogger.ermittleMigrierteStartstufe(defaults: defaults)

        #expect(stufe == .aus)
    }

    @Test
    func syncBereitsGespeicherteStufeGewinntGegenAltenBoolKey() {
        let defaults = isolierteDefaults(#function)
        defaults.set(false, forKey: SyncDebugLogger.alterAktivSchluessel)
        defaults.set(Protokollstufe.ausfuehrlich.rawValue, forKey: SyncDebugLogger.stufeSchluessel)

        let stufe = SyncDebugLogger.ermittleMigrierteStartstufe(defaults: defaults)

        #expect(stufe == .ausfuehrlich)
    }

    // MARK: - Migration DatabaseDebugLogger

    @Test
    func datenbankMigrationVonAlterAktivFlagErgibtStandard() {
        let defaults = isolierteDefaults(#function)
        defaults.set(true, forKey: DatabaseDebugLogger.alterAktivSchluessel)

        let stufe = DatabaseDebugLogger.ermittleMigrierteStartstufe(defaults: defaults)

        #expect(stufe == .standard)
    }

    // MARK: - mindestStufe-Einordnung (Stichprobe)

    @Test
    func syncEreignisEinordnung() {
        #expect(SyncDebugLogger.Ereignis.ordnerZugriffFehlgeschlagen.mindestStufe == .fehler)
        #expect(SyncDebugLogger.Ereignis.eventAufgegeben.mindestStufe == .fehler)
        #expect(SyncDebugLogger.Ereignis.zyklusStart.mindestStufe == .standard)
        #expect(SyncDebugLogger.Ereignis.snapshotEmpfangen.mindestStufe == .standard)
        #expect(SyncDebugLogger.Ereignis.snapshotUnveraendertUebersprungen.mindestStufe == .ausfuehrlich)
        #expect(SyncDebugLogger.Ereignis.scopeZugriff.mindestStufe == .ausfuehrlich)
    }

    @Test
    func datenbankEreignisEinordnung() {
        #expect(DatabaseDebugLogger.Ereignis.saveFailure.mindestStufe == .fehler)
        #expect(DatabaseDebugLogger.Ereignis.leaseStaleTakeover.mindestStufe == .fehler)
        #expect(DatabaseDebugLogger.Ereignis.saveSuccess.mindestStufe == .standard)
        #expect(DatabaseDebugLogger.Ereignis.leaseAcquireSuccess.mindestStufe == .standard)
    }
}
