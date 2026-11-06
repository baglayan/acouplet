import XCTest
@testable import Acouplet

final class SonyLegacyIndicatorsTests: XCTestCase {
    func testAdvertisedLegacyFunctionsGateEachQueryAndResponseIndependently() {
        let features: [(UInt8, [UInt8], [UInt8])] = [
            (0x13, [0x18, 0], [0x19, 0, 0x10]),
            (0x12, [0x14, 0], [0x15, 0, 2, 1]),
            (0x17, [0x24, 1], [0x25, 1, 1, 0]),
        ]
        for mask in 0..<8 {
            let advertised = features.enumerated().filter { mask & (1 << $0.offset) != 0 }
            var indicators = SonyLegacyIndicators(supportedFunctions: Set(advertised.map { $0.element.0 }))
            XCTAssertEqual(indicators.queryPayloads, advertised.map { $0.element.1 })
            XCTAssertEqual(indicators.supportsCodecStatus, mask & 1 != 0)
            XCTAssertEqual(indicators.supportsUpscalingStatus, mask & 2 != 0)
            XCTAssertEqual(indicators.supportsConnectionStatus, mask & 4 != 0)
            for (index, feature) in features.enumerated() {
                XCTAssertEqual(indicators.update(feature.2), mask & (1 << index) != 0)
            }
        }
        let modernFunctions = SonyLegacyIndicators(supportedFunctions: [0x11, 0xE2])
        XCTAssertTrue(modernFunctions.queryPayloads.isEmpty)
    }

    func testCodecRepliesAndNotificationsRecognizeOnlyLegacyCodecs() {
        var indicators = SonyLegacyIndicators(supportedFunctions: [0x13])
        XCTAssertNil(indicators.codec)
        let expected: [UInt8: SonyAudioCodec] = [0: .unsettled, 1: .sbc, 2: .aac, 0x10: .ldac,
                                               0x20: .aptX, 0x21: .aptXHD, 0xFF: .other]
        for command: UInt8 in [0x19, 0x1B] {
            for value in UInt8.min...UInt8.max {
                XCTAssertTrue(indicators.update([command, 0, value]))
                XCTAssertEqual(indicators.codecValue, value)
                XCTAssertEqual(indicators.codec, expected[value] ?? .unknown(value))
            }
        }
    }

    func testUpscalingKeepsEffectTypeAndAllThreeStatusesSeparate() {
        var indicators = SonyLegacyIndicators(supportedFunctions: [0x12])
        XCTAssertNil(indicators.upscalingType)
        XCTAssertNil(indicators.upscalingStatus)
        for command: UInt8 in [0x15, 0x17] {
            for type: UInt8 in [0, 1, 2, 3, 127, 128, 255] {
                for status: UInt8 in [0, 1, 2, 3, 127, 128, 255] {
                    XCTAssertTrue(indicators.update([command, 0, type, status]))
                    XCTAssertEqual(indicators.upscalingTypeValue, type)
                    XCTAssertEqual(indicators.upscalingStatusValue, status)
                    XCTAssertEqual(indicators.upscalingType, SonyLegacyIndicators.UpscalingType(rawValue: type))
                    XCTAssertEqual(indicators.upscalingStatus, SonyLegacyIndicators.UpscalingStatus(rawValue: status))
                }
            }
        }
    }

    func testConnectionKeepsLeftAndRightIndependentAndUnknownDistinctFromDisconnected() {
        var indicators = SonyLegacyIndicators(supportedFunctions: [0x17])
        XCTAssertNil(indicators.leftConnected)
        XCTAssertNil(indicators.rightConnected)
        for command: UInt8 in [0x25, 0x27] {
            for left: UInt8 in [0, 1, 2, 127, 128, 255] {
                for right: UInt8 in [0, 1, 2, 127, 128, 255] {
                    XCTAssertTrue(indicators.update([command, 1, left, right]))
                    XCTAssertEqual(indicators.leftConnectionValue, left)
                    XCTAssertEqual(indicators.rightConnectionValue, right)
                    XCTAssertEqual(indicators.leftConnected, left <= 1 ? left == 1 : nil)
                    XCTAssertEqual(indicators.rightConnected, right <= 1 ? right == 1 : nil)
                }
            }
        }
    }

    func testMalformedOrOtherTableMessagesNeverMutatePreviousReadbacks() {
        var indicators = SonyLegacyIndicators(supportedFunctions: [0x12, 0x13, 0x17])
        XCTAssertTrue(indicators.update([0x19, 0, 0x10]))
        XCTAssertTrue(indicators.update([0x15, 0, 2, 1]))
        XCTAssertTrue(indicators.update([0x25, 1, 1, 0]))
        let previous = indicators
        for payload: [UInt8] in [[0x19, 0, 2], [0x1B, 0, 2], [0x15, 0, 1, 0], [0x17, 0, 1, 0],
                                 [0x25, 1, 0, 1], [0x27, 1, 0, 1]] {
            var invalid = (0..<payload.count).map { Array(payload.prefix($0)) }
            invalid.append(payload + [0])
            invalid += [0, 1, 2, 255].filter { $0 != payload[1] }.map { [payload[0], $0] + payload.dropFirst(2) }
            for value in invalid {
                XCTAssertFalse(indicators.update(value))
                XCTAssertEqual(indicators, previous)
            }
            for frame: UInt8 in [0x0E, 0x1C, 0x2C] {
                XCTAssertFalse(indicators.update(payload, frameType: frame))
                XCTAssertEqual(indicators, previous)
            }
        }
        for unrelated: [UInt8] in [[0x13, 2, 0x10], [0x15, 2, 0x10], [0x25, 0, 90, 1], [0x27, 2, 1, 1]] {
            XCTAssertFalse(indicators.update(unrelated))
            XCTAssertEqual(indicators, previous)
        }
        indicators = SonyLegacyIndicators(supportedFunctions: [0x12, 0x13, 0x17])
        XCTAssertNil(indicators.codec)
        XCTAssertNil(indicators.upscalingType)
        XCTAssertNil(indicators.upscalingStatus)
        XCTAssertNil(indicators.leftConnected)
        XCTAssertNil(indicators.rightConnected)
    }

    func testReadInvalidationClearsOnlyItsIndicator() {
        for query: [UInt8] in [[0x18, 0], [0x14, 0], [0x24, 1]] {
            var indicators = SonyLegacyIndicators(supportedFunctions: [0x12, 0x13, 0x17])
            indicators.update([0x19, 0, 0x10])
            indicators.update([0x15, 0, 2, 1])
            indicators.update([0x25, 1, 1, 0])
            indicators.invalidateRead(query)
            XCTAssertEqual(indicators.codec, query == [0x18, 0] ? nil : .ldac)
            XCTAssertEqual(indicators.upscalingType, query == [0x14, 0] ? nil : .dseeHXAI)
            XCTAssertEqual(indicators.upscalingStatus, query == [0x14, 0] ? nil : .valid)
            XCTAssertEqual(indicators.leftConnected, query == [0x24, 1] ? nil : true)
            XCTAssertEqual(indicators.rightConnected, query == [0x24, 1] ? nil : false)
            XCTAssertEqual(indicators.queryPayloads, [[0x18, 0], [0x14, 0], [0x24, 1]])
        }
    }
}
