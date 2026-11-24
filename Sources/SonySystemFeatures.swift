import Foundation

enum SonySystemFeature: UInt8, CaseIterable, Sendable {
    case incomingCallVibration = 0x00
    case pauseOnRemoval = 0x01
    case legacyPowerSavingMode = 0x02
    case adaptiveVolume = 0x0A
    case headGestures = 0x0F
    case speakToChat = 0x0C
    case voiceAssistantWakeWord = 0x05

    var title: String {
        switch self {
        case .incomingCallVibration: String(localized: "Vibration for incoming call")
        case .pauseOnRemoval: String(localized: "Pause when removed")
        case .legacyPowerSavingMode: String(localized: "Power Saving")
        case .adaptiveVolume: String(localized: "Adaptive Volume Control")
        case .headGestures: String(localized: "Head gestures")
        case .speakToChat: String(localized: "Speak-to-Chat")
        case .voiceAssistantWakeWord: String(localized: "Voice assistant wake word")
        }
    }

    var function: UInt8 {
        switch self {
        case .incomingCallVibration: 0xF0
        case .pauseOnRemoval: 0xF1
        case .legacyPowerSavingMode: 0xF2
        case .adaptiveVolume: 0xFA
        case .headGestures: 0xFF
        case .speakToChat: 0xFC
        case .voiceAssistantWakeWord: 0xF5
        }
    }
}

struct SonySystemFeatureState: Equatable, Sendable {
    var enabled: Bool?
    var available: Bool?
    var isVisible: Bool?
}

struct SonyCallSettings: Equatable, Sendable {
    struct Status: Equatable, Sendable {
        let available: Bool
        let inSettingMode: Bool
        let testSoundEnabled: Bool
        let inCall: Bool
    }

    struct Parameters: Equatable, Sendable {
        let enabled: Bool
        let unknownFields: [UInt8]
    }

    static let function: UInt8 = 0xF8
    static let inquiry: UInt8 = 0x08
    static let capabilityQuery: [UInt8] = [0xF0, inquiry]
    static let statusQuery: [UInt8] = [0xF2, inquiry]
    static let parameterQuery: [UInt8] = [0xF6, inquiry]
    static let queryPayloads = [capabilityQuery, statusQuery, parameterQuery]
    private(set) var capabilityFields: [UInt8]?
    private(set) var status: Status?
    private(set) var parameters: Parameters?

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery: capabilityFields = nil
        case Self.statusQuery: status = nil
        case Self.parameterQuery: parameters = nil
        default: break
        }
    }

    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == Self.inquiry else { return false }
        switch payload[0] {
        case 0xF1:
            guard payload.count == 4, payload[2] >= 2, payload[3] >= 2 else { return false }
            capabilityFields = Array(payload.dropFirst(2))
        case 0xF3, 0xF5:
            guard payload.count == 6, payload.dropFirst(2).allSatisfy({ $0 <= 1 }) else { return false }
            status = Status(available: payload[2] == 0, inSettingMode: payload[3] == 1,
                            testSoundEnabled: payload[4] == 0, inCall: payload[5] == 0)
        case 0xF7, 0xF9:
            guard payload.count == 5, payload[2] <= 1 else { return false }
            parameters = Parameters(enabled: payload[2] == 0, unknownFields: Array(payload.dropFirst(3)))
        default:
            return false
        }
        return true
    }
}

struct SonyAdaptiveVolumeWithLimitation: Equatable, Sendable {
    static let function: UInt8 = 0xF4
    static let statusQuery: [UInt8] = [0xF2, 0x04]
    static let parameterQuery: [UInt8] = [0xF6, 0x04]
    static let writePrefix: [UInt8] = [0xF8, 0x04]

    let isSupported: Bool
    private(set) var available: Bool?
    private(set) var enabled: Bool?
    private(set) var limitationActive: Bool?

    init(supportedFunctions2: Set<UInt8> = []) {
        isSupported = supportedFunctions2.contains(Self.function)
    }

    var queryPayloads: [[UInt8]] { isSupported ? [Self.statusQuery, Self.parameterQuery] : [] }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard available == true, self.enabled != nil else { return nil }
        return Self.writePrefix + [enabled ? 0 : 1]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        if query == Self.statusQuery { available = nil }
        if query == Self.parameterQuery {
            enabled = nil
            limitationActive = nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, payload.count >= 3, payload[1] == 0x04, payload[2] <= 1 else { return false }
        switch payload[0] {
        case 0xF3, 0xF5:
            guard payload.count == 3 else { return false }
            available = payload[2] == 0
        case 0xF7, 0xF9:
            guard payload.count >= 4, payload.count == 4 + Int(payload[3]),
                  payload.dropFirst(4).allSatisfy({ $0 == 0 }) else { return false }
            enabled = payload[2] == 0
            limitationActive = payload[3] != 0
        default:
            return false
        }
        return true
    }
}

