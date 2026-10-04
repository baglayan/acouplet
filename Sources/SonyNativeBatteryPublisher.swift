#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import Darwin
import Foundation
import OSLog

struct SonyNativeBatteryPublication: Equatable, Codable {
    struct Part: Equatable, Codable {
        let level: Int
        let isCharging: Bool
        let observedAt: TimeInterval

        init(_ reading: SonyNativeBatterySnapshot.Reading) {
            level = reading.level
            isCharging = reading.isCharging
            observedAt = reading.observedAt.timeIntervalSince1970
        }
    }

    struct Identity: Hashable {
        let address: String
        let identifier: UUID
        let controlSession: UInt64
    }

    let address: String
    let identifier: UUID
    let controlSession: UInt64
    let left: Part
    let right: Part

    var identity: Identity { Identity(address: address, identifier: identifier, controlSession: controlSession) }
    var expiresAt: Date { Date(timeIntervalSince1970: min(left.observedAt, right.observedAt) + 45) }

    init?(address: String, controlSession: UInt64, snapshot: SonyNativeBatterySnapshot, at date: Date) {
        guard let address = SonyBLEIdentity.normalizedAddress(address),
              let left = snapshot.left, let right = snapshot.right,
              left.level > 0, right.level > 0,
              left.isFresh(at: date), right.isFresh(at: date) else { return nil }
        self.address = address
        identifier = snapshot.identifier
        self.controlSession = controlSession
        self.left = Part(left)
        self.right = Part(right)
    }

    func canReplace(_ previous: Self) -> Bool {
        identity == previous.identity && left.observedAt > previous.left.observedAt && right.observedAt > previous.right.observedAt
    }
}

@MainActor
final class SonyNativeBatteryPublisher {
    struct Connection {
        let send: (Data) throws -> Void
        let close: () -> Void
        let isRunning: () -> Bool
        var didExitWithoutPublishing: () -> Bool = { false }
        var didExitSuccessfully: () -> Bool = { false }
        var didWithdrawAfterNativeDisconnect: () -> Bool = { false }
        var exitStatus: () -> Int32? = { nil }
    }

    private struct Session {
        let connection: Connection
        let attempt: Int
        var publication: SonyNativeBatteryPublication
        var pending: SonyNativeBatteryPublication?
        var queued: SonyNativeBatteryPublication?
        var update: UInt64 = 0
        var acknowledgmentDeadline: Date?
        var acknowledgmentExpiry: AnyCancellable?
        var expiry: AnyCancellable?
        var output = Data()
    }

    private struct Attempt {
        let publication: SonyNativeBatteryPublication
        let date: Date
        let count: Int
        var retryCount = 1
        var retry = false
        var resumeAfterWithdrawal = false
        var exitedSuccessfully = false
        var withdrewAfterNativeDisconnect = false
    }

    private struct Acknowledgment: Decodable {
        let sample: SonyNativeBatteryPublication
        let update: UInt64
    }

