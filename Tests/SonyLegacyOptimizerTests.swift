import XCTest
@testable import Acouplet

final class SonyLegacyOptimizerTests: XCTestCase {
    func testAdvertisedOptimizerPreservesAvailabilityProgressAndBothMeasurementTuples() {
        var unsupported = SonyLegacyOptimizer(supportedFunctions: [0x80, 0x82])
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        XCTAssertFalse(unsupported.update([0x81, 1, 5, 1, 3, 1, 4]))
        XCTAssertFalse(unsupported.canStart)

        var optimizer = SonyLegacyOptimizer(supportedFunctions: [0x81])
        XCTAssertEqual(optimizer.queryPayloads, [[0x80, 1], [0x82, 1], [0x86, 1]])
        XCTAssertFalse(optimizer.update([0x87, 1, 1, 1, 1, 10]))
        XCTAssertTrue(optimizer.update([0x81, 1, 5, 1, 3, 1, 4]))
        XCTAssertEqual(optimizer.capability?.optimizationSeconds, 5)
        XCTAssertEqual(optimizer.capability?.personalSeconds, 3)
        XCTAssertEqual(optimizer.capability?.pressureSeconds, 4)
        XCTAssertFalse(optimizer.canStart)
        XCTAssertTrue(optimizer.update([0x83, 1, 0, 0]))
        XCTAssertTrue(optimizer.canStart)
        XCTAssertEqual(SonyLegacyOptimizer.startPayload, [0x84, 1, 0, 1])
        XCTAssertEqual(SonyLegacyOptimizer.cancelPayload, [0x84, 1, 0, 0])

        for phase: UInt8 in [1, 2, 0x10] {
            XCTAssertTrue(optimizer.update([0x85, 1, 0, phase]))
            XCTAssertTrue(optimizer.status?.phase?.isActive == true)
            XCTAssertFalse(optimizer.canStart)
        }
        XCTAssertTrue(optimizer.update([0x89, 1, 1, 1, 1, 9]))
        XCTAssertEqual(optimizer.measurements?.personalMeasured, true)
        XCTAssertEqual(optimizer.measurements?.pressureAtmospheres, 0.9)
        XCTAssertEqual(optimizer.status?.phase, .optimizing)
        XCTAssertTrue(optimizer.update([0x85, 1, 0, 0x11]))
        XCTAssertEqual(optimizer.status?.phase, .completed)
        XCTAssertTrue(optimizer.canStart)
        XCTAssertTrue(optimizer.update([0x85, 1, 0, 0]))
        XCTAssertEqual(optimizer.status?.phase, .idle)

        let previous = optimizer
        for invalid: [UInt8] in [[0x81, 1, 5, 1, 3, 1], [0x83, 1, 0], [0x85, 2, 0, 0],
                                 [0x89, 1, 0, 1, 1, 9], [0x87, 1, 1, 1, 0, 9], [0x89, 1, 1, 1, 1]] {
            XCTAssertFalse(optimizer.update(invalid))
            XCTAssertEqual(optimizer, previous)
        }
        XCTAssertFalse(optimizer.update([0x85, 1, 0, 0], frameType: 0x0E))
        XCTAssertTrue(optimizer.update([0x85, 1, 1, 0]))
        XCTAssertFalse(optimizer.canStart)
        XCTAssertTrue(optimizer.update([0x85, 1, 0xFF, 0xFE]))
        XCTAssertNil(optimizer.status?.available)
        XCTAssertNil(optimizer.status?.phase)
        XCTAssertEqual(optimizer.status?.phaseValue, 0xFE)
        XCTAssertFalse(optimizer.canStart)
        XCTAssertTrue(optimizer.update([0x89, 1, 1, 0xFE, 1, 0xFF]))
        XCTAssertNil(optimizer.measurements?.personalMeasured)
        XCTAssertNil(optimizer.measurements?.pressureAtmospheres)
        XCTAssertEqual(optimizer.measurements?.personalValue, 0xFE)
        XCTAssertTrue(optimizer.update([0x81, 1, 5, 0xFE, 3, 1, 4]))
        XCTAssertNil(optimizer.measurements)
        XCTAssertTrue(optimizer.update([0x85, 1, 0, 0]))
        XCTAssertFalse(optimizer.canStart)
    }
}
