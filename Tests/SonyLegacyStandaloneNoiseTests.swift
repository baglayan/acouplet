import XCTest
@testable import Acouplet

final class SonyLegacyStandaloneNoiseTests: XCTestCase {
    func testStandaloneNoiseCancellingUsesItsOwnQueryAndBinaryTuple() {
        var model = SonyLegacyNoiseControl(inquiryType: 1)
        XCTAssertEqual(model.queryPayloads, [[0x60, 1], [0x62, 1], [0x66, 1]])
        XCTAssertNil(model.setPayload(enabled: true))
        XCTAssertTrue(model.update([0x61, 1, 0]))
        XCTAssertTrue(model.update([0x67, 1, 0, 0]))
        XCTAssertFalse(model.canSet)
        XCTAssertTrue(model.update([0x63, 1, 0]))
        XCTAssertEqual(model.enabled, false)
        XCTAssertEqual(model.setPayload(enabled: true), [0x68, 1, 0, 1])
        XCTAssertTrue(model.acceptsSetPayload([0x68, 1, 0, 1]))
        XCTAssertNil(model.setPayload(enabled: true, focusOnVoice: false))
        XCTAssertTrue(model.update([0x69, 1, 0, 1]))
        XCTAssertEqual(model.enabled, true)
        XCTAssertEqual(model.setPayload(enabled: false), [0x68, 1, 0, 0])
        XCTAssertTrue(model.update([0x65, 1, 1]))
        XCTAssertFalse(model.canSet)
    }

    func testStandaloneAmbientPreservesItsConfirmedModeAndRequiresAdvertisedVoice() {
        var model = readyAmbient()
        XCTAssertEqual(model.queryPayloads, [[0x60, 3], [0x62, 3], [0x66, 3]])
        XCTAssertEqual(model.setPayload(enabled: false), [0x68, 3, 0, 0, 1, 0])
        XCTAssertEqual(model.setPayload(enabled: true), [0x68, 3, 1, 0, 1, 1])
        XCTAssertEqual(model.setPayload(enabled: true, focusOnVoice: false), [0x68, 3, 1, 0, 0, 1])
        XCTAssertTrue(model.update([0x69, 3, 0x10, 0, 1, 1]))
        XCTAssertNil(model.enabled)
        XCTAssertFalse(model.canSet)
        XCTAssertTrue(model.update([0x69, 3, 0x11, 0, 1, 1]))
        XCTAssertEqual(model.enabled, true)
        XCTAssertTrue(model.update([0x61, 3, 0, 1, 0, 2]))
        XCTAssertFalse(model.canSet)
        XCTAssertTrue(model.update([0x69, 3, 1, 0, 0, 1]))
        XCTAssertTrue(model.canSet)
        XCTAssertNil(model.setPayload(enabled: true, focusOnVoice: true))
    }

    func testCoadvertisedDomainsKeepCapabilitiesAvailabilityAndStateIndependent() throws {
        var controls = try XCTUnwrap(SonyLegacyControls(supportPayload: [7, 0, 3, 0x61, 0x62, 0x63]))
        XCTAssertEqual(Set(controls.noiseQueries), Set([UInt8(1), 2, 3].flatMap { [[0x60, $0], [0x62, $0], [0x66, $0]] }))
        for payload: [UInt8] in [[0x61, 1, 0], [0x63, 1, 0], [0x67, 1, 0, 1],
                                 [0x61, 3, 0, 1, 0, 2], [0x63, 3, 0], [0x67, 3, 0, 0, 0, 0],
                                 [0x61, 2, 2, 3, 1, 1, 0, 20], [0x63, 2, 0], [0x67, 2, 1, 2, 0, 1, 0, 12]] {
            XCTAssertTrue(controls.update(payload))
        }
        XCTAssertEqual(controls.standaloneNoiseCancel?.enabled, true)
        XCTAssertEqual(controls.standaloneAmbient?.enabled, false)
        XCTAssertTrue(controls.canSetNoiseControl)
        XCTAssertTrue(controls.allows([0x68, 1, 0, 0]))
        XCTAssertTrue(controls.allows([0x68, 3, 1, 0, 0, 1]))
        let combined = controls.noiseState
        XCTAssertTrue(controls.update([0x65, 1, 1]))
        XCTAssertEqual(controls.standaloneNoiseCancel?.canSet, false)
        XCTAssertEqual(controls.standaloneAmbient?.canSet, true)
        XCTAssertEqual(controls.noiseState, combined)
        controls.invalidateStandaloneNoiseRead([0x66, 3])
        XCTAssertNil(controls.standaloneAmbient?.state)
        XCTAssertNotNil(controls.standaloneNoiseCancel?.state)
        XCTAssertEqual(controls.noiseState, combined)
    }

    func testMalformedUnknownAndUnsupportedValuesCannotRetainStandaloneWrites() {
        for payload: [UInt8] in [[0x61, 3], [0x61, 3, 0, 1], [0x61, 3, 0, 2, 0, 2, 0, 2],
                                 [0x61, 3, 1, 1, 0, 20], [0x61, 3, 255, 1, 0, 2],
                                 [0x63, 3], [0x65, 3, 255], [0x63, 3, 0, 0],
                                 [0x67, 3], [0x69, 3, 1, 0, 1, 2], [0x69, 3, 1, 0, 255, 1],
                                 [0x69, 3, 255, 0, 1, 1], [0x69, 3, 1, 1, 1, 1]] {
            var model = readyAmbient()
            XCTAssertTrue(model.canSet)
            XCTAssertTrue(model.update(payload))
            XCTAssertFalse(model.canSet, "\(payload)")
            XCTAssertNil(model.setPayload(enabled: false))
        }
        var model = SonyLegacyNoiseControl(inquiryType: 1)
        model.update([0x61, 1, 1])
        model.update([0x63, 1, 0])
        model.update([0x67, 1, 1, 1])
        XCTAssertTrue(model.canSet)
        XCTAssertEqual(model.enabled, true)
        XCTAssertEqual(model.setPayload(enabled: false), [0x68, 1, 0, 0])
        XCTAssertTrue(model.acceptsSetPayload([0x68, 1, 0, 0]))
        XCTAssertTrue(model.update([0x69, 1, 0, 0]))
        XCTAssertTrue(model.canSet)
        XCTAssertEqual(model.enabled, false)
        XCTAssertTrue(model.update([0x69, 1, 255, 1]))
        XCTAssertFalse(model.canSet)
        XCTAssertNil(model.enabled)
        let prior = model
        XCTAssertFalse(model.update([0x67, 3, 1, 0, 0, 1]))
        XCTAssertEqual(model, prior)
        XCTAssertNil(SonyLegacyNoiseState(payload: [0x67, 1, 0, 1, 0]))
    }

    private func readyAmbient() -> SonyLegacyNoiseControl {
        var model = SonyLegacyNoiseControl(inquiryType: 3)
        model.update([0x61, 3, 0, 2, 0, 2, 1, 2])
        model.update([0x63, 3, 0])
        model.update([0x67, 3, 1, 0, 1, 1])
        return model
    }
}
