struct SonyLegacyOptimizer: Equatable, Sendable {
    enum Phase: UInt8, Sendable {
        case idle = 0x00, personal = 0x01, pressure = 0x02, optimizing = 0x10, completed = 0x11

        var isActive: Bool { self == .personal || self == .pressure || self == .optimizing }
    }

    struct Capability: Equatable, Sendable {
        let optimizationSeconds: UInt8
        let personalType: UInt8
        let personalSeconds: UInt8
        let pressureType: UInt8
        let pressureSeconds: UInt8

        var isRecognized: Bool { personalType <= 1 && pressureType <= 1 }
    }

    struct Status: Equatable, Sendable {
        let availability: UInt8
        let phaseValue: UInt8

        var available: Bool? {
            switch availability {
            case 0: true
            case 1: false
            default: nil
            }
        }

        var phase: Phase? { Phase(rawValue: phaseValue) }
    }

    struct Measurements: Equatable, Sendable {
        let personalType: UInt8
        let personalValue: UInt8
        let pressureType: UInt8
        let pressureValue: UInt8

        var personalMeasured: Bool? {
            guard personalType == 1 else { return nil }
            switch personalValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }

        var pressureAtmospheres: Double? {
            guard pressureType == 1, (7...10).contains(pressureValue) else { return nil }
            return Double(pressureValue) / 10
        }
    }

    static let startPayload: [UInt8] = [0x84, 1, 0, 1]
    static let cancelPayload: [UInt8] = [0x84, 1, 0, 0]
    static let statusQuery: [UInt8] = [0x82, 1]
    static let measurementsQuery: [UInt8] = [0x86, 1]

    let isSupported: Bool
    private(set) var capability: Capability?
    private(set) var status: Status?
    private(set) var measurements: Measurements?

    init(supportedFunctions: Set<UInt8> = []) {
        isSupported = supportedFunctions.contains(0x81)
    }

    var queryPayloads: [[UInt8]] {
        isSupported ? [[0x80, 1], Self.statusQuery, Self.measurementsQuery] : []
    }

    var canStart: Bool {
        isSupported && capability?.isRecognized == true && status?.available == true
            && (status?.phase == .idle || status?.phase == .completed)
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard isSupported, frameType == 0x0C, payload.count >= 2, payload[1] == 1 else { return false }
        switch payload[0] {
        case 0x81:
            guard payload.count == 7 else { return false }
            capability = Capability(optimizationSeconds: payload[2], personalType: payload[3], personalSeconds: payload[4],
                                    pressureType: payload[5], pressureSeconds: payload[6])
            if let measurements, measurements.personalType != payload[3] || measurements.pressureType != payload[5] {
                self.measurements = nil
            }
        case 0x83, 0x85:
            guard payload.count == 4 else { return false }
            status = Status(availability: payload[2], phaseValue: payload[3])
        case 0x87, 0x89:
            guard payload.count == 6, let capability,
                  payload[2] == capability.personalType, payload[4] == capability.pressureType else { return false }
            measurements = Measurements(personalType: payload[2], personalValue: payload[3],
                                        pressureType: payload[4], pressureValue: payload[5])
        default:
            return false
        }
        return true
    }
}