struct SonyMicrophoneOperation: Equatable, Sendable {
    enum Key: UInt8, Sendable {
        case touchSensor = 0, button, faceTap
    }

    static let capability: UInt8 = 0xF9
    static let parameterQuery: [UInt8] = [0xF6, 0x0B]
    static let writePrefix: [UInt8] = [0xF8, 0x0B]

    let isSupported: Bool
    private(set) var key: Key?
    private(set) var available: Bool?
    private(set) var gestureEnabled: Bool?
    private(set) var toneEnabled: Bool?

    init(supportedFunctions2: Set<UInt8> = []) {
        isSupported = supportedFunctions2.contains(Self.capability)
    }

    var queryPayloads: [[UInt8]] {
        isSupported ? [[0xF0, 0x0B], [0xF2, 0x0B], Self.parameterQuery] : []
    }

    var parameterValue: [UInt8]? {
        guard let gestureEnabled, let toneEnabled else { return nil }
        return [gestureEnabled ? 0 : 1, toneEnabled ? 0 : 1]
    }

    func setPayload(gesture: Bool? = nil, tone: Bool? = nil) -> [UInt8]? {
        guard available == true, let gestureEnabled, let toneEnabled,
              tone == nil || gestureEnabled else { return nil }
        return Self.writePrefix + [(gesture ?? gestureEnabled) ? 0 : 1, (tone ?? toneEnabled) ? 0 : 1]
    }

    static func readQuery(for payload: [UInt8]) -> (query: [UInt8], notification: Bool)? {
        guard payload.count >= 2, payload[1] == 0x0B else { return nil }
        switch payload[0] {
        case 0xF1, 0xF3, 0xF7: return ([payload[0] - 1, 0x0B], false)
        case 0xF5, 0xF9: return ([payload[0] - 3, 0x0B], true)
        default: return nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query[0] {
        case 0xF0: key = nil
        case 0xF2: available = nil
        case 0xF6:
            gestureEnabled = nil
            toneEnabled = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, let response = Self.readQuery(for: payload) else { return false }
        switch response.query[0] {
        case 0xF0:
            guard payload.count == 3, let key = Key(rawValue: payload[2]) else { return false }
            self.key = key
        case 0xF2:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        default:
            guard payload.count == 4, payload[2] <= 1, payload[3] <= 1 else { return false }
            gestureEnabled = payload[2] == 0
            toneEnabled = payload[3] == 0
        }
        return true
    }
}

struct SonySpeechSensitivity: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    static let options = (UInt8(0)...2).map(Self.init)
    var sonyValue: UInt8? { rawValue <= 2 ? rawValue : nil }
    var title: String {
        switch rawValue {
        case 0: String(localized: "Automatic")
        case 1: String(localized: "High")
        case 2: String(localized: "Low")
        default: String(localized: "Unknown")
        }
    }
}

struct SonySpeakToChatDelay: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    static let options = (UInt8(0)...3).map(Self.init)
    var sonyValue: UInt8? { rawValue <= 3 ? rawValue : nil }
    var title: String {
        switch rawValue {
        case 0: String(localized: "Short")
        case 1: String(localized: "Medium")
        case 2: String(localized: "Long")
        case 3: String(localized: "Manually")
        default: String(localized: "Unknown")
        }
    }
}

enum SonySpeakToChatVariant: UInt8, Equatable, Sendable {
    case legacy = 0x05, type1 = 0x02, type2 = 0x0C

    var inquiry: UInt8 { rawValue }
    var hasVoiceFocus: Bool { self != .type2 }

    var queryPayloads: [[UInt8]] {
        (self == .type2 ? [0xF2, 0xF6, 0xFA] : [0xF0, 0xF2, 0xF6, 0xFA]).map { [$0, inquiry] }
    }

    func togglePayload(enabled: Bool) -> [UInt8] {
        self == .legacy ? [0xF8, inquiry, 1, enabled ? 1 : 0] : [0xF8, inquiry, enabled ? 0 : 1, 1]
    }
}

