import Foundation

enum SonySoundPressureReading: Equatable, Sendable {
    case decibels(Int), notPlaying, inCall, notWorn
    case unknown(level: UInt8, reason: UInt8)
}

struct SonySoundPressure: Equatable, Sendable {
    static let levelQueryPayload: [UInt8] = [0x5A, 0x03]

    let isSupported: Bool
    private(set) var roundBase: UInt8?
    private(set) var timestampBase: UInt32?
    private(set) var minimumInterval: UInt8?
    private(set) var logCapacity: UInt8?
    private(set) var available: Bool?
    private(set) var measurementEnabled: Bool?
    private(set) var previewEnabled: Bool?
    private(set) var reading: SonySoundPressureReading?

    init(supportedFunctions: Set<UInt8> = []) {
        isSupported = supportedFunctions.contains(0x53)
    }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return (minimumInterval == nil ? [[0x50, 0x03]] : []) + [[0x56, 0x03]]
    }

    var intervalSeconds: Int? {
        guard let minimumInterval, minimumInterval > 0 else { return nil }
        return Int(minimumInterval)
    }

    var isStopped: Bool { measurementEnabled == false && previewEnabled == false }

    mutating func invalidateReading() {
        reading = nil
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0E) -> Bool {
        guard isSupported, frameType == 0x0E, payload.count >= 2, payload[1] == 0x03 else { return false }
        switch payload[0] {
        case 0x51:
            guard payload.count == 9 else { return false }
            roundBase = payload[2]
            timestampBase = UInt32(payload[3]) << 24 | UInt32(payload[4]) << 16
                | UInt32(payload[5]) << 8 | UInt32(payload[6])
            minimumInterval = payload[7]
            logCapacity = payload[8]
        case 0x57:
            guard payload.count == 3 else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
            if available != true { invalidateReading() }
        case 0x59:
            guard payload.count == 4 else { return false }
            let measurementEnabled: Bool? = payload[2] <= 1 ? payload[2] == 0 : nil
            let previewEnabled: Bool? = payload[3] <= 1 ? payload[3] == 0 : nil
            if self.measurementEnabled != measurementEnabled || self.previewEnabled != previewEnabled
                || measurementEnabled == nil || previewEnabled == nil {
                invalidateReading()
            }
            self.measurementEnabled = measurementEnabled
            self.previewEnabled = previewEnabled
        case 0x5B:
            guard payload.count == 4, payload[2] != 0xFF || payload[3] <= 2 else { return false }
            reading = switch payload[3] {
            case 0: .notPlaying
            case 1: .inCall
            case 2: .notWorn
            case 0xFF: .decibels(Int(payload[2]))
            default: .unknown(level: payload[2], reason: payload[3])
            }
        default:
            return false
        }
        return true
    }
}
