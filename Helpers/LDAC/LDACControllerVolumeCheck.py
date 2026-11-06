import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[2]
source = (root / "Sources/LDACController.swift").read_text()
output_source = (root / "Sources/LDACNativeOutput.swift").read_text()


def member(name):
    match = re.search(r"^    (?:private )?(?:func|var) " + name + r"\b", source, re.MULTILINE)
    end = re.search(r"^    (?:(?:private )?(?:func|var|struct) |#(?:if|endif)\b)", source[match.end():], re.MULTILINE)
    return re.sub(r"^    private ", "    ", source[match.start():match.end() + end.start()], flags=re.MULTILINE)


volume = output_source[output_source.index("struct LDACNativeVolume:"):output_source.index("\nstruct LDACRouteRecovery")]
fixture = r'''
import Foundation
import Combine

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Fixture assertion failed") {
    if !condition() {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
        exit(1)
    }
}

enum Generation { case v1, v2 }
enum Model { case unknown, wfXM3, whCH720N, whXM4, wfXM5; var name: String { "fixture" } }
struct LDACFormat: Equatable { var value = 1 }
enum LDACState: Equatable { case off, requested, waitingForDevice, connecting, active(LDACFormat), stopping, failed(String) }
enum LDACAudioCaptureAccess { case unchecked, checking, ready, permissionRequired }
enum LDACQuality { case connection, balanced, quality, adaptive }
struct LDACConfiguration: Equatable { var sampleRate = 48000; var quality = LDACQuality.connection }
struct LDACPriorityControl {}
struct LDACPriorityCleanupError: Error {}
struct LDACOwnerError: Error { var outputDeselected = false }
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
}
@MainActor
enum LDACDriverInstaller {
    enum State { case current }
    static func inspect(bundle: Bundle) -> State { .current }
}

__VOLUME__

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
    struct Source { var address: String }
    struct Multipoint { var selectedSource: Source? }
    struct VolumeWrite { let volume: Int; let isCurrent: (() -> Bool)? }
    var deviceModel = Model.whXM4
    var address = "02:00:00:00:00:01"
    @Published var playback = Playback()
    var multipoint = Multipoint()
    var earbudFinder: EarbudFinder?
    var isReady = true
    var isDeviceConnected = true
    var supportsConnectionMode = true
    var ldacRequiresMultipointOff = false
    @Published var connectionMode: SonyConnectionMode? = .soundQuality
    @Published var connectionTransition: ConnectionTransition?
    var lastConnectionModeChangeID: UUID?
    var connectionModeError: String?
    var connectionRequests: [SonyConnectionMode] = []
    var notificationSession: UInt64 = 1
    var capabilityFresh = true
    var statusFresh = true
    var volumeFresh = true
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
    var hasCurrentMusicVolumeControl: Bool { isReady && !requiredMusicVolumeReadTimedOut && capabilityFresh && statusFresh && volumeFresh && playback.volume != nil }
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
    var preparations = 0
    var silences = 0
    var configurations = 0
    var recoveryPreparations = 0
    var blocksConfiguration = false
    var configurationWaiter: CheckedContinuation<Void, Never>?
    var blocksPreparation = false
    var preparationWaiter: CheckedContinuation<Void, Never>?
    var restores: [Bool] = []
    var restoreError: String?
    let changed: (Result<LDACNativeVolume, Error>) -> Void
    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) { self.changed = changed }
    func simulateControls(_ controls: LDACNativeVolume) { self.controls = controls; changed(.success(controls)) }
    func claim(model: String, targetAddress: String, sampleRate: Int) async throws {}
    func priorityControl() async throws {}
    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) async throws {
        configurations += 1
        if blocksConfiguration { await withCheckedContinuation { configurationWaiter = $0 } }
        if !preservingUserChange { _ = controls.update(volume: volume, range: range) }
    }
    func validateForRecovery() async throws {}
    func prepareForReconnect() async throws { recoveryPreparations += 1 }
    func selectForHandoff() async throws { selected = true }
    func finishPreparation() async throws {
        ready = true
        preparations += 1
        if blocksPreparation { await withCheckedContinuation { preparationWaiter = $0 } }
    }
    func silence() { ready = false; silences += 1 }
    func restoreAndRelease(targetDisconnected: Bool = false) async -> String? { restores.append(targetDisconnected); ready = false; selected = false; return restoreError }
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
        case handoffReady, connecting, active(LDACFormat), formatChanged(LDACFormat), gainApplied(Double)
        case audioCaptureAccess(LDACAudioCaptureAccess), failed(String), connectionLost(String), finished(Completion)
    }
    let id: UUID
    let address: String
    let restoringOnly: Bool
    let receive: (Event) -> Void
    var gains: [Double]
    var qualities: [LDACQuality] = []
    var stops = 0
    var recoveries: [String] = []
    var audioRestorations: [Bool] = []
    var handoffs = 0
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
    func updateGain(_ gain: Double) { gains.append(gain) }
    func updateQuality(_ quality: LDACQuality) { qualities.append(quality) }
    func stop(restoreAudio: Bool) { stops += 1; audioRestorations.append(restoreAudio) }
    func recoverConnection(reason: String) { recoveries.append(reason) }
    func verifyConnectionLoss(reason: String) {}
}

@MainActor
final class Controller: ObservableObject {
    var state = LDACState.off
    var targetAddress: String?
    var isSessionRunning = false
    var isRecovering = false
    var audioCaptureAccess = LDACAudioCaptureAccess.unchecked
    var session: LDACNativeSession?
    var sessionID = UUID()
    var requestedAddress: String?
    var requestedConfiguration = LDACConfiguration()
    var diagnosticAttempt = 0
    var nativeOutput: LDACNativeOutput?
    var outputID: UUID?
    var headphones: SonyHeadphonesController?
    let bundle = Bundle.main
    let inspectDriver: (Bundle) -> LDACDriverInstaller.State = { LDACDriverInstaller.inspect(bundle: $0) }
    var isClassicConnected: (String) -> Bool = { _ in true }
    var driverState = LDACDriverInstaller.State.current
    var audioRoute: MacAudioRouteObserver? = MacAudioRouteObserver()
    var resumeOutputUID: String?
    var suspensionRequested = false
    var multipointConflictAddress: String?
    var multipointConflictConfiguration: LDACConfiguration?
    var multipointShutdownAddress: String?
    var multipointShutdownTask: Task<Void, Never>?
    var multipointShutdownRequestID: UUID?
    func confirmPendingMultipointAlert() {}
    var pendingConnectionModes: [String: UUID] = [:]
    var deferredConnectionModes: [String: UUID] = [:]
    var preferenceRestoreTasks: [String: Task<Void, Never>] = [:]
    var connectionModeRestoreID: UUID?
    var connectionModeConfirmed = false
    var controlObservation: AnyCancellable?
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
        preconditionFailure("Production controller did not reach the expected fixture state at line \(line)")
    }

    @MainActor
    static func started(_ generation: Generation = .v1, supportsMute: Bool = false, musicMuted: Bool? = nil) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let controller = Controller()
        let headphones = SonyHeadphonesController()
        headphones.playback.generation = generation
        headphones.playback.supportsMute = supportsMute
        headphones.playback.musicMuted = musicMuted
        headphones.localSource = generation == .v2
        controller.devices?.controllers[headphones.address] = headphones
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
        return (controller, headphones, controller.nativeOutput!, controller.session!)
    }

    @MainActor
    static func stop(_ controller: Controller) async throws {
        controller.stop(restoreAudio: false, reason: "fixture complete")
        controller.session?.emit(.finished(.init(message: nil)))
        try await waitUntil { !controller.isSessionRunning }
    }

    @MainActor
    static func active(_ generation: Generation) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let (controller, headphones, output, raw) = try await started(generation)
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
    static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1")
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
            precondition(raw.qualities == [.quality, .adaptive] && raw.stops == initialStops && output.restores.isEmpty,
                         "Live bitrate selection restarted the transport")
            controller.updateConfiguration(LDACConfiguration(sampleRate: 96000, quality: .adaptive))
            precondition(raw.stops == initialStops + 1 && controller.state == .stopping && !controller.canChangeConfiguration,
                         "Sample-rate change did not enter controlled cleanup")
            precondition(controller.requestedAddress != nil && controller.requestedConfiguration.sampleRate == 96000,
                         "Sample-rate change lost the requested session")
            try await stop(controller)
        }
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

        let (otherSource, sourceDevice, _, sourceRaw) = try await started(.v2)
        sourceDevice.multipoint.selectedSource = .init(address: "02:00:00:00:00:03")
        sourceDevice.localSource = false
        otherSource.controlsChanged()
        precondition(otherSource.requestedAddress == sourceDevice.address && sourceRaw.stops == 1)
        precondition(sourceRaw.audioRestorations == [true], "Phone playback left ordinary Mac Bluetooth audio disconnected")
        sourceRaw.emit(.finished(.init(message: nil)))
        try await waitUntil { otherSource.state == .waitingForDevice }
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
names = ["canChangeConfiguration", "updateConfiguration", "handleOutputDeselection", "needsStopBeforeTermination", "nextRecoveryDelay", "canResumeRecovery", "deviceUnavailableReason", "refreshDriverState", "start", "launch", "hasMusicVolumeForHandoff", "hasOwnedMusicContext",
         "hasOtherMusicSource", "observeControls", "bindingIsCurrent", "musicControlStatus", "waitForControls", "controlsChanged",
         "rebindControls", "sendPendingVolume", "setOutputGain", "fail", "beginRecovery", "scheduleRecovery", "cancelMultipointRequest", "stop", "stopSession",
         "suspend", "resumeIfReady", "reconcileConnectionPreferences", "forgetConnectionPreference", "scheduleConnectionPreferenceRestoration", "prepareConnectionMode", "waitForConnectionChange", "restoreConnectionMode",
         "restoreConnectionPreference", "finish", "completeStop"]
fixture = fixture.replace("precondition(", "check(")
fixture = fixture.replace("__VOLUME__", volume).replace("__METHODS__", "\n".join(member(name) for name in names))

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
    arguments = ["--check-handoff-refresh"] if "--check-handoff-refresh" in sys.argv or "--check-handoff-mutations" in sys.argv else ["--check-volume-observation"] if "--check-volume-observation" in sys.argv else ["--check-headphone-mute"] if "--check-mute-mutations" in sys.argv or "--check-headphone-mute" in sys.argv else []
    subprocess.run([str(binary), *arguments], env=environment, check=True)
    if "--check-mutations" in sys.argv or "--check-mute-mutations" in sys.argv or "--check-handoff-mutations" in sys.argv:
        mutations = [
            ("handoff refresh wait", "if headphones.hasFreshMusicVolumeReadback { break }", "break",
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
