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

enum SonyUpscalingStatus: UInt8, Sendable {
    case off = 0, valid = 1, invalid = 2

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .valid: String(localized: "Active")
        case .invalid: String(localized: "Inactive")
        }
    }
}

enum SonyDSEEDisableReason: UInt8, Sendable {
    case calling = 0x00
    case demoMode = 0x01
    case leAudioConnected = 0x02
    case leAudioPlayback = 0x03
    case tandemOverGATT = 0x04
    case googleVoiceAssistant = 0x05
    case sonyVoiceAssistant = 0x06
    case tencentVoiceAssistant = 0x07
    case cinemaUpmix = 0x08
    case gameUpmix = 0x09
    case musicUpmix = 0x0A
    case listeningModeIsNotStandard = 0x0B
    case other = 0xFE
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
    static let codecQueryPayload: [UInt8] = [0x12, 0x02]
    static let upscalingFunction: UInt8 = 0x13
    static let upscalingQueryPayload: [UInt8] = [0x12, 0x03]
    static let dseeFunction: UInt8 = 0xE2
    static let dseeWithDisableReasonsFunction: UInt8 = 0xED
    static let dseeWithDisableReasonsInquiry: UInt8 = 0x0B
    static let connectionModeFunction: UInt8 = 0xE7
    static let listeningModeFunction: UInt8 = 0xE6

