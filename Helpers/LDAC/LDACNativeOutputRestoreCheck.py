from pathlib import Path
import subprocess
import tempfile


source = (Path(__file__).resolve().parents[2] / "Sources/LDACNativeOutput.swift").read_text()
method = source[source.index("    func restoreAndRelease("):source.index("    private func applyControls(")]
volume = source[source.index("struct LDACNativeVolume:"):source.index("\n@MainActor\nfinal class LDACNativeOutput")]
fixture = r'''
import Foundation

typealias AudioObjectID = UInt32
typealias AudioObjectPropertySelector = UInt32
let kAudioObjectUnknown: UInt32 = 0
let kAudioDevicePropertyDeviceUID: UInt32 = 10
let noErr: Int32 = 0
let kAudioHardwareBadObjectError: Int32 = 1

@MainActor
struct Date {
    static var time = 0.0
    let time: Double
    init() { time = Self.time }
    init(time: Double) { self.time = time }
    func addingTimeInterval(_ interval: Double) -> Self { Self(time: time + interval) }
    static func >= (lhs: Self, rhs: Self) -> Bool { lhs.time >= rhs.time }
}

func AudioObjectRemovePropertyListenerBlock(_ object: UInt32, _ property: inout UInt32,
    _ queue: DispatchQueue, _ block: () -> Void) -> Int32 { noErr }

struct RouteError: LocalizedError {
    var errorDescription: String? { "The route write failed." }
}

__VOLUME__

@MainActor
final class LDACNativeOutput {
    nonisolated static let uid = "LDAC"
    static let system: UInt32 = 1
    static let defaultSelectors: [UInt32] = [2, 3]
    static var current: [UInt32: UInt32] = [:]
    static var identities: [UInt32: String] = [:]
    static var available: [String: UInt32] = [:]
    static var fallback: UInt32?
    static var muteWrites: [(UInt32, Bool)] = []
    static var writes: [(UInt32, UInt32)] = []
    static var failMute = false
    static var failWrite = false
    static var expire = false
    var restoring = false
    var ownsLease = true
    var isSelected = true
    var controls = LDACNativeVolume(scalar: 0.5, muted: false)
    var savedDefaults: [UInt32: String] = [2: "headphones", 3: "headphones"]
    var listeners: [(UInt32, UInt32, () -> Void)] = []
    var renewTask: Task<Void, Never>?
    var device: UInt32 = 5
    var events: [String] = []
    var leaseReleased = false

    static func reset() {
        current = [2: 5, 3: 5]
        identities = [5: uid, 6: "headphones", 7: "speakers", 8: "user-output"]
        available = [:]
        fallback = 7
        muteWrites = []
        writes = []
        failMute = false
        failWrite = false
        expire = false
        Date.time = 0
    }
    func silence() {}
    func record(_ event: String, reason: String) { events.append(event) }
    func setLease(_ value: Bool) throws { leaseReleased = !value }
    static func read(_ object: UInt32, selector: UInt32, initial: UInt32) throws -> UInt32 { current[selector]! }
    static func readString(_ object: UInt32, selector: UInt32) throws -> String { identities[object]! }
    static func resolve(_ uid: String) throws -> UInt32? {
        if expire { Date.time += 9 }
        return available[uid]
    }
    static func isAliveOutput(_ object: UInt32) throws -> Bool { true }
    static func availableFallback() throws -> UInt32? { fallback }
    static func setMute(_ object: UInt32, muted: Bool) throws {
        if failMute { throw RouteError() }
        muteWrites.append((object, muted))
    }
    static func write(_ object: UInt32, selector: UInt32, value: UInt32) throws {
        if failWrite { throw RouteError() }
        writes.append((selector, value))
        current[selector] = value
    }
__METHOD__
}

@main
enum Check {
    @MainActor
    static func main() async {
        typealias Output = LDACNativeOutput
        Output.reset()
        let disconnected = Output()
        let clean = await disconnected.restoreAndRelease(targetDisconnected: true)
        precondition(clean == nil && disconnected.leaseReleased && !disconnected.ownsLease)
        precondition(Output.writes.count == 2 && Output.writes.allSatisfy { $0.1 == 7 })
        precondition(Output.muteWrites.count == 2 && Output.muteWrites.allSatisfy { $0.0 == 7 && $0.1 })

        for targetDisconnected in [false, true] {
            Output.reset()
            Output.current = [2: 8, 3: 8]
            let preserved = Output()
            let result = await preserved.restoreAndRelease(targetDisconnected: targetDisconnected)
            precondition(result == nil && Output.writes.isEmpty && Output.muteWrites.isEmpty)
            precondition(preserved.leaseReleased)

            Output.reset()
            Output.available = ["headphones": 6]
            let restored = Output()
            let restoredResult = await restored.restoreAndRelease(targetDisconnected: targetDisconnected)
            precondition(restoredResult == nil && Output.writes.count == 2)
            precondition(Output.writes.allSatisfy { $0.1 == 6 })
            precondition(Output.muteWrites.allSatisfy { $0.0 == 6 && !$0.1 })
        }

        Output.reset()
        Output.expire = true
        let missing = Output()
        let missingResult = await missing.restoreAndRelease()
        precondition(missingResult?.contains("previous Mac audio output did not return") == true)
        precondition(Output.writes.count == 2 && missing.leaseReleased)

        for failure in ["no-fallback", "mute", "write"] {
            Output.reset()
            if failure == "no-fallback" { Output.fallback = nil }
            if failure == "mute" { Output.failMute = true }
            if failure == "write" { Output.failWrite = true }
            let output = Output()
            let result = await output.restoreAndRelease(targetDisconnected: true)
            precondition(result != nil && output.leaseReleased)
            precondition(Output.writes.isEmpty)
        }
        print("PASS actual native output restoration: disconnected fallback stays muted, user routes preserved, available prior routes restored, connected missing-route and fallback failures remain errors; no audio devices accessed")
    }
}
'''.replace("__VOLUME__", volume).replace("__METHOD__", method)

with tempfile.TemporaryDirectory(prefix="acouplet-native-output-restore-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
