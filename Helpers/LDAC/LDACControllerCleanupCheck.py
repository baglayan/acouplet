import pathlib
import re
import subprocess
import tempfile


source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/LDACController.swift").read_text()


def method(name):
    match = re.search(r"^    (?:private )?func " + name + r"\(", source, re.MULTILINE)
    end = re.search(r"^    (?:private )?(?:func|struct) ", source[match.end():], re.MULTILINE)
    return source[match.start():match.end() + end.start()]


fixture = r'''
import Foundation

enum LDACState: Equatable { case off, requested, connecting, stopping, failed(String) }
enum LDACAudioCaptureAccess { case checking, unchecked }
struct LDACConfiguration: Equatable { var value = 0 }
enum SonyBLEIdentity {
    static func normalizedAddress(_ value: String) -> String? { value }
}

enum Model { case unknown, wfXM3, whCH720N, wfXM5, whXM5 }
struct Playback {
    var isSupported = true
    var hasReceivedCapabilities = false
    var musicVolumeRange: ClosedRange<Int>?
}
final class Device {
    var deviceModel: Model
    var isReady: Bool
    var playback: Playback
    init(_ model: Model = .wfXM5, ready: Bool = true, playback: Bool = true) {
        deviceModel = model
        isReady = ready
        self.playback = Playback(isSupported: playback)
    }
}

final class Devices {
    var controllers = ["02:00:00:00:00:01": Device(), "02:00:00:00:00:02": Device(), "02:00:00:00:00:03": Device()]
    func controller(for address: String) -> Device? { controllers[address] }
}

@MainActor
enum LDACDriverInstaller {
    enum State { case missing, outdated, current }
    static var state = State.current
    static var inspections = 0
    static var installations = 0
    static func inspect(bundle: Bundle) -> State { inspections += 1; return state }
    static func openInstaller(bundle: Bundle) async throws { installations += 1 }
}

@MainActor
final class Output {
    var restores = 0
    var continuation: CheckedContinuation<String?, Never>?
    func silence() {}
    func restoreAndRelease() async -> String? {
        restores += 1
        return await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
final class Session {
    var stops: [Bool] = []
    func stop(restoreAudio: Bool) { stops.append(restoreAudio) }
}

@MainActor
final class Controller {
    struct Helpers { var isAvailable = true }
    var helpers = Helpers()
    var driverState = LDACDriverInstaller.State.current
    var driverInstallationError: String?
    var isOpeningDriverInstaller = false
    let bundle = Bundle.main
    var devices: Devices? = Devices()
    var requestedConfiguration = LDACConfiguration()
    var sessionID = UUID()
    var state = LDACState.connecting
    var targetAddress: String? = "02:00:00:00:00:01"
    var requestedAddress: String? = "02:00:00:00:00:01"
    var isSessionRunning = true
    var isRecovering = true
    var restoreAudioOnStop = true
    var nativeOutput: Output?
    var session: Session?
    var startTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var readinessTask: Task<Void, Never>?
    var volumeTask: Task<Void, Never>?
    var volumeTaskID: UUID?
    var controlObservation: Int?
    var outputID: UUID?
    var headphones: Int?
    var transportFormat: Int?
    var controlSession: UInt64?
    var sourceAddress: String?
    var volumeRange: ClosedRange<Int>?
    var pendingVolume: Int?
    var initialReadbackID: UUID?
    var stableSince: Date?
    var actualOutputGain = 0.0
    var requestedOutputGain = 0.0
    var usable = false
    var volumeError: String?
    var audioCaptureAccess = LDACAudioCaptureAccess.checking
    var stopCompletions: [@MainActor () -> Void] = []
    var starts: [String] = []
    var restores: [String] = []
    var musicControlStatus: String { "simulated" }

    init(output: Output? = nil) {
        nativeOutput = output
        if output == nil {
            isSessionRunning = false
            isRecovering = false
            state = .off
            targetAddress = nil
            requestedAddress = nil
        }
    }
    func record(_ event: String, reason: String) {}
    func setOutputGain(_ gain: Double) { requestedOutputGain = gain }
    func sessionFinished() { finish(nil) }
    func launch(_ address: String, priority: Int?, restoringOnly: Bool) { restores.append(address) }
    func start(_ address: String) {
        starts.append(address)
        targetAddress = address
        state = .requested
        isSessionRunning = true
    }
__METHODS__
}

@main
enum LDACControllerCleanupCheck {
    @MainActor
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Controller operation did not complete")
    }

    @MainActor
    static func main() async {
        let address = "02:00:00:00:00:01"
        let volumeUnavailable = Device()
        volumeUnavailable.playback.hasReceivedCapabilities = true
        let refused: [(String, Device?)] = [
            ("missing", nil), ("unknown", Device(.unknown)),
            ("WF-1000XM3", Device(.wfXM3)), ("WH-CH720N", Device(.whCH720N)),
            ("disconnected", Device(ready: false)), ("missing playback", Device(playback: false)),
            ("reported no volume control", volumeUnavailable),
        ]
        for (name, device) in refused {
            let admission = Controller()
            admission.devices?.controllers[address] = device
            precondition(admission.deviceUnavailableReason(forAddress: address) != nil, "Eligibility admitted \(name)")
            precondition(!admission.canEnable(forAddress: address), "Enable availability admitted \(name)")
            LDACDriverInstaller.inspections = 0
            LDACDriverInstaller.installations = 0
            LDACDriverInstaller.state = .missing
            admission.setEnabled(true, forAddress: address, configuration: LDACConfiguration(value: 1))
            precondition(LDACDriverInstaller.inspections == 0, "Enable inspected driver for \(name)")
            precondition(admission.starts.isEmpty && admission.requestedAddress == nil && admission.targetAddress == nil)
            precondition(admission.requestedConfiguration == LDACConfiguration() && admission.state == .off)
            admission.installDriver(forAddress: address)
            precondition(LDACDriverInstaller.inspections == 0, "Installer inspected driver for \(name)")
            precondition(!admission.isOpeningDriverInstaller && LDACDriverInstaller.installations == 0)
        }
        let missingCoordinator = Controller()
        missingCoordinator.devices = nil
        precondition(missingCoordinator.deviceUnavailableReason(forAddress: address) != nil)
        for model in [Model.wfXM5, .whXM5] {
            for state in [LDACDriverInstaller.State.current, .missing, .outdated] {
                let admission = Controller()
                admission.devices?.controllers[address] = Device(model)
                admission.devices?.controllers[address]?.playback.hasReceivedCapabilities = true
                admission.devices?.controllers[address]?.playback.musicVolumeRange = model == .wfXM5 ? 0...30 : 0...0
                LDACDriverInstaller.state = state
                LDACDriverInstaller.inspections = 0
                LDACDriverInstaller.installations = 0
                precondition(admission.deviceUnavailableReason(forAddress: address) == nil && admission.canEnable(forAddress: address))
                admission.setEnabled(true, forAddress: address)
                if state == .current {
                    precondition(admission.starts == [address] && admission.isSessionRunning)
                    precondition(LDACDriverInstaller.inspections == 1 && LDACDriverInstaller.installations == 0)
                } else {
                    precondition(admission.starts.isEmpty && admission.isOpeningDriverInstaller)
                    await waitUntil { !admission.isOpeningDriverInstaller }
                    precondition(LDACDriverInstaller.inspections == 2 && LDACDriverInstaller.installations == 1)
                }
            }
        }
        let active = Controller()
        active.isSessionRunning = true
        active.targetAddress = address
        active.requestedAddress = address
        active.state = .connecting
        let activeSession = Session()
        active.session = activeSession
        let next = "02:00:00:00:00:02"
        active.devices?.controllers[next]?.isReady = false
        active.setEnabled(true, forAddress: next)
        precondition(active.requestedAddress == address && activeSession.stops.isEmpty)
        active.devices?.controllers[next]?.isReady = true
        active.setEnabled(true, forAddress: next)
        precondition(active.requestedAddress == next && activeSession.stops == [true])
        active.devices?.controllers.removeAll()
        active.setEnabled(false, forAddress: address)
        precondition(active.requestedAddress == nil && activeSession.stops == [true, true], "Control loss prevented disable")

        let output = Output()
        let controller = Controller(output: output)
        controller.sessionFinished()
        await waitUntil { output.continuation != nil }
        var completions = 0
        controller.stop(reason: "app is terminating") { completions += 1 }
        controller.stop(restoreAudio: false, reason: "Mac is going to sleep") { completions += 1 }
        controller.stop(reason: "repeated stop")
        precondition(controller.restores.isEmpty, "Repeated stop launched another restoration session")
        precondition(!controller.restoreAudioOnStop, "A later stop weakened the sleep request")
        precondition(controller.isSessionRunning && completions == 0 && output.restores == 1)
        output.continuation?.resume(returning: nil)
        await waitUntil { controller.cleanupTask == nil }
        precondition(!controller.isSessionRunning && controller.state == .off && completions == 2)
        precondition(controller.starts.isEmpty && controller.stopCompletions.isEmpty)

        let pendingOutput = Output()
        let pending = Controller(output: pendingOutput)
        pending.sessionFinished()
        await waitUntil { pendingOutput.continuation != nil }
        pending.setEnabled(true, forAddress: "02:00:00:00:00:02")
        pending.setEnabled(true, forAddress: "02:00:00:00:00:03")
        precondition(pending.restores.isEmpty && pending.starts.isEmpty)
        precondition(pending.requestedAddress == "02:00:00:00:00:03")
        pendingOutput.continuation?.resume(returning: nil)
        await waitUntil { pending.cleanupTask == nil }
        precondition(pending.starts == ["02:00:00:00:00:03"] && pending.isSessionRunning)

        let cancelledOutput = Output()
        let cancelled = Controller(output: cancelledOutput)
        cancelled.sessionFinished()
        await waitUntil { cancelledOutput.continuation != nil }
        cancelled.setEnabled(true, forAddress: "02:00:00:00:00:02")
        cancelled.stop(reason: "app is terminating") { completions += 1 }
        precondition(cancelled.requestedAddress == nil && cancelled.restores.isEmpty && completions == 2)
        cancelledOutput.continuation?.resume(returning: nil)
        await waitUntil { cancelled.cleanupTask == nil }
        precondition(cancelled.starts.isEmpty && !cancelled.isSessionRunning && completions == 3)
        print("PASS actual LDAC admission and cleanup methods: unsupported/unknown/disconnected/playback refusal before side effects, compatible start/install, disable after control loss, target changes, repeated stop and quit completion; fake peers only")
    }
}
'''.replace("__METHODS__", "\n".join(method(name) for name in ["deviceUnavailableReason", "canEnable", "refreshDriverState", "installDriver", "setEnabled", "stop", "stopSession", "finish", "completeStop"]))

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-controller-cleanup-") as directory:
    directory = pathlib.Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
