import Foundation

struct SonyEqualizerBand: Codable, Equatable, Hashable, Sendable {
    let informationType: UInt8
    let value: UInt16

    static let clearBass = Self(informationType: 0x10, value: 1)
    static let legacy: [Self] = [.clearBass] + [400, 1_000, 2_500, 6_300, 16_000].map {
        Self(informationType: 1, value: $0)
    }
    static let tenBand: [Self] = [31, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000].map {
        Self(informationType: 1, value: $0)
    }

    static func reportedLayout(_ payload: [UInt8]) -> [Self]? {
        guard payload.count >= 3, payload.count == 3 + Int(payload[2]) * 3 else { return nil }
        var bands: [Self] = []
        for index in stride(from: 3, to: payload.count, by: 3) {
            let type = payload[index]
            guard [0, 1, 2, 0x10].contains(type) else { return nil }
            bands.append(Self(informationType: type, value: UInt16(payload[index + 1]) << 8 | UInt16(payload[index + 2])))
        }
        return bands
    }

    var frequency: Int? {
        switch informationType {
        case 1: Int(value)
        case 2: Int(value) * 1_000
        default: nil
        }
    }

    var title: String {
        if self == .clearBass { return String(localized: "Clear Bass") }
        guard let frequency else { return String(localized: "Unknown Band") }
        return frequency >= 1_000
            ? "\((Double(frequency) / 1_000).formatted()) kHz"
            : "\(frequency) Hz"
    }
}

struct SonyEqualizerPreset: Equatable, Identifiable, Sendable {
    let id: UInt8
    let name: String?

    var title: String {
        if id < 0xA0, let preset = EqualizerPreset(rawValue: id) { return preset.title }
        return name ?? EqualizerPreset(rawValue: id)?.title ?? String(format: String(localized: "Preset %02X"), id)
    }
}

struct SonyEqualizerCapabilities: Equatable, Sendable {
    let bandCount: UInt8
    let levelSteps: UInt8
    let presets: [SonyEqualizerPreset]
    let ultAdditionalSteps: UInt8?

    init?(payload: [UInt8], generation: SonyProtocolInfo.Generation = .v2) {
        guard payload.count >= 5, payload[0] == 0x51,
              (generation == .v1 ? [1, 3] : [0, 2, 3, 4]).contains(payload[1]) else { return nil }
        let hasULT = generation == .v2 && payload[1] == 3
        let countIndex = hasULT ? 5 : 4
        guard payload.count > countIndex else { return nil }
        var offset = countIndex + 1
        var presets: [SonyEqualizerPreset] = []
        for _ in 0..<Int(payload[countIndex]) {
            guard offset + 2 <= payload.count else { return nil }
            if generation == .v1, payload[offset + 1] > 128 { return nil }
            let end = offset + 2 + Int(payload[offset + 1])
            guard end <= payload.count,
                  let name = String(bytes: payload[(offset + 2)..<end], encoding: .utf8) else { return nil }
            presets.append(SonyEqualizerPreset(id: payload[offset], name: name.isEmpty ? nil : name))
            offset = end
        }
        guard offset == payload.count else { return nil }
        bandCount = payload[2]
        levelSteps = payload[3]
        self.presets = presets
        ultAdditionalSteps = hasULT ? payload[4] : nil
    }
}

struct SonyBassBoost: Equatable, Sendable {
    let inquiryType: UInt8?
    private(set) var range: ClosedRange<Int>?
    private(set) var available: Bool?
    private var reportedLevel: Int?

    init(supportedFunctions: Set<UInt8>, generation: SonyProtocolInfo.Generation) {
        if generation == .v1 { inquiryType = supportedFunctions.contains(0x52) ? 2 : nil }
        else { inquiryType = supportedFunctions.contains(0x51) ? 1 : nil }
    }

    var level: Int? { reportedLevel.flatMap { range?.contains($0) == true ? $0 : nil } }

    var queryPayloads: [[UInt8]] {
        guard let inquiryType else { return [] }
        return [[0x50, inquiryType, 1], [0x52, inquiryType], [0x56, inquiryType]]
    }

