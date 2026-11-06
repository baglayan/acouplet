import Darwin
import Foundation

@main
enum LDACSessionDiagnosticsCheck {
    static let helperEvents: [(source: String, line: String, summary: String, failure: Bool)] = [
        ("probe", "OPEN_INDETERMINATE nil_channel=1 callback_status=0",
         "OPEN_INDETERMINATE callback_status=0 nil_channel=1", true),
        ("probe", "TRANSPORT_CLOSE_UNCONFIRMED CID=0041 closeRequested=1",
         "TRANSPORT_CLOSE_UNCONFIRMED closeRequested=1", true),
        ("probe", "OWNED_CALLBACKS_LOST cleanup=unconfirmed", "OWNED_CALLBACKS_LOST cleanup=unconfirmed", true),
        ("probe", "OPEN_CLEANUP_UNCONFIRMED pending=1 indeterminate=0",
         "OPEN_CLEANUP_UNCONFIRMED pending=1 indeterminate=0", true),
        ("probe", "MEDIA_CLOSE_UNCONFIRMED parentEOF=1 CID=0042", "MEDIA_CLOSE_UNCONFIRMED parentEOF=1", true),
        ("media", "OPEN_INDETERMINATE reason=nil-channel-zero-status",
         "OPEN_INDETERMINATE reason=nil-channel-zero-status", true),
        ("media", "OWNED_CLOSE_UNCONFIRMED CID=0042 openPending=1 openIndeterminate=0 inputEOF=0 parentEOF=1 closeRequested=1",
         "OWNED_CLOSE_UNCONFIRMED closeRequested=1 parentEOF=1 openPending=1 openIndeterminate=0 inputEOF=0", true),
        ("connector", "CONNECT_RETURN time=1793642544.578000 status=0x00000000", "CONNECT_RETURN status=0x00000000", false),
        ("connector", "CONNECTION_CALLBACK time=1793642550.789000 status=0xE00002D6 connected=0",
         "CONNECTION_CALLBACK status=0xE00002D6 connected=0", true),
        ("connector", "AFTER callback=1 status=0xE00002D6 connected=0", "AFTER status=0xE00002D6 callback=1 connected=0", true),
        ("connector", "ACL_OBSERVATION_FAILED reason=callback-without-fresh-acl",
         "ACL_OBSERVATION_FAILED reason=callback-without-fresh-acl", true),
        ("connector", "NATIVE_AUDIO_UNCONFIRMED reason=output-inspection",
         "NATIVE_AUDIO_UNCONFIRMED reason=output-inspection", true),
        ("connector", "CONNECT_CANCEL_CLOSE status=0xE00002BC", "CONNECT_CANCEL_CLOSE status=0xE00002BC", true),
        ("connector", "CONNECT_CANCELED issued=0 settled=1", "CONNECT_CANCELED issued=0 settled=1", false),
        ("connector", "CONNECT_CANCELED callback=0 originalDisconnected=1 retired=1",
         "CONNECT_CANCELED callback=0 originalDisconnected=1 retired=1", false),
        ("connector", "CONNECT_CANCELED callback=1 disconnected=1 settled=1",
         "CONNECT_CANCELED callback=1 disconnected=1 settled=1", false),
        ("connector", "CONNECT_CANCELLATION_UNCONFIRMED callback=0 disconnected=1 closeRequested=0 status=0x00000000",
         "CONNECT_CANCELLATION_UNCONFIRMED status=0x00000000 closeRequested=0 callback=0 disconnected=1", true),
        ("connector", "CONNECT_TERMINAL_UNCONFIRMED callback=0 connected=1",
         "CONNECT_TERMINAL_UNCONFIRMED callback=0 connected=1", true),
        ("connector", "CONNECT_LOCK_UNAVAILABLE canceled=1", "CONNECT_LOCK_UNAVAILABLE canceled=1", false),
        ("connector", "CONNECT_LOCK_UNAVAILABLE canceled=0", "CONNECT_LOCK_UNAVAILABLE canceled=0", true)
    ]

