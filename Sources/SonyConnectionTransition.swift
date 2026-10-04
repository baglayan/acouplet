struct SonyConnectionTransition: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case awaitingResponse
        case awaitingUser(SonyConnectionAlert)
        case replyQueued(SonyConnectionAlert, SonyConnectionAlertAction)
        case pairingRequired
        case reconnecting
        case recovering
        case verifying
        case confirmed
        case cancelled
        case failed
    }

    let generation: SonyProtocolInfo.Generation
    let originalMode: SonyConnectionMode
    private(set) var targetMode: SonyConnectionMode
    private(set) var phase = Phase.queued
    private(set) var session: UInt64
    private(set) var preferenceConfirmed = false
    private(set) var requiredStream: SonyConnectionStream?
    private var awaitingReadback = false
    private var resumesVerification = false
    private var acceptedPairingRequest = false

    init?(original: SonyConnectionMode, target: SonyConnectionMode, supportedModes: [SonyConnectionMode], session: UInt64,
          generation: SonyProtocolInfo.Generation = .v2) {
        guard original.sonyValue != nil, target.sonyValue != nil,
              original != target, supportedModes.contains(target),
              generation != .v1 || (original != .lowLatency && target != .lowLatency) else { return nil }
        self.generation = generation
        originalMode = original
        targetMode = target
        self.session = session
    }

    var requestPayload: [UInt8] {
        generation == .v1 ? [0xE8, 0x01, 0, targetMode.sonyValue!] : [0xE8, 0x05, targetMode.sonyValue!, 0x00]
    }

    var readbackPayload: [UInt8] {
        [0xE6, generation == .v1 ? 0x01 : 0x05]
    }

    var crossesTransport: Bool {
        (originalMode == .lowLatency) != (targetMode == .lowLatency)
    }

    var alert: SonyConnectionAlert? {
        if case .awaitingUser(let alert) = phase { alert } else { nil }
    }

    var awaitingUser: Bool {
        alert != nil
    }

    var isFinished: Bool {
        switch phase {
        case .confirmed, .cancelled, .failed: true
        default: false
        }
    }

    @discardableResult
    mutating func commandTransmitted(_ payload: [UInt8], session: UInt64) -> Bool {
        guard session == self.session else { return false }
        switch phase {
        case .queued:
            guard payload == requestPayload else { return false }
            phase = .awaitingResponse
        case .replyQueued(let alert, let action):
            guard payload == alert.replyPayload(action) else { return false }
            acceptedPairingRequest = action == .positive && alert.format == .flexible && alert.messageID == 0x10
            phase = action == .negative ? .cancelled : responsePhase
        default:
            return false
        }
        awaitingReadback = false
        return true
    }

    @discardableResult
    mutating func receiveAlert(_ alert: SonyConnectionAlert, session: UInt64) -> Bool {
        guard session == self.session,
              phase == .awaitingResponse || phase == .reconnecting || phase == .verifying || phase == .confirmed,
              generation != .v1 || phase != .confirmed,
              generation == .v1 ? alert.isLegacyConnectionChange : alert.requestedMode == targetMode else { return false }
        if case .unknown = alert.actionType { return false }
        resumesVerification = phase == .verifying
        phase = .awaitingUser(alert)
        awaitingReadback = false
        return true
    }

    mutating func respond(to alert: SonyConnectionAlert, action: SonyConnectionAlertAction) -> [UInt8]? {
        guard phase == .awaitingUser(alert), let payload = alert.replyPayload(action) else { return nil }
        if generation == .v1, action == .positive {
            targetMode = .stableConnection
            preferenceConfirmed = false
        }
        phase = .replyQueued(alert, action)
        return payload
    }

    @discardableResult
    mutating func acknowledge(_ alert: SonyConnectionAlert) -> Bool {
        guard phase == .awaitingUser(alert), alert.actionType == .confirmationOnly else { return false }
        phase = responsePhase
        return true
    }

    @discardableResult
    mutating func receiveLEStandby(_ enabled: Bool, session: UInt64) -> Bool {
        guard generation == .v2, session == self.session, phase == .awaitingResponse, acceptedPairingRequest, enabled else { return false }
        phase = .pairingRequired
        awaitingReadback = false
        return true
    }

    @discardableResult
    mutating func readbackTransmitted(session: UInt64) -> Bool {
        guard session == self.session, !awaitingReadback else { return false }
        switch phase {
        case .awaitingResponse, .reconnecting, .verifying:
            awaitingReadback = true
            return true
        default:
            return false
        }
    }

    mutating func discardReadback(session: UInt64) {
        guard session == self.session else { return }
        awaitingReadback = false
    }

    @discardableResult
    mutating func receiveReadback(_ mode: SonyConnectionMode, session: UInt64) -> Bool {
        guard session == self.session, awaitingReadback else { return false }
        awaitingReadback = false
        preferenceConfirmed = mode == targetMode
        if phase == .verifying, acceptedPairingRequest, mode == originalMode {
            phase = .pairingRequired
        }
        guard mode == targetMode else { return true }
        if phase == .verifying || (!crossesTransport && requiredStream == nil) {
            phase = .confirmed
        } else {
            phase = .reconnecting
        }
        return true
    }

    @discardableResult
    mutating func receiveNotification(_ mode: SonyConnectionMode, stream: SonyConnectionStream, session: UInt64) -> Bool {
        guard session == self.session, mode == targetMode, generation != .v1 || stream == .none else { return false }
        switch phase {
        case .awaitingResponse, .reconnecting, .verifying, .confirmed: break
        default: return false
        }
        switch stream {
        case .none:
            preferenceConfirmed = true
            if phase != .verifying && phase != .confirmed {
                phase = crossesTransport || requiredStream != nil ? .reconnecting : .confirmed
            }
        case .leAudio, .classicAudio:
            preferenceConfirmed = true
            requiredStream = stream
            if phase != .verifying { phase = .reconnecting }
        case .unknown:
            return false
        }
        if phase == .confirmed { awaitingReadback = false }
        return true
    }

    @discardableResult
    mutating func controlLost(session: UInt64) -> Bool {
        guard session == self.session, phase != .cancelled, phase != .failed, phase != .pairingRequired else { return false }
        phase = phase == .queued ? .failed : .recovering
        awaitingReadback = false
        return true
    }

    @discardableResult
    mutating func controlReady(session: UInt64) -> Bool {
        guard session > self.session, phase == .reconnecting || phase == .recovering else { return false }
        self.session = session
        phase = .verifying
        awaitingReadback = false
        return true
    }

    @discardableResult
    mutating func timeout() -> Bool {
        guard phase == .awaitingResponse || phase == .verifying else { return false }
        phase = .failed
        awaitingReadback = false
        return true
    }

    @discardableResult
    mutating func recoveryFailed() -> Bool {
        guard phase == .recovering || phase == .reconnecting || phase == .verifying else { return false }
        phase = .failed
        awaitingReadback = false
        return true
    }

    @discardableResult
    mutating func retryRecovery() -> Bool {
        guard phase == .failed || phase == .pairingRequired else { return false }
        phase = .recovering
        awaitingReadback = false
        return true
    }

    private var responsePhase: Phase {
        if resumesVerification { return .verifying }
        return preferenceConfirmed && (crossesTransport || requiredStream != nil) ? .reconnecting : .awaitingResponse
    }
}
