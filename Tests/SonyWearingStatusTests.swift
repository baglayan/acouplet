import XCTest
@testable import Acouplet

final class SonyWearingStatusTests: XCTestCase {
    func testCapabilityAndSeparateEarStates() {
        var unsupported = SonyWearingStatus(supportedFunctions: [0xF1, 0xF6])
        XCTAssertFalse(unsupported.isSupported)
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        XCTAssertFalse(unsupported.update([0xF3, 0x00, 0x04]))
        XCTAssertNil(unsupported.leftWorn)
        XCTAssertNil(unsupported.rightWorn)

        var model = SonyWearingStatus(supportedFunctions: [0xF0])
        XCTAssertEqual(model.queryPayloads, [[0xF2, 0x00]])
        XCTAssertNil(model.state)
        for command: UInt8 in [0xF3, 0xF5] {
            for (value, left, right): (UInt8, Bool, Bool) in [
                (0x00, true, true), (0x02, false, true), (0x03, true, false), (0x04, false, false)
            ] {
                XCTAssertTrue(model.update([command, 0x00, value]))
                XCTAssertEqual(model.leftWorn, left)
                XCTAssertEqual(model.rightWorn, right)
            }
        }
    }

    func testUnknownMalformedAndInvalidatedStatesCannotMeanRemoved() {
        var model = SonyWearingStatus(supportedFunctions: [0xF0])
        for value in UInt8.min...UInt8.max where ![0x00, 0x02, 0x03, 0x04].contains(value) {
            XCTAssertTrue(model.update([0xF3, 0x00, 0x04]))
            XCTAssertTrue(model.update([0xF5, 0x00, value]))
            XCTAssertEqual(model.state, .unknown(value))
            XCTAssertNil(model.leftWorn)
            XCTAssertNil(model.rightWorn)
        }
        for payload: [UInt8] in [[0xF3, 0x00], [0xF5, 0x00, 0x04, 0x00]] {
            XCTAssertTrue(model.update([0xF3, 0x00, 0x04]))
            XCTAssertFalse(model.update(payload))
            XCTAssertNil(model.state)
            XCTAssertNil(model.leftWorn)
            XCTAssertNil(model.rightWorn)
        }
        XCTAssertTrue(model.update([0xF3, 0x00, 0x04]))
        model.invalidate()
        XCTAssertNil(model.state)
        XCTAssertNil(model.leftWorn)
        XCTAssertNil(model.rightWorn)
        XCTAssertTrue(model.isSupported)
    }

    func testUnrelatedPacketsAndTableOneCannotChangeTheState() {
        var model = SonyWearingStatus(supportedFunctions: [0xF0])
        XCTAssertTrue(model.update([0xF3, 0x00, 0x00]))
        let previous = model
        for payload: [UInt8] in [[], [0xF3], [0xF2, 0x00], [0xF7, 0x00, 0x04], [0xF3, 0x01, 0x04]] {
            XCTAssertFalse(model.update(payload))
            XCTAssertEqual(model, previous)
        }
        for frameType: UInt8 in [0x01, 0x0C, 0x0D, 0x0F] {
            XCTAssertFalse(model.update([0xF3, 0x00, 0x04], frameType: frameType))
            XCTAssertEqual(model, previous)
        }
    }
}
