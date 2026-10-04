import XCTest
@testable import Acouplet

final class SonyFirmwareUpdateTests: XCTestCase {
    func testDeviceIdentityAndNumericVersionsFailClosed() throws {
        XCTAssertEqual(SonyFirmwareUpdateIdentity.request(supportedFunctions: [0x32, 0x36]), [0x36, 0x02])
        XCTAssertEqual(SonyFirmwareUpdateIdentity.request(supportedFunctions: [0x38]), [0x36, 0x07])
        XCTAssertNil(SonyFirmwareUpdateIdentity.request(supportedFunctions: [0x37]))
        let strings = ["HP002", "MDRID296300", "US", "English", "12345"]
        let payload: [UInt8] = [0x37, 0x02] + strings.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0x00]
        let identity = try XCTUnwrap(SonyFirmwareUpdateIdentity(payload: payload, selector: 0x02))
        XCTAssertEqual(identity.serviceID, "MDRID296300")
        XCTAssertEqual(identity.url.absoluteString, "https://info.update.sony.net/HP002/MDRID296300/info/info.xml")
        XCTAssertNil(SonyFirmwareUpdateIdentity(payload: payload, selector: 0x04))
        XCTAssertNil(SonyFirmwareUpdateIdentity(payload: Array(payload.dropLast(4)), selector: 0x02))
        XCTAssertNil(SonyFirmwareUpdateIdentity(categoryID: "HP002", serviceID: "../MDRID296300"))
        XCTAssertNotNil(SonyFirmwareUpdateIdentity(categoryID: "HP002", serviceID: "MDRID_2963-A"))
        XCTAssertEqual(SonyFirmwareUpdateIdentity.legacyValue(payload: [0x37, 0x02, 5] + Array("HP002".utf8), selector: 0x02), "HP002")
        XCTAssertNil(SonyFirmwareUpdateIdentity.legacyValue(payload: [0x37, 0x02, 5] + Array("HP002".utf8), selector: 0x03))
        XCTAssertLessThan(try XCTUnwrap(SonyFirmwareVersion("2.9.0")), try XCTUnwrap(SonyFirmwareVersion("2.10.0")))
        for version in ["", "2.5", "2.5.1beta", "02.5.1", "2..1", "2.5.1.0", "999999999999999999999.0.0", "２.５.１"] {
            XCTAssertNil(SonyFirmwareVersion(version), version)
        }
    }

    func testOfficialManifestRequiresMatchingIdentityDigestAndOlderFirmware() throws {
        let identity = try XCTUnwrap(SonyFirmwareUpdateIdentity(categoryID: "HP002", serviceID: "MDRID296300"))
        XCTAssertEqual(SonyFirmwareManifest.availability(data: Self.manifest, identity: identity, currentVersion: "6.0.0"), .available("6.1.0"))
        XCTAssertEqual(SonyFirmwareManifest.availability(data: Self.manifest, identity: identity, currentVersion: "6.1.0"), .noUpdate)
        XCTAssertEqual(SonyFirmwareManifest.availability(data: Self.manifest, identity: identity, currentVersion: "6.2.0"), .noUpdate)
        let differentRegion = try XCTUnwrap(SonyFirmwareUpdateIdentity(categoryID: "HP002", serviceID: "MDRID296302"))
        XCTAssertEqual(SonyFirmwareManifest.availability(data: Self.manifest, identity: differentRegion, currentVersion: "6.0.0"), .unavailable)
        var corrupt = Self.manifest
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertEqual(SonyFirmwareManifest.availability(data: corrupt, identity: identity, currentVersion: "6.0.0"), .unavailable)
        XCTAssertEqual(SonyFirmwareManifest.availability(data: Data("Access denied".utf8), identity: identity, currentVersion: "6.0.0"), .unavailable)
    }

    @MainActor
    func testManualCheckBypassesCachedResultsAndFailureThrottle() async throws {
        let suite = "dev.baglayan.Acouplet.firmware-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(SonyFirmwareUpdateIdentity(categoryID: "HP002", serviceID: "MDRID296300"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetched = expectation(description: "Fresh manual firmware checks")
        fetched.expectedFulfillmentCount = 3
        let checker = SonyFirmwareUpdateChecker(defaults: defaults) { _ in
            fetched.fulfill()
            return Self.manifest
        }
        let first = await checker.check(identity: identity, currentVersion: "6.0.0", now: now)
        XCTAssertEqual(first, .available("6.1.0"))
        let cached = await checker.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(1))
        XCTAssertEqual(cached, .available("6.1.0"))
        let manual = await checker.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(2), force: true)
        XCTAssertEqual(manual, .available("6.1.0"))
        let offline = SonyFirmwareUpdateChecker(defaults: defaults) { _ in throw URLError(.notConnectedToInternet) }
        let failed = await offline.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(3), force: true)
        XCTAssertEqual(failed, .unavailable)
        let throttled = await checker.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(4))
        XCTAssertEqual(throttled, .unavailable)
        let retried = await checker.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(5), force: true)
        XCTAssertEqual(retried, .available("6.1.0"))
        await fulfillment(of: [fetched], timeout: 2)
    }

    @MainActor
    func testCacheFailureThrottleAndNoticeAcknowledgementSurviveRestart() async throws {
        let suite = "dev.baglayan.Acouplet.firmware-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(SonyFirmwareUpdateIdentity(categoryID: "HP002", serviceID: "MDRID296300"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = SonyFirmwareUpdateChecker(defaults: defaults) { _ in Self.manifest }
        let available = await checker.check(identity: identity, currentVersion: "6.0.0", now: now)
        XCTAssertEqual(available, .available("6.1.0"))
        XCTAssertTrue(checker.shouldNotify(identity: identity, version: "6.1.0"))
        checker.markNotified(identity: identity, version: "6.1.0")
        let offline = SonyFirmwareUpdateChecker(defaults: defaults) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(offline.shouldNotify(identity: identity, version: "6.1.0"))
        XCTAssertFalse(offline.shouldNotify(identity: identity, version: "6.0.0"))
        let cached = await offline.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(60))
        XCTAssertEqual(cached, .available("6.1.0"))
        let failed = await offline.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(86_401))
        XCTAssertEqual(failed, .unavailable)
        let throttled = await checker.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(86_402))
        XCTAssertEqual(throttled, .unavailable)
        let recovered = await checker.check(identity: identity, currentVersion: "6.0.0", now: now.addingTimeInterval(172_802))
        XCTAssertEqual(recovered, .available("6.1.0"))
    }

    static let manifest = Data(base64Encoded: """
        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
        """, options: .ignoreUnknownCharacters)!
}
