import Foundation

struct SonyAuracast: Equatable, Sendable {
    enum Variant: UInt8, Sendable {
        case standard = 0x76
        case requiresLEAudio = 0x77

        var statusInquiry: UInt8 { self == .standard ? 6 : 9 }
    }

    enum Restriction: UInt8, Sendable {
        case none, call, partyChain, stereoPair
        case outOfRange = 0xFF
    }

    enum ScanStatus: UInt8, Sendable {
        case scanning, stopped, timedOut, receptionRequested
        case outOfRange = 0xFF
    }

    enum Reception: UInt8, Sendable {
        case start, stop
    }

    enum ReceptionResult: UInt8, Sendable {
        case started, passwordRequired, incorrectPassword, notFound, stopped
        case outOfRange = 0xFF
    }

    struct Broadcast: Identifiable, Equatable, Sendable {
        enum Protection: UInt8, Sendable {
            case unknown, open, password
            case outOfRange = 0xFF
        }

        let id: [UInt8]
        let name: String
        let program: String
        let protection: Protection
    }

    enum Report: Equatable, Sendable {
        case availability(Bool, Restriction)
        case reception(receiving: Bool?, broadcast: Broadcast)
        case scan(ScanStatus)
        case discovered(Broadcast)
        case result(ReceptionResult, id: [UInt8])
    }

    static let frameType: UInt8 = 0x0E
    static let receptionQuery: [UInt8] = [0x76, 6]
    static let scanPrefix: [UInt8] = [0x78, 7]
    static let receptionPrefix: [UInt8] = [0x78, 8]

    let variant: Variant?
    private(set) var available: Bool?
    private(set) var restriction: Restriction?
    private(set) var receiving: Bool?
    private(set) var current: Broadcast?
    private(set) var scan: ScanStatus?
    private(set) var broadcasts: [Broadcast] = []

    init(supportedFunctions2: Set<UInt8> = []) {
        variant = supportedFunctions2.contains(Variant.standard.rawValue) ? .standard
            : supportedFunctions2.contains(Variant.requiresLEAudio.rawValue) ? .requiresLEAudio : nil
    }

    var statusQuery: [UInt8]? { variant.map { [0x72, $0.statusInquiry] } }

    var queryPayloads: [[UInt8]] {
        guard let variant, let statusQuery else { return [] }
        return variant == .standard ? [statusQuery, Self.receptionQuery] : [statusQuery]
    }

    func canOperate(leAudioEnabled: Bool?) -> Bool {
        available == true && (variant == .standard || leAudioEnabled == true)
    }

    func scanPayload(start: Bool) -> [UInt8] {
        Self.scanPrefix + [start ? 0 : 1]
    }

    static func validPassword(_ password: String) -> Bool {
        (4...16).contains(password.utf16.count)
    }

    func receptionPayload(_ operation: Reception, broadcastID: [UInt8], password: String = "") -> [UInt8]? {
        guard broadcastID.count == 15, password.isEmpty || operation == .start && Self.validPassword(password) else { return nil }
        let bytes = Array(password.utf8)
        return Self.receptionPrefix + [operation.rawValue] + broadcastID + [UInt8(bytes.count)] + bytes
    }

    func report(_ payload: [UInt8]) -> Report? {
        guard let variant, payload.count >= 3 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x73, variant.statusInquiry), (0x75, 6):
            guard payload.count == 4, payload[2] <= 1, let restriction = Restriction(rawValue: payload[3]) else { return nil }
            return .availability(payload[2] == 0, restriction)
        case (0x77, 6), (0x79, 6):
            guard payload[2] <= 1 || payload[2] == 0xFF, let broadcast = Self.broadcast(payload, at: 3) else { return nil }
            return .reception(receiving: payload[2] == 0xFF ? nil : payload[2] == 1, broadcast: broadcast)
        case (0x79, 7):
            guard payload.count == 3, let scan = ScanStatus(rawValue: payload[2]) else { return nil }
            return .scan(scan)
        case (0x7D, 7):
            return Self.broadcast(payload, at: 2).map(Report.discovered)
        case (0x79, 8):
            guard payload.count == 18, let result = ReceptionResult(rawValue: payload[2]) else { return nil }
            return .result(result, id: Array(payload[3..<18]))
        default:
            return nil
        }
    }

    mutating func invalidateAvailability() {
        available = nil
        restriction = nil
    }

    mutating func update(_ report: Report) {
        switch report {
        case .availability(let available, let restriction):
            self.available = available
            self.restriction = restriction
        case .reception(let receiving, let broadcast):
            self.receiving = receiving
            current = receiving == true ? broadcast : nil
        case .scan(let scan):
            if scan == .scanning, self.scan != .scanning { broadcasts.removeAll() }
            self.scan = scan
        case .discovered(let broadcast):
            if let index = broadcasts.firstIndex(where: { $0.id == broadcast.id }) {
                broadcasts[index] = broadcast
            } else {
                broadcasts.append(broadcast)
            }
        case .result(let result, let id):
            if result == .passwordRequired,
               let index = broadcasts.firstIndex(where: { $0.id == id }) {
                let broadcast = broadcasts[index]
                broadcasts[index] = Broadcast(id: id, name: broadcast.name, program: broadcast.program, protection: .password)
            }
        }
    }

    private static func broadcast(_ payload: [UInt8], at start: Int) -> Broadcast? {
        let endID = start + 15
        guard payload.count >= endID + 3, let protection = Broadcast.Protection(rawValue: payload[endID]) else { return nil }
        let endName = endID + 2 + Int(payload[endID + 1])
        guard endName < payload.count, payload.count == endName + 1 + Int(payload[endName]) else { return nil }
        return Broadcast(id: Array(payload[start..<endID]),
                         name: String(decoding: payload[(endID + 2)..<endName], as: UTF8.self),
                         program: String(decoding: payload[(endName + 1)...], as: UTF8.self),
                         protection: protection)
    }
}
