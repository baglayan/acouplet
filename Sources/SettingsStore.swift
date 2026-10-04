import Combine
import Foundation
import ServiceManagement

struct SavedEqualizerProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var settings: EqualizerSettings
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedSettingsPane = "general"
    @Published var reconnectAutomatically: Bool {
        didSet { defaults.set(reconnectAutomatically, forKey: Keys.reconnectAutomatically) }
    }
    @Published var keepMenuBarIconWhenDisconnected: Bool {
        didSet { defaults.set(keepMenuBarIconWhenDisconnected, forKey: Keys.keepMenuBarIconWhenDisconnected) }
    }
    @Published var showBatteryInMenuBar: Bool {
        didSet { defaults.set(showBatteryInMenuBar, forKey: Keys.showBatteryInMenuBar) }
    }
    @Published var lowBatteryNotificationsEnabled: Bool {
        didSet { defaults.set(lowBatteryNotificationsEnabled, forKey: Keys.lowBatteryNotificationsEnabled) }
    }
    @Published var firmwareNotificationsEnabled: Bool {
        didSet { defaults.set(firmwareNotificationsEnabled, forKey: Keys.firmwareNotificationsEnabled) }
    }
    @Published var experimentalLDACEnabled: Bool {
        didSet { defaults.set(experimentalLDACEnabled, forKey: Keys.experimentalLDACEnabled) }
    }
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @Published var ldacConfiguration: LDACConfiguration {
        didSet { persist(ldacConfiguration, forKey: Keys.ldacConfiguration) }
    }
    #endif
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var backgroundServiceStatus: SMAppService.Status = .notRegistered
    var hasBackgroundService: Bool {
        CommandLine.arguments.contains("--background-service")
    }
    @Published var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Keys.globalShortcutEnabled) }
    }
    @Published var globalShortcutError: String?
    @Published var customEqualizerDraft: EqualizerSettings {
        didSet {
            if let equalizerDeviceAddress {
                equalizerDraftsByDevice[equalizerDeviceAddress] = customEqualizerDraft
                persist(equalizerDraftsByDevice, forKey: Keys.equalizerDraftsByDevice)
            } else {
                persist(customEqualizerDraft, forKey: Keys.customEqualizerDraft)
            }
        }
    }
    @Published private(set) var equalizerProfiles: [SavedEqualizerProfile] {
        didSet { persist(equalizerProfiles, forKey: Keys.equalizerProfiles) }
    }

    let defaults: UserDefaults
    private var equalizerDeviceAddress: String?
    private var equalizerDraftsByDevice: [String: EqualizerSettings]

    private let managesLaunchService: Bool

    init(defaults: UserDefaults, managesLaunchService: Bool = false,
         isDevelopmentDistribution: Bool = Bundle.main.object(forInfoDictionaryKey: "AcoupletDistribution") as? String == "development") {
        self.defaults = defaults
        self.managesLaunchService = managesLaunchService
        keepMenuBarIconWhenDisconnected = defaults.bool(forKey: Keys.keepMenuBarIconWhenDisconnected)
        showBatteryInMenuBar = defaults.bool(forKey: Keys.showBatteryInMenuBar)
        lowBatteryNotificationsEnabled = defaults.bool(forKey: Keys.lowBatteryNotificationsEnabled)
        firmwareNotificationsEnabled = defaults.bool(forKey: Keys.firmwareNotificationsEnabled)
        experimentalLDACEnabled = defaults.object(forKey: Keys.experimentalLDACEnabled) == nil
            ? isDevelopmentDistribution
            : defaults.bool(forKey: Keys.experimentalLDACEnabled)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        ldacConfiguration = Self.decode(LDACConfiguration.self, from: defaults.data(forKey: Keys.ldacConfiguration)) ?? LDACConfiguration()
        #endif
        reconnectAutomatically = defaults.object(forKey: Keys.reconnectAutomatically) == nil
            ? true
            : defaults.bool(forKey: Keys.reconnectAutomatically)
        launchAtLogin = managesLaunchService && SMAppService.mainApp.status == .enabled
        globalShortcutEnabled = defaults.object(forKey: Keys.globalShortcutEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.globalShortcutEnabled)
        customEqualizerDraft = Self.decode(EqualizerSettings.self, from: defaults.data(forKey: Keys.customEqualizerDraft)) ?? .flat
        equalizerDraftsByDevice = Self.decode([String: EqualizerSettings].self, from: defaults.data(forKey: Keys.equalizerDraftsByDevice)) ?? [:]
        equalizerProfiles = Self.decode([SavedEqualizerProfile].self, from: defaults.data(forKey: Keys.equalizerProfiles)) ?? []
        refreshLaunchStatus()
    }

    static func migrateLegacyPreferences(from legacy: [String: Any], to defaults: UserDefaults, bundleIdentifier: String?) {
        let migrationKey = "migration.legacyPreferences"
        guard bundleIdentifier == "dev.baglayan.Acouplet", !defaults.bool(forKey: migrationKey) else { return }
        let keys = ["headphones.verifiedIdentity", "headphones.verifiedIdentities", "notifications.lowBatteryHistory",
                    "SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            if key.hasPrefix("preferences.") || key.hasPrefix("firmwareUpdate.") || keys.contains(key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }

    func selectEqualizerDevice(address: String, defaultDraft: EqualizerSettings) {
        let address = address.replacingOccurrences(of: "-", with: ":").uppercased()
        guard !address.isEmpty, equalizerDeviceAddress != address else { return }
        let draft = equalizerDraftsByDevice[address] ?? (equalizerDraftsByDevice.isEmpty ? customEqualizerDraft : defaultDraft)
        equalizerDeviceAddress = address
        customEqualizerDraft = draft
    }

    func refreshLaunchStatus() {
        guard managesLaunchService, let user = getpwuid(getuid()) else { return }
        let home = String(cString: user.pointee.pw_dir)
        let plist = URL(fileURLWithPath: home).appending(path: "Library/LaunchAgents/dev.baglayan.Acouplet.agent.plist")
        backgroundServiceStatus = SMAppService.statusForLegacyPlist(at: plist)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard managesLaunchService else {
            launchAtLogin = enabled
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

    @discardableResult
    func saveEqualizerProfile(named proposedName: String) -> SavedEqualizerProfile {
        let name = equalizerProfileName(for: proposedName)
        if let index = equalizerProfiles.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            equalizerProfiles[index].settings = customEqualizerDraft
            return equalizerProfiles[index]
        }
        let profile = SavedEqualizerProfile(id: UUID(), name: name, settings: customEqualizerDraft)
        equalizerProfiles.append(profile)
        return profile
    }

    func equalizerProfileName(for proposedName: String) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "My EQ \(equalizerProfiles.count + 1)") : String(trimmed.prefix(32))
    }

    func deleteEqualizerProfile(id: UUID) {
        equalizerProfiles.removeAll { $0.id == id }
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Keys {
        static let keepMenuBarIconWhenDisconnected = "preferences.keepMenuBarIconWhenDisconnected"
        static let showBatteryInMenuBar = "preferences.showBatteryInMenuBar"
        static let lowBatteryNotificationsEnabled = "preferences.lowBatteryNotificationsEnabled"
        static let firmwareNotificationsEnabled = "preferences.firmwareNotificationsEnabled"
        static let experimentalLDACEnabled = "preferences.experimentalLDACEnabled"
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        static let ldacConfiguration = "preferences.ldacConfiguration"
        #endif
        static let reconnectAutomatically = "preferences.reconnectAutomatically"
        static let globalShortcutEnabled = "preferences.globalShortcutEnabled"
        static let customEqualizerDraft = "preferences.customEqualizerDraft"
        static let equalizerDraftsByDevice = "preferences.equalizerDraftsByDevice"
        static let equalizerProfiles = "preferences.equalizerProfiles"
    }
}
