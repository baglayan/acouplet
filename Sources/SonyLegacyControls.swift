struct SonyLegacyNoiseCapability: Equatable, Sendable {
    let inquiryType: UInt8
    let noiseType: UInt8
    let noiseSteps: UInt8
    let ambientType: UInt8
    let ambientSteps: [UInt8: UInt8]

    init?(payload: [UInt8]) {
        guard payload.count >= 3, payload[0] == 0x61, (1...3).contains(payload[1]) else { return nil }
        inquiryType = payload[1]
        if inquiryType == 1 {
            guard payload.count == 3 else { return nil }
            noiseType = payload[2]
            noiseSteps = 0
            ambientType = 0
            ambientSteps = [:]
            return
        }
        let countOffset = inquiryType == 2 ? 5 : 3
        guard payload.count > countOffset, payload.count == countOffset + 1 + Int(payload[countOffset]) * 2 else { return nil }
        var steps: [UInt8: UInt8] = [:]
        for offset in stride(from: countOffset + 1, to: payload.count, by: 2) {
            guard steps[payload[offset]] == nil else { return nil }
            steps[payload[offset]] = payload[offset + 1]
        }
        noiseType = inquiryType == 2 ? payload[2] : 0
        noiseSteps = inquiryType == 2 ? payload[3] : 0
        ambientType = payload[countOffset - 1]
        ambientSteps = steps
    }

    var supportsModes: Bool {
        if inquiryType == 1 { return noiseType <= 1 }
        if inquiryType == 3 { return ambientType == 0 && ambientSteps[0] != nil }
        return (noiseType == 0x00 || noiseType == 0x02) && ambientType <= 0x01
            && ambientSteps[0].map { ambientType == 0 || $0 > 0 } == true
    }

    var modes: [NoiseControlMode] {
        guard supportsModes else { return [] }
        if inquiryType == 1 { return [.off, .anc] }
        if inquiryType == 3 { return [.off, .ambient] }
        return noiseType == 0x02 ? [.off, .anc, .ambient, .wind] : [.off, .anc, .ambient]
    }

    func ambientRange(focusOnVoice: Bool) -> ClosedRange<Int>? {
        guard supportsModes, let steps = ambientSteps[focusOnVoice ? 1 : 0] else { return nil }
        if ambientType == 0 { return 1...1 }
        guard steps > 0 else { return nil }
        return 1...Int(steps)
    }
}

struct SonyLegacyNoiseState: Equatable, Sendable {
    let inquiryType: UInt8
    let effect: UInt8
    let noiseType: UInt8
    let noiseValue: UInt8
    let ambientType: UInt8
    let ambientID: UInt8
    let ambientValue: UInt8

    init?(payload: [UInt8]) {
        guard payload.count >= 2, [0x67, 0x68, 0x69].contains(payload[0]),
              (1...3).contains(payload[1]), payload.count == [1: 4, 2: 8, 3: 6][payload[1]] else { return nil }
        inquiryType = payload[1]
        if inquiryType == 1 {
            noiseType = payload[2]
            noiseValue = payload[3]
            effect = payload[3]
            ambientType = 0
            ambientID = 0
            ambientValue = 0
        } else {
            effect = payload[2]
            noiseType = inquiryType == 2 ? payload[3] : 0
            noiseValue = inquiryType == 2 ? payload[4] : 0
            ambientType = payload[payload.count - 3]
            ambientID = payload[payload.count - 2]
            ambientValue = payload[payload.count - 1]
        }
    }

    var mode: NoiseControlMode? {
        if inquiryType == 1 {
            guard noiseType <= 1, noiseValue <= 1 else { return nil }
            return noiseValue == 1 ? .anc : .off
        }
        guard [0x00, 0x01, 0x11].contains(effect), ambientType <= 1, ambientID <= 1 else { return nil }
        guard (noiseType == 0 && noiseValue <= 1) || (noiseType == 2 && noiseValue <= 2),
              ambientType != 0 || ambientValue <= 1 else { return nil }
        if effect == 0 { return .off }
        switch noiseType {
        case 0x00:
            if noiseValue == 1 { return .anc }
        case 0x02:
            if noiseValue == 2 { return .anc }
            if noiseValue == 1 { return .wind }
        default:
            return nil
        }
        return ambientValue > 0 ? .ambient : .off
    }