    func setPayload(_ value: Int) -> [UInt8]? {
        guard let inquiryType, available == true, level != nil, range?.contains(value) == true else { return nil }
        return [0x58, inquiryType, UInt8(bitPattern: Int8(value))]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        guard queryPayloads.contains(query) else { return }
        switch query[0] {
        case 0x50: range = nil
        case 0x52: available = nil
        case 0x56: reportedLevel = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x51:
            guard payload.count == 4 else { return false }
            let lower = Int(Int8(bitPattern: payload[2])), upper = Int(Int8(bitPattern: payload[3]))
            guard lower >= -127, lower <= upper else { return false }
            range = lower...upper
        case 0x53, 0x55:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        case 0x57, 0x59:
            guard payload.count == 3, payload[2] != 0x80 else { return false }
            reportedLevel = Int(Int8(bitPattern: payload[2]))
        default:
            return false
        }
        return true
    }
}

struct SonyLRBalanceCorrection: Equatable, Sendable {
    enum Mode: UInt8, Sendable { case on, off, offNotInitialized, outOfRange = 0xFF }

    static let function: UInt8 = 0x5A
    static let capabilityQuery: [UInt8] = [0x50, 0x51, 0x01]
    static let statusQuery: [UInt8] = [0x52, 0x50]
    static let adjustmentStatusQuery: [UInt8] = [0x52, 0x51]
    static let parameterQuery: [UInt8] = [0x56, 0x50]

    let isSupported: Bool
    private(set) var adjustmentCapability: [UInt8]?
    private(set) var available: Bool?
    private(set) var adjustmentAvailable: Bool?
    private(set) var mode: Mode?

    var queryPayloads: [[UInt8]] {
        isSupported ? [Self.capabilityQuery, Self.statusQuery, Self.adjustmentStatusQuery, Self.parameterQuery] : []
    }

    var canSet: Bool {
        adjustmentCapability != nil && available == true && (mode == .on || mode == .off)
    }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard canSet else { return nil }
        return [0x58, 0x50, enabled ? Mode.on.rawValue : Mode.off.rawValue]
    }

    func query(for payload: [UInt8]) -> [UInt8]? {
        guard isSupported, payload.count >= 2 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x51, 0x51): return Self.capabilityQuery
        case (0x53, 0x50), (0x55, 0x50): return Self.statusQuery
        case (0x53, 0x51), (0x55, 0x51): return Self.adjustmentStatusQuery
        case (0x57, 0x50), (0x59, 0x50): return Self.parameterQuery
        default: return nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery: adjustmentCapability = nil
        case Self.statusQuery: available = nil
        case Self.adjustmentStatusQuery: adjustmentAvailable = nil
        case Self.parameterQuery: mode = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        switch query(for: payload) {
        case Self.capabilityQuery:
            guard payload.count == 5 else { return false }
            adjustmentCapability = Array(payload.dropFirst(2))
        case Self.statusQuery:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        case Self.adjustmentStatusQuery:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            adjustmentAvailable = payload[2] == 0
        case Self.parameterQuery:
            guard payload.count == 3, let mode = Mode(rawValue: payload[2]) else { return false }
            self.mode = mode
        default: return false
        }
        return true
    }
}

struct SonyTurnKeyEqualizer: Equatable, Sendable {
    enum Limit: UInt8, Sendable { case maximum, spaceAvailable, unknown = 0xFF }
    enum Result: UInt8, Sendable { case success, notSupported, rejected, unknown = 0xFF }

    static let capabilityQuery: [UInt8] = [0x50, 0x37, 1]
    static let limitQuery: [UInt8] = [0x52, 0x37]

    let supportsImport: Bool
    let supportsManagement: Bool
    private(set) var deletablePresets: [UInt8]?
    private(set) var limit: Limit?
    var lastCompletedOperation: UInt8?

    var queryPayloads: [[UInt8]] { supportsManagement ? [Self.capabilityQuery, Self.limitQuery] : [] }
    var canImport: Bool { supportsImport && (!supportsManagement || limit == .spaceAvailable) }

    func importPayload(_ code: String) -> [UInt8]? {
        let text = code.filter { !$0.isWhitespace }
        guard canImport, text.utf8.count <= 340,
              let data = Data(base64Encoded: text), !data.isEmpty, data.count <= 255 else { return nil }
        return [0x58, 0x32, UInt8(data.count)] + data
    }

