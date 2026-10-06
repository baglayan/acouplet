import Foundation

struct SonyDeviceActionTransition: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case awaitingResult
        case queuedReadback
        case verifying
        case complete
        case failed
    }

    let requestID: UUID
    let session: UInt64
    let action: SonyPeripheralAction
    let targetAddress: String
    private(set) var phase = Phase.queued
    private(set) var failureMessage: String?

    init?(action: SonyPeripheralAction, targetAddress: String, model: SonyMultipoint, session: UInt64, requestID: UUID = UUID()) {
        guard action != .unpair, let payload = model.peripheralActionPayload(action, address: targetAddress) else { return nil }
        self.requestID = requestID
        self.session = session
        self.action = action
        self.targetAddress = String(decoding: payload.dropFirst(3), as: UTF8.self)
    }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .queued: [0x3C, 0x02, action.rawValue] + Array(targetAddress.utf8)
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
        } else {
            guard model.peripheralActionPayload(action, address: targetAddress) == payload else {
                return fail(String(localized: "The device connection changed or its controls are no longer available."))
            }
        }
        return true
    }

    @discardableResult
    mutating func commandTransmitted(_ payload: [UInt8], model: SonyMultipoint, session: UInt64) -> Bool {
        guard payload == expectedPayload, validateForTransmission(model: model, session: session) else { return false }
        switch phase {
        case .queued: phase = .awaitingResult
        case .queuedReadback: phase = .verifying
        default: return false
        }
        return true
    }

    @discardableResult
    mutating func receive(_ payload: [UInt8], model: SonyMultipoint, session: UInt64, readbackOwned: Bool = false) -> Bool {
        guard session == self.session, !isFinished else { return false }
        if phase == .awaitingResult || phase == .queuedReadback || phase == .verifying,
           payload.prefix(2) == [0x3D, 0x02] {
            guard payload.count == 21 else { return false }
            var received = model
            guard received.update(payload), let result = received.lastPeripheralResult,
                  result.matches(action: action, address: targetAddress) else { return false }
            if case .unknown = result.result {
                fail(String(localized: "The headphones reported an unknown device connection result."))
                return true
            }
            guard result.result.matches(action: action) else { return false }
            if result.result.isSuccess {
                guard phase == .awaitingResult else { return false }
                phase = .queuedReadback
            } else if result.result.isInProgress {
                return phase == .awaitingResult
            } else {
                if result.result == .connectionBusy || result.result == .disconnectionBusy {
                    fail(String(localized: "The headphones are busy. Try changing the device connection again later."))
                } else {
                    fail(action == .connect ? String(localized: "The headphones could not connect to the device.") : String(localized: "The headphones could not disconnect the device."))
                }
            }
            return true
        }
        guard phase == .verifying, readbackOwned, payload.prefix(2) == [0x37, 0x02] else { return false }
        var received = model
        guard received.update(payload), received.canManageDevices,
              let device = received.devices.first(where: { $0.address == targetAddress }),
              device.isConnected == (action == .connect) else {
            fail(String(localized: "The headphones did not confirm the requested device connection. Refresh the device list before trying again."))
            return true
        }
        phase = .complete
        return true
    }

    @discardableResult
    mutating func timeout() -> Bool {
        guard phase == .awaitingResult || phase == .queuedReadback || phase == .verifying else { return false }
        fail(String(localized: "The headphones did not confirm the device connection change in time."))
        return true
    }

    @discardableResult
    mutating func controlLost(session: UInt64) -> Bool {
        guard session == self.session, !isFinished else { return false }
        fail(String(localized: "The control connection was lost before the device connection change was confirmed."))
        return true
    }

    @discardableResult
    mutating func capabilitiesChanged(session: UInt64) -> Bool {
        guard session == self.session, !isFinished else { return false }
        fail(String(localized: "The headphone settings changed before the device connection change was confirmed."))
        return true
    }

    @discardableResult
    private mutating func fail(_ message: String) -> Bool {
        phase = .failed
        failureMessage = message
        return false
    }
}
