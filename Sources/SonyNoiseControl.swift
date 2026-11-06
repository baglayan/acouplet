struct SonyNoiseControl: Equatable, Sendable {
    enum Sensitivity: UInt8, CaseIterable, Identifiable, Sendable {
        case standard = 0, high = 1, low = 2

        var id: Self { self }
        var title: String {
            switch self {
            case .standard: "Standard"
            case .high: "High"
            case .low: "Low"
            }
        }
    }

    struct AmbientCapability: Equatable, Sendable {
        let ambientMode: UInt8
        let minimum: Int
        let maximum: Int
        let step: Int

        init?(ambientMode: UInt8, minimum: UInt8, maximum: UInt8, step: UInt8) {
            guard ambientMode <= 1, minimum < 255, maximum > 0, minimum <= maximum, step > 0 else { return nil }
            self.ambientMode = ambientMode
            self.minimum = Int(minimum)
            self.maximum = Int(maximum)
            self.step = Int(step)
        }

        var range: ClosedRange<Int> { minimum...(minimum + (maximum - minimum) / step * step) }

        func contains(_ value: Int) -> Bool {
            range.contains(value) && (value - minimum) % step == 0
        }

        func normalized(_ value: Int) -> Int {
            let value = max(range.lowerBound, min(range.upperBound, value))
            return minimum + (value - minimum + step / 2) / step * step
        }
    }

    struct State: Equatable, Sendable {
        let payload: [UInt8]

        init?(payload: [UInt8]) {
            guard payload.count >= 4, [0x67, 0x68, 0x69].contains(payload[0]),
                  payload[2] == 1, payload[3] <= 1 else { return nil }
            let inquiry = payload[1]
            switch inquiry {
            case 0x01:
                guard payload.count == 5, payload[4] <= 1 else { return nil }
            case 0x11, 0x12, 0x13, 0x14:
                guard payload.count == 7, payload[4] <= ([0x11, 0x13].contains(inquiry) ? 1 : 5),
                      payload[5] <= 1, ![0x11, 0x12].contains(inquiry) || payload[6] <= 1 else { return nil }
            case 0x15, 0x16:
                guard payload.count == 8, payload[4] <= 1, payload[5] <= 5, payload[6] <= 1 else { return nil }
            case 0x17, 0x18, 0x19:
                guard payload.count == (inquiry == 0x19 ? 9 : 7),
                      payload[4] <= (inquiry == 0x18 ? 2 : 1), payload[5] <= 1 else { return nil }
                if inquiry == 0x19 {
                    guard payload[7] <= 1, Sensitivity(rawValue: payload[8]) != nil else { return nil }
                }
            case 0x21, 0x22:
                guard payload.count == 6, payload[4] <= 1, inquiry != 0x21 || payload[5] <= 1 else { return nil }
            default:
                return nil
            }
            self.payload = [0x67] + payload.dropFirst()
        }

        var inquiryType: UInt8 { payload[1] }
        var effectEnabled: Bool { payload[3] == 1 }
        var ncAsmMode: UInt8 {
            switch inquiryType {
            case 0x01: payload[4] == 0 ? 1 : 0
            case 0x11...0x14: payload[4] == 0 ? 1 : 0
            case 0x21, 0x22: 1
            default: payload[4]
            }
        }
        var ambientMode: UInt8 {
            switch inquiryType {
            case 0x01: 0
            case 0x15, 0x16: payload[6]
            case 0x21, 0x22: payload[4]
            default: payload[5]
            }
        }
        var ambientLevel: Int {
            switch inquiryType {
            case 0x01: 0
            case 0x15, 0x16: Int(payload[7])
            case 0x21, 0x22: Int(payload[5])
            default: Int(payload[6])
            }
        }
        var noiseValue: UInt8? {
            switch inquiryType {
            case 0x01, 0x11...0x14: payload[4]
            case 0x15, 0x16: payload[5]
            default: nil
            }
        }
        var adaptationEnabled: Bool? { inquiryType == 0x19 ? payload[7] == 1 : nil }
        var sensitivity: Sensitivity? { inquiryType == 0x19 ? Sensitivity(rawValue: payload[8]) : nil }
        var isNoiseCancellingSS: Bool { effectEnabled && inquiryType == 0x18 && ncAsmMode == 2 }
        var mode: NoiseControlMode? {
            if inquiryType == 0x01 { return noiseValue == 1 ? .anc : .off }
            guard effectEnabled else { return .off }
            if isNoiseCancellingSS { return nil }
            if [0x11, 0x12, 0x13, 0x14].contains(inquiryType) {
                if noiseValue == 0 { return .ambient }
                return [0x12, 0x14].contains(inquiryType) && noiseValue == 1 ? .wind : .anc
            }
            if [0x21, 0x22].contains(inquiryType) { return .ambient }
            if ncAsmMode == 1 { return .ambient }
            if inquiryType == 0x15, let noiseValue, (3...5).contains(noiseValue) { return .wind }
            return inquiryType == 0x16 && noiseValue == 1 ? .wind : .anc
        }
        var focusOnVoice: Bool? { inquiryType == 0x01 ? nil : ambientMode == 1 }
    }

    let inquiryType: UInt8

    static func inquiryType(forFunction function: UInt8) -> UInt8? {
        [0x61: 0x01, 0x62: 0x11, 0x63: 0x12, 0x64: 0x13, 0x65: 0x14,
         0x66: 0x21, 0x67: 0x22, 0x68: 0x15, 0x6A: 0x16, 0x6B: 0x17,
         0x6C: 0x18, 0x6D: 0x19][function]
    }

    init(inquiryType: UInt8 = 0x19) {
        precondition([0x01, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x21, 0x22].contains(inquiryType))
        self.inquiryType = inquiryType
    }

    private(set) var capabilities: [UInt8: AmbientCapability]?
    private(set) var available: Bool?
    private(set) var state: State?

    var queryPayloads: [[UInt8]] { [[0x60, inquiryType], [0x62, inquiryType], [0x66, inquiryType]] }
    var supportsAmbientLevel: Bool { ![0x01, 0x11, 0x12, 0x21].contains(inquiryType) }
    var supportsFocusOnVoice: Bool { capabilities?[1] != nil }
    var supportedModes: [NoiseControlMode] {
        switch inquiryType {
        case 0x01: [.off, .anc]
        case 0x21, 0x22: [.off, .ambient]
        case 0x12, 0x14, 0x15, 0x16: [.off, .anc, .wind, .ambient]
        default: [.off, .anc, .ambient]
        }
    }

    var canSet: Bool {
        available == true && state.map { validatedState($0.payload) != nil } == true
    }

    func ambientCapability(focusOnVoice: Bool) -> AmbientCapability? {
        capabilities?[focusOnVoice ? 1 : 0]
    }

    func ambientRange(focusOnVoice: Bool) -> ClosedRange<Int>? {
        supportsAmbientLevel ? ambientCapability(focusOnVoice: focusOnVoice)?.range : nil
    }

    func ambientStep(focusOnVoice: Bool) -> Int? {
        supportsAmbientLevel ? ambientCapability(focusOnVoice: focusOnVoice)?.step : nil
    }

    func validatedState(_ payload: [UInt8]) -> State? {
        guard let state = State(payload: payload), state.inquiryType == inquiryType, let capabilities else { return nil }
        if inquiryType == 0x01 { return state }
        guard let capability = capabilities[state.ambientMode] else { return nil }
        if [0x13, 0x14].contains(inquiryType), state.noiseValue != 0, state.ambientLevel == 0 { return state }
        return capability.contains(state.ambientLevel) ? state : nil
    }

    func validatedMode(_ payload: [UInt8]) -> NoiseControlMode? {
        validatedState(payload)?.mode
    }

    func setPayload(mode: NoiseControlMode? = nil, ambientLevel: Int? = nil, focusOnVoice: Bool? = nil,
                    adaptationEnabled: Bool? = nil, sensitivity: Sensitivity? = nil,
                    noiseCancellingSS: Bool? = nil) -> [UInt8]? {
        guard canSet, let state else { return nil }
        if adaptationEnabled != nil || sensitivity != nil { guard inquiryType == 0x19 else { return nil } }
        if noiseCancellingSS != nil { guard inquiryType == 0x18 else { return nil } }
        if ambientLevel != nil { guard supportsAmbientLevel else { return nil } }
        if focusOnVoice != nil { guard inquiryType != 0x01 else { return nil } }
        var payload = state.payload
        payload[0] = 0x68
        if mode == .off {
            payload[3] = 0
            if inquiryType == 0x01 { payload[4] = 0 }
            return payload
        }
        let ambientOffset = [0x15, 0x16].contains(inquiryType) ? 6 : [0x21, 0x22].contains(inquiryType) ? 4 : 5
        if let mode {
            guard supportedModes.contains(mode) else { return nil }
            payload[3] = 1
            switch inquiryType {
            case 0x01:
                payload[4] = 1
            case 0x11...0x14:
                payload[4] = mode == .ambient ? 0 : mode == .wind || [0x11, 0x13].contains(inquiryType) ? 1 : 2
                payload[6] = mode == .ambient ? payload[6] : 0
            case 0x21, 0x22:
                break
            default:
                payload[4] = mode == .ambient ? 1 : 0
                if inquiryType == 0x15 { payload[5] = mode == .wind ? 3 : 2 }
                if inquiryType == 0x16, mode != .ambient { payload[5] = mode == .wind ? 1 : 2 }
            }
            if mode == .ambient, [0x11, 0x12, 0x13, 0x14, 0x21, 0x22].contains(inquiryType), payload[ambientOffset + 1] == 0 {
                guard let capability = capabilities?[payload[ambientOffset]] else { return nil }
                payload[ambientOffset + 1] = UInt8(capability.minimum > 0 ? capability.minimum : capability.step)
            }
        }
        if let ambientLevel {
            guard let level = UInt8(exactly: ambientLevel) else { return nil }
            payload[ambientOffset + 1] = level
        }
        if let focusOnVoice { payload[ambientOffset] = focusOnVoice ? 1 : 0 }
        if let adaptationEnabled { payload[7] = adaptationEnabled ? 1 : 0 }
        if let sensitivity { payload[8] = sensitivity.rawValue }
        if let noiseCancellingSS {
            payload[3] = 1
            payload[4] = noiseCancellingSS ? 2 : 0
        }
        return validatedState(payload) == nil ? nil : payload
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query[0] {
        case 0x60: capabilities = nil
        case 0x62: available = nil
        case 0x66: state = nil
        default: break
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0x61:
            capabilities = nil
            if inquiryType == 0x01 {
                if payload.count == 2 { capabilities = [:] }
                return true
            }
            let width = [0x11, 0x12, 0x21].contains(inquiryType) ? 1 : 4
            guard payload.count >= 3, payload.count == 3 + Int(payload[2]) * width else { return true }
            var records: [UInt8: AmbientCapability] = [:]
            for offset in stride(from: 3, to: payload.count, by: width) {
                let mode = payload[offset]
                guard records[mode] == nil,
                      let record = AmbientCapability(ambientMode: mode, minimum: width == 1 ? 0 : payload[offset + 1],
                                                     maximum: width == 1 ? 1 : payload[offset + 2],
                                                     step: width == 1 ? 1 : payload[offset + 3]) else { return true }
                records[mode] = record
            }
            capabilities = records
        case 0x63, 0x65:
            available = payload.count == 3 && payload[2] <= 1 ? payload[2] == 0 : nil
        case 0x67, 0x69:
            state = State(payload: payload)
        default:
            return false
        }
        return true
    }
}