    func deletePayload(_ preset: UInt8) -> [UInt8]? {
        guard preset != 0xFF, deletablePresets?.contains(preset) == true else { return nil }
        return [0x58, 0x37, preset]
    }

    func acceptsWrite(_ payload: [UInt8]) -> Bool {
        switch payload.prefix(2) {
        case [0x58, 0x32]: canImport && payload.count > 3 && Int(payload[2]) == payload.count - 3
        case [0x58, 0x37]: payload.count == 3 && deletePayload(payload[2]) == payload
        default: false
        }
    }

    func result(_ payload: [UInt8]) -> Result? {
        guard payload.count == 3, payload[0] == 0x59,
              payload[1] == 0x32 && supportsImport || payload[1] == 0x37 && supportsManagement else { return nil }
        guard let result = Result(rawValue: payload[2]), payload[1] != 0x32 || result != .unknown else { return nil }
        return result
    }

    func isDeletionAlert(_ alert: SonyConnectionAlert) -> Bool {
        supportsManagement && alert.format == .fixed && alert.messageID == 0x96
    }

    func query(for payload: [UInt8]) -> [UInt8]? {
        guard supportsManagement else { return nil }
        switch payload.prefix(2) {
        case [0x51, 0x37]: return Self.capabilityQuery
        case [0x53, 0x37]: return Self.limitQuery
        default: return nil
        }
    }

    mutating func invalidate(_ query: [UInt8]) {
        if query == Self.capabilityQuery { deletablePresets = nil }
        if query == Self.limitQuery { limit = nil }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3 else { return false }
        switch query(for: payload) {
        case Self.capabilityQuery:
            guard payload.count == 3 + Int(payload[2]) else { return false }
            let presets = Array(payload.dropFirst(3))
            guard presets.allSatisfy({ (0...0x23).contains($0) || (0x30...0x33).contains($0)
                || (0xA0...0xA5).contains($0) || (0xB0...0xBB).contains($0) || $0 == 0xFF }) else { return false }
            deletablePresets = presets
        case Self.limitQuery:
            guard payload.count == 3, let limit = Limit(rawValue: payload[2]) else { return false }
            self.limit = limit
        default: return false
        }
        return true
    }
}

struct SonyULTSoundEffectAssignment: Equatable, Sendable {
    enum Effect: UInt8, Identifiable, Sendable {
        case off, ult, ult1, ult2, custom, flat, live

        var id: Self { self }

        var title: String {
            switch self {
            case .off: String(localized: "Off")
            case .ult: "ULT"
            case .ult1: "ULT 1"
            case .ult2: "ULT 2"
            case .custom: String(localized: "Custom")
            case .flat: String(localized: "Flat")
            case .live: String(localized: "Live")
            }
        }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: Effect
        var enabled: Bool
    }

    static let capabilityQuery: [UInt8] = [0x50, 0x40]
    static let parameterQuery: [UInt8] = [0x56, 0x40]
    let isSupported: Bool
    private(set) var selectionCount: ClosedRange<Int>?
    private(set) var entries: [Entry]?

    var queryPayloads: [[UInt8]] { isSupported ? [Self.capabilityQuery, Self.parameterQuery] : [] }

    func setPayload(_ effect: Effect, enabled: Bool) -> [UInt8]? {
        guard var entries, let selectionCount, let index = entries.firstIndex(where: { $0.id == effect }),
              entries[index].enabled != enabled else { return nil }
        entries[index].enabled = enabled
        guard selectionCount.contains(entries.filter(\.enabled).count) else { return nil }
        return [0x58, 0x40, UInt8(entries.count)] + entries.flatMap { [$0.id.rawValue, $0.enabled ? 0 : 1] }
    }