    private let launch: (SonyNativeBatteryPublication, @escaping @MainActor @Sendable (Data) -> Void) throws -> Connection
    private let schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> AnyCancellable
    private let now: () -> Date
    private var sessions: [String: Session] = [:]
    private var closing: [String: (connection: Connection, publication: SonyNativeBatteryPublication, date: Date, retry: Bool, resumeAfterWithdrawal: Bool, attempt: Int, output: Data, outputComplete: Bool, protocolFailed: Bool)] = [:]
    private var attempts: [String: Attempt] = [:]
    private var isStopped = false
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "NativeBatteryPublisher")

    var ownedAddresses: Set<String> { Set(sessions.keys) }

    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping @MainActor (Date, @escaping @MainActor () -> Void) -> AnyCancellable = SonyNativeBatteryPublisher.scheduleExpiry,
         launch: @escaping (SonyNativeBatteryPublication, @escaping @MainActor @Sendable (Data) -> Void) throws -> Connection) {
        self.now = now
        self.schedule = schedule
        self.launch = launch
    }

    convenience init(executableURL: URL) {
        self.init { publication, receive in
            let pipe = try SonyNativeBatteryPipe(executableURL: executableURL,
                arguments: ["--publish", publication.identifier.uuidString, UUID().uuidString], receive: receive)
            return Connection(send: pipe.send, close: pipe.close, isRunning: { pipe.process.isRunning }, didExitWithoutPublishing: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 75
            }, didExitSuccessfully: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && [0, 76].contains(pipe.process.terminationStatus)
            }, didWithdrawAfterNativeDisconnect: {
                !pipe.process.isRunning && pipe.process.terminationReason == .exit && pipe.process.terminationStatus == 76
            }, exitStatus: {
                pipe.process.isRunning ? nil : pipe.process.terminationStatus
            })
        }
    }

    func reconcile(_ publications: [SonyNativeBatteryPublication]) {
        let date = now()
        guard !isStopped else { return }
        let current = Dictionary(uniqueKeysWithValues: publications.map { ($0.address, $0) })
        for address in Array(sessions.keys) {
            guard let session = sessions[address] else { continue }
            guard session.connection.didExitWithoutPublishing()
                || (session.publication.expiresAt > date && (session.acknowledgmentDeadline.map({ date < $0 }) ?? true)) else {
                close(address)
                continue
            }
            if !session.connection.isRunning() {
                close(address, retryIfUnpublished: true)
                continue
            }
            guard let publication = current[address] else {
                close(address, resumeAfterWithdrawal: true)
                continue
            }
            guard publication.expiresAt > date else {
                close(address)
                continue
            }
            guard publication.identity == session.publication.identity else {
                close(address, resumeAfterWithdrawal: true)
                continue
            }
            let latest = session.queued ?? session.pending ?? session.publication
            if publication == latest { continue }
            guard publication.canReplace(latest) else { close(address); continue }
            if session.pending != nil {
                sessions[address]?.queued = publication
            } else {
                send(publication)
            }
        }
        for address in Array(closing.keys) {
            guard let retired = closing[address], !retired.connection.isRunning(), retired.outputComplete else { continue }
            let disconnected = retired.connection.didWithdrawAfterNativeDisconnect()
            let successful = !retired.protocolFailed && retired.connection.didExitSuccessfully()
                && (!disconnected || retired.retry || retired.resumeAfterWithdrawal)
            if disconnected && successful, let previous = attempts[address] {
                attempts[address] = Attempt(publication: retired.publication, date: retired.date, count: previous.count)
            }
            attempts[address]?.retry = !retired.protocolFailed && retired.retry && retired.connection.didExitWithoutPublishing()
            attempts[address]?.exitedSuccessfully = successful
            attempts[address]?.withdrewAfterNativeDisconnect = disconnected && successful
            attempts[address]?.resumeAfterWithdrawal = (retired.resumeAfterWithdrawal || (retired.retry && disconnected)) && successful
            Self.logger.info("Native battery helper retired: status=\(retired.connection.exitStatus() ?? -1, privacy: .public) successful=\(successful, privacy: .public) protocolFailed=\(retired.protocolFailed, privacy: .public) disconnected=\(disconnected, privacy: .public) resume=\(self.attempts[address]?.resumeAfterWithdrawal == true, privacy: .public)")
            closing.removeValue(forKey: address)
        }
        for publication in publications where sessions[publication.address] == nil && closing[publication.address] == nil {
            guard publication.expiresAt.timeIntervalSince(date) >= 25 else { continue }
            let previous = attempts[publication.address]
            if let previous, previous.resumeAfterWithdrawal || previous.publication.identity == publication.identity || !previous.exitedSuccessfully {
                guard previous.resumeAfterWithdrawal || (previous.retry && previous.retryCount < 3),
                      date.timeIntervalSince(previous.date) >= 15,
                      publication.left.observedAt > previous.publication.left.observedAt,
                      publication.right.observedAt > previous.publication.right.observedAt else { continue }
            }
            let attempt = (previous?.count ?? 0) + 1
            attempts[publication.address] = Attempt(publication: publication, date: date, count: attempt,
                retryCount: previous?.exitedSuccessfully == true ? 1 : (previous?.retryCount ?? 0) + 1)
            do {
                let connection = try launch(publication) { [weak self] data in
                    self?.receive(data, identity: publication.identity, attempt: attempt)
                }
                sessions[publication.address] = Session(connection: connection, attempt: attempt, publication: publication)
                setExpiry(publication)
                send(publication)
            } catch {
                Self.logger.error("Native battery launch failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func revoke() {
        for address in Array(sessions.keys) { close(address) }
        for address in Array(closing.keys) {
            closing[address]?.retry = false
            closing[address]?.resumeAfterWithdrawal = false
        }
        for address in Array(attempts.keys) {
            if attempts[address]?.withdrewAfterNativeDisconnect == true { attempts[address]?.exitedSuccessfully = false }
            attempts[address]?.retry = false
            attempts[address]?.resumeAfterWithdrawal = false
        }
    }

    func stop() {
        isStopped = true
        revoke()
    }

    private func send(_ publication: SonyNativeBatteryPublication) {
        let address = publication.address, date = now()
        guard let session = sessions[address], session.publication.expiresAt > date,
              publication.expiresAt.timeIntervalSince(date) >= 25 else { close(address); return }
        do {
            var data = try JSONEncoder().encode(publication)
            data.append(0x0A)
            let deadline = min(date.addingTimeInterval(10), session.publication.expiresAt)
            sessions[address]?.pending = publication
            sessions[address]?.update += 1
            sessions[address]?.acknowledgmentDeadline = deadline
            sessions[address]?.acknowledgmentExpiry = schedule(deadline) { [weak self] in
                guard let self, self.sessions[address]?.pending == publication else { return }
                self.close(address)
            }
            try session.connection.send(data)
        } catch {
            Self.logger.error("Native battery update failed: \(error.localizedDescription, privacy: .private)")
            close(address)
        }
    }

    private func receive(_ data: Data, identity: SonyNativeBatteryPublication.Identity, attempt: Int) {
        let address = identity.address
        if let retired = closing[address], retired.publication.identity == identity, retired.attempt == attempt {
            if data.isEmpty {
                closing[address]?.outputComplete = true
                if !retired.output.isEmpty { closing[address]?.protocolFailed = true }
                return
            }
            closing[address]?.output.append(data)
            while let newline = closing[address]?.output.firstIndex(of: 0x0A) {
                guard let line = closing[address]?.output.prefix(upTo: newline) else { return }
                closing[address]?.output.removeSubrange(...newline)
                guard line.count <= 8192, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    closing[address]?.protocolFailed = true
                    continue
                }
                logHelperEvent(object)
            }
            if let count = closing[address]?.output.count, count > 8192 {
                closing[address]?.protocolFailed = true
                closing[address]?.output = Data()
            }
            return
        }
        guard let session = sessions[address], session.publication.identity == identity, session.attempt == attempt else { return }
        let date = now()
        guard session.connection.didExitWithoutPublishing()
            || (session.publication.expiresAt > date && (session.acknowledgmentDeadline.map({ date < $0 }) ?? true)) else { close(address, outputComplete: data.isEmpty); return }
        guard !data.isEmpty else { close(address, retryIfUnpublished: session.output.isEmpty, outputComplete: true, protocolFailed: !session.output.isEmpty); return }
        sessions[address]?.output.append(data)
        while let newline = sessions[address]?.output.firstIndex(of: 0x0A) {
            guard let line = sessions[address]?.output.prefix(upTo: newline), line.count <= 8192 else { close(address, protocolFailed: true); return }
            sessions[address]?.output.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { close(address, protocolFailed: true); return }
            logHelperEvent(object)
            guard object["event"] as? String == "refresh-completed" else { continue }
            guard let sample = object["sample"] as? [String: Any],
                  Set(sample.keys) == ["address", "identifier", "controlSession", "left", "right"],
                  ["left", "right"].allSatisfy({ key in
                      guard let part = sample[key] as? [String: Any] else { return false }
                      return Set(part.keys) == ["level", "isCharging", "observedAt"]
                  }),
                  let acknowledgment = try? JSONDecoder().decode(Acknowledgment.self, from: Data(line)),
                  let session = sessions[address], let pending = session.pending,
                  acknowledgment.sample == pending, acknowledgment.update == session.update,
                  let deadline = session.acknowledgmentDeadline,
                  now() < deadline, now() < session.publication.expiresAt else { close(address, protocolFailed: true); return }
            guard session.connection.isRunning() else {
                sessions[address]?.output = Data()
                close(address, retryIfUnpublished: true)
                if !session.output.isEmpty { receive(session.output, identity: identity, attempt: attempt) }
                return
            }
            session.acknowledgmentExpiry?.cancel()
            sessions[address]?.acknowledgmentExpiry = nil
            sessions[address]?.acknowledgmentDeadline = nil
            sessions[address]?.pending = nil
            sessions[address]?.queued = nil
            sessions[address]?.publication = pending
            setExpiry(pending)
            if let queued = session.queued { send(queued) }
        }
        if let count = sessions[address]?.output.count, count > 8192 { close(address, protocolFailed: true) }
    }

    private func logHelperEvent(_ object: [String: Any]) {
        let report = object["event"] as? String == "child-report" ? object["report"] as? [String: Any] : object
        guard let report, let event = report["event"] as? String,
              ["guard-lost", "native-unavailable", "native-disconnected", "final-inventory", "child-exit", "supervisor-exit", "child-terminated", "prerequisite-unavailable"].contains(event) else { return }
        let phase = report["phase"] as? String ?? "none"
        let knownPhase = ["child", "supervisor", "supervisor-refresh"].contains(phase) ? phase : "none"
        Self.logger.info("Native battery withdrawal: event=\(event, privacy: .public) phase=\(knownPhase, privacy: .public) result=\((report["result"] as? Int) ?? -1, privacy: .public) status=\((report["status"] as? Int) ?? -1, privacy: .public) nativeSingle=\((report["nativeSingle"] as? Bool) ?? false, privacy: .public) disconnected=\((report["nativeDisconnected"] as? Bool) ?? false, privacy: .public)")
    }

    private func setExpiry(_ publication: SonyNativeBatteryPublication) {
        sessions[publication.address]?.expiry?.cancel()
        sessions[publication.address]?.expiry = schedule(publication.expiresAt) { [weak self] in
            guard let self, self.sessions[publication.address]?.publication == publication else { return }
            self.close(publication.address)
        }
    }

    private func close(_ address: String, retryIfUnpublished: Bool = false, resumeAfterWithdrawal: Bool = false, outputComplete: Bool = false, protocolFailed: Bool = false) {
        guard let session = sessions.removeValue(forKey: address) else { return }
        session.expiry?.cancel()
        session.acknowledgmentExpiry?.cancel()
        session.connection.close()
        if resumeAfterWithdrawal {
            attempts[address] = Attempt(publication: session.queued ?? session.pending ?? session.publication,
                date: now(), count: session.attempt)
        }
        let classification = resumeAfterWithdrawal ? "intentional-withdrawal" : retryIfUnpublished ? "process-exit" : "failure"
        Self.logger.info("Native battery closing: classification=\(classification, privacy: .public)")
        closing[address] = (session.connection, session.queued ?? session.pending ?? session.publication, now(), retryIfUnpublished, resumeAfterWithdrawal, session.attempt, session.output, outputComplete, protocolFailed)
    }

    private static func scheduleExpiry(_ date: Date, action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            action()
        }
        return AnyCancellable { task.cancel() }
    }
}

final class SonyNativeBatteryPipe {
    let process = Process()
    private var input: FileHandle?
    private var output: FileHandle?

    init(executableURL: URL, arguments: [String], receive: @escaping @MainActor @Sendable (Data) -> Void = { _ in }) throws {
        let pipe = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = pipe
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        input = pipe.fileHandleForWriting
        self.output = output.fileHandleForReading
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { receive(data) }
        }
        try pipe.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }

    func send(_ data: Data) throws {
        guard let input, process.isRunning else { throw POSIXError(.EPIPE) }
        try input.write(contentsOf: data)
    }

    func close() {
        try? input?.close()
        input = nil
    }

    deinit {
        close()
        output?.readabilityHandler = nil
        try? output?.close()
    }
}
#endif
