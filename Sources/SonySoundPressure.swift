import Foundation

enum SonySoundPressureReading: Equatable, Sendable {
    case decibels(Int), notPlaying, inCall, notWorn
    case unknown(level: UInt8, reason: UInt8)
}

enum SonySoundPressureMode: CaseIterable, Hashable, Sendable {
    case off, preview, recording

    var flags: [UInt8] {
        switch self {
        case .off: [1, 1]
        case .preview: [1, 0]
        case .recording: [0, 1]
        }
    }
}

struct SonyExposureBatch: Equatable, Sendable {
    enum Status: UInt8, Sendable { case disconnected, sending, completed, notSending, error }

    struct Record: Equatable, Sendable {
        struct Key: Hashable, Sendable {
            let target: UInt8
            let timestamp: UInt32
            let resetCounter: UInt16
        }

        let key: Key
        let listeningMinutes: UInt8
        let pressure: Int32
        let ambientMinutes: UInt8?
    }

    let statuses: [Status]
    let records: [Record]
}

struct SonyExposureHistory: Equatable, Sendable {
    let channelCount: Int
    private var seen: Set<SonyExposureBatch.Record.Key> = []
    private var listeningTotal = 0
    private var pressureTotal: Int64 = 0
    private(set) var ambientMinutes: Int?
    private(set) var incomplete = false

    var isEmpty: Bool { seen.isEmpty }
    var listeningMinutes: Int { listeningTotal / channelCount }
    var averageDecibels: Int? {
        guard listeningTotal > 0, pressureTotal > 0 else { return nil }
        let pressure = pressureTotal / 100_000
        guard pressure > 0 else { return nil }
        let meanSquarePressure = (Float(pressure) / Float(channelCount) / 60) / (Float(listeningTotal) / Float(channelCount))
        return Int(Float(10 * log10(Double(meanSquarePressure) / 4e-10)))
    }

    mutating func append(_ batch: SonyExposureBatch) -> Bool {
        for record in batch.records {
            let target = Int(record.key.target)
            let index = channelCount == 1 ? target : target - 1
            guard batch.statuses.indices.contains(index), [.sending, .completed].contains(batch.statuses[index]),
                  seen.insert(record.key).inserted else { continue }
            guard seen.count <= 100_000 else { return false }
            listeningTotal += Int(record.listeningMinutes)
            pressureTotal += Int64(record.pressure)
            if let minutes = record.ambientMinutes { ambientMinutes = (ambientMinutes ?? 0) + Int(minutes) }
        }
        incomplete = batch.statuses.contains(.disconnected)
        return true
    }
}

struct SonySoundPressure: Equatable, Sendable {
    let inquiryType: UInt8?
    private(set) var roundBase: UInt8?
    private(set) var timestampBase: UInt32?
    private(set) var minimumInterval: UInt8?
    private(set) var logCapacity: UInt8?
    private(set) var available: Bool?
    private(set) var measurementEnabled: Bool?
    private(set) var previewEnabled: Bool?
    private(set) var reading: SonySoundPressureReading?

    init(supportedFunctions: Set<UInt8> = []) {
        inquiryType = (UInt8(0x50)...0x53).last(where: supportedFunctions.contains).map { $0 - 0x50 }
    }

    var isSupported: Bool { inquiryType != nil }
    var levelQueryPayload: [UInt8]? { inquiryType.map { [0x5A, $0] } }
    var exposureQueryPayload: [UInt8]? { inquiryType.map { [0x52, $0] } }

    var queryPayloads: [[UInt8]] {
        guard let inquiryType else { return [] }
        return (minimumInterval == nil ? [[0x50, inquiryType]] : []) + [[0x56, inquiryType]]
    }

    var intervalSeconds: Int? {
        guard let minimumInterval, minimumInterval > 0 else { return nil }
        return Int(minimumInterval)
    }

    var isStopped: Bool { measurementEnabled == false && previewEnabled == false }

    var mode: SonySoundPressureMode? {
        guard let measurementEnabled, let previewEnabled else { return nil }
        return SonySoundPressureMode.allCases.first { $0.flags == [measurementEnabled ? 0 : 1, previewEnabled ? 0 : 1] }
    }

    func modePayload(_ mode: SonySoundPressureMode) -> [UInt8]? {
        inquiryType.map { [0x58, $0] + mode.flags }
    }

    func historyPayload(start: Bool) -> [UInt8]? {
        guard let inquiryType else { return nil }
        let status = start ? SonyExposureBatch.Status.sending.rawValue : SonyExposureBatch.Status.notSending.rawValue
        let statuses = Array(repeating: status, count: inquiryType.isMultiple(of: 2) ? 1 : 2)
        return [0x54, inquiryType] + statuses + Array(repeating: 0, count: 6 * statuses.count)
    }