    func query(for payload: [UInt8]) -> [UInt8]? {
        guard isSupported else { return nil }
        switch payload.prefix(2) {
        case [0x51, 0x40]: return Self.capabilityQuery
        case [0x57, 0x40], [0x59, 0x40]: return Self.parameterQuery
        default: return nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        if query == Self.capabilityQuery { selectionCount = nil }
        if query == Self.parameterQuery { entries = nil }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3 else { return false }
        switch query(for: payload) {
        case Self.capabilityQuery:
            guard payload.count == 4, payload[2] <= payload[3] else { return false }
            selectionCount = Int(payload[2])...Int(payload[3])
        case Self.parameterQuery:
            guard payload.count == 3 + Int(payload[2]) * 2 else { return false }
            var entries: [Entry] = []
            for index in stride(from: 3, to: payload.count, by: 2) {
                guard let effect = Effect(rawValue: payload[index]), payload[index + 1] <= 1,
                      !entries.contains(where: { $0.id == effect }) else { return false }
                entries.append(Entry(id: effect, enabled: payload[index + 1] == 0))
            }
            self.entries = entries
        default: return false
        }
        return true
    }
}

struct SonySoundEffect: Equatable, Sendable {
    typealias Effect = SonyULTSoundEffectAssignment.Effect

    static let capabilityQuery: [UInt8] = [0x50, 0x30, 1]
    static let statusQuery: [UInt8] = [0x52, 0x30]
    static let parameterQuery: [UInt8] = [0x56, 0x30]
    let isSupported: Bool
    private(set) var modeCodes: [UInt8]?
    private(set) var exclusiveFunctions: [UInt8]?
    private(set) var available: Bool?
    private(set) var modeAvailability: [UInt8: Bool]?
    private(set) var selectedCode: UInt8?

    var queryPayloads: [[UInt8]] {
        isSupported ? [Self.capabilityQuery, Self.statusQuery, Self.parameterQuery] : []
    }

    var modes: [Effect]? { modeCodes?.filter { $0 <= Effect.custom.rawValue }.compactMap(Effect.init(rawValue:)) }

    func canSelect(_ effect: Effect) -> Bool {
        available == true && modeAvailability?[effect.rawValue] == true && modes?.contains(effect) == true
    }

    func setPayload(_ effect: Effect) -> [UInt8]? {
        guard let selectedCode, selectedCode != effect.rawValue, canSelect(effect) else { return nil }
        return [0x58, 0x30, effect.rawValue]
    }

    func query(for payload: [UInt8]) -> [UInt8]? {
        guard isSupported else { return nil }
        switch payload.prefix(2) {
        case [0x51, 0x30]: return Self.capabilityQuery
        case [0x53, 0x30], [0x55, 0x30]: return Self.statusQuery
        case [0x57, 0x30], [0x59, 0x30]: return Self.parameterQuery
        default: return nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery:
            modeCodes = nil
            exclusiveFunctions = nil
        case Self.statusQuery:
            available = nil
            modeAvailability = nil
        case Self.parameterQuery: selectedCode = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3 else { return false }
        switch query(for: payload) {
        case Self.capabilityQuery:
            let end = 3 + Int(payload[2])
            guard end < payload.count, payload.count == end + 1 + Int(payload[end]),
                  payload[3..<end].allSatisfy(Self.isKnownMode),
                  payload[(end + 1)...].allSatisfy({ $0 == 0 }) else { return false }
            let modes = Array(payload[3..<end])
            guard Set(modes).count == modes.count else { return false }
            modeCodes = modes
            exclusiveFunctions = Array(payload[(end + 1)...])
        case Self.statusQuery:
            guard payload.count >= 4, payload[2] <= 1, payload.count == 4 + Int(payload[3]) * 2 else { return false }
            var states: [UInt8: Bool] = [:]
            for index in stride(from: 4, to: payload.count, by: 2) {
                let mode = payload[index]
                guard Self.isKnownMode(mode), payload[index + 1] <= 1, states[mode] == nil else { return false }
                states[mode] = payload[index + 1] == 0
            }
            available = payload[2] == 0
            modeAvailability = states
        case Self.parameterQuery:
            guard payload.count == 3, Self.isKnownMode(payload[2]) else { return false }
            selectedCode = payload[2]
        default: return false
        }
        return true
    }

    private static func isKnownMode(_ code: UInt8) -> Bool {
        Effect(rawValue: code) != nil || code == 0xFF
    }
}

struct SonyCustomEQ: Equatable, Sendable {
    static let capabilityQuery: [UInt8] = [0x50, 0x31, 1]
    static let statusQuery: [UInt8] = [0x52, 0x31]
    static let bandsQuery: [UInt8] = [0x5A, 0x31]
    static let parameterQuery: [UInt8] = [0x56, 0x31]
    let isSupported: Bool
    private(set) var bandCount: Int?
    private(set) var levelSteps: Int?
    private(set) var available: Bool?
    private(set) var bands: [SonyEqualizerBand]?
    private(set) var values: [UInt8]?

