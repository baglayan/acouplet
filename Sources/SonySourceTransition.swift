import Foundation

struct SonySourceTransition: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case awaitingKeeping
        case queuedSelection
        case awaitingSelection
        case queuedReadback
        case verifying
        case complete
        case failed
    }

    let requestID: UUID
    let session: UInt64
    let targetAddress: String?
    let requestedKeeping: Bool?
    private(set) var phase = Phase.queued
    private(set) var failureMessage: String?
    private let initialPayload: [UInt8]

    init?(targetAddress: String, model: SonyMultipoint, session: UInt64, requestID: UUID = UUID()) {
        guard let selection = model.sourceSwitchPayload(address: targetAddress) else { return nil }
        let address = String(decoding: selection.dropFirst(2), as: UTF8.self)
        guard model.selectedSource?.address != address else { return nil }
        self.requestID = requestID
        self.session = session
        self.targetAddress = address
        requestedKeeping = nil
        initialPayload = model.keeping == true ? [0x38, 0x01, 0x01] : selection
    }

    init?(keeping: Bool, model: SonyMultipoint, session: UInt64, requestID: UUID = UUID()) {
        guard model.keeping != keeping, let payload = model.keepingSetPayload(keeping) else { return nil }
        self.requestID = requestID
        self.session = session
        targetAddress = keeping ? model.selectedSource?.address : nil
        requestedKeeping = keeping
        initialPayload = payload
    }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .queued: initialPayload
        case .queuedSelection: [0x3C, 0x01] + Array(targetAddress!.utf8)
        case .queuedReadback: [0x36, 0x02]
        default: nil
        }
    }

    var isFinished: Bool { phase == .complete || phase == .failed }

    @discardableResult
    mutating func validateForTransmission(model: SonyMultipoint, session: UInt64) -> Bool {
        guard session == self.session, let payload = expectedPayload else { return false }
        if phase == .queuedReadback {
            guard model.supportsInventory else { return fail(String(localized: "Device information is no longer available.")) }
            return true
        }
        if let requestedKeeping {
            guard model.keepingSetPayload(requestedKeeping) == payload,
                  !requestedKeeping || model.selectedSource?.address == targetAddress else {
                return fail(String(localized: "The audio source changed or its controls are no longer available."))
            }
        } else {
            guard let targetAddress, model.sourceSwitchPayload(address: targetAddress) != nil,
                  payload[0] != 0x3C || model.keeping == false,
                  payload[0] != 0x38 || model.keepingSetPayload(false) == payload else {
                return fail(String(localized: "The selected device is no longer connected or its audio controls are unavailable."))
            }
        }
        return true
    }

    @discardableResult
    mutating func commandTransmitted(_ payload: [UInt8], model: SonyMultipoint, session: UInt64) -> Bool {
        guard payload == expectedPayload, validateForTransmission(model: model, session: session) else { return false }
        switch phase {
        case .queued: phase = payload[0] == 0x38 ? .awaitingKeeping : .awaitingSelection
        case .queuedSelection: phase = .awaitingSelection
        case .queuedReadback: phase = .verifying
        default: return false
        }
        return true
    }

    @discardableResult
    mutating func receive(_ payload: [UInt8], model: SonyMultipoint, session: UInt64, readbackOwned: Bool = false) -> Bool {
        guard session == self.session, !isFinished else { return false }
        switch phase {
        case .awaitingKeeping:
            guard payload.count == 4, payload[0] == 0x39, payload[1] == 0x01 else { return false }
            let result = SonySourceControlResult(rawValue: payload[3])
            if result != .success {
                fail(result.errorMessage!)
                return true
            }
            let expectedKeeping = requestedKeeping ?? false
            guard payload[2] == (expectedKeeping ? 0x00 : 0x01) else {
                fail(String(localized: "The headphones did not confirm the requested source keeping setting."))
                return true
            }
            if requestedKeeping != nil {
                guard !expectedKeeping || model.selectedSource?.address == targetAddress else {
                    fail(String(localized: "The audio source changed before source keeping was confirmed."))
                    return true
                }
                phase = .complete
            } else {
                phase = .queuedSelection
                _ = validateForTransmission(model: model, session: session)
            }
        case .awaitingSelection:
            guard payload.count == 20, payload[0] == 0x3D, payload[1] == 0x01 else { return false }
            var received = model
            guard received.update(payload), let result = received.lastSourceResult,
                  result.matches(address: targetAddress!) else { return false }
            if result.result != .success {
                fail(result.result.errorMessage!)
            } else {
                phase = .queuedReadback
            }
        case .verifying:
            guard readbackOwned, payload.count >= 2, payload[0] == 0x37, payload[1] == 0x02 else { return false }
            var received = model
            guard received.update(payload), !received.inventoryIsStale,
                  received.available == true, received.selectedSource?.address == targetAddress else {
                fail(String(localized: "The headphones did not confirm the selected audio source. Refresh the device list before trying again."))
                return true
            }
            phase = .complete
        default:
            return false
        }
        return true
    }

    @discardableResult
    mutating func timeout() -> Bool {
        guard phase == .awaitingKeeping || phase == .awaitingSelection || phase == .verifying else { return false }
        fail(String(localized: "The headphones did not confirm the audio source change in time."))
        return true
    }

    @discardableResult
    mutating func controlLost(session: UInt64) -> Bool {
        guard session == self.session, !isFinished else { return false }
        fail(String(localized: "The control connection was lost before the audio source change was confirmed."))
        return true
    }

    @discardableResult
    mutating func capabilitiesChanged(session: UInt64) -> Bool {
        guard session == self.session, !isFinished else { return false }
        fail(String(localized: "The headphone settings changed before the audio source change was confirmed."))
        return true
    }

    @discardableResult
    private mutating func fail(_ message: String) -> Bool {
        phase = .failed
        failureMessage = message
        return false
    }
}
