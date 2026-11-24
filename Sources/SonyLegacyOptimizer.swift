struct SonyLegacyOptimizer: Equatable, Sendable {
    struct Inquiry: Equatable, Sendable {
        static let legacy = Self(generation: .v1, type: 1)

        let generation: SonyProtocolInfo.Generation
        let type: UInt8

        var capabilityQuery: [UInt8] { [0x80, type] }
        var statusQuery: [UInt8] { [0x82, type] }
        var measurementsQuery: [UInt8] { [0x86, type] }
        var startPayload: [UInt8] { [0x84, type, 0, 1] }
        var cancelPayload: [UInt8] { [0x84, type, 0, 0] }
        var queries: [[UInt8]] { [capabilityQuery, statusQuery, measurementsQuery] }
    }

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

    static let startPayload = Inquiry.legacy.startPayload
    static let cancelPayload = Inquiry.legacy.cancelPayload
    static let statusQuery = Inquiry.legacy.statusQuery
    static let measurementsQuery = Inquiry.legacy.measurementsQuery

    let inquiry: Inquiry?
    private(set) var capability: Capability?
    private(set) var status: Status?
    private(set) var measurements: Measurements?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v1) {
        switch generation {
        case .v1:
            inquiry = supportedFunctions.contains(0x81) ? .legacy : nil
        case .v2:
            inquiry = [UInt8(0x82), 0x81, 0x80].first(where: supportedFunctions.contains)
                .map { Inquiry(generation: .v2, type: $0 - 0x80) }
        }
    }

    init(inquiry: Inquiry) {
        self.inquiry = inquiry
    }

    var isSupported: Bool { inquiry != nil }
    var queryPayloads: [[UInt8]] { inquiry?.queries ?? [] }

    var canStart: Bool {
        isSupported && capability?.isRecognized == true && status?.available == true
            && (status?.phase == .idle || status?.phase == .completed)
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard let inquiry, frameType == 0x0C, payload.count >= 2, payload[1] == inquiry.type else { return false }
        switch payload[0] {
        case 0x81:
            if inquiry.generation == .v2, payload.dropFirst(2).contains(0) { return false }
            let reported: Capability
            switch (inquiry.generation, inquiry.type, payload.count) {
            case (.v1, _, 7):
                reported = Capability(optimizationSeconds: payload[2], personalType: payload[3], personalSeconds: payload[4],
                                      pressureType: payload[5], pressureSeconds: payload[6])
            case (.v2, 0, 5):
                reported = Capability(optimizationSeconds: payload[2], personalType: 1, personalSeconds: payload[3],
                                      pressureType: 1, pressureSeconds: payload[4])
            case (.v2, 1, 4):
                reported = Capability(optimizationSeconds: payload[2], personalType: 1, personalSeconds: payload[3],
                                      pressureType: 0, pressureSeconds: 0)
            case (.v2, 2, 4):
                reported = Capability(optimizationSeconds: payload[2], personalType: 0, personalSeconds: 0,
                                      pressureType: 1, pressureSeconds: payload[3])
            default: return false
            }
            capability = reported
            if let measurements, measurements.personalType != reported.personalType || measurements.pressureType != reported.pressureType {
                self.measurements = nil
            }
        case 0x83, 0x85:
            guard payload.count == 4 else { return false }
            let reported = Status(availability: payload[2], phaseValue: payload[3])
            if inquiry.generation == .v2, reported.available == nil || reported.phase == nil { return false }
            status = reported
        case 0x87, 0x89:
            guard let capability else { return false }
            let reported: Measurements
            switch (inquiry.generation, inquiry.type, payload.count) {
            case (.v1, _, 6):
                guard payload[2] == capability.personalType, payload[4] == capability.pressureType else { return false }
                reported = Measurements(personalType: payload[2], personalValue: payload[3],
                                        pressureType: payload[4], pressureValue: payload[5])
            case (.v2, 0, 4):
                reported = Measurements(personalType: 1, personalValue: payload[2], pressureType: 1, pressureValue: payload[3])
            case (.v2, 1, 3):
                reported = Measurements(personalType: 1, personalValue: payload[2], pressureType: 0, pressureValue: 0)
            case (.v2, 2, 3):
                reported = Measurements(personalType: 0, personalValue: 0, pressureType: 1, pressureValue: payload[2])
            default: return false
            }
            if inquiry.generation == .v2 {
                guard reported.personalValue <= 1, reported.pressureValue == 0 || reported.pressureAtmospheres != nil else { return false }
            }
            measurements = reported
        default:
            return false
        }
        return true
    }
}
