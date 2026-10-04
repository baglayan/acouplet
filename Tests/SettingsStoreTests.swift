import Foundation
import XCTest
@testable import Acouplet

final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testLegacyPreferencesMigrateOnceWithoutReplacingCurrentValuesOrUpdatePolicy() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let draft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let profile = SavedEqualizerProfile(id: UUID(), name: "Night", settings: draft)
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "02:00:00:00:00:01",
                                                                  model: .wfXM5, hash: "12345678", peripheralIdentifier: nil))
        let history = Data("history".utf8)
        let legacy: [String: Any] = [
            "preferences.reconnectAutomatically": false,
            "preferences.showBatteryInMenuBar": true,
            "preferences.customEqualizerDraft": try JSONEncoder().encode(draft),
            "preferences.equalizerProfiles": try JSONEncoder().encode([profile]),
            "headphones.verifiedIdentities": [identity.classicAddress: identity.propertyList],
            "notifications.lowBatteryHistory": history,
            "firmwareUpdate.fixture.notified": "1.2.3",
            "SUEnableAutomaticChecks": false,
            "SUAutomaticallyUpdate": true,
            "SUFeedURL": "https://example.invalid/appcast.xml",
            "SUSkippedVersion": "56",
            "NSWindow Frame about": "old frame",
        ]
        defaults.set(false, forKey: "preferences.showBatteryInMenuBar")
        SettingsStore.migrateLegacyPreferences(from: legacy, to: defaults, bundleIdentifier: "dev.baglayan.Acouplet")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.reconnectAutomatically)
        XCTAssertFalse(settings.showBatteryInMenuBar)
        XCTAssertEqual(settings.customEqualizerDraft, draft)
        XCTAssertEqual(settings.equalizerProfiles, [profile])
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults)[identity.classicAddress], identity)
        XCTAssertEqual(defaults.data(forKey: "notifications.lowBatteryHistory"), history)
        XCTAssertEqual(defaults.string(forKey: "firmwareUpdate.fixture.notified"), "1.2.3")
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, true)
        for key in ["SUFeedURL", "SUSkippedVersion", "NSWindow Frame about"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
        settings.reconnectAutomatically = true
        defaults.removeObject(forKey: "preferences.equalizerProfiles")
        SettingsStore.migrateLegacyPreferences(from: legacy, to: defaults, bundleIdentifier: "dev.baglayan.Acouplet")
        XCTAssertTrue(SettingsStore(defaults: defaults).reconnectAutomatically)
        XCTAssertTrue(SettingsStore(defaults: defaults).equalizerProfiles.isEmpty)
    }

    @MainActor
    func testLegacyPreferencesDoNotMigrateIntoOtherAppIdentities() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for identifier in ["dev.baglayan.Acouplet.debug", "example.unrelated", nil] {
            SettingsStore.migrateLegacyPreferences(from: ["preferences.showBatteryInMenuBar": true],
                                                   to: defaults, bundleIdentifier: identifier)
            XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLDACMatrixPreferencesRoundTripAndRejectInvalidFormats() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.ldacConfiguration, LDACConfiguration())
        let expected = [[303, 606, 909, 303], [330, 660, 990, 330], [303, 606, 909, 303], [330, 660, 990, 330]]
        for (rateIndex, rate) in LDACSampleRate.allCases.enumerated() {
            for (qualityIndex, quality) in LDACQuality.allCases.enumerated() {
                let configuration = LDACConfiguration(sampleRate: rate, quality: quality)
                settings.ldacConfiguration = configuration
                XCTAssertEqual(SettingsStore(defaults: defaults).ldacConfiguration, configuration)
                XCTAssertEqual(configuration.bitrateKbps, expected[rateIndex][qualityIndex])
                XCTAssertEqual(configuration.format.sampleRateHz, rate.rawValue)
                XCTAssertEqual(configuration.helperArguments, ["--sample-rate", String(rate.rawValue), "--quality", quality.rawValue])
            }
        }
        for invalid in [#"{"sampleRate":192000,"quality":"high"}"#, #"{"sampleRate":48000,"quality":"unsupported"}"#, "invalid"] {
            defaults.set(Data(invalid.utf8), forKey: "preferences.ldacConfiguration")
            XCTAssertEqual(SettingsStore(defaults: defaults).ldacConfiguration, LDACConfiguration())
        }
    }
    #endif

    @MainActor
    func testLDACDefaultsFollowDistributionAndExplicitPreferencePersists() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let production = SettingsStore(defaults: defaults, isDevelopmentDistribution: false)
        XCTAssertFalse(production.experimentalLDACEnabled)
        XCTAssertTrue(SettingsStore(defaults: defaults, isDevelopmentDistribution: true).experimentalLDACEnabled)
        XCTAssertNil(defaults.object(forKey: "preferences.experimentalLDACEnabled"))
        production.experimentalLDACEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults, isDevelopmentDistribution: false).experimentalLDACEnabled)
        production.experimentalLDACEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults, isDevelopmentDistribution: true).experimentalLDACEnabled)
    }

    @MainActor
    func testGlobalShortcutConflictRecoversAfterRegistrationIsReleased() throws {
        let first = GlobalHotKeyController {}
        let second = GlobalHotKeyController {}
        guard first.setEnabled(true) == nil else {
            throw XCTSkip("The shortcut is registered outside this isolated test.")
        }
        defer {
            _ = first.setEnabled(false)
            _ = second.setEnabled(false)
        }
        XCTAssertNil(first.setEnabled(true))
        XCTAssertNotNil(second.setEnabled(true))
        XCTAssertNil(second.setEnabled(false))
        XCTAssertNil(first.setEnabled(false))
        XCTAssertNil(second.setEnabled(true))
    }

    @MainActor
    func testPresetNamePreflightMatchesSavedNamesAndPreservesReplacementIdentity() {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        for proposedName in ["  Night\n", String(repeating: "a", count: 40), "  "] {
            let expectedName = settings.equalizerProfileName(for: proposedName)
            XCTAssertEqual(settings.saveEqualizerProfile(named: proposedName).name, expectedName)
        }
        let original = settings.equalizerProfiles[0]
        let name = settings.equalizerProfileName(for: " NIGHT ")
        XCTAssertEqual(settings.equalizerProfiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id, original.id)
        XCTAssertEqual(SettingsStore(defaults: defaults).equalizerProfiles[0], original)
        settings.customEqualizerDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let replacement = settings.saveEqualizerProfile(named: name)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.settings, settings.customEqualizerDraft)
        settings.deleteEqualizerProfile(id: replacement.id)
        XCTAssertFalse(SettingsStore(defaults: defaults).equalizerProfiles.contains { $0.id == original.id })
    }

    @MainActor
    func testRestoredEqualizerNormalizesBandCountAndLevels() {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"clearBass":99,"bands":[-99,4]}"#.utf8), forKey: "preferences.customEqualizerDraft")

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.customEqualizerDraft, EqualizerSettings(clearBass: 10, bands: [-10, 4, 0, 0, 0]))
        XCTAssertEqual(restored.customEqualizerDraft[band: 4], 0)
    }

    @MainActor
    func testEqualizerDraftsRemainIndependentAcrossDevicesAndRelaunches() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let first = "02:00:00:00:00:01"
        let second = "02:00:00:00:00:02"
        let firstDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let secondDraft = EqualizerSettings(clearBass: -2, bands: [0, -1, -2, -3, -4])
        settings.customEqualizerDraft = firstDraft
        settings.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(settings.customEqualizerDraft, firstDraft)
        settings.selectEqualizerDevice(address: second, defaultDraft: secondDraft)
        XCTAssertEqual(settings.customEqualizerDraft, secondDraft)
        settings.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(settings.customEqualizerDraft, firstDraft)
        settings.selectEqualizerDevice(address: first.replacingOccurrences(of: ":", with: "-"), defaultDraft: secondDraft)
        XCTAssertEqual(settings.customEqualizerDraft, firstDraft)
        let restored = SettingsStore(defaults: defaults)
        restored.selectEqualizerDevice(address: second, defaultDraft: .flat)
        XCTAssertEqual(restored.customEqualizerDraft, secondDraft)
        restored.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(restored.customEqualizerDraft, firstDraft)
    }

    @MainActor
    func testMultipointSourcesWithTheSameNameRemainDistinguishable() {
        let first = SonyMultipointDevice(address: "02:00:00:00:00:01", connectionID: 1, classOfDevice: 0, name: "MacBook Pro")
        let second = SonyMultipointDevice(address: "02:00:00:00:00:02", connectionID: 2, classOfDevice: 0, name: "macbook pro")
        XCTAssertEqual(MultipointControls.title(for: first, among: [first]), first.name)
        XCTAssertEqual(MultipointControls.title(for: first, among: [first, second]), "MacBook Pro · 02:00:00:00:00:01")
        XCTAssertEqual(MultipointControls.title(for: second, among: [first, second]), "macbook pro · 02:00:00:00:00:02")
    }

    @MainActor
    func testDefaultsAndPersistence() {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.keepMenuBarIconWhenDisconnected)
        settings.keepMenuBarIconWhenDisconnected = true
        XCTAssertTrue(SettingsStore(defaults: defaults).keepMenuBarIconWhenDisconnected)
        settings.keepMenuBarIconWhenDisconnected = false
        XCTAssertFalse(SettingsStore(defaults: defaults).keepMenuBarIconWhenDisconnected)
        XCTAssertFalse(settings.showBatteryInMenuBar)
        settings.showBatteryInMenuBar = true
        XCTAssertTrue(SettingsStore(defaults: defaults).showBatteryInMenuBar)
        XCTAssertTrue(settings.reconnectAutomatically)
        XCTAssertTrue(settings.globalShortcutEnabled)
        XCTAssertEqual(settings.customEqualizerDraft, .flat)

        settings.reconnectAutomatically = false
        settings.globalShortcutEnabled = false
        settings.customEqualizerDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let profile = settings.saveEqualizerProfile(named: "Night")

        XCTAssertFalse(SettingsStore(defaults: defaults).reconnectAutomatically)
        XCTAssertFalse(SettingsStore(defaults: defaults).globalShortcutEnabled)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.customEqualizerDraft, settings.customEqualizerDraft)
        XCTAssertEqual(restored.equalizerProfiles, [profile])
    }
}
