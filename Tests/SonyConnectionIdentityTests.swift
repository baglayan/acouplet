import XCTest
@testable import Acouplet

final class SonyConnectionIdentityTests: XCTestCase {
    private let host = "10:20:30:40:50:60"
    private let classic = "AA:BB:CC:DD:EE:01"
    private let left = "AA:BB:CC:DD:EE:02"
    private let right = "AA:BB:CC:DD:EE:03"

    func testExactCapabilityQueriesAndTables() {
        XCTAssertEqual(SonyConnectionIdentity.queryPayloads(frameType: 0x0C, supportedFunctions: [0x19, 0x40, 0x41],
                                                           supportedFunctions2: [0x64]), [[0x10, 0x07], [0x40, 0], [0x40, 1]])
        XCTAssertEqual(SonyConnectionIdentity.queryPayloads(frameType: 0x0E, supportedFunctions: [0x19, 0x40, 0x41],
                                                           supportedFunctions2: [0x64]), [[0x60, 4]])
        for type: UInt8 in [0x0C, 0x0E, 0x1C] {
            XCTAssertTrue(SonyConnectionIdentity.queryPayloads(frameType: type, supportedFunctions: [0x64],
                                                              supportedFunctions2: [0x19, 0x40, 0x41]).isEmpty)
        }
    }

    func testCommonClassicNeverAdmitsHostAddress() throws {
        let identity = try XCTUnwrap(SonyConnectionIdentity(payload: [0x11, 7] + Array((host + classic.lowercased()).utf8),
            frameType: 0x0C, supportedFunctions: [0x19], supportedFunctions2: []))
        XCTAssertEqual(identity.queryPayload, [0x10, 7])
        XCTAssertEqual(identity.addresses, [classic])
        XCTAssertFalse(identity.addresses.contains(host))
    }

    func testTopologyIdentitySchemasAreDistinctAndCapabilityGated() throws {
        let cases: [(type: UInt8, function: UInt8, prefix: [UInt8], fields: [String])] = [
            (0x0C, 0x40, [0x41, 0], [classic, left, right]),
            (0x0C, 0x41, [0x41, 1], [classic, left]),
            (0x0E, 0x64, [0x61, 4], [classic, left]),
        ]
        for testCase in cases {
            let functions: Set<UInt8> = testCase.type == 0x0C ? [testCase.function] : []
            let functions2: Set<UInt8> = testCase.type == 0x0E ? [testCase.function] : []
            let payload = testCase.prefix + Array(testCase.fields.joined().utf8)
            let identity = try XCTUnwrap(SonyConnectionIdentity(payload: payload, frameType: testCase.type,
                supportedFunctions: functions, supportedFunctions2: functions2))
            XCTAssertEqual(identity.addresses, Set(testCase.fields))
            XCTAssertNil(SonyConnectionIdentity(payload: payload, frameType: testCase.type,
                supportedFunctions: [], supportedFunctions2: []))
            XCTAssertNil(SonyConnectionIdentity(payload: payload, frameType: testCase.type == 0x0C ? 0x0E : 0x0C,
                supportedFunctions: functions, supportedFunctions2: functions2))
            for invalid in [Array(payload.dropLast()), payload + [0], testCase.prefix + Array((classic + left + right + host).utf8)] {
                XCTAssertNil(SonyConnectionIdentity(payload: invalid, frameType: testCase.type,
                    supportedFunctions: functions, supportedFunctions2: functions2))
            }
        }
    }

    func testEveryAddressFieldIsValidatedBeforeAnyAliasIsAccepted() {
        let cases: [(type: UInt8, prefix: [UInt8], fields: [String])] = [
            (0x0C, [0x11, 7], [host, classic]),
            (0x0C, [0x41, 0], [classic, left, right]),
            (0x0C, [0x41, 1], [classic, left]),
            (0x0E, [0x61, 4], [classic, left]),
        ]
        for testCase in cases {
            let payload = testCase.prefix + Array(testCase.fields.joined().utf8)
            for field in testCase.fields.indices {
                for (offset, byte): (Int, UInt8) in [(0, 0x47), (2, 0x2D), (16, 0xFF)] {
                    var invalid = payload
                    invalid[2 + field * 17 + offset] = byte
                    XCTAssertNil(SonyConnectionIdentity(payload: invalid, frameType: testCase.type,
                        supportedFunctions: [0x19, 0x40, 0x41], supportedFunctions2: [0x64]))
                }
            }
        }
        for payload: [UInt8] in [[], [0x41], [0, 7]] {
            XCTAssertNil(SonyConnectionIdentity(payload: payload, frameType: 0x0C,
                supportedFunctions: [0x19, 0x40, 0x41], supportedFunctions2: [0x64]))
        }
    }
}
