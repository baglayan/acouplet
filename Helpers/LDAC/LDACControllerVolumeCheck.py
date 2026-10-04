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
    end = re.search(r"^    (?:private )?(?:func|var|struct) ", source[match.end():], re.MULTILINE)
    return re.sub(r"^    private ", "    ", source[match.start():match.end() + end.start()], flags=re.MULTILINE)


volume = output_source[output_source.index("struct LDACNativeVolume:"):output_source.index("\n@MainActor\nfinal class LDACNativeOutput")]
fixture = r'''
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Fixture assertion failed") {
    if !condition() {
        FileHandle.standardError.write(Data((message() + "\n").utf8))
        exit(1)
    }
}

enum Generation { case v1, v2 }
enum Model { case unknown, wfXM3, whCH720N, whXM4, wfXM5; var name: String { "fixture" } }
struct LDACFormat: Equatable { var value = 1 }
enum LDACState: Equatable { case off, requested, connecting, active(LDACFormat), stopping, failed(String) }
enum LDACAudioCaptureAccess { case unchecked, checking, ready, permissionRequired }
struct LDACConfiguration { var sampleRate = 48000 }
struct LDACPriorityControl {}
struct LDACPriorityCleanupError: Error {}
enum SonyBLEIdentity { static func normalizedAddress(_ address: String) -> String? { address.uppercased() } }
struct IOBluetoothDevice {
    init?(addressString: String) {}
    func isConnected() -> Bool { true }
}
struct IOBluetoothHostController {
    static func `default`() -> Self? { Self() }
    func addressAsString() -> String { "02:00:00:00:00:02" }
}
enum ReconnectBackoff { static func delay(forAttempt: Int) -> Double { 0 } }

__VOLUME__

@MainActor
final class SonyHeadphonesController {
    enum Setting { case playbackVolume }
    struct Playback {
        var generation = Generation.v1
        var isSupported = true
        var hasReceivedCapabilities = true
        var musicVolumeRange: ClosedRange<Int>? = 0...30
        var volume: Int? = 12
    }
    struct Source { var address: String }
    struct Multipoint { var selectedSource: Source? }
    struct VolumeWrite { let volume: Int; let isCurrent: (() -> Bool)? }
    var deviceModel = Model.whXM4
    var address = "02:00:00:00:00:01"
    var playback = Playback()
    var multipoint = Multipoint()
    var isReady = true
    var isDeviceConnected = true
    var notificationSession: UInt64 = 1
    var capabilityFresh = true
    var statusFresh = true
    var volumeFresh = true
    var localSource = true
    var musicVolumeReadbackID: UUID? = UUID()
    var musicStatusReadbackID: UUID? = UUID()
    var refreshes = 0
    var volumeRefreshes = 0
    var queuedWrite: VolumeWrite?
    var transmitted: [Int] = []
    var continuation: CheckedContinuation<Void, Error>?
    var hasCurrentMusicVolumeControl: Bool { isReady && capabilityFresh && statusFresh && volumeFresh && playback.volume != nil }
    var hasFreshMusicVolumeReadback: Bool { hasCurrentMusicVolumeControl }
    var canControlMusicVolume: Bool { hasCurrentMusicVolumeControl && queuedWrite == nil }
    func hasCurrentMusicSourceContext(for address: String?) -> Bool { localSource }
    func canPerformConfirmedSettingChange(_ setting: Setting) -> Bool { isReady && queuedWrite == nil }
    func refresh() {
        refreshes += 1
        guard isReady else { return }
        musicVolumeReadbackID = UUID()
        musicStatusReadbackID = UUID()
    }
    func refreshMusicVolume() -> Bool {
        guard isReady else { return false }
        volumeRefreshes += 1
        statusFresh = false
        volumeFresh = false
        return true
    }
    func receiveStatus() { statusFresh = true; musicStatusReadbackID = UUID() }
    func receiveVolume(_ volume: Int = 12) { volumeFresh = true; playback.volume = volume; musicVolumeReadbackID = UUID() }
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
final class SonyDeviceCoordinator {
    var controllers: [String: SonyHeadphonesController] = [:]
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
    init(id: UUID, address: String, changed: @escaping (Result<LDACNativeVolume, Error>) -> Void) {}
    func claim(model: String, targetAddress: String, sampleRate: Int) async throws {}
    func priorityControl() throws -> LDACPriorityControl { LDACPriorityControl() }
    func configure(volume: Int, range: ClosedRange<Int>, preservingUserChange: Bool = false) throws {
        configurations += 1
        if !preservingUserChange { _ = controls.update(volume: volume, range: range) }
    }
    func validateForRecovery() throws {}
    func prepareForReconnect() throws -> LDACPriorityControl { LDACPriorityControl() }
    func selectForHandoff() throws { selected = true }
    func finishPreparation() throws { ready = true; preparations += 1 }
    func silence() { ready = false; silences += 1 }
    func restoreAndRelease() async -> String? { ready = false; selected = false; return nil }
}

@MainActor
final class LDACNativeSession {
    struct Helpers {}
    struct Completion { var message: String?; var canRetry = false; var requiresAttention = false }
    enum Event {
        case handoffReady, connecting, active(LDACFormat), formatChanged(LDACFormat), gainApplied(Double)
        case audioCaptureAccess(LDACAudioCaptureAccess), failed(String), connectionLost(String), finished(Completion)
    }
    let id: UUID
    let address: String
    let receive: (Event) -> Void
    var gains: [Double]
    var stops = 0
    var handoffs = 0
    init(id: UUID, address: String, helpers: Helpers, gain: Double, outputDeviceUID: String,
         priority: LDACPriorityControl?, configuration: LDACConfiguration, recoveryAttempt: Bool,
         restoringOnly: Bool, receive: @escaping (Event) -> Void) {
        self.id = id
        self.address = address
        self.receive = receive
        gains = [gain]
    }
    func start() {}
    func emit(_ event: Event) { receive(event) }
    func allowHandoff() { handoffs += 1 }
    func updateGain(_ gain: Double) { gains.append(gain) }
    func stop(restoreAudio: Bool) { stops += 1 }
    func recoverConnection(reason: String) {}
    func verifyConnectionLoss(reason: String) {}
}

@MainActor
final class Controller {
    var state = LDACState.off
    var targetAddress: String?
    var actualOutputGain = 0.0
    var isSessionRunning = false
    var isRecovering = false
    var audioCaptureAccess = LDACAudioCaptureAccess.unchecked
    var session: LDACNativeSession?
    var sessionID = UUID()
    var requestedAddress: String?
    var requestedConfiguration = LDACConfiguration()
    var nativeOutput: LDACNativeOutput?
    var outputID: UUID?
    var headphones: SonyHeadphonesController?
    var controlObservation: Int?
    var startTask: Task<Void, Never>?
    var readinessTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var volumeTaskID: UUID?
    var cleanupTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var recoveryAttempt = 0
    var restoreAudioOnStop = true
    var stableSince: Date?
    var pendingVolume: Int?
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
    func observeControls(_ headphones: SonyHeadphonesController, devices: SonyDeviceCoordinator) {}
    func record(_ event: String, reason: String) {}
    __METHODS__
    struct ControlError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
}

@main
enum Check {
    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Production controller did not reach the expected fixture state")
    }

    @MainActor
    static func started(_ generation: Generation = .v1) async throws -> (Controller, SonyHeadphonesController, LDACNativeOutput, LDACNativeSession) {
        let controller = Controller()
        let headphones = SonyHeadphonesController()
        headphones.playback.generation = generation
        headphones.localSource = generation == .v2
        controller.devices?.controllers[headphones.address] = headphones
        controller.requestedAddress = headphones.address
        controller.start(headphones.address)
        try await waitUntil { controller.session != nil }
        return (controller, headphones, controller.nativeOutput!, controller.session!)
    }

    @MainActor
    static func stop(_ controller: Controller) async throws {
        controller.stop(restoreAudio: false, reason: "fixture complete")
        controller.session?.emit(.finished(.init(message: nil)))
        try await waitUntil { !controller.isSessionRunning }
    }

    @MainActor
    static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1")
        let (controller, headphones, output, session) = try await started()
        precondition(controller.hasMusicVolumeForHandoff && !controller.hasOwnedMusicContext,
                     "Legacy raw ownership admitted before active")
        session.emit(.handoffReady)
        precondition(output.selected && !output.ready && session.handoffs == 1)
        precondition(headphones.queuedWrite == nil && session.gains == [0])
        session.emit(.connecting)
        precondition(!controller.hasOwnedMusicContext && !output.ready)

        headphones.isReady = false
        session.emit(.active(LDACFormat()))
        precondition(headphones.refreshes == 2, "Disconnected legacy controls did not retain their reopen request")
        try await Task.sleep(for: .milliseconds(120))
        precondition(headphones.volumeRefreshes == 0 && controller.controlSession == nil && !output.ready)
        headphones.notificationSession += 1
        headphones.isReady = true
        try await waitUntil { headphones.volumeRefreshes == 1 }
        headphones.statusFresh = true
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
        session.emit(.finished(.init(message: nil, canRetry: true)))
        try await waitUntil { controller.session != nil && controller.session !== session }
        let recovered = controller.session!
        let renewedID = controller.sessionID
        session.emit(.active(LDACFormat(value: 99)))
        precondition(controller.sessionID == renewedID && controller.transportFormat == nil)
        recovered.emit(.handoffReady)
        precondition(!output.ready)
        recovered.emit(.active(LDACFormat()))
        try await waitUntil { headphones.volumeRefreshes == refreshes + 1 }
        precondition(headphones.refreshes == 2, "Ready legacy controls redundantly refreshed unrelated settings")
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
            raw.emit(.active(LDACFormat()))
            try await waitUntil { device.volumeRefreshes == 1 }
            device.receiveStatus()
            device.receiveVolume()
            try await waitUntil { device.queuedWrite != nil }
            if changed == "range" { device.playback.musicVolumeRange = 0...20 }
            else if changed == "control-session" { device.notificationSession += 1 }
            else if changed == "stop" { bound.stop(reason: "fixture queued stop") }
            else { bound.devices?.controllers[device.address] = SonyHeadphonesController() }
            bound.controlsChanged()
            device.transmitVolume()
            precondition(device.transmitted.isEmpty && !endpoint.ready && !bound.usable,
                         "Changed \(changed) retained queued legacy volume ownership")
            try await stop(bound)
        }
        print("PASS actual binding: range, Sony control session, controller replacement and stop revoke queued writes")

        let (modern, modernDevice, modernOutput, modernRaw) = try await started(.v2)
        precondition(modern.hasOwnedMusicContext)
        modernRaw.emit(.handoffReady)
        modernRaw.emit(.active(LDACFormat()))
        try await waitUntil { modernDevice.queuedWrite != nil }
        precondition(modernDevice.volumeRefreshes == 0 && !modernOutput.ready)
        modernDevice.transmitVolume()
        modernDevice.confirmVolume()
        try await waitUntil { modern.usable }
        modernDevice.localSource = false
        modern.controlsChanged()
        precondition(!modernOutput.ready && !modern.usable)
        try await stop(modern)
        print("PASS existing v2 path: source ownership remains required and no legacy refresh is imposed")
        print("PASS scope: production controller methods and volume mapping; fake transport, confirmations, observations and native output; no hardware or installation")
    }
}
'''
names = ["deviceUnavailableReason", "start", "launch", "hasMusicVolumeForHandoff", "hasOwnedMusicContext",
         "hasOtherMusicSource", "bindingIsCurrent", "musicControlStatus", "waitForControls", "controlsChanged",
         "sendPendingVolume", "setOutputGain", "fail", "beginRecovery", "scheduleRecovery", "stop", "stopSession",
         "finish", "completeStop"]
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
    subprocess.run([str(binary)], env=environment, check=True)
    if "--check-mutations" in sys.argv:
        mutations = [
            ("raw", "hasMusicVolumeForHandoff && (headphones?.playback.generation != .v1 || transportFormat != nil)",
             "hasMusicVolumeForHandoff", "Legacy raw ownership admitted before active"),
            ("status", "&& headphones.musicStatusReadbackID != nil && headphones.musicStatusReadbackID != initialStatusReadbackID",
             "", "Volume without post-admission status admitted legacy LDAC"),
        ]
        for name, before, after, failure in mutations:
            assert fixture.count(before) == 1
            swift.write_text(fixture.replace(before, after))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                           env=environment, check=True)
            result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
            assert result.returncode == 1 and failure in result.stderr, (name, result.returncode, result.stdout, result.stderr)
            print(f"PASS mutation rejected: missing {name} admission witness")
