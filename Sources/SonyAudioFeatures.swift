import Foundation

enum SonyAudioCodec: Equatable, Sendable {
    case unsettled, sbc, aac, ldac, aptX, aptXHD, lc3, other
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .unsettled
        case 0x01: .sbc
        case 0x02: .aac
        case 0x10: .ldac
        case 0x20: .aptX
        case 0x21: .aptXHD
        case 0x30: .lc3
        case 0xFF: .other
        default: .unknown(rawValue)
        }
    }

    var title: String {
        switch self {
        case .unsettled: String(localized: "Unknown")
        case .sbc: "SBC"
        case .aac: "AAC"
        case .ldac: "LDAC"
        case .aptX: "aptX"
        case .aptXHD: "aptX HD"
        case .lc3: "LC3"
        case .other: String(localized: "Other")
        case .unknown: String(localized: "Unknown")
        }
    }
}

enum SonyDSEEType: UInt8, Sendable {
    case hx = 0x00
    case dsee = 0x01
    case extreme = 0x02
    case ultimate = 0x03

    var title: String {
        switch self {
        case .hx: "DSEE HX"
        case .dsee: "DSEE"
        case .extreme: "DSEE Extreme"
        case .ultimate: "DSEE Ultimate"
        }
    }
}

enum SonyDSEEMode: Hashable, CaseIterable, Identifiable, Sendable {
    case off, automatic
    case unknown(UInt8)

    static let allCases: [Self] = [.off, .automatic]

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .off
        case 0x01: .automatic
        default: .unknown(rawValue)
        }
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .automatic: String(localized: "Auto")
        case .unknown: String(localized: "Unknown")
        }
    }

    var sonyValue: UInt8? {
        switch self {
        case .off: 0x00
        case .automatic: 0x01
        case .unknown: nil
        }
    }
}

enum SonyConnectionMode: Hashable, Sendable {
    case soundQuality, stableConnection, lowLatency
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .soundQuality
        case 0x01: .stableConnection
        case 0x02: .lowLatency
        default: .unknown(rawValue)
        }
    }

    var title: String {
        switch self {
        case .soundQuality: String(localized: "Sound Quality")
        case .stableConnection: String(localized: "Stable Connection")
        case .lowLatency: String(localized: "Low Latency")
        case .unknown: String(localized: "Unknown")
        }
    }

    var sonyValue: UInt8? {
        switch self {
        case .soundQuality: 0x00
        case .stableConnection: 0x01
        case .lowLatency: 0x02
        case .unknown: nil
        }
    }
}

enum SonyLDACExclusiveFeature: Equatable, Sendable {
    case gattConnectable
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .gattConnectable
        default: .unknown(rawValue)
        }
    }
}

enum SonyConnectionStream: Equatable, Sendable {
    case none, leAudio, classicAudio
    case unknown(UInt8)

    init(rawValue: UInt8) {
        self = switch rawValue {
        case 0x00: .none
        case 0x01: .leAudio
        case 0x02: .classicAudio
        default: .unknown(rawValue)
        }
    }
}

struct SonyAudioFeatures: Equatable, Sendable {
    static let connectionStatusFunction: UInt8 = 0x11
    static let codecFunction: UInt8 = 0x12
    static let dseeFunction: UInt8 = 0xE2
    static let connectionModeFunction: UInt8 = 0xE7

    let supportsConnectionStatus: Bool
    let supportsCodecStatus: Bool
    let supportsDSEE: Bool
    let supportsConnectionMode: Bool
    private(set) var codec: SonyAudioCodec?
    private(set) var dseeType: SonyDSEEType?
    private(set) var dseeAvailable: Bool?
    private(set) var dseeMode: SonyDSEEMode?
    private(set) var supportedConnectionModes: [SonyConnectionMode]?
    private(set) var connectionModeLDACExclusions: [SonyLDACExclusiveFeature]?
    private(set) var connectionModeStatus: UInt8?
    private(set) var connectionModeAdditionalStatus: UInt8?
    private(set) var connectionMode: SonyConnectionMode?
    private(set) var lastConnectionModeSwitchingStream: SonyConnectionStream?
    private(set) var leftConnected: Bool?
    private(set) var rightConnected: Bool?

