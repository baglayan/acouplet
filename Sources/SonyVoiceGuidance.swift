import Foundation

struct SonyVoiceGuidance: Equatable, Sendable {
    static let volumeRange = -2...2

    let generation: SonyProtocolInfo.Generation
    let supportsGuidance: Bool
    private(set) var supportsOnOffSwitch: Bool?
    private(set) var supportedLanguages: [UInt8]?
    private(set) var available: Bool?
    private(set) var enabled: Bool?
    private(set) var currentLanguage: UInt8?
    private(set) var volume: Int?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.generation = generation
        supportsGuidance = supportedFunctions.contains(generation == .v1 ? 0x39 : 0x42)
    }

    var supportsVolume: Bool { supportsGuidance && generation == .v2 }

    var parameterQueryPayload: [UInt8] { generation == .v1 ? [0x46, 1, 1] : [0x46, 1] }

    var volumeAvailable: Bool? {
        guard supportsVolume else { return nil }
        switch supportsOnOffSwitch {
        case .some(true): return available
        case .some(false): return true
        case nil: return nil
        }
    }

    var queryPayloads: [[UInt8]] {
        guard supportsGuidance else { return [] }
        if generation == .v1 {
            return (supportedLanguages == nil ? [[0x40, 1]] : [])
                + (supportsOnOffSwitch == true ? [[0x42, 1, 1], parameterQueryPayload] : [])
        }
        return (supportedLanguages == nil ? [[0x40, 0x01]] : [])
            + [[0x42, 0x01, 0x00], [0x46, 0x01], [0x46, 0x20]]
    }

    func setEnabledPayload(_ enabled: Bool) -> [UInt8]? {
        guard supportsGuidance, supportsOnOffSwitch == true, available == true,
              self.enabled != nil else { return nil }
        if generation == .v1 { return [0x48, 1, 1, enabled ? 1 : 0] }
        return [0x48, 0x01, enabled ? 0x00 : 0x01]
    }

    func setVolumePayload(_ volume: Int) -> [UInt8]? {
        guard supportsVolume, supportedLanguages != nil, volumeAvailable == true,
              self.volume != nil, Self.volumeRange.contains(volume) else { return nil }
        return [0x48, 0x20, UInt8(bitPattern: Int8(volume)), 0x01]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x40, 0x01]:
            supportsOnOffSwitch = nil
            supportedLanguages = nil
        case [0x42, 0x01, 0x00], [0x42, 0x01, 0x01]: available = nil
        case [0x46, 0x01, 0x01]: enabled = nil
        case [0x46, 0x01]:
            enabled = nil
            currentLanguage = nil
        case [0x46, 0x20]: volume = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard supportsGuidance, payload.count >= 2 else { return false }
        if generation == .v1 {
            switch (payload[0], payload[1]) {
            case (0x41, 1):
                guard payload.count >= 4,
                      (payload[3] == 0 && payload.count == 4)
                        || (payload[3] == 1 && payload.count >= 5 && payload.count == 5 + Int(payload[4])) else { return false }
                supportsOnOffSwitch = payload[2] <= 1 ? payload[2] == 1 : nil
                supportedLanguages = payload[3] == 0 ? [] : Array(payload.dropFirst(5))
            case (0x43, 1), (0x45, 1):
                guard payload.count == 4, payload[2] == 1 else { return false }
                available = payload[3] <= 1 ? payload[3] == 0 : nil
            case (0x47, 1), (0x49, 1):
                guard payload.count == 4, payload[2] == 1 else { return false }
                enabled = payload[3] <= 1 ? payload[3] == 1 : nil
            default: return false
            }
            return true
        }
        switch (payload[0], payload[1]) {
        case (0x41, 0x01):
            guard payload.count >= 8, payload.count == 8 + Int(payload[7]) else { return false }
            supportsOnOffSwitch = payload[6] <= 1 ? payload[6] == 1 : nil
            supportedLanguages = Array(payload.dropFirst(8))
        case (0x43, 0x01), (0x45, 0x01):
            guard payload.count == 4, payload[2] == 0 else { return false }
            available = payload[3] <= 1 ? payload[3] == 0 : nil
        case (0x47, 0x01):
            guard payload.count == 4 else { return false }
            enabled = payload[2] <= 1 ? payload[2] == 0 : nil
            currentLanguage = payload[3]
        case (0x47, 0x20):
            guard payload.count == 3 else { return false }
            let value = Int(Int8(bitPattern: payload[2]))
            volume = Self.volumeRange.contains(value) ? value : nil
        default:
            return false
        }
        return true
    }
}
