import XCTest
@testable import Acouplet

final class EarbudFindingAuthorizationLogTests: XCTestCase {
    func testPersistsEveryAppendedAuthorizationInOrderWithOnlyTheRequestedFields() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = record(0)
        let second = record(1, side: "right")
        try EarbudFindingAuthorizationLog.append(first, directory: directory)
        try EarbudFindingAuthorizationLog.append(second, directory: directory)
        XCTAssertEqual(try readHistory(directory), [first, second])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["authorization-history.json"])
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: historyURL(directory))) as? [[String: Any]])
        XCTAssertEqual(Set(objects[0].keys), ["timestamp", "sessionID", "accountName", "accountID", "side", "model", "firmware"])
        XCTAssertEqual(objects[0]["timestamp"] as? String, "2023-11-14T22:13:20Z")
    }

    func testPrunesOnlyTheOldestRecordsAtTheCountLimit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = (0..<1_000).map { record($0) }
        try writeHistory(existing, directory: directory)
        let latest = record(1_000)
        try EarbudFindingAuthorizationLog.append(latest, directory: directory)
        XCTAssertEqual(try readHistory(directory), Array(existing.dropFirst()) + [latest])
        XCTAssertLessThanOrEqual(try Data(contentsOf: historyURL(directory)).count, 1_048_576)
    }

    func testPrunesOldestRecordsToFitTheByteLimitWithoutLosingTheNewRecord() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = String(repeating: "ğ", count: 140_000)
        let existing = (0..<3).map { record($0, accountName: name) }
        try writeHistory(existing, directory: directory)
        let latest = record(3, accountName: name)
        try EarbudFindingAuthorizationLog.append(latest, directory: directory)
        XCTAssertEqual(try readHistory(directory), Array(existing.dropFirst()) + [latest])
        XCTAssertLessThanOrEqual(try Data(contentsOf: historyURL(directory)).count, 1_048_576)
    }

    func testMakesDirectoryAndHistoryPrivateAndUsesApplicationSupport() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeHistory([], directory: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: historyURL(directory).path)
        try EarbudFindingAuthorizationLog.append(record(0), directory: directory)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: historyURL(directory).path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Acouplet", isDirectory: true)
            .appendingPathComponent("Safety", isDirectory: true)
        XCTAssertEqual(EarbudFindingAuthorizationLog.directory, expected)
    }

    func testCorruptOrOversizedHistoryIsRefusedWithoutReplacingItsBytes() throws {
        for bytes in [Data("{broken".utf8), Data("{}".utf8), Data(repeating: 0x20, count: 1_048_577)] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: historyURL(directory))
            XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(0), directory: directory))
            XCTAssertEqual(try Data(contentsOf: historyURL(directory)), bytes)
        }
    }

    func testInvalidSideAndOversizedNewRecordDoNotReplaceHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try EarbudFindingAuthorizationLog.append(record(0), directory: directory)
        let original = try Data(contentsOf: historyURL(directory))
        XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(1, side: "both"), directory: directory))
        XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(1, accountName: String(repeating: "x", count: 1_048_576)), directory: directory))
        XCTAssertEqual(try Data(contentsOf: historyURL(directory)), original)
        try writeHistory([record(0, side: "both")], directory: directory)
        let invalid = try Data(contentsOf: historyURL(directory))
        XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(1), directory: directory))
        XCTAssertEqual(try Data(contentsOf: historyURL(directory)), invalid)
    }

    func testRefusesHistorySymlinksIncludingDanglingLinks() throws {
        for targetExists in [true, false] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("other.json")
            let original = Data("[]".utf8)
            if targetExists { try original.write(to: target) }
            try FileManager.default.createSymbolicLink(at: historyURL(directory), withDestinationURL: target)
            XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(0), directory: directory))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: historyURL(directory).path), target.path)
            if targetExists { XCTAssertEqual(try Data(contentsOf: target), original) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
        }
    }

    func testRefusesDirectorySymlinkAndNonregularHistory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(0), directory: link))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try FileManager.default.createDirectory(at: historyURL(target), withIntermediateDirectories: false)
        XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(0), directory: target))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: historyURL(target).path)[.type] as? FileAttributeType, .typeDirectory)
        let file = root.appendingPathComponent("file")
        try Data("untouched".utf8).write(to: file)
        XCTAssertThrowsError(try EarbudFindingAuthorizationLog.append(record(0), directory: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("untouched".utf8))
    }

    func testConcurrentAppendsPreserveEveryAuthorization() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = (0..<12).map { record($0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { try EarbudFindingAuthorizationLog.append(record, directory: directory) }
            }
            try await group.waitForAll()
        }
        let stored = try readHistory(directory)
        XCTAssertEqual(stored.count, records.count)
        XCTAssertEqual(Set(stored.map(\.sessionID)), Set(records.map(\.sessionID)))
    }

    private func record(_ index: Int, side: String = "left", accountName: String = "Test User") -> EarbudFindingAuthorizationLog.Record {
        EarbudFindingAuthorizationLog.Record(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            sessionID: UUID(), accountName: accountName, accountID: 501, side: side, model: "WF-1000XM5", firmware: "6.1.0")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func historyURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("authorization-history.json")
    }

    private func writeHistory(_ records: [EarbudFindingAuthorizationLog.Record], directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: historyURL(directory))
    }

    private func readHistory(_ directory: URL) throws -> [EarbudFindingAuthorizationLog.Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([EarbudFindingAuthorizationLog.Record].self, from: Data(contentsOf: historyURL(directory)))
    }
}
