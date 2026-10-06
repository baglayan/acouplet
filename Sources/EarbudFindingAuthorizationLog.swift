import Foundation

struct EarbudFindingAuthorizationLog {
    struct Record: Codable, Equatable, Sendable {
        let timestamp: Date
        let sessionID: UUID
        let accountName: String
        let accountID: UInt32
        let side: String
        let model: String
        let firmware: String
    }

    enum Failure: Error {
        case invalidPath, historyTooLarge, invalidRecord, recordTooLarge
    }

    private static let maximumRecords = 1_000
    private static let maximumBytes = 1_048_576
    private static let lock = NSLock()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Acouplet", isDirectory: true)
            .appendingPathComponent("Safety", isDirectory: true)
    }

    static func append(_ record: Record, directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard directory.isFileURL else { throw Failure.invalidPath }
        guard record.side == "left" || record.side == "right" else { throw Failure.invalidRecord }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        guard try encoder.encode([record]).count <= maximumBytes else { throw Failure.recordTooLarge }
        let files = FileManager.default
        if try attributes(at: directory) == nil {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard try attributes(at: directory)?[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidPath }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let history = directory.appendingPathComponent("authorization-history.json")
        var records: [Record] = []
        if let attributes = try attributes(at: history) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidPath }
            let size = (attributes[.size] as! NSNumber).intValue
            guard size <= maximumBytes else { throw Failure.historyTooLarge }
            let input = try FileHandle(forReadingFrom: history)
            let data: Data
            do {
                data = try input.read(upToCount: maximumBytes + 1) ?? Data()
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
            guard data.count == size, data.count <= maximumBytes else { throw Failure.historyTooLarge }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([Record].self, from: data)
            guard records.allSatisfy({ $0.side == "left" || $0.side == "right" }) else { throw Failure.invalidRecord }
        }
        records.append(record)
        var kept: [Record] = []
        var byteCount = 2
        for candidate in records.suffix(maximumRecords).reversed() {
            let size = try encoder.encode(candidate).count + (kept.isEmpty ? 0 : 1)
            guard byteCount + size <= maximumBytes else { break }
            kept.append(candidate)
            byteCount += size
        }
        let data = try encoder.encode(Array(kept.reversed()))
        try data.write(to: history, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
    }

    private static func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == CocoaError.Code.fileNoSuchFile.rawValue || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue) {
            return nil
        }
    }
}