    var queryPayloads: [[UInt8]] {
        isSupported ? [Self.capabilityQuery, Self.statusQuery, Self.parameterQuery, Self.bandsQuery] : []
    }

    var editableValues: [UInt8]? {
        guard let values, let bands, let levelSteps, levelSteps > 1, !values.isEmpty,
              bandCount == values.count, bands.count == values.count,
              values.allSatisfy({ Int($0) < levelSteps }) else { return nil }
        return values
    }

    func setPayload(_ values: [UInt8]) -> [UInt8]? {
        guard available == true, let previous = editableValues, values != previous,
              let levelSteps, values.count == previous.count,
              values.allSatisfy({ Int($0) < levelSteps }) else { return nil }
        return [0x58, 0x31, UInt8(values.count)] + values
    }

    func query(for payload: [UInt8]) -> [UInt8]? {
        guard isSupported else { return nil }
        switch payload.prefix(2) {
        case [0x51, 0x31]: return Self.capabilityQuery
        case [0x53, 0x31], [0x55, 0x31]: return Self.statusQuery
        case [0x5B, 0x31]: return Self.bandsQuery
        case [0x57, 0x31], [0x59, 0x31]: return Self.parameterQuery
        default: return nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery:
            bandCount = nil
            levelSteps = nil
        case Self.statusQuery: available = nil
        case Self.bandsQuery: bands = nil
        case Self.parameterQuery: values = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3 else { return false }
        switch query(for: payload) {
        case Self.capabilityQuery:
            guard payload.count == 4 else { return false }
            bandCount = Int(payload[2])
            levelSteps = Int(payload[3])
        case Self.statusQuery:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        case Self.bandsQuery:
            guard let layout = SonyEqualizerBand.reportedLayout(payload) else { return false }
            bands = layout
        case Self.parameterQuery:
            guard payload.count == 3 + Int(payload[2]) else { return false }
            values = Array(payload.dropFirst(3))
        default: return false
        }
        return true
    }
}

struct SonyCustomSoundEffect: Equatable, Sendable {
    typealias Effect = SonyULTSoundEffectAssignment.Effect

    static let capabilityQuery: [UInt8] = [0x50, 0x33]
    static let bandsQuery: [UInt8] = [0x5A, 0x33]
    static let parameterQuery: [UInt8] = [0x56, 0x33]
    let isSupported: Bool
    private(set) var modeCodes: [UInt8]?
    private(set) var bandCount: Int?
    private(set) var levelSteps: Int?
    private(set) var bands: [SonyEqualizerBand]?
    private(set) var selectedCode: UInt8?
    private(set) var activeExclusiveFunctions: [UInt8] = []
    private(set) var profiles: [[UInt8]]?

    var queryPayloads: [[UInt8]] {
        isSupported ? [Self.capabilityQuery, Self.bandsQuery, Self.parameterQuery] : []
    }

    var selectedEffect: Effect? { selectedCode.flatMap(Effect.init(rawValue:)) }
    var effects: [Effect]? { modeCodes?.compactMap(Effect.init(rawValue:)) }
    var isExcludedByStamina: Bool { activeExclusiveFunctions.contains(0) }

    var values: [UInt8]? {
        guard let selectedCode, let modeCodes, let index = modeCodes.firstIndex(of: selectedCode),
              let profiles, modeCodes.count == profiles.count else { return nil }
        return profiles[index]
    }

    var editableValues: [UInt8]? {
        guard let values, let bands, let levelSteps, levelSteps > 1, !bands.isEmpty,
              bandCount == bands.count, values.count == bands.count,
              values.allSatisfy({ Int($0) < levelSteps }) else { return nil }
        return values
    }

    func selectPayload(_ effect: Effect) -> [UInt8]? {
        guard selectedCode != nil, selectedEffect != effect, !isExcludedByStamina,
              effects?.contains(effect) == true else { return nil }
        return [0x58, 0x33, effect.rawValue]
    }

