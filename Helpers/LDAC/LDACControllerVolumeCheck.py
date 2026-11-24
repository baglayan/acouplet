import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[2]
source = (root / "Sources/LDACController.swift").read_text()
output_source = (root / "Sources/LDACNativeOutput.swift").read_text()
installer = (root / "Sources/LDACDriverInstaller.swift").read_text()
driver_states = installer[installer.index("    enum State:"):installer.index("    private static let minimumStreamingRevision")]


def member(name):
    match = re.search(r"^    (?:private )?(?:func|var) " + name + r"\b", source, re.MULTILINE)
    end = re.search(r"^    (?:(?:private )?(?:func|var|struct) |#(?:if|endif)\b)", source[match.end():], re.MULTILINE)
    return re.sub(r"^    private ", "    ", source[match.start():match.end() + end.start()], flags=re.MULTILINE)


volume = output_source[output_source.index("struct LDACNativeVolume:"):output_source.index("\nstruct LDACRouteRecovery")]
transfer = output_source[output_source.index("    nonisolated static func canTransferControls("):output_source.index("    func claim(")]
fixture = r'''
import Foundation
import Combine
import CoreAudio

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Fixture assertion failed") {
    if !condition() {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
        exit(1)
    }
}

enum Generation { case v1, v2 }
enum Model { case unknown, wfXM3, whCH720N, whXM4, wfXM5; var name: String { "fixture" } }
struct LDACFormat: Equatable { var value = 1 }
enum LDACState: Equatable { case off, requested, waitingForDevice, waitingForMac, connecting, active(LDACFormat), stopping, failed(String) }
enum LDACAudioCaptureAccess { case unchecked, checking, ready, permissionRequired }
enum LDACQuality { case connection, balanced, quality, adaptive }
typealias LDACSampleRate = Int
extension LDACSampleRate { var displayName: String { String(self) } }
struct LDACConfiguration: Equatable { var sampleRate = 48000; var quality = LDACQuality.connection }
struct LDACPriorityControl {}
struct LDACPriorityCleanupError: Error {}
struct LDACOwnerError: Error {
    var outputDeselected = false
    var captureAccess: LDACAudioCaptureAccess? = nil
}
extension LDACOwnerError {
    init(_ error: LDACOutputDeselectedError) { self.init(outputDeselected: true) }
}
enum SonyBLEIdentity { static func normalizedAddress(_ address: String) -> String? { address.uppercased() } }
struct IOBluetoothDevice {
    init?(addressString: String) {}
    func isClassicConnected() -> Bool { true }
}
struct IOBluetoothHostController {
    static func `default`() -> Self? { Self() }
    func addressAsString() -> String { "02:00:00:00:00:02" }
}
enum ReconnectBackoff { static func delay(forAttempt: Int) -> Double { 0 } }
enum SonyConnectionMode { case soundQuality, stableConnection, lowLatency }
struct ConnectionTransition {
    enum Phase { case awaitingResponse, awaitingUser, recovering, confirmed, cancelled, failed, pairingRequired }
    var phase: Phase
    var isFinished: Bool { [.confirmed, .cancelled, .failed].contains(phase) }
    var awaitingUser: Bool { phase == .awaitingUser }
}
struct Route { var uid: String? }
struct EarbudFinder {
    var isBusy: Bool
    var mayBeRinging: Bool
}
@MainActor
final class MacAudioRouteObserver {
    var route: Route? = Route(uid: "fixture-headphones")
    var currentOutputUID: String?
    var currentOutputTransport = kAudioDeviceTransportTypeBluetooth
    func isDefaultOutput(_ uid: String, transport: UInt32? = nil) -> Bool {
        (currentOutputUID ?? route?.uid) == uid && (transport == nil || transport == currentOutputTransport)
    }
}
@MainActor
enum LDACDriverInstaller {
__DRIVER_STATES__
    static func inspect(bundle: Bundle) -> State { .current }
}

__VOLUME__

struct MenuBarHeadphoneControls {
    init(_ headphones: SonyHeadphonesController) {}
}

@MainActor
final class SonyHeadphonesController: ObservableObject {
    enum Setting { case playbackVolume }
    struct Playback {
        var generation = Generation.v1
        var isSupported = true
        var hasReceivedCapabilities = true
        var musicVolumeRange: ClosedRange<Int>? = 0...30
        var volume: Int? = 12
        var supportsMute = false
        var musicMuted: Bool?
        var callMuted: Bool?
    }
    struct Source { var address: String; var isConnected = true }
    struct Multipoint {
        var selectedSource: Source?
        var inventoryIsStale = false
        var supportsInventory = true
        var devices: [Source] = []
        var keeping: Bool? = false
        func sourceSwitchPayload(address: String) -> [UInt8]? {
            guard !inventoryIsStale, keeping != nil, devices.contains(where: { $0.address == address && $0.isConnected }) else { return nil }
            return [0x3C, 0x01] + Array(address.utf8)
        }
    }
    struct VolumeWrite { let volume: Int; let isCurrent: (() -> Bool)? }
    var deviceModel = Model.whXM4
    var address = "02:00:00:00:00:01"
    @Published var playback = Playback()
    var multipoint = Multipoint()
    var earbudFinder: EarbudFinder?
    var isReady = true
    enum LinkState { case disconnected, opening, handshaking, ready, controlBusy }
    var linkState = LinkState.ready
    var hasCachedControlChannel = true
    var coldControlReopens = 0
    var isDeviceConnected = true
    var hasCurrentTable2Capabilities = true
    var supportsConnectionMode = true
    var ldacRequiresMultipointOff = false
    enum PreparationIssue {
        case selectMac(Source?)
        var message: String { "Select this Mac" }
    }
    struct SourceTransition {
        enum Phase { case queued, awaitingSelection, queuedReadback, verifying, complete, failed }
        var phase = Phase.queued
        var isFinished: Bool { phase == .complete || phase == .failed }
        var requestID = UUID()
        var session: UInt64
        var targetAddress: String?
        var failureMessage: String?
    }
    var preparationIssue: PreparationIssue?
    var sourceControlUnavailableReason: String?
    @Published var sourceTransition: SourceTransition?
    var sourceRequests: [String] = []
    var sourceUnlocks = 0
    var defersSourceWrite = false
    static var sourceSelectionTimeout: TimeInterval = 10
    var pendingSourceWrite: (() -> Void)?
    var playbackSourceGeneration: UInt64 = 0
    let musicSourceConfirmations = PassthroughSubject<Source?, Never>()
    func ldacPreparationIssue(for address: String?) -> PreparationIssue? { preparationIssue }
    func selectAudioSource(_ source: Source, isCurrent: (() -> Bool)? = nil) {
        let transition = SourceTransition(session: notificationSession, targetAddress: source.address)
        sourceTransition = transition
        if multipoint.keeping == true { sourceUnlocks += 1; return }
        let write = { [weak self] in
            guard let self, self.isQueuedAudioSourceSelection(transition.requestID) else { return }
            guard isCurrent?() != false else {
                self.sourceTransition?.phase = .failed
                return
            }
            self.sourceRequests.append(source.address)
            self.sourceTransition?.phase = .awaitingSelection
        }
        if defersSourceWrite { pendingSourceWrite = write }
        else { write() }
    }
    func isQueuedAudioSourceSelection(_ request: UUID) -> Bool {
        sourceTransition?.requestID == request && sourceTransition?.phase == .queued
    }
    func cancelQueuedAudioSourceSelection(_ request: UUID, expired: Bool) {
        guard isQueuedAudioSourceSelection(request) else { return }
        sourceTransition?.phase = .failed
        sourceTransition?.failureMessage = expired ? "The source selection timed out" : "The source selection was cancelled"
    }
    func reportAudioSource(_ source: Source?) {
        if multipoint.selectedSource?.address != source?.address { playbackSourceGeneration += 1 }
        multipoint.selectedSource = source
    }
    func reportMusicSource(_ source: Source?) {
        objectWillChange.send()
        let changed = multipoint.selectedSource?.address != source?.address
        reportAudioSource(source)
        localSource = source?.address == "02:00:00:00:00:02"
        if changed {
            statusFresh = false
            volumeFresh = false
            musicStatusReadbackID = nil
            musicVolumeReadbackID = nil
        }
    }
    func confirmMusicSource(_ source: Source?) {
        reportMusicSource(source)
        if source != nil, source?.address == sourceRequests.last,
           sourceTransition?.phase == .awaitingSelection || sourceTransition?.phase == .verifying {
            sourceTransition?.phase = .complete
        }
        musicSourceConfirmations.send(source)
    }
    func confirmAudioSource(_ source: Source) {
        reportAudioSource(source)
        sourceTransition?.phase = .complete
        preparationIssue = nil
        localSource = true
    }
    @Published var connectionMode: SonyConnectionMode? = .soundQuality
    @Published var connectionTransition: ConnectionTransition?
    var lastConnectionModeChangeID: UUID?
    var connectionModeError: String?
    var connectionRequests: [SonyConnectionMode] = []
    var notificationSession: UInt64 = 1
    var capabilityFresh = true
    var lastReadyMenuBarControls: MenuBarHeadphoneControls?
    var statusFresh = true
    var volumeFresh = true
    var playbackAvailable = true
    var statusReadPending = false
    var volumeReadPending = false
    var localSource = true
    @Published var musicVolumeReadbackID: UUID? = UUID()
    @Published var musicStatusReadbackID: UUID? = UUID()
    var refreshes = 0
    var settingsRefreshes = 0
    var volumeRefreshes = 0
    var requiredMusicVolumeReadTimedOut = false
    var optionalReadTimedOut = false
    var allowsVolumeRecovery = true
    var volumeRecoveryAttempts = 0
    var volumeRecoveries = 0
    @Published var queuedWrite: VolumeWrite?
    var blocksPlaybackCommands = false
    var transmitted: [Int] = []
    var continuation: CheckedContinuation<Void, Error>?
    private var hasCurrentMusicVolumeData: Bool { isReady && !requiredMusicVolumeReadTimedOut && capabilityFresh && statusFresh && volumeFresh && playback.volume != nil }
    var hasCurrentMusicVolumeRead: Bool { hasCurrentMusicVolumeData && !blocksPlaybackCommands && queuedWrite == nil }
    var hasFreshReadableMusicVolumeReadback: Bool {
        hasCurrentMusicVolumeRead && musicStatusReadbackID != nil && musicVolumeReadbackID != nil && !statusReadPending && !volumeReadPending
    }
    var hasCurrentMusicVolumeControl: Bool { hasCurrentMusicVolumeData && playbackAvailable }
    var hasFreshMusicVolumeReadback: Bool { hasCurrentMusicVolumeControl && canControlMusicVolume && !statusReadPending && !volumeReadPending }
    var canControlMusicVolume: Bool { hasCurrentMusicVolumeControl && !blocksPlaybackCommands && queuedWrite == nil }
    func hasCurrentMusicSourceContext(for address: String?) -> Bool { localSource }
    func connectionModeUnavailableReason(_ mode: SonyConnectionMode) -> String? { nil }
    func setConnectionMode(_ mode: SonyConnectionMode) {
        guard mode != connectionMode, connectionTransition?.isFinished != false else { return }
        connectionRequests.append(mode)
        lastConnectionModeChangeID = UUID()
        connectionTransition = ConnectionTransition(phase: .awaitingResponse)
    }
    func retryConnectionModeChange(expectedRequestID: UUID) -> Bool { false }
    func confirmConnectionMode(_ mode: SonyConnectionMode) {
        connectionMode = mode
        connectionTransition = ConnectionTransition(phase: .confirmed)
    }
    func canPerformConfirmedSettingChange(_ setting: Setting) -> Bool { isReady && !blocksPlaybackCommands && queuedWrite == nil }
    func refresh() { refreshes += 1 }
    func retryControlsIfNeeded(forColdLDAC: Bool = false) -> Bool {
        guard forColdLDAC, linkState == .disconnected || linkState == .controlBusy, hasCachedControlChannel else { return false }
        coldControlReopens += 1
        linkState = .opening
        return true
    }
    func requestCurrentSettings() { settingsRefreshes += 1; statusReadPending = true; volumeReadPending = true }
    func recoverMusicVolumeIfNeeded() -> Bool {
        volumeRecoveryAttempts += 1
        guard requiredMusicVolumeReadTimedOut, allowsVolumeRecovery, isReady else { return false }
        volumeRecoveries += 1
        notificationSession += 1
        isReady = false
        requiredMusicVolumeReadTimedOut = false
        capabilityFresh = false
        statusFresh = false
        volumeFresh = false
        musicVolumeReadbackID = nil
        musicStatusReadbackID = nil
        return true
    }
    @discardableResult
    func refreshMusicVolume() -> Bool {
        guard isReady else { return false }
        volumeRefreshes += 1
        statusReadPending = true
        volumeReadPending = true
        return true
    }
    func receiveStatus() { statusFresh = true; statusReadPending = false; musicStatusReadbackID = UUID() }
    func receiveVolume(_ volume: Int = 12) { volumeFresh = true; volumeReadPending = false; playback.volume = volume; musicVolumeReadbackID = UUID() }
    func notifyVolume(_ volume: Int, muted: Bool?) { playback.volume = volume; playback.musicMuted = muted }
    func performConfirmedSettingChange(_ setting: Setting, change: () -> Void) async throws {
        try Task.checkCancellation()
        change()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in
                let waiter = self.continuation
                self.continuation = nil
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
    func setPlaybackVolume(_ volume: Int, isCurrent: (() -> Bool)? = nil) {
        precondition(queuedWrite == nil)
        queuedWrite = VolumeWrite(volume: volume, isCurrent: isCurrent)
    }
    func transmitVolume() {
        guard let write = queuedWrite else { return }
        if write.isCurrent?() == false {
            queuedWrite = nil
            let waiter = continuation
            continuation = nil
            waiter?.resume(throwing: CancellationError())
        } else { transmitted.append(write.volume) }
    }
    func confirmVolume() {
        guard let write = queuedWrite else { return }
        precondition(transmitted.last == write.volume)
        playback.volume = write.volume
        queuedWrite = nil
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }
}

typealias SonyMultipointDevice = SonyHeadphonesController.Source

@MainActor
final class SonyDeviceCoordinator: ObservableObject {
    var controllers: [String: SonyHeadphonesController] = [:]
    @Published var isSystemSleeping = false
    var selectedAddress: String? = "02:00:00:00:00:01"
    func controller(for address: String) -> SonyHeadphonesController? { controllers[address] }
}

@MainActor
final class LDACNativeOutput {
    nonisolated static let uid = "fixture-output"
    var controls = LDACNativeVolume(scalar: 0.8, muted: false)
    var ready = false
    var selected = false
    var selections = 0
    var selectionError: Error?
    var didSelect: (() -> Void)?
    var preparations = 0
    var silences = 0
    var configurations = 0
    var recoveryPreparations = 0
    var blocksConfiguration = false
    var configurationWaiter: CheckedContinuation<Void, Never>?
    var blocksPreparation = false
    var preparationWaiter: CheckedContinuation<Void, Never>?
    var blocksClaim = false
    var claimWaiter: CheckedContinuation<Void, Never>?
    var claimError: Error?
    var claims: [Bool] = []
    var expectedDefaultOutputUIDs: [String?] = []
    var savedDefaultOutputUID: String? = "fixture-headphones"
    var permissionWaiter: CheckedContinuation<Void, Never>?
    var permissionError: Error?
    var blocksPermission = false
    var permissionChecks: [Int] = []
    var priorityRequests = 0
    var restores: [Bool] = []
    var restoredHeadphoneOutputs: [Bool] = []
    var restoreError: String?
    var parkRequests = 0
    var resumeRequests = 0
    var parkResult = true
    var parkError: Error?
    var blocksPark = false
    var parkWaiter: CheckedContinuation<Void, Never>?
    var didPark: (() -> Void)?
    var didResume: (() -> Void)?
    let changed: (Result<LDACNativeVolume, Error>) -> Void
    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) { self.changed = changed }
    func simulateControls(_ controls: LDACNativeVolume) { self.controls = controls; changed(.success(controls)) }
    __TRANSFER__
    func claim(model: String, targetAddress: String, sampleRate: Int, requiresIdlePriority: Bool = false,
               expectedDefaultOutputUID: String? = nil) async throws {
        claims.append(requiresIdlePriority)
        expectedDefaultOutputUIDs.append(expectedDefaultOutputUID)
        if blocksClaim { await withCheckedContinuation { claimWaiter = $0 } }
        try Task.checkCancellation()
        if let claimError { throw claimError }
    }
    func checkCapturePermission(at sampleRate: Int) async throws {
        permissionChecks.append(sampleRate)
        if blocksPermission { await withCheckedContinuation { permissionWaiter = $0 } }
        try Task.checkCancellation()
        if let permissionError { throw permissionError }
    }
    func priorityControl() async throws { priorityRequests += 1 }
    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) async throws {
        configurations += 1
        if blocksConfiguration { await withCheckedContinuation { configurationWaiter = $0 } }
        if !preservingUserChange { _ = controls.update(volume: volume, range: range) }
    }
    func validateForRecovery() async throws {}
    func prepareForReconnect() async throws { recoveryPreparations += 1 }
    func selectForHandoff() async throws {
        if let selectionError { throw selectionError }
        if selected { return }
        selected = true
        selections += 1
        didSelect?()
    }
    func parkForPhone() async throws -> Bool {
        parkRequests += 1
        if blocksPark { await withCheckedContinuation { parkWaiter = $0 } }
        try Task.checkCancellation()
        if let parkError { throw parkError }
        if parkResult {
            ready = false
            selected = false
            didPark?()
        }
        return parkResult
    }
    func resumeFromPhone() async throws {
        resumeRequests += 1
        selected = true
        didResume?()
    }
    func finishPreparation() async throws {
        ready = true
        preparations += 1
        if blocksPreparation { await withCheckedContinuation { preparationWaiter = $0 } }
    }
    func silence() { ready = false; silences += 1 }
    func restoreAndRelease(targetDisconnected: Bool = false, restoreHeadphoneOutput: Bool = true) async -> String? {
        restores.append(targetDisconnected)
        restoredHeadphoneOutputs.append(restoreHeadphoneOutput)
        ready = false
        selected = false
        return restoreError
    }
}

typealias LDACOwnerOutput = LDACNativeOutput
typealias LDACOwnerSession = LDACNativeSession

@MainActor
final class LDACNativeSession {
    struct Helpers { var isAvailable = true }
    struct Diagnostic { var stage: String; var detail: String; var isFailure = false }
    struct Completion { var message: String?; var canRetry = false; var requiresAttention = false; var targetDisconnected = false; var waitForReconnect = false }
    enum Event {
        case diagnostic(Diagnostic)
        case handoffReady, connecting, ownedMediaReady, active(LDACFormat), warmHeld, warmCaptureReady(UUID), warmResumed(LDACFormat), formatChanged(LDACFormat), gainApplied(Double)
        case sampleRateChangeRejected(requested: LDACSampleRate, active: LDACSampleRate)
        case sampleRateChangeDeferred(requested: LDACConfiguration, active: LDACSampleRate)
        case audioCaptureAccess(LDACAudioCaptureAccess), failed(String), connectionLost(String), finished(Completion)
    }
    let id: UUID
    let address: String
    let restoringOnly: Bool
    let receive: (Event) -> Void
    var gains: [Double]
    var configurations: [LDACConfiguration] = []
    var stops = 0
    var recoveries: [String] = []
    var audioRestorations: [Bool] = []
    var handoffs = 0
    var parkRequests = 0
    var resumeRequests = 0
    var parkedStartAuthorizations: [UUID] = []
    init(id: UUID, address: String, helpers: Helpers, gain: Double, outputDeviceUID: String,
         priority: LDACPriorityControl?, configuration: LDACConfiguration, recoveryAttempt: Bool,
         restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.id = id
        self.address = address
        self.restoringOnly = restoringOnly
        self.receive = receive
        gains = [gain]
    }
    convenience init(id: UUID, output: LDACNativeOutput, configuration: LDACConfiguration,
                     recoveryAttempt: Bool, restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.init(id: id, address: "02:00:00:00:00:01", helpers: Helpers(), gain: 0,
                  outputDeviceUID: LDACNativeOutput.uid, priority: nil, configuration: configuration,
                  recoveryAttempt: recoveryAttempt, restoringOnly: restoringOnly, receive: receive)
    }
    func start() {}
    func emit(_ event: Event) { receive(event) }
    func allowHandoff() { handoffs += 1 }
    func park() { parkRequests += 1 }
    func resumeParkedStream() { resumeRequests += 1 }
    func allowParkedStart(_ authorization: UUID) { parkedStartAuthorizations.append(authorization) }
    func updateGain(_ gain: Double) { gains.append(gain) }
    func updateConfiguration(_ configuration: LDACConfiguration) { configurations.append(configuration) }
    func stop(restoreAudio: Bool) { stops += 1; audioRestorations.append(restoreAudio) }
    func recoverConnection(reason: String) { recoveries.append(reason) }
    func verifyConnectionLoss(reason: String) {}
}

@MainActor
final class Controller: ObservableObject {
    var state = LDACState.off
    var targetAddress: String?
    var menuBarControlOrigin: (controller: ObjectIdentifier, session: UInt64)?
    var menuBarControlsAtHandoff: MenuBarHeadphoneControls?
    var isSessionRunning = false
    var isRecovering = false
    var audioCaptureAccess = LDACAudioCaptureAccess.unchecked
    var session: LDACNativeSession?
    var sessionID = UUID()
    var requestedAddress: String?
    var requestedConfiguration = LDACConfiguration()
    var diagnosticAttempt = 0
    var nativeOutput: LDACNativeOutput? {
        didSet {
            nativeOutput?.didSelect = { [weak self] in self?.audioRoute?.currentOutputUID = LDACNativeOutput.uid }
            nativeOutput?.didPark = { [weak self] in
                let uid = self?.nativeOutput?.savedDefaultOutputUID
                self?.audioRoute?.route = Route(uid: uid)
                self?.audioRoute?.currentOutputUID = uid
            }
            nativeOutput?.didResume = { [weak self] in
                self?.audioRoute?.route = Route(uid: LDACNativeOutput.uid)
                self?.audioRoute?.currentOutputUID = LDACNativeOutput.uid
            }
        }
    }
    var outputID: UUID?
    var headphones: SonyHeadphonesController?
    let bundle = Bundle.main
    let inspectDriver: (Bundle) -> LDACDriverInstaller.State = { LDACDriverInstaller.inspect(bundle: $0) }
    var isClassicConnected: (String) -> Bool = { _ in true }
    var driverState = LDACDriverInstaller.State.current
    var audioRoute: MacAudioRouteObserver? = MacAudioRouteObserver()
    let localBluetoothAddress = { IOBluetoothHostController.default()?.addressAsString() }
    var resumeOutputUID: String?
    var suspensionRequested = false
    var multipointConflictAddress: String?
    var multipointConflictConfiguration: LDACConfiguration?
    var multipointShutdownAddress: String?
    var multipointShutdownTask: Task<Void, Never>?
    var multipointShutdownRequestID: UUID?
    var preparationTask: Task<Void, Never>?
    var isPreparingSourceChange = false
    var startupSourceReturn: (source: String, session: UInt64, generation: UInt64, request: UUID)?
    var pendingStartupSourceSelection: (source: String, mac: String, session: UInt64, generation: UInt64,
                                        request: UUID, deadline: ContinuousClock.Instant, outputDeselected: Bool)?
    func confirmPendingMultipointAlert() {}
    var pendingConnectionModes: [String: UUID] = [:]
    var deferredConnectionModes: [String: UUID] = [:]
    var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    var connectionModeRestoreID: UUID?
    var connectionModeConfirmed = false
    var controlObservation: AnyCancellable?
    enum PhoneHandoffPhase { case suspending, yieldingOutput, held, selectingOutput, restarting, confirmingVolume }
    var phoneHandoff: (peer: String, session: UInt64, generation: UInt64, confirmed: Bool, returned: Bool, phase: PhoneHandoffPhase)?
    var phoneSourceObservation: AnyCancellable?
    var phoneHandoffTask: Task<Void, Never>?
    var phoneVolumeWakeup: Task<Void, Never>?
    var pendingPhoneSelection: SonyMultipointDevice?
    var phoneSourceRequest: UUID?
    var phoneSelectionAuthorization: (id: UUID, request: UUID?, output: String, deadline: ContinuousClock.Instant, isCurrent: () -> Bool)?
    var deselectedSourceObservation: AnyCancellable?
    var deselectedSourceReturn: (controller: ObjectIdentifier, session: UInt64, generation: UInt64)?
    var sourceResumeOutputUID: String?
    var startTask: Task<Void, Never>?
    var readinessTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var volumeTaskID: UUID?
    var cleanupTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var recoveryAttempt = 0
    var recoveryPaused = false
    var recoveryResumeContext: (controller: ObjectIdentifier, observedConnected: Bool, observedDisconnect: Bool)?
    var restoreAudioOnStop = true
    var stableSince: Date?
    var pendingVolume: Int?
    var lastNativeVolumeScalar: Float32?
    var nativeVolumeChangeID = UUID()
    var initialReadbackID: UUID?
    var controlSession: UInt64?
    var sourceAddress: String?
    var volumeRange: ClosedRange<Int>?
    var transportFormat: LDACFormat?
    var usable = false
    var requestedOutputGain = 0.0
    var volumeError: String?
    var sampleRateChangeError: String?
    var restoredRates: [LDACSampleRate] = []
    func restoreSampleRate(_ rate: LDACSampleRate) { restoredRates.append(rate) }
    var stopCompletions: [@MainActor () -> Void] = []
    let helpers = LDACNativeSession.Helpers()
    var devices: SonyDeviceCoordinator? = SonyDeviceCoordinator()
    func recordOutputFailure(_ error: Error) {}
    func recordNativeDiagnostic(_ diagnostic: LDACNativeSession.Diagnostic) {}
    var events: [String] = []
    func record(_ event: String, reason: String) { events.append(event) }
    __METHODS__
    struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String, userFacing: String? = nil) { self.message = userFacing ?? message }
    }
}

@main
enum Check {
    @MainActor
    static func waitUntil(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(false, "Production controller did not reach the expected fixture state at line \(line)")
    }

    @MainActor
    static func started(_ generation: Generation = .v1, supportsMute: Bool = false, musicMuted: Bool? = nil,
                        playbackAvailable: Bool = true, initialRouteUID: String = "fixture-headphones",
                        initialSource: SonyMultipointDevice? = nil) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let controller = Controller()
        let headphones = SonyHeadphonesController()
        headphones.playback.generation = generation
        headphones.playback.supportsMute = supportsMute
        headphones.playback.musicMuted = musicMuted
        headphones.playbackAvailable = playbackAvailable
        headphones.localSource = generation == .v2
        headphones.multipoint.selectedSource = initialSource
        controller.devices?.controllers[headphones.address] = headphones
        controller.audioRoute?.route = Route(uid: initialRouteUID)
        controller.requestedAddress = headphones.address
        controller.start(headphones.address)
        try await waitUntil { headphones.volumeRefreshes == 1 || headphones.refreshes != 0 }
        precondition(headphones.refreshes == 0 && controller.session == nil,
                     "LDAC startup refreshed unrelated settings or admitted stale volume")
        headphones.receiveVolume()
        try await Task.sleep(for: .milliseconds(120))
        precondition(controller.session == nil, "LDAC startup admitted volume without fresh status")
        headphones.receiveStatus()
        try await waitUntil { controller.session != nil }
        headphones.volumeRefreshes = 0
        controller.nativeOutput?.savedDefaultOutputUID = initialRouteUID
        return (controller, headphones, controller.nativeOutput!, controller.session!)
    }

    @MainActor
    static func stop(_ controller: Controller) async throws {
        controller.stop(restoreAudio: false, reason: "fixture complete")
        controller.session?.emit(.finished(.init(message: nil)))
        try await waitUntil { !controller.isSessionRunning }
    }

    @MainActor
    static func startedWithSourceHandoff() async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession, SonyMultipointDevice) {
        let controller = Controller()
        let device = SonyHeadphonesController()
        let mac = SonyMultipointDevice(address: "02:00:00:00:00:02")
        let phone = SonyMultipointDevice(address: "02:00:00:00:00:03")
        device.playback.generation = .v2
        device.localSource = false
        device.multipoint.selectedSource = phone
        device.multipoint.devices = [mac, phone]
        device.preparationIssue = .selectMac(mac)
        controller.devices?.controllers[device.address] = device
        controller.requestedAddress = device.address
        controller.start(device.address, selectingSource: mac)
        try await waitUntil { device.sourceRequests == [mac.address] }
        device.confirmAudioSource(mac)
        try await waitUntil { device.statusReadPending && device.volumeReadPending }
        device.receiveStatus()
        device.receiveVolume()
        try await waitUntil { controller.session != nil }
        let raw = controller.session!
        raw.emit(.handoffReady)
        try await waitUntil { raw.handoffs == 1 }
        precondition(controller.startupSourceReturn?.source == phone.address)
        return (controller, device, controller.nativeOutput!, raw, phone)
    }

    @MainActor
    static func active(_ generation: Generation, initialRouteUID: String = "fixture-headphones",
                       initialSource: SonyMultipointDevice? = nil) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let (controller, headphones, output, raw) = try await started(generation, initialRouteUID: initialRouteUID, initialSource: initialSource)
        raw.emit(.handoffReady)
        try await waitUntil { raw.handoffs == 1 }
        raw.emit(.active(LDACFormat()))
        try await waitUntil { headphones.volumeRefreshes == 1 || headphones.refreshes != 0 }
        precondition(generation == .v1 || headphones.refreshes == 0,
                     "Ready modern controls used destructive full refresh")
        headphones.receiveStatus()
        headphones.receiveVolume()
        try await waitUntil { headphones.queuedWrite != nil }
        headphones.transmitVolume()
        headphones.confirmVolume()
        try await waitUntil { controller.usable }
        return (controller, headphones, output, raw)
    }

    @MainActor
    static func checkPhoneHandoffs() async throws {
        let mac = SonyMultipointDevice(address: "02:00:00:00:00:02")
        let phone = SonyMultipointDevice(address: "02:00:00:00:00:03")
        let other = SonyMultipointDevice(address: "02:00:00:00:00:04")
        let original = "02:00:00:00:00:01:output"
        func startedHandoff() async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
            let (controller, device, output, raw) = try await active(.v2, initialRouteUID: original, initialSource: mac)
            device.multipoint.devices = [mac, phone, other]
            precondition(raw.gains.last == 1 && output.selected && output.ready)
            device.confirmMusicSource(phone)
            precondition(raw.gains.last == 0 && !output.ready, "A confirmed phone selection did not synchronously mute LDAC")
            try await waitUntil { raw.parkRequests == 1 }
            precondition(raw.stops == 0 && raw.recoveries.isEmpty && output.parkRequests == 0,
                         "A confirmed phone source tore down or moved the route before native suspension")
            return (controller, device, output, raw)
        }

        for timing in ["held", "during HAL park", "before native hold"] {
            let (controller, device, output, raw) = try await startedHandoff()
            device.musicSourceConfirmations.send(phone)
            precondition(raw.parkRequests == 1 && raw.resumeRequests == 0, "A duplicate phone notification restarted suspension")
            let writes = device.transmitted
            let claimed = output.claims
            let unrestrictedGain = raw.gains.count
            if timing == "before native hold" {
                device.confirmMusicSource(mac)
                precondition(raw.resumeRequests == 0 && output.resumeRequests == 0,
                             "Returning Mac audio resumed before native suspension")
            }
            output.blocksPark = timing == "during HAL park"
            raw.emit(.warmHeld)
            if timing == "during HAL park" {
                try await waitUntil { output.parkWaiter != nil }
                device.confirmMusicSource(mac)
                precondition(raw.resumeRequests == 0 && output.resumeRequests == 0,
                             "Returning Mac audio resumed before the parked output yielded")
                output.parkWaiter?.resume()
            } else if timing == "held" {
                try await waitUntil { controller.state == .waitingForMac && !output.selected }
                try await Task.sleep(for: .seconds(5.2))
                precondition(controller.state == .waitingForMac && controller.session === raw && controller.nativeOutput === output
                             && raw.stops == 0 && output.restores.isEmpty && raw.resumeRequests == 0,
                             "The controller expired a validated phone hold")
                precondition(device.transmitted == writes && device.sourceRequests.isEmpty && device.connectionRequests.isEmpty
                             && raw.recoveries.isEmpty && device.refreshes == 0,
                             "Waiting for the Mac sent a Sony setting or initiated a connection")
                device.confirmMusicSource(mac)
            }
            try await waitUntil { device.statusReadPending && device.volumeReadPending }
            precondition(output.resumeRequests == 0 && raw.resumeRequests == 0,
                         "Warm resume used volume cached before the Mac returned")
            device.receiveStatus()
            try await Task.sleep(for: .milliseconds(120))
            precondition(output.resumeRequests == 0 && raw.resumeRequests == 0,
                         "Warm resume started without a fresh readable volume")
            device.receiveVolume()
            try await waitUntil { output.resumeRequests == 1 && raw.resumeRequests == 1 }
            precondition(controller.session === raw && controller.nativeOutput === output && output.claims == claimed,
                         "The confirmed Mac return created a fresh owner instead of resuming the parked stream")
            precondition(raw.gains.dropFirst(unrestrictedGain).allSatisfy { $0 == 0 },
                         "Positive gain was sent before validated native resume")
            let authorization = UUID()
            raw.emit(.warmCaptureReady(authorization))
            precondition(raw.parkedStartAuthorizations == [authorization] && raw.gains.last == 0,
                         "Fresh warm prefill was not authorized at zero gain")
            raw.emit(.warmResumed(LDACFormat()))
            try await waitUntil { device.statusReadPending && device.volumeReadPending }
            device.receiveStatus()
            try await Task.sleep(for: .milliseconds(120))
            precondition(raw.gains.last == 0 && !controller.usable, "Fresh status alone enabled LDAC audio on return")
            device.blocksPlaybackCommands = true
            device.receiveVolume()
            try await Task.sleep(for: .milliseconds(120))
            precondition(raw.gains.last == 0 && !controller.usable, "Readable but unwritable volume enabled LDAC audio on return")
            device.blocksPlaybackCommands = false
            device.objectWillChange.send()
            try await waitUntil { controller.usable || device.queuedWrite != nil }
            if device.queuedWrite != nil {
                precondition(raw.gains.last == 0, "Gain preceded the resumed volume setter confirmation")
                device.transmitVolume()
                device.confirmVolume()
            }
            try await waitUntil { controller.usable && raw.gains.last == 1 }
            precondition(controller.state == .active(LDACFormat()) && output.ready && raw.parkRequests == 1
                         && raw.resumeRequests == 1 && device.sourceRequests.isEmpty && device.connectionRequests.isEmpty,
                         "Warm resumption replayed source control or failed to return the same stream")
            try await stop(controller)
        }
        print("PASS confirmed phone takeover waits with the validated owner, then resumes once with fresh writable Mac volume")

        for accepted in [true, false] {
            let (returning, returnDevice, returnOutput, returnRaw) = try await startedHandoff()
            returnRaw.emit(.warmHeld)
            try await waitUntil { returning.state == .waitingForMac }

            returning.selectAudioSource(mac, on: returnDevice)
            precondition(returnDevice.sourceRequests == [mac.address] && returnDevice.sourceTransition?.phase == .awaitingSelection)
            returnDevice.reportMusicSource(mac)
            try await Task.sleep(for: .milliseconds(120))
            precondition(returning.state == .waitingForMac && returning.session === returnRaw && returnRaw.stops == 0,
                         "The Sony picker's early Mac inventory stopped a valid warm hold")
            precondition(returnRaw.resumeRequests == 0 && returnOutput.resumeRequests == 0 && returnRaw.gains.last == 0,
                         "Mac inventory alone resumed the warm stream before the Sony picker confirmed its readback")
            if accepted {
                returnDevice.sourceTransition?.phase = .queuedReadback
                returnDevice.sourceTransition?.phase = .verifying
                try await Task.sleep(for: .milliseconds(120))
                precondition(returnRaw.stops == 0 && returnRaw.resumeRequests == 0)
                returnDevice.confirmMusicSource(mac)
                try await waitUntil { returnDevice.statusReadPending && returnDevice.volumeReadPending }
                precondition(returnRaw.resumeRequests == 0)
                returnDevice.receiveStatus()
                returnDevice.receiveVolume()
                try await waitUntil { returnRaw.resumeRequests == 1 }
                precondition(returnOutput.resumeRequests == 1 && returnRaw.stops == 0 && returnRaw.gains.last == 0)
                try await stop(returning)
            } else {
                returnDevice.sourceTransition?.phase = .failed
                try await waitUntil { returnRaw.stops == 1 }
                precondition(returnRaw.resumeRequests == 0 && returnOutput.resumeRequests == 0 && returnRaw.audioRestorations == [false])
                returnRaw.emit(.finished(.init(message: nil)))
                try await waitUntil { returnOutput.restores.count == 1 && returning.nativeOutput !== returnOutput }
                if returning.isSessionRunning { try await stop(returning) }
            }
        }
        print("PASS early Mac inventory preserves the mute and lease until the Sony picker completes or fails its owned readback")

        let (unwritten, unwrittenDevice, unwrittenOutput, unwrittenRaw) = try await startedHandoff()
        unwrittenRaw.emit(.warmHeld)
        try await waitUntil { unwritten.state == .waitingForMac }
        unwrittenDevice.defersSourceWrite = true
        unwritten.selectAudioSource(mac, on: unwrittenDevice)
        precondition(unwrittenDevice.sourceTransition?.phase == .queued && unwrittenDevice.sourceRequests.isEmpty)
        unwrittenDevice.reportMusicSource(mac)
        try await waitUntil { unwrittenRaw.stops == 1 }
        precondition(unwrittenRaw.resumeRequests == 0 && unwrittenOutput.resumeRequests == 0,
                     "An untransmitted Mac selection authorized an early inventory change")
        unwrittenRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { unwrittenOutput.restores.count == 1 && unwritten.nativeOutput !== unwrittenOutput }
        if unwritten.isSessionRunning { try await stop(unwritten) }
        print("PASS a queued local selection cannot keep a warm hold after an unconfirmed source change")

        let (requested, requestDevice, requestOutput, requestRaw) = try await active(.v2, initialRouteUID: original, initialSource: mac)
        requestDevice.multipoint.devices = [mac, phone]
        requested.selectAudioSource(phone, on: requestDevice)
        try await waitUntil { requestRaw.parkRequests == 1 }
        precondition(requestDevice.sourceRequests.isEmpty && requestRaw.gains.last == 0 && !requestOutput.ready,
                     "The source picker sent the Sony write before native pause")
        requestRaw.emit(.warmHeld)
        try await waitUntil { requestDevice.sourceRequests == [phone.address] }
        requestDevice.confirmMusicSource(phone)
        try await waitUntil { requested.state == .waitingForMac && !requestOutput.selected }
        precondition(requestRaw.parkRequests == 1 && requestDevice.sourceRequests == [phone.address]
                     && requestDevice.connectionRequests.isEmpty && requestRaw.recoveries.isEmpty)
        try await stop(requested)
        print("PASS normal source picker mutes and parks LDAC before its sole Sony phone request")

        let (deferred, deferredDevice, _, deferredRaw) = try await active(.v2, initialRouteUID: original, initialSource: mac)
        deferredDevice.multipoint.devices = [mac, phone]
        deferredDevice.defersSourceWrite = true
        deferred.selectAudioSource(phone, on: deferredDevice)
        try await waitUntil { deferredRaw.parkRequests == 1 }
        deferredRaw.emit(.warmHeld)
        try await waitUntil { deferredDevice.pendingSourceWrite != nil }
        precondition(deferredDevice.sourceRequests.isEmpty)
        deferred.stop()
        deferredDevice.pendingSourceWrite?()
        precondition(deferredDevice.sourceRequests.isEmpty, "Off did not revoke a queued explicit Sony phone selection")
        deferredRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { deferred.state == .off }
        print("PASS Off revokes a phone selection already queued for Sony transmission")

        for resolution in ["wire transmitted", "wire transmitted with error", "Off", "external output", "expired"] {
            let (cold, coldDevice, coldOutput, coldRaw) = try await active(.v2, initialRouteUID: original, initialSource: mac)
            coldDevice.multipoint.devices = [mac, phone]
            coldDevice.defersSourceWrite = true
            coldOutput.parkResult = false
            if resolution == "expired" { SonyHeadphonesController.sourceSelectionTimeout = 0.8 }
            defer { SonyHeadphonesController.sourceSelectionTimeout = 10 }
            cold.selectAudioSource(phone, on: coldDevice)
            try await waitUntil { coldRaw.parkRequests == 1 }
            coldRaw.emit(.warmHeld)
            try await waitUntil { coldRaw.stops == 1 && coldDevice.pendingSourceWrite != nil }
            precondition(coldRaw.audioRestorations == [false] && coldRaw.gains.last == 0 && coldRaw.resumeRequests == 0)
            let transportError = resolution == "wire transmitted with error" ? "Native transport cleanup failed" : nil
            coldRaw.emit(.finished(.init(message: transportError, requiresAttention: transportError != nil)))
            try await Task.sleep(for: .milliseconds(120))
            precondition(cold.nativeOutput === coldOutput && coldOutput.restores.isEmpty && !coldOutput.ready
                         && cold.audioRoute?.isDefaultOutput(LDACNativeOutput.uid) == true && coldDevice.sourceRequests.isEmpty,
                         "Cold fallback released the muted output before its queued Sony selection reached the wire")
            switch resolution {
            case "Off": cold.stop()
            case "expired":
                try await waitUntil { coldDevice.sourceTransition?.phase == .failed }
                precondition(coldDevice.sourceTransition?.failureMessage == "The source selection timed out")
            case "external output":
                cold.audioRoute?.route = Route(uid: "external-output")
                cold.audioRoute?.currentOutputUID = "external-output"
                coldOutput.changed(.failure(LDACOwnerError(outputDeselected: true)))
            default: break
            }
            coldDevice.pendingSourceWrite?()
            try await waitUntil { coldOutput.restores.count == 1 && cold.nativeOutput !== coldOutput }
            if resolution != "expired" {
                precondition(cold.nativeOutput == nil, "Cold fallback reacquired LDAC before Sony confirmed the source: \(resolution)")
            }
            precondition(coldDevice.sourceRequests == (resolution.hasPrefix("wire transmitted") ? [phone.address] : [])
                         && coldDevice.multipoint.selectedSource?.address == mac.address && coldDevice.connectionRequests.isEmpty
                         && coldOutput.restoredHeadphoneOutputs == [false],
                         "Cold fallback mishandled the queued Sony selection: \(resolution)")
            if resolution == "external output" {
                precondition(cold.audioRoute?.isDefaultOutput("external-output") == true)
            }
            if let transportError {
                precondition(cold.state == .failed(transportError), "Awaiting the Sony wire hid a raw cleanup error")
            }
            if cold.isSessionRunning { try await stop(cold) }
        }
        print("PASS cold fallback retains the muted owner through transmission, preserves raw errors, and cancels invalid writes")

        let (prefill, prefillDevice, prefillOutput, prefillRaw) = try await startedHandoff()
        prefillRaw.emit(.warmHeld)
        try await waitUntil { prefill.state == .waitingForMac }
        prefillDevice.confirmMusicSource(mac)
        try await waitUntil { prefillDevice.volumeReadPending && prefillDevice.statusReadPending }
        prefillDevice.receiveStatus()
        prefillDevice.receiveVolume()
        try await waitUntil { prefillRaw.resumeRequests == 1 }
        prefill.audioRoute?.route = Route(uid: "external-output")
        prefill.audioRoute?.currentOutputUID = "external-output"
        prefillRaw.emit(.warmCaptureReady(UUID()))
        try await waitUntil { prefillRaw.stops == 1 }
        precondition(prefillRaw.parkedStartAuthorizations.isEmpty && prefillRaw.gains.last == 0
                     && prefillRaw.audioRestorations == [false],
                     "Warm prefill authorized START after the Mac route changed")
        prefillRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { prefill.nativeOutput == nil }
        precondition(prefillOutput.restoredHeadphoneOutputs == [false]
                     && prefill.audioRoute?.isDefaultOutput("external-output") == true)
        print("PASS warm PCM prefill is independently denied if the Mac output changes before START")

        let (timeout, timeoutDevice, timeoutOutput, timeoutRaw) = try await startedHandoff()
        timeoutRaw.emit(.warmHeld)
        try await waitUntil { timeout.state == .waitingForMac }
        timeoutDevice.confirmMusicSource(mac)
        try await waitUntil { timeoutDevice.volumeReadPending && timeoutDevice.statusReadPending }
        timeoutDevice.receiveStatus()
        precondition(timeoutRaw.stops == 0 && timeoutRaw.resumeRequests == 0 && timeoutOutput.resumeRequests == 0)
        try await Task.sleep(for: .seconds(15.2))
        try await waitUntil { timeoutRaw.stops == 1 }
        precondition(timeoutRaw.resumeRequests == 0 && timeoutRaw.parkedStartAuthorizations.isEmpty
                     && timeoutRaw.audioRestorations == [false] && timeoutRaw.gains.last == 0,
                     "Missing fresh Mac volume restarted or unmuted LDAC")
        timeoutRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { timeoutOutput.restores.count == 1 && timeout.nativeOutput !== timeoutOutput }
        if timeout.isSessionRunning { try await stop(timeout) }
        print("PASS missing fresh Mac volume releases the held owner once the bounded return wait expires")

        for scenario in ["Stop", "park declined", "park error", "native park failure", "route changed", "controls reset", "another peer"] {
            let (controller, device, output, raw) = try await startedHandoff()
            switch scenario {
            case "park declined": output.parkResult = false
            case "park error": output.parkError = LDACOwnerError()
            case "Stop": output.blocksPark = true
            default: break
            }
            if scenario == "native park failure" {
                raw.emit(.failed("The peer did not suspend"))
            } else {
                raw.emit(.warmHeld)
                if scenario == "Stop" {
                    try await waitUntil { output.parkWaiter != nil }
                    controller.stop()
                    output.parkWaiter?.resume()
                } else if !["park declined", "park error"].contains(scenario) {
                    try await waitUntil { controller.state == .waitingForMac && !output.selected }
                    switch scenario {
                    case "route changed":
                        controller.audioRoute?.route = Route(uid: "external-speakers")
                        controller.audioRoute?.currentOutputUID = "external-speakers"
                        output.changed(.failure(LDACOwnerError(outputDeselected: true)))
                    case "controls reset":
                        device.notificationSession += 1
                        device.objectWillChange.send()
                    case "another peer": device.confirmMusicSource(other)
                    default: break
                    }
                }
            }
            try await waitUntil { raw.stops == 1 }
            precondition(raw.audioRestorations == [false] && raw.resumeRequests == 0 && output.resumeRequests == 0,
                         "Invalid warm handoff requested Mac audio or resumed: \(scenario)")
            raw.emit(.finished(.init(message: nil)))
            try await waitUntil { controller.nativeOutput == nil && controller.session == nil }
            precondition(output.restores.count == 1 && output.restoredHeadphoneOutputs == [false]
                         && device.sourceRequests.isEmpty && device.connectionRequests.isEmpty && raw.recoveries.isEmpty,
                         "Invalid warm handoff left an owner or perturbed phone audio: \(scenario)")
            if scenario == "Stop" { precondition(controller.state == .off && controller.requestedAddress == nil) }
            precondition(raw.gains.last == 0)
        }
        print("PASS Stop, declined native or HAL parking, external routing, lost Sony controls and a superseding peer release the owner silently")
    }

    @MainActor
    static func checkColdControlsOverlap() async throws {
        for scenario in ["cold", "control busy after closure", "early failure", "opening", "handshaking", "no cached channel", "ready", "stale session",
                         "other output", "other device", "other source", "Classic lost", "raw recovery"] {
            let (controller, device, _, raw) = try await started(.v2)
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            device.isReady = scenario == "ready"
            switch scenario {
            case "control busy after closure": device.linkState = .controlBusy
            case "opening": device.linkState = .opening
            case "handshaking": device.linkState = .handshaking
            case "no cached channel": device.hasCachedControlChannel = false
            case "stale session": controller.sessionID = UUID()
            case "other output": controller.audioRoute?.currentOutputUID = "fixture-speakers"
            case "other device": controller.devices?.selectedAddress = "02:00:00:00:00:04"
            case "other source": device.reportAudioSource(.init(address: "02:00:00:00:00:03"))
            case "Classic lost": controller.isClassicConnected = { _ in false }
            case "raw recovery": controller.isRecovering = true
            default: break
            }
            if !["control busy after closure", "opening", "handshaking", "ready"].contains(scenario) { device.linkState = .disconnected }
            raw.emit(.ownedMediaReady)
            raw.emit(.ownedMediaReady)
            let expectEarly = ["cold", "control busy after closure", "early failure"].contains(scenario)
            precondition(device.coldControlReopens == (expectEarly ? 1 : 0),
                         "Wrong early Sony reopen count for \(scenario)")
            precondition(device.refreshes == 0 && device.volumeRefreshes == 0 && raw.gains.last != 1
                         && device.sourceRequests.isEmpty && device.connectionRequests.isEmpty && !controller.usable,
                         "Owned-media readiness granted audio or changed Sony settings for \(scenario)")

            switch scenario {
            case "cold", "control busy after closure", "opening", "handshaking", "early failure", "no cached channel":
                if scenario == "early failure" { device.linkState = .controlBusy }
                raw.emit(.active(LDACFormat()))
                let expectFallback = scenario == "early failure" || scenario == "no cached channel"
                precondition(device.refreshes == (expectFallback ? 1 : 0),
                             "Active admission duplicated a pending Sony open or missed its existing fallback for \(scenario)")
            default: break
            }
            try await stop(controller)
        }
        print("PASS cold controls overlap: one current Sony open before active, pending discovery preserved, fallback retained and stale routes ignored")
    }

    @MainActor
    static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1")
        if ProcessInfo.processInfo.arguments.contains("--check-cold-controls-overlap") || ProcessInfo.processInfo.arguments.count == 1 {
            try await checkColdControlsOverlap()
            if ProcessInfo.processInfo.arguments.contains("--check-cold-controls-overlap") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-phone-handoff") || ProcessInfo.processInfo.arguments.count == 1 {
            try await checkPhoneHandoffs()
            if ProcessInfo.processInfo.arguments.contains("--check-phone-handoff") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-output-deselection") || ProcessInfo.processInfo.arguments.count == 1 {
            let (controller, device, output, raw) = try await started(.v2)
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            output.changed(.failure(LDACOwnerError(outputDeselected: true)))
            raw.emit(.finished(.init(message: nil)))
            try await waitUntil { controller.state == .waitingForDevice }
            for _ in 0..<20 { controller.resumeIfReady() }
            precondition(controller.nativeOutput == nil && controller.session == nil && controller.diagnosticAttempt == 1
                         && controller.requestedAddress == device.address && raw.audioRestorations == [false]
                         && !output.selected && !output.ready && raw.gains == [0])

            controller.audioRoute?.route = Route(uid: "fixture-speakers")
            controller.isClassicConnected = { _ in false }
            controller.resumeIfReady()
            controller.isClassicConnected = { _ in true }
            controller.resumeIfReady()
            precondition(controller.state == .waitingForDevice && controller.nativeOutput == nil)
            controller.audioRoute?.route = Route(uid: "fixture-headphones")
            controller.resumeIfReady()
            try await waitUntil { device.statusReadPending && device.volumeReadPending }
            device.receiveStatus()
            device.receiveVolume()
            try await waitUntil { controller.session != nil }
            precondition(controller.diagnosticAttempt == 2 && controller.session !== raw && controller.nativeOutput?.claims == [false])
            try await stop(controller)
            print("PASS output deselection: no immediate retry on the saved route; one new Bluetooth connection can resume on that route")
            if ProcessInfo.processInfo.arguments.contains("--check-output-deselection") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-route-first-source-return") || ProcessInfo.processInfo.arguments.count == 1 {
            let target = "02:00:00:00:00:01:output"
            let speakers = "fixture-speakers"
            let mac = SonyMultipointDevice(address: "02:00:00:00:00:02")
            let phone = SonyMultipointDevice(address: "02:00:00:00:00:03")
            for scenario in ["same target", "later target", "other Bluetooth", "same speaker UID", "same UID different transport",
                             "no cycle", "unowned peer", "unowned Mac", "different Sony session", "stale after return",
                             "route changes during preparation", "source changes before native handoff"] {
                let original = scenario == "same speaker UID" ? speakers : target
                let (controller, device, output, raw) = try await active(.v2, initialRouteUID: original)
                device.reportAudioSource(mac)
                controller.audioRoute?.route = Route(uid: speakers)
                controller.audioRoute?.currentOutputUID = speakers
                output.changed(.failure(LDACOwnerError(outputDeselected: true)))
                raw.emit(.finished(.init(message: nil)))
                try await waitUntil { controller.state == .waitingForDevice }
                precondition(controller.isClassicConnected(device.address) && output.restoredHeadphoneOutputs == [false] && !output.selected)
                if scenario != "no cycle" {
                    device.reportAudioSource(phone)
                    device.localSource = false
                    if scenario != "unowned peer" { device.musicSourceConfirmations.send(phone) }
                }
                if scenario == "different Sony session" { device.notificationSession += 1 }
                if scenario == "same UID different transport" { controller.audioRoute?.currentOutputTransport = kAudioDeviceTransportTypeUSB }
                let returnedOutput = scenario == "later target" ? speakers : scenario == "other Bluetooth" ? "02:00:00:00:00:09:output" : original
                controller.audioRoute?.route = Route(uid: returnedOutput)
                controller.audioRoute?.currentOutputUID = returnedOutput
                if scenario == "route changes during preparation" { device.connectionMode = .stableConnection }
                device.reportAudioSource(mac)
                device.localSource = true
                if scenario != "unowned Mac" { device.musicSourceConfirmations.send(mac) }
                if scenario == "stale after return" { device.multipoint.inventoryIsStale = true }
                controller.resumeIfReady()

                if scenario == "same target" || scenario == "source changes before native handoff" {
                    precondition(controller.diagnosticAttempt == 2,
                                 "Fresh sourced return was not admitted: \(controller.state) receipt=\(controller.deselectedSourceReturn != nil) observer=\(controller.deselectedSourceObservation != nil)")
                    try await waitUntil { device.statusReadPending && device.volumeReadPending }
                    device.receiveStatus()
                    device.receiveVolume()
                    try await waitUntil { controller.session != nil }
                    precondition(controller.diagnosticAttempt == 2 && controller.session !== raw && controller.nativeOutput?.expectedDefaultOutputUIDs == [target],
                                 "Fresh same-session source return did not resume on the exact originally selected Bluetooth device")
                    let resumed = controller.session!
                    if scenario == "source changes before native handoff" {
                        device.reportAudioSource(phone)
                        device.reportAudioSource(mac)
                        resumed.emit(.handoffReady)
                        try await waitUntil { resumed.stops == 1 }
                        precondition(resumed.handoffs == 0 && controller.nativeOutput?.selections == 0,
                                     "A newer Sony source cycle was admitted by an older return witness")
                    } else {
                        resumed.emit(.handoffReady)
                        try await waitUntil { resumed.handoffs == 1 }
                    }
                } else if scenario == "route changes during preparation" {
                    try await waitUntil { device.connectionRequests == [.soundQuality] }
                    let attemptedOutput = controller.nativeOutput
                    controller.audioRoute?.currentOutputUID = speakers
                    device.confirmConnectionMode(.soundQuality)
                    try await waitUntil { controller.state == .waitingForDevice && controller.nativeOutput == nil }
                    precondition(attemptedOutput?.claims.isEmpty == true && controller.session == nil && controller.audioRoute?.isDefaultOutput(speakers) == true,
                                 "Asynchronous preparation overrode a new live speaker selection")
                } else {
                    if scenario == "later target" {
                        controller.audioRoute?.route = Route(uid: original)
                        controller.audioRoute?.currentOutputUID = original
                        device.musicSourceConfirmations.send(mac)
                    }
                    if scenario == "stale after return" { device.multipoint.inventoryIsStale = false }
                    for _ in 0..<10 {
                        controller.resumeIfReady()
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    precondition(controller.diagnosticAttempt == 1 && controller.state == .waitingForDevice && controller.session == nil && controller.nativeOutput == nil,
                                 "Route-first LDAC resumed without contemporaneous target route and fresh same-session source proof for \(scenario)")
                }
                precondition(device.sourceRequests.isEmpty, "Passive recovery issued a Sony source switch for \(scenario)")
                try await stop(controller)
            }
            print("PASS active route-first source return: live exact Bluetooth target and fresh same-session Sony cycle required; later routing and in-flight selector changes preserve explicit outputs")
            if ProcessInfo.processInfo.arguments.contains("--check-route-first-source-return") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-startup-output-deselection") || ProcessInfo.processInfo.arguments.count == 1 {
            for difference in ["return", "competing source", "ordinary stop", "sleep", "already active",
                               "ordinary stop at transmit", "suspension at transmit", "source changed at transmit",
                               "request superseded at transmit", "control session changed at transmit",
                               "inventory stale at transmit", "phone unavailable at transmit"] {
                let (controller, device, output, raw, phone) = try await startedWithSourceHandoff()
                let mac = device.multipoint.selectedSource!.address
                let preferenceRequest = UUID()
                if difference == "return" {
                    controller.connectionModeRestoreID = preferenceRequest
                    device.lastConnectionModeChangeID = preferenceRequest
                }
                if difference == "already active" {
                    raw.emit(.active(LDACFormat()))
                    try await waitUntil { device.statusReadPending && device.volumeReadPending }
                    device.receiveStatus()
                    device.receiveVolume()
                    try await waitUntil { device.queuedWrite != nil }
                    device.transmitVolume()
                    device.confirmVolume()
                    try await waitUntil { controller.usable }
                    precondition(controller.startupSourceReturn == nil)
                }
                controller.audioRoute?.route = Route(uid: "external-default")
                if difference == "ordinary stop" {
                    controller.stop(restoreAudio: false, reason: "ordinary suppression")
                } else {
                    output.changed(.failure(LDACOwnerError(outputDeselected: true)))
                }
                if difference == "competing source" { device.reportAudioSource(.init(address: "02:00:00:00:00:04")) }
                if difference == "sleep" { controller.devices?.isSystemSleeping = true }
                device.defersSourceWrite = difference.hasSuffix("at transmit")
                raw.emit(.finished(.init(message: nil)))
                if difference == "return" {
                    try await waitUntil { device.sourceRequests == [mac, phone.address] }
                    device.confirmAudioSource(phone)
                    device.localSource = false
                } else if device.defersSourceWrite {
                    try await waitUntil { device.pendingSourceWrite != nil }
                    switch difference {
                    case "ordinary stop at transmit": controller.stop(restoreAudio: false, reason: "ordinary suppression")
                    case "suspension at transmit": controller.suspend(restoreAudio: false, reason: "sleep request")
                    case "source changed at transmit": device.reportAudioSource(.init(address: "02:00:00:00:00:04"))
                    case "request superseded at transmit": device.sourceTransition = .init(phase: .complete, session: device.notificationSession)
                    case "control session changed at transmit": device.notificationSession += 1
                    case "inventory stale at transmit": device.multipoint.inventoryIsStale = true
                    case "phone unavailable at transmit": device.multipoint.devices.removeAll { $0.address == phone.address }
                    default: preconditionFailure()
                    }
                    device.pendingSourceWrite?()
                }
                try await waitUntil { controller.cleanupTask == nil }
                for _ in 0..<3 { controller.resumeIfReady() }
                precondition(device.sourceRequests == (difference == "return" ? [mac, phone.address] : [mac]), difference)
                precondition(controller.audioRoute?.route?.uid == "external-default"
                             && raw.audioRestorations == [false] && output.restoredHeadphoneOutputs == [false], difference)
                precondition(controller.requestedAddress == (difference == "already active" ? device.address : nil)
                             && controller.startupSourceReturn == nil
                             && controller.session == nil && controller.diagnosticAttempt == 1, difference)
                if difference == "return" {
                    precondition(device.connectionRequests.isEmpty && controller.deferredConnectionModes[device.address] == preferenceRequest)
                }
            }
            print("PASS startup output deselection: release external Mac output without retry; return Sony source only while still owned at transmit")
            if ProcessInfo.processInfo.arguments.contains("--check-startup-output-deselection") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-readable-handoff") || ProcessInfo.processInfo.arguments.count == 1 {
            for generation in [Generation.v1, .v2] {
                let (controller, device, output, raw) = try await started(generation)
                raw.emit(.handoffReady)
                try await waitUntil { raw.handoffs == 1 }
                let configurations = output.configurations
                raw.emit(.active(LDACFormat()))
                try await waitUntil { device.statusReadPending && device.volumeReadPending }
                device.receiveStatus()
                device.receiveVolume(output.controls.volume(in: 0...30))
                try await waitUntil { controller.usable }
                precondition(output.ready && raw.gains.last == 1 && device.transmitted.isEmpty &&
                             output.configurations == configurations,
                             "Matching confirmed Mac and headphone volumes were configured again before admission")
                try await stop(controller)
            }
            let (controller, device, output, raw) = try await started(.v2, playbackAvailable: false)
            precondition(device.hasFreshReadableMusicVolumeReadback && !device.hasFreshMusicVolumeReadback
                         && !controller.hasOwnedMusicContext && !output.selected && raw.gains == [0])
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            precondition(output.selected && !output.ready && device.transmitted.isEmpty && raw.gains == [0])
            raw.emit(.active(LDACFormat()))
            try await waitUntil { device.volumeRefreshes == 1 }
            device.receiveStatus()
            device.receiveVolume(13)
            try await Task.sleep(for: .milliseconds(120))
            precondition(controller.state == .connecting && !controller.usable && !output.ready && device.transmitted.isEmpty
                         && device.queuedWrite == nil && raw.gains == [0])
            device.playbackAvailable = true
            device.receiveStatus()
            try await waitUntil { device.queuedWrite != nil }
            device.transmitVolume()
            precondition(!output.ready && raw.gains == [0])
            device.confirmVolume()
            try await waitUntil { controller.usable }
            precondition(output.ready && raw.gains.last == 1)
            try await stop(controller)
            print("PASS readable startup: disabled playback allows silent handoff and stays muted until writable post-transport volume confirms")
            if ProcessInfo.processInfo.arguments.contains("--check-readable-handoff") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-source-preflight") || ProcessInfo.processInfo.arguments.count == 1 {
            for result in ["claim denied", "claim cancelled", "permission denied", "permission failed", "permission cancelled",
                           "source changed", "source changed and returned", "queued source changed and returned",
                           "request changed", "Mac route changed", "output selection rejected", "output replaced before transmit",
                           "keeping changed during output selection", "keeping changed before transmit",
                           "rate changed", "accepted"] {
                let controller = Controller()
                let device = SonyHeadphonesController()
                let mac = SonyMultipointDevice(address: "02:00:00:00:00:02")
                let phone = SonyMultipointDevice(address: "02:00:00:00:00:03")
                let other = SonyMultipointDevice(address: "02:00:00:00:00:04")
                device.playback.generation = .v2
                device.localSource = false
                device.preparationIssue = .selectMac(mac)
                device.multipoint.selectedSource = phone
                device.multipoint.devices = [mac, phone, other]
                device.defersSourceWrite = result == "queued source changed and returned" || result.hasSuffix("before transmit")
                if result != "accepted" { device.connectionMode = .stableConnection }
                controller.devices?.controllers[device.address] = device
                controller.requestedAddress = device.address
                controller.start(device.address, selectingSource: mac)
                let output = controller.nativeOutput!
                if result == "keeping changed during output selection" {
                    let markSelected = output.didSelect
                    output.didSelect = { markSelected?(); device.multipoint.keeping = true }
                }
                output.blocksClaim = true
                output.blocksPermission = true
                try await waitUntil { output.claimWaiter != nil }
                precondition(output.claims == [true] && output.priorityRequests == 0 && !output.selected
                             && output.configurations == 0 && controller.session == nil && device.sourceRequests.isEmpty
                             && device.multipoint.selectedSource?.address == phone.address && device.transmitted.isEmpty
                             && output.permissionChecks.isEmpty)
                if result == "claim denied" { output.claimError = LDACOwnerError() }
                if result == "claim cancelled" { controller.stop(reason: "User cancelled") }
                output.claimWaiter?.resume()
                output.claimWaiter = nil
                if !result.hasPrefix("claim ") {
                    try await waitUntil {
                        precondition(device.sourceRequests.isEmpty, "Sony source changed before capture permission was verified")
                        return output.permissionWaiter != nil
                    }
                    precondition(output.permissionChecks == [48000] && controller.audioCaptureAccess == .checking
                                 && output.priorityRequests == 0 && !output.selected && controller.session == nil
                                 && device.sourceRequests.isEmpty && device.multipoint.selectedSource?.address == phone.address)
                    switch result {
                    case "permission denied": output.permissionError = LDACOwnerError(captureAccess: .permissionRequired)
                    case "permission failed": output.permissionError = LDACOwnerError()
                    case "permission cancelled": controller.stop(reason: "User cancelled")
                    case "source changed": device.reportAudioSource(other)
                    case "source changed and returned":
                        device.reportAudioSource(other)
                        device.reportAudioSource(phone)
                    case "request changed": device.sourceTransition = .init(phase: .complete, session: device.notificationSession)
                    case "Mac route changed": controller.audioRoute?.route = Route(uid: "fixture-speakers")
                    case "output selection rejected": output.selectionError = LDACOwnerError(outputDeselected: true)
                    case "rate changed": controller.updateConfiguration(.init(sampleRate: 44100))
                    default: break
                    }
                    output.permissionWaiter?.resume()
                    output.permissionWaiter = nil
                }
                if result == "queued source changed and returned" {
                    try await waitUntil { device.pendingSourceWrite != nil }
                    device.reportAudioSource(other)
                    device.reportAudioSource(phone)
                    let write = device.pendingSourceWrite
                    device.pendingSourceWrite = nil
                    write?()
                }
                if result == "output replaced before transmit" {
                    try await waitUntil { device.pendingSourceWrite != nil }
                    controller.audioRoute?.route = Route(uid: LDACNativeOutput.uid)
                    controller.audioRoute?.currentOutputUID = "fixture-speakers"
                    device.pendingSourceWrite?()
                }
                if result == "keeping changed before transmit" {
                    try await waitUntil { device.pendingSourceWrite != nil }
                    device.multipoint.keeping = true
                    device.pendingSourceWrite?()
                }
                if result == "accepted" {
                    try await waitUntil { device.sourceRequests == [mac.address] }
                    precondition(output.selected && output.priorityRequests == 1 && controller.session == nil
                                 && controller.audioCaptureAccess == .ready && output.permissionChecks == [48000])
                    device.confirmAudioSource(mac)
                    try await waitUntil { device.volumeReadPending }
                    device.receiveStatus()
                    device.receiveVolume()
                    try await waitUntil { controller.session != nil }
                    precondition(output.claims == [true] && output.priorityRequests == 1 && output.selected
                                 && controller.audioCaptureAccess == .ready && output.permissionChecks == [48000])
                    controller.session?.emit(.handoffReady)
                    try await waitUntil { controller.session?.handoffs == 1 }
                    precondition(output.selections == 1 && device.sourceRequests == [mac.address])
                    try await stop(controller)
                } else {
                    try await waitUntil {
                        precondition(device.sourceRequests.isEmpty, "A superseded Sony source request reached the wire")
                        precondition(device.sourceUnlocks == 0, "LDAC attempted to change source keeping")
                        return !controller.isSessionRunning
                    }
                    let reachedSelection = device.defersSourceWrite || result == "keeping changed during output selection"
                    precondition(device.sourceRequests.isEmpty && device.transmitted.isEmpty && !output.selected
                                 && device.connectionRequests.isEmpty && output.priorityRequests == (reachedSelection ? 1 : 0)
                                 && output.configurations == 0 && output.restores.count == 1)
                    precondition(device.multipoint.selectedSource?.address ==
                                 (result == "source changed" ? other.address : phone.address))
                    if result.hasSuffix("cancelled") { precondition(controller.state == .off) }
                    if result == "permission denied" { precondition(controller.audioCaptureAccess == .permissionRequired) }
                }
                precondition(device.sourceUnlocks == 0, "LDAC attempted to change source keeping")
            }
            print("PASS source preparation: verified Mac output, one route selection, and no unlock or source write after rejection, replacement, or a source keeping change")
            if ProcessInfo.processInfo.arguments.contains("--check-source-preflight") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-pending-source-return") || ProcessInfo.processInfo.arguments.count == 1 {
            for outcome in ["return", "confirmed before cancellation", "rejected", "expired", "superseded",
                            "changed twice", "new session", "untouched queue", "sleep while pending", "ordinary suppression"] {
                let controller = Controller()
                let device = SonyHeadphonesController()
                let mac = SonyMultipointDevice(address: "02:00:00:00:00:02")
                let phone = SonyMultipointDevice(address: "02:00:00:00:00:03")
                let other = SonyMultipointDevice(address: "02:00:00:00:00:04")
                device.playback.generation = .v2
                device.localSource = false
                device.multipoint.selectedSource = phone
                device.multipoint.devices = [mac, phone, other]
                device.preparationIssue = .selectMac(mac)
                device.defersSourceWrite = outcome == "untouched queue"
                controller.devices?.controllers[device.address] = device
                controller.requestedAddress = device.address
                controller.start(device.address, selectingSource: mac)
                let output = controller.nativeOutput!
                try await waitUntil {
                    outcome == "untouched queue" ? device.pendingSourceWrite != nil : device.sourceRequests == [mac.address]
                }
                precondition(controller.pendingStartupSourceSelection?.request == device.sourceTransition?.requestID
                             && controller.startupSourceReturn == nil && controller.session == nil)
                if outcome == "confirmed before cancellation" { device.confirmAudioSource(mac) }
                if outcome == "expired" { controller.pendingStartupSourceSelection?.deadline = .now }
                controller.audioRoute?.route = Route(uid: "external-default")
                controller.audioRoute?.currentOutputUID = "external-default"
                if outcome == "ordinary suppression" { controller.stop(restoreAudio: false, reason: "fixture ordinary stop") }
                else { output.changed(.failure(LDACOwnerError(outputDeselected: true))) }
                try await waitUntil { output.restores == [false] }
                let shouldReturn = outcome == "return" || outcome == "confirmed before cancellation"
                switch outcome {
                case "return":
                    precondition(controller.isSessionRunning && device.sourceRequests == [mac.address],
                                 "Output release abandoned the transmitted Sony request before its confirmation")
                    device.confirmAudioSource(mac)
                case "rejected": device.sourceTransition?.phase = .failed
                case "superseded":
                    device.sourceTransition = .init(session: device.notificationSession)
                    device.confirmAudioSource(mac)
                case "changed twice":
                    device.reportAudioSource(other)
                    device.confirmAudioSource(mac)
                case "new session":
                    device.notificationSession += 1
                    device.confirmAudioSource(mac)
                case "untouched queue": device.pendingSourceWrite?()
                case "sleep while pending": controller.devices?.isSystemSleeping = true
                default: break
                }
                if shouldReturn {
                    try await waitUntil { device.sourceRequests == [mac.address, phone.address] }
                    device.confirmAudioSource(phone)
                }
                try await waitUntil { !controller.isSessionRunning }
                if ["expired", "sleep while pending", "ordinary suppression"].contains(outcome) { device.confirmAudioSource(mac) }
                let expected = shouldReturn ? [mac.address, phone.address] : outcome == "untouched queue" ? [] : [mac.address]
                precondition(device.sourceRequests == expected && device.sourceUnlocks == 0, outcome)
                precondition(controller.state == .off && controller.requestedAddress == nil && controller.session == nil
                             && controller.startupSourceReturn == nil && controller.pendingStartupSourceSelection == nil
                             && output.restoredHeadphoneOutputs == [false]
                             && controller.audioRoute?.currentOutputUID == "external-default", outcome)
            }
            print("PASS in-flight deselection: release output before awaiting exact Sony confirmation; reject expired, superseded, untransmitted or rejected transfers")
            if ProcessInfo.processInfo.arguments.contains("--check-pending-source-return") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-source-return") || ProcessInfo.processInfo.arguments.count == 1 {
            for outcome in ["return", "transient no source", "source changed before confirmation",
                            "phone disconnected", "source changed twice", "different request",
                            "new session", "keeping enabled"] {
                let controller = Controller()
                let device = SonyHeadphonesController()
                let mac = SonyMultipointDevice(address: "02:00:00:00:00:02")
                let phone = SonyMultipointDevice(address: "02:00:00:00:00:03")
                device.playback.generation = .v2
                device.localSource = false
                device.multipoint.selectedSource = phone
                device.multipoint.devices = [mac, phone]
                device.preparationIssue = .selectMac(mac)
                controller.devices?.controllers[device.address] = device
                controller.headphones = device
                controller.targetAddress = device.address
                controller.requestedAddress = device.address
                controller.resumeOutputUID = controller.audioRoute?.route?.uid
                controller.state = .requested
                let output = LDACNativeOutput(id: controller.sessionID, address: device.address) { _ in }
                output.didSelect = { [weak controller] in controller?.audioRoute?.currentOutputUID = LDACNativeOutput.uid }
                controller.nativeOutput = output
                let origin = (device.notificationSession, phone.address, device.playbackSourceGeneration, nil as UUID?)
                let selection = Task { @MainActor in
                    try await controller.selectMacAudioSource(mac, for: device, address: device.address, identifier: controller.sessionID,
                        origin: origin, output: output)
                }
                try await waitUntil { device.sourceRequests == [mac.address] }
                if outcome == "transient no source" { device.reportAudioSource(nil) }
                if outcome == "source changed before confirmation" {
                    device.reportAudioSource(mac)
                    device.reportAudioSource(phone)
                }
                device.confirmAudioSource(mac)
                try await selection.value
                let expectedReturn = outcome == "transient no source" || outcome == "source changed before confirmation" ? nil : phone.address
                precondition(controller.startupSourceReturn?.source == expectedReturn && device.multipoint.selectedSource?.address == mac.address)
                switch outcome {
                case "phone disconnected": device.multipoint.devices = [mac]
                case "source changed twice": device.confirmAudioSource(phone); device.confirmAudioSource(mac)
                case "different request": device.sourceTransition = .init(phase: .complete, session: device.notificationSession)
                case "new session": device.notificationSession += 1
                case "keeping enabled": device.multipoint.keeping = true
                default: break
                }
                controller.requestedAddress = nil
                controller.finish("LDAC startup failed")
                if outcome == "return" {
                    try await waitUntil { device.sourceRequests == [mac.address, phone.address] }
                    device.confirmAudioSource(phone)
                }
                try await waitUntil { controller.cleanupTask == nil }
                precondition(device.sourceRequests == (outcome == "return" ? [mac.address, phone.address] : [mac.address]))
                precondition(controller.startupSourceReturn == nil && controller.state == .failed("LDAC startup failed"))
            }
            print("PASS failed LDAC handoff returns an owned direct source switch; transient no-source and extra changes skip rollback without blocking confirmed Mac selection")
            if ProcessInfo.processInfo.arguments.contains("--check-source-return") { return }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-handoff-refresh") || ProcessInfo.processInfo.arguments.count == 1 {
            for generation in [Generation.v1, .v2] {
                let (controller, device, output, raw) = try await started(generation)
                let readback = device.musicVolumeReadbackID
                device.requestCurrentSettings()
                precondition(controller.hasMusicVolumeForHandoff && device.canControlMusicVolume
                             && !device.hasFreshMusicVolumeReadback && device.musicVolumeReadbackID == readback)
                raw.emit(.handoffReady)
                try await Task.sleep(for: .milliseconds(120))
                precondition(raw.stops == 0 && raw.handoffs == 0 && !output.selected && !output.ready,
                             "Routine playback refresh aborted handoff instead of awaiting its existing reads")
                device.receiveStatus()
                try await Task.sleep(for: .milliseconds(120))
                precondition(raw.handoffs == 0 && !output.selected && device.transmitted.isEmpty,
                             "Handoff admitted pending music-volume readback")
                device.receiveVolume()
                try await waitUntil { raw.handoffs == 1 || raw.stops != 0 }
                precondition(raw.handoffs == 1 && raw.stops == 0 && output.selected && !output.ready
                             && raw.gains == [0] && device.volumeRefreshes == 0 && device.transmitted.isEmpty,
                             "Completed unchanged settings refresh did not allow silent handoff")
                try await stop(controller)
            }
            print("PASS handoff polling collision: existing settings reads are awaited, both replies remain required, and unchanged fresh controls allow silent handoff without another refresh or setter")
            for change in ["volume", "range", "control-session", "source", "write", "target", "stop", "native-timeout"] {
                let (controller, device, output, raw) = try await started()
                device.requestCurrentSettings()
                raw.emit(.handoffReady)
                try await waitUntil { controller.events.contains("handoff-volume-wait") }
                if change == "volume" { device.receiveVolume(9) }
                else if change == "range" { device.playback.musicVolumeRange = 0...20 }
                else if change == "control-session" { device.notificationSession += 1 }
                else if change == "source" { device.multipoint.selectedSource = .init(address: "02:00:00:00:00:03") }
                else if change == "write" { device.blocksPlaybackCommands = true }
                else if change == "target" { controller.devices?.controllers[device.address] = SonyHeadphonesController() }
                else if change == "stop" { controller.stop(reason: "fixture handoff cancellation") }
                else { raw.emit(.failed("The silent LDAC output could not be selected before Bluetooth handoff.")) }
                try await waitUntil { raw.stops != 0 }
                device.receiveStatus()
                device.receiveVolume()
                precondition(raw.handoffs == 0 && !output.selected && !output.ready && raw.gains == [0],
                             "Changed \(change) was admitted while awaiting handoff reads")
                try await stop(controller)
            }
            for change in ["readback", "source"] {
                let (controller, device, output, raw) = try await started()
                output.blocksConfiguration = true
                raw.emit(.handoffReady)
                try await waitUntil { output.configurationWaiter != nil }
                if change == "readback" { device.receiveVolume() }
                else { device.multipoint.selectedSource = .init(address: "02:00:00:00:00:03") }
                output.blocksConfiguration = false
                output.configurationWaiter?.resume()
                output.configurationWaiter = nil
                try await waitUntil { raw.stops != 0 }
                precondition(raw.handoffs == 0 && !output.selected && !output.ready,
                             "Changed \(change) during asynchronous configuration bypassed handoff provenance")
                try await stop(controller)
            }
            print("PASS handoff provenance: changed volume, range, Sony session, source, pending write, controller replacement, stop and native timeout remain refused; configuration retains readback identity")
            for completeRead in [false, true] {
                let (controller, device, output, raw) = try await started()
                device.requestCurrentSettings()
                raw.emit(.handoffReady)
                try await waitUntil { controller.events.contains("handoff-volume-wait") }
                if completeRead {
                    output.blocksConfiguration = true
                    try await Task.sleep(for: .seconds(8.5))
                    device.receiveStatus()
                    device.receiveVolume()
                    try await waitUntil { output.configurationWaiter != nil }
                    try await Task.sleep(for: .seconds(2))
                    output.blocksConfiguration = false
                    output.configurationWaiter?.resume()
                    output.configurationWaiter = nil
                } else {
                    try await Task.sleep(for: .seconds(10.2))
                }
                try await waitUntil { raw.stops != 0 }
                precondition(raw.handoffs == 0 && !output.selected && !output.ready && device.volumeRefreshes == 0,
                             "Handoff refreshed or outlived its original ten-second budget")
                try await stop(controller)
            }
            print("PASS handoff deadline: pending reads and asynchronous output configuration share the original ten-second budget")
            if ProcessInfo.processInfo.arguments.contains("--check-handoff-refresh") { return }
        }
        do {
            let (controller, _, output, raw) = try await active(.v2)
            precondition(controller.canChangeConfiguration)
            let initialStops = raw.stops
            controller.updateConfiguration(LDACConfiguration(sampleRate: 48000, quality: .quality))
            controller.updateConfiguration(LDACConfiguration(sampleRate: 48000, quality: .adaptive))
            precondition(raw.configurations.map(\.quality) == [.quality, .adaptive] && raw.stops == initialStops && output.restores.isEmpty,
                         "Live bitrate selection restarted the transport")
            controller.updateConfiguration(LDACConfiguration(sampleRate: 96000, quality: .adaptive))
            precondition(raw.configurations.last?.sampleRate == 96000 && raw.stops == initialStops &&
                         controller.state == .active(LDACFormat()) && controller.canChangeConfiguration,
                         "Sample-rate change replaced the active session")
            precondition(controller.requestedAddress != nil && controller.requestedConfiguration.sampleRate == 96000,
                         "Sample-rate change lost the requested session")
            raw.emit(.sampleRateChangeRejected(requested: 96000, active: 48000))
            precondition(controller.requestedConfiguration.sampleRate == 48000 && controller.restoredRates == [48000] &&
                         controller.sampleRateChangeError != nil && controller.state == .active(LDACFormat()),
                         "Rejection did not preserve the active output or restore the preferred rate")
            let superseded = LDACConfiguration(sampleRate: 96000, quality: .quality)
            let latest = LDACConfiguration(sampleRate: 96000, quality: .balanced)
            controller.updateConfiguration(superseded)
            controller.updateConfiguration(latest)
            raw.emit(.sampleRateChangeDeferred(requested: .init(sampleRate: 88200, quality: .balanced), active: 48000))
            raw.emit(.sampleRateChangeDeferred(requested: superseded, active: 48000))
            precondition(controller.requestedConfiguration == latest && controller.restoredRates == [48000] &&
                         controller.sampleRateChangeError == nil && Array(raw.configurations.suffix(2)) == [superseded, latest],
                         "A stale deferral restored the preference after a newer request at the same rate")
            let newerFormat = LDACFormat(value: 2)
            raw.emit(.formatChanged(newerFormat))
            precondition(controller.requestedConfiguration == latest && controller.state == .active(newerFormat),
                         "A successful newer request left the preference or active format behind")
            let deferred = LDACConfiguration(sampleRate: 88200, quality: .adaptive)
            controller.updateConfiguration(deferred)
            raw.emit(.sampleRateChangeDeferred(requested: deferred, active: 96000))
            precondition(controller.requestedConfiguration == .init(sampleRate: 96000, quality: .adaptive) &&
                         controller.restoredRates == [48000, 96000] && controller.sampleRateChangeError?.contains("buffered") == true &&
                         controller.state == .active(newerFormat) && raw.stops == initialStops && output.restores.isEmpty,
                         "A matching deferral failed to restore the active sample rate and preserve the requested quality")
            try await stop(controller)
        }
        print("PASS live LDAC configuration, peer rejection, and capture deferral preserve the active session and current preference")
        if ProcessInfo.processInfo.arguments.contains("--check-live-configuration") { return }
        for generation in [Generation.v1, .v2] {
            let (controller, device, output, raw) = try await active(generation)
            let devices = controller.devices!
            let relay = device.objectWillChange.sink { devices.objectWillChange.send() }
            try await Task.sleep(for: .milliseconds(30))
            let configurations = output.configurations
            let confirmations = controller.events.filter { $0 == "volume-confirmed" }.count
            let writes = device.transmitted
            for _ in 0..<30 {
                device.receiveVolume(device.playback.volume!)
                devices.objectWillChange.send()
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(output.configurations == configurations
                         && controller.events.filter { $0 == "volume-confirmed" }.count == confirmations
                         && controller.pendingVolume == nil && controller.volumeTask == nil && device.transmitted == writes,
                         "Unchanged headphone/coordinator observations repeated volume confirmation or output configuration")

            device.receiveVolume(9)
            try await waitUntil { output.controls.volume(in: 0...30) == 9 && controller.volumeTask == nil }
            precondition(output.configurations == configurations + 1 && device.transmitted == writes,
                         "A headphone-side volume change was lost or echoed as a Sony setter")
            let confirmedHeadphoneVolume = output.configurations
            output.simulateControls(LDACNativeVolume(scalar: 0.5, muted: false))
            try await waitUntil { device.queuedWrite != nil }
            precondition(device.queuedWrite?.volume == 15)
            device.transmitVolume()
            device.confirmVolume()
            try await waitUntil { controller.volumeTask == nil }
            try await Task.sleep(for: .milliseconds(30))
            precondition(device.transmitted == writes + [15] && output.configurations == confirmedHeadphoneVolume + 1,
                         "Published Sony confirmation reentered the volume writer or lost the Mac volume change")

            output.simulateControls(LDACNativeVolume(scalar: 0.5, muted: true))
            try await waitUntil { controller.volumeTask == nil }
            device.receiveVolume(6)
            try await waitUntil { output.controls.volume(in: 0...30) == 6 && controller.volumeTask == nil }
            precondition(output.controls.muted && raw.gains.last == 0 && device.transmitted == writes + [15],
                         "A headphone volume change cleared mute or sent an unnecessary Sony setter")
            output.simulateControls(LDACNativeVolume(scalar: output.controls.scalar, muted: false))
            try await waitUntil { controller.volumeTask == nil }
            precondition(raw.gains.last == 1 && device.playback.volume == 6)

            output.blocksConfiguration = true
            device.receiveVolume(7)
            try await waitUntil { output.configurationWaiter != nil }
            device.receiveVolume(8)
            devices.objectWillChange.send()
            try await Task.sleep(for: .milliseconds(30))
            output.blocksConfiguration = false
            output.configurationWaiter?.resume()
            output.configurationWaiter = nil
            try await Task.sleep(for: .milliseconds(100))
            precondition(output.controls.volume(in: 0...30) == 8 && controller.volumeTask == nil
                         && controller.pendingVolume == nil && device.transmitted == writes + [15],
                         "A headphone volume change during the asynchronous output reply was lost")
            withExtendedLifetime(relay) {}
            try await stop(controller)
        }
        print("PASS observed volume reconciliation: unchanged/readback/coordinator notifications stay idle, published Sony confirmations do not repeat writes, headphone and Mac changes propagate, mute survives, and changes during an output reply are reconciled")
        if ProcessInfo.processInfo.arguments.contains("--check-volume-observation") { return }

        for initialMute in [Bool?(true), nil, false] {
            let (controller, device, output, raw) = try await started(.v2, supportsMute: true, musicMuted: initialMute)
            output.simulateControls(LDACNativeVolume(scalar: 0.4, muted: false))
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            raw.emit(.active(LDACFormat()))
            try await waitUntil { device.volumeRefreshes == 1 }
            device.receiveStatus()
            device.receiveVolume()
            try await waitUntil { controller.usable && controller.readinessTask == nil }
            precondition(raw.gains.last == (initialMute == false ? 1 : 0),
                         "LDAC admission ignored known or unknown headphone mute")
            precondition(device.transmitted.isEmpty && device.queuedWrite == nil && controller.state == .active(LDACFormat())
                         && raw.recoveries.isEmpty && raw.stops == 0 && !controller.isRecovering,
                         "Headphone mute changed volume or was treated as transport failure during admission")

            device.playback.musicMuted = false
            try await Task.sleep(for: .milliseconds(30))
            precondition(raw.gains.last == 1, "Headphone mute notification did not update raw gain")
            for reportedMute in [Bool?(true), nil, false] {
                let configurations = output.configurations
                device.notifyVolume(device.playback.volume!, muted: reportedMute)
                try await Task.sleep(for: .milliseconds(30))
                precondition(raw.gains.last == (reportedMute == false ? 1 : 0),
                             "Headphone mute notification did not update raw gain")
                let gains = raw.gains
                for _ in 0..<3 { device.notifyVolume(device.playback.volume!, muted: reportedMute) }
                try await Task.sleep(for: .milliseconds(30))
                precondition(raw.gains == gains && output.configurations == configurations && controller.volumeTask == nil
                             && controller.pendingVolume == nil && device.transmitted.isEmpty && device.queuedWrite == nil,
                             "Mute-only reports replayed volume, configured output, or repeated gain writes")
                output.simulateControls(LDACNativeVolume(scalar: output.controls.scalar, muted: true))
                try await waitUntil { controller.volumeTask == nil }
                precondition(raw.gains.last == 0, "Headphone unmute overrode Mac mute")
                output.simulateControls(LDACNativeVolume(scalar: output.controls.scalar, muted: false))
                try await waitUntil { controller.volumeTask == nil }
                precondition(raw.gains.last == (reportedMute == false ? 1 : 0) && device.transmitted.isEmpty,
                             "Mac unmute bypassed headphone mute or replayed volume")
                if reportedMute != false {
                    let volume = device.playback.volume! - 1
                    device.notifyVolume(volume, muted: reportedMute)
                    try await waitUntil { output.controls.volume(in: 0...30) == volume && controller.volumeTask == nil }
                    precondition(raw.gains.last == 0 && device.transmitted.isEmpty,
                                 "A headphone volume notification cleared mute or echoed a setter")
                }
            }
            device.playback.callMuted = true
            try await Task.sleep(for: .milliseconds(30))
            precondition(raw.gains.last == 1, "Call mute changed music output gain")

            device.playback.musicMuted = true
            try await Task.sleep(for: .milliseconds(30))
            output.simulateControls(LDACNativeVolume(scalar: 0.5, muted: false))
            try await waitUntil { device.queuedWrite != nil }
            precondition(device.queuedWrite?.volume == 15 && raw.gains.last == 0,
                         "A deliberate Mac volume change bypassed headphone mute")
            device.transmitVolume()
            device.confirmVolume()
            try await waitUntil { controller.volumeTask == nil }
            precondition(device.playback.musicMuted == true && raw.gains.last == 0 && device.transmitted == [15],
                         "Volume confirmation cleared headphone mute or repeated its setter")

            for reboundMute in [Bool?(true), nil, false] {
                device.statusFresh = false
                controller.controlsChanged()
                precondition(controller.session === raw && raw.recoveries.isEmpty && raw.stops == 0
                             && !controller.isRecovering && !controller.usable && raw.gains.last == 0,
                             "Control-only loss did not silence and revoke writes while retaining the raw session")
                try await waitUntil { device.statusReadPending && device.volumeReadPending }
                output.blocksPreparation = true
                device.playback.musicMuted = false
                device.receiveStatus()
                device.receiveVolume(9)
                try await waitUntil { output.preparationWaiter != nil }
                device.playback.musicMuted = reboundMute
                try await Task.sleep(for: .milliseconds(30))
                precondition(raw.gains.last == 0 && !controller.usable,
                             "A mute report enabled audio before control rebinding completed")
                output.blocksPreparation = false
                output.preparationWaiter?.resume()
                output.preparationWaiter = nil
                try await waitUntil { controller.usable && controller.readinessTask == nil }
                precondition(raw.gains.last == (reboundMute == false ? 1 : 0) && output.controls.volume(in: 0...30) == 9,
                             "Control rebinding ignored the latest headphone mute state")
                precondition(device.transmitted == [15] && device.queuedWrite == nil && controller.session === raw
                             && raw.recoveries.isEmpty && raw.stops == 0 && !controller.isRecovering,
                             "Headphone mute replayed volume or replaced a healthy raw transport")
            }
            output.simulateControls(LDACNativeVolume(scalar: output.controls.scalar, muted: true))
            try await waitUntil { controller.volumeTask == nil }
            device.playback.musicMuted = true
            device.playback.musicMuted = false
            try await Task.sleep(for: .milliseconds(30))
            precondition(raw.gains.last == 0, "A headphone unmute notification cleared Mac mute")
            try await stop(controller)
        }
        let mutedStartup = Controller()
        let mutedDevice = SonyHeadphonesController()
        mutedDevice.playback.generation = .v2
        mutedDevice.playback.supportsMute = true
        mutedDevice.playback.musicMuted = false
        mutedStartup.devices?.controllers[mutedDevice.address] = mutedDevice
        mutedStartup.requestedAddress = mutedDevice.address
        mutedStartup.start(mutedDevice.address)
        let mutedOutput = mutedStartup.nativeOutput!
        mutedOutput.controls = LDACNativeVolume(scalar: 0.4, muted: false)
        mutedOutput.blocksConfiguration = true
        try await waitUntil { mutedDevice.volumeRefreshes == 1 }
        mutedDevice.receiveStatus()
        mutedDevice.receiveVolume()
        try await waitUntil { mutedOutput.configurationWaiter != nil }
        let readbackID = mutedDevice.musicVolumeReadbackID
        mutedDevice.notifyVolume(12, muted: true)
        mutedOutput.blocksConfiguration = false
        mutedOutput.configurationWaiter?.resume()
        mutedOutput.configurationWaiter = nil
        try await waitUntil { mutedStartup.session != nil }
        let mutedRaw = mutedStartup.session!
        mutedOutput.blocksConfiguration = true
        mutedRaw.emit(.handoffReady)
        try await waitUntil { mutedOutput.configurationWaiter != nil }
        mutedDevice.notifyVolume(12, muted: nil)
        mutedOutput.blocksConfiguration = false
        mutedOutput.configurationWaiter?.resume()
        mutedOutput.configurationWaiter = nil
        try await waitUntil { mutedRaw.handoffs == 1 }
        precondition(mutedDevice.musicVolumeReadbackID == readbackID && mutedRaw.gains.last == 0
                     && mutedDevice.transmitted.isEmpty && mutedStartup.requestedAddress == mutedDevice.address,
                     "Mute-only startup notifications invalidated volume admission or enabled raw audio")
        mutedRaw.emit(.active(LDACFormat()))
        try await waitUntil { mutedDevice.volumeRefreshes == 2 }
        mutedDevice.receiveStatus()
        mutedDevice.receiveVolume()
        try await waitUntil { mutedStartup.usable }
        precondition(mutedRaw.gains.last == 0 && mutedDevice.transmitted.isEmpty && mutedRaw.recoveries.isEmpty,
                     "Mute-only startup notifications caused a setter, recovery or audible admission")
        try await stop(mutedStartup)
        print("PASS headphone mute: A2 known mute and unknown mute stay silent through startup, notifications, Mac volume/mute changes and control rebinding; explicit unmute preserves Mac mute; call mute is independent; no mute-driven writes, stops or reconnects")
        if ProcessInfo.processInfo.arguments.contains("--check-headphone-mute") { return }

        for generation in [Generation.v1, .v2] {
            let admission = Controller()
            let device = SonyHeadphonesController()
            device.playback.generation = generation
            device.optionalReadTimedOut = true
            device.allowsVolumeRecovery = false
            admission.devices?.controllers[device.address] = device
            admission.requestedAddress = device.address
            admission.start(device.address)
            try await waitUntil { device.volumeRecoveryAttempts >= 2 }
            let endpoint = admission.nativeOutput!
            let controlSession = device.notificationSession
            precondition(device.volumeRefreshes == 1 && device.refreshes == 0 && device.volumeRecoveries == 0
                         && device.notificationSession == controlSession && admission.session == nil,
                         "Optional-only expiry restarted initial volume controls")
            device.requiredMusicVolumeReadTimedOut = true
            let refusedAttempts = device.volumeRecoveryAttempts
            try await waitUntil { device.volumeRecoveryAttempts >= refusedAttempts + 2 }
            precondition(device.volumeRecoveries == 0 && device.notificationSession == controlSession,
                         "Refused initial volume recovery changed the control session")
            device.allowsVolumeRecovery = true
            try await waitUntil { device.volumeRecoveries == 1 }
            precondition(device.notificationSession == controlSession + 1 && !device.isReady
                         && !device.capabilityFresh && !device.statusFresh && !device.volumeFresh,
                         "Accepted initial volume recovery retained old readback data")
            device.isReady = true
            device.requiredMusicVolumeReadTimedOut = true
            let recoveryAttempts = device.volumeRecoveryAttempts
            try await Task.sleep(for: .milliseconds(250))
            precondition(device.volumeRecoveries == 1 && device.volumeRecoveryAttempts == recoveryAttempts,
                         "A second initial volume timeout restarted the control session")
            device.requiredMusicVolumeReadTimedOut = false
            device.capabilityFresh = true
            try await Task.sleep(for: .milliseconds(120))
            precondition(admission.session == nil && endpoint.configurations == 0,
                         "Initial volume recovery admitted capabilities without status and volume")
            device.receiveVolume()
            try await Task.sleep(for: .milliseconds(120))
            precondition(admission.session == nil && endpoint.configurations == 0,
                         "Initial volume recovery admitted volume without fresh status")
            device.capabilityFresh = false
            device.receiveStatus()
            try await Task.sleep(for: .milliseconds(120))
            precondition(admission.session == nil && endpoint.configurations == 0,
                         "Initial volume recovery admitted status and volume without fresh capabilities")
            device.capabilityFresh = true
            try await waitUntil { admission.session != nil }
            precondition(endpoint.configurations == 1 && !endpoint.selected && !endpoint.ready,
                         "Initial volume recovery handed off before the raw session was ready")
            if generation == .v2 {
                let raw = admission.session!
                raw.emit(.handoffReady)
                try await waitUntil { raw.handoffs == 1 }
                raw.emit(.active(LDACFormat()))
                try await waitUntil { device.volumeRefreshes == 2 }
                device.receiveStatus()
                device.receiveVolume()
                try await waitUntil { device.queuedWrite != nil }
                device.transmitVolume()
                device.confirmVolume()
                try await waitUntil { admission.usable }
                device.requiredMusicVolumeReadTimedOut = true
                device.statusFresh = false
                admission.controlsChanged()
                try await Task.sleep(for: .milliseconds(120))
                precondition(device.volumeRecoveries == 1 && device.volumeRecoveryAttempts == recoveryAttempts
                             && device.notificationSession == controlSession + 1 && !endpoint.ready && !admission.usable,
                             "Active volume monitoring restarted the Sony control session")
            }
            try await stop(admission)
        }
        print("PASS initial volume recovery: optional expiry stays idle; refused recovery retains its allowance; a later required timeout gets one reconnect; all fresh readbacks remain required; active monitoring never reconnects controls")

        let deadlineController = Controller()
        let deadlineDevice = SonyHeadphonesController()
        deadlineController.devices?.controllers[deadlineDevice.address] = deadlineDevice
        deadlineController.requestedAddress = deadlineDevice.address
        deadlineController.start(deadlineDevice.address)
        try await waitUntil { deadlineDevice.volumeRefreshes == 1 }
        let deadlineOutput = deadlineController.nativeOutput!
        try await Task.sleep(for: .seconds(13))
        deadlineDevice.requiredMusicVolumeReadTimedOut = true
        try await waitUntil { deadlineDevice.volumeRecoveries == 1 }
        deadlineDevice.isReady = true
        deadlineDevice.requiredMusicVolumeReadTimedOut = true
        try await Task.sleep(for: .seconds(3))
        precondition(!deadlineController.isSessionRunning && deadlineController.session == nil
                     && deadlineController.requestedAddress == nil && deadlineDevice.volumeRecoveries == 1
                     && deadlineOutput.configurations == 0 && deadlineOutput.restores == [false],
                     "Initial volume recovery extended the startup deadline or admitted missing data")
        if case let .failed(message) = deadlineController.state {
            precondition(message.contains("The headphone volume could not be read"),
                         "Initial volume recovery reported the wrong deadline failure")
        } else { preconditionFailure("Initial volume recovery did not fail at the original deadline") }
        print("PASS initial volume deadline: a late recovery and second timeout still fail within the original 15-second wait and release the silent output")

        let (controller, headphones, output, session) = try await started()
        precondition(controller.hasMusicVolumeForHandoff && !controller.hasOwnedMusicContext,
                     "Legacy raw ownership admitted before active")
        session.emit(.handoffReady)
        try await waitUntil { session.handoffs == 1 }
        precondition(output.selected && !output.ready && session.handoffs == 1)
        precondition(headphones.queuedWrite == nil && session.gains == [0])
        session.emit(.connecting)
        precondition(!controller.hasOwnedMusicContext && !output.ready)

        headphones.isReady = false
        session.emit(.active(LDACFormat()))
        precondition(headphones.refreshes == 1, "Disconnected legacy controls did not retain their reopen request")
        try await Task.sleep(for: .milliseconds(120))
        precondition(headphones.volumeRefreshes == 0 && controller.controlSession == nil && !output.ready)
        headphones.notificationSession += 1
        headphones.isReady = true
        try await waitUntil { headphones.volumeRefreshes == 1 }
        headphones.statusFresh = true
        headphones.statusReadPending = false
        headphones.receiveVolume()
        try await Task.sleep(for: .milliseconds(120))
        precondition(controller.controlSession == nil && headphones.queuedWrite == nil && !output.ready,
                     "Volume without post-admission status admitted legacy LDAC")
        headphones.receiveStatus()
        try await waitUntil { headphones.queuedWrite != nil }
        precondition(!output.ready && session.gains == [0], "An unconfirmed setter unmuted the output")
        headphones.transmitVolume()
        precondition(!output.ready)
        headphones.confirmVolume()
        try await waitUntil { controller.usable }
        precondition(output.ready && output.preparations == 1 && session.gains.last == 1)
        print("PASS actual start/handoff/active/readiness: legacy preparation is silent; delayed controls require new status and volume plus confirmed setter")

        session.emit(.connectionLost("fixture raw loss"))
        precondition(!output.ready && !controller.usable && controller.transportFormat == nil && controller.controlSession == nil)
        precondition(!controller.hasOwnedMusicContext && session.gains.last == 0)
        let refreshes = headphones.volumeRefreshes
        controller.isClassicConnected = { _ in false }
        session.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
        try await waitUntil { controller.session != nil && controller.session !== session }
        let recovered = controller.session!
        precondition(output.restores.isEmpty && controller.requestedAddress == headphones.address,
                     "Deliberate disconnect with usable controls was mistaken for unavailable headphones")
        controller.isClassicConnected = { _ in true }
        let renewedID = controller.sessionID
        session.emit(.active(LDACFormat(value: 99)))
        precondition(controller.sessionID == renewedID && controller.transportFormat == nil)
        recovered.emit(.handoffReady)
        try await waitUntil { recovered.handoffs == 1 }
        precondition(!output.ready)
        recovered.emit(.active(LDACFormat()))
        try await waitUntil { headphones.volumeRefreshes == refreshes + 1 }
        precondition(headphones.refreshes == 1, "Ready legacy controls redundantly refreshed unrelated settings")
        headphones.receiveStatus()
        try await Task.sleep(for: .milliseconds(120))
        precondition(controller.controlSession == nil && !output.ready,
                     "Status without post-recovery volume admitted legacy LDAC")
        headphones.receiveVolume(headphones.playback.volume!)
        try await waitUntil { controller.usable }
        precondition(output.ready && output.preparations == 2 && headphones.transmitted.count == 1)
        print("PASS actual recovery: same Sony session needs both new replies; old raw-session events cannot re-admit; equal confirmed volume avoids a redundant setter")

        controller.pendingVolume = 6
        controller.sendPendingVolume()
        try await waitUntil { headphones.queuedWrite != nil }
        recovered.emit(.connectionLost("fixture queued loss"))
        headphones.transmitVolume()
        precondition(headphones.transmitted.count == 1 && !output.ready && !controller.hasOwnedMusicContext)
        try await stop(controller)
        print("PASS actual volume task: raw loss revokes the queued write token before fake transmission")

        for changed in ["range", "control-session", "target", "stop"] {
            let (bound, device, endpoint, raw) = try await started()
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            raw.emit(.active(LDACFormat()))
            try await waitUntil { device.volumeRefreshes == 1 }
            device.receiveStatus()
            device.receiveVolume()
            try await waitUntil { device.queuedWrite != nil }
            if changed == "range" { device.playback.musicVolumeRange = 0...20 }
            else if changed == "control-session" { device.notificationSession += 1 }
            else if changed == "stop" { bound.stop(reason: "fixture queued stop") }
            else {
                let returning = SonyHeadphonesController()
                returning.isDeviceConnected = false
                returning.isReady = false
                bound.devices?.controllers[device.address] = returning
            }
            bound.controlsChanged()
            if changed == "target" {
                precondition(bound.requestedAddress == device.address && bound.suspensionRequested)
                precondition(bound.state == .stopping && raw.audioRestorations == [false])
                raw.emit(.finished(.init(message: nil, targetDisconnected: true)))
                try await waitUntil { !bound.isSessionRunning }
                precondition(bound.requestedAddress == device.address && bound.state == .waitingForDevice)
            }
            device.transmitVolume()
            precondition(device.transmitted.isEmpty && !endpoint.ready && !bound.usable,
                         "Changed \(changed) retained queued legacy volume ownership")
            try await stop(bound)
        }
        print("PASS actual binding: range, Sony control session, controller replacement and stop revoke queued writes")

        let (modern, modernDevice, modernOutput, modernRaw) = try await started(.v2)
        precondition(modern.hasOwnedMusicContext)
        modernRaw.emit(.handoffReady)
        try await waitUntil { modernRaw.handoffs == 1 }
        modernRaw.emit(.active(LDACFormat()))
        try await waitUntil { modernDevice.volumeRefreshes == 1 || modernDevice.refreshes != 0 }
        precondition(modernDevice.volumeRefreshes == 1 && modernDevice.refreshes == 0,
                     "Ready modern controls used destructive full refresh")
        modernDevice.receiveStatus()
        modernDevice.receiveVolume()
        try await waitUntil { modernDevice.queuedWrite != nil }
        precondition(modernDevice.volumeRefreshes == 1 && modernDevice.settingsRefreshes == 0 && !modernOutput.ready)
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.usable }
        let transmitted = modernDevice.transmitted
        let silences = modernOutput.silences
        modernDevice.blocksPlaybackCommands = true
        modern.pendingVolume = 7
        modern.controlsChanged()
        try await Task.sleep(for: .milliseconds(150))
        precondition(modern.bindingIsCurrent && modern.usable && modernOutput.ready && !modern.isRecovering
                     && modern.session === modernRaw && modernOutput.silences == silences,
                     "A temporary command block discarded active LDAC ownership")
        precondition(modern.pendingVolume == 7 && modernDevice.queuedWrite == nil && modernDevice.transmitted == transmitted,
                     "A blocked Sony volume command was submitted")
        modernDevice.blocksPlaybackCommands = false
        modern.controlsChanged()
        try await waitUntil { modernDevice.queuedWrite != nil }
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.volumeTask == nil }
        precondition(modern.usable && modernOutput.ready && !modern.isRecovering && modernDevice.playback.volume == 7,
                     "Volume did not resume on the original LDAC session")
        modernDevice.blocksPlaybackCommands = true
        modernDevice.localSource = false
        modern.controlsChanged()
        precondition(!modernOutput.ready && !modern.usable)
        try await stop(modern)
        print("PASS existing v2 path: temporary command blocks retain active audio and defer volume; unblocking resumes writes; real source loss still revokes ownership")

        for generation in [Generation.v1, .v2] {
            for changed in ["freshness", "control-session"] {
                let (bound, device, endpoint, raw) = try await active(generation)
                let identifier = bound.sessionID
                let format = bound.transportFormat
                let refreshes = device.volumeRefreshes
                let settingsRefreshes = device.settingsRefreshes
                let transmitted = device.transmitted
                let volume = device.playback.volume!
                device.statusReadPending = true
                device.volumeReadPending = true
                bound.controlsChanged()
                try await waitUntil { bound.volumeTask == nil }
                precondition(!device.hasFreshMusicVolumeReadback && bound.bindingIsCurrent && bound.usable && endpoint.ready
                             && raw.recoveries.isEmpty && raw.stops == 0,
                             "An ordinary in-flight read discarded an authenticated volume binding")
                device.receiveStatus()
                device.receiveVolume(volume)
                bound.pendingVolume = 7
                bound.sendPendingVolume()
                try await waitUntil { device.queuedWrite != nil }
                if changed == "freshness" { device.statusFresh = false }
                else { device.isReady = false; device.notificationSession += 1 }
                bound.controlsChanged()
                device.transmitVolume()
                precondition(!endpoint.ready && !bound.usable && bound.controlSession == nil
                             && raw.gains.last == 0 && raw.recoveries.isEmpty && raw.stops == 0
                             && bound.transportFormat == format && bound.session === raw && bound.sessionID == identifier
                             && device.transmitted == transmitted,
                             "Control-only loss did not silence and revoke writes while retaining the raw session")
                device.isReady = true
                try await waitUntil { device.volumeRefreshes == refreshes + 1 && device.continuation == nil }
                precondition(device.settingsRefreshes == settingsRefreshes && device.volumeRecoveries == 0,
                             "Control rebinding refreshed unrelated settings or restarted Sony controls")
                device.receiveVolume(volume)
                try await Task.sleep(for: .milliseconds(120))
                precondition(!endpoint.ready && !bound.usable && bound.controlSession == nil && device.queuedWrite == nil,
                             "Control rebinding admitted a new volume without a new status reply")
                device.receiveStatus()
                try await waitUntil { bound.usable }
                precondition(endpoint.ready && bound.session === raw && bound.sessionID == identifier
                             && bound.transportFormat == format && raw.recoveries.isEmpty && raw.stops == 0
                             && raw.gains.last == 1 && device.transmitted == transmitted,
                             "Fresh controls did not resume the original live raw session")
                try await stop(bound)
            }
        }
        print("PASS control-only rebinding: ordinary in-flight reads preserve binding; stale replies and replaced Sony sessions silence and revoke queued writes; both fresh replies resume the same raw owner without recovery")

        for generation in [Generation.v1, .v2] {
            for change in ["headphones", "mute", "mac-volume", "mac-volume-return"] {
                let (bound, device, endpoint, raw) = try await active(generation)
                let writes = device.transmitted
                device.statusFresh = false
                bound.controlsChanged()
                try await waitUntil { device.statusReadPending && device.volumeReadPending }
                if change == "mute" { endpoint.simulateControls(LDACNativeVolume(scalar: 0.8, muted: true)) }
                if change == "mac-volume" { endpoint.simulateControls(LDACNativeVolume(scalar: 0.5, muted: false)) }
                if change == "mac-volume-return" {
                    endpoint.simulateControls(LDACNativeVolume(scalar: 0.5, muted: false))
                    endpoint.simulateControls(LDACNativeVolume(scalar: 0.8, muted: false))
                }
                device.receiveStatus()
                device.receiveVolume(6)
                let expectedVolume = change == "mac-volume" ? 15 : change == "mac-volume-return" ? 24 : 6
                if change.hasPrefix("mac-volume") {
                    try await waitUntil { device.queuedWrite != nil || bound.usable }
                    precondition(device.queuedWrite?.volume == expectedVolume && !bound.usable && !endpoint.ready,
                                 "A newer Mac volume request was lost or admitted before confirmation")
                    device.transmitVolume()
                    device.confirmVolume()
                } else {
                    try await waitUntil { bound.usable || device.queuedWrite != nil }
                    precondition(device.queuedWrite == nil,
                                 "Rebinding replayed the old Mac volume over a lower headphone readback")
                }
                try await waitUntil { bound.usable }
                precondition(device.playback.volume == expectedVolume && endpoint.controls.volume(in: 0...30) == expectedVolume
                             && endpoint.controls.muted == (change == "mute") && raw.gains.last == (change == "mute" ? 0 : 1)
                             && raw.recoveries.isEmpty && raw.stops == 0 && bound.session === raw,
                             "Rebinding overwrote fresh headphone volume or lost a newer Mac volume/mute request")
                precondition(device.transmitted == (change.hasPrefix("mac-volume") ? writes + [expectedVolume] : writes),
                             "Rebinding replayed the old Mac volume over a lower headphone readback")
                try await stop(bound)
            }
        }
        print("PASS rebind volume ownership: a lower headphone volume updates the Mac without a setter; mute alone cannot replay old volume; a newer Mac scalar requires headphone confirmation")

        let (interruptedPreparation, preparationDevice, preparationOutput, preparationRaw) = try await active(.v2)
        let preparationWrites = preparationDevice.transmitted
        let preparationRefreshes = preparationDevice.volumeRefreshes
        preparationDevice.statusFresh = false
        interruptedPreparation.controlsChanged()
        try await waitUntil { preparationDevice.statusReadPending && preparationDevice.volumeReadPending }
        preparationOutput.blocksPreparation = true
        preparationDevice.receiveStatus()
        preparationDevice.receiveVolume(6)
        try await waitUntil { preparationOutput.preparationWaiter != nil }
        precondition(preparationOutput.controls.volume(in: 0...30) == 6 && !interruptedPreparation.usable)
        preparationDevice.statusFresh = false
        interruptedPreparation.controlsChanged()
        preparationOutput.simulateControls(LDACNativeVolume(scalar: 0.2, muted: true))
        preparationOutput.blocksPreparation = false
        preparationOutput.preparationWaiter?.resume()
        preparationOutput.preparationWaiter = nil
        try await waitUntil { preparationDevice.volumeRefreshes == preparationRefreshes + 2 }
        precondition(!preparationOutput.ready && !interruptedPreparation.usable && preparationRaw.recoveries.isEmpty)
        preparationDevice.receiveStatus()
        preparationDevice.receiveVolume(3)
        try await waitUntil { interruptedPreparation.usable }
        precondition(preparationDevice.transmitted == preparationWrites && preparationDevice.playback.volume == 3
                     && preparationOutput.controls.volume(in: 0...30) == 3 && preparationOutput.controls.muted
                     && preparationRaw.recoveries.isEmpty && preparationRaw.stops == 0,
                     "Repeated rebinding mistook its own volume mirror or a mute for a new Mac scalar request")
        try await stop(interruptedPreparation)
        print("PASS interrupted preparation: loss during finishPreparation reuses the same wait; repeated lower headphone readbacks and a mute never replay our own earlier volume mirror")

        for interruption in ["raw-loss", "other-source", "stop"] {
            let (bound, device, endpoint, raw) = try await active(.v2)
            device.statusFresh = false
            bound.controlsChanged()
            try await waitUntil { device.statusReadPending && device.volumeReadPending }
            if interruption == "raw-loss" { raw.emit(.connectionLost("fixture raw loss during control wait")) }
            else if interruption == "stop" { bound.stop(reason: "fixture stop during control wait") }
            else {
                device.localSource = false
                device.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
            }
            device.receiveStatus()
            device.receiveVolume()
            bound.controlsChanged()
            try await Task.sleep(for: .milliseconds(150))
            precondition(!bound.usable && !endpoint.ready && bound.readinessTask == nil && raw.recoveries.isEmpty,
                         "An interrupted control rebind re-admitted audio or requested redundant raw recovery")
            if interruption == "raw-loss" {
                precondition(bound.isRecovering && bound.transportFormat == nil && raw.stops == 0,
                             "Actual raw loss did not retain full connection recovery")
            } else {
                precondition(raw.stops == 1 && bound.state == .stopping,
                             "Stop or another music source did not stop the raw owner")
            }
            try await stop(bound)
        }
        print("PASS control-wait interruption: actual raw loss revokes transport ownership; explicit stop and a different music source cancel the wait and stay silent")

        let (expired, expiredDevice, expiredOutput, expiredRaw) = try await active(.v2)
        let expiredVolume = expiredDevice.playback.volume!
        expiredDevice.statusFresh = false
        expired.controlsChanged()
        try await waitUntil { expiredDevice.statusReadPending && expiredDevice.volumeReadPending }
        expiredOutput.simulateControls(LDACNativeVolume(scalar: 0.2, muted: false))
        try await Task.sleep(for: .seconds(26))
        expiredDevice.receiveStatus()
        expiredDevice.receiveVolume(expiredVolume)
        try await waitUntil { expiredDevice.queuedWrite != nil }
        expiredDevice.statusFresh = false
        expired.controlsChanged()
        expiredDevice.transmitVolume()
        try await waitUntil { expiredDevice.statusReadPending && expiredDevice.volumeReadPending }
        try await Task.sleep(for: .seconds(5))
        precondition(!expired.usable && !expiredOutput.ready && expired.state == .stopping
                     && expired.requestedAddress == nil && expiredRaw.stops == 1 && expiredRaw.recoveries.isEmpty
                     && expired.recoveryTask == nil && expired.readinessTask == nil,
                     "Repeated control loss renewed the original readiness deadline or restarted raw recovery")
        expiredDevice.receiveStatus()
        expiredDevice.receiveVolume()
        expired.controlsChanged()
        precondition(expiredRaw.stops == 1 && !expired.usable,
                     "Late controls restarted an expired rebind")
        expiredRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { !expired.isSessionRunning }
        precondition(expiredOutput.restores == [false], "Expired controls did not release the silent output")
        if case let .failed(message) = expired.state {
            precondition(message.contains("The headphone volume could not be confirmed"))
        } else { preconditionFailure("Expired controls did not report the readiness failure") }
        print("PASS control-wait deadline: repeated loss retains the original 30-second deadline, stops once without raw recovery, releases output, and rejects late replies")

        for (controlsConnected, cleanupFails) in [(false, false), (true, false), (false, true)] {
            let (cased, casedDevice, casedOutput, casedRaw) = try await started(.v2)
            casedRaw.emit(.handoffReady)
            try await waitUntil { casedOutput.selected }
            casedDevice.isReady = false
            casedDevice.isDeviceConnected = controlsConnected
            cased.isClassicConnected = { _ in false }
            if cleanupFails { casedOutput.restoreError = "Fixture lease release failed" }
            casedRaw.emit(.connectionLost("Controls lost before deliberate recovery disconnect"))
            casedRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: false)))
            precondition(cased.session == nil && cased.recoveryTask != nil)
            try await waitUntil { !cased.isSessionRunning }
            precondition(cased.session == nil && cased.recoveryTask == nil && cased.nativeOutput == nil)
            precondition(casedOutput.recoveryPreparations == 1 && casedOutput.restores == [true] && !casedOutput.selected,
                         "Unavailable controls after deliberate disconnect retained the virtual output")
            precondition(casedDevice.connectionRequests.isEmpty,
                         "Unavailable headphones launched ordinary Bluetooth restoration")
            if cleanupFails {
                precondition(cased.state == .failed("Fixture lease release failed") && cased.requestedAddress == nil,
                             "A real output cleanup failure was hidden")
            } else {
                precondition(cased.state == .waitingForDevice && cased.requestedAddress == casedDevice.address,
                             "Safe disconnect discarded LDAC intent")
                for _ in 0..<100 { cased.resumeIfReady() }
                precondition(cased.session == nil && cased.recoveryTask == nil)
                cased.audioRoute?.route = Route(uid: "fixture-speakers")
                casedDevice.isReady = true
                casedDevice.isDeviceConnected = true
                cased.isClassicConnected = { _ in true }
                cased.resumeIfReady()
                precondition(cased.session == nil && cased.audioRoute?.route?.uid == "fixture-speakers",
                             "Device return replaced the user's subsequently selected output")
                cased.audioRoute?.route = Route(uid: "fixture-headphones")
                cased.resumeIfReady()
                try await waitUntil { casedDevice.statusReadPending && casedDevice.volumeReadPending }
                casedDevice.receiveStatus()
                casedDevice.receiveVolume()
                try await waitUntil { cased.session != nil }
                try await stop(cased)
            }
        }
        print("PASS actual incident sequence: controls unavailable, safe deliberate disconnect without waitForReconnect, retry exits by releasing output and preserving intent; cleanup errors remain explicit and external route guards hold")

        let (resuming, returning, oldOutput, oldSession) = try await started(.v2)
        let originalPreference = UUID()
        returning.lastConnectionModeChangeID = originalPreference
        resuming.connectionModeRestoreID = originalPreference
        resuming.connectionModeConfirmed = true
        returning.isDeviceConnected = false
        oldSession.emit(.connectionLost("Headphones returned to case"))
        oldSession.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: true)))
        try await waitUntil { resuming.state == .waitingForDevice }
        precondition(!resuming.isSessionRunning && resuming.session == nil && !oldOutput.selected)
        precondition(resuming.deferredConnectionModes[returning.address] == originalPreference)
        for _ in 0..<100 { resuming.resumeIfReady() }
        precondition(resuming.session == nil && resuming.recoveryTask == nil && returning.connectionRequests.isEmpty)
        returning.isDeviceConnected = true
        resuming.resumeIfReady()
        try await waitUntil { returning.statusReadPending && returning.volumeReadPending }
        returning.receiveStatus()
        returning.receiveVolume()
        try await waitUntil { resuming.session != nil }
        let resumedSession = resuming.session!
        precondition(resumedSession !== oldSession && resuming.headphones === returning)
        precondition(resuming.connectionModeRestoreID == originalPreference && resuming.deferredConnectionModes.isEmpty,
                     "Actual resume dropped the original Stable Connection obligation")
        oldSession.emit(.failed("Stale session failure"))
        precondition(resuming.requestedAddress == returning.address && resuming.session === resumedSession)
        resuming.stop(restoreAudio: false, reason: "User disabled LDAC after resume")
        resumedSession.emit(.finished(.init(message: nil)))
        try await waitUntil { returning.connectionRequests == [.stableConnection] }
        returning.confirmConnectionMode(.stableConnection)
        try await waitUntil { !resuming.isSessionRunning }
        precondition(resuming.state == .off && resuming.requestedAddress == nil)
        print("PASS actual case-disconnect completion and resumed start: waiting releases output, notifications stay idle, stale events are ignored, and original Stable Connection is restored after manual Off")

        let (manual, manualDevice, _, manualRaw) = try await started(.v2)
        manualDevice.isDeviceConnected = false
        manual.stop(reason: "User disabled LDAC during disconnect")
        manualRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true, waitForReconnect: true)))
        try await waitUntil { !manual.isSessionRunning }
        precondition(manual.session == nil && manual.state == .off,
                     "Manual Off launched a restoration helper for absent headphones")

        let (forced, _, _, forcedRaw) = try await started(.v2)
        forced.stop(reason: "User disabled LDAC after deliberate recovery disconnect")
        forcedRaw.emit(.finished(.init(message: nil, canRetry: true, targetDisconnected: true)))
        let restorationOnly = forced.session
        precondition(restorationOnly != nil && restorationOnly !== forcedRaw && restorationOnly?.restoringOnly == true,
                     "Manual Off skipped native-audio restoration after our deliberate disconnect")
        restorationOnly?.emit(.finished(.init(message: nil)))
        try await waitUntil { !forced.isSessionRunning }
        precondition(forced.session == nil && forced.state == .off)

        for changedOutput in [false, true] {
            let (deselected, device, output, raw) = try await started(.v2)
            raw.emit(.handoffReady)
            try await waitUntil { raw.handoffs == 1 }
            deselected.audioRoute?.route = Route(uid: "fixture-speakers")
            output.changed(.failure(LDACOwnerError(outputDeselected: true)))
            precondition(device.isDeviceConnected && raw.audioRestorations == [false] && !output.ready,
                         "Route-first loss requested an ordinary Bluetooth reconnect")
            deselected.isClassicConnected = { _ in false }
            raw.emit(.finished(.init(message: nil, targetDisconnected: true, waitForReconnect: true)))
            try await waitUntil { deselected.state == .waitingForDevice }
            precondition(output.restores == [true] && output.restoredHeadphoneOutputs == [false] && !output.selected)
            precondition(deselected.session == nil && deselected.requestedAddress == device.address)
            deselected.audioRoute?.route = Route(uid: changedOutput ? "fixture-speakers" : "fixture-headphones")
            deselected.resumeIfReady()
            precondition(deselected.session == nil, "LDAC resumed before the headphones returned")
            deselected.isClassicConnected = { _ in true }
            deselected.resumeIfReady()
            if changedOutput {
                precondition(deselected.state == .waitingForDevice && deselected.session == nil,
                             "Device return overrode the selected speakers")
            } else {
                try await waitUntil { device.statusReadPending && device.volumeReadPending }
                device.receiveStatus()
                device.receiveVolume()
                try await waitUntil { deselected.session != nil }
                precondition(deselected.session !== raw && deselected.session?.restoringOnly == false)
            }
            try await stop(deselected)
        }
        print("PASS route-first physical loss releases LDAC without restoring Bluetooth audio and only resumes on the original output")

        let (otherSource, sourceDevice, sourceOutput, sourceRaw) = try await started(.v2)
        sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
        sourceDevice.localSource = false
        sourceDevice.statusFresh = false
        sourceDevice.volumeFresh = false
        sourceDevice.multipoint.inventoryIsStale = true
        precondition(!otherSource.hasOtherMusicSource, "A stale source was treated as a confirmed phone handoff")
        sourceDevice.multipoint.inventoryIsStale = false
        otherSource.controlsChanged()
        precondition(otherSource.requestedAddress == sourceDevice.address && sourceRaw.stops == 1)
        precondition(sourceRaw.audioRestorations == [false], "Phone playback triggered ordinary Mac Bluetooth audio restoration")
        sourceRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { otherSource.state == .waitingForDevice }
        precondition(sourceOutput.restores == [false] && sourceOutput.restoredHeadphoneOutputs == [false] && !sourceOutput.selected)
        for _ in 0..<10 { otherSource.resumeIfReady() }
        precondition(otherSource.session == nil, "LDAC took over another multipoint source")
        sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:02")
        sourceDevice.localSource = true
        otherSource.resumeIfReady()
        try await waitUntil { sourceDevice.statusReadPending && sourceDevice.volumeReadPending }
        sourceDevice.receiveStatus()
        sourceDevice.receiveVolume()
        try await waitUntil { otherSource.session != nil }
        try await stop(otherSource)

        let (phoneBeforeStop, phoneDevice, phoneOutput, phoneRaw) = try await started(.v2)
        phoneDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
        phoneDevice.localSource = false
        let phonePreference = UUID()
        phoneDevice.connectionMode = .soundQuality
        phoneDevice.lastConnectionModeChangeID = phonePreference
        phoneBeforeStop.connectionModeRestoreID = phonePreference
        phoneBeforeStop.connectionModeConfirmed = true
        phoneBeforeStop.stop(reason: "User disabled LDAC while the phone was selected")
        precondition(phoneRaw.audioRestorations == [false])
        phoneRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { phoneBeforeStop.state == .off }
        precondition(phoneOutput.restoredHeadphoneOutputs == [false] && phoneBeforeStop.session == nil)
        precondition(phoneDevice.connectionRequests.isEmpty && phoneBeforeStop.deferredConnectionModes[phoneDevice.address] == phonePreference)
        phoneDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:02")
        phoneDevice.localSource = true
        phoneBeforeStop.resumeIfReady()
        try await waitUntil { phoneDevice.connectionRequests == [.stableConnection] }
        phoneDevice.confirmConnectionMode(.stableConnection)
        try await waitUntil { phoneBeforeStop.preferenceRestoreTasks.isEmpty }
        print("PASS actual completion routing: manual Off never reconnects absent headphones; another multipoint source holds resume until the Mac is confirmed")
        for initiallyConnected in [false, true] {
            let (bounded, recoveringDevice, _, originalRaw) = try await started(.v2)
            var previous = originalRaw
            for _ in 0..<2 {
                previous.emit(.connectionLost("Fixture control loss"))
                previous.emit(.finished(.init(message: nil, canRetry: true)))
                try await waitUntil { bounded.session != nil && bounded.session !== previous }
                previous = bounded.session!
                precondition(!previous.restoringOnly, "Recovery restored audio before using its bounded attempts")
            }
            previous.emit(.finished(.init(message: nil, canRetry: true)))
            let exhaustedRestore = bounded.session
            precondition(exhaustedRestore?.restoringOnly == true, "Exhausted recovery did not restore ordinary audio")
            recoveringDevice.isDeviceConnected = initiallyConnected
            bounded.isClassicConnected = { _ in initiallyConnected }
            recoveringDevice.isReady = false
            recoveringDevice.notificationSession += 1
            exhaustedRestore?.emit(.finished(.init(message: nil)))
            try await waitUntil { bounded.state == .waitingForDevice }
            for _ in 0..<100 { bounded.resumeIfReady() }
            precondition(bounded.session == nil && bounded.requestedAddress == recoveringDevice.address,
                         "Unchanged controls restarted exhausted recovery or lost remembered LDAC intent")
            recoveringDevice.isDeviceConnected = true
            bounded.isClassicConnected = { _ in true }
            bounded.resumeIfReady()
            for _ in 0..<3 {
                recoveringDevice.isDeviceConnected = false
                recoveringDevice.isReady = false
                recoveringDevice.notificationSession += 1
                bounded.resumeIfReady()
                recoveringDevice.isDeviceConnected = true
                recoveringDevice.isReady = true
                bounded.resumeIfReady()
                precondition(bounded.session == nil && bounded.state == .waitingForDevice
                             && bounded.recoveryAttempt == 2 && bounded.recoveryPaused,
                             "Cleanup or automatic control reconnect renewed exhausted recovery")
            }
            recoveringDevice.isDeviceConnected = false
            bounded.isClassicConnected = { _ in false }
            recoveringDevice.isReady = false
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "A disconnected device restarted exhausted recovery")
            recoveringDevice.isDeviceConnected = true
            bounded.isClassicConnected = { _ in true }
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "Device return bypassed control readiness")
            recoveringDevice.isReady = true
            recoveringDevice.localSource = false
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "Device return bypassed source ownership")
            recoveringDevice.localSource = true
            bounded.audioRoute?.route = Route(uid: "fixture-speakers")
            bounded.resumeIfReady()
            precondition(bounded.session == nil, "Device return bypassed the selected Mac output")
            bounded.audioRoute?.route = Route(uid: "fixture-headphones")
            bounded.resumeIfReady()
            try await waitUntil { recoveringDevice.statusReadPending && recoveringDevice.volumeReadPending }
            recoveringDevice.receiveStatus()
            recoveringDevice.receiveVolume()
            try await waitUntil { bounded.session != nil }
            precondition(bounded.recoveryAttempt == 0 && !bounded.recoveryPaused,
                         "An observed device disconnect and return did not renew bounded recovery")
            try await stop(bounded)
        }
        print("PASS actual recovery loop: two retries, restore-only completion, induced control reconnect remains paused, and a later device disconnect/return resumes with source/output guards")
        print("PASS scope: production controller methods and volume mapping; real Combine observation; fake transport, confirmations and native output; no hardware or installation")
    }
}
'''
names = ["canChangeConfiguration", "updateConfiguration", "handleOutputDeselection", "observeDeselectedSourceReturn", "needsStopBeforeTermination", "nextRecoveryDelay", "canResumeRecovery", "deviceUnavailableReason", "refreshDriverState", "captureMenuBarControls", "captureMenuBarControlsFromActiveSession", "start", "validateSourceResume", "selectMacAudioSource", "launch", "hasMusicControlTarget", "hasReadableMusicVolumeForHandoff", "hasMusicVolumeForHandoff", "hasOwnedMusicContext",
         "hasOtherMusicSource", "selectAudioSource", "beginPhoneHandoff", "observePhoneSource", "phoneHandoffIsCurrent",
         "sendPendingPhoneSelection", "waitForQueuedPhoneSelection", "handlePhoneHeld", "resumePhoneHandoffIfReady", "verifyPhoneOutput", "clearPhoneHandoff", "observeControls",
         "bindingIsCurrent", "musicControlStatus", "waitForControls", "controlsChanged",
         "rebindControls", "sendPendingVolume", "setOutputGain", "fail", "beginRecovery", "scheduleRecovery", "cancelMultipointRequest", "cancelPreparation", "stop", "stopSession",
         "suspend", "resumeIfReady", "reconcileConnectionPreferences", "forgetConnectionPreference", "scheduleConnectionPreferenceRestoration", "prepareConnectionMode", "waitForConnectionChange", "restoreConnectionMode",
         "restoreConnectionPreference", "returnStartupSource", "finish", "completeStop"]
