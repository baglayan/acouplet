import Foundation

struct SonyLegacySoundEffect: Equatable, Sendable {
    enum Kind: UInt8, Hashable, Sendable {
        case surround = 1, soundPosition = 2

        var title: String { self == .surround ? String(localized: "Surround (VPT)") : String(localized: "Sound Position") }

        func presetTitle(_ id: UInt8) -> String {
            switch (self, id) {
            case (_, 0): String(localized: "Off")
            case (.surround, 1): String(localized: "Outdoor Stage")
            case (.surround, 2): String(localized: "Arena")
            case (.surround, 3): String(localized: "Concert Hall")
            case (.surround, 4): String(localized: "Club")
            case (.soundPosition, 1): String(localized: "Front Left")
            case (.soundPosition, 2): String(localized: "Front Right")
            case (.soundPosition, 3): String(localized: "Front")
            case (.soundPosition, 0x11): String(localized: "Rear Left")
            case (.soundPosition, 0x12): String(localized: "Rear Right")
            default: String(format: String(localized: "Preset %02X"), id)
            }
        }

        func recognizesPreset(_ id: UInt8) -> Bool {
            self == .surround ? id <= 0x0F : [0, 1, 2, 3, 0x11, 0x12].contains(id)
        }
    }

    struct Preset: Equatable, Identifiable, Sendable {
        let id: UInt8
        let name: String
    }

    let kind: Kind
    let isSupported: Bool
    private(set) var presets: [Preset]?
    private(set) var positionType: UInt8?
    private(set) var status: UInt8?
    private(set) var presetID: UInt8?

    init(kind: Kind, supportedFunctions: Set<UInt8> = []) {
        self.kind = kind
        isSupported = supportedFunctions.contains(0x40 + kind.rawValue)
    }

    var capabilityQuery: [UInt8] { [0x40, kind.rawValue, 1] }
    var statusQuery: [UInt8] { [0x42, kind.rawValue] }
    var parameterQuery: [UInt8] { [0x46, kind.rawValue] }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return (presets == nil ? [capabilityQuery] : []) + (status == nil ? [statusQuery] : []) + [parameterQuery]
    }

    var available: Bool? {
        switch status {
        case 0: true
        case 1: false
        default: nil
        }
    }

    var selectablePresets: [Preset] { (presets ?? []).filter { kind.recognizesPreset($0.id) } }
    var selectedPreset: Preset? { presets?.first { $0.id == presetID } }
    var selectedTitle: String? { presetID.map { selectedPreset?.name ?? kind.presetTitle($0) } }

    var canSet: Bool {
        isSupported && available == true && presetID != nil && !selectablePresets.isEmpty
    }

    func setPayload(_ preset: UInt8) -> [UInt8]? {
        guard canSet, selectablePresets.contains(where: { $0.id == preset }) else { return nil }
        return [0x48, kind.rawValue, preset]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        payload.count == 3 && setPayload(payload[2]) == payload
    }

    func confirmsSetPayload(_ payload: [UInt8], response: [UInt8]) -> Bool {
        payload.count == 3 && payload.prefix(2) == [0x48, kind.rawValue]
            && response.count == 3 && [0x47, 0x49].contains(response[0])
            && response.dropFirst() == payload.dropFirst()
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard isSupported, frameType == 0x0C, payload.count >= 3, payload[1] == kind.rawValue else { return false }
        switch payload[0] {
        case 0x41:
            if kind == .soundPosition {
                guard payload.count == 3 else { return false }
                positionType = payload[2]
                presets = positionType == 1 ? [0, 1, 2, 3, 0x11, 0x12].map {
                    Preset(id: $0, name: kind.presetTitle($0))
                } : []
            } else {
                var offset = 3
                var decoded: [Preset] = []
                for _ in 0..<Int(payload[2]) {
                    guard offset + 2 <= payload.count, payload[offset + 1] <= 128 else { return false }
                    let id = payload[offset]
                    let end = offset + 2 + Int(payload[offset + 1])
                    guard end <= payload.count, !decoded.contains(where: { $0.id == id }),
                          let name = String(bytes: payload[(offset + 2)..<end], encoding: .utf8) else { return false }
                    decoded.append(Preset(id: id, name: name.isEmpty ? kind.presetTitle(id) : name))
                    offset = end
                }
                guard offset == payload.count else { return false }
                presets = decoded
            }
        case 0x43, 0x45:
            guard payload.count == 3 else { return false }
            status = payload[2]
        case 0x47, 0x49:
            guard payload.count == 3 else { return false }
            presetID = payload[2]
        default:
            return false
        }
        return true
    }
}
