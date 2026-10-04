import CommonCrypto
import CryptoKit
import Foundation
import OSLog

struct SonyFirmwareVersion: Comparable, Sendable {
    let text: String
    private let parts: [Int]

    init?(_ text: String) {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ (1...3).contains($0.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let parts = components.map { Int($0)! }
        guard parts.map(String.init).joined(separator: ".") == text else { return nil }
        self.text = text
        self.parts = parts
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct SonyFirmwareUpdateIdentity: Equatable, Sendable {
    let categoryID: String
    let serviceID: String

    init?(categoryID: String, serviceID: String) {
        guard ["HP001", "HP002"].contains(categoryID), (1...128).contains(serviceID.utf8.count),
              serviceID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        self.categoryID = categoryID
        self.serviceID = serviceID
    }

    static func request(supportedFunctions: Set<UInt8>) -> [UInt8]? {
        let selectors: [(UInt8, UInt8)] = [(0x32, 0x02), (0x34, 0x04), (0x35, 0x05), (0x36, 0x06), (0x38, 0x07), (0x30, 0x10)]
        return selectors.first { supportedFunctions.contains($0.0) }.map { [0x36, $0.1] }
    }

    init?(payload: [UInt8], selector: UInt8) {
        guard payload.count >= 2, payload[0] == 0x37, payload[1] == selector,
              [0x02, 0x04, 0x05, 0x06, 0x07, 0x10].contains(selector) else { return nil }
        var offset = 2
        var strings: [String] = []
        for index in 0..<5 {
            guard offset < payload.count else { return nil }
            let count = Int(payload[offset])
            offset += 1
            guard (index < 2 ? 1...128 : 0...128).contains(count), offset + count <= payload.count,
                  let string = String(bytes: payload[offset..<(offset + count)], encoding: .utf8) else { return nil }
            strings.append(string)
            offset += count
        }
        self.init(categoryID: strings[0], serviceID: strings[1])
    }

    static func legacyValue(payload: [UInt8], selector: UInt8) -> String? {
        guard [0x02, 0x03].contains(selector), payload.count >= 4,
              payload[0] == 0x37, payload[1] == selector, (1...128).contains(payload[2]),
              payload.count == Int(payload[2]) + 3 else { return nil }
        return String(bytes: payload.dropFirst(3), encoding: .utf8)
    }

    var key: String { categoryID + "." + serviceID }
    var url: URL { URL(string: "https://info.update.sony.net/\(categoryID)/\(serviceID)/info/info.xml")! }
}

enum SonyFirmwareAvailability: Equatable, Sendable {
    case available(String)
    case noUpdate
    case unavailable
}

enum SonyFirmwareManifest {
    static func availability(data: Data, identity: SonyFirmwareUpdateIdentity, currentVersion: String) -> SonyFirmwareAvailability {
        guard let current = SonyFirmwareVersion(currentVersion), let xml = decode(data, identity: identity),
              let text = String(data: xml, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              let document = try? XMLDocument(data: xml, options: .nodeLoadExternalEntitiesNever),
              let root = document.rootElement(), root.name == "InformationFile",
              root.attribute(forName: "Version")?.stringValue == "1.0",
              root.attribute(forName: "Noop")?.stringValue == "false",
              root.elements(forName: "ControlConditions").count == 1,
              let controls = root.elements(forName: "ControlConditions").first,
              controls.attribute(forName: "DefaultServiceStatus")?.stringValue == "open",
              controls.attribute(forName: "DefaultVariance")?.stringValue == "0",
              controls.children?.contains(where: { $0.kind == .element }) != true,
              let conditions = try? root.nodes(forXPath: "ApplyConditions/ApplyCondition"), conditions.count == 1,
              let condition = conditions.first as? XMLElement,
              let rules = try? condition.nodes(forXPath: "Rules/Rule"), !rules.isEmpty,
              let distributions = try? condition.nodes(forXPath: "Distributions/Distribution[@ID='FW']"), distributions.count == 1,
              let firmware = distributions.first as? XMLElement,
              firmware.attribute(forName: "InstallType")?.stringValue == "binary",
              let latest = firmware.attribute(forName: "Version")?.stringValue.flatMap(SonyFirmwareVersion.init) else { return .unavailable }
        var matchesFirmware = true
        var hasFirmwareRule = false
        for case let rule as XMLElement in rules {
            guard rule.attribute(forName: "Type")?.stringValue == "System",
                  let key = rule.attribute(forName: "Key")?.stringValue,
                  let value = rule.attribute(forName: "Value")?.stringValue,
                  let comparison = rule.attribute(forName: "Operator")?.stringValue else { return .unavailable }
            switch key {
            case "SerialNo":
                guard value == "0", comparison == "GreaterThanEqual" else { return .unavailable }
            case "ClientVersion":
                guard SonyFirmwareVersion(value) != nil, comparison == "GreaterThanEqual" else { return .unavailable }
            case "FirmwareVersion":
                guard let version = SonyFirmwareVersion(value) else { return .unavailable }
                hasFirmwareRule = true
                switch comparison {
                case "LessThan": matchesFirmware = matchesFirmware && current < version
                case "LessThanEqual": matchesFirmware = matchesFirmware && current <= version
                case "Equal": matchesFirmware = matchesFirmware && current == version
                case "NotEqual": matchesFirmware = matchesFirmware && current != version
                case "GreaterThan": matchesFirmware = matchesFirmware && current > version
                case "GreaterThanEqual": matchesFirmware = matchesFirmware && current >= version
                default: return .unavailable
                }
            default: return .unavailable
            }
        }
        guard hasFirmwareRule else { return .unavailable }
        return matchesFirmware && latest > current ? .available(latest.text) : .noUpdate
    }

    private static func decode(_ data: Data, identity: SonyFirmwareUpdateIdentity) -> Data? {
        guard data.count <= 65_536,
              let split = data.range(of: Data([10, 10])), split.lowerBound < 256,
              let header = String(data: data[..<split.lowerBound], encoding: .ascii) else { return nil }
        let lines = header.split(separator: "\n")
        guard lines.count == 3, lines[0] == "eaid:ENC0003", lines[1] == "daid:HAS0003",
              lines[2].hasPrefix("digest:"), lines[2].count == 47 else { return nil }
        let encrypted = Data(data[split.upperBound...])
        guard !encrypted.isEmpty, encrypted.count % kCCBlockSizeAES128 == 0 else { return nil }
        let key: [UInt8] = [0x4F, 0xA2, 0x79, 0x99, 0xFF, 0xD0, 0x8B, 0x1F, 0xE4, 0xD2, 0x60, 0xD5, 0x7B, 0x6D, 0x3C, 0x17]
        var decrypted = Data(count: encrypted.count)
        var length = 0
        let capacity = decrypted.count
        let status = decrypted.withUnsafeMutableBytes { output in
            encrypted.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            key.baseAddress, kCCKeySizeAES128, nil, input.baseAddress, encrypted.count,
                            output.baseAddress, capacity, &length)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        decrypted = decrypted.prefix(length)
        while decrypted.last == 0 { decrypted.removeLast() }
        let digest = sha1(Data((sha1(decrypted) + identity.serviceID + identity.categoryID).utf8))
        guard digest == lines[2].dropFirst(7) else { return nil }
        return decrypted
    }

    private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class SonyFirmwareUpdateChecker {
    private static let logger = Logger(subsystem: "dev.baglayan.Acouplet", category: "SonyFirmwareUpdate")
    private let defaults: UserDefaults
    private let fetch: @Sendable (URL) async throws -> Data
    private var requests: [String: Task<Data, Error>] = [:]

    init(defaults: UserDefaults, fetch: @escaping @Sendable (URL) async throws -> Data = { try await SonyFirmwareUpdateChecker.fetchMetadata($0) }) {
        self.defaults = defaults
        self.fetch = fetch
    }

    func check(identity: SonyFirmwareUpdateIdentity, currentVersion: String, now: Date = Date(), force: Bool = false) async -> SonyFirmwareAvailability {
        guard SonyFirmwareVersion(currentVersion) != nil else { return .unavailable }
        var availability: SonyFirmwareAvailability = .unavailable
        var source = "network"
        defer {
            Self.logger.notice("Firmware check completed; service=\(identity.key, privacy: .public) installed=\(currentVersion, privacy: .public) source=\(source, privacy: .public) result=\(String(describing: availability), privacy: .public)")
        }
        let key = "firmwareUpdate." + identity.key
        if let request = requests[key] {
            source = "shared"
            guard let data = try? await request.value else { return .unavailable }
            availability = SonyFirmwareManifest.availability(data: data, identity: identity, currentVersion: currentVersion)
            return availability
        }
        if !force, let attempted = defaults.object(forKey: key + ".attempted") as? Date,
           now.timeIntervalSince(attempted) >= 0, now.timeIntervalSince(attempted) < 86_400 {
            source = "throttled"
            guard let data = defaults.data(forKey: key + ".metadata") else { return .unavailable }
            source = "cache"
            availability = SonyFirmwareManifest.availability(data: data, identity: identity, currentVersion: currentVersion)
            return availability
        }
        defaults.set(now, forKey: key + ".attempted")
        defaults.removeObject(forKey: key + ".metadata")
        let fetch = fetch
        let request = Task { try await fetch(identity.url) }
        requests[key] = request
        defer { requests[key] = nil }
        guard let data = try? await request.value else { return .unavailable }
        availability = SonyFirmwareManifest.availability(data: data, identity: identity, currentVersion: currentVersion)
        if availability != .unavailable { defaults.set(data, forKey: key + ".metadata") }
        return availability
    }

    func shouldNotify(identity: SonyFirmwareUpdateIdentity, version: String) -> Bool {
        guard let version = SonyFirmwareVersion(version) else { return false }
        guard let previous = defaults.string(forKey: "firmwareUpdate." + identity.key + ".notified").flatMap(SonyFirmwareVersion.init) else { return true }
        return version > previous
    }

    func markNotified(identity: SonyFirmwareUpdateIdentity, version: String) {
        defaults.set(version, forKey: "firmwareUpdate." + identity.key + ".notified")
    }

    nonisolated private static func fetchMetadata(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: SonyFirmwareMetadataSession(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "info.update.sony.net",
              response.url?.path == url.path, response.expectedContentLength <= 65_536 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

private final class SonyFirmwareMetadataSession: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