    func exposureBatch(_ payload: [UInt8]) -> SonyExposureBatch? {
        guard let inquiryType, payload.count >= 2, payload[1] == inquiryType else { return nil }
        let channels = inquiryType.isMultiple(of: 2) ? 1 : 2
        let includesAmbient = inquiryType >= 2
        let size = includesAmbient ? 13 : 12
        let recordOffset = 2 + channels
        guard payload.count >= recordOffset + 1 else { return nil }
        let statuses = payload[2..<recordOffset].compactMap { SonyExposureBatch.Status(rawValue: $0) }
        guard statuses.count == channels else { return nil }
        let recordsStart: Int
        let count: Int
        switch payload[0] {
        case 0x53:
            recordsStart = recordOffset
            count = channels
        case 0x55:
            recordsStart = recordOffset + 1
            count = Int(payload[recordOffset])
        default: return nil
        }
        guard payload.count == recordsStart + count * size else { return nil }
        var records: [SonyExposureBatch.Record] = []
        for start in stride(from: recordsStart, to: payload.count, by: size) {
            let target = payload[start]
            guard target <= 2 else { return nil }
            let timestamp = payload[(start + 1)..<(start + 5)].reduce(UInt32.zero) { $0 << 8 | UInt32($1) }
            let resetCounter = UInt16(payload[start + 5]) << 8 | UInt16(payload[start + 6])
            let pressure = payload[(start + 8)..<(start + 12)].reduce(UInt32.zero) { $0 << 8 | UInt32($1) }
            records.append(.init(key: .init(target: target, timestamp: timestamp, resetCounter: resetCounter),
                                 listeningMinutes: payload[start + 7], pressure: Int32(bitPattern: pressure),
                                 ambientMinutes: includesAmbient ? payload[start + 12] : nil))
        }
        return SonyExposureBatch(statuses: statuses, records: records)
    }

    mutating func invalidateReading() {
        reading = nil
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0E) -> Bool {
        guard frameType == 0x0E, payload.count >= 2, payload[1] == inquiryType else { return false }
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

struct SonyVolumeProtection: Equatable, Sendable {
    enum LimitPreset: UInt8, CaseIterable, Sendable {
        case percent30, percent40, percent50, percent60, percent70

        var percent: Int { 30 + Int(rawValue) * 10 }
    }

    enum LimitPattern: UInt8, Sendable { case closed, openAir }
    enum HearingProfile: UInt8, Sendable { case standard, sensitive }

    let supportsSafeVolume: Bool
    let supportsMaxVolume: Bool
    private(set) var automaticallyLimiting: Bool?
    private(set) var safeVolumeEnabled: Bool?
    private(set) var hearingProfile: HearingProfile?
    private(set) var limitPattern: LimitPattern?
    private(set) var limitCapabilityValue: UInt8?
    private(set) var maxVolumeEnabled: Bool?
    private(set) var limitPreset: LimitPreset?

    init(supportedFunctions: Set<UInt8> = []) {
        supportsSafeVolume = supportedFunctions.contains(0x54)
        supportsMaxVolume = supportedFunctions.contains(0x55)
    }

    var queryPayloads: [[UInt8]] {
        guard supportsMaxVolume else { return [] }
        return (limitPattern == nil ? [[0x50, 0x05]] : [])
            + (maxVolumeEnabled == nil ? [[0x52, 0x05]] : [])
            + (limitPreset == nil ? [[0x56, 0x05]] : [])
    }

    var enablePayload: [UInt8]? {
        guard limitPattern != nil, limitPreset != nil, maxVolumeEnabled == false else { return nil }
        return [0x54, 0x05, 0x00]
    }

    func limitPayload(_ preset: LimitPreset) -> [UInt8]? {
        guard limitPattern != nil, maxVolumeEnabled == true, let limitPreset, limitPreset != preset else { return nil }
        return [0x58, 0x05, preset.rawValue]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8], frameType: UInt8 = 0x0E) -> Bool {
        guard frameType == 0x0E, payload.count >= 3 else { return false }
        switch (payload[0], payload[1]) {
        case (0x55, 0x04) where supportsSafeVolume:
            guard payload.count == 3, let profile = HearingProfile(rawValue: payload[2]) else { return false }
            hearingProfile = profile
        case (0x59, 0x04) where supportsSafeVolume:
            guard payload.count == 4, payload[2] <= 1, payload[3] <= 1 else { return false }
            automaticallyLimiting = payload[2] == 0
            safeVolumeEnabled = payload[3] == 0
        case (0x51, 0x05) where supportsMaxVolume:
            guard payload.count == 4, let pattern = LimitPattern(rawValue: payload[2]) else { return false }
            limitPattern = pattern
            limitCapabilityValue = payload[3]
        case (0x53, 0x05), (0x55, 0x05):
            guard supportsMaxVolume, payload.count == 3, payload[2] <= 1 else { return false }
            maxVolumeEnabled = payload[2] == 0
        case (0x57, 0x05), (0x59, 0x05):
            guard supportsMaxVolume, payload.count == 3, let preset = LimitPreset(rawValue: payload[2]) else { return false }
            limitPreset = preset
        default: return false
        }
        return true
    }
}