    let supportsConnectionStatus: Bool
    let supportsCodecStatus: Bool
    let supportsUpscalingStatus: Bool
    let dseeInquiry: UInt8?
    let supportsListeningMode: Bool
    let connectionModeInquiryType: UInt8?
    private(set) var codec: SonyAudioCodec?
    private(set) var upscalingType: SonyDSEEType?
    private(set) var upscalingStatus: SonyUpscalingStatus?
    private(set) var dseeType: SonyDSEEType?
    private(set) var dseeAvailable: Bool?
    private(set) var dseeMode: SonyDSEEMode?
    private(set) var dseeDisableReasons: [SonyDSEEDisableReason] = []
    private(set) var soundLeakageReduction: SonySoundLeakageReduction?
    private(set) var voiceContents: SonyVoiceContents?
    private(set) var soundFieldOptimization: SonySoundFieldOptimization?
    private(set) var tvSoundBooster: SonyTVSoundBooster?
    private(set) var upmix: [SonyUpmix.Variant: SonyUpmix] = [:]
    private(set) var backgroundMusic: SonyBackgroundMusic?
    private(set) var listeningModeAssignments: SonyListeningModeAssignments?
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
        supportsUpscalingStatus = supportedFunctions.contains(Self.upscalingFunction)
        if supportedFunctions.contains(Self.dseeFunction) {
            dseeInquiry = 0x01
        } else {
            dseeInquiry = supportedFunctions.contains(Self.dseeWithDisableReasonsFunction) ? Self.dseeWithDisableReasonsInquiry : nil
        }
        supportsListeningMode = supportedFunctions.contains(Self.listeningModeFunction)
        soundLeakageReduction = supportedFunctions.contains(SonySoundLeakageReduction.function) ? SonySoundLeakageReduction() : nil
        voiceContents = supportedFunctions.contains(SonyVoiceContents.function) ? SonyVoiceContents() : nil
        soundFieldOptimization = supportedFunctions.contains(SonySoundFieldOptimization.function) ? SonySoundFieldOptimization() : nil
        tvSoundBooster = supportedFunctions.contains(SonyTVSoundBooster.function) ? SonyTVSoundBooster() : nil
        for variant in SonyUpmix.Variant.allCases where supportedFunctions.contains(variant.function) {
            upmix[variant] = SonyUpmix(variant: variant)
        }
        backgroundMusic = SonyBackgroundMusic(supportedFunctions: supportedFunctions)
        listeningModeAssignments = supportedFunctions.contains(SonyListeningModeAssignments.function) ? SonyListeningModeAssignments() : nil
        connectionModeInquiryType = supportedFunctions.contains(Self.connectionModeFunction) ? 0x05
            : supportedFunctions.contains(0xE3) ? 0x02 : supportedFunctions.contains(0xE1) ? 0x00 : nil
        if let connectionModeInquiryType, connectionModeInquiryType != 0x05 {
            supportedConnectionModes = [.soundQuality, .stableConnection]
        }
    }

    var supportsConnectionMode: Bool {
        connectionModeInquiryType != nil
    }

    var listeningMode: SonyListeningMode? {
        guard supportsListeningMode else { return nil }
        if let backgroundMusic {
            guard let enabled = backgroundMusic.enabled else { return nil }
            if enabled { return .backgroundMusic }
        }
        if let cinema = upmix[.cinema] {
            guard let selection = cinema.selection else { return nil }
            if selection == .cinema { return .cinema }
        }
        if let series = upmix[.series] {
            switch series.selection {
            case .cinema: return .cinema
            case .game: return .game
            case .music: return .music
            case .standard: break
            case nil: return nil
            }
        }
        if let voiceContents {
            guard let enabled = voiceContents.enabled else { return nil }
            if enabled { return .voiceContents }
        }
        if let soundLeakageReduction {
            guard let enabled = soundLeakageReduction.enabled else { return nil }
            if enabled { return .soundLeakageReduction }
        }
        return .standard
    }

    var listeningModeOptions: [SonyListeningMode] {
        guard supportsListeningMode else { return [] }
        let seriesModes = upmix[.series]?.selectableModes ?? []
        var options: [SonyListeningMode] = [.standard]
        if backgroundMusic != nil { options.append(.backgroundMusic) }
        if upmix[.cinema] != nil || seriesModes.contains(.cinema) { options.append(.cinema) }
        if seriesModes.contains(.game) { options.append(.game) }
        if seriesModes.contains(.music) { options.append(.music) }
        if voiceContents != nil { options.append(.voiceContents) }
        if soundLeakageReduction != nil { options.append(.soundLeakageReduction) }
        return options
    }

    func listeningModeChanges(to mode: SonyListeningMode) -> [SonyListeningMode.Change] {
        guard let current = listeningMode, mode != current, listeningModeOptions.contains(mode) else { return [] }
        let enabling = mode != .standard
        switch enabling ? mode : current {
        case .standard: return []
        case .backgroundMusic: return [.backgroundMusic(enabling)]
        case .voiceContents: return [.voiceContents(enabling)]
        case .soundLeakageReduction: return [.soundLeakageReduction(enabling)]
        case .cinema:
            let target: SonyUpmix.Mode = enabling ? .cinema : .standard
            return SonyUpmix.Variant.allCases.filter { variant in
                guard let state = upmix[variant], state.selection != target else { return false }
                return variant == .cinema || !enabling || state.selectableModes.contains(.cinema)
            }.map { .upmix($0, target) }
        case .game: return [.upmix(.series, enabling ? .game : .standard)]
        case .music: return [.upmix(.series, enabling ? .music : .standard)]
        }
    }

    var queryPayloads: [[UInt8]] {
        var queries: [[UInt8]] = (supportsConnectionStatus ? [[0x12, 0x01]] : [])
            + (supportsCodecStatus ? [Self.codecQueryPayload] : [])
            + (supportsUpscalingStatus ? [Self.upscalingQueryPayload] : [])
        if let dseeInquiry { queries += [[0xE0, dseeInquiry], [0xE2, dseeInquiry], [0xE6, dseeInquiry]] }
        if let inquiry = connectionModeInquiryType {
            if inquiry == 0x05 { queries.append([0xE0, inquiry]) }
            queries += [[0xE2, inquiry], [0xE6, inquiry]]
        }
        return queries + (soundLeakageReduction == nil ? [] : SonySoundLeakageReduction.queryPayloads)
            + (voiceContents == nil ? [] : SonyVoiceContents.queryPayloads)
            + (soundFieldOptimization == nil ? [] : SonySoundFieldOptimization.queryPayloads)
            + (tvSoundBooster == nil ? [] : SonyTVSoundBooster.queryPayloads)
            + SonyUpmix.Variant.allCases.filter { upmix[$0] != nil }.flatMap(\.queryPayloads)
            + (backgroundMusic?.queryPayloads ?? [])
            + (listeningModeAssignments == nil ? [] : SonyListeningModeAssignments.queryPayloads)
    }

    var connectionModeAvailable: Bool? {
        switch connectionModeStatus {
        case 0x00: true
        case 0x01: false
        default: nil
        }
    }

    var connectionModeLDACAvailable: Bool? {
        switch connectionModeAdditionalStatus {
        case 0x00: true
        case 0x01: false
        default: nil
        }
    }

    var supportsDSEE: Bool { dseeInquiry != nil }
    var dseeParameterQuery: [UInt8]? { dseeInquiry.map { [0xE6, $0] } }
    var canSetDSEE: Bool {
        dseeAvailable == true && dseeDisableReasons.isEmpty && dseeMode?.sonyValue != nil
            && (dseeInquiry != Self.dseeWithDisableReasonsInquiry || dseeType != nil)
    }

    func dseeSetPayload(_ mode: SonyDSEEMode) -> [UInt8]? {
        guard let dseeInquiry, canSetDSEE, let value = mode.sonyValue else { return nil }
        return [0xE8, dseeInquiry, value]
    }

    mutating func invalidateDSEEStatus() {
        dseeAvailable = nil
        dseeDisableReasons = []
    }

    mutating func invalidateDSEERead() {
        dseeMode = nil
    }

    mutating func invalidateUpscalingRead() {
        upscalingType = nil
        upscalingStatus = nil
    }

    mutating func invalidateSoundLeakageRead(_ query: [UInt8]) {
        soundLeakageReduction?.invalidateRead(query)
    }

    mutating func invalidateVoiceContentsRead(_ query: [UInt8]) {
        voiceContents?.invalidateRead(query)
    }

    mutating func invalidateTVSoundBoosterRead(_ query: [UInt8]) {
        tvSoundBooster?.invalidateRead(query)
    }

    mutating func invalidateSoundFieldOptimizationRead(_ query: [UInt8]) {
        soundFieldOptimization?.invalidateRead(query)
    }

    mutating func invalidateUpmixRead(_ query: [UInt8], variant: SonyUpmix.Variant) {
        upmix[variant]?.invalidateRead(query[0])
    }

    mutating func invalidateBackgroundMusicRead(_ query: [UInt8]) {
        backgroundMusic?.invalidateRead(query[0])
    }

    mutating func invalidateListeningModeAssignmentsRead(_ query: [UInt8]) {
        listeningModeAssignments?.invalidateRead(query)
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
        case (0x13, 0x03), (0x15, 0x03):
            guard supportsUpscalingStatus, payload.count == 4,
                  payload[0] != 0x13 || !payload.suffix(2).contains(0xFF) else { return false }
            upscalingType = SonyDSEEType(rawValue: payload[2])
            upscalingStatus = SonyUpscalingStatus(rawValue: payload[3])
        case (0xE1, let inquiry) where inquiry == dseeInquiry:
            guard payload.count == 3 else { return false }
            let type = SonyDSEEType(rawValue: payload[2])
            guard inquiry != Self.dseeWithDisableReasonsInquiry || type != nil else { return false }
            dseeType = type
        case (0xE3, let inquiry) where inquiry == dseeInquiry, (0xE5, let inquiry) where inquiry == dseeInquiry:
            if inquiry == Self.dseeWithDisableReasonsInquiry {
                guard payload.count >= 4, payload[2] <= 1, Int(payload[3]) == payload.count - 4 else { return false }
                let reasons = payload.dropFirst(4).compactMap(SonyDSEEDisableReason.init(rawValue:))
                guard reasons.count == Int(payload[3]) else { return false }
                dseeDisableReasons = reasons
            } else {
                guard payload.count == 3 else { return false }
            }
            dseeAvailable = payload[2] <= 1 ? payload[2] == 0 : nil
        case (0xE7, let inquiry) where inquiry == dseeInquiry, (0xE9, let inquiry) where inquiry == dseeInquiry:
            guard payload.count == 3 else { return false }
            let mode = SonyDSEEMode(rawValue: payload[2])
            guard inquiry != Self.dseeWithDisableReasonsInquiry || mode.sonyValue != nil else { return false }
            dseeMode = mode
        case (_, SonySoundLeakageReduction.inquiry):
            return soundLeakageReduction?.update(payload) == true
        case (_, SonyVoiceContents.inquiry):
            return voiceContents?.update(payload) == true
        case (_, SonyTVSoundBooster.inquiry):
            return tvSoundBooster?.update(payload) == true
        case (_, SonySoundFieldOptimization.inquiry):
            return soundFieldOptimization?.update(payload) == true
        case (_, 0x04), (_, 0x0A):
            return SonyUpmix.Variant(rawValue: payload[1]).flatMap { upmix[$0]?.update(payload) } == true
        case (_, 0x03), (_, 0x09):
            return backgroundMusic?.update(payload) == true
        case (_, SonyListeningModeAssignments.inquiry):
            return listeningModeAssignments?.update(payload) == true
        case (0xE1, 0x05):
            guard connectionModeInquiryType == payload[1], payload.count >= 6 else { return false }
            let modeCount = Int(payload[2])
            let exclusionCountIndex = 3 + modeCount
            guard modeCount >= 2, exclusionCountIndex < payload.count else { return false }
            let exclusionCount = Int(payload[exclusionCountIndex])
            guard payload.count == exclusionCountIndex + 1 + exclusionCount else { return false }
            supportedConnectionModes = payload[3..<exclusionCountIndex].map(SonyConnectionMode.init(rawValue:))
            connectionModeLDACExclusions = payload.suffix(exclusionCount).map(SonyLDACExclusiveFeature.init(rawValue:))
        case (0xE3, 0x00), (0xE5, 0x00), (0xE3, 0x02), (0xE5, 0x02), (0xE3, 0x05), (0xE5, 0x05):
            guard connectionModeInquiryType == payload[1], payload.count == (payload[1] == 0x00 ? 3 : 4) else { return false }
            connectionModeStatus = payload[2]
            connectionModeAdditionalStatus = payload[1] == 0x00 ? nil : payload[3]
        case (0xE7, 0x00), (0xE7, 0x02), (0xE7, 0x05):
            guard connectionModeInquiryType == payload[1], payload.count == 3 else { return false }
            connectionMode = SonyConnectionMode(rawValue: payload[2])
        case (0xE9, 0x00), (0xE9, 0x02), (0xE9, 0x05):
            guard connectionModeInquiryType == payload[1], payload.count == (payload[1] == 0x05 ? 4 : 3) else { return false }
            connectionMode = SonyConnectionMode(rawValue: payload[2])
            lastConnectionModeSwitchingStream = payload[1] == 0x05 ? SonyConnectionStream(rawValue: payload[3]) : SonyConnectionStream.none
        default:
            return false
        }
        return true
    }
}

