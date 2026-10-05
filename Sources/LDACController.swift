#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import Foundation
import OSLog
@preconcurrency import IOBluetooth

@MainActor
final class LDACController: ObservableObject {
    @Published private(set) var state: LDACState = .off
    @Published private(set) var targetAddress: String?
    @Published private(set) var actualOutputGain = 0.0
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecovering = false
    @Published private(set) var audioCaptureAccess: LDACAudioCaptureAccess = .unchecked
    @Published private(set) var driverState: LDACDriverInstaller.State
    @Published private(set) var driverInstallationError: String?
    @Published private(set) var isOpeningDriverInstaller = false
    private let bundle: Bundle
    private var session: LDACNativeSession?
    private var sessionID = UUID()
    private var requestedAddress: String?
    private var requestedConfiguration = LDACConfiguration()
    private var nativeOutput: LDACNativeOutput?
    private var outputID: UUID?
    private var headphones: SonyHeadphonesController?
    private var controlObservation: AnyCancellable?
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
    private var restoreAudioOnStop = true
    private var stableSince: Date?
    private var pendingVolume: Int?
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
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "LDACLifecycle")

    init(bundle: Bundle = .main, devices: SonyDeviceCoordinator? = nil, audioRoute: MacAudioRouteObserver? = nil) {
        self.bundle = bundle
        driverState = LDACDriverInstaller.inspect(bundle: bundle)
        helpers = LDACNativeSession.Helpers(bundle: bundle)
        self.devices = devices
        self.audioRoute = audioRoute
        for changes in [devices?.objectWillChange, audioRoute?.objectWillChange].compactMap({ $0 }) {
            changes.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.resumeIfReady() }
            }.store(in: &availabilityObservations)
        }
    }

    var isNativeOutputAvailable: Bool { LDACNativeOutput.isAvailable }

    var canStartOrInstallDriver: Bool {
        switch driverState {
        case .missing, .outdated, .current: !isOpeningDriverInstaller
        case .restartRequired, .unavailable: false
        }
    }

    func refreshDriverState() {
        guard !isSessionRunning else { return }
        driverState = LDACDriverInstaller.inspect(bundle: bundle)
    }

    func installDriver(forAddress address: String) {
        guard deviceUnavailableReason(forAddress: address) == nil, !isSessionRunning, !isOpeningDriverInstaller else { return }
        refreshDriverState()
        guard driverState == .missing || driverState == .outdated else { return }
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
            return String(localized: "Connect Sony controls before starting LDAC.")
        }
        switch headphones.deviceModel {
        case .wfXM3, .whCH720N:
            return String(localized: "This model does not support the LDAC codec.")
        default: break
        }
        guard headphones.isReady else {
            return String(localized: "Connect Sony controls before starting LDAC.")
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

    func setEnabled(_ enabled: Bool, forAddress address: String, configuration: LDACConfiguration? = nil) {
        guard let address = SonyBLEIdentity.normalizedAddress(address) else { return }
        if enabled {
            guard requestedAddress != address else { return }
            guard preferenceRestoreTasks[address] == nil else { return }
            guard deviceUnavailableReason(forAddress: address) == nil else { return }
            if let configuration { requestedConfiguration = configuration }
            if !isSessionRunning {
                refreshDriverState()
                guard driverState == .current else {
                    state = .off
                    targetAddress = nil
                    installDriver(forAddress: address)
                    return
                }
            }
            guard helpers.isAvailable else {
                targetAddress = address
                state = .failed(String(localized: "The LDAC audio helpers are unavailable."))
                return
            }
            requestedAddress = address
            if !isSessionRunning { start(address) }
            else { stopSession(reason: "target changed") }
        } else if targetAddress == address || requestedAddress == address {
            requestedAddress = nil
            suspensionRequested = false
            if isSessionRunning { stopSession(reason: "user disabled LDAC") }
            else { state = .off; targetAddress = nil; resumeIfReady() }
        }
    }

    func stop(restoreAudio: Bool = true, reason: String = "app requested stop", completion: (@MainActor () -> Void)? = nil) {
        requestedAddress = nil
        suspensionRequested = false
        if let completion {
            stopCompletions.append(completion)
            objectWillChange.send()
        }
        if !isSessionRunning { state = .off; targetAddress = nil; resumeIfReady(); completeStop() }
        else { stopSession(restoreAudio: restoreAudio, reason: reason) }
    }

    func suspend(reason: String = "Mac is going to sleep") {
        guard requestedAddress != nil else { return }
        suspensionRequested = true
        if isSessionRunning { stopSession(restoreAudio: false, reason: reason) }
        else { state = .waitingForDevice }
    }

    private func resumeIfReady() {
        guard devices?.isSystemSleeping != true else { return }
        for (address, request) in deferredConnectionModes where address != requestedAddress && preferenceRestoreTasks[address] == nil {
            guard let headphones = devices?.controller(for: address), headphones.isDeviceConnected, headphones.isReady else { continue }
            deferredConnectionModes[address] = nil
            preferenceRestoreTasks[address] = Task { [weak self] in
                guard let self else { return }
                let error = await self.restoreConnectionPreference(headphones, address: address, request: request)
                self.objectWillChange.send()
                self.preferenceRestoreTasks[address] = nil
                if let error { self.record("preference-restore-failed", reason: error) }
            }
        }
        guard state == .waitingForDevice, !isSessionRunning, cleanupTask == nil,
              let address = requestedAddress, preferenceRestoreTasks[address] == nil,
              devices?.selectedAddress == address,
              let headphones = devices?.controller(for: address), headphones.isDeviceConnected,
              deviceUnavailableReason(forAddress: address) == nil,
              headphones.hasCurrentMusicSourceContext(for: IOBluetoothHostController.default()?.addressAsString()),
              let resumeOutputUID, audioRoute?.route?.uid == resumeOutputUID else { return }
        refreshDriverState()
        guard driverState == .current, helpers.isAvailable else { return }
        start(address)
    }

    private func start(_ address: String) {
        sessionID = UUID()
        state = .requested
        targetAddress = address
        volumeError = nil
        connectionModeRestoreID = deferredConnectionModes.removeValue(forKey: address)
        connectionModeConfirmed = connectionModeRestoreID != nil
        suspensionRequested = false
        resumeOutputUID = audioRoute?.route?.uid
        isRecovering = false
        recoveryAttempt = 0
        restoreAudioOnStop = true
        isSessionRunning = true
        record("requested", reason: "enabled")
        let identifier = sessionID
        outputID = identifier
        let output = LDACNativeOutput(id: sessionID, address: address) { [weak self] result in
            guard let self, self.outputID == identifier, self.state != .stopping else { return }
            switch result {
            case let .success(controls):
                self.record("native-controls", reason: "scalar=\(controls.scalar) userMuted=\(controls.muted)")
                if controls.muted { self.setOutputGain(0) }
                if let range = self.volumeRange {
                    self.pendingVolume = controls.volume(in: range)
                    self.sendPendingVolume()
                }
                if self.usable { self.setOutputGain(controls.muted ? 0 : 1) }
            case let .failure(error):
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
            do {
                guard let devices = self.devices, let headphones = devices.controller(for: address), headphones.deviceModel != .unknown else {
                    throw ControlError("Connect Sony controls before starting LDAC.")
                }
                if let reason = self.deviceUnavailableReason(forAddress: address) { throw ControlError(reason) }
                self.headphones = headphones
                if let request = self.connectionModeRestoreID, headphones.lastConnectionModeChangeID != request {
                    self.connectionModeRestoreID = nil
                    self.connectionModeConfirmed = false
                }
                try await self.prepareConnectionMode(headphones, address: address, identifier: identifier)
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.requestedAddress == address, self.state != .stopping else {
                    throw CancellationError()
                }
                guard devices.controller(for: address) === headphones else {
                    throw ControlError(String(localized: "The Sony headphone controller changed."))
                }
                try await output.claim(model: headphones.deviceModel.name, targetAddress: address, sampleRate: self.requestedConfiguration.sampleRate)
                let priority = try output.priorityControl()
                let previousReadback = headphones.musicVolumeReadbackID
                if IOBluetoothDevice(addressString: address)?.isConnected() == true { headphones.refresh() }
                self.record("initial-volume-wait", reason: self.musicControlStatus)
                let deadline = Date().addingTimeInterval(15)
                while !self.hasMusicVolumeForHandoff || !headphones.hasFreshMusicVolumeReadback || headphones.musicVolumeReadbackID == previousReadback {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw ControlError("The Mac's headphone music volume could not be read. Connect Sony controls and select this Mac as the headphone audio source, then retry LDAC.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume else {
                    throw ControlError("The headphones did not report their music volume range.")
                }
                self.volumeRange = range
                self.record("initial-volume-admitted", reason: self.musicControlStatus)
                self.initialReadbackID = headphones.musicVolumeReadbackID
                try output.configure(volume: volume, range: range, preservingUserChange: true)
                self.pendingVolume = output.controls.volume(in: range)
                self.observeControls(headphones, devices: devices)
                self.startTask = nil
                self.launch(address, priority: priority)
            } catch is CancellationError {
                guard self.sessionID == identifier else { return }
                self.record("start-cancelled", reason: self.musicControlStatus)
                self.startTask = nil
                self.finish(nil)
            } catch {
                guard self.sessionID == identifier else { return }
                self.record("start-failed", reason: "\(error.localizedDescription); \(self.musicControlStatus)")
                self.startTask = nil
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

    private func prepareConnectionMode(_ headphones: SonyHeadphonesController, address: String, identifier: UUID) async throws {
        try Task.checkCancellation()
        guard headphones.connectionTransition?.isFinished != false else {
            throw ControlError(String(localized: "Finish the current connection change before starting LDAC."))
        }
        guard headphones.supportsConnectionMode else { return }
        if headphones.connectionMode == .soundQuality { return }
        let original = headphones.connectionMode
        let previous = headphones.lastConnectionModeChangeID
        headphones.setConnectionMode(.soundQuality)
        guard let request = headphones.lastConnectionModeChangeID, request != previous else {
            throw ControlError(headphones.connectionModeError ?? String(localized: "Sound Quality could not be selected for LDAC."))
        }
        if original == .stableConnection { connectionModeRestoreID = request }
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
                throw ControlError(String(localized: "The Sony headphone controller changed."))
            }
            guard headphones.lastConnectionModeChangeID == request else { return false }
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

    private func restoreConnectionPreference(_ headphones: SonyHeadphonesController, address: String, request: UUID) async -> String? {
        var ownedRequest = request
        do {
            guard try await waitForConnectionChange(headphones, address: address, request: request, restoring: true) else { return nil }
            if headphones.connectionMode == .stableConnection { return nil }
            guard headphones.connectionMode == .soundQuality else {
                throw ControlError(String(localized: "The headphone connection preference could not be verified."))
            }
            headphones.setConnectionMode(.stableConnection)
            guard let restoration = headphones.lastConnectionModeChangeID, restoration != request else {
                throw ControlError(headphones.connectionModeError ?? String(localized: "Stable Connection could not be selected."))
            }
            ownedRequest = restoration
            guard try await waitForConnectionChange(headphones, address: address, request: restoration, restoring: true) else { return nil }
            guard headphones.connectionMode == .stableConnection else {
                throw ControlError(String(localized: "Stable Connection was not confirmed."))
            }
            return nil
        } catch {
            if devices?.isSystemSleeping == true || !headphones.isDeviceConnected,
               headphones.lastConnectionModeChangeID == ownedRequest {
                deferredConnectionModes[address] = ownedRequest
                return nil
            }
            return String(localized: "Stable Connection could not be restored. \(error.localizedDescription)")
        }
    }

    private func launch(_ address: String, priority: LDACPriorityControl?, restoringOnly: Bool = false) {
        if !restoringOnly { audioCaptureAccess = .checking }
        let identifier = sessionID
        record("helpers-started", reason: restoringOnly ? "restoring ordinary Bluetooth audio" : "checking targeted audio permission")
        let session = LDACNativeSession(id: identifier, address: address, helpers: helpers, gain: 0,
                                        outputDeviceUID: LDACNativeOutput.uid, priority: priority, configuration: requestedConfiguration,
                                        recoveryAttempt: isRecovering, restoringOnly: restoringOnly) { [weak self] event in
            guard let self, self.session?.id == identifier else { return }
            switch event {
            case .handoffReady:
                self.record("handoff-ready", reason: self.musicControlStatus)
                guard self.state != .stopping else { return }
                do {
                    if !self.isRecovering {
                        guard self.hasMusicVolumeForHandoff, let headphones = self.headphones, headphones.hasFreshMusicVolumeReadback,
                              let range = headphones.playback.musicVolumeRange, let volume = headphones.playback.volume else {
                            throw ControlError("Headphone music controls changed before Bluetooth handoff. Retry LDAC.")
                        }
                        try self.nativeOutput?.configure(volume: volume, range: range, preservingUserChange: true)
                        self.initialReadbackID = headphones.musicVolumeReadbackID
                        if let output = self.nativeOutput { self.pendingVolume = output.controls.volume(in: range) }
                    } else {
                        try self.nativeOutput?.validateForRecovery()
                    }
                    try self.nativeOutput?.selectForHandoff()
                    self.record("handoff-allowed", reason: "silent native output selected")
                    self.session?.allowHandoff()
                    self.state = .connecting
                } catch { self.fail(error.localizedDescription) }
            case .connecting:
                self.record("connecting", reason: "owned raw transport setup")
                if self.state != .stopping { self.state = .connecting }
            case let .active(format):
                if self.state != .stopping {
                    self.transportFormat = format
                    self.record("raw-ready", reason: self.musicControlStatus)
                    self.waitForControls(address)
                }
            case let .formatChanged(format):
                if self.state != .stopping {
                    self.transportFormat = format
                    if case .active = self.state { self.state = .active(format) }
                }
            case let .gainApplied(gain):
                self.actualOutputGain = gain
                self.record("gain-applied", reason: "gain=\(gain)")
            case let .audioCaptureAccess(access):
                self.audioCaptureAccess = access
                self.record("capture-access", reason: String(describing: access))
            case let .failed(message):
                self.fail(message)
            case let .connectionLost(message):
                if self.requestedAddress == address, self.state != .stopping { self.beginRecovery(reason: message) }
                else { self.session?.stop(restoreAudio: self.restoreAudioOnStop) }
            case let .finished(completion):
                self.session = nil
                if completion.waitForReconnect, completion.canRetry, self.requestedAddress == address {
                    self.suspensionRequested = true
                    self.finish(nil, targetDisconnected: true)
                } else if completion.canRetry, self.requestedAddress == address, self.state != .stopping {
                    if !self.isRecovering { self.beginRecovery(reason: completion.message ?? "Bluetooth connection lost") }
                    self.scheduleRecovery(address)
                } else if completion.canRetry, !completion.waitForReconnect, self.restoreAudioOnStop {
                    self.sessionID = UUID()
                    self.launch(address, priority: nil, restoringOnly: true)
                } else {
                    self.finish(completion.requiresAttention ? completion.message : nil, targetDisconnected: completion.targetDisconnected)
                }
            }
        }
        self.session = session
        session.start()
    }

    private var hasMusicVolumeForHandoff: Bool {
        guard let headphones, let address = targetAddress,
              devices?.controller(for: address) === headphones,
              SonyBLEIdentity.normalizedAddress(headphones.address) == address,
              headphones.isDeviceConnected, headphones.hasCurrentMusicVolumeControl else { return false }
        return headphones.playback.generation == .v1
            || headphones.hasCurrentMusicSourceContext(for: IOBluetoothHostController.default()?.addressAsString())
    }

    private var hasOwnedMusicContext: Bool {
        hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)
    }

    private var hasOtherMusicSource: Bool {
        guard let headphones, headphones.isDeviceConnected, headphones.hasCurrentMusicVolumeControl,
              let local = SonyBLEIdentity.normalizedAddress(IOBluetoothHostController.default()?.addressAsString() ?? ""),
              let address = headphones.multipoint.selectedSource?.address,
              let source = SonyBLEIdentity.normalizedAddress(address) else { return false }
        return source != local
    }

    private func observeControls(_ headphones: SonyHeadphonesController, devices: SonyDeviceCoordinator) {
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

    private func waitForControls(_ address: String) {
        let identifier = sessionID
        if (headphones?.playback.generation != .v1 || headphones?.isReady != true),
           IOBluetoothDevice(addressString: address)?.isConnected() == true { headphones?.refresh() }
        readinessTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            var previousStatus = ""
            var refreshedLegacySession: UInt64?
            var initialStatusReadbackID: UUID?
            do {
                while !self.usable {
                    try Task.checkCancellation()
                    guard self.sessionID == identifier, self.state != .stopping else { return }
                    let status = self.musicControlStatus
                    if status != previousStatus { self.record("volume-wait", reason: status); previousStatus = status }
                    guard Date() < deadline else { throw ControlError("LDAC transport started, but fresh Sony music volume controls were not confirmed. Reconnect Sony controls and retry LDAC.") }
                    if let headphones = self.headphones, headphones.playback.generation == .v1,
                       refreshedLegacySession != headphones.notificationSession {
                        let volumeReadback = headphones.musicVolumeReadbackID
                        let statusReadback = headphones.musicStatusReadbackID
                        if headphones.refreshMusicVolume() {
                            refreshedLegacySession = headphones.notificationSession
                            self.initialReadbackID = volumeReadback
                            initialStatusReadbackID = statusReadback
                        }
                    }
                    if self.controlSession == nil, self.hasOwnedMusicContext, let headphones = self.headphones, headphones.hasFreshMusicVolumeReadback,
                       let readback = headphones.musicVolumeReadbackID, readback != self.initialReadbackID,
                       headphones.playback.generation != .v1 || (refreshedLegacySession == headphones.notificationSession
                           && headphones.musicStatusReadbackID != nil && headphones.musicStatusReadbackID != initialStatusReadbackID),
                       let range = headphones.playback.musicVolumeRange, headphones.playback.volume != nil {
                        self.controlSession = headphones.notificationSession
                        self.sourceAddress = headphones.multipoint.selectedSource?.address
                        self.volumeRange = range
                        self.record("volume-bound", reason: self.musicControlStatus)
                        if self.isRecovering || self.pendingVolume == nil, let output = self.nativeOutput { self.pendingVolume = output.controls.volume(in: range) }
                    }
                    if self.controlSession != nil {
                        guard self.bindingIsCurrent else { throw ControlError("The headphone music source or Sony control session changed. LDAC stopped.") }
                        self.sendPendingVolume()
                        if self.pendingVolume == nil, self.volumeTask == nil,
                           self.headphones?.canControlMusicVolume == true,
                           self.headphones?.canPerformConfirmedSettingChange(.playbackVolume) == true,
                           let format = self.transportFormat {
                            try self.nativeOutput?.finishPreparation()
                            self.usable = true
                            self.isRecovering = false
                            self.stableSince = Date()
                            self.record("volume-admitted", reason: self.musicControlStatus)
                            self.setOutputGain(self.nativeOutput?.controls.muted == false ? 1 : 0)
                            self.state = .active(format)
                        }
                    }
                    if !self.usable { try await Task.sleep(for: .milliseconds(100)) }
                }
                if self.sessionID == identifier { self.readinessTask = nil }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == identifier else { return }
                if error is ControlError, self.isRecovering, !self.hasOtherMusicSource {
                    self.beginRecovery(reason: error.localizedDescription)
                    self.session?.recoverConnection(reason: error.localizedDescription)
                } else { self.fail(error.localizedDescription) }
            }
        }
    }

    private func controlsChanged() {
        guard state != .stopping else { return }
        if let request = connectionModeRestoreID, let headphones,
           headphones.lastConnectionModeChangeID != request
            || (connectionModeConfirmed && headphones.connectionMode != nil && headphones.connectionMode != .soundQuality) {
            connectionModeRestoreID = nil
        }
        if let address = targetAddress, let headphones, devices?.controller(for: address) !== headphones {
            fail("The Sony headphone controller changed. LDAC stopped.")
            return
        }
        if hasOtherMusicSource {
            suspend(reason: "another headphone music source is active")
            return
        }
        guard controlSession != nil else { return }
        guard bindingIsCurrent else {
            beginRecovery(reason: "Sony music controls temporarily disconnected.")
            session?.recoverConnection(reason: "Sony music controls temporarily disconnected.")
            return
        }
        if pendingVolume == nil, volumeTask == nil, let headphones,
           let range = volumeRange, let volume = headphones.playback.volume {
            do { try nativeOutput?.configure(volume: volume, range: range) }
            catch { fail(error.localizedDescription) }
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
                }
            }
            do {
                while let volume = self.pendingVolume {
                    try Task.checkCancellation()
                    guard self.bindingIsCurrent, let headphones = self.headphones,
                          self.volumeRange?.contains(volume) == true else {
                        throw ControlError("The headphone music volume controls became unavailable. LDAC stopped.")
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
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard self.sessionID == identifier, self.bindingIsCurrent, headphones.playback.volume == volume else {
                        throw ControlError("The headphones did not confirm the requested native volume. LDAC stopped.")
                    }
                    self.record("volume-confirmed", reason: "confirmed=\(volume)")
                    if self.pendingVolume == nil, let range = self.volumeRange {
                        try self.nativeOutput?.configure(volume: volume, range: range)
                    }
                }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == identifier, self.volumeTaskID == volumeIdentifier else { return }
                if !self.bindingIsCurrent, !self.hasOtherMusicSource, self.state != .stopping {
                    self.beginRecovery(reason: error.localizedDescription)
                    self.session?.recoverConnection(reason: error.localizedDescription)
                } else { self.fail(error.localizedDescription) }
            }
        }
    }

    private func setOutputGain(_ gain: Double) {
        guard requestedOutputGain != gain else { return }
        requestedOutputGain = gain
        record("gain-requested", reason: "gain=\(gain) usable=\(usable) userMuted=\(nativeOutput?.controls.muted ?? true)")
        session?.updateGain(gain)
    }

    private func fail(_ message: String) {
        guard state != .stopping else { return }
        record("failed", reason: "\(message); \(musicControlStatus)")
        volumeError = message
        requestedAddress = nil
        stopSession(reason: "coordinator failed: \(message)")
    }

    private func beginRecovery(reason: String) {
        guard requestedAddress == targetAddress, requestedAddress != nil, state != .stopping else { return }
        record("recovering", reason: reason)
        if let stableSince, Date().timeIntervalSince(stableSince) >= 30 { recoveryAttempt = 0 }
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
        actualOutputGain = 0
    }

    private func scheduleRecovery(_ address: String) {
        guard recoveryTask == nil else { return }
        let identifier = sessionID
        let delay = ReconnectBackoff.delay(forAttempt: recoveryAttempt)
        recoveryAttempt = min(recoveryAttempt + 1, 5)
        record("retry-scheduled", reason: "delay=\(delay)")
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, self.sessionID == identifier, self.requestedAddress == address,
                      self.isRecovering, self.state != .stopping, let output = self.nativeOutput else { return }
                try output.validateForRecovery()
                if self.hasOtherMusicSource {
                    self.suspend(reason: "another headphone music source is active")
                    return
                }
                let priority = try output.prepareForReconnect()
                self.initialReadbackID = self.headphones?.musicVolumeReadbackID
                self.recoveryTask = nil
                self.sessionID = UUID()
                self.requestedOutputGain = 0
                self.launch(address, priority: priority)
            } catch is CancellationError {
            } catch {
                guard let self, self.sessionID == identifier else { return }
                self.recoveryTask = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    private func stopSession(restoreAudio: Bool = true, reason: String) {
        record("stopping", reason: "\(reason); restoreAudio=\(restoreAudio) usable=\(usable) requestedGain=\(requestedOutputGain); \(musicControlStatus)")
        restoreAudioOnStop = restoreAudioOnStop && restoreAudio
        guard cleanupTask == nil else { return }
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
        if let session { session.stop(restoreAudio: restoreAudio) }
        else if let startTask { startTask.cancel() }
        else if isRecovering, restoreAudioOnStop, let address = targetAddress {
            sessionID = UUID()
            launch(address, priority: nil, restoringOnly: true)
        } else { finish(nil) }
    }

    private func finish(_ message: String?, targetDisconnected: Bool = false) {
        guard cleanupTask == nil else { return }
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
            let disconnected = targetDisconnected || self.devices?.isSystemSleeping == true
            let restoreError = await output?.restoreAndRelease(targetDisconnected: disconnected)
            let connectionRestoreError: String?
            if disconnected || self.suspensionRequested {
                if let address = self.targetAddress, let request = self.connectionModeRestoreID {
                    self.deferredConnectionModes[address] = request
                }
                self.connectionModeRestoreID = nil
                self.connectionModeConfirmed = false
                connectionRestoreError = nil
            } else {
                connectionRestoreError = await self.restoreConnectionMode()
            }
            self.record("restored", reason: restoreError ?? "routes restored and output lease released")
            self.nativeOutput = nil
            self.outputID = nil
            self.headphones = nil
            self.transportFormat = nil
            self.controlSession = nil
            self.sourceAddress = nil
            self.volumeRange = nil
            self.pendingVolume = nil
            self.initialReadbackID = nil
            self.actualOutputGain = 0
            self.requestedOutputGain = 0
            self.isSessionRunning = false
            self.isRecovering = false
            self.stableSince = nil
            if self.audioCaptureAccess == .checking { self.audioCaptureAccess = .unchecked }
            let messages = [message, self.volumeError, restoreError, connectionRestoreError].compactMap { $0 }
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

    private func record(_ event: String, reason: String) {
        Self.logger.notice("LDAC controller \(event, privacy: .public); target=\(self.targetAddress ?? "none", privacy: .private(mask: .hash)) session=\(self.sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .private)")
    }

    private func completeStop() {
        let completions = stopCompletions
        stopCompletions = []
        for completion in completions { completion() }
    }

    private struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
}
#endif
