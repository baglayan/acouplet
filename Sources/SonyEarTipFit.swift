import Foundation

struct SonyEarTipFit: Equatable, Sendable {
    enum Series: UInt8, Sendable {
        case other = 0x00, polyurethane = 0x01, hybrid = 0x02, softFitting = 0x03
        case notDetermined = 0xFF

        var title: String {
            switch self {
            case .other: String(localized: "Other")
            case .polyurethane: String(localized: "Polyurethane")
            case .hybrid: String(localized: "Hybrid silicone")
            case .softFitting: String(localized: "Soft fitting")
            case .notDetermined: String(localized: "Not determined")
            }
        }
    }

    enum Size: UInt8, Sendable {
        case ss = 0x00, s = 0x01, m = 0x02, l = 0x03, ll = 0x04
        case notDetermined = 0xFF
    }

    enum Mode: UInt8, Sendable {
        case out = 0x00, `in` = 0x01
    }

    enum ModeResult: UInt8, Sendable {
        case noError = 0x00, forcedOut = 0x01
    }

    enum OperationState: UInt8, Sendable {
        case notStarted = 0x00, started = 0x01, completed = 0x02, failed = 0x03
    }

    enum OperationError: UInt8, Sendable {
        case noError = 0x00, leftConnection = 0x01, rightConnection = 0x02, functionUnavailable = 0x03
        case leftFitting = 0x04, rightFitting = 0x05, bothFitting = 0x06, measuring = 0x07
    }

    enum Seal: UInt8, Sendable {
        case good = 0x00, poor = 0x01
    }

    struct Earpiece: Equatable, Sendable {
        let series: Series
        let sizes: [Size]
    }

    struct Capability: Equatable, Sendable {
        let duration: UInt8
        let earpieces: [Earpiece]

        var durationSeconds: Int? { (1...127).contains(duration) ? Int(duration) : nil }
    }

    struct Status: Equatable, Sendable {
        let available: Bool
        let mode: Mode
        let count: UInt8
        let result: ModeResult
    }

    struct Operation: Equatable, Sendable {
        let state: OperationState
        let error: OperationError
        let count: UInt8
        let index: UInt8
        let series: Series
        let size: Size
    }

    struct Result: Equatable, Sendable {
        let left: Seal
        let right: Seal
        let bestSeriesLeft: Series
        let bestSeriesRight: Series
        let bestSizeLeft: Size
        let bestSizeRight: Size
    }

    static let capabilityQueryPayload: [UInt8] = [0xF0, 0x06]
    static let statusQueryPayload: [UInt8] = [0xF2, 0x06]
    static let operationQueryPayload: [UInt8] = [0xF6, 0x06]
    static let selectionStatusQueryPayload: [UInt8] = [0xF2, 0x07]
    static let selectionQueryPayload: [UInt8] = [0xF6, 0x07]
    static let enterModePayload: [UInt8] = [0xF4, 0x06, 0x01, 0x01]
    static let exitModePayload: [UInt8] = [0xF4, 0x06, 0x00, 0x01]

    let isSupported: Bool
    let supportsEarpieceSelection: Bool
    private(set) var capability: Capability?
    private(set) var selectionAvailable: Bool?
    private(set) var selectedSeries: Series?
    private(set) var status: Status?
    private(set) var operation: Operation?
    private(set) var result: Result?

    init(supportedFunctions: Set<UInt8> = []) {
        isSupported = supportedFunctions.contains(0xF6)
        supportsEarpieceSelection = supportedFunctions.contains(0xF7)
    }

    var measurementSeries: Series? {
        guard let capability else { return nil }
        return supportsEarpieceSelection ? selectedSeries : capability.earpieces.first?.series ?? .other
    }

    var queryPayloads: [[UInt8]] {
        let measurement = isSupported ? (capability == nil ? [Self.capabilityQueryPayload] : [])
            + [Self.statusQueryPayload, Self.operationQueryPayload] : []
        return measurement + (supportsEarpieceSelection ? [Self.selectionStatusQueryPayload, Self.selectionQueryPayload] : [])
    }

    var selectionTitle: String {
        selectedSeries?.title ?? String(localized: "Unknown")
    }

    mutating func resetMeasurement() {
        capability = nil
        status = nil
        operation = nil
        result = nil
    }

    static func startPayload(series: Series) -> [UInt8] {
        [0xF8, 0x06, 0x00, 0x00, series.rawValue, 0xFF]
    }

