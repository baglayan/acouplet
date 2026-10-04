import XCTest
@testable import Acouplet

final class SonyLegacyEqualizerTests: XCTestCase {
    func testLegacyPresetsAndFullCurvesKeepDistinctWireContracts() throws {
        for type: UInt8 in [1, 3] {
            var equalizer = SonyEqualizer(supportedFunctions: [type == 1 ? 0x51 : 0x53], generation: .v1)
            XCTAssertEqual(equalizer.queryPayloads, [[0x50, type, 1], [0x52, type], [0x5A, type], [0x56, type]])
            let label = Array("Özel".utf8)
            XCTAssertTrue(equalizer.update([0x51, type, 6, 21, 3, 0x77, UInt8(label.count)] + label + [0xA0, 0, 0, 0]))
            XCTAssertEqual(equalizer.capabilities?.presets.map(\.id), [0x77, 0xA0, 0])
            XCTAssertEqual(equalizer.capabilities?.presets.first?.title, "Özel")
            XCTAssertNil(equalizer.capabilities?.ultAdditionalSteps)
            XCTAssertNil(equalizer.presetPayload(0xA0))
            XCTAssertTrue(equalizer.update([0x53, type, 0]))
            XCTAssertEqual(equalizer.presetPayload(0x77), [0x58, type, 0x77, 0])
            XCTAssertNil(equalizer.presetPayload(0xFF))
            XCTAssertNil(equalizer.presetPayload(0x10))

            let layout = Array(SonyEqualizerBand.legacy.dropFirst()) + [.clearBass]
            let bands: [UInt8] = layout.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
            XCTAssertTrue(equalizer.update([0x5B, type, 6] + bands))
            XCTAssertTrue(equalizer.update([0x57, type, 0x77, 6, 10, 10, 10, 10, 10, 10]))
            XCTAssertNotNil(equalizer.settings)
            XCTAssertFalse(equalizer.canEdit)
            XCTAssertTrue(equalizer.update([0x59, type, 0xA0, 0]))
            XCTAssertNil(equalizer.rawValues)
            XCTAssertNil(equalizer.settings)
            XCTAssertTrue(equalizer.update([0x57, type, 0xA0, 6, 10, 10, 10, 10, 10, 10]))
            var curve = try XCTUnwrap(equalizer.settings)
            curve.values = [-10, -5, 0, 3, 7, 10]
            let request: [UInt8] = [0x58, type, 0xFF, 6, 0, 5, 10, 13, 17, 20]
            XCTAssertEqual(equalizer.canEdit, type == 1)
            XCTAssertEqual(equalizer.settingsPayload(curve), type == 1 ? request : nil)
            XCTAssertEqual(equalizer.acceptsSetPayload(request), type == 1)
            XCTAssertFalse(equalizer.acceptsSetPayload([0x58, type, 0xA0, 6, 0, 5, 10, 13, 17, 20]))
            XCTAssertEqual(equalizer.confirmationValue(request), equalizer.confirmationValue([0x59, type, 0xA0, 6, 0, 5, 10, 13, 17, 20]))
            XCTAssertNotEqual(equalizer.confirmationValue(request), equalizer.confirmationValue([0x59, type, 0x16, 6, 0, 5, 10, 13, 17, 20]))
            XCTAssertNotEqual(equalizer.confirmationValue(request), equalizer.confirmationValue([0x59, type, 0xFF, 6, 0, 5, 10, 13, 17, 20]))
            XCTAssertNotEqual(equalizer.confirmationValue(request), equalizer.confirmationValue([0x59, type, 0xA0, 0]))
            XCTAssertNotEqual(equalizer.confirmationValue(request), equalizer.confirmationValue([0x59, type, 0xA0, 6, 0, 5, 10, 13, 17, 19]))

            let previous = equalizer
            for malformed: [UInt8] in [
                [0x51, type, 6, 21, 1, 0, 2, 65], [0x51, type, 6, 21, 1, 0, 1, 0xFF],
                [0x51, type, 6, 21, 1, 0, 129] + Array(repeating: 65, count: 129),
                [0x53, type, 0, 0], [0x5B, type, 1, 1, 0],
                [0x57, type, 0xA0, 5, 10, 10, 10, 10, 10],
                [0x57, type, 0xA0, 6, 21, 10, 10, 10, 10, 10],
                [0x57, 0, 0xA0, 0],
            ] {
                XCTAssertFalse(equalizer.update(malformed), "\(malformed)")
                XCTAssertEqual(equalizer, previous)
            }
            XCTAssertTrue(equalizer.update([0x59, type, 0xFF, 6, 10, 10, 10, 10, 10, 10]))
            XCTAssertNil(equalizer.presetID)
            XCTAssertFalse(equalizer.canEdit)
            XCTAssertTrue(equalizer.update([0x59, type, 0xA0, 0]))
            XCTAssertNil(equalizer.settings)
            XCTAssertTrue(equalizer.update([0x55, type, 1]))
            XCTAssertFalse(equalizer.acceptsSetPayload(request))
            XCTAssertNil(equalizer.presetPayload(0))
            XCTAssertEqual(equalizer.confirmationValue([0x58, type, 0xA0, 0]), equalizer.confirmationValue([0x59, type, 0xA0, 0]))
        }
        for functions: Set<UInt8> in [[], [0x50], [0x52]] {
            XCTAssertFalse(SonyEqualizer(supportedFunctions: functions, generation: .v1).isSupported)
        }
    }
}