enum SonyListeningMode: String, Hashable, Sendable {
    case standard = "NORMAL"
    case backgroundMusic = "BGM_MODE"
    case cinema = "UPMIX_CINEMA"
    case game = "UPMIX_GAME"
    case music = "UPMIX_MUSIC"
    case voiceContents = "VOICE_CONTENTS"
    case soundLeakageReduction = "SOUND_LEAKAGE_REDUCTION"

    enum Change: Equatable {
        case backgroundMusic(Bool), voiceContents(Bool), soundLeakageReduction(Bool)
        case upmix(SonyUpmix.Variant, SonyUpmix.Mode)
    }
}

struct SonyListeningModeAssignments: Equatable, Sendable {
    enum Flexibility: UInt8, Sendable { case fixed, flexible }
    enum Requirement: UInt8, Sendable { case mandatory, optional, unknown = 0xFF }
    enum Item: UInt8, Sendable, Hashable {
        case standard, backgroundMusic, cinema, game, music

        var mode: SonyListeningMode {
            switch self {
            case .standard: .standard
            case .backgroundMusic: .backgroundMusic
            case .cinema: .cinema
            case .game: .game
            case .music: .music
            }
        }
    }

    struct Option: Equatable, Sendable, Identifiable {
        var id: Item { item }
        let item: Item
        var requirement: Requirement
    }