struct SonySpeakToChatOptions: Equatable, Sendable {
    var variant: SonySpeakToChatVariant = .type2
    private(set) var sensitivity: SonySpeechSensitivity?
    private(set) var delay: SonySpeakToChatDelay?
    private(set) var voiceFocus: Bool?
    private(set) var delaySeconds: [UInt8]?

    var hasKnownCapability: Bool { variant == .type2 || delaySeconds != nil }
    var hasKnownParameters: Bool {
        sensitivity?.sonyValue != nil && delay?.sonyValue != nil && (!variant.hasVoiceFocus || voiceFocus != nil)
    }

    func setPayload(sensitivity: SonySpeechSensitivity, delay: SonySpeakToChatDelay, voiceFocus: Bool? = nil) -> [UInt8]? {
        guard hasKnownCapability, hasKnownParameters,
              let sensitivity = sensitivity.sonyValue, let delay = delay.sonyValue else { return nil }
        let prefix: [UInt8] = [0xFC, variant.inquiry]
        guard variant.hasVoiceFocus else { return voiceFocus == nil ? prefix + [sensitivity, delay] : nil }
        let on: UInt8 = variant == .legacy ? 1 : 0
        let focus = (voiceFocus ?? self.voiceFocus!) ? on : 1 - on
        return prefix + (variant == .legacy ? [0] : []) + [sensitivity, focus, delay]
    }

    mutating func invalidateRead(_ opcode: UInt8) {
        if opcode == 0xF0 { delaySeconds = nil }
        if opcode == 0xFA {
            sensitivity = nil
            delay = nil
            voiceFocus = nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == variant.inquiry else { return false }
        switch payload[0] {
        case 0xF1 where variant == .legacy:
            guard payload.count == 12, payload[2] == 0, payload[3] <= 1,
                  payload[4...7].allSatisfy({ $0 == 0 }) else { return false }
            delaySeconds = Array(payload[8...10])
        case 0xF1 where variant == .type1:
            guard payload.count == 6, payload[2] <= 1, payload[3...5].allSatisfy({ $0 > 0 }) else { return false }
            delaySeconds = Array(payload[3...5])
        case 0xFB, 0xFD:
            let start = variant == .legacy ? 3 : 2
            guard payload.count == start + (variant.hasVoiceFocus ? 3 : 2),
                  variant != .legacy || payload[2] == 0 else { return false }
            sensitivity = SonySpeechSensitivity(rawValue: payload[start])
            delay = SonySpeakToChatDelay(rawValue: payload.last!)
            if variant.hasVoiceFocus {
                let focus = payload[start + 1]
                voiceFocus = focus <= 1 ? focus == (variant == .legacy ? 1 : 0) : nil
            }
        default:
            return false
        }
        return true
    }
}

struct SonyVoiceAssistantOption: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    var sonyValue: UInt8? { (0x30...0x34).contains(rawValue) || rawValue == 0x3F || rawValue == 0xFF ? rawValue : nil }

    var title: String {
        switch rawValue {
        case 0x30: String(localized: "Mobile device assistant")
        case 0x31: String(localized: "Google Assistant")
        case 0x32: String(localized: "Amazon Alexa")
        case 0x33: String(localized: "Tencent Xiaowei")
        case 0x34: String(localized: "Sony voice assistant")
        case 0x3F: String(localized: "Enabled on another device")
        case 0xFF: String(localized: "None")
        default: String(localized: "Unknown")
        }
    }
}

struct SonyVoiceAssistantState: Equatable, Sendable {
    private(set) var options: [SonyVoiceAssistantOption]?
    private(set) var keyType: UInt8?
    private(set) var available: Bool?
    private(set) var current: SonyVoiceAssistantOption?

    var hasKnownCapability: Bool { keyType.map { $0 <= 3 } == true && options != nil }
    var hasKnownParameter: Bool { knownCurrent != nil }
    var knownCurrent: SonyVoiceAssistantOption? { current.flatMap { $0.sonyValue != nil ? $0 : nil } }

    var knownOptions: [SonyVoiceAssistantOption] {
        guard hasKnownCapability, let options else { return [] }
        return options.filter { (0x30...0x34).contains($0.rawValue) } + [SonyVoiceAssistantOption(rawValue: 0xFF)]
    }