    init(supportedFunctions: Set<UInt8> = []) {
        supportsConnectionStatus = supportedFunctions.contains(Self.connectionStatusFunction)
        supportsCodecStatus = supportedFunctions.contains(Self.codecFunction)
        supportsDSEE = supportedFunctions.contains(Self.dseeFunction)
        supportsConnectionMode = supportedFunctions.contains(Self.connectionModeFunction)
    }

    var queryPayloads: [[UInt8]] {
        (supportsConnectionStatus ? [[0x12, 0x01]] : [])
            + (supportsCodecStatus ? [[0x12, 0x02]] : [])
            + (supportsDSEE ? [[0xE0, 0x01], [0xE2, 0x01], [0xE6, 0x01]] : [])
            + (supportsConnectionMode ? [[0xE0, 0x05], [0xE2, 0x05], [0xE6, 0x05]] : [])
    }

    var connectionModeAvailable: Bool? {
        switch connectionModeStatus {
        case 0x00: true
        case 0x01: false
        default: nil
        }
    }

    func dseeSetPayload(_ mode: SonyDSEEMode) -> [UInt8]? {
        guard supportsDSEE, dseeAvailable == true,
              dseeMode?.sonyValue != nil, let value = mode.sonyValue else { return nil }
        return [0xE8, 0x01, value]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3 else { return false }
        switch (payload[0], payload[1]) {
        case (0x13, 0x01), (0x15, 0x01):
            guard supportsConnectionStatus, payload.count == 4 else { return false }
            leftConnected = payload[2] <= 1 ? payload[2] == 1 : nil
            rightConnected = payload[3] <= 1 ? payload[3] == 1 : nil
        case (0x13, 0x02), (0x15, 0x02):
            guard supportsCodecStatus, payload.count == 3 else { return false }
            codec = SonyAudioCodec(rawValue: payload[2])
        case (0xE1, 0x01):
            guard supportsDSEE, payload.count == 3 else { return false }
            dseeType = SonyDSEEType(rawValue: payload[2])
        case (0xE3, 0x01), (0xE5, 0x01):
            guard supportsDSEE, payload.count == 3 else { return false }
            dseeAvailable = payload[2] <= 1 ? payload[2] == 0 : nil
        case (0xE7, 0x01), (0xE9, 0x01):
            guard supportsDSEE, payload.count == 3 else { return false }
            dseeMode = SonyDSEEMode(rawValue: payload[2])
        case (0xE1, 0x05):
            guard supportsConnectionMode, payload.count >= 6 else { return false }
            let modeCount = Int(payload[2])
            let exclusionCountIndex = 3 + modeCount
            guard modeCount >= 2, exclusionCountIndex < payload.count else { return false }
            let exclusionCount = Int(payload[exclusionCountIndex])
            guard payload.count == exclusionCountIndex + 1 + exclusionCount else { return false }
            supportedConnectionModes = payload[3..<exclusionCountIndex].map(SonyConnectionMode.init(rawValue:))
            connectionModeLDACExclusions = payload.suffix(exclusionCount).map(SonyLDACExclusiveFeature.init(rawValue:))
        case (0xE3, 0x05), (0xE5, 0x05):
            guard supportsConnectionMode, payload.count == 4 else { return false }
            connectionModeStatus = payload[2]
            connectionModeAdditionalStatus = payload[3]
        case (0xE7, 0x05):
            guard supportsConnectionMode, payload.count == 3 else { return false }
            connectionMode = SonyConnectionMode(rawValue: payload[2])
        case (0xE9, 0x05):
            guard supportsConnectionMode, payload.count == 4 else { return false }
            connectionMode = SonyConnectionMode(rawValue: payload[2])
            lastConnectionModeSwitchingStream = SonyConnectionStream(rawValue: payload[3])
        default:
            return false
        }
        return true
    }
}