    static let function: UInt8 = 0xEA
    static let inquiry: UInt8 = 0x08
    static let capabilityQuery: [UInt8] = [0xE0, inquiry]
    static let statusQuery: [UInt8] = [0xE2, inquiry]
    static let parameterQuery: [UInt8] = [0xE6, inquiry]
    static let queryPayloads = [capabilityQuery, parameterQuery, statusQuery]
    static let writePrefix: [UInt8] = [0xE8, inquiry]

    private(set) var flexibility: Flexibility?
    private(set) var options: [Option]?
    private(set) var available: Bool?
    private(set) var enabled: Bool?
    private(set) var selection: [Item]?

    var parameterValue: [UInt8]? {
        selection.map { [UInt8($0.count)] + $0.map(\.rawValue) }
    }

    func togglePayload(_ item: Item) -> [UInt8]? {
        guard available == true, enabled == true, let selection,
              options?.contains(where: { $0.item == item && $0.requirement == .optional }) == true else { return nil }
        var next = selection
        if let index = next.firstIndex(of: item) {
            next.remove(at: index)
        } else {
            guard next.count < Int(Int8.max) else { return nil }
            next.append(item)
        }
        return Self.writePrefix + [UInt8(next.count)] + next.map(\.rawValue)
    }

    fileprivate mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery:
            flexibility = nil
            options = nil
        case Self.statusQuery:
            available = nil
            enabled = nil
        case Self.parameterQuery:
            selection = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0xE1:
            guard payload.count >= 4, let flexibility = Flexibility(rawValue: payload[2]),
                  payload.count == 4 + Int(payload[3]) * 2, payload[3] <= 0x7F else { return false }
            var options: [Option] = []
            for index in stride(from: 4, to: payload.count, by: 2) {
                guard let item = Item(rawValue: payload[index]) else { return false }
                let requirement = Requirement(rawValue: payload[index + 1]) ?? .unknown
                if let previous = options.firstIndex(where: { $0.item == item }) {
                    options[previous].requirement = requirement
                } else {
                    options.append(Option(item: item, requirement: requirement))
                }
            }
            self.flexibility = flexibility
            self.options = options
        case 0xE3, 0xE5:
            guard payload.count == 4, payload[2] <= 1, payload[3] <= 1 else { return false }
            available = payload[2] == 0
            enabled = payload[3] == 0
        case 0xE7, 0xE9:
            guard payload.count == 3 + Int(payload[2]), payload[2] <= 0x7F else { return false }
            let selection = payload.dropFirst(3).compactMap(Item.init(rawValue:))
            guard selection.count == Int(payload[2]) else { return false }
            self.selection = selection
        default: return false
        }
        return true
    }
}

