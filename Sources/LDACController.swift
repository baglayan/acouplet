#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import Combine
import CoreAudio
import Foundation
import OSLog
@preconcurrency import IOBluetooth

@MainActor
final class LDACController: ObservableObject {
    @Published private(set) var state: LDACState = .off {
        didSet {
            guard oldValue != state else { return }
            if case let .failed(message) = state {
                record("failed", reason: message)
            } else {
                record("state", reason: diagnosticState)
            }
        }
    }
    @Published private(set) var targetAddress: String?
    private(set) var menuBarControlOrigin: (controller: ObjectIdentifier, session: UInt64)?
    private(set) var menuBarControlsAtHandoff: MenuBarHeadphoneControls?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecovering = false
    @Published private(set) var audioCaptureAccess: LDACAudioCaptureAccess = .unchecked
    @Published private(set) var sampleRateChangeError: String?
    @Published private(set) var driverState: LDACDriverInstaller.State {
        didSet {
            if oldValue != driverState { record("driver", reason: String(describing: driverState)) }
        }
    }
    @Published private(set) var driverInstallationError: String? {
        didSet {
            if let driverInstallationError { record("driver-install-failed", reason: driverInstallationError) }
        }
    }
    @Published private(set) var isOpeningDriverInstaller = false
    @Published private(set) var multipointConflictAddress: String?
    @Published private(set) var multipointShutdownAddress: String?
    private var multipointConflictConfiguration: LDACConfiguration?
    private var multipointShutdownTask: Task<Void, Never>?
    private var multipointShutdownRequestID: UUID?
    private var preparationTask: Task<Void, Never>?
    private var isPreparingSourceChange = false
    private var startupSourceReturn: (source: String, session: UInt64, generation: UInt64, request: UUID)?
    private var pendingStartupSourceSelection: (source: String, mac: String, session: UInt64, generation: UInt64,
                                                request: UUID, deadline: ContinuousClock.Instant, outputDeselected: Bool)?
    private var didAttemptAutomaticDriverUpdate = false
    private let bundle: Bundle
    private let defaults: UserDefaults?
    @Published private var pendingConnectionModes: [String: UUID] = [:] {
        didSet { defaults?.set(pendingConnectionModes.mapValues(\.uuidString), forKey: "ldac.pendingConnectionPreferences") }
    }
    private let inspectDriver: (Bundle) -> LDACDriverInstaller.State
    private let isClassicConnected: (String) -> Bool
    private let localBluetoothAddress: () -> String?
    private let restoreSampleRate: (LDACSampleRate) -> Void
    private var session: LDACOwnerSession?
    private var sessionID = UUID()
    private var diagnosticAttempt = 0
    private var diagnosticHistory = DiagnosticHistory()
    private var lastNativeFailure: (attempt: Int, message: String)?
    private var requestedAddress: String?
    private var requestedConfiguration = LDACConfiguration()
    private var nativeOutput: LDACOwnerOutput?
    private var outputID: UUID?
    private var headphones: SonyHeadphonesController?
    private var controlObservation: AnyCancellable?
    private enum PhoneHandoffPhase { case suspending, yieldingOutput, held, selectingOutput, restarting, confirmingVolume }
    private var phoneHandoff: (peer: String, session: UInt64, generation: UInt64, confirmed: Bool, returned: Bool, phase: PhoneHandoffPhase)?
    private var phoneSourceObservation: AnyCancellable?
    private var phoneHandoffTask: Task<Void, Never>?
    private var phoneVolumeWakeup: Task<Void, Never>?
    private var pendingPhoneSelection: SonyMultipointDevice?
    private var phoneSourceRequest: UUID?
    private var phoneSelectionAuthorization: (id: UUID, request: UUID?, output: String, deadline: ContinuousClock.Instant, isCurrent: () -> Bool)?
    private var deselectedSourceObservation: AnyCancellable?
    private var deselectedSourceReturn: (controller: ObjectIdentifier, session: UInt64, generation: UInt64)?
    private var sourceResumeOutputUID: String?
    private var availabilityObservations = Set<AnyCancellable>()
    private let audioRoute: MacAudioRouteObserver?
    private var resumeOutputUID: String?
    private var suspensionRequested = false
    private var deferredConnectionModes: [String: UUID] = [:]
    private var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    private var connectionModeRestoreID: UUID?
    private var connectionModeConfirmed = false
    private var startTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var volumeTaskID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var recoveryPaused = false
    private var recoveryResumeContext: (controller: ObjectIdentifier, observedConnected: Bool, observedDisconnect: Bool)?
    private var restoreAudioOnStop = true
    private var stableSince: Date?
    private var pendingVolume: Int?
    private var lastNativeVolumeScalar: Float32?
    private var nativeVolumeChangeID = UUID()
    private var initialReadbackID: UUID?
    private var controlSession: UInt64?
    private var sourceAddress: String?
    private var volumeRange: ClosedRange<Int>?
    private var transportFormat: LDACFormat?
    private var usable = false
    private var requestedOutputGain = 0.0
    private var volumeError: String?
    private var stopCompletions: [@MainActor () -> Void] = []
    private let helpers: LDACNativeSession.Helpers
    private let devices: SonyDeviceCoordinator?
    private nonisolated static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "LDACLifecycle")

    init(bundle: Bundle = .main, devices: SonyDeviceCoordinator? = nil, audioRoute: MacAudioRouteObserver? = nil, defaults: UserDefaults? = nil,
         inspectDriver: @escaping (Bundle) -> LDACDriverInstaller.State = { LDACDriverInstaller.inspect(bundle: $0) },
         isClassicConnected: @escaping (String) -> Bool = { IOBluetoothDevice(addressString: $0)?.isClassicConnected() == true },
         localBluetoothAddress: @escaping () -> String? = { IOBluetoothHostController.default()?.addressAsString() },
         restoreSampleRate: @escaping (LDACSampleRate) -> Void = { _ in }) {
        self.bundle = bundle
        self.defaults = defaults
        self.inspectDriver = inspectDriver
        self.isClassicConnected = isClassicConnected
        self.localBluetoothAddress = localBluetoothAddress
        self.restoreSampleRate = restoreSampleRate
        driverState = inspectDriver(bundle)
        helpers = LDACNativeSession.Helpers(bundle: bundle)
        self.devices = devices
        self.audioRoute = audioRoute
        if let saved = defaults?.dictionary(forKey: "ldac.pendingConnectionPreferences") as? [String: String] {
            for (address, value) in saved where SonyBLEIdentity.normalizedAddress(address) == address {
                if let request = UUID(uuidString: value) { pendingConnectionModes[address] = request }
            }
        }
        for changes in [devices?.objectWillChange, audioRoute?.objectWillChange].compactMap({ $0 }) {
            changes.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.resumeIfReady() }
            }.store(in: &availabilityObservations)
        }
        devices?.$selectedAddress.removeDuplicates()
            .sink { [weak self] address in
                guard let self else { return }
                if self.isPreparingSourceChange, self.targetAddress != address {
                    self.requestedAddress = nil
                    self.stopSession(reason: "selected device changed during LDAC preparation")
                    return
                }
                guard let pending = self.multipointConflictAddress ?? self.multipointShutdownAddress
                        ?? (self.preparationTask == nil ? nil : self.targetAddress),
                      address != pending else { return }
                self.cancelMultipointRequest()
                self.cancelPreparation()
            }.store(in: &availabilityObservations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.apple.installer" else { return }
                self?.refreshDriverState()
            }.store(in: &availabilityObservations)
    }

    var needsStopBeforeTermination: Bool {
        isSessionRunning || preparationTask != nil || !preferenceRestoreTasks.isEmpty || multipointConflictAddress != nil || multipointShutdownTask != nil
    }

    #if DEBUG
    func simulateConnectionPreferenceRestoration(_ headphones: SonyHeadphonesController, request: UUID) async -> String? {
        await restoreConnectionPreference(headphones, address: headphones.address, request: request)
    }

    func simulateConnectionPreferencePreparation(_ headphones: SonyHeadphonesController) async throws {
        try await prepareConnectionMode(headphones, address: headphones.address, identifier: sessionID)
    }

    func simulatedDeferredConnectionMode(forAddress address: String) -> UUID? {
        deferredConnectionModes[address]
    }

    func simulateRecoverySession(_ headphones: SonyHeadphonesController) {
        self.headphones = headphones
        requestedAddress = headphones.address
        targetAddress = headphones.address
        captureMenuBarControls(for: headphones)
        isSessionRunning = true
        state = .connecting
    }

    func simulateRecoveryTimeout(stableSince: Date? = nil, at date: Date = Date()) -> TimeInterval? {
        self.stableSince = stableSince
        beginRecovery(reason: "simulated control timeout", at: date)
        let delay = nextRecoveryDelay()
        if delay == nil { finish(nil) }
        return delay
    }

    func simulateOutputDeselection() {
        _ = handleOutputDeselection(LDACOwnerError(LDACOutputDeselectedError()))
    }

    var simulatedRequestedAddress: String? { requestedAddress }
    var simulatedRestoresAudioOnStop: Bool { restoreAudioOnStop }

    func simulatedCanResumeRecovery(with headphones: SonyHeadphonesController) -> Bool {
        canResumeRecovery(with: headphones)
    }
    #endif

    var canStartOrInstallDriver: Bool {
        switch driverState {
        case .missing, .outdated, .updateAvailable, .current: !isOpeningDriverInstaller
        case .restartRequired, .unavailable: false
        }
    }

    func refreshDriverState() {
        guard !isSessionRunning else { return }
        let state = inspectDriver(bundle)
        if driverState != state { driverState = state }
    }

    func installDriver() {
        guard !isSessionRunning, !isOpeningDriverInstaller else { return }
        refreshDriverState()
        guard driverState == .missing || driverState.offersUpdate else { return }
        openDriverInstaller()
    }

    func updateInstalledDriverIfNeeded() {
        guard !didAttemptAutomaticDriverUpdate, !isSessionRunning, !isOpeningDriverInstaller else { return }
        refreshDriverState()
        guard driverState.offersUpdate else { return }
        openDriverInstaller()
    }

    private func openDriverInstaller() {
        didAttemptAutomaticDriverUpdate = true
        driverInstallationError = nil
        isOpeningDriverInstaller = true
        Task {
            defer { isOpeningDriverInstaller = false }
            do { try await LDACDriverInstaller.openInstaller(bundle: bundle) }
            catch { driverInstallationError = error.localizedDescription }
        }
    }

    func deviceUnavailableReason(forAddress address: String) -> String? {
        guard let headphones = devices?.controller(for: address), headphones.deviceModel != .unknown else {
            return String(localized: "Connect the headphone controls in Acouplet before starting LDAC.")
        }
        switch headphones.deviceModel {
        case .wfXM3, .whCH720N:
            return String(localized: "This model does not support the LDAC codec.")
        default: break
        }
        guard headphones.isReady else {
            return String(localized: "Connect the headphone controls in Acouplet before starting LDAC.")
        }
        guard headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true else {
            return String(localized: "Stop the locating sound before starting LDAC.")
        }
        guard headphones.playback.isSupported,
              !headphones.playback.hasReceivedCapabilities || headphones.playback.musicVolumeRange != nil else {
            return String(localized: "This app does not yet support LDAC with this device's volume controls.")
        }
        return nil
    }

    func canEnable(forAddress address: String) -> Bool {
        deviceUnavailableReason(forAddress: address) == nil && helpers.isAvailable && !isSessionRunning
            && preferenceRestoreTasks[address] == nil
    }

    var canChangeConfiguration: Bool {
        if case .active = state { return true }
        return !isSessionRunning && state != .stopping
    }

    func updateConfiguration(_ configuration: LDACConfiguration) {
        let previous = requestedConfiguration
        requestedConfiguration = configuration
        guard previous != configuration else { return }
        if previous.sampleRate != configuration.sampleRate { sampleRateChangeError = nil }
        if requestedAddress != nil, state != .stopping { session?.updateConfiguration(configuration) }
    }

    func setEnabled(_ enabled: Bool, forAddress address: String, configuration: LDACConfiguration? = nil,
                    continuingMenuBarHandoff: Bool = false) {
        guard let address = SonyBLEIdentity.normalizedAddress(address) else { return }
        if enabled {
            guard requestedAddress != address || (recoveryPaused && !isSessionRunning) else { return }
            guard preparationTask == nil || targetAddress != address else { return }
            guard multipointShutdownAddress != address else { return }
            guard preferenceRestoreTasks[address] == nil else { return }
            guard deviceUnavailableReason(forAddress: address) == nil else { return }
            cancelMultipointRequest()
            cancelPreparation()
            if let configuration { requestedConfiguration = configuration }
            if !isSessionRunning {
                refreshDriverState()
                guard driverState.canStream else {
                    state = .off
                    targetAddress = nil
                    installDriver()
                    return
                }
            }
            guard helpers.isAvailable else {
                targetAddress = address
                state = .failed(String(localized: "LDAC playback is unavailable in this installation of Acouplet."))
                return
            }
            if !isSessionRunning, let headphones = devices?.controller(for: address) {
                if headphones.ldacPreparationIssue(for: localBluetoothAddress()) != nil {
                    waitForPreparation(headphones, address: address, continuingMenuBarHandoff: continuingMenuBarHandoff)
                    return
                }
                if headphones.ldacRequiresMultipointOff {
                    multipointConflictConfiguration = configuration
                    multipointConflictAddress = address
                    return
                }
            }
            requestedAddress = address
            if !isSessionRunning { start(address, continuingMenuBarHandoff: continuingMenuBarHandoff) }
            else { stopSession(reason: "target changed") }
        } else {
            if multipointConflictAddress == address || multipointShutdownAddress == address { cancelMultipointRequest() }
            if targetAddress == address { cancelPreparation() }
            if targetAddress == address || requestedAddress == address {
                phoneSelectionAuthorization = nil
                requestedAddress = nil
                suspensionRequested = false
                if isSessionRunning { stopSession(reason: "user disabled LDAC") }
                else { state = .off; targetAddress = nil; resumeIfReady() }
            }
        }
    }

    private func waitForPreparation(_ headphones: SonyHeadphonesController, address: String, continuingMenuBarHandoff: Bool) {
        captureMenuBarControls(for: headphones, continuing: continuingMenuBarHandoff)
        requestedAddress = nil
        targetAddress = address
        state = .requested
        preparationTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(15)
            var error = String(localized: "The headphone connection changed. Try LDAC again.")
            preparation: while let self, !Task.isCancelled, self.devices?.controller(for: address) === headphones, headphones.isReady {
                if let reason = self.deviceUnavailableReason(forAddress: address) {
                    error = reason
                    break
                }
                guard let issue = headphones.ldacPreparationIssue(for: self.localBluetoothAddress()) else {
                    self.preparationTask = nil
                    self.targetAddress = nil
                    self.state = .off
                    self.setEnabled(true, forAddress: address, continuingMenuBarHandoff: true)
                    return
                }
                error = issue.message
                if Date() >= deadline {
                    if case .readingSources = issue {
                        error = String(localized: "The device list was not received. Reconnect the headphones to try again.")
                    }
                    break
                }
                switch issue {
                case .readingMultipoint, .readingSources:
                    break
                case let .selectMac(mac?):
                    guard !headphones.ldacRequiresMultipointOff else { break preparation }
                    if headphones.sourceControlUnavailableReason != nil { break }
                    self.preparationTask = nil
                    self.requestedAddress = address
                    self.start(address, selectingSource: mac, continuingMenuBarHandoff: true)
                    return
                case .unknownLocalAddress, .selectMac(nil):
                    break preparation
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            self.preparationTask = nil
            self.state = .failed(error)
        }
    }

    private func cancelPreparation() {
        guard let preparationTask else { return }
        preparationTask.cancel()
        self.preparationTask = nil
        targetAddress = nil
        state = .off
    }

    func resolveMultipointConflict(turnOffMultipoint: Bool) {
        guard let address = multipointConflictAddress else { return }
        let configuration = multipointConflictConfiguration
        multipointConflictAddress = nil
        multipointConflictConfiguration = nil
        guard turnOffMultipoint else { return }
        let failure = String(localized: "Multipoint could not be turned off. LDAC did not start.")
        guard let headphones = devices?.controller(for: address), headphones.ldacRequiresMultipointOff else {
            setEnabled(true, forAddress: address, configuration: configuration)
            return
        }
        if let reason = deviceUnavailableReason(forAddress: address)
            ?? headphones.ldacPreparationIssue(for: localBluetoothAddress())?.message {
            targetAddress = address
            state = .failed(reason)
            return
        }
        headphones.setMultipointEnabled(false)
        guard let transition = headphones.multipointTransition, !transition.isFinished, !transition.targetEnabled else {
            targetAddress = address
            state = .failed(headphones.multipointUnavailableReason ?? failure)
            return
        }
        let requestID = transition.requestID
        captureMenuBarControls(for: headphones)
        multipointShutdownRequestID = requestID
        multipointShutdownAddress = address
        record("multipoint-off-requested", reason: "model=\(headphones.deviceModel.rawValue)")
        multipointShutdownTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(90)
            while !Task.isCancelled, Date() < deadline {
                guard self?.devices?.controller(for: address) === headphones,
                      let current = headphones.multipointTransition, current.requestID == requestID, !current.isFinished else { break }
                self?.confirmPendingMultipointAlert()
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, !Task.isCancelled else { return }
            self.multipointShutdownRequestID = nil
            self.multipointShutdownAddress = nil
            self.multipointShutdownTask = nil
            if self.devices?.controller(for: address) === headphones,
               headphones.multipointTransition?.requestID == requestID, headphones.multipointTransition?.phase == .complete,
               headphones.systemFeatures.multipoint?.enabled == false {
                self.record("multipoint-off-confirmed", reason: "starting LDAC")
                self.setEnabled(true, forAddress: address, configuration: configuration, continuingMenuBarHandoff: true)
            } else {
                self.targetAddress = address
                self.state = .failed(headphones.multipointTransition?.failureMessage ?? failure)
            }
        }
    }

    func handlesMultipointConfirmation(_ transition: SonyMultipointTransition?) -> Bool {
        guard let transition else { return false }
        return transition.requestID == multipointShutdownRequestID
    }

    private func confirmPendingMultipointAlert() {
        guard let address = multipointShutdownAddress, let headphones = devices?.controller(for: address),
              handlesMultipointConfirmation(headphones.multipointTransition),
              let alert = headphones.multipointTransition?.alert else { return }
        headphones.respondToMultipointAlert(alert, action: alert.availableActions.contains(.positive) ? .positive : nil)
    }

    private func cancelMultipointRequest() {
        multipointShutdownTask?.cancel()
        multipointShutdownTask = nil
        confirmPendingMultipointAlert()
        multipointShutdownRequestID = nil
        multipointShutdownAddress = nil
        multipointConflictAddress = nil
        multipointConflictConfiguration = nil
    }

    func stop(restoreAudio: Bool = true, reason: String = "app requested stop", completion: (@MainActor () -> Void)? = nil) {
        phoneSelectionAuthorization = nil
        cancelMultipointRequest()
        cancelPreparation()
        requestedAddress = nil
        deselectedSourceObservation = nil
        deselectedSourceReturn = nil
        sourceResumeOutputUID = nil
        suspensionRequested = false
        if let completion {
            stopCompletions.append(completion)
            objectWillChange.send()
        }
        if !isSessionRunning { state = .off; targetAddress = nil; resumeIfReady(); completeStop() }
        else { stopSession(restoreAudio: restoreAudio, reason: reason) }
    }

    func suspend(restoreAudio: Bool = false, preservingPhoneSelection: Bool = false, reason: String = "Mac is going to sleep") {
        if !preservingPhoneSelection { phoneSelectionAuthorization = nil }
        cancelMultipointRequest()
        cancelPreparation()
        startupSourceReturn = nil
        pendingStartupSourceSelection = nil
        deselectedSourceObservation = nil
        deselectedSourceReturn = nil
        sourceResumeOutputUID = nil
        guard requestedAddress != nil else { return }
        suspensionRequested = true
        if isSessionRunning { stopSession(restoreAudio: restoreAudio, reason: reason) }
        else { state = .waitingForDevice }
    }

    func hasPendingConnectionPreferenceRestoration(forAddress address: String) -> Bool {
        pendingConnectionModes[address] != nil && requestedAddress != address
            && !(isSessionRunning && targetAddress == address)
    }

    func canRestoreConnectionPreference(forAddress address: String) -> Bool {
        guard hasPendingConnectionPreferenceRestoration(forAddress: address), preferenceRestoreTasks[address] == nil,
              devices?.isSystemSleeping != true, let headphones = devices?.controller(for: address),
              headphones.isDeviceConnected, headphones.isReady, headphones.connectionMode == .soundQuality,
              headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true else { return false }
        return headphones.connectionModeUnavailableReason(.stableConnection) == nil
    }

    func restorePendingConnectionPreference(forAddress address: String) {
        reconcileConnectionPreferences()
        guard canRestoreConnectionPreference(forAddress: address), let headphones = devices?.controller(for: address) else { return }
        let previous = headphones.lastConnectionModeChangeID
        headphones.setConnectionMode(.stableConnection)
        guard let request = headphones.lastConnectionModeChangeID, request != previous else { return }
        pendingConnectionModes[address] = request
        deferredConnectionModes[address] = nil
        scheduleConnectionPreferenceRestoration(headphones, address: address, request: request, restorationRequested: true)
    }

    func keepConnectionPreference(forAddress address: String) {
        guard hasPendingConnectionPreferenceRestoration(forAddress: address), preferenceRestoreTasks[address] == nil else { return }
        forgetConnectionPreference(forAddress: address)
    }

    private func forgetConnectionPreference(forAddress address: String) {
        pendingConnectionModes[address] = nil
        deferredConnectionModes[address] = nil
        if targetAddress == address {
            connectionModeRestoreID = nil
            connectionModeConfirmed = false
        }
    }

    private func reconcileConnectionPreferences() {
        for (address, request) in pendingConnectionModes {
            guard let headphones = devices?.controller(for: address) else { continue }
            if let latest = headphones.lastConnectionModeChangeID, latest != request {
                forgetConnectionPreference(forAddress: address)
            } else if headphones.isDeviceConnected, headphones.isReady,
                      headphones.connectionTransition?.isFinished != false,
                      let mode = headphones.connectionMode, mode == .stableConnection || mode == .lowLatency {
                forgetConnectionPreference(forAddress: address)
            }
        }
    }

    private func scheduleConnectionPreferenceRestoration(_ headphones: SonyHeadphonesController, address: String,
                                                        request: UUID, restorationRequested: Bool = false) {
        preferenceRestoreTasks[address] = Task { [weak self] in
            guard let self else { return }
            let error = await self.restoreConnectionPreference(headphones, address: address, request: request,
                                                              restorationRequested: restorationRequested)
            self.objectWillChange.send()
            self.preferenceRestoreTasks[address] = nil
            if let error { self.record("preference-restore-failed", reason: error) }
            self.completeStop()
        }
    }

    private func resumeIfReady() {
        guard devices?.isSystemSleeping != true else { return }
        if sourceResumeOutputUID == nil, deselectedSourceReturn != nil, let resumeOutputUID,
           audioRoute?.isDefaultOutput(resumeOutputUID, transport: kAudioDeviceTransportTypeBluetooth) != true {
            deselectedSourceReturn = nil
        }
        reconcileConnectionPreferences()
        for (address, request) in deferredConnectionModes where address != requestedAddress && preferenceRestoreTasks[address] == nil {
            guard let headphones = devices?.controller(for: address), headphones.isDeviceConnected, headphones.isReady,
                  headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress()),
                  headphones.earbudFinder?.isBusy != true, headphones.earbudFinder?.mayBeRinging != true else { continue }
            deferredConnectionModes[address] = nil
            scheduleConnectionPreferenceRestoration(headphones, address: address, request: request)
        }
        guard state == .waitingForDevice, !isSessionRunning, cleanupTask == nil,
              let address = requestedAddress, preferenceRestoreTasks[address] == nil,
              let headphones = devices?.controller(for: address) else { return }
        let canResume = canResumeRecovery(with: headphones)
        if let returned = deselectedSourceReturn,
           devices?.selectedAddress != address || returned.controller != ObjectIdentifier(headphones)
            || headphones.notificationSession != returned.session || headphones.playbackSourceGeneration != returned.generation
            || !headphones.hasCurrentTable2Capabilities || !headphones.multipoint.supportsInventory || headphones.multipoint.inventoryIsStale {
            deselectedSourceReturn = nil
        }
        guard canResume || deselectedSourceReturn != nil,
              devices?.selectedAddress == address, headphones.isDeviceConnected,
              headphones.sourceTransition?.isFinished != false,
              deviceUnavailableReason(forAddress: address) == nil, !headphones.ldacRequiresMultipointOff,
              headphones.ldacPreparationIssue(for: localBluetoothAddress()) == nil,
              let resumeOutputUID, audioRoute?.route?.uid == resumeOutputUID,
              isClassicConnected(address),
              headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress()) else { return }
        refreshDriverState()
        guard driverState.canStream, helpers.isAvailable else { return }
        start(address, resumingSourceOn: canResume ? nil : resumeOutputUID)
    }

    private func captureMenuBarControls(for headphones: SonyHeadphonesController?, continuing: Bool = false) {
        if continuing, let headphones, menuBarControlOrigin?.controller == ObjectIdentifier(headphones) { return }
        menuBarControlOrigin = headphones.map { (ObjectIdentifier($0), $0.notificationSession) }
        menuBarControlsAtHandoff = headphones.flatMap { $0.isReady ? MenuBarHeadphoneControls($0) : nil }
    }

    private func captureMenuBarControlsFromActiveSession() {
        guard case .active = state, let headphones else { return }
        menuBarControlsAtHandoff = headphones.isReady ? MenuBarHeadphoneControls(headphones) : headphones.lastReadyMenuBarControls
    }

    private func start(_ address: String, selectingSource mac: SonyMultipointDevice? = nil, continuingMenuBarHandoff: Bool = false,
                       resumingSourceOn expectedDefaultOutputUID: String? = nil) {
        let controller = devices?.controller(for: address)
        let origin = controller.map { (session: $0.notificationSession, source: $0.multipoint.selectedSource?.address,
                                       generation: $0.playbackSourceGeneration, request: $0.sourceTransition?.requestID) }
        captureMenuBarControls(for: controller, continuing: continuingMenuBarHandoff)
        diagnosticAttempt += 1
        sessionID = UUID()
        state = .requested
        targetAddress = address
        volumeError = nil
        sampleRateChangeError = nil
        connectionModeRestoreID = deferredConnectionModes.removeValue(forKey: address)
        connectionModeConfirmed = connectionModeRestoreID != nil
        suspensionRequested = false
        resumeOutputUID = audioRoute?.route?.uid
        isRecovering = false
        recoveryAttempt = 0
        recoveryPaused = false
        recoveryResumeContext = nil
        deselectedSourceObservation = nil
        sourceResumeOutputUID = expectedDefaultOutputUID
        if expectedDefaultOutputUID == nil { deselectedSourceReturn = nil }
        restoreAudioOnStop = true
        isPreparingSourceChange = mac != nil
        isSessionRunning = true
        record("requested", reason: "enabled")
        let identifier = sessionID
        outputID = identifier
        let output = LDACOwnerOutput(id: sessionID, address: address) { [weak self] result in
            guard let self, self.outputID == identifier else { return }
            if self.state == .stopping {
                if case .failure = result { self.phoneSelectionAuthorization = nil }
                return
            }
            switch result {
            case let .success(controls):
                self.record("native-controls", reason: "scalar=\(controls.scalar) userMuted=\(controls.muted)")
                if controls.scalar != self.lastNativeVolumeScalar { self.nativeVolumeChangeID = UUID() }
                self.lastNativeVolumeScalar = controls.scalar
                if controls.muted { self.setOutputGain(0) }
                if let range = self.volumeRange {
                    self.pendingVolume = controls.volume(in: range)
                    self.sendPendingVolume()
                }
                if self.usable { self.setOutputGain(controls.muted ? 0 : 1) }
            case let .failure(error):
                if self.handleOutputDeselection(error) { return }
                self.recordOutputFailure(error)
                if error is LDACPriorityCleanupError, let session = self.session,
                   self.requestedAddress == self.targetAddress {
                    self.beginRecovery(reason: error.localizedDescription)
                    session.verifyConnectionLoss(reason: error.localizedDescription)
                } else { self.fail(error.localizedDescription) }
            }
        }
        nativeOutput = output
        startTask = Task { [weak self] in
            guard let self, self.sessionID == identifier else { return }
            defer {
                if self.sessionID == identifier { self.isPreparingSourceChange = false }
            }
            do {
                guard let devices = self.devices, let headphones = devices.controller(for: address), headphones.deviceModel != .unknown else {
                    throw ControlError(String(localized: "Connect the headphone controls in Acouplet before starting LDAC."))
                }
                if let reason = self.deviceUnavailableReason(forAddress: address) { throw ControlError(reason) }
                self.headphones = headphones
                if let request = self.connectionModeRestoreID, headphones.lastConnectionModeChangeID != request {
                    self.connectionModeRestoreID = nil
                    self.connectionModeConfirmed = false
                }
                var checkedCaptureRate: LDACSampleRate?
                if let mac {
                    guard let origin, headphones === controller, devices.selectedAddress == address else { throw CancellationError() }
                    let rate = self.requestedConfiguration.sampleRate
                    try await output.claim(model: headphones.deviceModel.name, targetAddress: address,
                        sampleRate: rate, requiresIdlePriority: true)
                    self.audioCaptureAccess = .checking
                    self.record("checking-audio-permission", reason: "before selecting this Mac as the Sony audio source")
                    try await output.checkCapturePermission(at: rate)
                    self.audioCaptureAccess = .ready
                    checkedCaptureRate = rate
                    guard self.requestedConfiguration.sampleRate == rate else {
                        throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                    }
                    try await self.selectMacAudioSource(mac, for: headphones, address: address, identifier: identifier,
                                                        origin: origin, output: output)
                }
                try self.validateSourceResume(headphones)
                try await self.prepareConnectionMode(headphones, address: address, identifier: identifier)
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.requestedAddress == address, self.state != .stopping else {
                    throw CancellationError()
                }
                guard devices.controller(for: address) === headphones else {
                    throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
                }
                if let reason = self.deviceUnavailableReason(forAddress: address)
                    ?? headphones.ldacPreparationIssue(for: self.localBluetoothAddress())?.message { throw ControlError(reason) }
                if headphones.ldacRequiresMultipointOff { throw ControlError(String(localized: "Turn off multipoint before starting LDAC.")) }
                if mac == nil {
                    try self.validateSourceResume(headphones)
                    try await output.claim(model: headphones.deviceModel.name, targetAddress: address, sampleRate: self.requestedConfiguration.sampleRate,
                        expectedDefaultOutputUID: expectedDefaultOutputUID)
                    try await output.priorityControl()
                }
                try Task.checkCancellation()
                let previousReadback = headphones.musicVolumeReadbackID
                if IOBluetoothDevice(addressString: address)?.isClassicConnected() == true { headphones.refreshMusicVolume() }
                self.record("initial-volume-wait", reason: self.musicControlStatus)
                let deadline = Date().addingTimeInterval(15)
                var recoveredVolumeControls = false
                while !self.hasReadableMusicVolumeForHandoff || !headphones.hasFreshReadableMusicVolumeReadback || headphones.musicVolumeReadbackID == previousReadback {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw ControlError(String(localized: "The headphone volume could not be read. Connect the headphone controls in Acouplet and select this Mac as their audio source, then try LDAC again.")) }
                    if !recoveredVolumeControls, headphones.recoverMusicVolumeIfNeeded() {
                        recoveredVolumeControls = true
                        self.record("initial-volume-control-recovery", reason: self.musicControlStatus)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume else {
                    throw ControlError("The headphones did not report their music volume range.", userFacing: String(localized: "The headphone volume could not be read. Connect the headphone controls in Acouplet and select this Mac as their audio source, then try LDAC again."))
                }
                self.volumeRange = range
                self.record("initial-volume-admitted", reason: self.musicControlStatus)
                self.initialReadbackID = headphones.musicVolumeReadbackID
                try await output.configure(volume: volume, range: range, preservingUserChange: true)
                self.lastNativeVolumeScalar = output.controls.scalar
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.state != .stopping else { throw CancellationError() }
                guard self.hasReadableMusicVolumeForHandoff, headphones.hasFreshReadableMusicVolumeReadback,
                      headphones.musicVolumeReadbackID == self.initialReadbackID,
                      headphones.playback.musicVolumeRange == range, headphones.playback.volume == volume else {
                    throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                }
                if let checkedCaptureRate, self.requestedConfiguration.sampleRate != checkedCaptureRate {
                    throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                }
                self.pendingVolume = output.controls.volume(in: range)
                try self.validateSourceResume(headphones)
                self.observeControls(headphones, devices: devices)
                self.startTask = nil
                self.launch(address, capturePermissionWasChecked: checkedCaptureRate != nil)
            } catch is CancellationError {
                guard self.sessionID == identifier else { return }
                self.record("start-cancelled", reason: self.musicControlStatus)
                self.startTask = nil
                self.finish(nil)
            } catch {
                guard self.sessionID == identifier else { return }
                self.startTask = nil
                if self.handleOutputDeselection(error) { return }
                if let access = (error as? LDACOwnerError)?.captureAccess { self.audioCaptureAccess = access }
                self.recordOutputFailure(error)
                self.record("start-failed", reason: "\(error.localizedDescription); \(self.musicControlStatus)")
                if self.devices?.isSystemSleeping == true || self.headphones?.isDeviceConnected == false {
                    self.suspensionRequested = self.requestedAddress == address
                    self.finish(nil, targetDisconnected: true)
                } else {
                    self.requestedAddress = nil
                    self.finish(error.localizedDescription)
                }
            }
        }
    }

    private func validateSourceResume(_ headphones: SonyHeadphonesController?, outputSelected: Bool = false) throws {
        guard let expectedDefaultOutputUID = sourceResumeOutputUID else { return }
        let routeIsCurrent = outputSelected ? audioRoute?.isDefaultOutput(LDACNativeOutput.uid)
            : audioRoute?.isDefaultOutput(expectedDefaultOutputUID, transport: kAudioDeviceTransportTypeBluetooth)
        guard routeIsCurrent == true else {
            throw LDACOwnerError(LDACOutputDeselectedError())
        }
        guard let headphones, let returned = deselectedSourceReturn, ObjectIdentifier(headphones) == returned.controller,
              devices?.controller(for: headphones.address) === headphones, devices?.selectedAddress == headphones.address,
              headphones.notificationSession == returned.session, headphones.playbackSourceGeneration == returned.generation,
              headphones.hasCurrentTable2Capabilities,
              headphones.multipoint.supportsInventory, !headphones.multipoint.inventoryIsStale,
              headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress()) else {
            throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
        }
    }

    private func selectMacAudioSource(_ mac: SonyMultipointDevice, for headphones: SonyHeadphonesController,
                                      address: String, identifier: UUID,
                                      origin: (session: UInt64, source: String?, generation: UInt64, request: UUID?),
                                      output: LDACOwnerOutput) async throws {
        let changed = String(localized: "The headphone connection changed. Try LDAC again.")
        let localAddress = localBluetoothAddress()
        try Task.checkCancellation()
        guard sessionID == identifier, requestedAddress == address, state != .stopping,
              devices?.selectedAddress == address else { throw CancellationError() }
        guard devices?.controller(for: address) === headphones, headphones.notificationSession == origin.session,
              headphones.playbackSourceGeneration == origin.generation,
              let source = origin.source, headphones.multipoint.selectedSource?.address == source,
              headphones.sourceTransition?.requestID == origin.request, !headphones.ldacRequiresMultipointOff,
              audioRoute?.route?.uid == resumeOutputUID,
              case let .selectMac(currentMac?) = headphones.ldacPreparationIssue(for: localAddress),
              currentMac.address == mac.address, headphones.sourceControlUnavailableReason == nil else { throw ControlError(changed) }
        let rate = requestedConfiguration.sampleRate
        try await output.selectForHandoff()
        try await output.priorityControl()
        try await output.validateForRecovery()
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        let isCurrent = { [weak self, weak headphones] in
            guard let self, let headphones, self.sessionID == identifier, self.requestedAddress == address,
                  self.state != .stopping, self.devices?.selectedAddress == address,
                  self.devices?.isSystemSleeping == false, headphones.isReady, headphones.isDeviceConnected,
                  self.devices?.controller(for: address) === headphones, headphones.notificationSession == origin.session,
                  headphones.playbackSourceGeneration == origin.generation,
                  self.requestedConfiguration.sampleRate == rate, ContinuousClock.now < deadline,
                  self.audioRoute?.isDefaultOutput(LDACNativeOutput.uid) == true else { return false }
            return headphones.multipoint.keeping == false && headphones.multipoint.selectedSource?.address == source
                && headphones.multipoint.selectedSource?.isConnected == true
                && headphones.multipoint.sourceSwitchPayload(address: currentMac.address) != nil
        }
        guard headphones.sourceTransition?.requestID == origin.request,
              headphones.sourceControlUnavailableReason == nil, isCurrent() else { throw ControlError(changed) }
        headphones.selectAudioSource(currentMac, isCurrent: isCurrent)
        guard let request = headphones.sourceTransition?.requestID, request != origin.request else { throw ControlError(changed) }
        pendingStartupSourceSelection = (source, currentMac.address, origin.session, origin.generation, request, deadline, false)
        while true {
            try Task.checkCancellation()
            guard sessionID == identifier, requestedAddress == address, state != .stopping,
                  devices?.selectedAddress == address else { throw CancellationError() }
            guard devices?.controller(for: address) === headphones, headphones.isReady,
                  let transition = headphones.sourceTransition, transition.requestID == request else { throw ControlError(changed) }
            if transition.phase == .failed { throw ControlError(transition.failureMessage ?? changed) }
            if transition.phase == .complete {
                guard headphones.hasCurrentMusicSourceContext(for: localAddress) else { throw ControlError(changed) }
                let generation = headphones.playbackSourceGeneration
                if headphones.notificationSession == origin.session, generation == origin.generation + 1 {
                    startupSourceReturn = (source, origin.session, generation, request)
                }
                pendingStartupSourceSelection = nil
                return
            }
            guard ContinuousClock.now < deadline else {
                throw ControlError(String(localized: "The headphones did not confirm the audio source change in time."))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func returnStartupSource() async -> String? {
        defer {
            startupSourceReturn = nil
            pendingStartupSourceSelection = nil
        }
        guard let headphones else { return nil }
        if let pending = pendingStartupSourceSelection, pending.outputDeselected {
            while pendingStartupSourceSelection?.request == pending.request, state == .stopping,
                  devices?.isSystemSleeping == false, devices?.selectedAddress == headphones.address,
                  devices?.controller(for: headphones.address) === headphones,
                  headphones.isReady, headphones.isDeviceConnected, headphones.notificationSession == pending.session,
                  let transition = headphones.sourceTransition, transition.requestID == pending.request,
                  ContinuousClock.now < pending.deadline {
                let generation = headphones.playbackSourceGeneration
                let selected = headphones.multipoint.selectedSource?.address
                let selectedMac = generation == pending.generation + 1 && selected == pending.mac
                if transition.phase == .complete {
                    if selectedMac { startupSourceReturn = (pending.source, pending.session, generation, pending.request) }
                    break
                }
                guard !transition.isFinished, selectedMac || (generation == pending.generation && selected == pending.source) else { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
            }
        }
        guard let origin = startupSourceReturn,
              headphones.sourceTransition?.requestID == origin.request, headphones.sourceTransition?.phase == .complete,
              let source = headphones.multipoint.devices.first(where: { $0.address == origin.source && $0.isConnected }),
              headphones.sourceControlUnavailableReason == nil else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        let isCurrent = { [weak self, weak headphones] in
            guard let self, let headphones else { return false }
            return self.startupSourceReturn?.request == origin.request && self.state == .stopping
                && self.devices?.isSystemSleeping == false && ContinuousClock.now < deadline
                && self.devices?.selectedAddress == headphones.address && self.devices?.controller(for: headphones.address) === headphones
                && headphones.notificationSession == origin.session && headphones.playbackSourceGeneration == origin.generation
                && headphones.isReady && headphones.isDeviceConnected && !headphones.multipoint.inventoryIsStale
                && headphones.multipoint.selectedSource?.isConnected == true
                && headphones.multipoint.devices.contains(where: { $0.address == origin.source && $0.isConnected })
                && headphones.multipoint.keeping == false && headphones.hasCurrentMusicSourceContext(for: self.localBluetoothAddress())
        }
        guard isCurrent() else { return nil }
        headphones.selectAudioSource(source, isCurrent: isCurrent)
        guard let request = headphones.sourceTransition?.requestID, request != origin.request else { return nil }
        while let change = headphones.sourceTransition, change.requestID == request,
              headphones.notificationSession == origin.session {
            if change.phase == .complete {
                if headphones.multipoint.selectedSource?.address == source.address {
                    record("source-restored", reason: "previous multipoint source confirmed")
                }
                return nil
            }
            if change.phase == .failed { return change.failureMessage }
            guard ContinuousClock.now < deadline else {
                return String(localized: "The headphones did not confirm the audio source change in time.")
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        return nil
    }

    private func prepareConnectionMode(_ headphones: SonyHeadphonesController, address: String, identifier: UUID,
                                       timeout: TimeInterval = 15) async throws {
        try Task.checkCancellation()
        guard headphones.connectionTransition?.isFinished != false else {
            throw ControlError(String(localized: "Finish the current connection change before starting LDAC."))
        }
        guard headphones.supportsConnectionMode else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            guard sessionID == identifier, requestedAddress == address, state != .stopping else { throw CancellationError() }
            guard devices?.controller(for: address) === headphones else {
                throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
            }
            guard headphones.connectionTransition?.isFinished != false else {
                throw ControlError(String(localized: "Finish the current connection change before starting LDAC."))
            }
            if let reason = headphones.ldacPreparationIssue(for: localBluetoothAddress())?.message {
                throw ControlError(reason)
            }
            if headphones.ldacRequiresMultipointOff { throw ControlError(String(localized: "Turn off multipoint before starting LDAC.")) }
            if headphones.connectionMode == .soundQuality { return }
            guard let reason = headphones.connectionModeUnavailableReason(.soundQuality) else { break }
            guard Date() < deadline else { throw ControlError(reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let original = headphones.connectionMode
        let previous = headphones.lastConnectionModeChangeID
        headphones.setConnectionMode(.soundQuality)
        guard let request = headphones.lastConnectionModeChangeID, request != previous else {
            throw ControlError(headphones.connectionModeError ?? String(localized: "Sound Quality could not be selected for LDAC."))
        }
        if original == .stableConnection {
            connectionModeRestoreID = request
            pendingConnectionModes[address] = request
        }
        guard try await waitForConnectionChange(headphones, address: address, request: request),
              headphones.connectionMode == .soundQuality else {
            throw ControlError(String(localized: "Sound Quality was not confirmed. LDAC did not start."))
        }
        try Task.checkCancellation()
        guard sessionID == identifier, requestedAddress == address, state != .stopping else { throw CancellationError() }
        connectionModeConfirmed = true
    }

    private func waitForConnectionChange(_ headphones: SonyHeadphonesController, address: String, request: UUID,
                                         restoring: Bool = false, timeout: Duration = .seconds(30)) async throws -> Bool {
        try Task.checkCancellation()
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = headphones.objectWillChange.sink { changes.continuation.yield(()) }
        let deviceObservation = devices?.objectWillChange.sink { changes.continuation.yield(()) }
        let stopObservation = objectWillChange.sink { changes.continuation.yield(()) }
        var deadline: Task<Void, Never>?
        var expired = false
        var refreshed = false
        var retried = false
        defer {
            observation.cancel()
            deviceObservation?.cancel()
            stopObservation.cancel()
            deadline?.cancel()
            changes.continuation.finish()
        }
        changes.continuation.yield(())
        for await _ in changes.stream {
            await Task.yield()
            try Task.checkCancellation()
            guard devices?.controller(for: address) === headphones,
                  SonyBLEIdentity.normalizedAddress(headphones.address) == address else {
                throw ControlError(String(localized: "The headphone connection changed. Try LDAC again."))
            }
            guard headphones.lastConnectionModeChangeID == request else { return false }
            if restoring, headphones.earbudFinder?.isBusy == true || headphones.earbudFinder?.mayBeRinging == true {
                deferredConnectionModes[address] = request
                pendingConnectionModes[address] = request
                return false
            }
            let sleeping = devices?.isSystemSleeping == true
            if stopCompletions.isEmpty && (sleeping || headphones.connectionTransition?.awaitingUser == true) {
                deadline?.cancel()
                deadline = nil
                expired = false
            } else if deadline == nil {
                deadline = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    expired = true
                    changes.continuation.yield(())
                }
            }
            if expired { throw ControlError(String(localized: "The headphones did not confirm the connection preference.")) }
            if sleeping { continue }
            if restoring, !headphones.isReady, headphones.connectionTransition?.isFinished != false, !refreshed {
                refreshed = true
                headphones.refresh()
            }
            if let transition = headphones.connectionTransition {
                switch transition.phase {
                case .failed:
                    if restoring, !retried, headphones.retryConnectionModeChange(expectedRequestID: request) {
                        retried = true
                        continue
                    }
                    throw ControlError(headphones.connectionModeError ?? String(localized: "The headphones did not confirm the connection preference."))
                case .pairingRequired:
                    throw ControlError(String(localized: "Check the headphone connection in Bluetooth settings before changing its preference."))
                case .cancelled:
                    if !restoring { throw ControlError(String(localized: "The connection preference change was cancelled.")) }
                default:
                    if !transition.isFinished { continue }
                }
            }
            if headphones.isReady, headphones.connectionMode != nil { return true }
        }
        try Task.checkCancellation()
        throw ControlError(String(localized: "The headphones did not confirm the connection preference."))
    }

    private func restoreConnectionMode() async -> String? {
        guard let request = connectionModeRestoreID, let headphones, let address = targetAddress else { return nil }
        defer {
            connectionModeRestoreID = nil
            connectionModeConfirmed = false
        }
        return await restoreConnectionPreference(headphones, address: address, request: request)
    }

    private func restoreConnectionPreference(_ headphones: SonyHeadphonesController, address: String, request: UUID,
                                             restorationRequested: Bool = false) async -> String? {
        var ownedRequest = request
        defer {
            if headphones.lastConnectionModeChangeID.map({ $0 != ownedRequest }) == true
                || (headphones.connectionTransition?.phase == .cancelled && (restorationRequested || ownedRequest != request)) {
                forgetConnectionPreference(forAddress: address)
            }
        }
        do {
            guard try await waitForConnectionChange(headphones, address: address, request: request, restoring: true) else { return nil }
            if headphones.connectionMode == .stableConnection {
                forgetConnectionPreference(forAddress: address)
                return nil
            }
            guard !restorationRequested else {
                throw ControlError(String(localized: "Stable Connection was not confirmed."))
            }
            guard headphones.connectionMode == .soundQuality else {
                throw ControlError(String(localized: "The headphone connection preference could not be verified."))
            }
            headphones.setConnectionMode(.stableConnection)
            guard let restoration = headphones.lastConnectionModeChangeID, restoration != request else {
                throw ControlError(headphones.connectionModeError ?? String(localized: "Stable Connection could not be selected."))
            }
            ownedRequest = restoration
            pendingConnectionModes[address] = restoration
            guard try await waitForConnectionChange(headphones, address: address, request: restoration, restoring: true) else { return nil }
            guard headphones.connectionMode == .stableConnection else {
                throw ControlError(String(localized: "Stable Connection was not confirmed."))
            }
            forgetConnectionPreference(forAddress: address)
            return nil
        } catch {
            if devices?.isSystemSleeping == true || !headphones.isDeviceConnected,
               headphones.lastConnectionModeChangeID == ownedRequest {
                deferredConnectionModes[address] = ownedRequest
                pendingConnectionModes[address] = ownedRequest
                return nil
            }
            return String(localized: "Stable Connection could not be restored. \(error.localizedDescription)")
        }
    }

    private func launch(_ address: String, restoringOnly: Bool = false, capturePermissionWasChecked: Bool = false) {
        if !restoringOnly && !capturePermissionWasChecked { audioCaptureAccess = .checking }
        let identifier = sessionID
        record("helpers-started", reason: restoringOnly ? "restoring ordinary Bluetooth audio"
            : capturePermissionWasChecked ? "targeted audio permission verified" : "checking targeted audio permission")
        let output = nativeOutput!
        var ownedMediaReadyForControls = false
        let session = LDACOwnerSession(id: identifier, output: output, configuration: requestedConfiguration,
                                       recoveryAttempt: isRecovering, restoringOnly: restoringOnly) { [weak self] event in
            guard let self, self.session?.id == identifier else { return }
            switch event {
            case let .diagnostic(diagnostic):
                self.recordNativeDiagnostic(diagnostic)
            case .handoffReady:
                self.record("handoff-ready", reason: self.musicControlStatus)
                guard self.state != .stopping else { return }
                let deadline = DispatchTime.now() + 10
                self.readinessTask = Task {
                    do {
                        if !self.isRecovering {
                            guard self.hasReadableMusicVolumeForHandoff, let headphones = self.headphones,
                                  let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume else {
                                throw ControlError("Headphone music controls changed before Bluetooth handoff. Retry LDAC.", userFacing: String(localized: "The headphone audio settings changed. Try LDAC again."))
                            }
                            let controlSession = headphones.notificationSession
                            let sourceAddress = headphones.multipoint.selectedSource?.address
                            if !headphones.hasFreshReadableMusicVolumeReadback { self.record("handoff-volume-wait", reason: self.musicControlStatus) }
                            while true {
                                try Task.checkCancellation()
                                guard self.sessionID == identifier, self.state != .stopping else { throw CancellationError() }
                                guard DispatchTime.now() < deadline, self.hasReadableMusicVolumeForHandoff,
                                      headphones.notificationSession == controlSession, headphones.multipoint.selectedSource?.address == sourceAddress,
                                      headphones.playback.musicVolumeRange == range, headphones.playback.volume == volume else {
                                    throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                                }
                                if headphones.hasFreshReadableMusicVolumeReadback { break }
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            let readback = headphones.musicVolumeReadbackID
                            try await self.nativeOutput?.configure(volume: volume, range: range, preservingUserChange: true)
                            self.lastNativeVolumeScalar = self.nativeOutput?.controls.scalar
                            try Task.checkCancellation()
                            guard DispatchTime.now() < deadline, self.hasReadableMusicVolumeForHandoff, headphones.hasFreshReadableMusicVolumeReadback,
                                  headphones.notificationSession == controlSession, headphones.musicVolumeReadbackID == readback,
                                  headphones.multipoint.selectedSource?.address == sourceAddress,
                                  headphones.playback.musicVolumeRange == range, headphones.playback.volume == volume else {
                                throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                            }
                            self.initialReadbackID = readback
                            if let output = self.nativeOutput { self.pendingVolume = output.controls.volume(in: range) }
                        } else {
                            try await self.nativeOutput?.validateForRecovery()
                        }
                        try self.validateSourceResume(self.headphones)
                        try await self.nativeOutput?.selectForHandoff()
                        try Task.checkCancellation()
                        guard self.sessionID == identifier, self.state != .stopping else { return }
                        try self.validateSourceResume(self.headphones, outputSelected: true)
                        guard DispatchTime.now() < deadline,
                              self.isRecovering ? self.hasMusicVolumeForHandoff : (self.hasReadableMusicVolumeForHandoff
                                  && self.headphones?.hasFreshReadableMusicVolumeReadback == true
                                  && self.headphones?.musicVolumeReadbackID == self.initialReadbackID) else {
                            throw ControlError(String(localized: "The headphone audio settings changed. Try LDAC again."))
                        }
                        self.sourceResumeOutputUID = nil
                        self.deselectedSourceReturn = nil
                        self.readinessTask = nil
                        self.record("handoff-allowed", reason: "silent native output selected")
                        self.session?.allowHandoff()
                        self.state = .connecting
                    } catch is CancellationError {
                    } catch {
                        guard self.sessionID == identifier else { return }
                        if self.handleOutputDeselection(error) { return }
                        self.recordOutputFailure(error)
                        if self.devices?.isSystemSleeping == true || self.headphones?.isDeviceConnected == false {
                            self.suspend(restoreAudio: false, reason: "headphones disconnected during handoff")
                        } else { self.fail(error.localizedDescription) }
                    }
                }
            case .connecting:
                self.record("connecting", reason: "owned raw transport setup")
                if self.state != .stopping { self.state = .connecting }
            case .ownedMediaReady:
                guard !restoringOnly, !self.isRecovering, !ownedMediaReadyForControls, self.sessionID == identifier,
                      self.state == .connecting, self.transportFormat == nil, self.targetAddress == address,
                      self.requestedAddress == address, self.devices?.selectedAddress == address,
                      self.devices?.isSystemSleeping != true, self.phoneHandoff == nil,
                      let headphones = self.headphones, self.devices?.controller(for: address) === headphones,
                      SonyBLEIdentity.normalizedAddress(headphones.address) == address,
                      !headphones.isReady, !self.hasOtherMusicSource, self.isClassicConnected(address),
                      self.audioRoute?.isDefaultOutput(LDACNativeOutput.uid) == true else { return }
                ownedMediaReadyForControls = true
                _ = headphones.retryControlsIfNeeded(forColdLDAC: true)
            case let .active(format):
                if self.state != .stopping {
                    self.transportFormat = format
                    self.record("raw-ready", reason: self.musicControlStatus)
                    self.waitForControls(address, preservingPendingControlOpen: ownedMediaReadyForControls)
                }
            case .warmHeld:
                self.handlePhoneHeld()
            case let .warmCaptureReady(authorization):
                guard self.phoneHandoff?.phase == .restarting else { return }
                guard self.verifyPhoneOutput(LDACNativeOutput.uid) else { return }
                guard self.phoneHandoffIsCurrent, self.hasReadableMusicVolumeForHandoff else {
                    if self.phoneHandoff != nil { self.suspend(reason: "source or output changed before LDAC restart") }
                    return
                }
                self.session?.allowParkedStart(authorization)
            case let .warmResumed(format):
                guard self.phoneHandoff?.phase == .restarting else { return }
                guard self.verifyPhoneOutput(LDACNativeOutput.uid) else { return }
                guard self.phoneHandoffIsCurrent else {
                    if self.phoneHandoff != nil { self.suspend(reason: "source or output changed during LDAC restart") }
                    return
                }
                self.phoneHandoff?.phase = .confirmingVolume
                self.transportFormat = format
                self.readinessTask?.cancel()
                self.waitForControls(address, rebinding: true)
            case let .formatChanged(format):
                if self.state != .stopping {
                    self.transportFormat = format
                    if case .active = self.state { self.state = .active(format) }
                }
            case let .sampleRateChangeRejected(requested, active):
                guard self.state != .stopping, self.requestedConfiguration.sampleRate == requested else { return }
                self.requestedConfiguration.sampleRate = active
                self.restoreSampleRate(active)
                self.sampleRateChangeError = String(localized: "The headphones declined \(requested.displayName). LDAC is using \(active.displayName).")
            case let .sampleRateChangeDeferred(requested, active):
                guard self.state != .stopping, self.requestedConfiguration == requested else { return }
                self.requestedConfiguration.sampleRate = active
                self.restoreSampleRate(active)
                self.sampleRateChangeError = String(localized: "Too much audio is buffered to change the sample rate. LDAC is using \(active.displayName).")
            case let .gainApplied(gain):
                self.record("gain-applied", reason: "gain=\(gain)")
            case let .audioCaptureAccess(access):
                self.audioCaptureAccess = access
                self.record("capture-access", reason: String(describing: access))
            case let .failed(message):
                if self.phoneHandoff != nil {
                    self.sendPendingPhoneSelection()
                    self.suspend(preservingPhoneSelection: true, reason: message)
                } else { self.fail(message) }
            case let .connectionLost(message):
                if self.phoneHandoff != nil {
                    self.sendPendingPhoneSelection()
                    self.suspend(preservingPhoneSelection: true, reason: message)
                }
                else if self.requestedAddress == address, self.state != .stopping { self.beginRecovery(reason: message) }
                else { self.session?.stop(restoreAudio: self.restoreAudioOnStop) }
            case let .finished(completion):
                self.session = nil
                if self.phoneHandoff != nil {
                    self.sendPendingPhoneSelection()
                    self.suspensionRequested = true
                    self.restoreAudioOnStop = false
                    self.finish(completion.requiresAttention ? completion.message : nil, targetDisconnected: completion.targetDisconnected)
                    return
                }
                if completion.waitForReconnect, completion.canRetry, self.requestedAddress == address {
                    self.suspensionRequested = true
                    self.finish(nil, targetDisconnected: true)
                } else if completion.canRetry, self.requestedAddress == address, self.state != .stopping {
                    if !self.isRecovering { self.beginRecovery(reason: completion.message ?? "Bluetooth connection lost") }
                    self.scheduleRecovery(address, targetDisconnected: completion.targetDisconnected)
                } else if completion.canRetry, !completion.waitForReconnect, self.restoreAudioOnStop {
                    self.sessionID = UUID()
                    self.launch(address, restoringOnly: true)
                } else {
                    self.finish(completion.requiresAttention ? completion.message : nil, targetDisconnected: completion.targetDisconnected)
                }
            }
        }
        self.session = session
        session.start()
    }

    private var hasMusicControlTarget: Bool {
        guard let headphones, let address = targetAddress,
              devices?.controller(for: address) === headphones,
              SonyBLEIdentity.normalizedAddress(headphones.address) == address,
              headphones.isDeviceConnected else { return false }
        return headphones.playback.generation == .v1
            || headphones.hasCurrentMusicSourceContext(for: localBluetoothAddress())
    }

    private var hasReadableMusicVolumeForHandoff: Bool {
        hasMusicControlTarget && headphones?.hasCurrentMusicVolumeRead == true
    }

    private var hasMusicVolumeForHandoff: Bool {
        hasMusicControlTarget && headphones?.hasCurrentMusicVolumeControl == true
    }

    private var hasOwnedMusicContext: Bool {
        hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)
    }

    private var hasOtherMusicSource: Bool {
        guard let headphones, headphones.isDeviceConnected, headphones.hasCurrentTable2Capabilities,
              !headphones.multipoint.inventoryIsStale, let selected = headphones.multipoint.selectedSource, selected.isConnected,
              let source = SonyBLEIdentity.normalizedAddress(selected.address),
              let local = SonyBLEIdentity.normalizedAddress(localBluetoothAddress() ?? "") else { return false }
        return source != local
    }

    func selectAudioSource(_ device: SonyMultipointDevice, on headphones: SonyHeadphonesController) {
        if pendingPhoneSelection != nil, self.headphones === headphones {
            if pendingPhoneSelection?.address == device.address { return }
            suspend(reason: "source selection superseded")
        }
        phoneSelectionAuthorization = nil
        if !beginPhoneHandoff(device, headphones: headphones, requested: true) {
            headphones.selectAudioSource(device)
        }
    }

    private func beginPhoneHandoff(_ peer: SonyMultipointDevice, headphones: SonyHeadphonesController, requested: Bool) -> Bool {
        guard case .active = state, usable, self.headphones === headphones, controlSession == headphones.notificationSession,
              devices?.selectedAddress == targetAddress, devices?.controller(for: headphones.address) === headphones,
              headphones.isReady, headphones.isDeviceConnected, headphones.hasCurrentTable2Capabilities,
              headphones.multipoint.supportsInventory, !headphones.multipoint.inventoryIsStale,
              let local = localBluetoothAddress().flatMap(SonyBLEIdentity.normalizedAddress),
              peer.isConnected, peer.address != local, let source = headphones.multipoint.selectedSource, source.isConnected,
              source.address == (requested ? local : peer.address), let session,
              audioRoute?.isDefaultOutput(LDACNativeOutput.uid) == true else { return false }
        if requested, headphones.sourceControlUnavailableReason != nil || headphones.multipoint.keeping != false
            || headphones.multipoint.sourceSwitchPayload(address: peer.address) == nil { return false }
        captureMenuBarControlsFromActiveSession()
        phoneHandoff = (peer.address, headphones.notificationSession,
                        headphones.playbackSourceGeneration &+ (requested ? 1 : 0), !requested, false, .suspending)
        pendingPhoneSelection = requested ? peer : nil
        usable = false
        state = .connecting
        nativeOutput?.silence()
        setOutputGain(0)
        volumeTask?.cancel()
        volumeTask = nil
        volumeTaskID = nil
        pendingVolume = nil
        controlSession = nil
        sourceAddress = nil
        session.park()
        return true
    }

    private func observePhoneSource(_ source: SonyMultipointDevice?) {
        guard let headphones else { return }
        guard let hold = phoneHandoff else {
            if let source { _ = beginPhoneHandoff(source, headphones: headphones, requested: false) }
            return
        }
        guard let source, source.isConnected, hold.session == headphones.notificationSession else {
            suspend(reason: "multipoint source unavailable")
            return
        }
        let generation = headphones.playbackSourceGeneration
        if source.address == hold.peer, generation == hold.generation, !hold.returned {
            phoneHandoff?.confirmed = true
            pendingPhoneSelection = nil
            if hold.phase == .held { state = .waitingForMac }
        } else if hold.confirmed, generation == hold.generation &+ 1,
                  let local = localBluetoothAddress().flatMap(SonyBLEIdentity.normalizedAddress), source.address == local {
            if !hold.returned {
                phoneHandoff?.returned = true
                state = .connecting
                _ = headphones.refreshMusicVolume()
                let identifier = sessionID
                readinessTask?.cancel()
                readinessTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.sessionID == identifier, self.phoneHandoff?.returned == true,
                          self.phoneHandoff?.phase != .confirmingVolume else { return }
                    self.suspend(reason: "headphone controls did not confirm the Mac source in time")
                }
            }
            resumePhoneHandoffIfReady()
        } else if !phoneHandoffIsCurrent {
            suspend(reason: "multipoint source changed")
        }
    }

    private var phoneHandoffIsCurrent: Bool {
        guard let hold = phoneHandoff, let headphones, let targetAddress, requestedAddress == targetAddress,
              devices?.selectedAddress == targetAddress, devices?.controller(for: targetAddress) === headphones,
              devices?.isSystemSleeping != true, headphones.isReady, headphones.isDeviceConnected,
              headphones.hasCurrentTable2Capabilities, headphones.multipoint.supportsInventory, !headphones.multipoint.inventoryIsStale,
              hold.session == headphones.notificationSession, let source = headphones.multipoint.selectedSource, source.isConnected,
              let local = localBluetoothAddress().flatMap(SonyBLEIdentity.normalizedAddress) else { return false }
        let generation = headphones.playbackSourceGeneration
        if hold.returned { return source.address == local && generation == hold.generation &+ 1 }
        if source.address == hold.peer { return generation == hold.generation }
        guard source.address == local else { return false }
        if !hold.confirmed { return generation &+ 1 == hold.generation }
        guard generation == hold.generation &+ 1, let selection = headphones.sourceTransition,
              selection.session == hold.session, selection.targetAddress == local else { return false }
        return [.awaitingSelection, .queuedReadback, .verifying].contains(selection.phase)
    }

    private func sendPendingPhoneSelection(onOutput expectedOutput: String = LDACNativeOutput.uid) {
        guard let peer = pendingPhoneSelection else { return }
        pendingPhoneSelection = nil
        guard let headphones, phoneHandoffIsCurrent, headphones.sourceControlUnavailableReason == nil,
              headphones.multipoint.keeping == false, headphones.multipoint.sourceSwitchPayload(address: peer.address) != nil,
              let hold = phoneHandoff, audioRoute?.isDefaultOutput(expectedOutput) == true else { return }
        let identifier = sessionID
        let authorization = UUID()
        let deadline = ContinuousClock.now + .seconds(SonyHeadphonesController.sourceSelectionTimeout)
        let isCurrent = { [weak self, weak headphones] in
            guard let self, let headphones else { return false }
            return self.sessionID == identifier && self.phoneSelectionAuthorization?.id == authorization
                && self.requestedAddress == headphones.address && self.devices?.selectedAddress == headphones.address
                && self.devices?.isSystemSleeping != true && self.audioRoute?.isDefaultOutput(expectedOutput) == true
                && self.devices?.controller(for: headphones.address) === headphones
                && headphones.isReady && headphones.isDeviceConnected && headphones.hasCurrentTable2Capabilities
                && headphones.notificationSession == hold.session && headphones.playbackSourceGeneration &+ 1 == hold.generation
                && !headphones.multipoint.inventoryIsStale && headphones.multipoint.keeping == false
                && headphones.multipoint.selectedSource?.address == self.localBluetoothAddress().flatMap(SonyBLEIdentity.normalizedAddress)
                && headphones.multipoint.sourceSwitchPayload(address: peer.address) != nil
                && (expectedOutput != LDACNativeOutput.uid || ContinuousClock.now < deadline)
        }
        phoneSelectionAuthorization = (authorization, nil, expectedOutput, deadline, isCurrent)
        let oldRequest = headphones.sourceTransition?.requestID
        headphones.selectAudioSource(peer, isCurrent: isCurrent)
        if let request = headphones.sourceTransition?.requestID, request != oldRequest {
            phoneSourceRequest = request
            phoneSelectionAuthorization?.request = request
        } else if phoneSelectionAuthorization?.id == authorization {
            phoneSelectionAuthorization = nil
        }
    }

    private func waitForQueuedPhoneSelection(targetDisconnected: Bool) async {
        guard let authorization = phoneSelectionAuthorization, authorization.output == LDACNativeOutput.uid,
              let request = authorization.request, let headphones else { return }
        while !targetDisconnected, headphones.isQueuedAudioSourceSelection(request), authorization.isCurrent() {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        headphones.cancelQueuedAudioSourceSelection(request, expired: ContinuousClock.now >= authorization.deadline)
        if phoneSelectionAuthorization?.id == authorization.id { phoneSelectionAuthorization = nil }
    }

    private func handlePhoneHeld() {
        guard phoneHandoff?.phase == .suspending, let output = nativeOutput else { return }
        guard phoneHandoffIsCurrent else { suspend(reason: "source changed before Mac output release"); return }
        phoneHandoff?.phase = .yieldingOutput
        let identifier = sessionID
        phoneHandoffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parked = try await output.parkForPhone()
                guard !Task.isCancelled, self.sessionID == identifier, self.phoneHandoff?.phase == .yieldingOutput else { return }
                if parked {
                    guard let original = output.savedDefaultOutputUID, self.verifyPhoneOutput(original) else { return }
                    self.sendPendingPhoneSelection(onOutput: original)
                } else { self.sendPendingPhoneSelection() }
                guard parked, self.phoneHandoffIsCurrent,
                      self.phoneHandoff?.confirmed == true || self.phoneSourceRequest != nil else {
                    self.suspend(preservingPhoneSelection: !parked, reason: "releasing LDAC for the other source")
                    return
                }
                self.phoneHandoff?.phase = .held
                if self.phoneHandoff?.confirmed == true, self.phoneHandoff?.returned == false { self.state = .waitingForMac }
                self.resumePhoneHandoffIfReady()
            } catch {
                guard !Task.isCancelled, self.sessionID == identifier else { return }
                if !self.handleOutputDeselection(error) { self.suspend(reason: "could not yield the Mac output") }
            }
        }
    }

    private func resumePhoneHandoffIfReady() {
        guard phoneHandoff?.phase == .held, phoneHandoff?.returned == true, phoneHandoffIsCurrent,
              hasReadableMusicVolumeForHandoff, headphones?.hasFreshReadableMusicVolumeReadback == true,
              let output = nativeOutput, let session else { return }
        phoneHandoff?.phase = .selectingOutput
        let identifier = sessionID
        phoneHandoffTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await output.resumeFromPhone()
                guard !Task.isCancelled, self.sessionID == identifier, self.phoneHandoff?.phase == .selectingOutput else { return }
                guard self.verifyPhoneOutput(LDACNativeOutput.uid) else { return }
                guard self.phoneHandoffIsCurrent, self.hasReadableMusicVolumeForHandoff else {
                    self.suspend(reason: "source or output changed before resuming LDAC")
                    return
                }
                self.phoneHandoff?.phase = .restarting
                session.resumeParkedStream()
            } catch {
                guard !Task.isCancelled, self.sessionID == identifier else { return }
                if !self.handleOutputDeselection(error) { self.suspend(reason: "could not reclaim the Mac output") }
            }
        }
    }

    private func verifyPhoneOutput(_ uid: String) -> Bool {
        guard audioRoute?.isDefaultOutput(uid) == true else {
            _ = handleOutputDeselection(LDACOwnerError(LDACOutputDeselectedError()))
            return false
        }
        return true
    }

    private func clearPhoneHandoff() {
        phoneHandoffTask?.cancel()
        phoneHandoffTask = nil
        phoneVolumeWakeup?.cancel()
        phoneVolumeWakeup = nil
        pendingPhoneSelection = nil
        phoneSourceRequest = nil
        phoneHandoff = nil
    }

    private func observeControls(_ headphones: SonyHeadphonesController, devices: SonyDeviceCoordinator) {
        phoneSourceObservation = headphones.musicSourceConfirmations.sink { [weak self] source in
            self?.observePhoneSource(source)
        }
        controlObservation = headphones.objectWillChange.merge(with: devices.objectWillChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.controlsChanged() }
        }
    }

    private var bindingIsCurrent: Bool {
        guard hasOwnedMusicContext, let headphones else { return false }
        return headphones.notificationSession == controlSession
            && headphones.multipoint.selectedSource?.address == sourceAddress
            && headphones.playback.musicVolumeRange == volumeRange
    }

    private var musicControlStatus: String {
        let volume = headphones?.playback.volume
        let range = headphones?.playback.musicVolumeRange
        let rangeDescription = range.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unknown"
        let currentSession = headphones.map { String($0.notificationSession) } ?? "none"
        let selectedSource = headphones?.multipoint.selectedSource?.address ?? "none"
        let newReadback = headphones?.musicVolumeReadbackID != nil && headphones?.musicVolumeReadbackID != initialReadbackID
        return "ready=\(headphones?.isReady == true) connected=\(headphones?.isDeviceConnected == true) ownedContext=\(hasOwnedMusicContext) fresh=\(headphones?.hasFreshMusicVolumeReadback == true) canWrite=\(headphones?.canControlMusicVolume == true) canConfirm=\(headphones?.canPerformConfirmedSettingChange(.playbackVolume) == true) newReadback=\(newReadback) controlSession=\(currentSession) bound=\(controlSession != nil) source=\(selectedSource) volume=\(volume.map(String.init) ?? "unknown") range=\(rangeDescription) pendingVolume=\(pendingVolume.map(String.init) ?? "none") writing=\(volumeTask != nil) userMuted=\(nativeOutput?.controls.muted ?? true)"
    }

    private func waitForControls(_ address: String, rebinding: Bool = false, preservingPendingControlOpen: Bool = false) {
        let identifier = sessionID
        let initialVolumeChangeID = nativeVolumeChangeID
        let openingEarly = preservingPendingControlOpen && (headphones?.linkState == .opening || headphones?.linkState == .handshaking)
        if !openingEarly, IOBluetoothDevice(addressString: address)?.isClassicConnected() == true {
            if headphones?.isReady != true { headphones?.refresh() }
        }
        readinessTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            var previousStatus = ""
            var isRebinding = rebinding
            var boundControls = false
            var refreshedControlSession: UInt64?
            var initialStatusReadbackID: UUID?
            do {
                while !self.usable {
                    try Task.checkCancellation()
                    guard self.sessionID == identifier, self.state != .stopping else { return }
                    let status = self.musicControlStatus
                    if status != previousStatus { self.record("volume-wait", reason: status); previousStatus = status }
                    if self.phoneHandoff != nil, !self.phoneHandoffIsCurrent {
                        self.suspend(reason: "source changed while confirming LDAC volume")
                        return
                    }
                    guard Date() < deadline else { throw ControlError(String(localized: "The headphone volume could not be confirmed after LDAC started. Reconnect the headphone controls and try LDAC again.")) }
                    if self.hasOtherMusicSource {
                        self.suspend(restoreAudio: false, reason: "another headphone music source is active")
                        return
                    }
                    if boundControls, !self.bindingIsCurrent {
                        self.rebindControls()
                        boundControls = false
                        refreshedControlSession = nil
                        isRebinding = true
                    }
                    if let headphones = self.headphones, refreshedControlSession != headphones.notificationSession {
                        let volumeReadback = headphones.musicVolumeReadbackID
                        let statusReadback = headphones.musicStatusReadbackID
                        if headphones.refreshMusicVolume() {
                            refreshedControlSession = headphones.notificationSession
                            self.initialReadbackID = volumeReadback
                            initialStatusReadbackID = statusReadback
                        }
                    }
                    if self.controlSession == nil, self.hasOwnedMusicContext, let headphones = self.headphones, headphones.hasFreshMusicVolumeReadback,
                       let readback = headphones.musicVolumeReadbackID, readback != self.initialReadbackID,
                       refreshedControlSession == headphones.notificationSession,
                       headphones.musicStatusReadbackID != nil, headphones.musicStatusReadbackID != initialStatusReadbackID,
                       let range = headphones.playback.musicVolumeRange, headphones.playback.volume != nil {
                        self.controlSession = headphones.notificationSession
                        boundControls = true
                        self.sourceAddress = headphones.multipoint.selectedSource?.address
                        self.volumeRange = range
                        self.record("volume-bound", reason: self.musicControlStatus)
                        if isRebinding, self.nativeVolumeChangeID == initialVolumeChangeID {
                            self.pendingVolume = headphones.playback.volume
                        } else if isRebinding || self.isRecovering || self.pendingVolume == nil, let output = self.nativeOutput {
                            self.pendingVolume = output.controls.volume(in: range)
                        }
                        if let volume = self.pendingVolume, volume == headphones.playback.volume,
                           volume == self.nativeOutput?.controls.volume(in: range) {
                            self.pendingVolume = nil
                        }
                    }
                    if self.controlSession != nil {
                        guard self.bindingIsCurrent else { throw ControlError(String(localized: "The headphone audio source or connection changed. LDAC stopped.")) }
                        self.sendPendingVolume()
                        if self.pendingVolume == nil, self.volumeTask == nil,
                           self.headphones?.canControlMusicVolume == true,
                           self.headphones?.canPerformConfirmedSettingChange(.playbackVolume) == true,
                           let format = self.transportFormat {
                            try await self.nativeOutput?.finishPreparation()
                            try Task.checkCancellation()
                            if self.phoneHandoff != nil {
                                guard self.verifyPhoneOutput(LDACNativeOutput.uid) else { return }
                                guard self.phoneHandoffIsCurrent, self.headphones?.hasFreshMusicVolumeReadback == true,
                                      self.headphones?.canPerformConfirmedSettingChange(.playbackVolume) == true else {
                                    self.suspend(reason: "source, volume or Mac output changed before resuming audio")
                                    return
                                }
                            }
                            guard self.sessionID == identifier, self.state != .stopping, self.bindingIsCurrent,
                                  self.pendingVolume == nil, self.volumeTask == nil else {
                                self.nativeOutput?.silence()
                                continue
                            }
                            if let output = self.nativeOutput, let range = self.volumeRange,
                               self.headphones?.playback.volume != output.controls.volume(in: range) {
                                output.silence()
                                self.pendingVolume = output.controls.volume(in: range)
                                continue
                            }
                            self.usable = true
                            self.clearPhoneHandoff()
                            self.startupSourceReturn = nil
                            self.isRecovering = false
                            self.stableSince = Date()
                            self.record("volume-admitted", reason: self.musicControlStatus)
                            self.setOutputGain(self.nativeOutput?.controls.muted == false ? 1 : 0)
                            self.state = .active(format)
                        }
                    }
                    if !self.usable {
                        if self.phoneHandoff?.phase == .confirmingVolume {
                            self.phoneVolumeWakeup = Task { _ = try? await Task.sleep(for: .milliseconds(100)) }
                            await self.phoneVolumeWakeup?.value
                        } else {
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }
                if self.sessionID == identifier { self.readinessTask = nil }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == identifier else { return }
                if self.handleOutputDeselection(error) { return }
                self.recordOutputFailure(error)
                if error is ControlError, !isRebinding, self.isRecovering, !self.hasOtherMusicSource {
                    self.beginRecovery(reason: error.localizedDescription)
                    self.session?.recoverConnection(reason: error.localizedDescription)
                } else { self.fail(error.localizedDescription) }
            }
        }
    }

    private func rebindControls() {
        guard let address = targetAddress, transportFormat != nil, state != .stopping else { return }
        captureMenuBarControlsFromActiveSession()
        record("controls-rebinding", reason: musicControlStatus)
        usable = false
        state = .connecting
        nativeOutput?.silence()
        setOutputGain(0)
        volumeTask?.cancel()
        volumeTask = nil
        volumeTaskID = nil
        controlSession = nil
        sourceAddress = nil
        if readinessTask == nil { waitForControls(address, rebinding: true) }
    }

    private func controlsChanged() {
        guard state != .stopping else { return }
        if let request = connectionModeRestoreID, let headphones,
           headphones.lastConnectionModeChangeID != request
            || (connectionModeConfirmed && headphones.connectionMode != nil && headphones.connectionMode != .soundQuality) {
            if let address = targetAddress { forgetConnectionPreference(forAddress: address) }
        }
        if let address = targetAddress, let headphones, devices?.controller(for: address) !== headphones {
            suspend(restoreAudio: false, reason: "headphone controller changed")
            return
        }
        if let hold = phoneHandoff {
            guard phoneHandoffIsCurrent else { suspend(reason: "multipoint handoff context changed"); return }
            if !hold.confirmed, let request = phoneSourceRequest,
               headphones?.sourceTransition?.requestID != request || headphones?.sourceTransition?.phase == .failed {
                suspend(reason: "headphones declined or superseded the source change")
                return
            }
            if hold.phase != .confirmingVolume {
                resumePhoneHandoffIfReady()
                return
            }
            phoneVolumeWakeup?.cancel()
        }
        if hasOtherMusicSource {
            suspend(restoreAudio: false, reason: "another headphone music source is active")
            return
        }
        guard controlSession != nil else { return }
        guard bindingIsCurrent else {
            rebindControls()
            return
        }
        if usable { setOutputGain(nativeOutput?.controls.muted == false ? 1 : 0) }
        if pendingVolume == nil, volumeTask == nil, let headphones, let output = nativeOutput,
           let range = volumeRange, let volume = headphones.playback.volume, output.controls.volume(in: range) != volume {
            pendingVolume = volume
        }
        sendPendingVolume()
    }

    private func sendPendingVolume() {
        guard volumeTask == nil, pendingVolume != nil, controlSession != nil, state != .stopping else { return }
        let identifier = sessionID
        let volumeIdentifier = UUID()
        volumeTaskID = volumeIdentifier
        volumeTask = Task { [weak self] in
            guard let self, self.sessionID == identifier else { return }
            defer {
                if self.volumeTaskID == volumeIdentifier {
                    self.volumeTask = nil
                    self.volumeTaskID = nil
                    self.controlsChanged()
                }
            }
            do {
                while let volume = self.pendingVolume {
                    try Task.checkCancellation()
                    guard self.bindingIsCurrent, let headphones = self.headphones,
                          self.volumeRange?.contains(volume) == true else {
                        throw ControlError("The headphone music volume controls became unavailable. LDAC stopped.", userFacing: String(localized: "The headphone volume controls became unavailable. LDAC stopped."))
                    }
                    if !headphones.canControlMusicVolume || !headphones.canPerformConfirmedSettingChange(.playbackVolume) {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    self.pendingVolume = nil
                    if headphones.playback.volume != volume {
                        self.record("volume-write", reason: "requested=\(volume)")
                        try await headphones.performConfirmedSettingChange(.playbackVolume) {
                            headphones.setPlaybackVolume(volume) { [weak self] in
                                guard let self else { return false }
                                return self.sessionID == identifier && self.volumeTaskID == volumeIdentifier
                                    && self.volumeTask?.isCancelled == false && self.state != .stopping
                                    && self.transportFormat != nil && self.bindingIsCurrent
                                    && (self.phoneHandoff == nil || (self.phoneHandoffIsCurrent && self.audioRoute?.isDefaultOutput(LDACNativeOutput.uid) == true))
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard self.sessionID == identifier, self.bindingIsCurrent, headphones.playback.volume == volume else {
                        throw ControlError("The headphones did not confirm the requested native volume. LDAC stopped.", userFacing: String(localized: "The headphones did not confirm the requested volume. LDAC stopped."))
                    }
                    self.record("volume-confirmed", reason: "confirmed=\(volume)")
                    if self.pendingVolume == nil, let range = self.volumeRange {
                        try await self.nativeOutput?.configure(volume: volume, range: range)
                        self.lastNativeVolumeScalar = self.nativeOutput?.controls.scalar
                        try Task.checkCancellation()
                    }
                }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == identifier, self.volumeTaskID == volumeIdentifier else { return }
                if self.handleOutputDeselection(error) { return }
                self.recordOutputFailure(error)
                if !self.bindingIsCurrent, !self.hasOtherMusicSource, self.state != .stopping {
                    self.rebindControls()
                } else { self.fail(error.localizedDescription) }
            }
        }
    }

    private func setOutputGain(_ gain: Double) {
        let gain = headphones?.playback.supportsMute == true && headphones?.playback.musicMuted != false ? 0 : gain
        guard requestedOutputGain != gain else { return }
        requestedOutputGain = gain
        record("gain-requested", reason: "gain=\(gain) usable=\(usable) userMuted=\(nativeOutput?.controls.muted ?? true)")
        session?.updateGain(gain)
    }

    private func handleOutputDeselection(_ error: Error) -> Bool {
        guard (error as? LDACOwnerError)?.outputDeselected == true else { return false }
        phoneSelectionAuthorization = nil
        if state != .stopping {
            if isPreparingSourceChange || startupSourceReturn != nil {
                pendingStartupSourceSelection?.outputDeselected = true
                requestedAddress = nil
                suspensionRequested = true
                stopSession(restoreAudio: false, preserveStartupSourceReturn: true, reason: "Mac audio output changed")
                return true
            }
            recoveryPaused = true
            let previouslyActive: Bool
            if case .active = state { previouslyActive = true } else { previouslyActive = false }
            let returningHeadphones = headphones
            if let headphones {
                let connected = isClassicConnected(headphones.address)
                recoveryResumeContext = (ObjectIdentifier(headphones), connected, !connected)
            }
            suspend(restoreAudio: false, reason: "Mac audio output changed")
            if previouslyActive, let returningHeadphones, let resumeOutputUID,
               nativeOutput?.savedDefaultOutputUID == resumeOutputUID {
                observeDeselectedSourceReturn(returningHeadphones, originalOutputUID: resumeOutputUID)
            }
        }
        return true
    }

    private func observeDeselectedSourceReturn(_ headphones: SonyHeadphonesController, originalOutputUID: String) {
        guard headphones.hasCurrentTable2Capabilities, headphones.multipoint.supportsInventory,
              LDACNativeOutput.canTransferControls(uid: originalOutputUID, transport: kAudioDeviceTransportTypeBluetooth, address: headphones.address),
              let local = SonyBLEIdentity.normalizedAddress(localBluetoothAddress() ?? ""),
              headphones.hasCurrentMusicSourceContext(for: local) else { return }
        let session = headphones.notificationSession
        var peerGeneration: UInt64?
        deselectedSourceObservation = headphones.musicSourceConfirmations.sink { [weak self, weak headphones] source in
            guard let self, let headphones, headphones.notificationSession == session else { return }
            let generation = headphones.playbackSourceGeneration
            if let address = source.flatMap({ SonyBLEIdentity.normalizedAddress($0.address) }) {
                if address != local {
                    peerGeneration = generation
                    self.deselectedSourceReturn = nil
                } else {
                    let peer = peerGeneration
                    peerGeneration = nil
                    if let peer, generation == peer + 1,
                       self.audioRoute?.isDefaultOutput(originalOutputUID, transport: kAudioDeviceTransportTypeBluetooth) == true {
                        self.deselectedSourceReturn = (ObjectIdentifier(headphones), session, generation)
                        Task { @MainActor [weak self] in self?.resumeIfReady() }
                    }
                }
            } else {
                peerGeneration = nil
                self.deselectedSourceReturn = nil
            }
        }
    }

    private func fail(_ message: String) {
        guard state != .stopping else { return }
        record("failed", reason: "\(message); \(musicControlStatus)")
        volumeError = message
        requestedAddress = nil
        stopSession(reason: "coordinator failed: \(message)")
    }

    private func beginRecovery(reason: String, at date: Date = Date()) {
        guard requestedAddress == targetAddress, requestedAddress != nil, state != .stopping else { return }
        captureMenuBarControlsFromActiveSession()
        record("recovering", reason: reason)
        if let stableSince, date.timeIntervalSince(stableSince) >= 30 { recoveryAttempt = 0 }
        stableSince = nil
        isRecovering = true
        state = .connecting
        usable = false
        nativeOutput?.silence()
        setOutputGain(0)
        readinessTask?.cancel()
        readinessTask = nil
        volumeTask?.cancel()
        volumeTask = nil
        volumeTaskID = nil
        controlSession = nil
        sourceAddress = nil
        transportFormat = nil
    }

    private func nextRecoveryDelay() -> TimeInterval? {
        guard recoveryAttempt < 2 else {
            recoveryPaused = true
            suspensionRequested = true
            startupSourceReturn = nil
            return nil
        }
        let delay = ReconnectBackoff.delay(forAttempt: recoveryAttempt)
        recoveryAttempt += 1
        return delay
    }

    private func canResumeRecovery(with headphones: SonyHeadphonesController) -> Bool {
        guard recoveryPaused else { return true }
        let controller = ObjectIdentifier(headphones)
        let connected = isClassicConnected(headphones.address)
        guard let context = recoveryResumeContext, context.controller == controller else {
            recoveryResumeContext = (controller, connected, false)
            return false
        }
        let disconnected = context.observedDisconnect || (context.observedConnected && !connected)
        recoveryResumeContext = (controller, context.observedConnected || connected, disconnected)
        return connected && disconnected
    }

    private func scheduleRecovery(_ address: String, targetDisconnected: Bool) {
        guard recoveryTask == nil else { return }
        guard let delay = nextRecoveryDelay() else {
            stopSession(reason: "automatic recovery attempts exhausted")
            return
        }
        let identifier = sessionID
        record("retry-scheduled", reason: "delay=\(delay)")
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, self.sessionID == identifier, self.requestedAddress == address,
                      self.isRecovering, self.state != .stopping, let output = self.nativeOutput else { return }
                try await output.validateForRecovery()
                if self.hasOtherMusicSource {
                    self.suspend(restoreAudio: false, reason: "another headphone music source is active")
                    return
                }
                try await output.prepareForReconnect()
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.state != .stopping else { return }
                guard self.hasMusicVolumeForHandoff else {
                    self.suspensionRequested = true
                    self.startupSourceReturn = nil
                    self.finish(nil, targetDisconnected: targetDisconnected)
                    return
                }
                self.initialReadbackID = self.headphones?.musicVolumeReadbackID
                self.recoveryTask = nil
                self.sessionID = UUID()
                self.requestedOutputGain = 0
                self.launch(address)
            } catch is CancellationError {
            } catch {
                guard let self, self.sessionID == identifier else { return }
                if self.handleOutputDeselection(error) { return }
                self.recordOutputFailure(error)
                self.recoveryTask = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    private func stopSession(restoreAudio: Bool = true, preserveStartupSourceReturn: Bool = false, reason: String) {
        let restoreAudio = restoreAudio && phoneHandoff == nil
        clearPhoneHandoff()
        phoneSourceObservation = nil
        record("stopping", reason: "\(reason); restoreAudio=\(restoreAudio) usable=\(usable) requestedGain=\(requestedOutputGain); \(musicControlStatus)")
        let otherSource = hasOtherMusicSource
        if !preserveStartupSourceReturn { pendingStartupSourceSelection = nil }
        if (!restoreAudio && !preserveStartupSourceReturn) || otherSource { startupSourceReturn = nil }
        restoreAudioOnStop = restoreAudioOnStop && restoreAudio && !otherSource
        guard cleanupTask == nil else { return }
        captureMenuBarControlsFromActiveSession()
        recoveryTask?.cancel()
        recoveryTask = nil
        state = .stopping
        usable = false
        nativeOutput?.silence()
        setOutputGain(0)
        readinessTask?.cancel()
        readinessTask = nil
        volumeTask?.cancel()
        volumeTask = nil
        volumeTaskID = nil
        controlObservation = nil
        if let session { session.stop(restoreAudio: restoreAudioOnStop) }
        else if let startTask { startTask.cancel() }
        else if isRecovering, restoreAudioOnStop, let address = targetAddress {
            sessionID = UUID()
            launch(address, restoringOnly: true)
        } else { finish(nil) }
    }

    private func finish(_ message: String?, targetDisconnected: Bool = false) {
        guard cleanupTask == nil else { return }
        clearPhoneHandoff()
        phoneSourceObservation = nil
        if sourceResumeOutputUID != nil {
            sourceResumeOutputUID = nil
            deselectedSourceReturn = nil
        }
        if targetDisconnected { captureMenuBarControls(for: nil) }
        else { captureMenuBarControlsFromActiveSession() }
        record("restoring", reason: "raw=\(message ?? "clean") coordinator=\(volumeError ?? "none")")
        state = .stopping
        usable = false
        recoveryTask?.cancel()
        recoveryTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        volumeTask?.cancel()
        volumeTask = nil
        volumeTaskID = nil
        controlObservation = nil
        let output = nativeOutput
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForQueuedPhoneSelection(targetDisconnected: targetDisconnected)
            let disconnected = targetDisconnected || self.devices?.isSystemSleeping == true
            let restoreError = await output?.restoreAndRelease(targetDisconnected: disconnected,
                restoreHeadphoneOutput: self.restoreAudioOnStop && !disconnected)
            let connectionRestoreError: String?
            if disconnected || self.suspensionRequested || self.hasOtherMusicSource {
                if let address = self.targetAddress, let request = self.connectionModeRestoreID {
                    self.deferredConnectionModes[address] = request
                    self.pendingConnectionModes[address] = request
                }
                self.connectionModeRestoreID = nil
                self.connectionModeConfirmed = false
                connectionRestoreError = nil
            } else {
                connectionRestoreError = await self.restoreConnectionMode()
            }
            var sourceRestoreError: String?
            if !disconnected, restoreError == nil, self.requestedAddress == nil || message != nil || self.volumeError != nil {
                sourceRestoreError = await self.returnStartupSource()
            } else {
                self.startupSourceReturn = nil
                self.pendingStartupSourceSelection = nil
            }
            self.record("restored", reason: restoreError ?? "native output cleanup completed and output lease released")
            self.nativeOutput = nil
            self.outputID = nil
            self.headphones = nil
            self.transportFormat = nil
            self.controlSession = nil
            self.sourceAddress = nil
            self.volumeRange = nil
            self.pendingVolume = nil
            self.initialReadbackID = nil
            self.requestedOutputGain = 0
            self.captureMenuBarControls(for: nil)
            self.isSessionRunning = false
            self.isRecovering = false
            self.stableSince = nil
            if self.audioCaptureAccess == .checking { self.audioCaptureAccess = .unchecked }
            let messages = [message, self.volumeError, restoreError, connectionRestoreError, sourceRestoreError].compactMap { $0 }
                .reduce(into: [String]()) { messages, message in
                    guard !messages.contains(where: { $0.contains(message) }) else { return }
                    messages.removeAll { message.contains($0) }
                    messages.append(message)
                }
            self.volumeError = nil
            self.cleanupTask = nil
            if !messages.isEmpty {
                self.requestedAddress = nil
                self.state = .failed(messages.joined(separator: " "))
            } else if let next = self.requestedAddress {
                if self.suspensionRequested {
                    if self.recoveryPaused, self.recoveryResumeContext == nil, let headphones = self.devices?.controller(for: next) {
                        self.recoveryResumeContext = (ObjectIdentifier(headphones), self.isClassicConnected(next), false)
                    }
                    self.targetAddress = next
                    self.state = .waitingForDevice
                } else { self.start(next) }
            } else {
                self.targetAddress = nil
                self.state = .off
            }
            self.resumeIfReady()
            if !self.isSessionRunning { self.completeStop() }
        }
    }

    private var diagnosticState: String {
        switch state {
        case .off: "off"
        case .requested: "requested"
        case .connecting: "connecting"
        case .waitingForDevice: "waiting for device"
        case .waitingForMac: "waiting for this Mac"
        case let .active(format): "active; \(format)"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }

    private var diagnosticMusicControlStatus: String {
        let volume = headphones?.playback.volume.map(String.init) ?? "unknown"
        let range = headphones?.playback.musicVolumeRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unknown"
        return "ready=\(headphones?.isReady == true) owned=\(hasOwnedMusicContext) fresh=\(headphones?.hasFreshMusicVolumeReadback == true) writable=\(headphones?.canControlMusicVolume == true) volume=\(volume) range=\(range) pending=\(pendingVolume.map(String.init) ?? "none") writing=\(volumeTask != nil)"
    }

    var diagnosticReport: String {
        let names = (headphones?.diagnosticPrivateNames ?? []) + [audioRoute?.route?.name ?? ""]
        let lines = [
            "Current LDAC snapshot:",
            "LDAC state: \(diagnosticState)",
            "LDAC attempt: \(diagnosticAttempt)",
            "LDAC target: \(targetAddress == nil ? "None" : "Selected; identity omitted")",
            "LDAC session running: \(isSessionRunning); recovering: \(isRecovering); retry: \(recoveryAttempt)",
            "LDAC driver: \(driverState)",
            "LDAC driver installation issue: \(driverInstallationError ?? "None")",
            "LDAC audio capture: \(audioCaptureAccess)",
            "LDAC configuration: \(requestedConfiguration.sampleRate.rawValue) Hz; quality=\(requestedConfiguration.quality)",
            "LDAC cleanup pending: \(cleanupTask != nil); preference restores: \(preferenceRestoreTasks.count)",
            "LDAC music controls: \(diagnosticMusicControlStatus)",
            "LDAC current volume issue: \(volumeError ?? "None")",
            "LDAC last native failure (may be from an earlier attempt): \(lastNativeFailure?.message ?? "None")",
        ]
        return lines.map { DiagnosticHistory.line($0, redacting: names) }.joined(separator: "\n")
            + "\n\nLDAC history\n" + diagnosticHistory.report
    }

    func recordOutputFailure(_ error: Error) {
        if let diagnostic = (error as? LDACOwnerError)?.diagnostic ?? (error as? LDACPriorityCleanupError)?.diagnostic {
            recordNativeDiagnostic(diagnostic)
        }
    }

    func recordNativeDiagnostic(_ diagnostic: LDACNativeSession.Diagnostic) {
        record("native \(diagnostic.stage)", reason: diagnostic.detail)
        if diagnostic.isFailure, lastNativeFailure?.attempt != diagnosticAttempt {
            let message = DiagnosticHistory.line("attempt=\(diagnosticAttempt) stage=\(diagnostic.stage); \(diagnostic.detail)",
                                                 redacting: (headphones?.diagnosticPrivateNames ?? []) + [audioRoute?.route?.name ?? ""])
            lastNativeFailure = (diagnosticAttempt, message)
        }
    }

    private func record(_ event: String, reason: String) {
        let detail = reason.replacingOccurrences(of: musicControlStatus, with: diagnosticMusicControlStatus)
        diagnosticHistory.record("attempt=\(diagnosticAttempt) \(event); \(detail)", failure: event.contains("failed"),
                                 redacting: (headphones?.diagnosticPrivateNames ?? []) + [audioRoute?.route?.name ?? ""])
        Self.logger.notice("LDAC controller \(event, privacy: .public); target=\(self.targetAddress ?? "none", privacy: .private(mask: .hash)) session=\(self.sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .private)")
    }

    private func completeStop() {
        guard !needsStopBeforeTermination else { return }
        let completions = stopCompletions
        stopCompletions = []
        for completion in completions { completion() }
    }

    private struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String, userFacing: String? = nil) {
            self.message = userFacing ?? message
            if userFacing != nil { LDACController.logger.error("\(message, privacy: .private)") }
        }
    }
}
#endif