    static func cancelPayload(series: Series) -> [UInt8] {
        [0xF8, 0x06, 0x01, 0x00, series.rawValue, 0xFF]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard frameType == 0x0C, payload.count >= 2 else { return false }
        if payload[1] == 0x07 {
            guard supportsEarpieceSelection, payload.count == 3 else { return false }
            switch payload[0] {
            case 0xF3, 0xF5:
                guard payload[2] <= 1 else { return false }
                selectionAvailable = payload[2] == 0
            case 0xF7, 0xF9:
                guard let series = Series(rawValue: payload[2]) else { return false }
                selectedSeries = series
            default: return false
            }
            return true
        }
        guard isSupported, payload[1] == 0x06 else { return false }
        switch payload[0] {
        case 0xF1:
            guard payload.count >= 4 else { return false }
            var offset = 4
            var earpieces: [Earpiece] = []
            for _ in 0..<payload[3] {
                guard offset + 2 <= payload.count, let series = Series(rawValue: payload[offset]),
                      series != .notDetermined else { return false }
                let sizeCount = Int(payload[offset + 1])
                offset += 2
                guard offset + sizeCount <= payload.count else { return false }
                let sizes = payload[offset..<(offset + sizeCount)].compactMap(Size.init(rawValue:))
                guard sizes.count == sizeCount, !sizes.contains(.notDetermined) else { return false }
                earpieces.append(Earpiece(series: series, sizes: sizes))
                offset += sizeCount
            }
            guard offset == payload.count else { return false }
            capability = Capability(duration: payload[2], earpieces: earpieces)
        case 0xF3, 0xF5:
            guard payload.count == 6, payload[2] <= 1, let mode = Mode(rawValue: payload[3]),
                  let result = ModeResult(rawValue: payload[5]) else { return false }
            status = Status(available: payload[2] == 0, mode: mode, count: payload[4], result: result)
        case 0xF7, 0xF9:
            guard payload.count == 8, let state = OperationState(rawValue: payload[2]),
                  let error = OperationError(rawValue: payload[3]), let series = Series(rawValue: payload[6]),
                  let size = Size(rawValue: payload[7]) else { return false }
            operation = Operation(state: state, error: error, count: payload[4], index: payload[5],
                                  series: series, size: size)
        case 0xFB, 0xFD:
            guard payload.count == 8, let left = Seal(rawValue: payload[2]),
                  let right = Seal(rawValue: payload[3]), let leftSeries = Series(rawValue: payload[4]),
                  let rightSeries = Series(rawValue: payload[5]), let leftSize = Size(rawValue: payload[6]),
                  let rightSize = Size(rawValue: payload[7]) else { return false }
            result = Result(left: left, right: right, bestSeriesLeft: leftSeries, bestSeriesRight: rightSeries,
                            bestSizeLeft: leftSize, bestSizeRight: rightSize)
        default:
            return false
        }
        return true
    }
}

struct SonyWearingPosition: Equatable, Sendable {
    enum Shape: UInt8, Sendable { case canal, openRing }

    enum Result: String, Sendable {
        case correct, reversedSides, insideOut, upsideDown, adjust, failed

        var message: String {
            switch self {
            case .correct: String(localized: "The earbuds are oriented correctly.")
            case .reversedSides: String(localized: "Check that the left and right earbuds are in the correct ears.")
            case .insideOut: String(localized: "Check that the earbuds are facing inward correctly.")
            case .upsideDown: String(localized: "Check that neither earbud is upside down.")
            case .adjust: String(localized: "Adjust how the earbuds sit, then look straight ahead and try again.")
            case .failed: String(localized: "The earbuds could not complete the position check.")
            }
        }
    }

    static let capabilities: Set<UInt8> = [0xF6, 0xFF]
    static let frameType: UInt8 = 0x0E
    static let infoQuery: [UInt8] = [0xF0, 0x07]
    static let statusQuery: [UInt8] = [0xF2, 0x08]
    static let startPayload: [UInt8] = [0xF8, 0x08, 0]

    let isSupported: Bool
    private(set) var shape: Shape?
    private(set) var duration: UInt8?
    private(set) var available: Bool?

    init(supportedFunctions2: Set<UInt8> = []) {
        isSupported = !supportedFunctions2.isDisjoint(with: Self.capabilities)
    }

    var queryPayloads: [[UInt8]] { isSupported ? [Self.infoQuery, Self.statusQuery] : [] }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported else { return false }
        if payload.count == 4, payload.starts(with: [0xF1, 7]), let shape = Shape(rawValue: payload[2]), payload[3] < 128 {
            self.shape = shape
            duration = payload[3]
            return true
        }
        guard payload.count == 3, [0xF3, 0xF5].contains(payload[0]), payload[1] == 8, payload[2] <= 1 else { return false }
        available = payload[2] == 0
        return true
    }

    static func decodeResult(_ payload: [UInt8]) -> Result? {
        guard payload.count >= 16, payload.starts(with: [0xF9, 8]), payload[2] <= 1 else { return nil }
        let count = Int(payload[3])
        guard payload.count == 16 + 4 * count,
              (0..<(2 * count)).allSatisfy({ payload[4 + 2 * $0] <= 5 && payload[5 + 2 * $0] <= 1 }) else { return nil }
        if payload[2] == 1 { return .failed }
        let left = payload[4..<(4 + 2 * count)]
        let right = payload[(4 + 2 * count)..<(4 + 4 * count)]
        guard left.elementsEqual(right) else { return .adjust }
        let issues = stride(from: 4, to: 4 + 2 * count, by: 2).filter { payload[$0 + 1] == 1 }.map { payload[$0] }
        if issues.contains(4) { return .reversedSides }
        if issues.contains(2) { return .insideOut }
        if issues.contains(3) { return .upsideDown }
        return issues.isEmpty ? .correct : .adjust
    }
}