    var focusOnVoice: Bool? { inquiryType != 1 && ambientID <= 1 ? ambientID == 1 : nil }

    var payload: [UInt8] {
        if inquiryType == 1 { return [0x67, 1, noiseType, noiseValue] }
        if inquiryType == 3 { return [0x67, 3, effect, ambientType, ambientID, ambientValue] }
        return [0x67, 2, effect, noiseType, noiseValue, ambientType, ambientID, ambientValue]
    }
}

struct SonyLegacyNoiseControl: Equatable, Sendable {
    let inquiryType: UInt8
    private(set) var capability: SonyLegacyNoiseCapability?
    private(set) var available: Bool?
    private(set) var state: SonyLegacyNoiseState?

    init(inquiryType: UInt8) {
        precondition(inquiryType == 1 || inquiryType == 3)
        self.inquiryType = inquiryType
    }

    var queryPayloads: [[UInt8]] { [[0x60, inquiryType], [0x62, inquiryType], [0x66, inquiryType]] }

    var canSet: Bool { available == true && state.map { validatedMode($0) != nil } == true }

    var enabled: Bool? { state.flatMap(validatedMode).map { $0 != .off } }

    func validatedMode(_ state: SonyLegacyNoiseState) -> NoiseControlMode? {
        guard let capability, capability.supportsModes, state.inquiryType == inquiryType,
              let mode = state.mode else { return nil }
        if inquiryType == 3 {
            guard state.ambientType == capability.ambientType, capability.ambientSteps[state.ambientID] != nil else { return nil }
        }
        return mode
    }

    func setPayload(enabled: Bool, focusOnVoice: Bool? = nil) -> [UInt8]? {
        guard canSet, let state else { return nil }
        if inquiryType == 1 {
            guard focusOnVoice == nil else { return nil }
            return [0x68, 1, 0, enabled ? 1 : 0]
        }
        let ambientID: UInt8 = focusOnVoice.map { $0 ? 1 : 0 } ?? state.ambientID
        guard capability?.ambientSteps[ambientID] != nil else { return nil }
        return [0x68, 3, enabled ? 1 : 0, 0, ambientID, enabled ? 1 : 0]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard let state = SonyLegacyNoiseState(payload: payload), payload[0] == 0x68,
              let mode = validatedMode(state) else { return false }
        return setPayload(enabled: mode != .off, focusOnVoice: inquiryType == 3 ? state.focusOnVoice : nil) == payload
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x60, inquiryType]: capability = nil
        case [0x62, inquiryType]: available = nil
        case [0x66, inquiryType]: state = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x61:
            capability = SonyLegacyNoiseCapability(payload: payload)
        case 0x63, 0x65:
            available = payload.count == 3 && payload[2] <= 1 ? payload[2] == 0 : nil
        case 0x67, 0x69:
            state = SonyLegacyNoiseState(payload: payload)
        default:
            return false
        }
        return true
    }
}

struct SonyLegacyDSEE: Equatable, Sendable {
    let isSupported: Bool
    private(set) var rawType: UInt8?
    private(set) var settingType: UInt8?
    private(set) var available: Bool?
    private(set) var parameterSettingType: UInt8?
    private(set) var mode: SonyDSEEMode?

