import pathlib
import subprocess
import sys
import tempfile


source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/LDACNativeSession.swift").read_text()

fixture = r'''
enum PipeSetupCheck {
    nonisolated(unsafe) static var failureCall = 0
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var spawnAttempts = 0
    nonisolated(unsafe) static var descriptors: [Int32] = []

    static func configure(_ descriptor: Int32, _ command: Int32, _ value: Int32) -> Int32 {
        calls += 1
        if calls == failureCall { errno = EPERM; return -1 }
        return Darwin.fcntl(descriptor, command, value)
    }
}

final class SessionClock: @unchecked Sendable {
    static let shared = SessionClock()
    private let lock = NSLock()
    private var elapsed: TimeInterval?
    private var wallOffset: TimeInterval = 0

    var monotonic: DispatchTime {
        lock.withLock {
            elapsed.map { DispatchTime(uptimeNanoseconds: UInt64((1_000 + $0) * 1_000_000_000)) } ?? .now()
        }
    }

    var wallTime: Date {
        lock.withLock {
            elapsed.map { Date(timeIntervalSince1970: 1_700_000_000 + $0 + wallOffset) } ?? Date()
        }
    }

    func set(elapsed: TimeInterval?, wallOffset: TimeInterval = 0) {
        lock.withLock {
            self.elapsed = elapsed
            self.wallOffset = wallOffset
        }
    }
}

struct ClosureCheckError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ClosureCheckError(description: message) }
}

func waitUntil(_ condition: () throws -> Bool) throws {
    for _ in 0..<600 {
        if try condition() { return }
        usleep(5_000)
    }
    throw ClosureCheckError(description: "Fixture did not finish within three seconds")
}

func cleanUp(_ children: [LDACNativeChild]) {
    for child in children { child.signal(SIGKILL) }
    for _ in 0..<600 {
        for child in children { child.reap() }
        if children.allSatisfy({ $0.status != nil }) { return }
        usleep(5_000)
    }
    fatalError("Fixture cleanup did not reap its children")
}

@MainActor
final class SessionEvents {
    var values: [LDACNativeSession.Event] = []

    var names: [String] {
        values.compactMap {
            switch $0 {
            case .diagnostic: nil
            case .connectionLost: "connectionLost"
            case .failed: "failed"
            case .active: "active"
            case .formatChanged: "formatChanged"
            case .sampleRateChangeDeferred: "sampleRateChangeDeferred"
            default: "other"
            }
        }
    }
}

final class FixturePriority: @unchecked Sendable {
    let lock = NSLock()
    let available: Bool
    var enabled = false
    var requests: [Bool] = []

    init(available: Bool) { self.available = available }

    var control: LDACPriorityControl {
        LDACPriorityControl(request: { enabled, removed in
            self.lock.withLock {
                self.enabled = enabled && self.available
                self.requests.append(enabled)
            }
        }, state: {
            self.lock.withLock { .init(phase: self.enabled ? "configured" : self.requests.isEmpty ? "observing" : "idle", error: nil,
                prioritySent: self.enabled, targetPublicationSeen: self.enabled, targetPublicationWithdrawn: false) }
        })
    }
}

enum RateFixture {
    static let firstFrames = 12_288
    static let secondFrames = 24_576
    static let firstWatermark = firstFrames * 8
    static let secondWatermark = firstWatermark + secondFrames * 8
    static let firstFreeze = "CAPTURE_FROZEN rate=48000 bytes=\(firstWatermark) sourceFrames=\(firstFrames)"
    static let declinedFreeze = "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=96256 reserveFrames=864256 capacityFrames=960000"
    static let secondFreeze = "CAPTURE_FROZEN rate=96000 bytes=\(secondWatermark) sourceFrames=\(firstFrames + secondFrames / 2)"
    static let firstDrain = "RATE_DRAINED rate=48000 bytes=\(firstWatermark) sourceFrames=\(firstFrames) paddingFrames=128"
    static let secondDrain = "RATE_DRAINED rate=96000 bytes=\(secondWatermark) sourceFrames=\(secondFrames) paddingFrames=256"
}

extension LDACNativeSession.Helpers {
    init(fixture: URL) {
        signaling = fixture
        media = fixture
        capture = fixture
        connection = fixture
    }
}
extension LDACNativeSession {
    static func priorityPreparationCheck(executable: URL) throws {
        for phase in ["preparation-failed", "cleanup-required", "observing"] {
            for stage in ["preflight", "disconnect"] {
                let state = LDACPriorityControl.State(phase: phase,
                    error: phase == "observing" ? "Audio-host connection was invalidated." : nil,
                    prioritySent: false, targetPublicationSeen: false, targetPublicationWithdrawn: false)
                let priority = LDACPriorityControl(request: { _, _ in fatalError("Preparation sent a priority mutation") },
                    state: { state })
                let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                    helpers: Helpers(fixture: executable), gain: 0, priority: priority, receive: { _ in })
                let preflight = try LDACNativeChild(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], inheritedPCM: nil)
                defer { cleanUp(Array(session.children.values)) }
                session.children["preflight"] = preflight
                try waitUntil {
                    _ = try preflight.readLines()
                    preflight.reap()
                    return preflight.finished
                }
                session.preflightReady = true
                session.deadline = DispatchTime.now() + 10
                var rejected = false
                do {
                    if stage == "preflight" { try session.advance() }
                    else { try session.handle("probe", line: "SIGNALING_ARMED time_ns=\(clock_gettime_nsec_np(CLOCK_MONOTONIC))") }
                } catch {
                    rejected = true
                    try require(error.localizedDescription == state.diagnosticDescription, "Preparation failure lost publication evidence")
                }
                try require(rejected && !session.handoffRequested && session.children["probe"] == nil &&
                    session.children["disconnect"] == nil && session.priorityPhase == .unused,
                    "Failed priority preparation disrupted ordinary Bluetooth audio at \(stage)")
            }
        }
    }

    static func priorityActivationFailureCheck(executable: URL) throws {
        for (phase, sent, error) in [("idle", nil, nil), ("idle", true, nil),
                                     ("cleanup-required", true, nil), ("idle", false, "Connection failed")] as [(String, Bool?, String?)] {
            let priority = LDACPriorityControl(request: { _, _ in fatalError("Activation check sent another mutation") },
                state: { .init(phase: phase, error: error, prioritySent: sent) })
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, priority: priority, receive: { _ in })
            session.startAccepted = true
            session.priorityPhase = .configuring
            session.deadline = DispatchTime.now() + 10
            var rejected = false
            do { try session.advance() } catch { rejected = true }
            try require(rejected && !session.started && session.priorityPhase == .configuring,
                "Uncertain or failed priority was treated as an unavailable hint")
        }
    }

    static func earlyMediaPreparationCheck(executable: URL, cancelled: Bool) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(fixture: executable), gain: 0, outputDeviceUID: "fixture-output",
            outputSampleRate: .hz48000, receive: { _ in })
        let probe = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "read", "FIXTURE_WAITING", "stop", "0"], inheritedPCM: nil)
        defer {
            cleanUp(Array(session.children.values))
            if session.pcmRead >= 0 { Darwin.close(session.pcmRead) }
            if session.pcmWrite >= 0 { Darwin.close(session.pcmWrite) }
        }
        session.children["probe"] = probe
        session.connected = true
        try session.handle("probe", line: "OWNED_OPEN CID=0040 outgoingMTU=1000")
        try session.advance()
        try require(session.children["media"] == nil && session.children["capture"] == nil,
            "Helper preparation preceded compatible endpoint discovery")
        try session.handle("probe", line: "PREPARE_MEDIA")
        try session.advance()
        guard let media = session.children["media"], let capture = session.children["capture"] else {
            throw ClosureCheckError(description: "Media and capture preparation did not start together before the connector finished")
        }
        var capturePrepared = false
        func readCapture() throws {
            for line in try capture.readLines() {
                if line == "PCM_CAPTURE_PREPARED rate=48000" { capturePrepared = true }
                try session.handle("capture", line: line)
            }
        }
        try waitUntil {
            for line in try media.readLines() { try session.handle("media", line: line) }
            try readCapture()
            return session.mediaPrepared && capturePrepared
        }
        try session.advance()
        try require(!session.preparedSent && !session.captureStartSent && session.mediaGate.cid == nil && !session.pcmReady,
            "Early preparation advanced media or audio capture before verified readiness")
        if cancelled { session.stop(restoreAudio: false) }
        else { session.fail("Fixture connection failed before readiness", stage: "connector") }
        try waitUntil {
            for child in [probe, media] {
                _ = try child.readLines()
                child.reap()
            }
            try readCapture()
            capture.reap()
            try session.advance()
            return probe.finished && media.finished && capture.finished
        }
        try require(probe.status == 0 && media.status == 0 && session.canRestore && !session.preparedSent && !session.started,
            "Early cancellation or failure did not close the prepared media helper cleanly")
        try require(!session.captureStartSent && !session.captureReady && !session.mediaStopSent
            && session.captureCancelledBeforeStream && session.captureStoppedCleanly && session.hardFailure != cancelled,
            "Prepared capture did not stop cleanly without starting audio or asking unopened media to stop")
    }

    @MainActor
    static func logfreePlaybackCheck(executable: URL, priorityAvailable: Bool, liveRates: Bool = false,
                                     capturePermissionMode: CapturePermissionMode = .check, mediaReadyFault: String? = nil, warmHold: Bool = false, warmExit: String? = nil) async throws {
        let barrier = FileManager.default.temporaryDirectory.appendingPathComponent("acouplet-capture-barrier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: barrier, withIntermediateDirectories: false)
        setenv("ACOUPLET_FIXTURE_CAPTURE_BARRIER", barrier.path, 1)
        if let mediaReadyFault { setenv("ACOUPLET_FIXTURE_MEDIA_READY_FAULT", mediaReadyFault, 1) }
        if let warmExit { setenv("ACOUPLET_FIXTURE_WARM_EXIT", warmExit, 1) }
        defer {
            unsetenv("ACOUPLET_FIXTURE_WARM_EXIT")
            unsetenv("ACOUPLET_FIXTURE_CAPTURE_BARRIER")
            unsetenv("ACOUPLET_FIXTURE_MEDIA_READY_FAULT")
            try? FileManager.default.removeItem(at: barrier)
        }
        let events = SessionEvents()
        let priority = FixturePriority(available: priorityAvailable)
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(fixture: executable), gain: 0.25, outputDeviceUID: liveRates ? "fixture-live-rate" : warmHold ? "fixture-warm-hold" : "fixture-output",
            outputSampleRate: .hz48000,
            priority: priority.control, capturePermissionMode: capturePermissionMode, receive: { events.values.append($0) })
        session.start()
        var handedOff = false
        var stopped = false
        var gainApplied = false
        var parkRequested = false
        var resumeRequested = false
        var heldAt: DispatchTime?
        var startRequestedAt: DispatchTime?
        var disallowedAuthorization: UUID?
        let peerEnded = ["peer-close", "peer-abort", "peer-close-before-suspend"].contains(warmExit ?? "")
        var rateRequested = false
        var rejectedRateRequested = false
        let deadline = DispatchTime.now() + 15
        while DispatchTime.now() < deadline {
            if !handedOff, events.values.contains(where: { if case .handoffReady = $0 { return true }; return false }) {
                session.allowHandoff()
                handedOff = true
            }
            let active = events.values.contains { if case .active = $0 { return true }; return false }
            let held = events.values.contains { if case .warmHeld = $0 { return true }; return false }
            let resumed = events.values.contains {
                if case let .warmResumed(format) = $0 { return format.sampleRateHz == 48000 }
                return false
            }
            if warmHold, active, !parkRequested {
                session.park()
                parkRequested = true
            }
            if warmHold, held, !resumeRequested, !peerEnded {
                let beganHolding = heldAt ?? .now()
                heldAt = beganHolding
                if warmExit != "long-hold" || DispatchTime.now() >= beganHolding + 6 {
                    session.updateGain(0.9)
                    if warmExit == "queued-configuration" || warmExit == "stop-prefill" {
                        session.updateConfiguration(.init(sampleRate: .hz48000, quality: .quality))
                    }
                    if warmExit == "stop" {
                        session.stop(restoreAudio: false)
                        stopped = true
                    } else {
                        session.resumeParkedStream()
                    }
                    resumeRequested = true
                }
            }
            if let authorization = events.values.compactMap({
                if case let .warmCaptureReady(value) = $0 { return value }
                return nil as UUID?
            }).last {
                if disallowedAuthorization == nil {
                    let stale = UUID()
                    disallowedAuthorization = stale
                    session.allowParkedStart(stale)
                    if warmExit == "stop-prefill" {
                        session.stop(restoreAudio: false)
                        session.allowParkedStart(authorization)
                    }
                    startRequestedAt = .now()
                } else if warmExit != "stop-prefill" && warmExit != "authorization-timeout",
                          let startRequestedAt, DispatchTime.now() >= startRequestedAt + .milliseconds(120) {
                    session.allowParkedStart(authorization)
                }
            }
            if warmExit == "overlap-stop", !stopped,
               FileManager.default.fileExists(atPath: barrier.appendingPathComponent("warm-start-accepted").path) {
                session.stop(restoreAudio: false)
                stopped = true
            }
            if !gainApplied, warmHold ? resumed : active {
                session.updateGain(0.5)
                gainApplied = true
            }
            let gainConfirmed = events.values.contains { if case .gainApplied(0.5) = $0 { return true }; return false }
            if liveRates, gainConfirmed, !rateRequested {
                rateRequested = true
                session.updateConfiguration(.init(sampleRate: .hz96000, quality: .quality))
            }
            if rateRequested, !rejectedRateRequested, events.values.contains(where: {
                if case let .formatChanged(format) = $0 { return format.sampleRateHz == 96000 }
                return false
            }) {
                rejectedRateRequested = true
                session.updateConfiguration(.init(sampleRate: .hz88200, quality: .quality))
            }
            let rateRolledBack = events.values.contains { if case .sampleRateChangeRejected(requested: .hz88200, active: .hz96000) = $0 { return true }; return false }
            if !stopped, gainConfirmed, !liveRates || rateRolledBack {
                session.stop(restoreAudio: false)
                stopped = true
            }
            if events.values.contains(where: { if case .finished = $0 { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer {
            cleanUp(Array(session.children.values))
            if let raw = session.rawURL { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Log-free fixture did not complete within fifteen seconds")
        }
        let log = try String(contentsOf: session.rawURL!.deletingLastPathComponent().appendingPathComponent("session.log"), encoding: .utf8)
        let ownedMediaEvents = events.values.indices.filter { if case .ownedMediaReady = events.values[$0] { return true }; return false }
        if let mediaReadyFault {
            let expected = mediaReadyFault == "format" ? "LDAC did not start with the selected audio format."
                : "The media helper reported invalid or repeated channel readiness."
            try require(handedOff && completion.message != nil && log.contains("FAILED \(expected)"),
                "Malformed media readiness was not rejected: \(mediaReadyFault)")
            try require(ownedMediaEvents.isEmpty && !session.captureStartSent && !session.captureReady && !session.pcmReady && !session.started
                && !log.contains("COMMAND capture capture") && !log.contains("COMMAND media start"),
                "Unverified media readiness enabled capture: \(mediaReadyFault)")
            try require(session.children["capture"]?.finished == true && session.children["media"]?.finished == true
                && session.captureCancelledBeforeStream && session.captureStoppedCleanly
                && session.mediaGate.closed && session.signalingGate.closed && !session.shutdownUnverified,
                "Invalid media readiness did not clean up both helpers or their owned channels: \(mediaReadyFault)")
            return
        }
        let activeEvent = events.values.firstIndex { if case .active = $0 { return true }; return false }
        try require(ownedMediaEvents.count == 1 && activeEvent.map({ ownedMediaEvents[0] < $0 }) == true,
                    "Cold owned-media readiness was missing, repeated, or published after the stream became active")
        if let warmExit, !["long-hold", "queued-configuration", "overlap"].contains(warmExit) {
            let orderly = ["stop", "stop-prefill", "overlap-stop"].contains(warmExit) || peerEnded
            let expected = warmExit == "authorization-timeout" ? "FAILED LDAC could not complete its warm hold within the deadline."
                : "FAILED Unexpected response while holding the LDAC stream."
            try require((completion.message == nil) == orderly && (orderly || log.contains(expected)),
                "A held-channel interruption had the wrong outcome: \(warmExit)")
            try require(session.signalingGate.closed && session.mediaGate.closed && session.captureStoppedCleanly
                && !session.shutdownUnverified && !log.contains("COMMAND media resume") && !log.contains("COMMAND media gain 0.5"),
                "A held-channel interruption reopened playback or failed to close: \(warmExit)")
            let prefillRequested = ["start-cid", "stop-prefill", "authorization-timeout", "overlap-stop"].contains(warmExit)
            let startSent = ["start-cid", "overlap-stop"].contains(warmExit)
            try require(log.contains("COMMAND probe resume") == startSent
                && log.contains("COMMAND media warm-prefill") == prefillRequested
                && !log.contains("COMMAND media quality high")
                && (!peerEnded || !log.contains("COMMAND probe media-finished")),
                "An invalid channel report advanced the wrong stage: \(warmExit)")
            return
        }
        try require(handedOff && gainApplied && stopped && completion.message == nil,
            "Log-free capture/playback/stop failed: \(completion.message ?? "missing active state")")
        try require(priority.lock.withLock { priority.requests } == (priorityAvailable ? [true, false] : [true]),
            "Priority requests did not preserve available-hint cleanup or unavailable-hint skipping")
        try require(session.captureDestroyed && session.captureStoppedCleanly && session.connectorSettled,
            "Capture or connection guardian cleanup was not confirmed")
        try require(session.signalingGate.closed && session.mediaGate.closed && !session.shutdownUnverified,
            "Owned channel callbacks did not confirm shutdown")
        try require(log.contains("LAUNCH preflight") == (capturePermissionMode == .check),
            "An already verified session repeated the targeted permission probe")
        if liveRates {
            let formats = events.values.compactMap { if case let .formatChanged(format) = $0 { return format }; return nil as LDACFormat? }
            try require(formats == Array(repeating: .init(sampleRateHz: 96000, bitrateKbps: 990, channels: 2, sourceSampleRateHz: 48000), count: 2),
                        "Rate changes reported unverified or misleading formats")
            try require(log.components(separatedBy: "LAUNCH capture").count == 2 &&
                        log.components(separatedBy: "COMMAND media open").count == 2 &&
                        log.components(separatedBy: "COMMAND probe resume").count == 4 &&
                        log.components(separatedBy: "COMMAND capture freeze").count == 3 &&
                        log.components(separatedBy: "COMMAND capture rate ").count == 3,
                        "Rate changes replaced the capture or owned transport")
            let initial = ["COMMAND capture freeze", "capture \(RateFixture.firstFreeze)",
                "COMMAND media drain \(RateFixture.firstWatermark)", "media \(RateFixture.firstDrain)",
                "COMMAND probe rate 96000", "probe RATE_SELECTED rate=96000", "COMMAND media rate 96000 high",
                "media RATE_PREPARED rate=96000", "COMMAND probe resume", "probe RATE_START_ACCEPTED rate=96000",
                "COMMAND capture rate 96000"]
            let rollback = ["COMMAND capture freeze", "capture \(RateFixture.secondFreeze)",
                "COMMAND media drain \(RateFixture.secondWatermark)", "media \(RateFixture.secondDrain)",
                "COMMAND probe rate 88200", "probe RATE_SELECTED rate=88200", "COMMAND media rate 88200 high",
                "media RATE_PREPARED rate=88200", "COMMAND probe resume", "probe RATE_ROLLBACK rate=96000",
                "COMMAND media rate 96000 high", "media RATE_PREPARED rate=96000", "COMMAND probe resume",
                "probe RATE_START_ACCEPTED rate=96000", "COMMAND capture rate 96000"]
            let live = ["COMMAND media resume", "media RATE_LIVE rate=96000"]
            for readiness in ["capture PCM_CAPTURE_RESUMED rate=96000", "media PCM_READY frames=24000 rate=96000"] {
                var next = log.startIndex
                for marker in initial + [readiness] + live + rollback + [readiness] + live {
                    guard let found = log.range(of: marker, range: next..<log.endIndex) else {
                        throw ClosureCheckError(description: "Missing or out-of-order live-rate marker: \(marker)")
                    }
                    next = found.upperBound
                }
            }
            try require(!log.contains("COMMAND capture rate 88200") && !log.contains("COMMAND capture pause"),
                        "A refused Start released or re-froze capture at the abandoned rate")
        }
        if warmHold {
            let order = [("media PARK_MEDIA_PAUSED CID=0041", "COMMAND probe park"),
                ("capture PARK_CAPTURE_PAUSED rate=48000", "COMMAND probe park"),
                ("probe PARK_SUSPENDED signalingCID=0040 mediaCID=0041", "COMMAND media warm-prefill"),
                ("capture PARK_CAPTURE_RESUMED rate=48000", "COMMAND probe resume"),
                ("media PARK_MEDIA_PREFILL_PREPARED rate=48000", "COMMAND capture warm-resume"),
                ("COMMAND media warm-prefill", "COMMAND probe resume"),
                ("probe PARK_START_ACCEPTED rate=48000 signalingCID=0040 mediaCID=0041", "COMMAND media resume"),
                ("media PARK_LIVE CID=0041 rate=48000", "COMMAND media gain 0.5")]
            for (first, second) in order {
                guard let before = log.range(of: first), let after = log.range(of: second), before.lowerBound < after.lowerBound else {
                    throw ClosureCheckError(description: "Missing or out-of-order warm ownership: \(first), \(second)")
                }
            }
            if warmExit == "overlap" {
                guard let start = log.range(of: "COMMAND probe resume"),
                      let prefill = log.range(of: "media PCM_READY ", range: start.upperBound..<log.endIndex),
                      let media = log.range(of: "COMMAND media resume"), prefill.lowerBound < media.lowerBound else {
                    throw ClosureCheckError(description: "START did not overlap the full PCM prefill")
                }
            }
            if warmExit == "queued-configuration" {
                guard let live = log.range(of: "media PARK_LIVE"), let quality = log.range(of: "COMMAND media quality high"),
                      live.lowerBound < quality.lowerBound else {
                    throw ClosureCheckError(description: "A queued quality change escaped before warm media resumed")
                }
            }
            try require(parkRequested && resumeRequested && log.components(separatedBy: "LAUNCH capture").count == 2 &&
                log.components(separatedBy: "COMMAND media open").count == 2 && !log.contains("COMMAND probe rate ") &&
                !log.contains("COMMAND media gain 0.9"),
                "Warm handoff reopened a channel or changed the negotiated format")
        }
        try require(!log.contains("LAUNCH daemon") && !log.contains("transport-closed") && !log.contains("COMMAND probe 0x"),
            "Log-free playback still required daemon framing or fabricated closure")
        if priorityAvailable {
            try require(!log.contains("PRIORITY_CONFIGURATION_SKIPPED"), "Available priority was skipped")
        } else {
            try require(!log.contains("PRIORITY_STOP_REQUESTED") &&
                log.contains("PRIORITY_CONFIGURATION_SKIPPED unavailable=1 prioritySent=0"),
                "Unavailable priority was not explicitly skipped without cleanup mutation")
            try require(events.values.contains(where: {
                if case let .diagnostic(value) = $0 { return value.detail == "Bluetooth playback hint unavailable; skipped without sending." }
                return false
            }), "Unavailable hint diagnostic was not emitted")
        }
        for (first, second) in [("SIGNALING_ARMED", "LAUNCH disconnect"), ("ACL_CONNECTED", "COMMAND probe acquire"),
            ("PREPARE_MEDIA", "LAUNCH media"), ("PREPARE_MEDIA", "LAUNCH capture"),
            ("LAUNCH capture", "media READY CID="), ("CONNECT_READY", "COMMAND probe media-prepared"),
            ("MEDIA_PREPARED", "COMMAND probe media-prepared"), ("OPEN_ACCEPTED", "COMMAND media open"),
            ("media OWNED_OPEN CID=", "media READY CID="), ("media READY CID=", "COMMAND capture capture"),
            ("COMMAND capture capture", "PCM_CAPTURE_READY"), ("COMMAND capture capture", "media PCM_READY"),
            ("PCM_CAPTURE_READY", "COMMAND probe media-ready"), ("PCM_READY", "COMMAND probe media-ready"),
            ("COMMAND probe media-ready", "probe START_ACCEPTED"), ("probe START_ACCEPTED", "COMMAND media start"),
            (priorityAvailable ? "PRIORITY_CONFIGURATION_ATTEMPT_COMPLETED" : "PRIORITY_CONFIGURATION_SKIPPED", "COMMAND media start"),
            ("FEED_COMPLETE", priorityAvailable ? "PRIORITY_STOP_REQUESTED" : "COMMAND probe media-finished"), ("DESTROY_TAP", "COMMAND probe media-finished"),
            ("media OWNED_CLOSED", "COMMAND probe media-closed")] {
            guard let before = log.range(of: first), let after = log.range(of: second) else {
                throw ClosureCheckError(description: "Missing lifecycle marker: \(first), \(second)")
            }
            try require(before.lowerBound < after.lowerBound, "Out-of-order log-free lifecycle: \(first), \(second)")
        }
    }

    @MainActor
    static func nativeClockPlaybackCheck(executable: URL, mode: String) async throws {
        setenv("ACOUPLET_NATIVE_CLOCK_FIXTURE", mode, 1)
        defer { unsetenv("ACOUPLET_NATIVE_CLOCK_FIXTURE") }
        let timer = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: timer, withIntermediateDirectories: false)
        setenv("ACOUPLET_NATIVE_CLOCK_BARRIER", timer.path, 1)
        defer {
            unsetenv("ACOUPLET_NATIVE_CLOCK_BARRIER")
            try? FileManager.default.removeItem(at: timer)
        }
        let events = SessionEvents()
        var rates: [Int] = []
        var verified: LDACSampleRate = .hz48000
        let clock = LDACNativeClockControl { from, to, _ in
            try require(verified == from, "Native clock request used a stale starting rate")
            rates.append(to.rawValue)
            if to == .hz96000 {
                try Data().write(to: timer.appendingPathComponent("clock-issued"))
                if ["park-during-rate", "stop-during-clock", "hal-timeout"].contains(mode) {
                    try await Task.sleep(for: .milliseconds(250))
                } else if ["timing", "staging-timing", "overlap-barrier"].contains(mode) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if mode == "hal-rejection" { return false }
                if mode == "hal-timeout" { throw ClosureCheckError(description: "Unconfirmed native HAL timeout") }
            } else if mode == "reverse-refused" {
                return false
            }
            verified = to
            return true
        }
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(fixture: executable), gain: 0.25, outputDeviceUID: "fixture-native-clock",
            outputSampleRate: .hz48000, clock: clock, capturePermissionMode: .verified, receive: { events.values.append($0) })
        session.start()
        var handedOff = false, gainApplied = false, requested = false, secondRequested = false, stopped = false
        var parkRequested = false
        let roundTrip = ["round-trip", "recreated-round-trip", "timing", "staging-timing", "overlap-barrier", "staged-before-peer"].contains(mode)
        let deadline = DispatchTime.now() + 15
        while DispatchTime.now() < deadline {
            if !handedOff, events.values.contains(where: { if case .handoffReady = $0 { return true }; return false }) {
                session.allowHandoff()
                handedOff = true
            }
            if !gainApplied, events.values.contains(where: { if case .active = $0 { return true }; return false }) {
                session.updateGain(0.5)
                gainApplied = true
            }
            if !requested, events.values.contains(where: { if case .gainApplied(0.5) = $0 { return true }; return false }) {
                session.updateConfiguration(.init(sampleRate: .hz96000, quality: .quality))
                requested = true
            }
            if mode == "park-during-rate", rates == [96000], !parkRequested {
                session.park()
                parkRequested = true
            }
            let stagedStop = mode == "staged-stop" && FileManager.default.fileExists(atPath: timer.appendingPathComponent("tap-prepared").path)
            if !stopped, mode == "stop-during-clock" && rates == [96000] || stagedStop {
                session.stop(restoreAudio: false)
                stopped = true
            }
            let formats = events.values.compactMap { if case let .formatChanged(format) = $0 { return format }; return nil as LDACFormat? }
            if roundTrip, !secondRequested, formats.contains(where: { $0.sampleRateHz == 96000 }) {
                session.updateConfiguration(.init(sampleRate: .hz48000, quality: .quality))
                secondRequested = true
            }
            let rejected = events.values.contains { if case .sampleRateChangeRejected(requested: .hz96000, active: .hz48000) = $0 { return true }; return false }
            if !stopped, (roundTrip ? formats.count == 2 : formats.count == 1 && rejected) {
                session.stop(restoreAudio: false)
                stopped = true
            }
            if events.values.contains(where: { if case .finished = $0 { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer {
            cleanUp(Array(session.children.values))
            if let raw = session.rawURL { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
        }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Native clock fixture did not complete: \(mode), events=\(events.names)")
        }
        let formats = events.values.compactMap { if case let .formatChanged(format) = $0 { return format }; return nil as LDACFormat? }
        if ["hal-timeout", "partial-after-ready", "park-during-rate", "stop-during-clock", "reverse-refused", "staged-partial", "staged-stop"].contains(mode) {
            let expectedRates = mode == "hal-timeout" ? [96000] : [96000, 48000]
            let expectedClock: LDACSampleRate = mode == "reverse-refused" ? .hz96000 : .hz48000
            try require((completion.message == nil) == ["stop-during-clock", "staged-stop"].contains(mode) && formats.isEmpty && rates == expectedRates && verified == expectedClock,
                "An uncommitted native clock did not settle safely in \(mode): \(rates), \(verified), \(completion.message ?? "clean stop")")
        } else {
            try require(handedOff && gainApplied && stopped && completion.message == nil,
                "Native clock fixture failed: \(mode): \(completion.message ?? "missing active state")")
            try require(formats.map(\.sampleRateHz) == (roundTrip ? [96000, 48000] : [48000]) &&
                formats.allSatisfy { $0.sampleRateHz == $0.sourceSampleRateHz } &&
                rates == (mode == "hal-rejection" ? [96000] : [96000, 48000]) && verified == .hz48000,
                "Native clock, capture and transport did not agree for \(mode): \(rates), \(formats)")
        }
        let log = try String(contentsOf: session.rawURL!.deletingLastPathComponent().appendingPathComponent("session.log"), encoding: .utf8)
        try require(log.components(separatedBy: "LAUNCH media").count == 2 && log.components(separatedBy: "LAUNCH probe").count == 2,
            "Native clock switch replaced an owned AVDTP channel")
        try require(log.contains("COMMAND capture clock-freeze") && log.contains("COMMAND media drain 98304"),
            "Native source did not close its PCM epoch before negotiation")
        if roundTrip {
            let launchCount = mode == "recreated-round-trip" ? 2 : 1
            try require(log.contains("COMMAND media drain \(RateFixture.secondWatermark)") &&
                log.components(separatedBy: "LAUNCH capture").count == launchCount + 1 &&
                log.contains("COMMAND capture clock-rate 96000") && log.contains("COMMAND capture clock-rate 48000") &&
                log.components(separatedBy: "capture DESTROY_TAP status=0").count == launchCount + 1 &&
                log.components(separatedBy: "capture CLOCK_CREATE_TAP status=0").count == 4 - launchCount,
                "Native capture did not replace its tap on the retained aggregate or preserve its absolute PCM watermark")
        }
        if mode == "empty-after-ready" || mode == "partial-after-ready" {
            try require(log.contains("PCM_CAPTURE_READY rate=96000") && !log.contains("RATE_LIVE rate=96000") &&
                log.contains("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=\(mode == "partial-after-ready" ? 4 : 0)"),
                "The ready-but-failed candidate was not accounted for")
        }
        if ["peer-rollback", "tap-rejection", "start-failure", "hal-timeout", "hal-rejection", "peer-rejected-suspend", "peer-rejected-config", "reverse-refused", "stop-during-clock"].contains(mode) {
            try require(!log.contains("PCM_CAPTURE_READY rate=96000"), "An abandoned rate reached the PCM writer")
        }
        if mode == "stop-during-clock" {
            try require(!log.contains("COMMAND probe resume") && !log.contains("COMMAND capture clock-rate")
                && session.signalingGate.closed && session.mediaGate.closed && !session.shutdownUnverified,
                "Stop during native clock work released PCM or bypassed owned closure")
        }
        if mode == "staged-stop" {
            try requireOrder(log, ["PCM_CAPTURE_CLOCK_PREPARED rate=96000", "PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0"])
            try require(!log.contains("RATE_SELECTED rate=96000") && !log.contains("COMMAND probe resume")
                && !log.contains("PCM_CAPTURE_READY rate=96000") && session.signalingGate.closed && session.mediaGate.closed,
                "Stop during sealed capture published tentative PCM or lost owned closure")
        }
        if mode == "staged-before-peer" {
            try requireOrder(log, ["RATE_DRAINED rate=48000", "PCM_CAPTURE_CLOCK_PREPARED rate=96000", "RATE_SELECTED rate=96000",
                                   "COMMAND probe resume", "RATE_START_ACCEPTED rate=96000", "COMMAND capture capture",
                                   "PCM_CAPTURE_READY rate=96000", "RATE_LIVE rate=96000"])
        }
        if ["staged-denial", "staged-denial-during-tap", "staged-denial-before-media", "staged-partial", "staged-failed-capture"].contains(mode) {
            try require(!log.contains("PCM_CAPTURE_READY rate=96000") && !log.contains("RATE_START_ACCEPTED rate=96000"),
                        "A tentative capture crossed the Sony START boundary: \(mode)")
            let selected = mode == "staged-failed-capture" ? "RATE_SELECTED rate=96000" : "RATE_SELECTED rate=48000"
            if mode == "staged-denial-before-media" {
                try requireOrder(log, [selected, "RATE_PREPARED rate=96000", "RATE_PREPARED rate=48000"])
                try require(!log.contains("COMMAND capture clock-rate 96000"), "A peer-rejected epoch opened the candidate tap")
            } else if mode == "staged-denial" || mode == "staged-denial-during-tap" {
                try requireOrder(log, ["COMMAND capture clock-rate 96000", selected, "PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0", "RATE_PREPARED rate=48000"])
                if mode == "staged-denial-during-tap" {
                    try requireOrder(log, [selected, "PCM_CAPTURE_CLOCK_PREPARED rate=96000", "PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0"])
                }
            } else if mode == "staged-failed-capture" {
                try requireOrder(log, ["PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0", selected,
                                      "COMMAND probe rollback", "RATE_PREPARED rate=48000"])
            } else {
                try require(log.contains("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=4") && !log.contains("RATE_PREPARED rate=48000")
                    && !log.contains("RATE_LIVE rate=96000"), "Unproved candidate bytes allowed rollback or native playback")
            }
        }
        if mode == "timing" || mode == "staging-timing" {
            let times = ["CAPTURE_FROZEN rate=48000", "RATE_LIVE rate=96000", "CAPTURE_FROZEN rate=96000", "RATE_LIVE rate=48000"]
                .compactMap { marker in log.split(separator: "\n").first { $0.contains(marker) }?.split(separator: " ").first.flatMap { Double($0) } }
            try require(times.count == 4, "Missing rate timing witness")
            print("TIMING \((times[1] - times[0]) * 1000) \((times[3] - times[2]) * 1000)")
        }
        if mode == "park-during-rate" {
            try require(parkRequested && log.contains("FAILED LDAC cannot hold or resume the current stream.")
                && !log.contains("COMMAND media park") && !log.contains("LAUNCH restore-disconnect")
                && session.signalingGate.closed && session.mediaGate.closed && !session.shutdownUnverified,
                "A park request racing the native clock silently disappeared or reset the ACL")
        }
        print("PASS native rate fixture \(mode): verified capture protocol and same owned transports")
    }

    static func requireOrder(_ log: String, _ markers: [String]) throws {
        var remaining = log[...]
        for marker in markers {
            guard let match = remaining.range(of: marker) else { throw ClosureCheckError(description: "Missing ordered native marker: \(marker)") }
            remaining = remaining[match.upperBound...]
        }
    }

    @MainActor
    static func stopBeforeQueuedClockCheck() async throws {
        let executable = URL(fileURLWithPath: "/bin/cat")
        for requested in [true, false] {
            let media = try LDACNativeChild(executable: executable, arguments: [], inheritedPCM: nil)
            defer { cleanUp([media]) }
            var calls = 0
            let clock = LDACNativeClockControl { _, _, _ in calls += 1; return true }
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, clock: clock, receive: { _ in })
            session.children["media"] = media
            session.rateChange = RateChange(.init(sampleRate: .hz96000, quality: .quality), sourceClock: .hz48000)
            session.deadline = DispatchTime.now() + 18
            try session.handle("capture", line: RateFixture.firstFreeze)
            try require(session.rateChange?.clockRequest == .hz96000, "The queued request was not represented in the rate transition")
            if requested { session.stop(restoreAudio: false) }
            else { session.fail("Fixture failure after capture freeze") }
            try await Task.sleep(for: .milliseconds(25))
            try session.settleClockBeforeRelease()
            try require(calls == 0 && session.rateChange?.clockRequest == nil && session.rateChange?.sourceClock == .hz48000,
                        "A stopped, queued HAL request applied after its authorization ended")
        }
        print("PASS queued native clock cannot apply after Stop or a failure")
    }

    static func rateTransitionDeadlineCheck(executable: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        let requested = LDACConfiguration(sampleRate: .hz96000, quality: .quality)
        for elapsed: TimeInterval in [17, 18] {
            SessionClock.shared.set(elapsed: 0)
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { _ in })
            let originalDeadline = SessionClock.shared.monotonic + 18
            session.deadline = originalDeadline
            session.rateChange = RateChange(requested)
            session.rateChange?.phase = .sending
            SessionClock.shared.set(elapsed: elapsed)
            var timedOut = false
            do { try session.handle("media", line: "RATE_LIVE rate=96000 channels=2 bitrateKbps=990 eqmid=0") }
            catch { timedOut = error.localizedDescription == "LDAC could not confirm the live sample rate change." }
            if elapsed < 18 {
                try require(!timedOut && session.rateChange == nil && session.activeConfiguration == requested,
                            "A valid rate report within the deadline did not commit")
            } else {
                try require(timedOut && session.rateChange != nil && session.deadline == originalDeadline &&
                            session.activeConfiguration.sampleRate == .hz48000,
                            "An overdue rate report replaced the active format or cleared its deadline")
            }
        }

        for elapsed: TimeInterval in [1, 16] {
            SessionClock.shared.set(elapsed: 0)
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { _ in })
            let capture = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
            let media = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
            let probe = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
            defer { cleanUp([capture, media, probe]) }
            session.children = ["capture": capture, "media": media, "probe": probe]
            try session.signalingGate.owned("OWNED_OPEN CID=0040 outgoingMTU=1000")
            try session.mediaGate.owned("OWNED_OPEN CID=0041 outgoingMTU=1000")
            let originalDeadline = SessionClock.shared.monotonic + 18
            session.deadline = originalDeadline
            session.rateChange = RateChange(requested)
            try session.handle("capture", line: RateFixture.firstFreeze)
            try session.handle("media", line: RateFixture.firstDrain)
            try session.handle("probe", line: "RATE_SELECTED rate=96000 suspended=1 rejected=0")
            try session.handle("media", line: "RATE_PREPARED rate=96000")
            try require(try capture.readLines().isEmpty, "Capture left freeze before the proposed Start")
            SessionClock.shared.set(elapsed: elapsed)
            try session.handle("probe", line: "RATE_ROLLBACK rate=48000")
            try require(session.rateChange?.selected.sampleRate == .hz48000 &&
                        session.deadline == min(originalDeadline, SessionClock.shared.monotonic + 7),
                        "Rate rollback did not preserve the original deadline and the shorter rollback limit")
            try session.handle("media", line: "RATE_PREPARED rate=48000")
            try require(try capture.readLines().isEmpty, "Rollback released capture before the original Start")
            try session.handle("probe", line: "RATE_START_ACCEPTED rate=48000 signalingCID=0040 mediaCID=0041")
            var captureCommands: [String] = []
            try waitUntil {
                captureCommands += try capture.readLines()
                return !captureCommands.isEmpty
            }
            try require(captureCommands == ["rate 48000"], "Rollback commanded capture outside the accepted original format")
        }
    }

    static func rateTransitionRejectionCheck(executable: URL) throws {
        let capture = ("capture", RateFixture.firstFreeze)
        let drain = ("media", RateFixture.firstDrain)
        let selection = ("probe", "RATE_SELECTED rate=96000 suspended=1 rejected=0")
        let prepared = ("media", "RATE_PREPARED rate=96000")
        let frozen = [capture]
        let drained = frozen + [drain]
        let starting = drained + [selection, prepared]
        let prefilling = starting + [("probe", "RATE_START_ACCEPTED rate=96000 signalingCID=0040 mediaCID=0041")]
        let cases: [(String, [(String, String)]?, String, String)] = [
            ("early-drain", [], "media", drain.1),
            ("early-selection", frozen, "probe", selection.1),
            ("wrong-frozen-rate", [], "capture", "CAPTURE_FROZEN rate=44100 bytes=98304 sourceFrames=12288"),
            ("unaligned-freeze-watermark", [], "capture", "CAPTURE_FROZEN rate=48000 bytes=98305 sourceFrames=12288"),
            ("oversized-freeze-watermark", [], "capture", "CAPTURE_FROZEN rate=48000 bytes=18446744073709551616 sourceFrames=12288"),
            ("oversized-source-count", [], "capture", "CAPTURE_FROZEN rate=48000 bytes=98304 sourceFrames=18446744073709551616"),
            ("malformed-freeze-count", [], "capture", "CAPTURE_FROZEN rate=48000 bytes=-8 sourceFrames=12288"),
            ("repeated-freeze", frozen, "capture", capture.1),
            ("unsolicited-freeze-decline", nil, "capture", RateFixture.declinedFreeze),
            ("late-freeze-decline", frozen, "capture", RateFixture.declinedFreeze),
            ("wrong-freeze-decline-rate", [], "capture", "CAPTURE_FREEZE_DECLINED rate=96000 queuedFrames=96256 reserveFrames=864256 capacityFrames=960000"),
            ("negative-freeze-decline-queue", [], "capture", "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=-1 reserveFrames=864256 capacityFrames=960000"),
            ("oversized-freeze-decline-reserve", [], "capture", "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=96256 reserveFrames=18446744073709551616 capacityFrames=960000"),
            ("missing-freeze-decline-capacity", [], "capture", "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=96256 reserveFrames=864256"),
            ("zero-freeze-decline-capacity", [], "capture", "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=0 reserveFrames=864256 capacityFrames=0"),
            ("freeze-decline-queue-exceeds-capacity", [], "capture", "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=960001 reserveFrames=864256 capacityFrames=960000"),
            ("freeze-decline-reserve-fits", [], "capture", "CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=95744 reserveFrames=864256 capacityFrames=960000"),
            ("wrong-drain-watermark", frozen, "media", "RATE_DRAINED rate=48000 bytes=98312 sourceFrames=12289 paddingFrames=127"),
            ("wrong-drain-rate", frozen, "media", "RATE_DRAINED rate=96000 bytes=98304 sourceFrames=12288 paddingFrames=128"),
            ("drain-frames-exceed-watermark", frozen, "media", "RATE_DRAINED rate=48000 bytes=98304 sourceFrames=12289 paddingFrames=128"),
            ("drain-padding-at-limit", frozen, "media", "RATE_DRAINED rate=48000 bytes=98304 sourceFrames=12288 paddingFrames=256"),
            ("malformed-drain-size", frozen, "media", "RATE_DRAINED rate=48000 bytes=98304 sourceFrames=12288 paddingFrames=-1"),
            ("oversized-drain-padding", frozen, "media", "RATE_DRAINED rate=48000 bytes=98304 sourceFrames=12288 paddingFrames=18446744073709551616"),
            ("early-prepare", drained, "media", prepared.1),
            ("early-capture-resume", starting, "capture", "PCM_CAPTURE_RESUMED rate=96000"),
            ("early-media-prefill", starting, "media", "PCM_READY frames=24000 rate=96000 channels=2 format=F32"),
            ("wrong-start-channel", starting, "probe", "RATE_START_ACCEPTED rate=96000 signalingCID=0041 mediaCID=0040"),
            ("undersized-prefill", prefilling, "media", "PCM_READY frames=23999 rate=96000 channels=2 format=F32"),
            ("oversized-prefill", prefilling, "media", "PCM_READY frames=24000 rate=96000 channels=2 format=F32 bufferedFrames=96001"),
        ]
        let cat = URL(fileURLWithPath: "/bin/cat")
        let children = try Dictionary(uniqueKeysWithValues: ["capture", "media", "probe"].map {
            ($0, try LDACNativeChild(executable: cat, arguments: [], inheritedPCM: nil))
        })
        defer { cleanUp(Array(children.values)) }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logURL) }
        for (name, valid, sender, report) in cases {
            try Data().write(to: logURL)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { _ in })
            session.children = children
            session.log = log
            try session.signalingGate.owned("OWNED_OPEN CID=0040 outgoingMTU=1000")
            try session.mediaGate.owned("OWNED_OPEN CID=0041 outgoingMTU=1000")
            session.deadline = DispatchTime.now() + 18
            if let valid {
                session.rateChange = RateChange(.init(sampleRate: .hz96000, quality: .quality))
                for (source, line) in valid { try session.handle(source, line: line) }
            }
            let original = session.activeConfiguration
            let deadline = session.deadline
            let phase = session.rateChange?.phase
            let before = try String(contentsOf: logURL, encoding: .utf8).components(separatedBy: "COMMAND ").count
            var rejected = false
            do { try session.handle(sender, line: report) }
            catch is LDACSessionError { rejected = true }
            let after = try String(contentsOf: logURL, encoding: .utf8).components(separatedBy: "COMMAND ").count
            try require(rejected && before == after && session.activeConfiguration == original && session.deadline == deadline &&
                        session.rateChange?.phase == phase,
                        "Invalid live-rate report \(name) advanced the handshake or changed the active stream")
            print("PASS invalid live-rate report \(name)")
        }
        let native = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(fixture: executable), gain: 0, receive: { _ in })
        native.children = children
        native.captureSourceRate = 48000
        native.rateChange = RateChange(.init(sampleRate: .hz48000, quality: .quality), sourceClock: .hz48000)
        native.rateChange?.phase = .prefilling
        native.deadline = DispatchTime.now() + 18
        for report in ["PCM_CAPTURE_RESUMED rate=48000", "PCM_CAPTURE_READY rate=48000 channels=2 format=F32 interleaved=1 bytesPerFrame=8"] {
            do {
                try native.handle("capture", line: report)
                throw ClosureCheckError(description: "Native capture accepted a ready message from an unverified epoch")
            } catch is LDACSessionError {}
        }
        try native.handle("capture", line: "PCM_CAPTURE_SOURCE rate=48000")
        try native.handle("capture", line: "PCM_CAPTURE_READY rate=48000 channels=2 format=F32 interleaved=1 bytesPerFrame=8")
        try require(native.rateChange?.captureResumed == true && native.rateChange?.pcmReady == false,
            "A current native capture witness did not permit the prepared epoch")
        print("PASS native capture requires a new source format witness after reusing the same rate")
    }

    @MainActor
    static func capturePressureDeclineCheck(executable: URL) async throws {
        let cat = URL(fileURLWithPath: "/bin/cat")
        let children = try Dictionary(uniqueKeysWithValues: ["capture", "media", "probe"].map {
            ($0, try LDACNativeChild(executable: cat, arguments: [], inheritedPCM: nil))
        })
        defer { cleanUp(Array(children.values)) }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let cases: [(String, LDACQuality, LDACConfiguration?)] = [
            (RateFixture.declinedFreeze, .connection, nil),
            (RateFixture.declinedFreeze, .balanced, nil),
            (RateFixture.declinedFreeze, .balanced, .init(sampleRate: .hz96000, quality: .quality)),
            ("CAPTURE_FREEZE_DECLINED rate=48000 queuedFrames=0 reserveFrames=960001 capacityFrames=960000",
                .balanced, .init(sampleRate: .hz88200, quality: .adaptive)),
        ]
        for (receipt, quality, newer) in cases {
            try Data().write(to: logURL)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { events.values.append($0) })
            session.children = children
            session.log = log
            session.active = true
            try session.signalingGate.owned("OWNED_OPEN CID=0040 outgoingMTU=1000")
            try session.mediaGate.owned("OWNED_OPEN CID=0041 outgoingMTU=1000")
            let requested = LDACConfiguration(sampleRate: .hz96000, quality: quality)
            session.updateConfiguration(requested)
            try session.advance()
            try require(session.rateChange?.requested == requested && session.rateChange?.phase == .freezing,
                "Rate request did not reach capture freeze")
            if let newer { session.updateConfiguration(newer) }

            try session.handle("media", line: receipt)
            try require(session.rateChange?.requested == requested && session.rateChange?.phase == .freezing &&
                session.requestedConfiguration == newer, "A media-origin freeze decline resolved the capture request")

            try session.handle("capture", line: receipt)
            try require(session.active && !session.shouldStop && session.failure == nil && session.rateChange == nil &&
                session.activeConfiguration == .init(sampleRate: .hz48000, quality: quality) &&
                session.deadline == .distantFuture && session.requestedConfiguration == newer,
                "Capture pressure interrupted the active stream or discarded a newer rate request")
            for _ in 0..<100 where events.names.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
            try require(events.names == ["sampleRateChangeDeferred"] && events.values.contains {
                if case let .sampleRateChangeDeferred(configuration, .hz48000) = $0 { return configuration == requested }
                return false
            }, "Capture pressure did not emit a single deferral for the original configuration and retained rate")
            let expected = ["capture freeze"] + (quality == .connection ? [] : ["media quality \(quality.rawValue)"])
            let commands = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").compactMap { line in
                line.range(of: "COMMAND ").map { String(line[$0.upperBound...]) }
            }
            try require(commands == expected && children.allSatisfy { session.children[$0.key]?.pid == $0.value.pid } &&
                session.signalingGate.cid == 0x40 && !session.signalingGate.closed &&
                session.mediaGate.cid == 0x41 && !session.mediaGate.closed,
                "Capture pressure changed the media transport or replaced a helper")
            if quality == .balanced {
                try session.handle("media", line: "LIVE_FORMAT rate=48000 channels=2 bitrateKbps=660 frameBytes=220")
                for _ in 0..<100 where events.names.count == 1 { try await Task.sleep(for: .milliseconds(1)) }
                try require(events.names == ["sampleRateChangeDeferred", "formatChanged"] && events.values.contains {
                    if case let .formatChanged(format) = $0 { return format.sampleRateHz == 48000 && format.bitrateKbps == 660 }
                    return false
                }, "Deferred rate did not allow the new bitrate to be confirmed on the active stream")
            }
            try session.advance()
            try require(session.rateChange?.requested == newer && session.requestedConfiguration == nil,
                "A declined request retried itself or prevented the newer request from starting")
        }
        print("PASS capture pressure defers the requested rate while keeping the stream, quality update, and newer requests")
    }

    @MainActor
    static func sinkRatePreflightCheck(executable: URL) async throws {
        let open = "OPEN_ACCEPTED signalingCID=0040 remoteSEID=3"
        let cases: [(String, LDACSampleRate, LDACSampleRate, LDACQuality, Bool)] = [
            (open + " rateMask=30", .hz48000, .hz96000, .connection, true),
            (open + " rateMask=14", .hz48000, .hz88200, .balanced, true),
            (open + " rateMask=20", .hz44100, .hz48000, .connection, true),
            (open + " rateMask=10", .hz48000, .hz44100, .connection, true),
            (open + " rateMask=14", .hz48000, .hz96000, .quality, false),
            (open + " rateMask=10", .hz48000, .hz48000, .balanced, false),
            (open, .hz48000, .hz96000, .connection, false),
            (open + " rateMask=GG", .hz48000, .hz96000, .connection, false),
            (open + " rateMask=20", .hz48000, .hz96000, .connection, false),
            ("OPEN_ACCEPTED signalingCID=0041 remoteSEID=3 rateMask=10", .hz48000, .hz96000, .connection, false),
        ]
        let cat = URL(fileURLWithPath: "/bin/cat")
        let capture = try LDACNativeChild(executable: cat, arguments: [], inheritedPCM: nil)
        let media = try LDACNativeChild(executable: cat, arguments: [], inheritedPCM: nil)
        defer { cleanUp([capture, media]) }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logURL) }

        for (receipt, original, requested, quality, rejected) in cases {
            try Data().write(to: logURL)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, configuration: .init(sampleRate: original),
                receive: { events.values.append($0) })
            session.children = ["capture": capture, "media": media]
            session.log = log
            try session.signalingGate.owned("OWNED_OPEN CID=0040 outgoingMTU=1000")
            session.preparedSent = true
            try session.handle("probe", line: receipt)
            session.active = true
            session.updateConfiguration(.init(sampleRate: requested, quality: quality))
            try session.advance()
            try session.advance()
            let commands = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").compactMap { line in
                line.range(of: "COMMAND ").map { String(line[$0.upperBound...]) }
            }
            let transitioning = !rejected && original != requested
            let expected = ["media open"] + (transitioning ? ["capture freeze"] : quality != .connection ? ["media quality \(quality.rawValue)"] : [])
            try require(commands == expected && (session.rateChange != nil) == transitioning &&
                        session.activeConfiguration == .init(sampleRate: original, quality: transitioning ? .connection : quality),
                        "Unexpected preflight for \(receipt) and \(requested): \(commands)")
            if rejected {
                if receipt == open + " rateMask=30" {
                    let next = LDACConfiguration(sampleRate: .hz44100, quality: .quality)
                    session.updateConfiguration(next)
                    try session.advance()
                    try require(session.rateChange?.requested == next, "A rejection discarded the next supported request")
                }
                for _ in 0..<100 where events.values.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
                guard events.values.count == 1, case let .sampleRateChangeRejected(rate, active) = events.values[0] else {
                    throw ClosureCheckError(description: "Missing preflight rejection for \(receipt) and \(requested)")
                }
                try require(rate == requested && active == original, "Preflight rejection identified the wrong rates")
            }
        }
    }

    static func acquisitionCheck(executable: URL) throws {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        for (baseline, connection, armed, prior, valid) in [
            (now - 2, now - 1, now - 3, false, true),
            (now - 4, now - 1, now - 3, false, false),
            (now - 1, now - 2, now - 3, false, false),
            (now - 2, now + 10_000_000_000, now - 3, false, false),
            (now - 3_000_000_000, now - 2_000_000_000, now - 4_000_000_000, false, false),
            (now - 2, now - 1, now - 3, true, false)
        ] {
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { _ in })
            session.signalingArmed = armed
            session.connected = prior
            let probe = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], inheritedPCM: nil)
            defer { cleanUp([probe]) }
            session.children["probe"] = probe
            var accepted = true
            do { try session.handle("connector", line: "ACL_CONNECTED baseline_ns=\(baseline) connected_ns=\(connection)") }
            catch { accepted = false }
            try require(accepted == valid, "Fresh ACL validation accepted a stale, reordered, future or repeated event")
        }
    }

    static func finishChildrenCheck(executable: URL) throws {
        for stubborn in [false, true] {
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
            let child = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", stubborn ? "trap '' TERM; echo READY; while :; do :; done" : "echo READY; exec sleep 60"], inheritedPCM: nil)
            let deadline = DispatchTime.now() + 2
            var ready = false
            while !ready && DispatchTime.now() < deadline {
                ready = try child.readLines().contains("READY")
                if !ready { Thread.sleep(forTimeInterval: 0.01) }
            }
            precondition(ready)
            session.children["capture"] = child
            session.finish()
            precondition(child.status != nil && kill(child.pid, 0) == -1 && errno == ESRCH)
            precondition(!stubborn || session.failure != nil)
        }
        print("PASS actual session finish reaps remaining children, including a SIGTERM-resistant child")
    }
}
extension LDACNativeSession {
    @MainActor
    static func ordinaryAudioRestorationPolicyCheck(executable: URL) async throws {
        for (restoreAudio, observedByGuardian) in [(true, false), (true, true), (false, false)] {
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, receive: { events.values.append($0) })
            let disconnect = try LDACNativeChild(executable: executable, arguments: ["fixture-disconnect"], inheritedPCM: nil)
            session.children["disconnect"] = disconnect
            defer { cleanUp(Array(session.children.values)) }
            try waitUntil {
                _ = try disconnect.readLines()
                disconnect.reap()
                return disconnect.finished
            }
            session.stop(restoreAudio: restoreAudio)
            if observedByGuardian {
                session.connected = true
                try session.handle("connector", line: "CONNECT_READY handle=0001 guarded=1")
                try session.handle("connector", line: "CONNECTION_DISCONNECTED handle=0001 connected=0")
            } else if restoreAudio {
                try session.beginRestore()
                let preparing = session.children["restore-disconnect"]!
                try waitUntil {
                    _ = try preparing.readLines()
                    preparing.reap()
                    return preparing.finished
                }
                try session.handle("restore-disconnect", line: "BEFORE time=1791160325.072411 address=02-00-00-00-00-01 paired=1 connected=0")
                try session.handle("restore-disconnect", line: "RESTORE_DISCONNECTED disconnected=1")
            }
            try session.beginRestore()
            try require(session.restoring && session.children["restore"] == nil,
                        "Ordinary audio restoration tried to reopen an absent headset")
            if !restoreAudio {
                try require(session.children["restore-disconnect"] == nil, "Relinquishing a healthy link caused a redundant disconnect")
            }
            session.finish()
            for _ in 0..<20 { await Task.yield() }
            guard case let .finished(completion)? = events.values.last else {
                throw ClosureCheckError(description: "Absent headset failed to finish cleanup")
            }
            try require(completion.message == nil && completion.targetDisconnected == restoreAudio && completion.waitForReconnect == restoreAudio,
                        "Ordinary audio restoration applied the wrong device loss classification")
        }
        print("PASS physical loss never reopens ordinary audio, and relinquishing a healthy link with settled priority never disconnects")
    }

    static func checkRestoreArguments(executable: URL, handle: Int?) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01", helpers: Helpers(fixture: executable), gain: 0) { _ in }
        let disconnect = try LDACNativeChild(executable: executable, arguments: ["fixture-disconnect"], inheritedPCM: nil)
        session.children["disconnect"] = disconnect
        func drain(_ child: LDACNativeChild) throws -> [String] {
            var lines: [String] = []
            for _ in 0..<600 {
                lines += try child.readLines()
                child.reap()
                if child.finished { return lines }
                usleep(5_000)
            }
            child.signal(SIGKILL)
            child.wait()
            fatalError("fixture child did not finish")
        }
        _ = try drain(disconnect)
        session.connectorHandle = handle
        try session.beginRestore()
        let child = session.children["restore-disconnect"]!
        let lines = try drain(child)
        let arguments = lines.first { $0.hasPrefix("FIXTURE_ARGS ") }!
        if let handle {
            precondition(arguments.hasSuffix(" --expected-handle " + String(format: "%04X", handle)))
        } else {
            precondition(!arguments.contains("--expected-handle"))
        }
        for value in session.children.values { value.closeInput() }
        print("PASS actual session restore-disconnect argument binding handle=\(handle.map(String.init) ?? "none")")
    }
}

extension LDACNativeSession {
    static func preliveStopCheck(_ mode: String, executable: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        SessionClock.shared.set(elapsed: 0)
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        let media = try LDACNativeChild(executable: executable, arguments: ["--prelive-media"], inheritedPCM: nil)
        let capture = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { cleanUp([media, capture]) }
        session.children["media"] = media
        session.children["capture"] = capture
        session.captureStartSent = true
        if mode == "recovering" { session.connectionLost("Fixture transport ended before playback") }
        else { session.stop(restoreAudio: false) }
        try session.advance()
        try require(session.mediaStopSent && !session.captureStopSent,
            "Capture stopped before pre-live media accepted shutdown")
        var receivedStop = false
        try waitUntil {
            for line in try media.readLines() {
                if line == "FIXTURE_STOP_RECEIVED" { receivedStop = true }
                try session.handle("media", line: line)
            }
            return receivedStop
        }
        try session.advance()
        capture.reap()
        try require(capture.status == nil && !session.captureStopSent && !session.hardFailure,
            "Sending stop was confused with the media helper acknowledging it")
        if mode == "missing-ack" {
            SessionClock.shared.set(elapsed: 5)
            try session.advance()
            try waitUntil {
                _ = try media.readLines()
                media.reap()
                return media.finished
            }
            try require(session.hardFailure, "Missing pre-live stop acknowledgment had no bounded failure")
        } else {
            try media.send("ack")
            try waitUntil {
                for line in try media.readLines() { try session.handle("media", line: line) }
                return session.mediaStopReady
            }
        }
        try session.advance()
        try waitUntil { capture.reap(); return capture.status != nil }
        try require(session.captureStopSent && capture.status.map { $0 & 0x7F } == SIGTERM,
            "Capture was not stopped after media accepted its EOF")
        try require(session.hardFailure == (mode == "missing-ack"), "Pre-live cancellation became a hard failure")
    }

    static func captureStartupSignalCheck(_ role: String, signal: Int32, executable: URL) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        try session.launch(role, executable: executable, arguments: [String(signal)])
        let child = session.children[role]!
        defer { cleanUp([child]) }
        child.signal(signal)
        var masked = false
        try waitUntil {
            for line in try child.readLines() { masked = masked || line == "FIXTURE_MASK INT=1 TERM=1" }
            child.reap()
            return masked || child.finished
        }
        try require(masked && child.status == nil, "The capture helper could terminate before installing its signal handlers")
        try child.send("install")
        var handled = false
        try waitUntil {
            for line in try child.readLines() { handled = handled || line == "FIXTURE_HANDLED signal=\(signal)" }
            child.reap()
            return child.finished
        }
        try require(handled && child.exitCode == 0, "The blocked stop signal was not delivered after installing the production handlers")
    }

    static func clockJumpCheck(_ wallOffset: TimeInterval, logURL: URL) throws {
        defer { SessionClock.shared.set(elapsed: nil) }
        SessionClock.shared.set(elapsed: 0)
        let media = try LDACNativeChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], inheritedPCM: nil)
        defer { cleanUp([media]) }
        let stopping = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0,
            priority: LDACPriorityControl(request: { _, _ in }, state: { .init(phase: "idle", error: nil) }), receive: { _ in })
        stopping.children["media"] = media
        stopping.started = true
        stopping.stop(restoreAudio: false)
        try stopping.advance()
        try require(stopping.mediaStopSent && stopping.mediaStopDeadline == SessionClock.shared.monotonic + 5,
            "Media shutdown did not arm its five-second deadline")

        let checking = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { _ in })
        checking.verifyConnectionLoss(reason: "Fixture priority observation")
        try checking.advance()
        try require(checking.priorityObservationDeadline == SessionClock.shared.monotonic + 5 && checking.failure == nil,
            "Priority observation did not start a five-second verification")

        SessionClock.shared.set(elapsed: 4.9, wallOffset: wallOffset)
        try stopping.advance()
        try checking.advance()
        media.reap()
        try require(media.status == nil && stopping.mediaStopDeadline != .distantFuture,
            "A calendar-clock jump ended media before five elapsed seconds")
        try require(checking.failure == nil, "A calendar-clock jump prematurely failed priority verification")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        checking.log = try FileHandle(forWritingTo: logURL)
        checking.record("CLOCK_FIXTURE")
        try checking.log?.close()
        checking.log = nil
        try require(String(contentsOf: logURL, encoding: .utf8).hasPrefix("\(SessionClock.shared.wallTime.timeIntervalSince1970) CLOCK_FIXTURE\n"),
            "Diagnostic timestamps no longer follow calendar time")

        SessionClock.shared.set(elapsed: 5, wallOffset: wallOffset)
        try stopping.advance()
        try checking.advance()
        try waitUntil { media.reap(); return media.status != nil }
        try require(media.status.map { $0 & 0x7F } == SIGKILL && stopping.mediaStopDeadline == .distantFuture,
            "A calendar-clock jump delayed media shutdown beyond five elapsed seconds")
        try require(checking.failure != nil && checking.priorityObservation == nil,
            "A calendar-clock jump delayed priority verification beyond five elapsed seconds")
    }

    @MainActor
    static func failurePresentationCheck(logURL: URL) async throws {
        let raw = "PCM_FAILED helper=probe reason=nonfinite sourceSamples=128"
        for (mode, expected) in [
            ("setup", "LDAC could not start. Try again."),
            ("active", "LDAC playback stopped unexpectedly. Try again."),
            ("stopping", "LDAC did not stop completely."),
            ("restoring", "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings."),
            ("restored", "LDAC did not stop completely."),
            ("restore-preparation", "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings."),
        ] {
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(bundle: .main), gain: 1, receive: { events.values.append($0) })
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            session.log = try FileHandle(forWritingTo: logURL)
            session.active = mode == "active"
            session.requestedStop = mode == "stopping"
            session.restoring = mode == "restoring" || mode == "restored"
            session.nativeAudioRestored = mode == "restored"
            if mode == "restore-preparation" {
                session.requestedStop = true
                session.fail(raw, userMessage: "Bluetooth audio could not be restored. Reconnect the headphones in Bluetooth settings.")
            } else {
                session.fail(raw)
            }
            session.finish()
            try session.log?.close()
            session.log = nil
            for _ in 0..<100 { await Task.yield() }
            let messages = events.values.compactMap { event -> String? in
                switch event {
                case .failed(let message): message
                case .finished(let completion): completion.message
                default: nil
                }
            }
            try require(messages == [expected, expected], "Internal failure reached public events in \(mode): \(messages)")
            let diagnosticFailures = events.values.compactMap { event -> LDACNativeSession.Diagnostic? in
                if case let .diagnostic(value) = event, value.isFailure { return value }
                return nil
            }
            try require(diagnosticFailures.contains { $0.detail == "PCM_FAILED reason=nonfinite" }, "Native failure detail did not reach copyable diagnostics")
            try require(diagnosticFailures.allSatisfy { !$0.detail.contains("sourceSamples") && !$0.detail.contains("helper=probe") }, "Raw helper line reached copyable diagnostics")
            try require(session.failure == raw, "Failure presentation changed internal failure state")
            try require(String(contentsOf: logURL, encoding: .utf8).contains(raw), "Failure detail was lost from diagnostics")
        }
        let events = SessionEvents()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1, receive: { events.values.append($0) })
        session.capturePermissionDenied()
        session.finish()
        for _ in 0..<100 { await Task.yield() }
        let messages = events.values.compactMap { event -> String? in
            switch event {
            case .failed(let message): message
            case .finished(let completion): completion.message
            default: nil
            }
        }
        try require(messages == [LDACAudioCaptureAccess.permissionGuidance, LDACAudioCaptureAccess.permissionGuidance],
            "Permission instructions were replaced by a generic failure")
    }

    @MainActor
    static func targetedPermissionCheck(executable: URL) async throws {
        for (mode, access) in [("allowed", LDACAudioCaptureAccess.ready), ("denied", .permissionRequired),
                               ("bad-exit", nil), ("no-callbacks", nil)] as [(String, LDACAudioCaptureAccess?)] {
            let events = SessionEvents()
            let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
                helpers: Helpers(fixture: executable), gain: 0, outputDeviceUID: "fixture-permission-\(mode)",
                outputSampleRate: .hz48000, capturePermissionMode: .checkOnly, receive: { events.values.append($0) })
            session.start()
            let deadline = DispatchTime.now() + 3
            while DispatchTime.now() < deadline, !events.values.contains(where: { if case .finished = $0 { return true }; return false }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            defer {
                cleanUp(Array(session.children.values))
                if let raw = session.rawURL { try? FileManager.default.removeItem(at: raw.deletingLastPathComponent()) }
            }
            guard case let .finished(completion)? = events.values.last else {
                throw ClosureCheckError(description: "Targeted capture permission check did not finish: \(mode)")
            }
            try require(completion.captureAccess == access && (completion.message == nil) == (access == .ready),
                "Targeted permission check admitted unverified access or lost the denial: \(mode)")
            try require(!session.handoffRequested && session.children.keys.sorted() == ["preflight"],
                "Permission-only check started Bluetooth or changed output: \(mode)")
        }
    }

    @MainActor
    static func captureCancellationCheck(_ mode: String, executable: URL) async throws {
        let events = SessionEvents()
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 0, receive: { events.values.append($0) })
        let preflight = mode.hasPrefix("permission-")
        let recovering = mode == "capture-recovery"
        let clean = ["permission-term", "permission-int", "capture-cancel", "capture-recovery"].contains(mode)
        if recovering { session.connectionLost("Fixture connection closed before playback") }
        else { session.stop(restoreAudio: false) }
        let signal = mode == "permission-int" ? SIGINT : mode == "permission-unknown-signal" ? 1 : SIGTERM
        let cleanup = mode == "permission-cleanup-failed" ? 0 : 1
        let error = mode == "permission-capture-failed" ? 5 : 0
        let line: String
        if preflight {
            line = "AUDIO_PERMISSION_FAILED cleanup=\(cleanup) callbacks=0 error=\(error) interrupted=\(signal)"
        } else {
            let destroyed = mode == "capture-no-destruction" ? "DESTROY_TAP status=1" : "DESTROY_TAP status=0"
            let cancelled = mode == "capture-unclassified" ? "CAPTURE error=0 interrupted=15"
                : mode == "capture-cleanup-failed" ? "PCM_CAPTURE_CANCELLED cleanup=0 error=0 interrupted=15"
                : "PCM_CAPTURE_CANCELLED cleanup=1 error=0 interrupted=15"
            line = destroyed + "\n" + cancelled
        }
        let child = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "exit", line, "", "1"], inheritedPCM: nil)
        defer { cleanUp([child]) }
        let name = preflight ? "preflight" : "capture"
        session.children[name] = child
        try waitUntil {
            for line in try child.readLines() { try session.handle(name, line: line) }
            child.reap()
            return child.finished
        }
        try session.advance()
        if session.canRestore { try session.beginRestore() }
        else { session.finish() }
        for _ in 0..<100 { await Task.yield() }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Cancellation did not publish completion: \(mode)")
        }
        try require(session.hardFailure != clean, "Cancellation cleanup was classified incorrectly: \(mode)")
        try require((completion.message == nil) == (clean && !recovering), "Cancellation retained the wrong failure: \(mode)")
        try require(completion.canRetry == recovering, "Clean interrupted capture blocked recovery: \(mode)")
        try require(events.names.contains("failed") != clean, "Cancellation emitted the wrong failure event: \(mode)")
    }

    @MainActor
    private static func lossSession(active: Bool, events: SessionEvents) throws -> LDACNativeSession {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1,
            configuration: LDACConfiguration(quality: .adaptive), receive: { events.values.append($0) })
        session.active = active
        session.started = true
        session.readySent = true
        session.captureReady = true
        session.pcmReady = true
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            var gate = LDACChannelGate()
            try gate.owned("OWNED_OPEN CID=\(cid) outgoingMTU=1000")
            if name == "probe" { session.signalingGate = gate }
            else { session.mediaGate = gate }
        }
        return session
    }

    @MainActor
    static func probeFailureCheck(_ line: String, source: String, active: Bool, stopping: Bool) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: active, events: events)
        if stopping { session.stop(restoreAudio: false) }
        try session.handle(source, line: line)
        let rejected = source == "probe" && !stopping
        let unavailable = line == "LDAC_UNAVAILABLE rate=48000 channels=2"
        let recoverable = rejected && active && !unavailable
        try require((session.failure != nil) == rejected, "Probe diagnostic did not immediately set failure for its live owner")
        try require(session.shouldStop == (rejected || stopping), "Probe diagnostic did not revoke live ownership")
        try require(session.recoverableFailure == recoverable && session.recoveryRequested == recoverable,
            "Probe recovery classification did not match admitted playback")
        try require(session.hardFailure == (rejected && !recoverable), "Probe setup failure was not distinct from active connection loss")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent && !session.finalized,
            "Probe diagnostic bypassed orderly protocol cleanup")
        if rejected {
            let message = unavailable ? "The headphones did not offer a compatible LDAC stream. Check their audio settings, then retry."
                : active ? "The LDAC Bluetooth connection ended."
                : "The LDAC audio connection could not finish setup. Try LDAC again."
            try require(session.failure == message, "Probe failure did not use the intended user-facing explanation")
            try session.handle("probe", line: "PEER_COMMAND_UNSUPPORTED")
            try session.handle("probe", line: "CONTROL_FAILED expected=media-finished closed=0")
            try session.handle("probe", line: "PREPARE_MEDIA")
            try session.handle("probe", line: "START_ACCEPTED signalingCID=0040 mediaCID=0041")
            if !active {
                try session.handle("media", line: "LIVE_SENT packets=1 rate=48000 channels=2 bitrateKbps=330 eqmid=2")
            }
            try session.handle("media", line: "LIVE_FORMAT rate=48000 channels=2 bitrateKbps=330 frameBytes=110")
            try session.advance()
            try require(session.children.isEmpty && !session.mediaCloseRequired && !session.finalized,
                "Late readiness restarted helpers or bypassed protocol cleanup")
            try session.handle("probe", line: "MEDIA_CLOSE_REQUIRED CID=0041")
            try session.handle("probe", line: "STREAM_CLOSED cleanupSignal=08")
            try require(session.mediaCloseRequired, "Real closure marker did not advance cleanup")
        }
        for _ in 0..<100 { await Task.yield() }
        if unavailable && rejected {
            let message = events.values.compactMap { event -> String? in
                if case .failed(let message) = event { return message }
                return nil
            }.first
            try require(message == session.failure, "LDAC availability instructions were replaced by a generic failure")
        }
        try require(events.names == (rejected ? [recoverable ? "connectionLost" : "failed"] : []),
            "Probe events were missing, duplicated, or reactivated playback: \(events.names)")
    }

    @MainActor
    static func mediaFailureCheck(_ mode: String) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: !["setup", "closed-before-active"].contains(mode), events: events)
        if mode == "stopping" { session.stop(restoreAudio: false) }
        let closed = "FEED_COMPLETE result=5 strictPass=0 sentPackets=1 drainedPackets=1 closed=1"
        let callback = "OWNED_CLOSED CID=0041"
        let encoder = "ENCODER_FAILED reason=packet-boundary bytes=700 outgoingMTU=679 baseline=1000"
        var lines: [(String, String)]
        switch mode {
        case "media-first": lines = [("media", closed), ("media", callback)]
        case "callback-first": lines = [("media", callback), ("media", closed)]
        case "callback-then-encoder": lines = [("media", callback), ("media", encoder), ("media", closed)]
        case "closed-before-active": lines = [("media", closed)]
        case "encoder-first": lines = [("media", encoder), ("media", closed), ("media", callback)]
        case "closure-first": lines = [("media", closed), ("media", encoder), ("media", callback)]
        case "pcm-error": lines = [("media", "PCM_FAILED reason=nonfinite sourceSamples=128 gain=1"), ("media", closed)]
        case "open-error": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 sentPackets=1 closed=0")]
        case "unknown-error": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 sentPackets=1")]
        case "setup": lines = [("media", "FEED_COMPLETE result=5 strictPass=0 reason=invalid-start-or-prefill sentPackets=0")]
        case "stopping": lines = [("media", "FEED_COMPLETE result=0 strictPass=1 sentPackets=1 closed=0")]
        default: throw ClosureCheckError(description: "Unknown media fixture")
        }
        for (source, line) in lines {
            do { try session.handle(source, line: line) }
            catch { session.fail(error.localizedDescription) }
            if line == encoder { try require(session.hardFailure, "Encoder diagnostic did not immediately retain hard failure") }
        }
        let recoverable = ["media-first", "callback-first", "closure-first", "callback-then-encoder"].contains(mode)
        let hard = !["media-first", "callback-first", "stopping"].contains(mode)
        try require(session.feedFinished && session.shouldStop, "Media completion did not enter shutdown")
        try require(session.recoverableFailure == recoverable && session.hardFailure == hard,
            "Media closure/error classification depended on child output order: \(mode)")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent, "Media diagnostic bypassed signaling cleanup")
        if recoverable {
            try session.handle("media", line: closed)
        }
        for _ in 0..<100 { await Task.yield() }
        let expected = mode == "stopping" ? [] : ["closure-first", "callback-then-encoder"].contains(mode) ? ["connectionLost", "failed"]
            : [hard ? "failed" : "connectionLost"]
        try require(events.names == expected, "Media failure emitted incorrect or repeated events: \(events.names)")
    }

    @MainActor
    static func recoveryExitCheck(_ mode: String, executable: URL, raw: URL) async throws {
        let events = SessionEvents()
        let session = try lossSession(active: mode != "unclassified" && mode != "requested-stop-before-active", events: events)
        session.rawURL = raw
        if mode == "unclassified" || mode.hasPrefix("requested-stop") { session.stop(restoreAudio: false) }
        else { try session.handle("probe", line: "STREAM_CLOSED peerSignal=08") }
        if mode == "requested-stop-before-active" {
            try session.handle("probe", line: "STOP_COMPLETE protocolCleanup=1")
        }
        session.originalConnectionEnded = mode == "acl-first"
        if mode == "restore-disconnected" || mode == "forced-disconnect" || mode == "native-replaced" {
            try session.handle("restore-disconnect", line: "BEFORE time=1791160325.072411 address=02-00-00-00-00-01 paired=1 connected=\(mode == "forced-disconnect" ? 1 : 0)")
            try session.handle("restore-disconnect", line: "RESTORE_DISCONNECTED disconnected=1")
        }
        session.nativeAudioRestored = mode == "native-replaced"
        if mode == "encoder-error" || mode == "requested-stop-encoder-error" {
            try session.handle("media", line: "ENCODER_FAILED reason=packet-boundary")
        }
        if mode.hasPrefix("requested-stop-cleanup") {
            session.priorityCleanupFailed("Target publication was lost; confirm the old Bluetooth connection is disconnected.")
            if mode == "requested-stop-cleanup-recovered" { session.priorityPhase = .removed }
        }
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            if !["missing-closure", "requested-stop-missing-closure"].contains(mode) || name != "media" {
                try session.handle(name, line: "OWNED_CLOSED CID=\(cid)")
            }
            session.children[name] = try LDACNativeChild(executable: executable,
                arguments: ["--fixture", "exit", "FIXTURE_EXIT", "", mode == "unexpected-exit" && name == "probe" ? "6" : "5"],
                inheritedPCM: nil)
        }
        defer { cleanUp(Array(session.children.values)) }
        try waitUntil {
            for (name, child) in session.children {
                for line in try child.readLines() { try session.handle(name, line: line) }
                child.reap()
            }
            return session.children.values.allSatisfy(\.finished)
        }
        try require(session.canRestore, "Recovery did not wait for transport children to finish")
        try session.beginRestore()
        for _ in 0..<100 { await Task.yield() }
        guard case let .finished(completion)? = events.values.last else {
            throw ClosureCheckError(description: "Recovery did not publish its completion")
        }
        let safe = ["channels-first", "acl-first", "restore-disconnected", "forced-disconnect"].contains(mode)
        let clean = safe || ["requested-stop", "requested-stop-before-active", "requested-stop-cleanup-recovered", "native-replaced"].contains(mode)
        try require(completion.canRetry == safe, "Recovery accepted an unsafe exit or rejected verified closure: \(mode)")
        try require(completion.requiresAttention == !safe, "Recovery reported the wrong attention requirement: \(mode)")
        try require(completion.targetDisconnected == ["acl-first", "restore-disconnected", "forced-disconnect"].contains(mode),
            "Channel closure was confused with confirmed target disconnection: \(mode)")
        try require(completion.waitForReconnect == ["acl-first", "restore-disconnected"].contains(mode),
            "A deliberate recovery disconnection was confused with an unavailable peer: \(mode)")
        try require(events.names.filter { $0 == "failed" }.isEmpty == clean,
            "Expected connection loss was promoted to a transport error: \(mode)")
        if clean && mode.hasPrefix("requested-stop") {
            try require(completion.message == nil, "Confirmed requested shutdown retained a transient cleanup warning")
        }
    }

    static func closureCheck(_ site: String, mode: String, fault: String, executable: URL, raw: URL) throws {
        let session = LDACNativeSession(id: UUID(), address: "02:00:00:00:00:01",
            helpers: Helpers(bundle: .main), gain: 1, receive: { _ in })
        session.stop(restoreAudio: false)
        session.signalingStopSent = true
        session.mediaCloseSent = true
        session.mediaStopSent = true
        session.rawURL = raw
        for (name, cid) in [("probe", "0040"), ("media", "0041")] {
            var gate = LDACChannelGate()
            try gate.owned("OWNED_OPEN CID=\(cid) outgoingMTU=672")
            if fault != "missing-closure" || name != (site == "media-transport" ? "media" : "probe") {
                try gate.owned("OWNED_CLOSED CID=\(cid)")
            }
            if name == "probe" { session.signalingGate = gate }
            else { session.mediaGate = gate }
        }
        let name = site == "media-transport" ? "media" : "probe"
        let other = name == "media" ? "probe" : "media"
        let command = site == "media-closed" ? "media-closed" : "transport-closed"
        let waiting = site == "media-closed" ? "WAIT_MEDIA_CLOSED" : "WAIT_TRANSPORT_CLOSED CID=\(name == "media" ? "0041" : "0040")"
        var control: [Int32] = [-1, -1]
        if mode == "broken" {
            try require(pipe(&control) == 0, "Control pipe could not be created")
        }
        defer {
            for descriptor in control where descriptor >= 0 { Darwin.close(descriptor) }
        }
        let child = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", mode, waiting, command, fault == "failed-exit" ? "5" : "0"],
            inheritedPCM: mode == "broken" ? control[0] : nil)
        defer { cleanUp([child]) }
        if control[0] >= 0 { Darwin.close(control[0]); control[0] = -1 }
        let companion = try LDACNativeChild(executable: executable,
            arguments: ["--fixture", "exit", "FIXTURE_EXIT", "", "0"], inheritedPCM: nil)
        defer { cleanUp([companion]) }
        session.children[name] = child
        session.children[other] = companion
        var sawWaiting = false
        func drain() throws {
            for (helper, process) in [(name, child), (other, companion)] {
                for line in try process.readLines() {
                    if helper == name && line == waiting { sawWaiting = true }
                    try session.handle(helper, line: line)
                }
                process.reap()
            }
        }
        try waitUntil {
            try drain()
            return sawWaiting && companion.finished && (mode != "exit" || child.finished)
        }
        if fault == "missing-recipient" || fault == "bad-descriptor" {
            if fault == "missing-recipient" { session.children.removeValue(forKey: name) }
            else { child.closeInput() }
            var rejected = false
            do { try session.advance() }
            catch {
                rejected = true
                if fault == "bad-descriptor" {
                    try require((error as? POSIXError)?.code == .EBADF, "Terminal write did not preserve EBADF")
                } else {
                    try require(error is LDACSessionError, "Missing recipient did not report a session error")
                }
            }
            try require(rejected, "Terminal acknowledgment accepted \(fault)")
            return
        }
        if fault == "nonterminal" {
            var rejected = false
            do { try session.send(name, "stop") }
            catch {
                rejected = true
                if mode == "broken" {
                    try require((error as? POSIXError)?.code == .EPIPE, "Nonterminal write did not report EPIPE")
                }
            }
            try require(rejected, "Nonterminal send accepted a closed helper input")
            return
        }
        if fault == "hung" { session.ownerExitDeadline = DispatchTime(uptimeNanoseconds: 0) }
        do { try session.advance() }
        catch { session.fail(error.localizedDescription) }
        if fault == "hung" {
            try require(session.hardFailure && session.ownerInputsClosed && !session.canRestore,
                "Shutdown deadline did not reject a live owner")
        } else {
            try require(session.failure == nil && !session.hardFailure,
                "Terminal acknowledgment failed: \(session.failure ?? "unknown")")
        }
        if fault == "none" {
            let sent = session.mediaClosedSent
            try require(sent == (mode == "read"), "Terminal acknowledgment delivery was recorded incorrectly")
        }
        if mode == "broken" {
            child.reap()
            try require(child.status == nil && !child.finished && !session.canRestore,
                "Broken input was treated as a completed child exit")
            var release: UInt8 = 1
            try require(Darwin.write(control[1], &release, 1) == 1, "Fixture could not be released")
            try waitUntil {
                child.reap()
                return child.status != nil
            }
            try require(!child.outputEnded && !session.canRestore,
                "A reaped child bypassed its output EOF requirement")
        }
        try waitUntil {
            try drain()
            return child.finished && companion.finished
        }
        try require(session.canRestore, "Exited children did not reach shutdown verification")
        try session.beginRestore()
        try require(session.finalized, "Shutdown verification did not finish")
        if ["missing-closure", "failed-exit", "hung"].contains(fault) {
            try require(session.failure != nil && session.hardFailure,
                "Shutdown verification accepted \(fault)")
            if fault == "missing-closure" {
                try require(session.shutdownUnverified, "Missing channel closure was not recorded")
            }
        } else {
            try require(session.failure == nil && !session.hardFailure && !session.shutdownUnverified,
                "Verified shutdown was rejected: \(session.failure ?? "unknown")")
        }
    }
}

@main
enum LDACSessionClosureCheck {
    static func child() -> Never {
        let arguments = CommandLine.arguments
        let mode = arguments[2]
        if mode == "broken" { Darwin.close(STDIN_FILENO) }
        let data = Data((arguments[3] + "\n").utf8)
        let sent = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, data.count) }
        if sent != data.count { exit(90) }
        if mode == "broken" {
            var release: UInt8 = 0
            if Darwin.read(3, &release, 1) != 1 { exit(91) }
        } else if mode == "read" {
            if readLine() != arguments[4] { exit(92) }
        }
        exit(Int32(arguments[5])!)
    }

    static func helperFixture() -> Bool {
        func output(_ line: String) { print(line); fflush(stdout) }
        func pcm(_ frames: Int, tag: UInt8, writing: Bool) {
            var bytes = [UInt8](repeating: tag, count: 4096)
            var remaining = frames * 8
            while remaining > 0 {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    if writing { return Darwin.write(3, buffer.baseAddress, min(remaining, buffer.count)) }
                    return Darwin.read(3, buffer.baseAddress, min(remaining, buffer.count))
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0, writing || bytes.prefix(count).allSatisfy({ $0 == tag }) else { exit(93) }
                remaining -= count
            }
        }
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return false }
        let barrier = ProcessInfo.processInfo.environment["ACOUPLET_FIXTURE_CAPTURE_BARRIER"].map { URL(fileURLWithPath: $0) }
        let native = ProcessInfo.processInfo.environment["ACOUPLET_NATIVE_CLOCK_FIXTURE"]
        let nativeBarrier = ProcessInfo.processInfo.environment["ACOUPLET_NATIVE_CLOCK_BARRIER"].map { URL(fileURLWithPath: $0) }
        func clockMarker(_ name: String) {
            guard let nativeBarrier else { exit(91) }
            do { try Data().write(to: nativeBarrier.appendingPathComponent(name)) }
            catch { exit(91) }
        }
        func waitClockMarker(_ name: String) {
            guard let nativeBarrier else { exit(91) }
            do { try waitUntil { FileManager.default.fileExists(atPath: nativeBarrier.appendingPathComponent(name).path) } }
            catch { output("FIXTURE_CLOCK_MARKER_TIMEOUT \(name)"); exit(91) }
        }
        let warmExit = ProcessInfo.processInfo.environment["ACOUPLET_FIXTURE_WARM_EXIT"]
        func terminateCapture() {
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, SIGTERM)
            var received: Int32 = 0
            guard sigwait(&mask, &received) == 0, received == SIGTERM else { exit(91) }
        }
        switch arguments[1] {
        case "--check-permission":
            if arguments.contains(where: { $0.hasPrefix("fixture-permission-") }) {
                guard arguments.suffix(2) == ["--device-rate", "48000"], arguments.contains("--device-uid") else { exit(92) }
                if arguments.contains("fixture-permission-denied") {
                    output("AUDIO_PERMISSION_DENIED operation=start status=560492391 cleanup=1")
                    exit(1)
                }
                if arguments.contains("fixture-permission-no-callbacks") {
                    output("AUDIO_PERMISSION_ALLOWED cleanup=1 callbacks=0")
                    return true
                }
            }
            output("AUDIO_PERMISSION_ALLOWED cleanup=1 callbacks=1")
            if arguments.contains("fixture-permission-bad-exit") { exit(1) }
        case "--playback-disconnected":
            output("SIGNALING_ARMED time_ns=\(clock_gettime_nsec_np(CLOCK_MONOTONIC))")
            guard readLine()?.hasPrefix("acquire ") == true else { exit(81) }
            output("OWNED_OPEN CID=0040 outgoingMTU=1000")
            output("PREPARE_MEDIA")
            guard readLine() == "media-prepared" else { exit(82) }
            output("OPEN_ACCEPTED")
            let readiness = readLine()
            guard readiness == "media-ready 41 1000" || readiness == "stop" else { exit(83) }
            if readiness == "media-ready 41 1000" { output("START_ACCEPTED") }
            var command = readiness == "stop" ? readiness : readLine()
            if command == "park" {
                if warmExit != "peer-close-before-suspend" {
                    output(warmExit == "suspend-cid" ? "PARK_SUSPENDED signalingCID=0040 mediaCID=0042" : "PARK_SUSPENDED signalingCID=0040 mediaCID=0041")
                }
                if ["peer-close", "peer-abort", "peer-close-before-suspend"].contains(warmExit ?? "") {
                    output(warmExit == "peer-abort" ? "STREAM_CLOSED peerSignal=0A" : "STREAM_CLOSED peerSignal=08")
                    output("MEDIA_CLOSE_REQUIRED")
                    output("WAIT_MEDIA_CLOSED")
                    guard readLine() == "media-closed" else { exit(85) }
                    output("OWNED_CLOSED CID=0040")
                    return true
                }
                command = readLine()
                if command == "resume" {
                    output(warmExit == "start-cid" ? "PARK_START_ACCEPTED rate=48000 signalingCID=0040 mediaCID=0042"
                        : "PARK_START_ACCEPTED rate=48000 signalingCID=0040 mediaCID=0041")
                    if ["overlap", "overlap-stop"].contains(warmExit ?? ""), let barrier {
                        do { try Data().write(to: barrier.appendingPathComponent("warm-start-accepted")) }
                        catch { exit(84) }
                    }
                    command = readLine()
                }
            }
            if let native, command == "rate 96000" {
                if native == "timing" || native == "staging-timing" { usleep(140_000) }
                switch native {
                case "staged-before-peer", "staged-denial", "staged-partial", "staged-stop": waitClockMarker("tap-prepared")
                case "staged-denial-during-tap": waitClockMarker("tap-preparing")
                case "staged-denial-before-media": waitClockMarker("media-preparing")
                case "staged-failed-capture": waitClockMarker("tap-replacement-failed")
                default: break
                }
                let refused = ["peer-rejected-suspend", "peer-rejected-config", "reverse-refused", "staged-denial", "staged-denial-during-tap", "staged-denial-before-media", "staged-partial"].contains(native)
                if refused {
                    output("RATE_SELECTED rate=48000 suspended=\(native == "peer-rejected-suspend" ? 0 : 1) rejected=1")
                    if native == "staged-denial-before-media" || native == "staged-denial-during-tap" {
                        clockMarker("peer-denied")
                    }
                } else if native != "staged-stop" {
                    output("RATE_SELECTED rate=96000 suspended=1 rejected=0")
                }
                switch native {
                case "hal-rejection", "tap-rejection", "staged-failed-capture":
                    guard readLine() == "rollback" else { exit(84) }
                    output("RATE_ROLLBACK rate=48000")
                case "peer-rollback":
                    guard readLine() == "resume" else { exit(84) }
                    output("RATE_ROLLBACK rate=48000")
                case "start-failure", "empty-after-ready":
                    guard readLine() == "resume" else { exit(84) }
                    output("RATE_START_ACCEPTED rate=96000 signalingCID=0040 mediaCID=0041")
                    guard readLine() == "rate 48000" else { exit(84) }
                    output("RATE_SELECTED rate=48000 suspended=1 rejected=0")
                case "partial-after-ready":
                    guard readLine() == "resume" else { exit(84) }
                    output("RATE_START_ACCEPTED rate=96000 signalingCID=0040 mediaCID=0041")
                    guard readLine() == "stop" else { exit(84) }
                    command = "stop"
                case "hal-timeout", "park-during-rate", "stop-during-clock", "reverse-refused", "staged-partial", "staged-stop":
                    guard readLine() == "stop" else { exit(84) }
                    command = "stop"
                case "peer-rejected-suspend", "peer-rejected-config", "staged-denial", "staged-denial-during-tap", "staged-denial-before-media":
                    break
                default:
                    guard readLine() == "resume" else { exit(84) }
                    output("RATE_START_ACCEPTED rate=96000 signalingCID=0040 mediaCID=0041")
                    guard readLine() == "rate 48000" else { exit(84) }
                    if native == "timing" || native == "staging-timing" { usleep(140_000) }
                    output("RATE_SELECTED rate=48000 suspended=1 rejected=0")
                }
                if !["hal-timeout", "partial-after-ready", "park-during-rate", "stop-during-clock", "reverse-refused", "staged-partial", "staged-stop"].contains(native) {
                    if native != "peer-rejected-suspend" {
                        guard readLine() == "resume" else { exit(84) }
                        output("RATE_START_ACCEPTED rate=48000 signalingCID=0040 mediaCID=0041")
                    }
                    command = readLine()
                }
            } else if command == "rate 96000" {
                output("RATE_SELECTED rate=96000 suspended=1 rejected=0")
                guard readLine() == "resume" else { exit(84) }
                output("RATE_START_ACCEPTED rate=96000 signalingCID=0040 mediaCID=0041")
                guard readLine() == "rate 88200" else { exit(84) }
                output("RATE_SELECTED rate=88200 suspended=1 rejected=0")
                guard readLine() == "resume" else { exit(84) }
                output("RATE_ROLLBACK rate=96000")
                guard readLine() == "resume" else { exit(84) }
                output("RATE_START_ACCEPTED rate=96000 signalingCID=0040 mediaCID=0041")
                command = readLine()
            }
            guard command == "media-finished" || command == "stop" else { exit(84) }
            output("MEDIA_CLOSE_REQUIRED")
            output("WAIT_MEDIA_CLOSED")
            guard readLine() == "media-closed" else { exit(85) }
            output("STOP_COMPLETE protocolCleanup=1")
            output("OWNED_CLOSED CID=0040")
        case "--media":
            output("MEDIA_PREPARED")
            let opening = readLine()
            if opening == "close" { return true }
            guard opening == "open" else { exit(86) }
            output("OWNED_OPEN CID=0041 outgoingMTU=1000")
            if let barrier {
                let prepared = barrier.appendingPathComponent("capture-prepared")
                do { try waitUntil { FileManager.default.fileExists(atPath: prepared.path) } }
                catch { output("FIXTURE_CAPTURE_WARMUP_TIMEOUT"); exit(86) }
            }
            let fault = ProcessInfo.processInfo.environment["ACOUPLET_FIXTURE_MEDIA_READY_FAULT"]
            let cid = fault == "cid" ? "0042" : "0041"
            let mtu = fault == "mtu" ? 1001 : 1000
            let rate = fault == "format" ? 44100 : 48000
            output("READY CID=\(cid) outgoingMTU=\(mtu) socketFD=3 PSM=0019 rate=\(rate) channels=2 bitrateKbps=330 eqmid=2")
            if fault != nil {
                guard readLine() == "close" else { exit(86) }
                output("OWNED_CLOSED CID=0041")
                return true
            }
            pcm(RateFixture.firstFrames, tag: 1, writing: false)
            output("PCM_READY frames=12000 rate=48000 channels=2 format=F32 bufferedFrames=\(RateFixture.firstFrames)")
            guard readLine() == "start live 0.25 0" else { exit(87) }
            output("LIVE_SENT packets=1 rate=48000 channels=2 bitrateKbps=330 eqmid=2")
            var gain = readLine()
            if gain == "park" {
                output("PARK_MEDIA_PAUSED CID=0041 packets=1")
                gain = readLine()
                if gain == "warm-prefill" {
                    output("PARK_MEDIA_PREFILL_PREPARED rate=48000")
                    if warmExit != "overlap-stop" {
                        pcm(RateFixture.firstFrames, tag: 4, writing: false)
                        output("PCM_READY frames=12000 rate=48000 channels=2 format=F32 bufferedFrames=\(RateFixture.firstFrames)")
                    }
                    gain = readLine()
                    if gain == "resume" {
                        output("PARK_MEDIA_DISCARDED bytes=1024")
                        output("PARK_LIVE CID=0041 rate=48000 packets=2")
                        gain = readLine()
                        if gain == "quality high" { gain = readLine() }
                    }
                }
            }
            guard gain == "gain 0.5" || gain == "stop" else { exit(88) }
            if gain == "gain 0.5" { output("GAIN_APPLIED gain=0.5") }
            var command = gain == "stop" ? gain : readLine()
            if let native, command == "drain \(RateFixture.firstWatermark)" {
                if native == "overlap-barrier", let nativeBarrier {
                    do { try waitUntil { FileManager.default.fileExists(atPath: nativeBarrier.appendingPathComponent("clock-issued").path) } }
                    catch { output("FIXTURE_NO_CLOCK_DURING_DRAIN"); exit(89) }
                }
                if native == "timing" || native == "staging-timing" { usleep(200_000) }
                output(RateFixture.firstDrain)
                if ["hal-timeout", "park-during-rate", "stop-during-clock", "reverse-refused"].contains(native) {
                    command = readLine()
                } else {
                    if !["hal-rejection", "peer-rejected-suspend", "peer-rejected-config"].contains(native) {
                        guard readLine() == "rate 96000 high" else { exit(89) }
                        if native == "staged-denial-before-media" {
                            clockMarker("media-preparing")
                            waitClockMarker("peer-denied")
                            usleep(75_000)
                        }
                        output("RATE_PREPARED rate=96000")
                    }
                    if !["partial-after-ready", "staged-partial", "staged-stop"].contains(native) {
                        if ["round-trip", "recreated-round-trip", "timing", "staging-timing", "overlap-barrier", "staged-before-peer"].contains(native) {
                            pcm(RateFixture.secondFrames, tag: 2, writing: false)
                            output("PCM_READY frames=24000 rate=96000 channels=2 format=F32 bufferedFrames=\(RateFixture.secondFrames)")
                            guard readLine() == "resume" else { exit(89) }
                            output("RATE_LIVE rate=96000 channels=2 bitrateKbps=990 eqmid=0")
                            guard readLine() == "drain \(RateFixture.secondWatermark)" else { exit(89) }
                            if native == "timing" || native == "staging-timing" { usleep(200_000) }
                            output(RateFixture.secondDrain)
                        }
                        guard readLine() == "rate 48000 high" else { exit(89) }
                        output("RATE_PREPARED rate=48000")
                        pcm(RateFixture.firstFrames, tag: 3, writing: false)
                        output("PCM_READY frames=12000 rate=48000 channels=2 format=F32 bufferedFrames=\(RateFixture.firstFrames)")
                        guard readLine() == "resume" else { exit(89) }
                        output("RATE_LIVE rate=48000 channels=2 bitrateKbps=990 eqmid=0")
                    }
                    command = readLine()
                }
            } else if command == "drain \(RateFixture.firstWatermark)" {
                output(RateFixture.firstDrain)
                guard readLine() == "rate 96000 high" else { exit(89) }
                output("RATE_PREPARED rate=96000")
                pcm(RateFixture.secondFrames, tag: 2, writing: false)
                output("PCM_READY frames=24000 rate=96000 channels=2 format=F32 bufferedFrames=\(RateFixture.secondFrames)")
                guard readLine() == "resume" else { exit(89) }
                output("RATE_LIVE rate=96000 channels=2 bitrateKbps=990 eqmid=0")
                guard readLine() == "drain \(RateFixture.secondWatermark)" else { exit(89) }
                output(RateFixture.secondDrain)
                guard readLine() == "rate 88200 high" else { exit(89) }
                output("RATE_PREPARED rate=88200")
                guard readLine() == "rate 96000 high" else { exit(89) }
                output("RATE_PREPARED rate=96000")
                pcm(RateFixture.secondFrames, tag: 3, writing: false)
                output("PCM_READY frames=24000 rate=96000 channels=2 format=F32 bufferedFrames=\(RateFixture.secondFrames)")
                guard readLine() == "resume" else { exit(89) }
                output("RATE_LIVE rate=96000 channels=2 bitrateKbps=990 eqmid=0")
                command = readLine()
            }
            guard command == "stop" else { exit(89) }
            output("FEED_COMPLETE result=0")
            guard readLine() == "close" else { exit(90) }
            output("OWNED_CLOSED CID=0041")
        case "--stream" where native != nil:
            guard let marker = arguments.firstIndex(of: "--sample-rate"), var rate = Int(arguments[marker + 1]),
                  arguments.contains("--device-uid"), arguments.contains("--await-start") else { exit(91) }
            var staged = arguments.contains("--native-epoch")
            var reused = false
            while true {
                var prefillBegan: UInt64?
                if staged {
                    if native == "staging-timing" {
                        usleep(75_000)
                        prefillBegan = clock_gettime_nsec_np(CLOCK_MONOTONIC)
                    }
                    if native == "staged-failed-capture", rate == 96000 {
                        output("DESTROY_TAP status=0")
                        output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0")
                        if !reused { clockMarker("tap-replacement-failed") }
                        exit(1)
                    }
                    if rate == 96000 && (native == "tap-rejection" || native == "recreated-round-trip" && reused) {
                        output("DESTROY_TAP status=0")
                        output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0")
                        exit(1)
                    }
                    if reused {
                        output("CLOCK_DESTROY_TAP status=0")
                        output("CLOCK_CREATE_TAP status=0")
                    }
                    if native == "staged-denial-during-tap", rate == 96000 {
                        clockMarker("tap-preparing")
                        waitClockMarker("peer-denied")
                        usleep(75_000)
                    }
                    output("PCM_CAPTURE_CLOCK_PREPARED rate=\(rate)")
                    if ["staged-before-peer", "staged-denial", "staged-partial", "staged-stop"].contains(native), rate == 96000 {
                        clockMarker("tap-prepared")
                    }
                    if ["peer-rollback", "staged-denial", "staged-denial-during-tap", "staged-partial", "staged-stop"].contains(native), rate == 96000 {
                        terminateCapture()
                        if native == "staged-partial" {
                            var word: UInt32 = 7
                            guard Darwin.write(3, &word, 4) == 4 else { exit(91) }
                        }
                        output("DESTROY_TAP status=0")
                        output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=\(native == "staged-partial" ? 4 : 0)")
                        return true
                    }
                } else {
                    output("PCM_CAPTURE_SOURCE rate=\(rate)")
                    output("PCM_CAPTURE_PREPARED rate=\(rate)")
                }
                guard readLine() == "capture" else { exit(91) }
                if let prefillBegan {
                    let elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC) - prefillBegan
                    if elapsed < 250_000_000 { usleep(useconds_t((250_000_000 - elapsed) / 1000)) }
                }
                if native == "start-failure", rate == 96000 {
                    output("DESTROY_TAP status=0")
                    output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0")
                    exit(1)
                }
                if staged { output("PCM_CAPTURE_SOURCE rate=\(rate)") }
                output("PCM_CAPTURE_READY rate=\(rate) channels=2 format=F32 interleaved=1 bytesPerFrame=8")
                if rate == 96000, native == "empty-after-ready" || native == "partial-after-ready" {
                    var word: UInt32 = 7
                    let bytes = native == "partial-after-ready" ? Darwin.write(3, &word, 4) : 0
                    guard bytes == (native == "partial-after-ready" ? 4 : 0) else { exit(91) }
                    output("DESTROY_TAP status=0")
                    output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=\(bytes)")
                    exit(1)
                }
                let frames = rate == 96000 ? RateFixture.secondFrames : RateFixture.firstFrames
                pcm(frames, tag: staged ? rate == 96000 ? 2 : 3 : 1, writing: true)
                if staged, rate == 48000 {
                    terminateCapture()
                    output("DESTROY_TAP status=0")
                    output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=\(frames * 8)")
                    return true
                }
                guard readLine() == "clock-freeze" else { exit(91) }
                output("CAPTURE_FROZEN rate=\(rate) bytes=\(frames * 8) sourceFrames=\(frames)")
                if ["hal-timeout", "park-during-rate", "stop-during-clock", "reverse-refused"].contains(native) {
                    terminateCapture()
                    output("DESTROY_TAP status=0")
                    output("PCM_CAPTURE_CLOCK_CLOSED cleanup=1 bytes=0")
                    return true
                }
                guard let command = readLine(), command.hasPrefix("clock-rate "),
                      let next = Int(command.dropFirst(11)), next == 48000 || next == 96000 else { exit(91) }
                staged = true
                reused = true
                rate = next
            }
        case "--stream":
            let liveRates = arguments.contains("fixture-live-rate")
            guard arguments.contains("--await-start"), arguments.suffix(2) == ["--device-rate", "48000"] else { exit(91) }
            output("PCM_CAPTURE_PREPARED rate=48000")
            output("PCM_CAPTURE_SOURCE rate=48000")
            if let barrier {
                do { try Data().write(to: barrier.appendingPathComponent("capture-prepared")) }
                catch { exit(91) }
            }
            var ready = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            while true {
                var pending = sigset_t()
                guard sigpending(&pending) == 0 else { exit(91) }
                if sigismember(&pending, SIGTERM) == 1 {
                    output("DESTROY_TAP status=0")
                    output("PCM_CAPTURE_CANCELLED cleanup=1 error=0 interrupted=\(SIGTERM)")
                    exit(1)
                }
                let result = poll(&ready, 1, 25)
                if result < 0 && errno != EINTR { exit(91) }
                if result > 0 {
                    guard readLine() == "capture" else { exit(91) }
                    break
                }
            }
            output("PCM_CAPTURE_READY rate=48000 channels=2 format=F32 interleaved=1 bytesPerFrame=8")
            pcm(RateFixture.firstFrames, tag: 1, writing: true)
            if liveRates {
                for (freeze, tag) in [(RateFixture.firstFreeze, UInt8(2)), (RateFixture.secondFreeze, UInt8(3))] {
                    guard readLine() == "freeze" else { exit(91) }
                    output(freeze)
                    guard readLine() == "rate 96000" else { exit(91) }
                    output("PCM_CAPTURE_RESUMED rate=96000")
                    pcm(RateFixture.secondFrames, tag: tag, writing: true)
                }
            }
            if arguments.contains("fixture-warm-hold") {
                guard readLine() == "park" else { exit(91) }
                output("PARK_CAPTURE_PAUSED rate=48000")
                if ["", "long-hold", "start-cid", "stop-prefill", "authorization-timeout", "queued-configuration", "overlap", "overlap-stop"].contains(warmExit ?? "") {
                    guard readLine() == "warm-resume" else { exit(91) }
                    output("PARK_CAPTURE_RESUMED rate=48000 discardedFrames=1024")
                    if warmExit == "overlap", let barrier {
                        do { try waitUntil { FileManager.default.fileExists(atPath: barrier.appendingPathComponent("warm-start-accepted").path) } }
                        catch { exit(91) }
                    }
                    if warmExit != "overlap-stop" { pcm(RateFixture.firstFrames, tag: 4, writing: true) }
                }
            }
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, SIGTERM)
            var received: Int32 = 0
            guard sigwait(&mask, &received) == 0, received == SIGTERM else { exit(91) }
            output("DESTROY_TAP status=0")
        case "--address" where arguments.contains("--watch-parent"):
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            output("ACL_CONNECTED baseline_ns=\(now - 1) connected_ns=\(now)")
            usleep(100_000)
            output("CONNECT_READY handle=0001 guarded=1")
            guard readLine() == "disarm" else { exit(92) }
            output("CONNECT_DISARMED explicit=1 connected=1")
        default: return false
        }
        return true
    }

    @MainActor
    static func main() async throws {
        if helperFixture() { return }
        if CommandLine.arguments.dropFirst().first == "--address" || CommandLine.arguments.dropFirst().first == "fixture-disconnect" {
            print("FIXTURE_ARGS " + CommandLine.arguments.dropFirst().joined(separator: " "))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--prelive-media" {
            guard readLine() == "stop" else { exit(93) }
            print("FIXTURE_STOP_RECEIVED")
            fflush(stdout)
            guard readLine() == "ack" else { exit(94) }
            print("PCM_STOP_READY started=0")
            fflush(stdout)
            _ = readLine()
            exit(0)
        }
        if CommandLine.arguments.dropFirst().first == "--fixture" { child() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        if CommandLine.arguments.count > 2 {
            for mode in CommandLine.arguments.dropFirst(2) {
                if mode == "stop-before-queued-clock" { try await LDACNativeSession.stopBeforeQueuedClockCheck() }
                else { try await LDACNativeSession.nativeClockPlaybackCheck(executable: executable, mode: mode) }
            }
            return
        }
        try LDACNativeSession.priorityPreparationCheck(executable: executable)
        try LDACNativeSession.priorityActivationFailureCheck(executable: executable)
        try LDACNativeSession.acquisitionCheck(executable: executable)
        try LDACNativeSession.earlyMediaPreparationCheck(executable: executable, cancelled: true)
        try LDACNativeSession.earlyMediaPreparationCheck(executable: executable, cancelled: false)
        print("PASS unopened capture and media helpers clean up after cancellation or connector failure")
        try await LDACNativeSession.logfreePlaybackCheck(executable: executable, priorityAvailable: true)
        try await LDACNativeSession.logfreePlaybackCheck(executable: executable, priorityAvailable: false, capturePermissionMode: .verified)
        try await LDACNativeSession.logfreePlaybackCheck(executable: executable, priorityAvailable: true, liveRates: true)
        try await LDACNativeSession.logfreePlaybackCheck(executable: executable, priorityAvailable: true, warmHold: true)
        for exit in ["long-hold", "stop", "stop-prefill", "suspend-cid", "start-cid", "peer-close", "peer-abort", "peer-close-before-suspend", "authorization-timeout", "queued-configuration", "overlap", "overlap-stop"] {
            try await LDACNativeSession.logfreePlaybackCheck(executable: executable, priorityAvailable: true, warmHold: true, warmExit: exit)
        }
        print("PASS warm hold preserves both CIDs through idle and explicit START authorization; peer exit, STOP, stale authorization and invalid CIDs fail closed")
        for fault in ["cid", "mtu", "format"] {
            try await LDACNativeSession.logfreePlaybackCheck(executable: executable, priorityAvailable: true, mediaReadyFault: fault)
        }
        print("PASS capture warms before media readiness and produces audio only after the owned channel and format are verified")
        print("PASS live rate selection and rejection preserve the same capture and owned channels")
        for mode in ["round-trip", "recreated-round-trip", "hal-rejection", "peer-rollback", "tap-rejection", "start-failure", "empty-after-ready", "partial-after-ready", "hal-timeout", "park-during-rate", "stop-during-clock", "overlap-barrier",
                     "peer-rejected-suspend", "peer-rejected-config", "reverse-refused", "staged-before-peer", "staged-denial",
                     "staged-denial-during-tap", "staged-denial-before-media", "staged-partial", "staged-failed-capture", "staged-stop"] {
            try await LDACNativeSession.nativeClockPlaybackCheck(executable: executable, mode: mode)
        }
        try await LDACNativeSession.stopBeforeQueuedClockCheck()
        print("PASS log-free acquisition, deferred media, live capture, gain, priority and owned shutdown")
        for handle in [nil, 0, 1] as [Int?] {
            try LDACNativeSession.checkRestoreArguments(executable: executable, handle: handle)
        }
        try await LDACNativeSession.ordinaryAudioRestorationPolicyCheck(executable: executable)
        for failure in 1...3 {
            PipeSetupCheck.failureCall = failure
            PipeSetupCheck.calls = 0
            PipeSetupCheck.spawnAttempts = 0
            var rejected = false
            do {
                let child = try LDACNativeChild(executable: executable,
                    arguments: ["--fixture", "exit", "UNEXPECTED_CHILD", "", "0"], inheritedPCM: nil)
                cleanUp([child])
            } catch let error as POSIXError {
                rejected = true
                try require(error.code == .EPERM, "Pipe setup did not preserve its failure")
            }
            try require(rejected && PipeSetupCheck.spawnAttempts == 0,
                "Failed pipe setup launched a helper")
            try require(PipeSetupCheck.descriptors.count == 4, "Pipe setup did not capture every descriptor")
            for descriptor in PipeSetupCheck.descriptors {
                try require(Darwin.fcntl(descriptor, F_GETFD) == -1 && errno == EBADF,
                    "Failed pipe setup leaked a descriptor")
            }
            print("PASS pipe setup failure=\(failure): descriptors closed without spawning a helper")
        }
        PipeSetupCheck.failureCall = 0
        let raw = executable.deletingLastPathComponent().appendingPathComponent("signaling.bin")
        try Data().write(to: raw)
        try LDACNativeSession.finishChildrenCheck(executable: executable)
        for role in ["preflight", "capture"] {
            for signal in [SIGINT, SIGTERM] {
                try LDACNativeSession.captureStartupSignalCheck(role, signal: signal,
                    executable: URL(fileURLWithPath: CommandLine.arguments[1]))
                print("PASS capture startup signal role=\(role) signal=\(signal)")
            }
        }
        for mode in ["stopping", "recovering", "missing-ack"] {
            try LDACNativeSession.preliveStopCheck(mode, executable: executable)
            print("PASS pre-live capture stop ordering mode=\(mode)")
        }
        for offset: TimeInterval in [-86_400, 86_400] {
            try LDACNativeSession.clockJumpCheck(offset, logURL: raw.deletingLastPathComponent().appendingPathComponent("clock.log"))
            print("PASS clock jump seconds=\(offset): operation and shutdown deadlines use elapsed time; logs retain calendar time")
        }
        try LDACNativeSession.rateTransitionDeadlineCheck(executable: executable)
        print("PASS live rate deadlines: overdue format reports rejected and rollback cannot extend the request")
        try LDACNativeSession.rateTransitionRejectionCheck(executable: executable)
        try await LDACNativeSession.capturePressureDeclineCheck(executable: executable)
        try await LDACNativeSession.sinkRatePreflightCheck(executable: executable)
        print("PASS selected-sink rate preflight: known unsupported rates leave PCM running and preserve quality changes; unknown capabilities negotiate")
        try await LDACNativeSession.failurePresentationCheck(logURL: raw.deletingLastPathComponent().appendingPathComponent("errors.log"))
        print("PASS LDAC failure presentation preserves diagnostics and actionable permission/availability messages")
        try await LDACNativeSession.targetedPermissionCheck(executable: executable)
        print("PASS permission-only capture accepts a clean callback, rejects failed checks, and never asks for Bluetooth handoff")
        for mode in ["permission-term", "permission-int", "permission-unknown-signal", "permission-cleanup-failed", "permission-capture-failed",
                     "capture-cancel", "capture-recovery", "capture-unclassified", "capture-cleanup-failed", "capture-no-destruction"] {
            try await LDACNativeSession.captureCancellationCheck(mode, executable: executable)
            print("PASS capture cancellation mode=\(mode)")
        }
        var failures = 0
        for site in ["media-closed"] {
            for (mode, fault) in [("exit", "none"), ("broken", "none"), ("read", "none"),
                                  ("exit", "missing-closure"), ("exit", "failed-exit"),
                                  ("broken", "hung"), ("exit", "nonterminal"), ("broken", "nonterminal"),
                                  ("exit", "missing-recipient"), ("broken", "bad-descriptor")] {
                do {
                    try LDACNativeSession.closureCheck(site, mode: mode, fault: fault, executable: executable, raw: raw)
                    print("PASS \(site) mode=\(mode) fault=\(fault)")
                } catch {
                    failures += 1
                    print("FAIL \(site) mode=\(mode) fault=\(fault): \(error)")
                }
            }
        }
        print("Actual LDAC session shutdown checks: \(10 - failures)/10 passed; local fixture children only")
        let closureFailures = failures
        var ownershipChecks = 0
        for line in ["PEER_COMMAND_UNSUPPORTED", "CONTROL_FAILED expected=media-finished closed=0", "LDAC_UNAVAILABLE rate=48000 channels=2"] {
            for source in ["probe", "media", "daemon"] {
                for active in [false, true] {
                    for stopping in [false, true] {
                        ownershipChecks += 1
                        do {
                            try await LDACNativeSession.probeFailureCheck(line, source: source, active: active, stopping: stopping)
                            print("PASS probe diagnostic=\(line) source=\(source) active=\(active) stopping=\(stopping)")
                        } catch {
                            failures += 1
                            print("FAIL probe source=\(source) active=\(active) stopping=\(stopping): \(error)")
                        }
                    }
                }
            }
        }
        for mode in ["media-first", "callback-first", "encoder-first", "closure-first", "callback-then-encoder",
                     "pcm-error", "open-error", "unknown-error", "setup", "closed-before-active", "stopping"] {
            ownershipChecks += 1
            do {
                try await LDACNativeSession.mediaFailureCheck(mode)
                print("PASS media ownership mode=\(mode)")
            } catch {
                failures += 1
                print("FAIL media ownership mode=\(mode): \(error)")
            }
        }
        for mode in ["channels-first", "acl-first", "restore-disconnected", "forced-disconnect", "native-replaced", "unexpected-exit",
                     "missing-closure", "encoder-error", "unclassified", "requested-stop", "requested-stop-before-active",
                     "requested-stop-encoder-error", "requested-stop-missing-closure", "requested-stop-cleanup-recovered",
                     "requested-stop-cleanup-pending"] {
            ownershipChecks += 1
            do {
                try await LDACNativeSession.recoveryExitCheck(mode, executable: executable, raw: raw)
                print("PASS recovery exit mode=\(mode)")
            } catch {
                failures += 1
                print("FAIL recovery exit mode=\(mode): \(error)")
            }
        }
        print("Actual LDAC session ownership checks: \(ownershipChecks - failures + closureFailures)/\(ownershipChecks) passed; protocol input only")
        if failures > 0 { exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="acouplet-ldac-session-closure-") as directory:
    directory = pathlib.Path(directory)
    swift = directory / "Check.swift"
    binary = directory / "check"
    source = source.replace('FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]', 'FileManager.default.temporaryDirectory.appendingPathComponent("acouplet-session-fixture-\\(getpid())")')
    timed_source = source.replace("DispatchTime.now()", "SessionClock.shared.monotonic").replace("Date()", "SessionClock.shared.wallTime")
    timed_source = timed_source.replace("        guard fcntl(incoming[1]", "        PipeSetupCheck.descriptors = incoming + outgoing\n        guard fcntl(incoming[1]")
    timed_source = timed_source.replace("fcntl(", "PipeSetupCheck.configure(")
    timed_source = timed_source.replace("        let result = posix_spawn(", "        PipeSetupCheck.spawnAttempts += 1\n        let result = posix_spawn(")
    swift.write_text(timed_source + fixture)
    capture_source = (pathlib.Path(__file__).parent / "SystemAudioTapProbe.m").read_text()
    handler = capture_source[capture_source.index("static void Interrupt(int value)"):capture_source.index("static double MonotonicTime")]
    unblock = capture_source[capture_source.index("            signal(SIGINT, Interrupt);"):capture_source.index("            if (streaming || checkingPermission) signal(SIGPIPE, SIG_IGN);")]
    signal_source = directory / "Signals.c"
    signal_binary = directory / "signals"
    signal_source.write_text('''#include <signal.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static volatile sig_atomic_t interrupted;
''' + handler + '''int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    sigset_t inherited;
    pthread_sigmask(SIG_BLOCK, NULL, &inherited);
    printf("FIXTURE_MASK INT=%d TERM=%d\\n", sigismember(&inherited, SIGINT), sigismember(&inherited, SIGTERM));
    char command[32];
    if (!fgets(command, sizeof(command), stdin)) return 1;
''' + unblock + '''
    printf("FIXTURE_HANDLED signal=%d\\n", interrupted);
    return argc == 2 && interrupted == atoi(argv[1]) ? 0 : 2;
}
''')
    subprocess.run(["xcrun", "clang", str(signal_source), "-o", str(signal_binary)], check=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(signal_binary), *sys.argv[1:]], check=True)
