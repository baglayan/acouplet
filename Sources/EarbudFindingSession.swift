import Foundation

struct EarbudFindingSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, connecting, awaitingWearingConfirmation, starting, ringing, stopping, finished, unconfirmed, failed
    }

    enum Effect: Equatable, Sendable {
        case connect
        case send(FastPairRingCommand)
        case close
    }

    let id: UUID
    let target: FastPairRingTarget
    let timeoutSeconds: UInt8
    private(set) var phase = Phase.idle
    private(set) var mayBeRinging = false
    private(set) var rejection: FastPairRingRejection?
    private(set) var isRetryingStop = false
    private(set) var startedWithWearingOverride = false
    private var ignoresWornReading = false
    private var pendingCommand: FastPairRingCommand?
    private var stopRequested = false
    private var stopAttempted = false

    init(target: FastPairRingTarget, timeoutSeconds: UInt8, id: UUID = UUID()) {
        precondition(timeoutSeconds > 0)
        self.id = id
        self.target = target
        self.timeoutSeconds = timeoutSeconds
    }

    var isFinished: Bool { phase == .finished || phase == .unconfirmed || phase == .failed }

    mutating func begin() -> [Effect] {
        guard phase == .idle else { return [] }
        phase = .connecting
        return [.connect]
    }

    mutating func connectionOpened(worn: Bool? = false) -> [Effect] {
        guard phase == .connecting else { return [] }
        if isRetryingStop {
            stopRequested = true
            pendingCommand = .stop
            phase = .stopping
            return [.send(.stop)]
        }
        guard let worn else { return stop() }
        if worn {
            phase = .awaitingWearingConfirmation
            return []
        }
        return start()
    }

    mutating func confirmWearingOverride(worn: Bool?) -> [Effect] {
        guard phase == .awaitingWearingConfirmation else { return [] }
        guard let worn else { return stop() }
        startedWithWearingOverride = worn
        ignoresWornReading = worn
        return start()
    }

    mutating func wearingChanged(_ worn: Bool?) -> [Effect] {
        guard phase == .starting || phase == .ringing else { return [] }
        guard let worn else { return stop() }
        if !worn { ignoresWornReading = false }
        else if !ignoresWornReading { return stop() }
        return []
    }

    private mutating func start() -> [Effect] {
        phase = .starting
        let command = FastPairRingCommand.ring(target, timeoutSeconds: timeoutSeconds)!
        pendingCommand = command
        return [.send(command)]
    }

    mutating func commandWillSend(_ command: FastPairRingCommand) -> Bool {
        guard pendingCommand == command else { return false }
        pendingCommand = nil
        if command == .stop { stopAttempted = true }
        else { mayBeRinging = true }
        return true
    }

    mutating func commandWasNotSent(_ command: FastPairRingCommand) -> [Effect] {
        guard pendingCommand == command else { return [] }
        return transportFailed()
    }

    mutating func receive(_ response: FastPairRingResponse) -> [Effect] {
        if !mayBeRinging, [.finished, .connecting, .awaitingWearingConfirmation, .starting].contains(phase),
           case .status(let status) = response, status.components != .stopped {
            mayBeRinging = true
            stopRequested = false
            stopAttempted = false
            phase = .ringing
            return stop()
        }
        guard [.starting, .ringing, .stopping].contains(phase), mayBeRinging else { return [] }
        let status: FastPairRingStatus?
        switch response {
        case .status(let value), .acknowledgement(let value?):
            status = value
        case .acknowledgement(nil):
            return []
        case .rejection(let reason, let value):
            rejection = reason
            status = value
            if status?.components != .stopped { return stop() }
        }
        guard let status else { return [] }
        if status.components == .stopped {
            if phase == .starting { return stop() }
            guard phase == .ringing || stopAttempted else { return [] }
            mayBeRinging = false
            isRetryingStop = false
            pendingCommand = nil
            phase = .finished
            return [.close]
        }
        guard !stopRequested else { return [] }
        guard status.components.rawValue == target.rawValue,
              status.timeoutSeconds == timeoutSeconds else { return stop() }
        phase = .ringing
        return []
    }

    mutating func stop() -> [Effect] {
        guard !isFinished else { return [] }
        if phase == .connecting, isRetryingStop { return transportFailed() }
        guard mayBeRinging else {
            pendingCommand = nil
            phase = .finished
            return [.close]
        }
        guard !stopRequested else { return [] }
        stopRequested = true
        pendingCommand = .stop
        phase = .stopping
        return [.send(.stop)]
    }

    mutating func retryStop() -> [Effect] {
        guard phase == .unconfirmed, mayBeRinging else { return [] }
        isRetryingStop = true
        stopRequested = false
        stopAttempted = false
        pendingCommand = nil
        phase = .connecting
        return [.connect]
    }

    mutating func acknowledgementExpired() -> [Effect] {
        switch phase {
        case .starting:
            return stop()
        case .stopping:
            return transportFailed()
        default:
            return []
        }
    }

    mutating func deadlineExpired() -> [Effect] {
        guard !isFinished, phase != .idle else { return [] }
        return stop()
    }

    mutating func transportFailed() -> [Effect] {
        guard !isFinished else { return [] }
        pendingCommand = nil
        isRetryingStop = false
        phase = mayBeRinging ? .unconfirmed : .failed
        return [.close]
    }
}
