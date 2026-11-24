import XCTest
@testable import Acouplet

final class SonyLegacyOptimizerTests: XCTestCase {
    func testModernCapabilitySelectionAndVariantSpecificMeasurements() throws {
        let variants: [(UInt8, Set<UInt8>, [UInt8], [UInt8], UInt8, UInt8, Bool?, Double?)] = [
            (0, [0x80, 0x83], [5, 3, 4], [1, 9], 3, 4, true, 0.9),
            (1, [0x80, 0x81], [5, 3], [0], 3, 0, false, nil),
            (2, [0x80, 0x81, 0x82], [5, 4], [8], 0, 4, nil, 0.8)
        ]
        for (type, functions, capability, result, personalDuration, pressureDuration, personal, pressure) in variants {
            var optimizer = SonyLegacyOptimizer(supportedFunctions: functions, generation: .v2)
            let inquiry = try XCTUnwrap(optimizer.inquiry)
            XCTAssertEqual(inquiry.generation, .v2)
            XCTAssertEqual(inquiry.type, type)
            XCTAssertEqual(optimizer.queryPayloads, [[0x80, type], [0x82, type], [0x86, type]])
            XCTAssertEqual(inquiry.startPayload, [0x84, type, 0, 1])
            XCTAssertEqual(inquiry.cancelPayload, [0x84, type, 0, 0])
            XCTAssertFalse(optimizer.update([0x89, type] + result))
            XCTAssertFalse(optimizer.update([0x81, type, 5, 1, 3, 1, 4]))
            XCTAssertFalse(optimizer.update([0x81, type] + capability + [0]))
            XCTAssertFalse(optimizer.update([0x81, type, 0] + capability.dropFirst()))
            XCTAssertTrue(optimizer.update([0x81, type] + capability))
            XCTAssertEqual(optimizer.capability?.optimizationSeconds, 5)
            XCTAssertEqual(optimizer.capability?.personalSeconds, personalDuration)
            XCTAssertEqual(optimizer.capability?.pressureSeconds, pressureDuration)
            XCTAssertFalse(optimizer.canStart)
            XCTAssertFalse(optimizer.update([0x83, type, 0, 0], frameType: 0x0E))
            XCTAssertTrue(optimizer.update([0x83, type, 1, 0]))
            XCTAssertFalse(optimizer.canStart)
            XCTAssertTrue(optimizer.update([0x85, type, 0, 0]))
            XCTAssertTrue(optimizer.canStart)
            XCTAssertFalse(optimizer.update([0x85, 0x30, 0, 0x11]))
            XCTAssertFalse(optimizer.update([0x85, type, 0, 0xFF]))
            XCTAssertTrue(optimizer.canStart)
            XCTAssertTrue(optimizer.update([0x89, type] + result))
            XCTAssertEqual(optimizer.measurements?.personalMeasured, personal)
            XCTAssertEqual(optimizer.measurements?.pressureAtmospheres, pressure)
            XCTAssertFalse(optimizer.update([0x87, type] + result.dropLast()))
            XCTAssertFalse(optimizer.update([0x87, type] + result.map { _ in 0xFF }))
        }
        let speaker = SonyLegacyOptimizer(supportedFunctions: [0x83], generation: .v2)
        XCTAssertFalse(speaker.isSupported)
        XCTAssertTrue(speaker.queryPayloads.isEmpty)
    }

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
