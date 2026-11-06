import XCTest
@testable import Acouplet

final class SonyCommonConnectionTests: XCTestCase {
    func testAdvertisedReconnectionRequestsPreserveRequestTypeAndNormalizeTheAddress() {
        for (value, requestType): (UInt8, SonyCommonConnection.RequestType) in [(0x00, .underConfirmation), (0x01, .execute)] {
            for address in ["01:23:45:67:89:AB", "01:23:45:67:89:ab", "aB:cD:eF:01:23:45"] {
                let payload = [0x19, 0x08, value] + Array(address.utf8)
                for functions: Set<UInt8> in [[0x1A], [0x1A, 0x1C], [0x16, 0x19, 0x1A, 0x1B, 0x1C]] {
                    XCTAssertEqual(SonyCommonConnection.parse(payload, supportedFunctions: functions),
                                   .reconnectionRequest(requestType: requestType, address: address.uppercased()))
                }
            }
        }
    }

    func testEachNotificationRequiresItsOwnAdvertisedFunction() {
        let reconnect: [UInt8] = [0x19, 0x08, 0x01] + Array("01:23:45:67:89:AB".utf8)
        for functions: Set<UInt8> in [[], [0x1C], [0x16, 0x19, 0x1B, 0x1C]] {
            XCTAssertNil(SonyCommonConnection.parse(reconnect, supportedFunctions: functions))
        }
        for functions: Set<UInt8> in [[], [0x1A], [0x16, 0x19, 0x1A, 0x1B]] {
            XCTAssertNil(SonyCommonConnection.parse([0x19, 0x0A], supportedFunctions: functions))
        }
        for functions: Set<UInt8> in [[0x1C], [0x1A, 0x1C], [0x16, 0x19, 0x1A, 0x1B, 0x1C]] {
            XCTAssertEqual(SonyCommonConnection.parse([0x19, 0x0A], supportedFunctions: functions), .releaseGATT)
        }
    }

    func testCommandsAndInquiriesCannotBeConfusedWithOtherCommonPackets() {
        let reconnect: [UInt8] = [0x19, 0x08, 0x01] + Array("01:23:45:67:89:AB".utf8)
        for command in UInt8.min...UInt8.max where command != 0x19 {
            XCTAssertNil(SonyCommonConnection.parse([command] + reconnect.dropFirst(), supportedFunctions: [0x1A, 0x1C]))
            XCTAssertNil(SonyCommonConnection.parse([command, 0x0A], supportedFunctions: [0x1A, 0x1C]))
        }
        for inquiry in UInt8.min...UInt8.max where inquiry != 0x08 && inquiry != 0x0A {
            XCTAssertNil(SonyCommonConnection.parse([0x19, inquiry] + reconnect.dropFirst(2), supportedFunctions: [0x1A, 0x1C]))
            XCTAssertNil(SonyCommonConnection.parse([0x19, inquiry], supportedFunctions: [0x1A, 0x1C]))
        }
        XCTAssertNil(SonyCommonConnection.parse([0x19, 0x08], supportedFunctions: [0x1A, 0x1C]))
        XCTAssertNil(SonyCommonConnection.parse([0x19, 0x0A] + reconnect.dropFirst(2), supportedFunctions: [0x1A, 0x1C]))
    }

    func testNotificationsRequireTheirExactLengths() {
        let reconnect: [UInt8] = [0x19, 0x08, 0x01] + Array("01:23:45:67:89:AB".utf8)
        for payload in [reconnect, [0x19, 0x0A]] {
            for length in 0..<payload.count {
                XCTAssertNil(SonyCommonConnection.parse(Array(payload.prefix(length)), supportedFunctions: [0x1A, 0x1C]))
            }
            XCTAssertNil(SonyCommonConnection.parse(payload + [0x00], supportedFunctions: [0x1A, 0x1C]))
        }
    }

    func testUnknownRequestTypesAndInvalidAddressesAreRejected() {
        let address = Array("01:23:45:67:89:AB".utf8)
        for requestType in UInt8(0x02)...UInt8.max {
            XCTAssertNil(SonyCommonConnection.parse([0x19, 0x08, requestType] + address, supportedFunctions: [0x1A]))
        }
        for index in address.indices {
            let invalidBytes: [UInt8] = index % 3 == 2 ? [0x00, 0x2D, 0x30, 0xFF] : [0x00, 0x2F, 0x3A, 0x40, 0x47, 0x60, 0x67, 0xFF]
            for byte in invalidBytes {
                var invalidAddress = address
                invalidAddress[index] = byte
                XCTAssertNil(SonyCommonConnection.parse([0x19, 0x08, 0x01] + invalidAddress, supportedFunctions: [0x1A]))
            }
        }
    }
}
