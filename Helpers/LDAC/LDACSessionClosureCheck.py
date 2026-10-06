import pathlib
import subprocess
import tempfile


source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/LDACNativeSession.swift").read_text()

fixture = r'''
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
        values.map {
            switch $0 {
            case .connectionLost: "connectionLost"
            case .failed: "failed"
            case .active: "active"
            case .formatChanged: "formatChanged"
            default: "other"
            }
        }
    }
}

extension LDACNativeSession {
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
            try gate.owned("OWNED_CHANNEL CID=\(cid)")
            try gate.daemon("connectedCB cid:0x\(cid) inMTU:1000 outMTU:1000 result:0")
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
        let daemon = "l2capDisconnected for CID: 0x0041"
        let encoder = "ENCODER_FAILED reason=packet-boundary bytes=700 outgoingMTU=679 baseline=1000"
        var lines: [(String, String)]
        switch mode {
        case "media-first": lines = [("media", closed), ("daemon", daemon)]
        case "daemon-first": lines = [("daemon", daemon), ("media", closed)]
        case "daemon-then-encoder": lines = [("daemon", daemon), ("media", encoder), ("media", closed)]
        case "closed-before-active": lines = [("media", closed)]
        case "encoder-first": lines = [("media", encoder), ("media", closed), ("daemon", daemon)]
        case "closure-first": lines = [("media", closed), ("media", encoder), ("daemon", daemon)]
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
        let recoverable = ["media-first", "daemon-first", "closure-first", "daemon-then-encoder"].contains(mode)
        let hard = !["media-first", "daemon-first", "stopping"].contains(mode)
        try require(session.feedFinished && session.shouldStop, "Media completion did not enter shutdown")
        try require(session.recoverableFailure == recoverable && session.hardFailure == hard,
            "Media closure/error classification depended on child output order: \(mode)")
        try require(!session.mediaCloseRequired && !session.mediaCloseSent, "Media diagnostic bypassed signaling cleanup")
        if recoverable {
            try session.handle("media", line: closed)
        }
        for _ in 0..<100 { await Task.yield() }
        let expected = mode == "stopping" ? [] : ["closure-first", "daemon-then-encoder"].contains(mode) ? ["connectionLost", "failed"]
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
                try session.handle("daemon", line: "l2capDisconnected for CID: 0x\(cid)")
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
        let clean = safe || ["requested-stop", "requested-stop-cleanup-recovered", "native-replaced"].contains(mode)
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
            try gate.owned("OWNED_CHANNEL CID=\(cid)")
            try gate.daemon("connectedCB cid:0x\(cid) inMTU:672 outMTU:672 result:0")
            if fault != "missing-closure" || name != (site == "media-transport" ? "media" : "probe") {
                try gate.daemon("l2capDisconnected for CID: 0x\(cid)")
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
        if fault == "hung" { session.ownerExitDeadline = .distantPast }
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
            let sent = site == "media-transport" ? session.mediaTransportClosedSent :
                site == "media-closed" ? session.mediaClosedSent : session.signalingClosedSent
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

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--fixture" { child() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let raw = executable.deletingLastPathComponent().appendingPathComponent("signaling.bin")
        try Data().write(to: raw)
        try await LDACNativeSession.failurePresentationCheck(logURL: raw.deletingLastPathComponent().appendingPathComponent("errors.log"))
        print("PASS LDAC failure presentation preserves diagnostics and actionable permission/availability messages")
        var failures = 0
        for site in ["media-transport", "media-closed", "signaling-transport"] {
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
        print("Actual LDAC session shutdown checks: \(30 - failures)/30 passed; local fixture children only")
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
        for mode in ["media-first", "daemon-first", "encoder-first", "closure-first", "daemon-then-encoder",
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
    swift.write_text(source + fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
