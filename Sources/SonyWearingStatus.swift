struct SonyWearingStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case bothWorn, leftRemoved, rightRemoved, bothRemoved
        case unknown(UInt8)

        init(rawValue: UInt8) {
            self = switch rawValue {
            case 0x00: .bothWorn
            case 0x02: .leftRemoved
            case 0x03: .rightRemoved
            case 0x04: .bothRemoved
            default: .unknown(rawValue)
            }
        }
    }

    static let queryPayload: [UInt8] = [0xF2, 0x00]

    let isSupported: Bool
    private(set) var state: State?

    init(supportedFunctions: Set<UInt8> = []) {
        isSupported = supportedFunctions.contains(0xF0)
    }

    var queryPayloads: [[UInt8]] { isSupported ? [Self.queryPayload] : [] }

    var leftWorn: Bool? {
        switch state {
        case .bothWorn, .rightRemoved: true
        case .leftRemoved, .bothRemoved: false
        default: nil
        }
    }

    var rightWorn: Bool? {
        switch state {
        case .bothWorn, .leftRemoved: true
        case .rightRemoved, .bothRemoved: false
        default: nil
        }
    }

    mutating func invalidate() {
        state = nil
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0E) -> Bool {
        guard isSupported, frameType == 0x0E, payload.count >= 2,
              payload[1] == 0x00, payload[0] == 0xF3 || payload[0] == 0xF5 else { return false }
        guard payload.count == 3 else {
            invalidate()
            return false
        }
        state = State(rawValue: payload[2])
        return true
    }
}