    var queryPayloads: [[UInt8]] {
        (options == nil ? [[0xF0, 0x04]] : []) + [[0xF2, 0x04], [0xF6, 0x04]]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0xF0, 0x04]:
            options = nil
            keyType = nil
        case [0xF2, 0x04]: available = nil
        case [0xF6, 0x04]: current = nil
        default: break
        }
    }

    func setPayload(_ option: SonyVoiceAssistantOption) -> [UInt8]? {
        guard available == true, hasKnownParameter, knownOptions.contains(option) else { return nil }
        return [0xF8, 0x04, option.rawValue]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, payload[1] == 0x04 else { return false }
        switch payload[0] {
        case 0xF1:
            guard payload.count >= 4, payload.count == 4 + Int(payload[3]),
                  Set(payload.dropFirst(4)).count == Int(payload[3]) else { return false }
            keyType = payload[2]
            options = payload.dropFirst(4).map(SonyVoiceAssistantOption.init)
        case 0xF3, 0xF5:
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0xF7, 0xF9:
            guard payload.count == 3 else { return false }
            current = SonyVoiceAssistantOption(rawValue: payload[2])
        default:
            return false
        }
        return true
    }
}

struct SonyAutomaticPowerOffOption: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    var sonyValue: UInt8? { rawValue <= 0x04 || rawValue == 0x10 || rawValue == 0x11 ? rawValue : nil }

    var title: String {
        switch rawValue {
        case 0x00: String(localized: "After 5 minutes")
        case 0x01: String(localized: "After 30 minutes")
        case 0x02: String(localized: "After 60 minutes")
        case 0x03: String(localized: "After 180 minutes")
        case 0x04: String(localized: "After 15 minutes")
        case 0x10: String(localized: "When removed")
        case 0x11: String(localized: "Never")
        default: String(localized: "Unknown")
        }
    }
}

struct SonyAutomaticPowerOffState: Equatable, Sendable {
    let inquiryType: UInt8
    let generation: SonyProtocolInfo.Generation
    private(set) var options: [SonyAutomaticPowerOffOption]?
    private(set) var available: Bool?
    private(set) var parameterType: UInt8?
    private(set) var current: SonyAutomaticPowerOffOption?
    private(set) var last: SonyAutomaticPowerOffOption?

    init(inquiryType: UInt8, generation: SonyProtocolInfo.Generation = .v2) {
        self.inquiryType = inquiryType
        self.generation = generation
    }

    private func recognizes(_ option: SonyAutomaticPowerOffOption) -> Bool {
        option.sonyValue != nil && (generation != .v1 || option.rawValue != 0x04)
    }

    var knownOptions: [SonyAutomaticPowerOffOption] { options?.filter { recognizes($0) } ?? [] }

    var knownCurrent: SonyAutomaticPowerOffOption? {
        guard generation != .v1 || parameterType == 1, let current, recognizes(current),
              generation != .v2 || inquiryType != 0x04 || current.rawValue != 0x10 else { return nil }
        return current
    }

    var hasKnownParameter: Bool {
        knownCurrent != nil && last.map { recognizes($0)
            && (generation != .v2 || inquiryType != 0x04 || $0.rawValue != 0x10) } == true
    }

    var parameterQueryPayload: [UInt8] { [generation == .v1 ? 0xF6 : 0x26, inquiryType] }

    mutating func invalidateRead(_ query: [UInt8]) {
        guard query.count == 2, query[1] == inquiryType else { return }
        switch (generation, query[0]) {
        case (.v1, 0xF0), (.v2, 0x20): options = nil
        case (.v1, 0xF2), (.v2, 0x22): available = nil
        case (.v1, 0xF6), (.v2, 0x26):
            parameterType = nil
            current = nil
            last = nil
        default: break
        }
    }

    var queryPayloads: [[UInt8]] {
        (options == nil ? [[generation == .v1 ? 0xF0 : 0x20, inquiryType]] : [])
            + [[generation == .v1 ? 0xF2 : 0x22, inquiryType], parameterQueryPayload]
    }