    func resetPayload(_ effect: Effect) -> [UInt8]? {
        guard selectedEffect == effect, !isExcludedByStamina, values?.isEmpty == false else { return nil }
        return [0x58, 0x34, effect.rawValue]
    }

    func editPayload(_ effect: Effect, values: [UInt8], preview: Bool = false) -> [UInt8]? {
        guard selectedEffect == effect, !isExcludedByStamina, let previous = editableValues,
              values.count == previous.count, values != previous, let levelSteps,
              values.allSatisfy({ Int($0) < levelSteps }) else { return nil }
        return [0x58, 0x35, preview ? 1 : 0, effect.rawValue, UInt8(values.count)] + values
    }

    func query(for payload: [UInt8]) -> [UInt8]? {
        guard isSupported else { return nil }
        switch payload.prefix(2) {
        case [0x51, 0x33]: return Self.capabilityQuery
        case [0x5B, 0x33]: return Self.bandsQuery
        case [0x57, 0x33], [0x59, 0x33], [0x59, 0x34], [0x59, 0x35], [0x59, 0x36]: return Self.parameterQuery
        default: return nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery: modeCodes = nil; bandCount = nil; levelSteps = nil; profiles = nil
        case Self.bandsQuery: bands = nil
        case Self.parameterQuery: selectedCode = nil; profiles = nil; activeExclusiveFunctions = []
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3 else { return false }
        switch query(for: payload) {
        case Self.capabilityQuery:
            guard payload.count >= 5, payload.count == 5 + Int(payload[4]) else { return false }
            let reported = Array(payload.dropFirst(5))
            guard reported.allSatisfy({ Effect(rawValue: $0) != nil }),
                  Set(reported).count == reported.count else { return false }
            if let modeCodes, modeCodes != reported { profiles = nil }
            modeCodes = reported
            bandCount = Int(payload[2])
            levelSteps = Int(payload[3])
        case Self.bandsQuery:
            guard let layout = SonyEqualizerBand.reportedLayout(payload) else { return false }
            bands = layout
        case Self.parameterQuery:
            let code = payload[2]
            guard code == 0xFF || Effect(rawValue: code) != nil else { return false }
            var index = 3
            let carriesExclusiveFunctions = payload[1] == 0x33 || payload[1] == 0x36
            var exclusive: [UInt8] = []
            if carriesExclusiveFunctions {
                guard index < payload.count else { return false }
                let end = index + 1 + Int(payload[index])
                guard end <= payload.count, code == 0xFF || end == index + 1,
                      payload[(index + 1)..<end].allSatisfy({ $0 == 0 }) else { return false }
                exclusive = Array(payload[(index + 1)..<end])
                index = end
            }
            if payload[0] == 0x57 {
                guard index < payload.count, payload[index] > 0 else { return false }
                let count = Int(payload[index])
                index += 1
                var reported: [[UInt8]] = []
                for _ in 0..<count {
                    guard let values = Self.readValues(payload, from: &index) else { return false }
                    reported.append(values)
                }
                guard index == payload.count else { return false }
                profiles = reported
            } else if payload[1] == 0x33 {
                guard index == payload.count else { return false }
            } else {
                guard let values = Self.readValues(payload, from: &index), index == payload.count,
                      payload[1] == 0x36 ? (code == 0xFF) == values.isEmpty : code != 0xFF else { return false }
                if let modeCodes, let index = modeCodes.firstIndex(of: code), profiles?.indices.contains(index) == true {
                    profiles?[index] = values
                }
            }
            selectedCode = code
            if carriesExclusiveFunctions { activeExclusiveFunctions = exclusive }
        default: return false
        }
        return true
    }

    private static func readValues(_ payload: [UInt8], from index: inout Int) -> [UInt8]? {
        guard index < payload.count else { return nil }
        let end = index + 1 + Int(payload[index])
        guard end <= payload.count else { return nil }
        let values = Array(payload[(index + 1)..<end])
        index = end
        return values
    }
}

struct SonyEqualizer: Equatable, Sendable {
    let supportedFunctions: Set<UInt8>
    let generation: SonyProtocolInfo.Generation
    let inquiryType: UInt8?
    var bassBoost: SonyBassBoost
    var lrBalanceCorrection: SonyLRBalanceCorrection
    var turnKey: SonyTurnKeyEqualizer
    var ultSoundEffectAssignment: SonyULTSoundEffectAssignment
    var customSoundEffect: SonyCustomSoundEffect
    var soundEffect: SonySoundEffect
    var customEQ: SonyCustomEQ
    private(set) var capabilities: SonyEqualizerCapabilities?
    private(set) var bandInformation: [SonyEqualizerBand]?
    private(set) var status: UInt8?
    private(set) var errorCodes: [UInt8]?
    private(set) var presetID: UInt8?
    private(set) var rawValues: [UInt8]?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.supportedFunctions = supportedFunctions
        self.generation = generation
        bassBoost = SonyBassBoost(supportedFunctions: supportedFunctions, generation: generation)
        lrBalanceCorrection = SonyLRBalanceCorrection(isSupported: generation == .v2
            && supportedFunctions.contains(SonyLRBalanceCorrection.function))
        turnKey = SonyTurnKeyEqualizer(supportsImport: generation == .v2 && supportedFunctions.contains(0x56),
                                     supportsManagement: generation == .v2 && supportedFunctions.contains(0x5B))
        ultSoundEffectAssignment = SonyULTSoundEffectAssignment(isSupported: generation == .v2 && supportedFunctions.contains(0x58))
        customSoundEffect = SonyCustomSoundEffect(isSupported: generation == .v2 && supportedFunctions.contains(0x59))
        soundEffect = SonySoundEffect(isSupported: generation == .v2 && supportedFunctions.contains(0x54))
        customEQ = SonyCustomEQ(isSupported: generation == .v2 && supportedFunctions.contains(0x55))
        let types: [(UInt8, UInt8)] = generation == .v1 ? [(0x51, 1), (0x53, 3)]
            : [(0x57, 4), (0x50, 0), (0x52, 2), (0x53, 3)]
        inquiryType = types
            .first { supportedFunctions.contains($0.0) }?.1
    }