struct SonyVoiceContents: Equatable, Sendable {
    enum Exclusion: UInt8 { case equalizer = 0, dsee = 1, leAudio = 3 }

    static let function: UInt8 = 0xE8
    static let inquiry: UInt8 = 0x06
    static let capabilityQuery: [UInt8] = [0xE0, inquiry]
    static let parameterQuery: [UInt8] = [0xE6, inquiry]
    static let writePrefix: [UInt8] = [0xE8, inquiry]
    static let queryPayloads = [capabilityQuery, [0xE2, inquiry], parameterQuery]

    private(set) var exclusions: [UInt8]?
    private(set) var available: Bool?
    private(set) var enabled: Bool?

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard exclusions != nil, let current = self.enabled, current != enabled,
              available == true || (available == false && !enabled) else { return nil }
        return Self.writePrefix + [enabled ? 0 : 1]
    }

    fileprivate mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery: exclusions = nil
        case [0xE2, Self.inquiry]: available = nil
        case Self.parameterQuery: enabled = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0xE1:
            guard payload[2] <= 0x7F, payload.count == 3 + Int(payload[2]),
                  payload.dropFirst(3).allSatisfy({ $0 <= 0x0F }) else { return false }
            exclusions = Array(payload.dropFirst(3))
        case 0xE3, 0xE5:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        case 0xE7, 0xE9:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            enabled = payload[2] == 0
        default: return false
        }
        return true
    }
}

struct SonySoundLeakageReduction: Equatable, Sendable {
    enum Exclusion: UInt8 { case equalizer, dsee }

    static let function: UInt8 = 0xE9
    static let inquiry: UInt8 = 0x07
    static let parameterQuery: [UInt8] = [0xE6, inquiry]
    static let queryPayloads: [[UInt8]] = [[0xE0, inquiry], [0xE2, inquiry], parameterQuery]

    private(set) var exclusions: [UInt8]?
    private(set) var available: Bool?
    private(set) var enabled: Bool?

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard exclusions != nil, let current = self.enabled, available == true || (!enabled && current) else { return nil }
        return [0xE8, Self.inquiry, enabled ? 0 : 1]
    }

    fileprivate mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case [0xE0, Self.inquiry]: exclusions = nil
        case [0xE2, Self.inquiry]: available = nil
        case Self.parameterQuery: enabled = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0xE1:
            guard payload.count == 3 + Int(payload[2]), payload.dropFirst(3).allSatisfy({ $0 <= 0x0F }) else { return false }
            exclusions = Array(payload.dropFirst(3))
        case 0xE3, 0xE5:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            available = payload[2] == 0
        case 0xE7, 0xE9:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            enabled = payload[2] == 0
        default: return false
        }
        return true
    }
}

struct SonyBackgroundMusic: Equatable, Sendable {
    enum Room: UInt8, CaseIterable, Sendable {
        case small, medium, large
    }

    enum UnavailableReason: UInt8, Hashable, Sendable {
        case calling, demoMode, leAudioConnected, leAudioPlaying, tandemOverGATT
        case googleAssistant, sonyAssistant, tencentAssistant, upmixCinema, upmixGame, upmixMusic, nonstandardListeningMode
        case other = 0xFE
    }

    let inquiry: UInt8
    private(set) var exclusions: [UInt8]?
    private(set) var available: Bool?
    private(set) var reasons: [UnavailableReason] = []
    private(set) var enabled: Bool?
    private(set) var room: Room?

    init?(supportedFunctions: Set<UInt8>) {
        if supportedFunctions.contains(0xEB) { inquiry = 0x09 }
        else if supportedFunctions.contains(0xE4) { inquiry = 0x03 }
        else { return nil }
    }

    var parameterQuery: [UInt8] { [0xE6, inquiry] }
    var queryPayloads: [[UInt8]] { [[0xE0, inquiry], [0xE2, inquiry], parameterQuery] }

    var parameterValue: [UInt8]? {
        guard let enabled, let room else { return nil }
        return [enabled ? 0 : 1, room.rawValue]
    }