    func setPayload(_ option: SonyAutomaticPowerOffOption) -> [UInt8]? {
        guard available == true, options?.contains(option) == true, recognizes(option), hasKnownParameter,
              let last, generation != .v2 || inquiryType != 0x04 || option.rawValue != 0x10 else { return nil }
        let selected = option.rawValue
        return (generation == .v1 ? [0xF8, inquiryType, 1] : [0x28, inquiryType])
            + [selected, selected <= 0x04 ? selected : last.rawValue]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count == (generation == .v1 ? 5 : 4) else { return false }
        return setPayload(SonyAutomaticPowerOffOption(rawValue: payload[payload.count - 2])) == payload
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, payload[1] == inquiryType else { return false }
        switch (generation, payload[0]) {
        case (.v1, 0xF1), (.v2, 0x21):
            guard payload.count == 3 + Int(payload[2]), Set(payload.dropFirst(3)).count == Int(payload[2]) else { return false }
            options = payload.dropFirst(3).map(SonyAutomaticPowerOffOption.init)
        case (.v1, 0xF3), (.v1, 0xF5), (.v2, 0x23), (.v2, 0x25):
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
        case (.v1, 0xF7), (.v1, 0xF9), (.v2, 0x27), (.v2, 0x29):
            guard payload.count == (generation == .v1 ? 5 : 4) else { return false }
            if generation == .v1 { parameterType = payload[2] }
            current = SonyAutomaticPowerOffOption(rawValue: payload[payload.count - 2])
            last = SonyAutomaticPowerOffOption(rawValue: payload[payload.count - 1])
        default:
            return false
        }
        return true
    }
}

struct SonySystemFeatures: Equatable, Sendable {
    static let legacyVibrationInquiry: UInt8 = 0x01
    private var legacyOnOffCapabilities: Set<SonySystemFeature> = []
    var hasLegacyVibrationCapability: Bool { hasLegacyOnOffCapability(.incomingCallVibration) }
    private var states: [SonySystemFeature: SonySystemFeatureState] = [:]
    private(set) var speakToChatOptions: SonySpeakToChatOptions?
    private(set) var voiceAssistant: SonyVoiceAssistantState?
    private(set) var automaticPowerOff: SonyAutomaticPowerOffState?
    private(set) var callSettings: SonyCallSettings?
    private var generalSlots: [UInt8] = []
    private var identifiedGeneralSlots: Set<UInt8> = []
    private var sidetoneStates: [UInt8: SonySystemFeatureState] = [:]
    private var multipointStates: [UInt8: SonySystemFeatureState] = [:]
    private var multipointLDACRestrictions: [UInt8: Bool] = [:]
    private(set) var generation = SonyProtocolInfo.Generation.v2

    init(legacyGeneralSettings supportedFunctions: Set<UInt8>) {
        generation = .v1
        generalSlots = (0xD1...0xD4).filter { supportedFunctions.contains($0) }
        if supportedFunctions.contains(0xF1) { states[.incomingCallVibration] = SonySystemFeatureState(isVisible: true) }
        if supportedFunctions.contains(SonySystemFeature.legacyPowerSavingMode.function) {
            states[.legacyPowerSavingMode] = SonySystemFeatureState(isVisible: true)
        }
        if supportedFunctions.contains(0xF5) {
            states[.speakToChat] = SonySystemFeatureState(isVisible: true)
            speakToChatOptions = SonySpeakToChatOptions(variant: .legacy)
        }
    }

    init(supportedFunctions: Set<UInt8> = []) {
        for feature in SonySystemFeature.allCases where feature != .legacyPowerSavingMode && supportedFunctions.contains(feature.function) {
            states[feature] = SonySystemFeatureState(isVisible: feature == .voiceAssistantWakeWord ? nil : true)
        }
        if supportedFunctions.contains(SonySystemFeature.speakToChat.function) {
            speakToChatOptions = SonySpeakToChatOptions()
        } else if supportedFunctions.contains(0xF2) {
            states[.speakToChat] = SonySystemFeatureState(isVisible: true)
            speakToChatOptions = SonySpeakToChatOptions(variant: .type1)
        }
        if supportedFunctions.contains(0xF4) { voiceAssistant = SonyVoiceAssistantState() }
        if supportedFunctions.contains(SonyCallSettings.function) { callSettings = SonyCallSettings() }
        if supportedFunctions.contains(0x25) {
            automaticPowerOff = SonyAutomaticPowerOffState(inquiryType: 0x05)
        } else if supportedFunctions.contains(0x24) {
            automaticPowerOff = SonyAutomaticPowerOffState(inquiryType: 0x04)
        }
        generalSlots = (0xD1...0xD4).filter { supportedFunctions.contains($0) }
    }

    subscript(_ feature: SonySystemFeature) -> SonySystemFeatureState? { states[feature] }

    func hasLegacyOnOffCapability(_ feature: SonySystemFeature) -> Bool { legacyOnOffCapabilities.contains(feature) }

