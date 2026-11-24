import Foundation

enum SonyConnectionEstablishedTime {
    static func payload(supportedFunctions: Set<UInt8>, at date: Date, timeZone: TimeZone) -> [UInt8]? {
        guard supportedFunctions.contains(0x16) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let seconds = Int64(date.timeIntervalSince1970)
        let offset = timeZone.secondsFromGMT(for: date) / 60
        var payload: [UInt8] = [0x18, 0x05, 0x00]
        payload.append(contentsOf: withUnsafeBytes(of: seconds.bigEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(components.year!).bigEndian) { Array($0) })
        payload += [UInt8(components.month!), UInt8(components.day!), UInt8(components.hour!),
                    UInt8(components.minute!), UInt8(components.second!),
                    UInt8(bitPattern: Int8(offset / 60)), UInt8(bitPattern: Int8(offset % 60))]
        return payload
    }

    static func acknowledges(_ payload: [UInt8]) -> Bool {
        payload.starts(with: [0x19, 0x05])
    }
}

struct SonyLEAudioStandby: Equatable, Sendable {
    enum Field: UInt8, Sendable {
        case availability = 0x42
        case setting = 0x46

        var inquiry: [UInt8] { [rawValue, 0x0C] }
    }

    struct Report: Equatable, Sendable {
        let field: Field
        let enabled: Bool
        let notification: Bool
    }

    static let writePrefix: [UInt8] = [0x48, 0x0C]
    private(set) var available: Bool?
    private(set) var enabled: Bool?

    func preferencePayload(enabled: Bool) -> [UInt8]? {
        guard available == true, let current = self.enabled, current != enabled else { return nil }
        return Self.writePrefix + [enabled ? 0 : 1, 1]
    }

    static func requestedPreference(for alert: SonyConnectionAlert) -> Bool? {
        switch (alert.format, alert.messageID) {
        case (.fixed, 0x2C), (.flexible, 0x0E): false
        case (.fixed, 0x2D), (.flexible, 0x0F): true
        default: nil
        }
    }

    static func queries(supportedFunctions: Set<UInt8>) -> [[UInt8]] {
        guard supportedFunctions.contains(0x42) else { return [] }
        return [Field.availability.inquiry, Field.setting.inquiry]
    }

    static func parse(_ payload: [UInt8], supportedFunctions: Set<UInt8>) -> Report? {
        guard supportedFunctions.contains(0x42), payload.count == 3, payload[1] == 0x0C, payload[2] <= 1,
              [0x43, 0x45, 0x47, 0x49].contains(payload[0]) else { return nil }
        let field: Field = payload[0] < 0x46 ? .availability : .setting
        return Report(field: field, enabled: payload[2] == 0, notification: payload[0] != field.rawValue + 1)
    }

    mutating func update(_ report: Report) {
        switch report.field {
        case .availability:
            available = report.enabled
        case .setting:
            enabled = report.enabled
        }
    }
}

struct SonyLEAudioCapabilities: Equatable, Sendable {
    enum Mode: UInt8, Sendable {
        case highReliability, lowLatency, lowLatencyWithEQRestriction

        var title: String {
            switch self {
            case .highReliability: String(localized: "High reliability")
            case .lowLatency: String(localized: "Low latency")
            case .lowLatencyWithEQRestriction: String(localized: "Low latency with equalizer restrictions")
            }
        }
    }

    enum Report: Equatable, Sendable {
        case compatibility(UInt8)
        case supportedModes([Mode])
        case modeAvailability(Bool)
        case mode(Mode)
    }

    static let frameType: UInt8 = 0x0E
    let supportsHostStateNotification: Bool
    let supportsSwitchCompatibility: Bool
    let supportsConnectionMode: Bool
    private(set) var compatibilityVersion: UInt8?
    private(set) var supportedModes: [Mode]?
    private(set) var modeAvailable: Bool?
    private(set) var mode: Mode?

    init(supportedFunctions2: Set<UInt8> = []) {
        supportsHostStateNotification = supportedFunctions2.contains(0x60)
        supportsSwitchCompatibility = supportedFunctions2.contains(0x61)
        supportsConnectionMode = supportedFunctions2.contains(0x62)
    }

    var queryPayloads: [[UInt8]] {
        (supportsSwitchCompatibility ? [[0x60, 1]] : []) + (supportsConnectionMode ? [[0x60, 2], [0x62, 2], [0x66, 2]] : [])
    }

    func report(_ payload: [UInt8]) -> (report: Report, query: [UInt8], notification: Bool)? {
        guard payload.count >= 3 else { return nil }
        switch (payload[0], payload[1]) {
        case (0x61, 1) where supportsSwitchCompatibility && payload.count == 3:
            return (.compatibility(payload[2]), [0x60, 1], false)
        case (0x61, 2) where supportsConnectionMode && payload.count == 3 + Int(payload[2]):
            let modes = payload.dropFirst(3).compactMap(Mode.init(rawValue:))
            guard modes.count == payload.count - 3 else { return nil }
            return (.supportedModes(modes), [0x60, 2], false)
        case (0x63, 2), (0x65, 2):
            guard supportsConnectionMode, payload.count == 3, payload[2] <= 1 else { return nil }
            return (.modeAvailability(payload[2] == 0), [0x62, 2], payload[0] == 0x65)
        case (0x67, 2):
            guard supportsConnectionMode, payload.count == 3, let mode = Mode(rawValue: payload[2]) else { return nil }
            return (.mode(mode), [0x66, 2], false)
        default: return nil
        }
    }

    mutating func update(_ report: Report) {
        switch report {
        case .compatibility(let version): compatibilityVersion = version
        case .supportedModes(let values): supportedModes = values
        case .modeAvailability(let available): modeAvailable = available
        case .mode(let value): mode = value
        }
    }
}

enum SonyCommonConnection: Equatable, Sendable {
    enum RequestType: UInt8, Sendable {
        case underConfirmation = 0x00, execute = 0x01
    }

    case reconnectionRequest(requestType: RequestType, address: String)
    case releaseGATT

    static func parse(_ payload: [UInt8], supportedFunctions: Set<UInt8>) -> Self? {
        guard payload.count >= 2, payload[0] == 0x19 else { return nil }
        switch payload[1] {
        case 0x08:
            guard supportedFunctions.contains(0x1A), payload.count == 20,
                  let requestType = RequestType(rawValue: payload[2]),
                  payload[3...].enumerated().allSatisfy({ index, byte in
                      index % 3 == 2 ? byte == 0x3A
                          : (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
                  }) else { return nil }
            return .reconnectionRequest(requestType: requestType, address: String(decoding: payload[3...], as: UTF8.self).uppercased())
        case 0x0A:
            guard supportedFunctions.contains(0x1C), payload.count == 2 else { return nil }
            return .releaseGATT
        default:
            return nil
        }
    }
}