    @MainActor
    static func main() async throws {
        let timing = "serviceMean=0.004000 serviceMax=0.006000 sendMax=0.000020 waitMax=0.002100 localStallMax=0.000100 debtMax=0.025000 debt=0.021000"
        precondition(LDACNativeSession.senderTimingSummary("SENDER_TIMING packets=180 waits=250 \(timing) clock=uptime-raw") == timing)
        precondition(LDACNativeSession.senderTimingSummary("SENDER_TIMING \(timing)") == nil)
        precondition(LDACNativeSession.senderTimingSummary("SENDER_TIMING packets=180 waits=250 \(timing) clock=uptime-raw private-data") == nil)
        let reasons = [
            "target_not_paired", "classic_manager_interface_unavailable", "classic_manager_not_ready",
            "classic_peer_interface_unavailable", "unexpected_peer_refresh_abi", "classic_peer_not_owned",
            "missing_or_invalid_fresh_acl_trigger", "canceled_or_owner_unavailable", "owned_peer_refresh_owner_mismatch",
            "owned_peer_refresh_invalid_reply", "owned_peer_refresh_not_connected", "owned_peer_refresh_update_failed",
            "classic-manager-unavailable", "classic-authorization-denied", "classic-initialization-incomplete",
            "classic-target-unavailable", "unexpected-peer-refresh-interface", "owned-peer-refresh-owner-mismatch",
            "owned-peer-refresh-invalid-reply", "owned-peer-refresh-not-connected", "owned-peer-refresh-update-failed"
        ]
        for reason in reasons {
            precondition(LDACNativeSession.helperFailureSummary("NO_OPEN reason=\(reason) address=AA-BB-CC-DD-EE-FF") == "NO_OPEN reason=\(reason)")
        }
        for reason in ["private_device_name", "private-device-name", "classic_manager_not_ready_extra", "classic-manager-unavailable-extra"] {
            precondition(LDACNativeSession.helperFailureSummary("NO_OPEN reason=\(reason)") == "NO_OPEN")
        }
        precondition(LDACNativeSession.helperFailureSummary("NO_OPEN Classic manager interface is unavailable reason=classic-manager-unavailable") == "NO_OPEN reason=classic-manager-unavailable")
        precondition(LDACNativeSession.helperFailureSummary("PCM_FAILED reason=read errno=32 address=AA-BB-CC-DD-EE-FF") == "PCM_FAILED errno=32 reason=read")
        for event in helperEvents {
            precondition(LDACNativeSession.helperFailureSummary(event.line + " address=AA-BB-CC-DD-EE-FF name=Private-headphones /Users/alex/private channel=0x12345678") == event.summary)
        }
        for reason in ["peer-selector", "query-selector", "reply-shape", "query-result", "state-shape", "state-value",
                       "baseline-connected", "baseline-native-output-present", "original-connection-ended", "epoch-retired",
                       "callback-without-fresh-acl", "output-inspection", "baseline-output-inspection"] {
            precondition(LDACNativeSession.helperFailureSummary("ACL_OBSERVATION_FAILED reason=\(reason)") == "ACL_OBSERVATION_FAILED reason=\(reason)")
        }
        for reason in ["private-device-name", "callback-without-fresh-acl-private", "output-inspection-private"] {
            precondition(LDACNativeSession.helperFailureSummary("ACL_OBSERVATION_FAILED reason=\(reason)") == "ACL_OBSERVATION_FAILED")
        }
        for status in ["0x0000000", "0x000000000", "0xE00002D6-private", "-1-private", String(repeating: "9", count: 10_000)] {
            precondition(LDACNativeSession.helperFailureSummary("CONNECTION_CALLBACK status=\(status) connected=0") == "CONNECTION_CALLBACK connected=0")
        }
        precondition(LDACNativeSession.helperFailureSummary("CONNECTION_CALLBACK status=-536870174 connected=0") == "CONNECTION_CALLBACK status=-536870174 connected=0")
        precondition(LDACNativeSession.helperFailureSummary("OPEN_CLEANUP_UNCONFIRMED pending=10 indeterminate=0-private cleanup=private") == "OPEN_CLEANUP_UNCONFIRMED")
        precondition(LDACNativeSession.helperFailureSummary("PRIVATE_HEADPHONES_UNCONFIRMED address=AA-BB-CC-DD-EE-FF") == "Unrecognized helper event")
        if CommandLine.arguments.count == 3, ["--live", "--finish"].contains(CommandLine.arguments[1]) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let active = try LDACNativeSession.beginDiagnostics(in: directory)
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            withExtendedLifetime(active) { _ = FileHandle.standardInput.readDataToEndOfFile() }
            if CommandLine.arguments[1] == "--finish" {
                try LDACNativeSession.completeDiagnostics(in: directory, releasing: active)
            }
            return
        }
        #if DEBUG
        try await checkHelperEmission()
        #endif
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let active = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let concurrent = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var children: [Process] = []
        defer {
            for child in children where child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        for directory in [active, concurrent] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--live", directory.path]
            child.standardInput = Pipe()
            child.standardOutput = Pipe()
            try child.run()
            children.append(child)
        }
        for child in children {
            let output = child.standardOutput as! Pipe
            let ready = try output.fileHandleForReading.read(upToCount: 1)
            precondition(ready == Data([1]))
        }
        for directory in [active, concurrent] {
            try Data("unchanged".utf8).write(to: directory.appendingPathComponent("session.log"))
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: -1)], ofItemAtPath: directory.path)
        }
        var inactive: [URL] = []
        for index in 0..<10 {
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("diagnostic \(index)".utf8).write(to: directory.appendingPathComponent("session.log"))
            if index.isMultiple(of: 2) {
                let marker = directory.appendingPathComponent("completed")
                try Data().write(to: marker)
                try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: marker.path)
            } else {
                try Data().write(to: directory.appendingPathComponent("active.lock"))
            }
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: directory.path)
            inactive.append(directory)
        }
        let legacy = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyLog = legacy.appendingPathComponent("session.log")
        try manager.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("legacy diagnostics".utf8).write(to: legacyLog)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: -2)], ofItemAtPath: legacy.path)
        let legacyHandle = try FileHandle(forWritingTo: legacyLog)
        defer { try? legacyHandle.close() }
        let current = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data().write(to: unrelated.appendingPathComponent("completed"))
        let linked = root.appendingPathComponent(UUID().uuidString)
        try manager.createSymbolicLink(at: linked, withDestinationURL: unrelated)
        let currentLock = try LDACNativeSession.beginDiagnostics(in: current)
        defer { try? currentLock.close() }
        for (index, directory) in inactive.enumerated() {
            precondition(manager.fileExists(atPath: directory.path) == (index >= 3))
        }
        try LDACNativeSession.completeDiagnostics(in: current)
        for (index, directory) in inactive.enumerated() {
            precondition(manager.fileExists(atPath: directory.path) == (index >= 3))
        }
        precondition(manager.fileExists(atPath: current.appendingPathComponent("completed").path))
        precondition(manager.fileExists(atPath: unrelated.path))
        precondition(manager.fileExists(atPath: linked.path))
        precondition(manager.fileExists(atPath: legacy.path))
        precondition(!manager.fileExists(atPath: legacy.appendingPathComponent("active.lock").path))
        for directory in [active, concurrent] {
            let contents = try Data(contentsOf: directory.appendingPathComponent("session.log"))
            precondition(contents == Data("unchanged".utf8))
            precondition(!manager.fileExists(atPath: directory.appendingPathComponent("completed").path))
        }
        precondition(kill(children[0].processIdentifier, SIGKILL) == 0)
        children[0].waitUntilExit()
        try LDACNativeSession.completeDiagnostics(in: current)
        precondition(!manager.fileExists(atPath: active.path))
        precondition(manager.fileExists(atPath: concurrent.path))
        for directory in inactive.suffix(7) { precondition(manager.fileExists(atPath: directory.path)) }
        try legacyHandle.close()
        try LDACNativeSession.completeDiagnostics(in: current)
        let legacyContents = try Data(contentsOf: legacyLog)
        precondition(legacyContents == Data("legacy diagnostics".utf8))
        precondition(!manager.fileExists(atPath: legacy.appendingPathComponent("completed").path))
        precondition(!manager.fileExists(atPath: legacy.appendingPathComponent("active.lock").path))
        let finishing = root.appendingPathComponent("finishing", isDirectory: true)
        try manager.createDirectory(at: finishing, withIntermediateDirectories: false)
        for index in 0..<8 {
            let directory = finishing.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let marker = directory.appendingPathComponent("completed")
            try Data().write(to: marker)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: marker.path)
        }
        for _ in 0..<2 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--finish", finishing.appendingPathComponent(UUID().uuidString).path]
            child.standardInput = Pipe()
            child.standardOutput = Pipe()
            try child.run()
            children.append(child)
        }
        for child in children.suffix(2) {
            let output = child.standardOutput as! Pipe
            let ready = try output.fileHandleForReading.read(upToCount: 1)
            precondition(ready == Data([1]))
        }
        for child in children.suffix(2) {
            let input = child.standardInput as! Pipe
            try input.fileHandleForWriting.close()
        }
        for child in children.suffix(2) {
            child.waitUntilExit()
            precondition(child.terminationStatus == 0)
        }
        let histories = try manager.contentsOfDirectory(at: finishing, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        precondition(histories.count == 8)
        print("LDAC diagnostic checks passed: redacted helper events/status/reasons, mixed completed/managed-orphan limit, legacy preservation, concurrent live locks and completion, forced-exit recovery, unrelated paths")
    }

    #if DEBUG
    @MainActor
    static func checkHelperEmission() async throws {
        for stopping in [false, true] {
            for event in helperEvents {
                var diagnostics: [LDACNativeSession.Diagnostic] = []
                var completed = false
                let session = LDACNativeSession(id: UUID(), address: "AA:BB:CC:DD:EE:FF", helpers: .init(bundle: .main), gain: 0) {
                    switch $0 {
                    case let .diagnostic(value): diagnostics.append(value)
                    case .finished: completed = true
                    default: break
                    }
                }
                session.simulateDiagnosticHelperFailure(event.line + " address=AA-BB-CC-DD-EE-FF name=Private-headphones /Users/alex/private channel=0x12345678",
                    source: event.source, stopping: stopping, previousStage: event.source == "connector" ? "probe" : "connector")
                let deadline = DispatchTime.now() + 2
                while !completed && DispatchTime.now() < deadline { try await Task.sleep(for: .milliseconds(1)) }
                precondition(completed)
                precondition(diagnostics.contains { $0.stage == event.source && $0.detail == event.summary && $0.isFailure == (event.failure && !stopping) })
                if event.failure && !stopping {
                    precondition(diagnostics.first(where: \.isFailure)?.stage == event.source)
                    precondition(diagnostics.first(where: \.isFailure)?.detail == event.summary)
                }
                for diagnostic in diagnostics {
                    precondition(diagnostic.detail.utf8.count <= 250)
                    for omitted in ["AA-BB-CC-DD-EE-FF", "Private-headphones", "/Users/alex", "0x12345678", "CID=", "time="] {
                        precondition(!diagnostic.detail.contains(omitted))
                    }
                }
            }
        }
        print("LDAC helper diagnostic emission checks passed: explicit source, first failure, shutdown evidence, redaction")
    }
    #endif
}