    func legacyOnOffFeature(inquiry: UInt8) -> SonySystemFeature? {
        guard generation == .v1 else { return nil }
        let feature: SonySystemFeature
        switch inquiry {
        case Self.legacyVibrationInquiry: feature = .incomingCallVibration
        case SonySystemFeature.legacyPowerSavingMode.rawValue: feature = .legacyPowerSavingMode
        default: return nil
        }
        return states[feature] != nil ? feature : nil
    }

    var sidetoneSlot: UInt8? { sidetoneStates.count == 1 ? sidetoneStates.keys.first : nil }
    var sidetone: SonySystemFeatureState? { sidetoneSlot.flatMap { sidetoneStates[$0] } }
    var multipointSlot: UInt8? { multipointStates.count == 1 ? multipointStates.keys.first : nil }
    var multipoint: SonySystemFeatureState? { multipointSlot.flatMap { multipointStates[$0] } }
    var multipointDisablesLDAC: Bool? { multipointSlot.flatMap { multipointLDACRestrictions[$0] } }
    var generalSettingsAreIdentified: Bool { generalSlots.allSatisfy { identifiedGeneralSlots.contains($0) } }

    var queryPayloads: [[UInt8]] {
        var queries = SonySystemFeature.allCases.filter { states[$0] != nil }.flatMap { feature -> [[UInt8]] in
            if feature == .speakToChat { return speakToChatOptions?.variant.queryPayloads.filter { $0[0] != 0xFA } ?? [] }
            let inquiry = feature == .incomingCallVibration && generation == .v1 ? Self.legacyVibrationInquiry : feature.rawValue
            if legacyOnOffFeature(inquiry: inquiry) == feature {
                return (hasLegacyOnOffCapability(feature) ? [] : [[0xF0, inquiry]]) + [[0xF2, inquiry], [0xF6, inquiry]]
            }
            return [[0xF2, feature.rawValue], [0xF6, feature.rawValue]]
        }
        if let options = speakToChatOptions { queries.append([0xFA, options.variant.inquiry]) }
        queries += voiceAssistant?.queryPayloads ?? []
        queries += automaticPowerOff?.queryPayloads ?? []
        if callSettings != nil { queries += SonyCallSettings.queryPayloads }
        queries += generalSlots.filter { !identifiedGeneralSlots.contains($0) }.map { [0xD0, $0, 0x01] }
        if let slot = sidetoneSlot { queries += [[0xD2, slot], [0xD6, slot]] }
        if let slot = multipointSlot { queries += [[0xD2, slot], [0xD6, slot]] }
        return queries
    }

    func setPayload(_ feature: SonySystemFeature, enabled: Bool) -> [UInt8]? {
        guard let state = states[feature], state.available == true, state.enabled != nil,
              state.isVisible == true else { return nil }
        if feature == .speakToChat {
            guard let options = speakToChatOptions, options.hasKnownCapability else { return nil }
            return options.variant.togglePayload(enabled: enabled)
        }
        if feature == .incomingCallVibration, generation == .v1 {
            guard hasLegacyVibrationCapability else { return nil }
            return [0xF8, Self.legacyVibrationInquiry, 0, enabled ? 1 : 0]
        }
        if feature == .legacyPowerSavingMode {
            guard hasLegacyOnOffCapability(feature) else { return nil }
            return [0xF8, feature.rawValue, 0, enabled ? 1 : 0]
        }
        return [0xF8, feature.rawValue, enabled ? 0x00 : 0x01]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        voiceAssistant?.invalidateRead(query)
        automaticPowerOff?.invalidateRead(query)
        callSettings?.invalidateRead(query)
        guard query.count == 2 else { return }
        if let feature = legacyOnOffFeature(inquiry: query[1]) {
            switch query[0] {
            case 0xF0: legacyOnOffCapabilities.remove(feature)
            case 0xF2: states[feature]?.available = nil
            case 0xF6: states[feature]?.enabled = nil
            default: break
            }
            return
        }
        if query[1] == speakToChatOptions?.variant.inquiry {
            speakToChatOptions?.invalidateRead(query[0])
            if query[0] == 0xF2 { states[.speakToChat]?.available = nil }
            if query[0] == 0xF6 { states[.speakToChat]?.enabled = nil }
            return
        }
        if let feature = SonySystemFeature(rawValue: query[1]), states[feature] != nil {
            if query[0] == 0xF2 {
                states[feature]?.available = nil
                if feature == .voiceAssistantWakeWord { states[feature]?.isVisible = nil }
            } else if query[0] == 0xF6 {
                states[feature]?.enabled = nil
            }
        }
        if query[0] == 0xD2 { sidetoneStates[query[1]]?.available = nil }
        else if query[0] == 0xD6 { sidetoneStates[query[1]]?.enabled = nil }
    }