struct SonyNoiseToggle: Equatable, Sendable {
    private(set) var key: UInt8?
    private(set) var selected: UInt8?
    private(set) var available: Bool?

    var queryPayloads: [[UInt8]] { [[0x60, 0x30], [0x62, 0x30], [0x66, 0x30]] }
    var options: [UInt8]? { key == nil ? nil : [1, 2, 3, 4] }
    var canSet: Bool { key != nil && available == true && selected != nil }

    func setPayload(_ option: UInt8) -> [UInt8]? {
        guard canSet, options?.contains(option) == true else { return nil }
        return [0x68, 0x30, option]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 0x30 else { return false }
        switch payload[0] {
        case 0x61:
            key = payload.count == 3 && payload[2] <= 5 ? payload[2] : nil
        case 0x63, 0x65:
            available = payload.count == 3 && payload[2] <= 1 ? payload[2] == 0 : nil
        case 0x67, 0x69:
            selected = payload.count == 3 && (1...4).contains(payload[2]) ? payload[2] : nil
        default:
            return false
        }
        return true
    }
}

struct SonyNoiseTest: Equatable, Sendable {
    private(set) var active: Bool?

    var queryPayload: [UInt8] { [0x62, 0x40] }

    func setPayload(start: Bool) -> [UInt8]? {
        guard active != nil else { return nil }
        return [0x64, 0x40, start ? 0 : 1]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2, payload[1] == 0x40, [0x63, 0x65].contains(payload[0]) else { return false }
        active = payload.count == 3 && payload[2] <= 1 ? payload[2] == 0 : nil
        return true
    }
}