fixture = fixture.replace("precondition(", "check(")
fixture = fixture.replace("__DRIVER_STATES__", driver_states).replace("__VOLUME__", volume).replace("__TRANSFER__", transfer).replace("__METHODS__", "\n".join(member(name) for name in names))

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-controller-volume-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    environment = os.environ.copy()
    environment["ACOUPLET_TESTING"] = "1"
    environment["CFFIXED_USER_HOME"] = str(directory / "home")
    Path(environment["CFFIXED_USER_HOME"]).mkdir()
    environment["CLANG_MODULE_CACHE_PATH"] = str(directory / "module-cache")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                   env=environment, check=True)
    arguments = ["--check-source-return"] if "--check-source-return" in sys.argv else ["--check-source-preflight"] if "--check-source-preflight" in sys.argv else ["--check-handoff-refresh"] if "--check-handoff-refresh" in sys.argv or "--check-handoff-mutations" in sys.argv else ["--check-volume-observation"] if "--check-volume-observation" in sys.argv else ["--check-headphone-mute"] if "--check-mute-mutations" in sys.argv or "--check-headphone-mute" in sys.argv else []
    for check in ["--check-live-configuration", "--check-readable-handoff", "--check-output-deselection", "--check-route-first-source-return", "--check-startup-output-deselection", "--check-pending-source-return", "--check-phone-handoff", "--check-cold-controls-overlap"]:
        if check in sys.argv: arguments = [check]
    subprocess.run([str(binary), *arguments], env=environment, check=True)
    if "--check-mutations" in sys.argv or "--check-mute-mutations" in sys.argv or "--check-handoff-mutations" in sys.argv:
        mutations = [
            ("handoff refresh wait", "if headphones.hasFreshReadableMusicVolumeReadback { break }", "break",
             "Routine playback refresh aborted handoff instead of awaiting its existing reads"),
            ("headphone mute gain", "let gain = headphones?.playback.supportsMute == true && headphones?.playback.musicMuted != false ? 0 : gain",
             "", "LDAC admission ignored known or unknown headphone mute"),
            ("headphone mute unknown state", "headphones?.playback.musicMuted != false",
             "headphones?.playback.musicMuted == true", "Headphone mute notification did not update raw gain"),
            ("headphone mute observation", "if usable { setOutputGain(nativeOutput?.controls.muted == false ? 1 : 0) }",
             "", "Headphone mute notification did not update raw gain"),
            ("volume reply reconciliation", "self.volumeTaskID = nil\n                    self.controlsChanged()", "self.volumeTaskID = nil",
             "A headphone volume change during the asynchronous output reply was lost"),
            ("modern settings refresh", "if headphones?.isReady != true { headphones?.refresh() }", "headphones?.refresh()",
             "Ready modern controls used destructive full refresh"),
            ("targeted startup refresh", "if IOBluetoothDevice(addressString: address)?.isClassicConnected() == true { headphones.refreshMusicVolume() }",
             "if IOBluetoothDevice(addressString: address)?.isClassicConnected() == true { headphones.refresh() }",
             "LDAC startup refreshed unrelated settings or admitted stale volume"),
            ("initial recovery limit", "if !recoveredVolumeControls, headphones.recoverMusicVolumeIfNeeded() {",
             "if headphones.recoverMusicVolumeIfNeeded() {",
             "A second initial volume timeout restarted the control session"),
            ("initial volume deadline", "let deadline = Date().addingTimeInterval(15)",
             "let deadline = Date().addingTimeInterval(30)",
             "Initial volume recovery extended the startup deadline or admitted missing data"),
            ("raw", "hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)",
             "hasMusicVolumeForHandoff", "Legacy raw ownership admitted before active"),
            ("status", "headphones.musicStatusReadbackID != nil, headphones.musicStatusReadbackID != initialStatusReadbackID,",
             "", "Volume without post-admission status admitted legacy LDAC"),
            ("control-only recovery", "if readinessTask == nil { waitForControls(address, rebinding: true) }",
             'beginRecovery(reason: "fixture control loss")\n        session?.recoverConnection(reason: "fixture control loss")',
             "Control-only loss did not silence and revoke writes while retaining the raw session"),
            ("native volume provenance", "if controls.scalar != self.lastNativeVolumeScalar { self.nativeVolumeChangeID = UUID() }",
             "", "A newer Mac volume request was lost or admitted before confirmation"),
        ]
        for name, before, after, failure in mutations:
            if "--check-handoff-mutations" in sys.argv and not name.startswith("handoff"): continue
            if "--check-mute-mutations" in sys.argv and not name.startswith("headphone mute"): continue
            assert fixture.count(before) == 1
            swift.write_text(fixture.replace(before, after))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                           env=environment, check=True)
            mutation_arguments = ["--check-handoff-refresh"] if name.startswith("handoff") else arguments or ["--skip-handoff-refresh"]
            result = subprocess.run([str(binary), *mutation_arguments], env=environment, capture_output=True, text=True)
            assert result.returncode == 1 and failure in result.stderr, (name, result.returncode, result.stdout, result.stderr)
            print(f"PASS mutation rejected: missing {name} admission witness")