    func sidetoneSetPayload(enabled: Bool) -> [UInt8]? {
        guard let slot = sidetoneSlot, let state = sidetone,
              state.available == true, state.enabled != nil else { return nil }
        return generalSetPayload(slot: slot, enabled: enabled)
    }

    func multipointSetPayload(enabled: Bool) -> [UInt8]? {
        guard let slot = multipointSlot, let state = multipoint,
              state.available == true, state.enabled != nil else { return nil }
        return generalSetPayload(slot: slot, enabled: enabled)
    }

    private func generalSetPayload(slot: UInt8, enabled: Bool) -> [UInt8] {
        generation == .v1 ? [0xD8, slot, 0x01, enabled ? 0x01 : 0x00] : [0xD8, slot, 0x00, enabled ? 0x00 : 0x01]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        if payload.count >= 2,
           [0xF1, 0xF3, 0xF5, 0xF7, 0xF9].contains(payload[0]) {
            if let feature = legacyOnOffFeature(inquiry: payload[1]) { return updateOnOffFeature(feature, payload) }
            if generation == .v2, let feature = SonySystemFeature(rawValue: payload[1]),
               [.incomingCallVibration, .adaptiveVolume].contains(feature), states[feature] != nil {
                return updateOnOffFeature(feature, payload)
            }
        }
        if speakToChatOptions?.update(payload) == true { return true }
        if let variant = speakToChatOptions?.variant, payload.count >= 2, payload[1] == variant.inquiry {
            guard payload.count == 4 else { return false }
            switch payload[0] {
            case 0xF3, 0xF5:
                states[.speakToChat]?.available = payload[2] <= 1 ? payload[2] == 0 : nil
            case 0xF7, 0xF9:
                if variant == .legacy {
                    guard payload[2] == (payload[0] == 0xF7 ? 0 : 1) else { return false }
                    states[.speakToChat]?.enabled = payload[3] <= 1 ? payload[3] == 1 : nil
                } else {
                    states[.speakToChat]?.enabled = payload[2] <= 1 ? payload[2] == 0 : nil
                }
            default:
                return false
            }
            return true
        }
        if voiceAssistant?.update(payload) == true { return true }
        if automaticPowerOff?.update(payload) == true { return true }
        if callSettings?.update(payload) == true { return true }
        if updateGeneralSetting(payload) { return true }
        guard payload.count >= 2, let feature = SonySystemFeature(rawValue: payload[1]),
              feature != .speakToChat, var state = states[feature], payload.count == 3 else { return false }
        let value = payload[2] <= 1 ? payload[2] == 0 : nil
        switch payload[0] {
        case 0xF3, 0xF5:
            state.available = value
            if feature == .voiceAssistantWakeWord {
                state.isVisible = payload[2] <= 2 ? payload[2] != 2 : nil
                if payload[2] == 2 { state.available = false }
            }
        case 0xF7, 0xF9:
            state.enabled = value
        default:
            return false
        }
        states[feature] = state
        return true
    }