    var canEdit: Bool { available == true && exclusions != nil && parameterValue != nil }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard canEdit, self.enabled != enabled, let room else { return nil }
        return [0xE8, inquiry, enabled ? 0 : 1, room.rawValue]
    }

    func setPayload(room: Room) -> [UInt8]? {
        guard canEdit, self.room != room, let enabled else { return nil }
        return [0xE8, inquiry, enabled ? 0 : 1, room.rawValue]
    }

    fileprivate mutating func invalidateRead(_ opcode: UInt8) {
        switch opcode {
        case 0xE0: exclusions = nil
        case 0xE2:
            available = nil
            reasons = []
        case 0xE6:
            enabled = nil
            room = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        guard payload[1] == inquiry else { return false }
        switch payload[0] {
        case 0xE1:
            guard payload[2] <= 0x7F, payload.count == 3 + Int(payload[2]),
                  payload.dropFirst(3).allSatisfy({ $0 <= 0x0F }) else { return false }
            exclusions = Array(payload.dropFirst(3))
        case 0xE3, 0xE5:
            guard payload[2] <= 1 else { return false }
            if inquiry == 0x09 {
                guard payload.count >= 4, payload.count == 4 + Int(payload[3]) else { return false }
                let reasons = payload.dropFirst(4).compactMap(UnavailableReason.init(rawValue:))
                guard reasons.count == Int(payload[3]) else { return false }
                self.reasons = reasons
            } else {
                guard payload.count == 3 else { return false }
            }
            available = payload[2] == 0
        case 0xE7, 0xE9:
            guard payload.count == 4, payload[2] <= 1, let room = Room(rawValue: payload[3]) else { return false }
            enabled = payload[2] == 0
            self.room = room
        default: return false
        }
        return true
    }
}

struct SonyUpmix: Equatable, Sendable {
    enum Variant: UInt8, CaseIterable, Sendable {
        case cinema = 0x04
        case series = 0x0A

        var function: UInt8 { self == .cinema ? 0xE5 : 0xEC }
        var queryPayloads: [[UInt8]] { [[0xE0, rawValue], [0xE2, rawValue], parameterQuery] }
        var parameterQuery: [UInt8] { [0xE6, rawValue] }

        func mode(_ byte: UInt8) -> Mode? {
            switch self {
            case .cinema: byte == 0 ? .cinema : byte == 1 ? .standard : nil
            case .series: Mode(rawValue: byte)
            }
        }
    }

    enum Mode: UInt8, CaseIterable, Hashable, Sendable {
        case standard, cinema, game, music
    }

    enum PreferredEffect: UInt8, Sendable {
        case upmix, bravia3DSurround
    }

    let variant: Variant
    private(set) var exclusions: [UInt8]?
    private(set) var available: Bool?
    private(set) var reportedModes: [Mode]?
    private(set) var selection: Mode?
    private(set) var preferredEffect: PreferredEffect?

    var selectableModes: [Mode] {
        guard exclusions != nil else { return [] }
        if variant == .cinema { return [.standard, .cinema] }
        return Mode.allCases.filter { $0 == .standard || reportedModes?.contains($0) == true }
    }

    var parameterValue: [UInt8]? { selection.map { [wireValue($0)] } }

    func setPayload(_ mode: Mode) -> [UInt8]? {
        guard available == true, let selection, selection != mode, selectableModes.contains(mode) else { return nil }
        return [0xE8, variant.rawValue, wireValue(mode)]
    }

    private func wireValue(_ mode: Mode) -> UInt8 {
        variant == .series ? mode.rawValue : mode == .standard ? 1 : 0
    }

    fileprivate mutating func invalidateRead(_ opcode: UInt8) {
        switch opcode {
        case 0xE0:
            exclusions = nil
            reportedModes = nil
        case 0xE2:
            available = nil
            preferredEffect = nil
        case 0xE6: selection = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0xE1:
            let start: Int
            let modes: [Mode]?
            if variant == .series {
                let end = 3 + Int(payload[2])
                guard payload[2] <= 0x7F, payload.count > end else { return false }
                let values = payload[3..<end].compactMap(Mode.init(rawValue:))
                guard values.count == Int(payload[2]) else { return false }
                modes = values
                start = end
            } else {
                modes = nil
                start = 2
            }
            guard payload[start] <= 0x7F, payload.count == start + 1 + Int(payload[start]),
                  payload.dropFirst(start + 1).allSatisfy({ $0 <= 0x0F }) else { return false }
            reportedModes = modes
            exclusions = Array(payload.dropFirst(start + 1))
        case 0xE3, 0xE5:
            guard payload.count == (variant == .cinema ? 3 : 4), payload[2] <= 1 else { return false }
            if variant == .series {
                guard let effect = PreferredEffect(rawValue: payload[3]) else { return false }
                preferredEffect = effect
            }
            available = payload[2] == 0
        case 0xE7, 0xE9:
            guard payload.count == 3, let mode = variant.mode(payload[2]) else { return false }
            selection = mode
        default: return false
        }
        return true
    }
}