    var type: SonyDSEEType? {
        guard let rawType, rawType <= 2 else { return nil }
        return SonyDSEEType(rawValue: rawType)
    }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return (rawType == nil ? [[0xE0, 0x02]] : []) + [[0xE2, 0x02], [0xE6, 0x02]]
    }

    var canSet: Bool {
        isSupported && type != nil && settingType == 0 && available == true
            && parameterSettingType == 0 && mode?.sonyValue != nil
    }

    func setPayload(_ mode: SonyDSEEMode) -> [UInt8]? {
        guard canSet, let value = mode.sonyValue else { return nil }
        return [0xE8, 0x02, 0x00, value]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count == 4 else { return false }
        return setPayload(SonyDSEEMode(rawValue: payload[3])) == payload
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query[0] {
        case 0xE0:
            rawType = nil
            settingType = nil
        case 0xE2:
            available = nil
        case 0xE6:
            parameterSettingType = nil
            mode = nil
        default:
            break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, payload.count >= 3, payload[1] == 0x02 else { return false }
        switch payload[0] {
        case 0xE1:
            guard payload.count == 4 else { return false }
            rawType = payload[2]
            settingType = payload[3]
        case 0xE3, 0xE5:
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0xE7, 0xE9:
            guard payload.count == 4 else { return false }
            parameterSettingType = payload[2]
            mode = SonyDSEEMode(rawValue: payload[3])
        default:
            return false
        }
        return true
    }
}

struct SonyLegacyConnectionQuality: Equatable, Sendable {
    let isSupported: Bool
    private(set) var settingType: UInt8?
    private(set) var parameterSettingType: UInt8?
    private(set) var available: Bool?
    private(set) var mode: SonyConnectionMode?

    var supportedModes: [SonyConnectionMode]? {
        settingType == 0 ? [.soundQuality, .stableConnection] : nil
    }

    var hasKnownParameter: Bool {
        parameterSettingType == 0 && (mode == .soundQuality || mode == .stableConnection)
    }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return (settingType == nil ? [[0xE0, 0x01]] : []) + [[0xE2, 0x01], [0xE6, 0x01]]
    }

    var canSet: Bool {
        isSupported && settingType == 0 && available == true && hasKnownParameter
    }

    func setPayload(_ mode: SonyConnectionMode) -> [UInt8]? {
        guard canSet, mode == .soundQuality || mode == .stableConnection else { return nil }
        return [0xE8, 0x01, 0, mode.sonyValue!]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count == 4 else { return false }
        return setPayload(SonyConnectionMode(rawValue: payload[3])) == payload
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0xE0, 0x01]: settingType = nil
        case [0xE2, 0x01]: available = nil
        case [0xE6, 0x01]:
            parameterSettingType = nil
            mode = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, payload.count >= 3, payload[1] == 0x01 else { return false }
        switch payload[0] {
        case 0xE1:
            guard payload.count == 3 else { return false }
            settingType = payload[2]
        case 0xE3, 0xE5:
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0xE7, 0xE9:
            guard payload.count == 4 else { return false }
            parameterSettingType = payload[2]
            mode = payload[2] == 0 && payload[3] <= 1 ? SonyConnectionMode(rawValue: payload[3]) : .unknown(payload[3])
        default:
            return false
        }
        return true
    }
}

struct SonyLegacyWearingControl: Equatable, Sendable {
    let isSupported: Bool
    private(set) var settingType: UInt8?
    private(set) var parameterSettingType: UInt8?
    private(set) var status: UInt8?
    private(set) var value: UInt8?

    var available: Bool? { status.flatMap { $0 <= 1 ? $0 == 0 : nil } }
    var enabled: Bool? {
        guard parameterSettingType == 0 else { return nil }
        return value.flatMap { $0 <= 1 ? $0 == 1 : nil }
    }

    var state: SonySystemFeatureState? {
        isSupported ? SonySystemFeatureState(enabled: enabled, available: available, isVisible: true) : nil
    }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return (settingType == nil ? [[0xF0, 0x03]] : []) + [[0xF2, 0x03], [0xF6, 0x03]]
    }

    var canSet: Bool {
        isSupported && settingType == 0 && parameterSettingType == 0 && available == true && enabled != nil
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0xF0, 0x03]: settingType = nil
        case [0xF2, 0x03]: status = nil
        case [0xF6, 0x03]:
            parameterSettingType = nil
            value = nil
        default: break
        }
    }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard canSet else { return nil }
        return [0xF8, 0x03, 0x00, enabled ? 0x01 : 0x00]
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count == 4, payload[3] <= 1 else { return false }
        return setPayload(enabled: payload[3] == 1) == payload
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, payload.count >= 3, payload[1] == 0x03 else { return false }
        switch payload[0] {
        case 0xF1:
            guard payload.count == 3 else { return false }
            settingType = payload[2]
        case 0xF3, 0xF5:
            guard payload.count == 3 else { return false }
            status = payload[2]
        case 0xF7, 0xF9:
            guard payload.count == 4 else { return false }
            parameterSettingType = payload[2]
            value = payload[3]
        default:
            return false
        }
        return true
    }
}

