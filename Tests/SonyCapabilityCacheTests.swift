import XCTest
@testable import Acouplet

final class SonyCapabilityCacheTests: XCTestCase {
    private let query: [UInt8] = [0xF0, 4]
    private let reply: [UInt8] = [0xF1, 4, 3, 2, 0x30, 0x31]

    func testIdentityReadsCounterAndExactUTF8ByteLength() throws {
        XCTAssertEqual(SonyCapabilityIdentity.queryPayload, [0x02, 0x00])
        for identifier in ["capability-123", "能力-é", String(repeating: "a", count: 255)] {
            let bytes = Array(identifier.utf8)
            let identity = try XCTUnwrap(SonyCapabilityIdentity(payload: [0x03, 0x00, 0xFF, UInt8(bytes.count)] + bytes))
            XCTAssertEqual(identity.identifier, identifier)
            XCTAssertEqual(identity.counter, 0xFF)
        }
    }

    func testIdentityRejectsMalformedLengthsHeadersAndUTF8() {
        let valid: [UInt8] = [0x03, 0x00, 7, 3, 0x61, 0x62, 0x63]
        for length in 0..<valid.count {
            XCTAssertNil(SonyCapabilityIdentity(payload: Array(valid.prefix(length))))
        }
        for payload: [UInt8] in [valid + [0], [0x03, 0, 7, 0], [0x03, 0, 7, 1, 0xFF],
                                [0x03, 0, 7, 2, 0xC0, 0xAF], [0x03, 0, 7, 2, 0xED, 0xA0],
                                [0x01, 0, 7, 1, 0x61], [0x03, 1, 7, 1, 0x61]] {
            XCTAssertNil(SonyCapabilityIdentity(payload: payload))
        }
    }

    func testMatchingRequiresEveryIdentityField() throws {
        var cache = SonyCapabilityCache()
        let original = try key()
        cache.store(reply, for: query, key: original)
        XCTAssertEqual(cache.reply(for: query, key: original), reply)
        for changed in [try key(identifier: "different"), try key(counter: 2),
                        try key(protocolVersion: 0x0101), try key(displayLanguage: 1)] {
            cache.store(reply, for: query, key: original)
            XCTAssertNil(cache.reply(for: query, key: changed))
        }
        XCTAssertNil(cache.reply(for: query, key: original))
        var separate = SonyCapabilityCache()
        XCTAssertNil(separate.reply(for: query, key: original))
    }

    func testIdentifiersCompareTheirWireBytesWithoutUnicodeNormalization() throws {
        var cache = SonyCapabilityCache()
        let original = try key(identifier: "\u{00E9}")
        cache.store(reply, for: query, key: original)
        XCTAssertNil(cache.reply(for: query, key: try key(identifier: "e\u{0301}")))
        XCTAssertEqual(cache.reply(for: query, key: original), reply)
    }

    func testActualRepliesRoundTripAndInvalidationPersists() throws {
        let suite = "dev.baglayan.Acouplet.capability-cache-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try key()
        let replies: [[UInt8]] = [[0xA1, 1, 5, 1, 0], [0xE1, 1, 1], [0xE1, 2, 1, 0], reply]
        var cache = SonyCapabilityCache(defaults: defaults)
        for (query, reply) in zip(SonyCapabilityCache.queryPayloads, replies) {
            cache.store(reply, for: query, key: identity)
        }
        var restored = SonyCapabilityCache(defaults: defaults)
        for (query, reply) in zip(SonyCapabilityCache.queryPayloads, replies) {
            XCTAssertEqual(restored.reply(for: query, key: identity), reply)
        }
        restored.remove(for: query, key: identity)
        var afterRemoval = SonyCapabilityCache(defaults: defaults)
        XCTAssertNil(afterRemoval.reply(for: query, key: identity))
        XCTAssertEqual(afterRemoval.reply(for: [0xE0, 1], key: identity), [0xE1, 1, 1])
        afterRemoval.store([0xF1, 4, 0, 1, 0x30], for: query, key: identity)
        XCTAssertEqual(afterRemoval.reply(for: query, key: identity), [0xF1, 4, 0, 1, 0x30])
    }

    func testOnlyBoundedCapabilityReplyEnvelopesAreStored() throws {
        var cache = SonyCapabilityCache()
        let identity = try key()
        for invalid in [[], [0xF1, 4], [0xF3, 4, 1], [0xF1, 5, 1],
                        [0xF1, 4] + Array(repeating: UInt8(0), count: SonyCapabilityCache.maximumReplyBytes)] {
            cache.store(invalid, for: query, key: identity)
            XCTAssertNil(cache.reply(for: query, key: identity))
        }
        for liveQuery: [UInt8] in [[], [0xF0], [0xA2, 1], [0xE2, 1], [0xE2, 2], [0xF2, 4], [0xF6, 4]] {
            cache.store(reply, for: liveQuery, key: identity)
            XCTAssertNil(cache.reply(for: liveQuery, key: identity))
        }
    }

    func testMalformedPreferencesAreMisses() throws {
        let suite = "dev.baglayan.Acouplet.capability-cache-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try key()
        for value: Any in ["invalid", Data("invalid".utf8), Data(repeating: 0, count: 1_048_577)] {
            defaults.set(value, forKey: SonyCapabilityCache.savedEntriesKey)
            var cache = SonyCapabilityCache(defaults: defaults)
            XCTAssertNil(cache.reply(for: query, key: identity))
            cache.store(reply, for: query, key: identity)
            var restored = SonyCapabilityCache(defaults: defaults)
            XCTAssertEqual(restored.reply(for: query, key: identity), reply)
        }
    }

