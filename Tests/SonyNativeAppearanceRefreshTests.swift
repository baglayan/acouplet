#if !ACOUPLET_PUBLIC_APIS_ONLY
import XCTest
@testable import Acouplet

final class SonyNativeAppearanceRefreshTests: XCTestCase {
    private let canonicalIdentifier = UUID(uuidString: "00000000-0000-4000-8000-000000000019")!
    private let otherIdentifier = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
    private let manufacturerData = Data([0x2D, 0x01, 0x04, 0x00, 0x02, 0x01,
                                         0xB0, 0x32, 0x00, 0x00, 0x00, 0xF0, 0x12, 0xAB, 0xCD, 0x00, 0x00, 0x00])

    func testOnlyCanonicalUUIDEstablishesCanonicalObservation() throws {
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "12:34:56:78:9A:BC", model: .wfXM5,
                                                                  hash: "F012ABCD", peripheralIdentifier: canonicalIdentifier))
        XCTAssertEqual(SonyNativeAppearanceRefresh.match(peripheralIdentifier: canonicalIdentifier, manufacturerData: nil, identity: identity), .canonical)
        XCTAssertEqual(SonyNativeAppearanceRefresh.match(peripheralIdentifier: canonicalIdentifier, manufacturerData: manufacturerData, identity: identity), .canonical)
        XCTAssertEqual(SonyNativeAppearanceRefresh.match(peripheralIdentifier: otherIdentifier, manufacturerData: manufacturerData, identity: identity), .related)
        XCTAssertNil(SonyNativeAppearanceRefresh.match(peripheralIdentifier: otherIdentifier, manufacturerData: nil, identity: identity))
        XCTAssertNil(SonyNativeAppearanceRefresh.match(peripheralIdentifier: otherIdentifier, manufacturerData: Data([0]), identity: identity))
    }

    func testConflictingHashCannotConfirmTheCanonicalIdentity() throws {
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "12:34:56:78:9A:BC", model: .wfXM5,
                                                                  hash: "12345678", peripheralIdentifier: canonicalIdentifier))
        XCTAssertEqual(SonyNativeAppearanceRefresh.match(peripheralIdentifier: canonicalIdentifier, manufacturerData: manufacturerData, identity: identity), .conflictingHash)
        XCTAssertNil(SonyNativeAppearanceRefresh.match(peripheralIdentifier: otherIdentifier, manufacturerData: manufacturerData, identity: identity))
        let missing = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: identity.classicAddress, model: .wfXM5,
                                                                 hash: "F012ABCD", peripheralIdentifier: nil))
        XCTAssertNil(SonyNativeAppearanceRefresh.match(peripheralIdentifier: otherIdentifier, manufacturerData: manufacturerData, identity: missing))
        let headphones = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: identity.classicAddress, model: .whXM5,
                                                                    hash: "F012ABCD", peripheralIdentifier: canonicalIdentifier))
        XCTAssertNil(SonyNativeAppearanceRefresh.match(peripheralIdentifier: canonicalIdentifier, manufacturerData: manufacturerData, identity: headphones))
    }

    func testOptionalAppearanceMetadataRequiresAnExactUnsigned16BitInteger() {
        XCTAssertEqual(SonyNativeAppearanceRefresh.appearance(NSNumber(value: 0x0941)), 0x0941)
        XCTAssertEqual(SonyNativeAppearanceRefresh.appearance(NSNumber(value: 0)), 0)
        XCTAssertEqual(SonyNativeAppearanceRefresh.appearance(NSNumber(value: UInt16.max)), UInt16.max)
        for value: Any? in [nil, true, "0x0941", Data([0x41, 0x09]), -1, 65_536, 2369.5, Double.nan, Double.infinity] {
            XCTAssertNil(SonyNativeAppearanceRefresh.appearance(value))
        }
    }
}
#endif
