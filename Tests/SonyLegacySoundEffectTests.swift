import XCTest
@testable import Acouplet

final class SonyLegacySoundEffectTests: XCTestCase {
    func testSurroundPreservesAdvertisedOrderNamesAndRequiresAvailableFullState() {
        var effect = SonyLegacySoundEffect(kind: .surround, supportedFunctions: [0x41])
        XCTAssertEqual(effect.queryPayloads, [[0x40, 1, 1], [0x42, 1], [0x46, 1]])
        XCTAssertFalse(effect.update([0x41, 2, 1]))
        XCTAssertFalse(effect.update([0x41, 1, 1, 0, 0], frameType: 0x0E))
        let name = Array("Salle Écho".utf8)
        let capability: [UInt8] = [0x41, 1, 4, 3, UInt8(name.count)] + name + [0, 0, 5, 3, 78, 101, 119, 0x20, 0]
        XCTAssertTrue(effect.update(capability))
        XCTAssertEqual(effect.presets?.map(\.id), [3, 0, 5, 0x20])
        XCTAssertEqual(effect.presets?.map(\.name), ["Salle Écho", "Off", "New", "Preset 20"])
        XCTAssertEqual(effect.selectablePresets.map(\.id), [3, 0, 5])
        XCTAssertTrue(effect.update([0x43, 1, 0]))
        XCTAssertNil(effect.setPayload(3))
        XCTAssertTrue(effect.update([0x47, 1, 0]))
        XCTAssertEqual(effect.setPayload(3), [0x48, 1, 3])
        XCTAssertEqual(effect.setPayload(5), [0x48, 1, 5])
        XCTAssertNil(effect.setPayload(1))
        XCTAssertNil(effect.setPayload(0x20))
        XCTAssertTrue(effect.acceptsSetPayload([0x48, 1, 3]))
        XCTAssertFalse(effect.acceptsSetPayload([0x48, 2, 3]))
        XCTAssertTrue(effect.update([0x45, 1, 1]))
        XCTAssertFalse(effect.canSet)
        XCTAssertFalse(effect.acceptsSetPayload([0x48, 1, 3]))
        XCTAssertTrue(effect.confirmsSetPayload([0x48, 1, 3], response: [0x49, 1, 3]))
        XCTAssertFalse(effect.confirmsSetPayload([0x48, 1, 3], response: [0x49, 2, 3]))
        XCTAssertFalse(effect.confirmsSetPayload([0x48, 1, 3], response: [0x47, 1, 0]))
        XCTAssertFalse(effect.confirmsSetPayload([0x48, 1, 3], response: [0x48, 1, 3]))
        XCTAssertTrue(effect.update([0x49, 1, 0x20]))
        XCTAssertEqual(effect.presetID, 0x20)
        XCTAssertEqual(effect.selectedTitle, "Preset 20")
        XCTAssertTrue(effect.update([0x45, 1, 0x80]))
        XCTAssertEqual(effect.status, 0x80)
        XCTAssertNil(effect.available)
        XCTAssertNil(effect.setPayload(0))
    }

    func testMalformedCapabilitiesNeverReplaceTheLastValidList() {
        var effect = SonyLegacySoundEffect(kind: .surround, supportedFunctions: [0x41])
        XCTAssertTrue(effect.update([0x41, 1, 1, 0, 0]))
        let original = effect
        let malformed: [[UInt8]] = [
            [0x41, 1, 1], [0x41, 1, 1, 0, 2, 65], [0x41, 1, 1, 0, 1, 0xFF],
            [0x41, 1, 1, 0, 0, 99], [0x41, 1, 2, 0, 0, 0, 0],
            [0x41, 1, 1, 0, 129] + Array(repeating: 65, count: 129)
        ]
        for payload in malformed {
            XCTAssertFalse(effect.update(payload), "Unexpectedly accepted \(payload)")
            XCTAssertEqual(effect, original)
        }
        XCTAssertTrue(effect.update([0x41, 1, 1, 1, 128] + Array(repeating: 65, count: 128)))
        XCTAssertEqual(effect.presets?.first?.name.count, 128)
        XCTAssertTrue(effect.update([0x41, 1, 0]))
        XCTAssertEqual(effect.presets, [])
        XCTAssertFalse(effect.canSet)
    }

    func testSoundPositionTypeAndSupportAreIndependentOfSurround() {
        let absent = SonyLegacySoundEffect(kind: .soundPosition, supportedFunctions: [0x41])
        XCTAssertFalse(absent.isSupported)
        XCTAssertTrue(absent.queryPayloads.isEmpty)
        var effect = SonyLegacySoundEffect(kind: .soundPosition, supportedFunctions: [0x42])
        XCTAssertEqual(effect.queryPayloads, [[0x40, 2, 1], [0x42, 2], [0x46, 2]])
        XCTAssertFalse(effect.update([0x41, 1, 0]))
        XCTAssertTrue(effect.update([0x43, 2, 0]))
        XCTAssertTrue(effect.update([0x47, 2, 0]))
        XCTAssertFalse(effect.canSet)
        for type: UInt8 in [0, 0x80] {
            XCTAssertTrue(effect.update([0x41, 2, type]))
            XCTAssertEqual(effect.positionType, type)
            XCTAssertTrue(effect.selectablePresets.isEmpty)
            XCTAssertNil(effect.setPayload(0))
        }
        XCTAssertTrue(effect.update([0x41, 2, 1]))
        XCTAssertEqual(effect.presets?.map(\.id), [0, 1, 2, 3, 0x11, 0x12])
        XCTAssertEqual(effect.presets?.map(\.name), ["Off", "Front Left", "Front Right", "Front", "Rear Left", "Rear Right"])
        XCTAssertTrue(effect.canSet)
        XCTAssertEqual(effect.setPayload(0x11), [0x48, 2, 0x11])
        XCTAssertNil(effect.setPayload(4))
        XCTAssertTrue(effect.update([0x49, 2, 0x12]))
        XCTAssertEqual(effect.selectedTitle, "Rear Right")
        XCTAssertTrue(effect.confirmsSetPayload([0x48, 2, 0x12], response: [0x47, 2, 0x12]))
        XCTAssertFalse(effect.confirmsSetPayload([0x48, 2, 0x12], response: [0x47, 1, 0x12]))
        XCTAssertTrue(effect.update([0x49, 2, 0xEE]))
        XCTAssertEqual(effect.presetID, 0xEE)
        XCTAssertEqual(effect.selectedTitle, "Preset EE")
        XCTAssertNil(effect.setPayload(0xEE))
        XCTAssertFalse(effect.update([0x47, 2, 0, 1]))
        XCTAssertEqual(effect.presetID, 0xEE)
    }
}
