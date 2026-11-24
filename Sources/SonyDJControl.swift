struct SonyDJControl: Equatable, Sendable {
    static let frameType: UInt8 = 0x0E

    enum Effect: UInt8, Hashable, Sendable {
        case off = 0, isolator, flanger, drums, audience, phaser, rhythm, scratch, voice
        case reggaeHorn, robot, customEQ, drumRoll, explosion, clap, sevenDrums

        var usesTouchPad: Bool { self == .isolator || self == .flanger }

        var samplePositions: [[Int]] {
            switch self {
            case .drums, .rhythm, .voice, .robot:
                [[-40, -40], [40, 40], [-40, 40], [40, -40]]
            case .sevenDrums:
                [[30, 30], [-30, 70], [30, 70], [70, 40], [-70, 30], [-30, 30], [-70, 70]]
            case .audience, .phaser, .scratch, .reggaeHorn, .drumRoll, .explosion, .clap:
                [[40, 40]]
            default:
                []
            }
        }
    }

    enum DisableReason: UInt8, Hashable, Sendable {
        case tvSoundBooster = 0, demoMode, speaking
    }

    let inquiry: UInt8?
    private(set) var options: [Effect]?
    private(set) var bandCount: UInt8?
    private(set) var bandStep: UInt8?
    private(set) var available: Bool?
    private(set) var equalizerAvailable: Bool?
    private(set) var disableReasons: [DisableReason] = []
    private(set) var effect: Effect?
    private(set) var bands: [UInt8]?

    init(supportedFunctions2: Set<UInt8> = []) {
        inquiry = supportedFunctions2.contains(0x70) ? 0 : supportedFunctions2.contains(0x73) ? 3 : nil
    }

    var parameterQuery: [UInt8]? { inquiry.map { [0x76, $0] } }
    var queryPayloads: [[UInt8]] { inquiry.map { [[0x70, $0], [0x72, $0], [0x76, $0]] } ?? [] }

    var parameterValue: [UInt8]? {
        guard let effect, let bands else { return nil }
        return [effect.rawValue, UInt8(bands.count)] + bands
    }

    func setPayload(effect: Effect, bands updatedBands: [UInt8]? = nil) -> [UInt8]? {
        guard let inquiry, let options, let currentBands = bands,
              effect == .off || options.contains(effect),
              (effect == .customEQ ? equalizerAvailable : available) == true else { return nil }
        let value = updatedBands ?? currentBands
        if value != currentBands {
            guard effect == .customEQ, let bandCount, let bandStep,
                  value.count == Int(bandCount), value.allSatisfy({ $0 <= bandStep }) else { return nil }
        }
        return [0x78, inquiry, effect.rawValue, UInt8(value.count)] + value
    }

    func acceptsSetPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 5, let effect = Effect(rawValue: payload[2]) else { return false }
        return setPayload(effect: effect, bands: Array(payload.dropFirst(4))) == payload
    }

    func touchPayload(operation: UInt8, x: Int, y: Int) -> [UInt8]? {
        guard let inquiry, available == true, let effect,
              options?.contains(effect) == true, effect.usesTouchPad || !effect.samplePositions.isEmpty,
              operation <= 2, (-100...100).contains(x), (-100...100).contains(y) else { return nil }
        return [0x7C, inquiry, operation, UInt8(bitPattern: Int8(x)), UInt8(bitPattern: Int8(y))]
    }

    func readQuery(for payload: [UInt8]) -> (query: [UInt8], notification: Bool)? {
        guard let inquiry, payload.count >= 2, payload[1] == inquiry else { return nil }
        switch payload[0] {
        case 0x71, 0x73, 0x77: return ([payload[0] - 1, inquiry], false)
        case 0x75, 0x79: return ([payload[0] - 3, inquiry], true)
        default: return nil
        }
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8) -> Bool {
        guard frameType == Self.frameType, readQuery(for: payload) != nil, payload.count >= 4 else { return false }
        switch payload[0] {
        case 0x71:
            let count = Int(payload[2])
            guard count > 0, payload.count == count + 5 else { return false }
            let options = payload[3..<(count + 3)].compactMap(Effect.init(rawValue:))
            guard options.count == count else { return false }
            self.options = options
            bandCount = payload[count + 3]
            bandStep = payload[count + 4]
        case 0x73, 0x75:
            guard payload[2] <= 1, payload[3] <= 1 else { return false }
            if inquiry == 3 {
                guard payload.count >= 5, payload.count == 5 + Int(payload[4]) else { return false }
                let reasons = payload.dropFirst(5).compactMap(DisableReason.init(rawValue:))
                guard reasons.count == Int(payload[4]) else { return false }
                disableReasons = reasons
            } else {
                guard payload.count == 4 else { return false }
                disableReasons = payload[2] == 0 && payload[3] == 0 ? [.tvSoundBooster] : []
            }
            available = payload[2] == 1
            equalizerAvailable = payload[3] == 1
        case 0x77, 0x79:
            guard payload[3] > 0, payload.count == 4 + Int(payload[3]), let effect = Effect(rawValue: payload[2]) else { return false }
            self.effect = effect
            bands = Array(payload.dropFirst(4))
        default: return false
        }
        return true
    }
}
