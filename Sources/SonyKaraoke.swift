struct SonyKaraoke: Equatable, Sendable {
    static let frameType: UInt8 = 0x0E

    enum Item: UInt8, Hashable, Sendable {
        case echo = 0, key, vocal, voiceChanger, sampler, scoring, bass, treble

        var range: ClosedRange<Int>? {
            switch self {
            case .echo: 0...3
            case .key: -6...6
            case .vocal: 0...2
            case .voiceChanger: 0...4
            case .bass, .treble: 0...10
            case .sampler, .scoring: nil
            }
        }

        func value(_ byte: UInt8) -> Int {
            self == .key ? Int(Int8(bitPattern: byte)) : Int(byte)
        }
    }

    enum Sample: UInt8, Hashable, Sendable {
        case clap = 0, letsGo, reggaeHorn, comeOn
    }

    enum Scoring: UInt8, Sendable {
        case stopped = 0, started, waiting

        var next: Self? {
            switch self {
            case .stopped: .started
            case .started: .waiting
            case .waiting: nil
            }
        }
    }

    enum Availability: UInt8, Sendable {
        case enabled = 0, disabled, exceptVocal
    }

    enum DisableReason: UInt8, Hashable, Sendable {
        case tvSoundBooster = 0, demoMode, speaking
    }

    enum Setting: Hashable, Sendable {
        case controls, scoring, live
    }

    let inquiry: UInt8?
    let supportsLive: Bool
    private(set) var items: [Item]?
    private(set) var samples: [Sample] = []
    private(set) var availability: Availability?
    private(set) var micPlugged: Bool?
    private(set) var scoring: Scoring?
    private(set) var disableReasons: [DisableReason] = []
    private(set) var score: UInt8?
    private(set) var liveEnabled: Bool?
    private var parameters: [UInt8]?

    init(supportedFunctions2: Set<UInt8> = []) {
        inquiry = supportedFunctions2.contains(0x72) ? 2 : supportedFunctions2.contains(0x74) ? 4 : nil
        supportsLive = inquiry != nil && supportedFunctions2.contains(0x75)
    }

    var queryPayloads: [[UInt8]] {
        guard let inquiry else { return [] }
        return [[0x70, inquiry], [0x72, inquiry], [0x76, inquiry]] + (supportsLive ? [[0x76, 5]] : [])
    }

    func query(_ setting: Setting) -> [UInt8]? {
        guard let inquiry else { return nil }
        switch setting {
        case .controls: return [0x76, inquiry]
        case .scoring: return [0x72, inquiry]
        case .live: return supportsLive ? [0x76, 5] : nil
        }
    }

    func setting(forQuery query: [UInt8]) -> Setting? {
        if query == self.query(.controls) { return .controls }
        if query == self.query(.scoring) { return .scoring }
        if query == self.query(.live) { return .live }
        return nil
    }

    static func settingForCommand(_ payload: [UInt8]) -> Setting? {
        guard payload.count >= 3 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x78, 2), (0x78, 4): return .controls
        case (0x74, 2), (0x74, 4): return .scoring
        case (0x78, 5): return .live
        default: return nil
        }
    }

    func setting(forWrite payload: [UInt8]) -> Setting? {
        guard let setting = Self.settingForCommand(payload), query(setting)?.last == payload[1] else { return nil }
        return setting
    }

    private var controls: [Item] { items?.filter { $0.range != nil } ?? [] }

    private var available: Bool {
        guard let availability else { return false }
        return availability != .disabled && micPlugged == true && disableReasons.isEmpty
    }

    func value(_ item: Item) -> Int? {
        guard let index = controls.firstIndex(of: item), let parameters,
              parameters.indices.contains(index), let range = item.range else { return nil }
        let value = item.value(parameters[index])
        return range.contains(value) ? value : nil
    }

    func current(_ setting: Setting) -> [UInt8]? {
        switch setting {
        case .controls: return parameters.map { [UInt8($0.count)] + $0 }
        case .scoring: return scoring.map { [$0.rawValue] }
        case .live: return liveEnabled.map { [$0 ? 0 : 1] }
        }
    }

    func canAdjust(_ item: Item) -> Bool {
        available && (item != .vocal || availability != .exceptVocal) && value(item) != nil
    }

    func controlsPayload(_ changes: [Item: Int]) -> [UInt8]? {
        guard let inquiry, let parameters, !changes.isEmpty,
              controls.count == parameters.count, controls.allSatisfy({ value($0) != nil }),
              changes.allSatisfy({ canAdjust($0.key) && $0.key.range?.contains($0.value) == true }) else { return nil }
        let values = zip(controls, parameters).map { item, original in
            changes[item].map { UInt8(bitPattern: Int8($0)) } ?? original
        }
        guard values != parameters else { return nil }
        return [0x78, inquiry, UInt8(values.count)] + values
    }

    func scoringPayload(_ next: Scoring) -> [UInt8]? {
        guard let inquiry, available, items?.contains(.scoring) == true,
              scoring?.next == next else { return nil }
        return [0x74, inquiry, next.rawValue]
    }

    func samplePayload(_ sample: Sample) -> [UInt8]? {
        guard let inquiry, available, items?.contains(.sampler) == true, samples.contains(sample) else { return nil }
        return [0x7C, inquiry, sample.rawValue]
    }

    func livePayload(_ enabled: Bool) -> [UInt8]? {
        guard supportsLive, available, let previous = liveEnabled, previous != enabled else { return nil }
        return [0x78, 5, enabled ? 0 : 1]
    }

    func acceptsSetPayload(_ payload: [UInt8], setting: Setting) -> Bool {
        guard self.setting(forWrite: payload) == setting else { return false }
        switch setting {
        case .controls:
            guard payload.count == controls.count + 3 else { return false }
            var changes: [Item: Int] = [:]
            for (item, byte) in zip(controls, payload.dropFirst(3)) {
                let proposed = item.value(byte)
                if value(item) != proposed { changes[item] = proposed }
            }
            return controlsPayload(changes) == payload
        case .scoring:
            return Scoring(rawValue: payload[2]).flatMap(scoringPayload) == payload
        case .live:
            return payload[2] <= 1 && livePayload(payload[2] == 0) == payload
        }
    }

    func readQuery(for payload: [UInt8]) -> (query: [UInt8], notification: Bool)? {
        guard payload.count >= 2,
              payload[1] == inquiry || (supportsLive && payload[1] == 5 && [0x77, 0x79].contains(payload[0])) else { return nil }
        switch payload[0] {
        case 0x71, 0x73, 0x77: return ([payload[0] - 1, payload[1]], false)
        case 0x75, 0x79: return ([payload[0] - 3, payload[1]], true)
        default: return nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard frameType == Self.frameType, readQuery(for: payload) != nil, payload.count >= 3 else { return false }
        switch payload[0] {
        case 0x71:
            let end = Int(payload[2]) + 3
            guard end > 3, payload.count > end, payload.count == end + 1 + Int(payload[end]) else { return false }
            let items = payload[3..<end].compactMap(Item.init(rawValue:))
            let samples = payload.dropFirst(end + 1).compactMap(Sample.init(rawValue:))
            guard items.count == end - 3, samples.count == Int(payload[end]) else { return false }
            self.items = items
            self.samples = samples
        case 0x73, 0x75:
            guard payload.count >= 5, let availability = Availability(rawValue: payload[2]),
                  let scoring = Scoring(rawValue: payload[4]), payload[3] <= 1 else { return false }
            if inquiry == 4 {
                guard payload.count >= 6, payload.count == 6 + Int(payload[5]) else { return false }
                let reasons = payload.dropFirst(6).compactMap(DisableReason.init(rawValue:))
                guard reasons.count == Int(payload[5]) else { return false }
                disableReasons = reasons
            } else {
                guard payload.count == 5, availability != .exceptVocal else { return false }
                disableReasons = availability == .disabled ? [.tvSoundBooster] : []
            }
            self.availability = availability
            self.scoring = scoring
            micPlugged = payload[3] == 0
        case 0x77 where payload[1] == 5, 0x79 where payload[1] == 5:
            guard payload.count == 3, payload[2] <= 1 else { return false }
            liveEnabled = payload[2] == 0
        case 0x77, 0x79:
            let end = 3 + Int(payload[2])
            guard payload.count == end + 1, payload[end] <= 99 || payload[end] == 0xFF else { return false }
            parameters = Array(payload[3..<end])
            score = payload[end] == 0xFF ? nil : payload[end]
        default: return false
        }
        return true
    }
}