    var isSupported: Bool { inquiryType != nil }

    private var isOrdinary: Bool {
        generation == .v1 ? inquiryType == 1 || inquiryType == 3 : inquiryType == 0 || inquiryType == 2 || inquiryType == 4
    }

    var queryPayloads: [[UInt8]] {
        guard let inquiryType else { return [] }
        let capability: [[UInt8]] = [[0x50, inquiryType, 1]]
        return isOrdinary ? capability + [[0x52, inquiryType], [0x5A, inquiryType], [0x56, inquiryType]] : capability
    }

    var parameterQueryPayload: [UInt8]? {
        guard isOrdinary, let inquiryType else { return nil }
        return [0x56, inquiryType]
    }

    var available: Bool? {
        switch status {
        case 0: true
        case 1: false
        default: nil
        }
    }

    var presetTitle: String? {
        guard let presetID else { return nil }
        return capabilities?.presets.first { $0.id == presetID }?.title
            ?? SonyEqualizerPreset(id: presetID, name: nil).title
    }

    var canSelectPreset: Bool { isOrdinary && available == true && capabilities != nil }

    var flatSettings: EqualizerSettings? {
        guard isOrdinary, let capabilities, let bandInformation,
              capabilities.levelSteps > 1, !bandInformation.isEmpty else { return nil }
        return EqualizerSettings(layout: bandInformation, levelSteps: capabilities.levelSteps,
                                 values: Array(repeating: 0, count: bandInformation.count))
    }

    var settings: EqualizerSettings? {
        guard let flatSettings, let rawValues, rawValues.count == flatSettings.layout.count,
              rawValues.allSatisfy({ $0 < flatSettings.levelSteps }) else { return nil }
        let center = (Int(flatSettings.levelSteps) - 1) / 2
        return EqualizerSettings(layout: flatSettings.layout, levelSteps: flatSettings.levelSteps,
                                 values: rawValues.map { Int($0) - center })
    }

    var canEdit: Bool {
        canSelectPreset && (generation == .v1 ? inquiryType == 1 && presetID == EqualizerPreset.manual.rawValue : inquiryType != 2 && presetID != nil)
            && flatSettings != nil
            && capabilities?.presets.contains { $0.id == EqualizerPreset.manual.rawValue } == true
    }