enum SonyOptimizerExclusion: UInt8, Sendable {
    case none, soundEffect, soundFieldOptimization, stamina, stereoPair, tvSoundBooster, partyConnect, handsfree
    case partyChainTransmitter, partyChainReceiver, auracastTransmitter, auracastReceiver
    case outOfRange = 0xFF
}

struct SonySoundFieldOptimization: Equatable, Sendable {
    static let function: UInt8 = 0x83
    static let inquiry: UInt8 = 0x30
    static let statusQuery: [UInt8] = [0x82, inquiry]
    static let parameterQuery: [UInt8] = [0x86, inquiry]
    static let writePrefix: [UInt8] = [0x88, inquiry]
    static let queryPayloads = [statusQuery, parameterQuery]

    private(set) var available: Bool?
    private(set) var exclusion: SonyOptimizerExclusion?
    private(set) var enabled: Bool?

    var parameterValue: [UInt8]? { enabled.map { [$0 ? 0 : 1] } }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard available == true, let current = self.enabled, current != enabled else { return nil }
        return Self.writePrefix + [enabled ? 0 : 1]
    }

    static func response(to payload: [UInt8]) -> (query: [UInt8], notification: Bool)? {
        guard payload.count >= 3, payload[1] == inquiry else { return nil }
        switch payload[0] {
        case 0x83: return (statusQuery, false)
        case 0x85: return (statusQuery, true)
        case 0x87: return (parameterQuery, false)
        case 0x89: return (parameterQuery, true)
        default: return nil
        }
    }

    fileprivate mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.statusQuery:
            available = nil
            exclusion = nil
        case Self.parameterQuery:
            enabled = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0x83, 0x85:
            guard payload.count == 4, payload[2] <= 1, let exclusion = SonyOptimizerExclusion(rawValue: payload[3]) else { return false }
            available = payload[2] == 0
            self.exclusion = exclusion
        case 0x87, 0x89:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            enabled = payload[2] == 0
        default: return false
        }
        return true
    }
}

struct SonyTVSoundBooster: Equatable, Sendable {
    typealias Exclusion = SonyOptimizerExclusion

    static let function: UInt8 = 0x84
    static let inquiry: UInt8 = 0x31
    static let capabilityQuery: [UInt8] = [0x80, inquiry]
    static let statusQuery: [UInt8] = [0x82, inquiry]
    static let parameterQuery: [UInt8] = [0x86, inquiry]
    static let writePrefix: [UInt8] = [0x88, inquiry]
    static let queryPayloads = [capabilityQuery, statusQuery, parameterQuery]
    static let delays = 0...5

    private(set) var exclusions: [Exclusion]?
    private(set) var available: Bool?
    private(set) var syncAvailable: Bool?
    private(set) var enabled: Bool?
    private(set) var delay: Int?

    var parameterValue: [UInt8]? {
        guard let enabled, let delay else { return nil }
        return [enabled ? 0 : 1, UInt8(delay)]
    }

    var canAdjustDelay: Bool {
        available == true && enabled == true && syncAvailable == true && delay != nil
    }

    func setPayload(enabled: Bool) -> [UInt8]? {
        guard available == true, let current = self.enabled, current != enabled, let delay else { return nil }
        return Self.writePrefix + [enabled ? 0 : 1, UInt8(delay)]
    }

    func setPayload(delay: Int) -> [UInt8]? {
        guard canAdjustDelay, delay != self.delay, Self.delays.contains(delay) else { return nil }
        return Self.writePrefix + [0, UInt8(delay)]
    }

    static func response(to payload: [UInt8]) -> (query: [UInt8], notification: Bool)? {
        guard payload.count >= 3, payload[1] == inquiry else { return nil }
        switch payload[0] {
        case 0x81: return (capabilityQuery, false)
        case 0x83: return (statusQuery, false)
        case 0x85: return (statusQuery, true)
        case 0x87: return (parameterQuery, false)
        case 0x89: return (parameterQuery, true)
        default: return nil
        }
    }

    fileprivate mutating func invalidateRead(_ query: [UInt8]) {
        switch query {
        case Self.capabilityQuery: exclusions = nil
        case Self.statusQuery:
            available = nil
            syncAvailable = nil
        case Self.parameterQuery:
            enabled = nil
            delay = nil
        default: break
        }
    }

