import Foundation

struct SonyVoiceGuidance: Equatable, Sendable {
    static let volumeRange = -2...2
    static let languageLocales: [UInt8: String] = [
        0x01: "en", 0x02: "fr", 0x03: "de", 0x04: "es", 0x05: "it", 0x06: "pt", 0x07: "nl",
        0x08: "sv", 0x09: "fi", 0x0A: "ru", 0x0B: "ja", 0x0D: "pt-BR", 0x0F: "ko", 0x10: "tr", 0xF0: "zh"
    ]

    enum Tone: UInt8, CaseIterable, Sendable {
        case batteryLevel = 0x30
        case powerButton = 0x31
        case ultButton = 0x32

        var function: UInt8 {
            switch self {
            case .batteryLevel: 0x46
            case .powerButton: 0x47
            case .ultButton: 0x48
            }
        }
    }

    let generation: SonyProtocolInfo.Generation
    let guidanceInquiry: UInt8?
    let volumeInquiry: UInt8?
    let tones: [Tone]
    private(set) var supportsOnOffSwitch: Bool?
    private(set) var supportedLanguages: [UInt8]?
    private(set) var available: Bool?
    private(set) var enabled: Bool?
    private(set) var currentLanguage: UInt8?
    private(set) var languageAvailable: Bool?
    private(set) var volume: Int?
    private var fixedVolumeAvailable: Bool?
    private(set) var toneAvailability: [Tone: Bool] = [:]
    private(set) var toneEnabled: [Tone: Bool] = [:]

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.generation = generation
        if generation == .v1 {
            guidanceInquiry = supportedFunctions.contains(0x39) ? 1 : nil
            volumeInquiry = nil
            tones = []
        } else {
            let dialects: [(function: UInt8, inquiry: UInt8)] = [(0x42, 1), (0x41, 1), (0x40, 0), (0x44, 2), (0x45, 3)]
            guidanceInquiry = dialects.first { supportedFunctions.contains($0.function) }?.inquiry
            volumeInquiry = supportedFunctions.contains(0x43) ? 0x21 : supportedFunctions.contains(0x42) ? 0x20 : nil
            tones = Tone.allCases.filter { supportedFunctions.contains($0.function) }
            if guidanceInquiry == 3 { supportsOnOffSwitch = true }
        }
    }

    var supportsGuidance: Bool { guidanceInquiry != nil || volumeInquiry != nil || !tones.isEmpty }
    var supportsVolume: Bool { volumeInquiry != nil }
    var supportedLanguageChoices: [UInt8] {
        guard guidanceInquiry == 2 else { return [] }
        var seen: Set<UInt8> = []
        return (supportedLanguages ?? []).filter { Self.languageLocales[$0] != nil && seen.insert($0).inserted }
    }

    func parameterQuery(for inquiry: UInt8) -> [UInt8]? {
        guard guidanceInquiry == inquiry || volumeInquiry == inquiry || tones.contains(where: { $0.rawValue == inquiry }) else { return nil }
        return generation == .v1 ? [0x46, inquiry, 1] : [0x46, inquiry]
    }

    var volumeAvailable: Bool? {
        if volumeInquiry == 0x21 { return fixedVolumeAvailable }
        guard volumeInquiry == 0x20 else { return nil }
        switch supportsOnOffSwitch {
        case .some(true): return available
        case .some(false): return true
        case nil: return nil
        }
    }

    var queryPayloads: [[UInt8]] {
        var payloads: [[UInt8]] = []
        if let inquiry = guidanceInquiry {
            if inquiry != 3, supportedLanguages == nil { payloads.append([0x40, inquiry]) }
            if generation == .v2 || supportsOnOffSwitch == true {
                let subtype: [UInt8] = generation == .v1 ? [1] : inquiry == 3 ? [] : [0]
                if inquiry == 1 || supportsOnOffSwitch != false { payloads.append([0x42, inquiry] + subtype) }
                if inquiry == 2 { payloads.append([0x42, inquiry, 1]) }
                payloads.append([0x46, inquiry] + (generation == .v1 ? [1] : []))
            }
        }
        if let inquiry = volumeInquiry {
            if inquiry == 0x21 { payloads.append([0x42, inquiry]) }
            payloads.append([0x46, inquiry])
        }
        return payloads + tones.flatMap { [[0x42, $0.rawValue], [0x46, $0.rawValue]] }
    }

    func setEnabledPayload(_ enabled: Bool) -> [UInt8]? {
        guard let inquiry = guidanceInquiry, supportsOnOffSwitch == true, available == true,
              self.enabled != nil else { return nil }
        if generation == .v1 { return [0x48, 1, 1, enabled ? 1 : 0] }
        if inquiry == 2 {
            guard let currentLanguage, supportedLanguageChoices.contains(currentLanguage) else { return nil }
            return [0x48, inquiry, enabled ? 0 : 1, currentLanguage]
        }
        return [0x48, inquiry, enabled ? 0 : 1]
    }

    func setLanguagePayload(_ language: UInt8) -> [UInt8]? {
        guard languageAvailable == true, supportedLanguageChoices.contains(language), let enabled else { return nil }
        return [0x48, 2, enabled ? 0 : 1, language]
    }

    func setVolumePayload(_ volume: Int, playTestAudio: Bool = false) -> [UInt8]? {
        guard let inquiry = volumeInquiry, (inquiry == 0x21 || supportedLanguages != nil), volumeAvailable == true,
              self.volume != nil, Self.volumeRange.contains(volume) else { return nil }
        return [0x48, inquiry, UInt8(bitPattern: Int8(volume)), playTestAudio ? 0 : 1]
    }

    func setTonePayload(_ tone: Tone, enabled: Bool) -> [UInt8]? {
        guard toneAvailability[tone] == true, toneEnabled[tone] != nil else { return nil }
        return [0x48, tone.rawValue, enabled ? 0 : 1]
    }

    func availability(for inquiry: UInt8) -> Bool? {
        if inquiry == guidanceInquiry { return available }
        if inquiry == volumeInquiry { return volumeAvailable }
        return Tone(rawValue: inquiry).flatMap { toneAvailability[$0] }
    }

    func parameter(for inquiry: UInt8) -> UInt8? {
        if inquiry == guidanceInquiry { return enabled.map { $0 ? 0 : 1 } }
        if inquiry == volumeInquiry { return volume.map { UInt8(bitPattern: Int8($0)) } }
        return Tone(rawValue: inquiry).flatMap { toneEnabled[$0] }.map { $0 ? 0 : 1 }
    }

    func replyQuery(for payload: [UInt8]) -> [UInt8]? {
        switch payload.first {
        case 0x41: [0x40, payload[1]]
        case 0x43, 0x45: [0x42] + payload.dropFirst().dropLast()
        case 0x47, 0x49: parameterQuery(for: payload[1])
        default: nil
        }
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0x40, 0], [0x40, 1], [0x40, 2]:
            supportsOnOffSwitch = nil
            supportedLanguages = nil
        case [0x42, 0, 0], [0x42, 1, 0], [0x42, 1, 1], [0x42, 2, 0], [0x42, 3]: available = nil
        case [0x42, 2, 1]: languageAvailable = nil
        case [0x42, 0x21]: fixedVolumeAvailable = nil
        case [0x46, 0x01, 0x01]: enabled = nil
        case [0x46, 1], [0x46, 2]:
            enabled = nil
            currentLanguage = nil
        case [0x46, 0], [0x46, 3]: enabled = nil
        case [0x46, 0x20], [0x46, 0x21]: volume = nil
        default:
            if query.count == 2, let tone = Tone(rawValue: query[1]) {
                if query[0] == 0x42 { toneAvailability[tone] = nil }
                if query[0] == 0x46 { toneEnabled[tone] = nil }
            }
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
        case (0x41, 0) where guidanceInquiry == 0:
            guard payload.count == 7 else { return false }
            supportsOnOffSwitch = payload[6] <= 1 ? payload[6] == 1 : nil
            supportedLanguages = []
        case (0x41, 0x01) where guidanceInquiry == 1:
            guard payload.count >= 8, payload.count == 8 + Int(payload[7]) else { return false }
            supportsOnOffSwitch = payload[6] <= 1 ? payload[6] == 1 : nil
            supportedLanguages = Array(payload.dropFirst(8))
        case (0x41, 2) where guidanceInquiry == 2:
            guard payload.count >= 4, payload.count == 4 + Int(payload[3]) else { return false }
            supportsOnOffSwitch = payload[2] <= 1 ? payload[2] == 1 : nil
            supportedLanguages = Array(payload.dropFirst(4))
        case (0x43, 0...2), (0x45, 0...2):
            guard payload[1] == guidanceInquiry, payload.count == 4 else { return false }
            let value = payload[3] <= 1 ? payload[3] == 0 : nil
            if payload[2] == 0 {
                available = value
            } else if payload[1] == 2, payload[2] == 1 {
                languageAvailable = value
            } else {
                return false
            }
        case (0x47, 1...2), (0x49, 2):
            guard payload[1] == guidanceInquiry else { return false }
            guard payload.count == 4 else { return false }
            enabled = payload[2] <= 1 ? payload[2] == 0 : nil
            currentLanguage = payload[3]
        case (0x47, 0), (0x49, 0...1):
            guard payload[1] == guidanceInquiry, payload.count == 3 else { return false }
            enabled = payload[2] <= 1 ? payload[2] == 0 : nil
        default:
            let (opcode, inquiry) = (payload[0], payload[1])
            guard payload.count == 3, parameterQuery(for: inquiry) != nil, inquiry != 1 else { return false }
            let flag = payload[2] <= 1 ? payload[2] == 0 : nil
            switch (opcode, inquiry) {
            case (0x43, 0x03), (0x45, 0x03): available = flag
            case (0x47, 0x03), (0x49, 0x03): enabled = flag
            case (0x43, 0x21), (0x45, 0x21): fixedVolumeAvailable = flag
            case (0x47, 0x20...0x21), (0x49, 0x20...0x21):
                let value = Int(Int8(bitPattern: payload[2]))
                volume = Self.volumeRange.contains(value) ? value : nil
            default:
                guard let tone = Tone(rawValue: inquiry) else { return false }
                switch opcode {
                case 0x43, 0x45: toneAvailability[tone] = flag
                case 0x47, 0x49: toneEnabled[tone] = flag
                default: return false
                }
            }
        }
        return true
    }
}