    func testMalformedDecodedRecordsAndDuplicateKeysAreMisses() throws {
        let suite = "dev.baglayan.Acouplet.capability-cache-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try key()
        var cache = SonyCapabilityCache(defaults: defaults)
        cache.store(reply, for: query, key: identity)
        let data = try XCTUnwrap(defaults.data(forKey: SonyCapabilityCache.savedEntriesKey))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for replies: [String: String] in [[:], ["240:4": Data([0xF3, 4, 1]).base64EncodedString()],
                                         ["242:4": Data(reply).base64EncodedString()], ["240:4": "invalid"]] {
            var invalid = valid
            invalid[0]["replies"] = replies
            defaults.set(try JSONSerialization.data(withJSONObject: invalid), forKey: SonyCapabilityCache.savedEntriesKey)
            var restored = SonyCapabilityCache(defaults: defaults)
            XCTAssertNil(restored.reply(for: query, key: identity))
        }
        defaults.set(try JSONSerialization.data(withJSONObject: valid + valid), forKey: SonyCapabilityCache.savedEntriesKey)
        var duplicate = SonyCapabilityCache(defaults: defaults)
        XCTAssertNil(duplicate.reply(for: query, key: identity))
    }

    func testStorageEvictsLeastRecentlyUsedIdentityAndPersistsTheBound() throws {
        let suite = "dev.baglayan.Acouplet.capability-cache-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var cache = SonyCapabilityCache(defaults: defaults)
        for index in 0..<SonyCapabilityCache.maximumEntries {
            cache.store(reply, for: query, key: try key(identifier: "identity-\(index)"))
        }
        XCTAssertEqual(cache.reply(for: query, key: try key(identifier: "identity-0")), reply)
        cache.store(reply, for: query, key: try key(identifier: "identity-new"))
        var restored = SonyCapabilityCache(defaults: defaults)
        XCTAssertEqual(restored.reply(for: query, key: try key(identifier: "identity-0")), reply)
        XCTAssertNil(restored.reply(for: query, key: try key(identifier: "identity-1")))
        XCTAssertEqual(restored.reply(for: query, key: try key(identifier: "identity-new")), reply)
        let data = try XCTUnwrap(defaults.data(forKey: SonyCapabilityCache.savedEntriesKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(entries.count, SonyCapabilityCache.maximumEntries)
    }

    func testIndependentControllersPreserveEachOthersSavedCapabilities() throws {
        let suite = "dev.baglayan.Acouplet.capability-cache-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var first = SonyCapabilityCache(defaults: defaults)
        var second = SonyCapabilityCache(defaults: defaults)
        let firstKey = try key(identifier: "first")
        let secondKey = try key(identifier: "second")
        first.store(reply, for: query, key: firstKey)
        second.store(reply, for: query, key: secondKey)
        XCTAssertEqual(first.reply(for: query, key: secondKey), reply)
        XCTAssertEqual(second.reply(for: query, key: firstKey), reply)
        first.remove(for: query, key: firstKey)
        second.store([0xE1, 1, 1], for: [0xE0, 1], key: secondKey)
        XCTAssertNil(second.reply(for: query, key: firstKey))
        XCTAssertEqual(first.reply(for: query, key: secondKey), reply)
        XCTAssertEqual(first.reply(for: [0xE0, 1], key: secondKey), [0xE1, 1, 1])
    }

    func testChangedKeyInvalidatesHistoryEvenWithoutNewRepliesAcrossControllers() throws {
        let suite = "dev.baglayan.Acouplet.capability-cache-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = try key(counter: 7)
        let other = try key(identifier: "other")
        for changed in [try key(counter: 8), try key(counter: 7, protocolVersion: 0x0101),
                        try key(counter: 7, displayLanguage: 1)] {
            var first = SonyCapabilityCache(defaults: defaults)
            var second = SonyCapabilityCache(defaults: defaults)
            first.store(reply, for: query, key: original)
            first.store(reply, for: query, key: other)
            XCTAssertEqual(second.reply(for: query, key: original), reply)
            XCTAssertNil(first.reply(for: query, key: changed))
            XCTAssertNil(first.reply(for: query, key: original))
            XCTAssertNil(second.reply(for: query, key: original))
            XCTAssertEqual(second.reply(for: query, key: other), reply)
            first.store(reply, for: query, key: original)
            XCTAssertEqual(second.reply(for: query, key: original), reply)
        }
    }

    func testBindingAndFreshStorageDiscardOtherKeysForTheSameIdentifier() throws {
        var cache = SonyCapabilityCache()
        let original = try key(counter: 7)
        let changed = try key(counter: 8)
        cache.store(reply, for: query, key: original)
        cache.bind(to: changed)
        XCTAssertNil(cache.reply(for: query, key: original))
        cache.store(reply, for: query, key: original)
        cache.store([0xE1, 1, 1], for: [0xE0, 1], key: changed)
        XCTAssertEqual(cache.reply(for: [0xE0, 1], key: changed), [0xE1, 1, 1])
        XCTAssertNil(cache.reply(for: query, key: original))
    }

    private func key(identifier: String = "capability-123", counter: UInt8 = 1,
                     protocolVersion: UInt32 = 0x0100, displayLanguage: UInt8 = 0) throws -> SonyCapabilityCache.Key {
        let bytes = Array(identifier.utf8)
        let identity = try XCTUnwrap(SonyCapabilityIdentity(payload: [0x03, 0, counter, UInt8(bytes.count)] + bytes))
        return SonyCapabilityCache.Key(protocolVersion: protocolVersion, identity: identity, displayLanguage: displayLanguage)
    }
}