    fileprivate mutating func update(_ payload: [UInt8]) -> Bool {
        switch payload[0] {
        case 0x81:
            guard payload.count == 3 + Int(payload[2]) else { return false }
            let exclusions = payload.dropFirst(3).compactMap(Exclusion.init(rawValue:))
            guard exclusions.count == Int(payload[2]), !exclusions.contains(.outOfRange) else { return false }
            self.exclusions = exclusions
        case 0x83, 0x85:
            guard payload.count == 4, payload[2] <= 1, payload[3] <= 1 else { return false }
            available = payload[2] == 0
            syncAvailable = payload[3] == 0
        case 0x87, 0x89:
            guard payload.count == 4, payload[2] <= 1, Self.delays.contains(Int(payload[3])) else { return false }
            enabled = payload[2] == 0
            delay = Int(payload[3])
        default: return false
        }
        return true
    }
}

struct SonyLEAudioRestrictions: Equatable, Sendable {
    enum Feature: UInt8, CaseIterable, Sendable {
        case backgroundMusic = 0x45
        case headTracking = 0x46
        case pairedDevices = 0x47
        case soundAR = 0x48
        case autoPlay = 0x49
        case gattConnectable = 0x4A
        case soundAROptimization = 0x4B
        case quickAccess = 0x4C
        case connectionPreference = 0x4D
        case voiceAssistant = 0x4E
        case voiceAssistantWakeWord = 0x4F
        case linkAutoSwitch = 0x6F

        var frameType: UInt8 { self == .linkAutoSwitch ? 0x0E : 0x0C }
        var query: [UInt8] {
            self == .linkAutoSwitch ? [0x62, 0xFE] : [0x42, rawValue + 0xB0]
        }
    }

    enum Reason: UInt8, Sendable {
        case leAudioPriority = 0, unavailable, leAudioSwitchOn
    }

    struct Shortcut: Equatable, Sendable {
        let id: UInt8
        let enabled: Bool
    }

    struct Status: Equatable, Sendable {
        let reason: Reason
        let shortcuts: [Shortcut]
    }

    private(set) var supported: Set<Feature>
    private(set) var status: [Feature: Status] = [:]

    init(supportedFunctions: Set<UInt8> = [], supportedFunctions2: Set<UInt8> = []) {
        supported = Set(Feature.allCases.filter {
            ($0.frameType == 0x0E ? supportedFunctions2 : supportedFunctions).contains($0.rawValue)
        })
    }

    mutating func updateTable2(_ functions: Set<UInt8>) {
        let feature = Feature.linkAutoSwitch
        if functions.contains(feature.rawValue) {
            supported.insert(feature)
        } else {
            supported.remove(feature)
            status[feature] = nil
        }
    }

    func queryPayloads(frameType: UInt8) -> [[UInt8]] {
        Feature.allCases.filter { supported.contains($0) && $0.frameType == frameType }.map(\.query)
    }

    func readQuery(for payload: [UInt8], frameType: UInt8) -> (feature: Feature, query: [UInt8], notification: Bool)? {
        guard payload.count >= 2,
              let feature = Feature.allCases.first(where: { $0.frameType == frameType && $0.query[1] == payload[1] }),
              supported.contains(feature) else { return nil }
        let query = feature.query
        switch payload[0] {
        case query[0] + 1: return (feature, query, false)
        case query[0] + 3: return (feature, query, true)
        default: return nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard let response = readQuery(for: payload, frameType: frameType), payload.count >= 3,
              let reason = Reason(rawValue: payload[2]) else { return false }
        let feature = response.feature
        let shortcuts: [Shortcut]
        if feature == .quickAccess {
            guard payload.count >= 4, payload.count == 4 + Int(payload[3]) * 2 else { return false }
            shortcuts = stride(from: 4, to: payload.count, by: 2).compactMap { index in
                guard payload[index + 1] <= 1 else { return nil }
                return Shortcut(id: payload[index], enabled: payload[index + 1] == 0)
            }
            guard shortcuts.count == Int(payload[3]) else { return false }
        } else {
            guard payload.count == 3 else { return false }
            shortcuts = []
        }
        status[feature] = Status(reason: reason, shortcuts: shortcuts)
        return true
    }

    func restricts(_ feature: Feature, codec: SonyAudioCodec?) -> Bool {
        guard supported.contains(feature) else { return false }
        let reason = status[feature]?.reason
        return reason == .leAudioPriority || reason == .leAudioSwitchOn || codec == .lc3
    }
}
