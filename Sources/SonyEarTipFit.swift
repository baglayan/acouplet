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
    static let selectionQueryPayload: [UInt8] = [0xF6, 0x07]
    static let resultQueryPayload: [UInt8] = [0xFA, 0x06]
    static let enterModePayload: [UInt8] = [0xF4, 0x06, 0x01, 0x01]
    static let exitModePayload: [UInt8] = [0xF4, 0x06, 0x00, 0x01]

    let isSupported: Bool
    let supportsEarpieceSelection: Bool
    private(set) var capability: Capability?
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
        guard isSupported else { return [] }
        return (capability == nil ? [Self.capabilityQueryPayload] : [])
            + [Self.statusQueryPayload, Self.operationQueryPayload]
            + (supportsEarpieceSelection ? [Self.selectionQueryPayload] : [])
    }

    static func startPayload(series: Series) -> [UInt8] {
        [0xF8, 0x06, 0x00, 0x00, series.rawValue, 0xFF]
    }

    static func cancelPayload(series: Series) -> [UInt8] {
        [0xF8, 0x06, 0x01, 0x00, series.rawValue, 0xFF]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0C) -> Bool {
        guard isSupported, frameType == 0x0C, payload.count >= 2 else { return false }
        if payload[1] == 0x07 {
            guard supportsEarpieceSelection, payload.count == 3, payload[0] == 0xF7 || payload[0] == 0xF9,
                  let series = Series(rawValue: payload[2]) else { return false }
            selectedSeries = series
            return true
        }
        guard payload[1] == 0x06 else { return false }
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