struct SonyLegacyControls: Equatable, Sendable {
    let supportedFunctions: Set<UInt8>
    private(set) var noiseCapability: SonyLegacyNoiseCapability?
    private(set) var noiseAvailable: Bool?
    private(set) var noiseState: SonyLegacyNoiseState?
    private(set) var standaloneNoiseCancel: SonyLegacyNoiseControl?
    private(set) var standaloneAmbient: SonyLegacyNoiseControl?
    private(set) var batteries = SonyBatteries()
    private(set) var dsee: SonyLegacyDSEE
    private(set) var connectionQuality: SonyLegacyConnectionQuality
    private(set) var wearingControl: SonyLegacyWearingControl
    private(set) var automaticPowerOff: SonyAutomaticPowerOffState?

    mutating func invalidateNoiseRead(_ query: [UInt8]) {
        switch query[0] {
        case 0x60: noiseCapability = nil
        case 0x62: noiseAvailable = nil
        case 0x66: noiseState = nil
        default: break
        }
    }

    mutating func invalidateStandaloneNoiseRead(_ query: [UInt8]) {
        standaloneNoiseCancel?.invalidateRead(query)
        standaloneAmbient?.invalidateRead(query)
    }

    mutating func invalidateSystemRead(_ query: [UInt8]) {
        connectionQuality.invalidateRead(query)
        wearingControl.invalidateRead(query)
        automaticPowerOff?.invalidateRead(query)
    }

    init?(supportPayload: [UInt8], model: SonyDeviceModel = .unknown) {
        guard supportPayload.count >= 3, supportPayload.prefix(2) == [0x07, 0x00],
              supportPayload.count == 3 + Int(supportPayload[2]) else { return nil }
        supportedFunctions = Set(supportPayload.dropFirst(3)).subtracting(model == .whXM4 ? [0xF6] : [])
        if supportedFunctions.contains(0x61) { standaloneNoiseCancel = SonyLegacyNoiseControl(inquiryType: 1) }
        if supportedFunctions.contains(0x63) { standaloneAmbient = SonyLegacyNoiseControl(inquiryType: 3) }
        dsee = SonyLegacyDSEE(isSupported: supportedFunctions.contains(0xE2))
        connectionQuality = SonyLegacyConnectionQuality(isSupported: supportedFunctions.contains(0xE1))
        wearingControl = SonyLegacyWearingControl(isSupported: supportedFunctions.contains(0xF3))
        if supportedFunctions.contains(0xF4) { automaticPowerOff = SonyAutomaticPowerOffState(inquiryType: 0x04, generation: .v1) }
    }

    var batteryQueries: [[UInt8]] {
        [(UInt8(0x11), UInt8(0x00)), (0x15, 0x01), (0x18, 0x02)].compactMap { function, type in
            supportedFunctions.contains(function) ? [0x10, type] : nil
        }
    }

    var noiseQueries: [[UInt8]] {
        (supportedFunctions.contains(0x62) ? [[0x60, 0x02], [0x62, 0x02], [0x66, 0x02]] : [])
            + (standaloneNoiseCancel?.queryPayloads ?? []) + (standaloneAmbient?.queryPayloads ?? [])
    }

    var canSetNoiseControl: Bool {
        noiseAvailable == true && noiseState.map { validatedMode($0) != nil } == true
    }

    func validatedMode(_ state: SonyLegacyNoiseState) -> NoiseControlMode? {
        guard let capability = noiseCapability, capability.supportsModes, let mode = state.mode,
              state.inquiryType == 2,
              state.noiseType == capability.noiseType, state.ambientType == capability.ambientType else { return nil }
        guard let range = capability.ambientRange(focusOnVoice: state.ambientID == 1),
              state.ambientValue == 0 || range.contains(Int(state.ambientValue)) else { return nil }
        return mode
    }

