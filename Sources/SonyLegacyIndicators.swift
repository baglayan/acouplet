import Foundation

struct SonyLegacyIndicators: Equatable, Sendable {
    enum UpscalingType: UInt8, Sendable {
        case dseeHX = 0, dsee = 1, dseeHXAI = 2

        var title: String {
            switch self {
            case .dseeHX: "DSEE HX"
            case .dsee: "DSEE"
            case .dseeHXAI: "DSEE Extreme"
            }
        }
    }

    enum UpscalingStatus: UInt8, Sendable {
        case off = 0, valid = 1, invalid = 2

        var title: String {
            switch self {
            case .off: String(localized: "Off")
            case .valid: String(localized: "Active")
            case .invalid: String(localized: "Inactive")
            }
        }
    }

    static let codecFunction: UInt8 = 0x13
    static let upscalingFunction: UInt8 = 0x12
    static let connectionStatusFunction: UInt8 = 0x17

    let supportsCodecStatus: Bool
    let supportsUpscalingStatus: Bool
    let supportsConnectionStatus: Bool
    private(set) var codecValue: UInt8?
    private(set) var upscalingTypeValue: UInt8?
    private(set) var upscalingStatusValue: UInt8?
    private(set) var leftConnectionValue: UInt8?
    private(set) var rightConnectionValue: UInt8?

    init(supportedFunctions: Set<UInt8> = []) {
        supportsCodecStatus = supportedFunctions.contains(Self.codecFunction)
        supportsUpscalingStatus = supportedFunctions.contains(Self.upscalingFunction)
        supportsConnectionStatus = supportedFunctions.contains(Self.connectionStatusFunction)
    }

    var queryPayloads: [[UInt8]] {
        (supportsCodecStatus ? [[0x18, 0]] : [])
            + (supportsUpscalingStatus ? [[0x14, 0]] : [])
            + (supportsConnectionStatus ? [[0x24, 1]] : [])
    }

    var codec: SonyAudioCodec? {
        guard let codecValue else { return nil }
        switch codecValue {
        case 0, 1, 2, 0x10, 0x20, 0x21, 0xFF: return SonyAudioCodec(rawValue: codecValue)
        default: return .unknown(codecValue)
        }
    }

    var upscalingType: UpscalingType? { upscalingTypeValue.flatMap(UpscalingType.init(rawValue:)) }
    var upscalingStatus: UpscalingStatus? { upscalingStatusValue.flatMap(UpscalingStatus.init(rawValue:)) }

    var leftConnected: Bool? {
        switch leftConnectionValue {
        case 0: false
        case 1: true
        default: nil
        }
    }

    var rightConnected: Bool? {
        switch rightConnectionValue {
        case 0: false
        case 1: true
        default: nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x18, 0]:
            codecValue = nil
        case [0x14, 0]:
            upscalingTypeValue = nil
            upscalingStatusValue = nil
        case [0x24, 1]:
            leftConnectionValue = nil
            rightConnectionValue = nil
        default:
            break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard frameType == 0x0C, payload.count >= 2 else { return false }
        switch (payload[0], payload[1]) {
        case (0x19, 0), (0x1B, 0):
            guard supportsCodecStatus, payload.count == 3 else { return false }
            codecValue = payload[2]
        case (0x15, 0), (0x17, 0):
            guard supportsUpscalingStatus, payload.count == 4 else { return false }
            upscalingTypeValue = payload[2]
            upscalingStatusValue = payload[3]
        case (0x25, 1), (0x27, 1):
            guard supportsConnectionStatus, payload.count == 4 else { return false }
            leftConnectionValue = payload[2]
            rightConnectionValue = payload[3]
        default:
            return false
        }
        return true
    }
}
