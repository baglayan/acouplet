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
    let inventoryInquiryType: UInt8
    private let actionPayload: [UInt8]
    private(set) var phase = Phase.queued
    private(set) var failureMessage: String?

    init?(action: SonyPeripheralAction, targetAddress: String, model: SonyMultipoint, session: UInt64, requestID: UUID = UUID()) {
        guard action != .unpair || model.supportsLegacyInventory, let inquiry = model.deviceInventoryInquiryType,
              let payload = model.peripheralActionPayload(action, address: targetAddress) else { return nil }
        self.requestID = requestID
        self.session = session
        self.action = action
        self.targetAddress = String(decoding: payload.suffix(17), as: UTF8.self)
        inventoryInquiryType = inquiry
        actionPayload = payload
    }

    var expectedPayload: [UInt8]? {
        switch phase {
        case .queued: actionPayload
        case .queuedReadback: [0x36, inventoryInquiryType]
        default: nil
        }
    }

    var isFinished: Bool { phase == .complete || phase == .failed }

    @discardableResult
    mutating func validateForTransmission(model: SonyMultipoint, session: UInt64, unavailableReason: String? = nil) -> Bool {
        guard session == self.session, let payload = expectedPayload else { return false }
        if phase == .queuedReadback {
            guard model.deviceInventoryInquiryType == inventoryInquiryType else { return fail(String(localized: "Device information is no longer available.")) }
        } else {
            if let unavailableReason { return fail(unavailableReason) }
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
           payload.prefix(2) == [0x3D, inventoryInquiryType] {
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
                if result.result == .connectionBusy || result.result == .disconnectionBusy || result.result == .unpairingBusy {
                    fail(String(localized: "The headphones are busy. Try changing the device connection again later."))
                } else {
                    let message = switch action {
                    case .connect: String(localized: "The headphones could not connect to the device.")
                    case .disconnect: String(localized: "The headphones could not disconnect the device.")
                    case .unpair: String(localized: "The headphones could not forget the device.")
                    }
                    fail(message)
                }
            }
            return true
        }
        guard phase == .verifying, readbackOwned, payload.prefix(2) == [0x37, inventoryInquiryType] else { return false }
        var received = model
        let parsed = received.update(payload)
        let device = received.devices.first { $0.address == targetAddress }
        guard parsed, received.canManageDevices,
              action == .unpair ? device == nil : device?.isConnected == (action == .connect) else {
            fail(String(localized: "The headphones did not confirm the requested device connection. Refresh the device list before trying again."))
            return true
        }
        phase = .complete
        return true
    }

    mutating func repeatReadback() {
        if phase == .verifying { phase = .queuedReadback }
    }

    mutating func inventoryReadFailed() {
        guard phase == .queued else { return }
        fail(String(localized: "The device list was not received. Reconnect the headphones to try again."))
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