    private mutating func updateOnOffFeature(_ feature: SonySystemFeature, _ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0xF1:
            guard generation == .v1, payload.count == 3, payload[2] == 0 else { return false }
            legacyOnOffCapabilities.insert(feature)
        case 0xF3, 0xF5:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            states[feature]?.available = payload[2] == 0
        case 0xF7, 0xF9:
            if generation == .v1 {
                guard payload.count == 4, payload[2] == 0, payload[3] <= 1 else { return false }
                states[feature]?.enabled = payload[3] == 1
            } else {
                guard payload.count == 3, payload[2] <= 1 else { return false }
                states[feature]?.enabled = payload[2] == 0
            }
        default:
            return false
        }
        return true
    }

    private mutating func updateGeneralSetting(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 3, generalSlots.contains(payload[1]) else { return false }
        let slot = payload[1]
        if payload[0] == 0xD1 {
            let isBoolean: Bool
            let titleStart: Int
            if generation == .v1 {
                guard payload.count >= 5, payload[2] <= 0x02 else { return false }
                titleStart = 4
            } else {
                guard payload.count >= 6, payload[2] == 0x00, payload[3] <= 1 else { return false }
                titleStart = 5
            }
            let titleEnd = titleStart + Int(payload[titleStart - 1])
            guard titleEnd < payload.count else { return false }
            let summaryEnd = titleEnd + 1 + Int(payload[titleEnd])
            if generation == .v1 {
                guard payload.count == summaryEnd + 1 || (payload.count == summaryEnd + 2 && payload.last == 0),
                      payload[summaryEnd] == 0x01 || (payload[summaryEnd] == 0x02 && payload.count == summaryEnd + 2) else { return false }
                isBoolean = payload[2] == 0x02 && payload[summaryEnd] == 0x01
            } else {
                guard payload.count == summaryEnd else { return false }
                isBoolean = payload[3] == 1
            }
            guard let title = String(bytes: payload[titleStart..<titleEnd], encoding: .utf8),
                  let summary = String(bytes: payload[(titleEnd + 1)..<summaryEnd], encoding: .utf8) else { return false }
            identifiedGeneralSlots.insert(slot)
            if isBoolean, title == "SIDETONE_SETTING" {
                if sidetoneStates[slot] == nil { sidetoneStates[slot] = SonySystemFeatureState() }
            } else {
                sidetoneStates[slot] = nil
            }
            if isBoolean, title == "MULTIPOINT_SETTING" {
                if multipointStates[slot] == nil { multipointStates[slot] = SonySystemFeatureState() }
                multipointLDACRestrictions[slot] = switch summary {
                case "MULTIPOINT_SETTING_SUMMARY": true
                case "MULTIPOINT_SETTING_SUMMARY_LDAC_AVAILABLE": false
                default: nil
                }
            } else {
                multipointStates[slot] = nil
                multipointLDACRestrictions[slot] = nil
            }
            return true
        }
        guard var state = sidetoneStates[slot] ?? multipointStates[slot] else { return false }
        switch payload[0] {
        case 0xD3, 0xD5:
            guard payload.count == 3 else { return false }
            state.available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0xD7, 0xD9:
            guard payload.count == 4, payload[2] == (generation == .v1 ? 0x01 : 0x00) else { return false }
            state.enabled = payload[3] <= 1 ? payload[3] == (generation == .v1 ? 1 : 0) : nil
        default:
            return false
        }
        if sidetoneStates[slot] != nil {
            sidetoneStates[slot] = state
        } else {
            multipointStates[slot] = state
        }
        return true
    }
}

struct SonyLinkAutoSwitch: Equatable, Sendable {
    let supportsSpeaker: Bool
    let supportsHeadset: Bool
    private(set) var speakerAvailable: Bool?
    private(set) var speakerStereoPair: Bool?
    private(set) var registeredPhoneCount: Int?
    private(set) var headsetAvailable: Bool?
    private(set) var headsetLinkEnabled: Bool?

    init(supportedFunctions2: Set<UInt8> = []) {
        supportsSpeaker = supportedFunctions2.contains(0xF7)
        supportsHeadset = supportedFunctions2.contains(0xF8)
    }

    var queryPayloads: [[UInt8]] {
        (supportsSpeaker ? [[0xF2, 0x09], [0xF6, 0x09]] : [])
            + (supportsHeadset ? [[0xF2, 0x0A], [0xF6, 0x0A]] : [])
    }

    func readQuery(for payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 2 else { return nil }
        let inquiry = payload[1]
        guard (inquiry == 0x09 && supportsSpeaker) || (inquiry == 0x0A && supportsHeadset) else { return nil }
        switch payload[0] {
        case 0xF3, 0xF5: return [0xF2, inquiry]
        case 0xF7, 0xF9: return [0xF6, inquiry]
        default: return nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard let query = readQuery(for: payload) else { return false }
        switch (query[0], query[1]) {
        case (0xF2, 0x09):
            guard payload.count == 6, payload[2] <= 1, payload[3] <= 1 else { return false }
            speakerAvailable = payload[2] == 0
            speakerStereoPair = payload[3] == 0
        case (0xF6, 0x09):
            guard payload.count >= 3, payload[2] <= 8, payload.count == 3 + 17 * Int(payload[2]) else { return false }
            registeredPhoneCount = Int(payload[2])
        case (0xF2, 0x0A):
            guard payload.count == 3, payload[2] <= 1 else { return false }
            headsetAvailable = payload[2] == 0
        case (0xF6, 0x0A):
            guard payload.count == 22, payload[2] <= 1 else { return false }
            headsetLinkEnabled = payload[2] == 0
        default:
            return false
        }
        return true
    }
}
