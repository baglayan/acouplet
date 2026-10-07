import XCTest
@testable import Acouplet

final class SonyConnectionAlertsTests: XCTestCase {
    func testLegacyConnectionCautionHasNoTargetAndRequiresAnExplicitBinaryReply() throws {
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 1, 1, 1], generation: .v1))
        XCTAssertEqual(alert.format, .legacyFixed)
        XCTAssertTrue(alert.isLegacyConnectionChange)
        XCTAssertNil(alert.requestedMode)
        XCTAssertFalse(alert.isMultipointChange)
        XCTAssertTrue(alert.affectedFeatures.isEmpty)
        XCTAssertEqual(alert.availableActions, [.negative, .positive])
        XCTAssertEqual(alert.replyPayload(.negative), [0x98, 1, 1, 0])
        XCTAssertEqual(alert.replyPayload(.positive), [0x98, 1, 1, 1])
        for payload: [UInt8] in [[0x99, 1, 1, 0], [0x99, 1, 1, 2], [0x99, 1, 1, 0xFF],
                                [0x99, 1, 0, 1], [0x99, 1, 0x74, 1]] {
            let unrelated = try XCTUnwrap(SonyConnectionAlert(payload: payload, generation: .v1))
            XCTAssertFalse(unrelated.isLegacyConnectionChange)
            XCTAssertNil(unrelated.requestedMode)
            XCTAssertTrue(unrelated.availableActions.isEmpty)
            XCTAssertNil(unrelated.replyPayload(.positive))
            XCTAssertNil(unrelated.replyPayload(.negative))
        }
    }

    func testLegacyCautionRequiresItsExactShapeAndNegotiatedGeneration() {
        let payload: [UInt8] = [0x99, 1, 1, 1]
        for length in 0..<payload.count {
            XCTAssertNil(SonyConnectionAlert(payload: Array(payload.prefix(length)), generation: .v1))
        }
        for invalid in [payload + [0], [0x98, 1, 1, 1], [0x99, 0, 0x74, 1], [0x99, 6, 0x11, 0, 1]] {
            XCTAssertNil(SonyConnectionAlert(payload: invalid, generation: .v1))
        }
        XCTAssertNil(SonyConnectionAlert(payload: payload))
        XCTAssertNil(SonyConnectionAlert(payload: payload, generation: .v2))
        XCTAssertNotNil(SonyConnectionAlert(payload: [0x99, 0, 0x74, 1]))
    }

    func testFixedConnectionAlertsIdentifyModeAndBuildExactReplies() throws {
        for (messageID, expectedMode): (UInt8, SonyConnectionMode) in [
            (0x74, .soundQuality), (0x75, .stableConnection),
            (0x76, .soundQuality), (0x77, .stableConnection),
        ] {
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x00, messageID, 0x01]))
            XCTAssertEqual(alert.format, .fixed)
            XCTAssertEqual(alert.requestedMode, expectedMode)
            XCTAssertEqual(alert.actionType, .positiveNegative)
            XCTAssertTrue(alert.affectedFeatures.isEmpty)
            XCTAssertEqual(alert.availableActions, [.negative, .positive])
            XCTAssertEqual(alert.replyPayload(.negative), [0x98, 0x00, messageID, 0x00])
            XCTAssertEqual(alert.replyPayload(.positive), [0x98, 0x00, messageID, 0x01])
        }
    }

    func testFlexibleConnectionAlertsPreserveAffectedFeaturesAndReplyWithoutTheList() throws {
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, 0x11, 0x04, 0x05, 0x18, 0x19, 0xA5, 0x01]))
        XCTAssertEqual(alert.format, .flexible)
        XCTAssertEqual(alert.requestedMode, .lowLatency)
        XCTAssertEqual(alert.affectedFeatures.map(\.rawValue), [0x05, 0x18, 0x19, 0xA5])
        XCTAssertEqual(alert.affectedFeatures.map(\.title), [
            "Service Link", "LDAC playback", "Some Scene-based Listening functions", "Unknown feature",
        ])
        XCTAssertEqual(alert.replyPayload(.positive), [0x98, 0x06, 0x11, 0x01])
        XCTAssertEqual(alert.replyPayload(.negative), [0x98, 0x06, 0x11, 0x00])
        let pairing = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, 0x10, 0x00, 0x01]))
        XCTAssertEqual(pairing.requestedMode, .lowLatency)
        XCTAssertTrue(pairing.affectedFeatures.isEmpty)
        XCTAssertEqual(pairing.replyPayload(.positive), [0x98, 0x06, 0x10, 0x01])
    }

    func testMultipointAlertsRecognizeOnlyTheirFormatsAndPreserveActionContracts() throws {
        for prefix: [UInt8] in [[0x99, 0x00, 0x06], [0x99, 0x00, 0x07], [0x99, 0x00, 0x70], [0x99, 0x06, 0x01, 0x02, 0x06, 0xA5]] {
            for actionType: UInt8 in [0x00, 0x01, 0x02, 0xFF] {
                let alert = try XCTUnwrap(SonyConnectionAlert(payload: prefix + [actionType]))
                XCTAssertTrue(alert.isMultipointChange)
                XCTAssertNil(alert.requestedMode)
                XCTAssertEqual(alert.affectedFeatures.map(\.rawValue), prefix[1] == 0 ? [] : [0x06, 0xA5])
                let actions: [SonyConnectionAlertAction] = actionType == 1 ? [.negative, .positive] : actionType == 2 ? [.positive] : []
                XCTAssertEqual(alert.availableActions, actions)
                for action: SonyConnectionAlertAction in [.negative, .positive] {
                    XCTAssertEqual(alert.replyPayload(action), actions.contains(action) ? [0x98, prefix[1], prefix[2], action.rawValue] : nil)
                }
            }
            let payload = prefix + [0x01]
            for length in 0..<payload.count { XCTAssertNil(SonyConnectionAlert(payload: Array(payload.prefix(length)))) }
            XCTAssertNil(SonyConnectionAlert(payload: payload + [0x00]))
        }
        for payload: [UInt8] in [[0x99, 0x00, 0x01, 1], [0x99, 0x06, 0x06, 0, 1], [0x99, 0x06, 0x07, 0, 1], [0x99, 0x06, 0x70, 0, 1]] {
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: payload))
            XCTAssertFalse(alert.isMultipointChange)
            XCTAssertTrue(alert.availableActions.isEmpty)
            XCTAssertNil(alert.replyPayload(.positive))
            XCTAssertNil(alert.replyPayload(.negative))
        }
    }

    func testConfirmationOnlyNeverRepliesAndPositiveConfirmationCannotReject() throws {
        for prefix: [UInt8] in [[0x99, 0x00, 0x74], [0x99, 0x06, 0x11, 0x00]] {
            let confirmation = try XCTUnwrap(SonyConnectionAlert(payload: prefix + [0x00]))
            XCTAssertEqual(confirmation.actionType, .confirmationOnly)
            XCTAssertTrue(confirmation.availableActions.isEmpty)
            XCTAssertNil(confirmation.replyPayload(.positive))
            XCTAssertNil(confirmation.replyPayload(.negative))
            let confirmationWithReply = try XCTUnwrap(SonyConnectionAlert(payload: prefix + [0x02]))
            XCTAssertEqual(confirmationWithReply.actionType, .positiveConfirmationWithReply)
            XCTAssertEqual(confirmationWithReply.availableActions, [.positive])
            XCTAssertNotNil(confirmationWithReply.replyPayload(.positive))
            XCTAssertNil(confirmationWithReply.replyPayload(.negative))
        }
    }

    func testUnrelatedMessagesAndUnknownActionTypesCannotBuildReplies() throws {
        for payload: [UInt8] in [
            [0x99, 0x00, 0x10, 0x01], [0x99, 0x00, 0x73, 0x01],
            [0x99, 0x00, 0xFF, 0x01], [0x99, 0x06, 0x74, 0x00, 0x01],
            [0x99, 0x06, 0x0F, 0x00, 0x01], [0x99, 0x06, 0xFF, 0x00, 0x01],
        ] {
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: payload))
            XCTAssertEqual(alert.messageID, payload[2])
            XCTAssertNil(alert.requestedMode)
            XCTAssertTrue(alert.availableActions.isEmpty)
            XCTAssertNil(alert.replyPayload(.positive))
            XCTAssertNil(alert.replyPayload(.negative))
        }
        for prefix: [UInt8] in [[0x99, 0x00, 0x74], [0x99, 0x06, 0x11, 0x00]] {
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: prefix + [0xFF]))
            XCTAssertEqual(alert.actionType, .unknown(0xFF))
            XCTAssertNotNil(alert.requestedMode)
            XCTAssertTrue(alert.availableActions.isEmpty)
            XCTAssertNil(alert.replyPayload(.positive))
            XCTAssertNil(alert.replyPayload(.negative))
        }
    }

    func testMalformedMessagesAndCountBoundaries() throws {
        let fixed: [UInt8] = [0x99, 0x00, 0x74, 0x01]
        let flexible: [UInt8] = [0x99, 0x06, 0x11, 0x02, 0x05, 0x18, 0x01]
        for payload in [fixed, flexible] {
            for length in 0..<payload.count {
                XCTAssertNil(SonyConnectionAlert(payload: Array(payload.prefix(length))))
            }
            XCTAssertNil(SonyConnectionAlert(payload: payload + [0x00]))
        }
        for payload: [UInt8] in [
            [0x98, 0x00, 0x74, 0x01], [0x95, 0x00, 0x74, 0x01],
            [0x99, 0x05, 0x74, 0x01], [0x99, 0xFF, 0x74, 0x01],
            [0x99, 0x06, 0x11, 0x01, 0x01], [0x99, 0x06, 0x11, 0xFF, 0x01],
        ] {
            XCTAssertNil(SonyConnectionAlert(payload: payload))
        }
        let maximum = [UInt8(0x99), 0x06, 0x11, 0xFF] + Array(repeating: UInt8(0xA5), count: 255) + [0x01]
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: maximum))
        XCTAssertEqual(alert.affectedFeatures.count, 255)
        XCTAssertTrue(alert.affectedFeatures.allSatisfy { $0.rawValue == 0xA5 })
        XCTAssertEqual(alert.actionType, .positiveNegative)
        XCTAssertNil(SonyConnectionAlert(payload: Array(maximum.dropLast())))
        XCTAssertNil(SonyConnectionAlert(payload: maximum + [0x00]))
    }
}