    var requiresManualSelection: Bool {
        generation == .v1 && inquiryType == 1 && canSelectPreset && flatSettings != nil
            && presetID != EqualizerPreset.manual.rawValue
            && capabilities?.presets.contains { $0.id == EqualizerPreset.manual.rawValue } == true
    }

    func presetPayload(_ preset: UInt8) -> [UInt8]? {
        guard canSelectPreset, let inquiryType, generation != .v1 || preset != 0xFF,
              capabilities?.presets.contains(where: { $0.id == preset }) == true else { return nil }
        return [0x58, inquiryType, preset, 0]
    }

    func settingsPayload(_ settings: EqualizerSettings) -> [UInt8]? {
        guard canEdit, let inquiryType, let flatSettings,
              settings.layout == flatSettings.layout, settings.levelSteps == flatSettings.levelSteps,
              settings.values.count == flatSettings.layout.count, let range = settings.levelRange,
              settings.values.allSatisfy(range.contains) else { return nil }
        let center = (Int(settings.levelSteps) - 1) / 2
        return [0x58, inquiryType, generation == .v1 ? 0xFF : EqualizerPreset.manual.rawValue, UInt8(settings.values.count)]
            + settings.values.map { UInt8($0 + center) }
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 4, payload[0] == 0x58, payload[1] == inquiryType,
              payload.count == 4 + Int(payload[3]) else { return false }
        if payload[3] == 0 { return presetPayload(payload[2]) == payload }
        guard payload[2] == (generation == .v1 ? 0xFF : EqualizerPreset.manual.rawValue), let flatSettings,
              payload[3] == flatSettings.layout.count else { return false }
        let center = (Int(flatSettings.levelSteps) - 1) / 2
        let settings = EqualizerSettings(layout: flatSettings.layout, levelSteps: flatSettings.levelSteps,
                                         values: payload.dropFirst(4).map { Int($0) - center })
        return settingsPayload(settings) == payload
    }

    func confirmationValue(_ payload: [UInt8]) -> [UInt8] {
        if generation == .v1, payload[0] == 0x58, payload[2] == 0xFF, payload[3] != 0 {
            return [EqualizerPreset.manual.rawValue] + payload.dropFirst(3)
        }
        return payload[2] == EqualizerPreset.manual.rawValue && payload[3] != 0 ? Array(payload.dropFirst(2)) : [payload[2]]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, let inquiryType, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x51:
            guard let capabilities = SonyEqualizerCapabilities(payload: payload, generation: generation) else { return false }
            self.capabilities = capabilities
        case 0x53, 0x55:
            guard isOrdinary else { return false }
            if inquiryType == 4 {
                guard payload.count >= 4, payload.count == 4 + Int(payload[3]) else { return false }
                errorCodes = Array(payload.dropFirst(4))
            } else {
                guard payload.count == 3 else { return false }
                errorCodes = nil
            }
            status = payload[2]
        case 0x5B:
            guard isOrdinary, payload.count >= 3, payload.count == 3 + 3 * Int(payload[2]) else { return false }
            bandInformation = stride(from: 3, to: payload.count, by: 3).map { index in
                SonyEqualizerBand(informationType: payload[index],
                                  value: UInt16(payload[index + 1]) << 8 | UInt16(payload[index + 2]))
            }
        case 0x57, 0x59:
            guard isOrdinary, payload.count >= 4, payload.count == 4 + Int(payload[3]) else { return false }
            if payload[3] != 0, let flatSettings {
                guard payload[3] == flatSettings.layout.count,
                      payload.dropFirst(4).allSatisfy({ $0 < flatSettings.levelSteps }) else { return false }
            } else if generation == .v1, payload[3] != 0, let capabilities {
                guard payload.dropFirst(4).allSatisfy({ $0 < capabilities.levelSteps }) else { return false }
            }
            presetID = generation == .v1 && payload[2] == 0xFF ? nil : payload[2]
            if generation == .v1 || payload[3] != 0 {
                rawValues = payload[3] == 0 ? nil : Array(payload.dropFirst(4))
            }
        default:
            return false
        }
        return true
    }
}