    func allows(_ payload: [UInt8]) -> Bool {
        if [[0x04, 0x01], [0x04, 0x02], [0x04, 0x03], [0x06, 0x00]].contains(payload) { return true }
        if batteryQueries.contains(payload) || noiseQueries.contains(payload) { return true }
        if standaloneNoiseCancel?.acceptsSetPayload(payload) == true || standaloneAmbient?.acceptsSetPayload(payload) == true { return true }
        if dsee.queryPayloads.contains(payload) || dsee.acceptsSetPayload(payload) { return true }
        if connectionQuality.queryPayloads.contains(payload) || connectionQuality.acceptsSetPayload(payload) { return true }
        if wearingControl.queryPayloads.contains(payload) || wearingControl.acceptsSetPayload(payload) { return true }
        if automaticPowerOff?.queryPayloads.contains(payload) == true || automaticPowerOff?.acceptsSetPayload(payload) == true { return true }
        guard payload.first == 0x68, let state = SonyLegacyNoiseState(payload: payload),
              state.effect <= 1, canSetNoiseControl else { return false }
        return validatedMode(state) != nil
    }

    func noiseControlPayload(mode: NoiseControlMode, ambientLevel: Int, focusOnVoice: Bool) -> [UInt8]? {
        guard canSetNoiseControl, let capability = noiseCapability, let state = noiseState,
              capability.modes.contains(mode) else { return nil }
        if mode == .off {
            return [0x68, 0x02, 0x00, state.noiseType, state.noiseValue, state.ambientType, state.ambientID, state.ambientValue]
        }
        guard let range = capability.ambientRange(focusOnVoice: focusOnVoice) else { return nil }
        let noiseValue: UInt8
        switch mode {
        case .anc: noiseValue = capability.noiseType == 0x02 ? 2 : 1
        case .wind: noiseValue = 1
        case .ambient: noiseValue = 0
        case .off: return nil
        }
        if mode == .ambient, !range.contains(ambientLevel) { return nil }
        return [0x68, 0x02, 0x01, capability.noiseType, noiseValue, capability.ambientType,
                focusOnVoice ? 1 : 0, mode == .ambient ? UInt8(ambientLevel) : 0]
    }

    mutating func invalidateDSEERead(_ query: [UInt8]) {
        dsee.invalidateRead(query)
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2 else { return false }
        if standaloneNoiseCancel?.update(payload) == true || standaloneAmbient?.update(payload) == true { return true }
        if dsee.update(payload) { return true }
        if connectionQuality.update(payload) { return true }
        if wearingControl.update(payload) { return true }
        if automaticPowerOff?.update(payload) == true { return true }
        switch payload[0] {
        case 0x61:
            guard supportedFunctions.contains(0x62), payload[1] == 2, let capability = SonyLegacyNoiseCapability(payload: payload) else { return false }
            noiseCapability = capability
        case 0x63, 0x65:
            guard supportedFunctions.contains(0x62), payload[1] == 2, payload.count == 3 else { return false }
            noiseAvailable = payload[2] <= 1 ? payload[2] == 0 : nil
        case 0x67, 0x69:
            guard supportedFunctions.contains(0x62), payload[1] == 2, let state = SonyLegacyNoiseState(payload: payload) else { return false }
            noiseState = state
        case 0x11, 0x13:
            guard batteryQueries.contains([0x10, payload[1]]) else { return false }
            switch payload[1] {
            case 0x00:
                guard payload.count == 4 else { return false }
                batteries.single = BatteryReading(level: payload[2], charging: payload[3], generation: .v1)
            case 0x01:
                guard payload.count == 6 else { return false }
                batteries.left = BatteryReading(level: payload[2], charging: payload[3], generation: .v1)
                batteries.right = BatteryReading(level: payload[4], charging: payload[5], generation: .v1)
            case 0x02:
                guard payload.count == 4 else { return false }
                batteries.caseBattery = BatteryReading(level: payload[2], charging: payload[3], generation: .v1)
            default:
                return false
            }
        default:
            return false
        }
        return true
    }
}
