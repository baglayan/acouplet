import XCTest
@testable import Acouplet

final class SonyConnectionTransitionTests: XCTestCase {
    let modes: [SonyConnectionMode] = [.soundQuality, .stableConnection, .lowLatency]

    func testLegacyQualityUsesTypedPacketsAndCannotRequestOrInferLEAudio() throws {
        for (original, target, value): (SonyConnectionMode, SonyConnectionMode, UInt8) in [
            (.soundQuality, .stableConnection, 1), (.stableConnection, .soundQuality, 0),
        ] {
            var transition = try XCTUnwrap(SonyConnectionTransition(original: original, target: target,
                supportedModes: modes, session: 3, generation: .v1))
            XCTAssertEqual(transition.generation, .v1)
            XCTAssertEqual(transition.requestPayload, [0xE8, 1, 0, value])
            XCTAssertEqual(transition.readbackPayload, [0xE6, 1])
            XCTAssertFalse(transition.crossesTransport)
            XCTAssertFalse(transition.receiveNotification(target, stream: .none, session: 3))
            XCTAssertFalse(transition.readbackTransmitted(session: 3))
            XCTAssertFalse(transition.commandTransmitted([0xE8, 5, value, 0], session: 3))
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, session: 2))
            XCTAssertTrue(transition.commandTransmitted(transition.requestPayload, session: 3))
            XCTAssertFalse(transition.receiveLEStandby(true, session: 3))
            for stream: SonyConnectionStream in [.classicAudio, .leAudio, .unknown(0xFF)] {
                XCTAssertFalse(transition.receiveNotification(target, stream: stream, session: 3))
            }
            XCTAssertNil(transition.requiredStream)
            XCTAssertFalse(transition.preferenceConfirmed)
            XCTAssertTrue(transition.receiveNotification(target, stream: .none, session: 3))
            XCTAssertEqual(transition.phase, .confirmed)
        }
        XCTAssertNil(SonyConnectionTransition(original: .soundQuality, target: .lowLatency,
            supportedModes: modes, session: 1, generation: .v1))
        XCTAssertNil(SonyConnectionTransition(original: .lowLatency, target: .soundQuality,
            supportedModes: modes, session: 1, generation: .v1))
    }

    func testLegacyCautionMatchesEitherOwnedQualityChangeButNeverAnswersItself() throws {
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 1, 1, 1], generation: .v1))
        let modern = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0, 0x75, 1]))
        for action: SonyConnectionAlertAction in [.negative, .positive] {
            var transition = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .stableConnection,
                supportedModes: modes, session: 7, generation: .v1))
            XCTAssertFalse(transition.receiveAlert(alert, session: 7))
            transition.commandTransmitted(transition.requestPayload, session: 7)
            transition.readbackTransmitted(session: 7)
            XCTAssertFalse(transition.receiveAlert(modern, session: 7))
            XCTAssertFalse(transition.receiveAlert(alert, session: 6))
            XCTAssertTrue(transition.receiveAlert(alert, session: 7))
            XCTAssertEqual(transition.phase, .awaitingUser(alert))
            XCTAssertFalse(transition.timeout())
            XCTAssertFalse(transition.acknowledge(alert))
            XCTAssertFalse(transition.receiveReadback(.stableConnection, session: 7))
            XCTAssertFalse(transition.receiveNotification(.stableConnection, stream: .none, session: 7))
            let reply = try XCTUnwrap(transition.respond(to: alert, action: action))
            XCTAssertEqual(reply, [0x98, 1, 1, action.rawValue])
            XCTAssertEqual(transition.phase, .replyQueued(alert, action))
            XCTAssertFalse(transition.commandTransmitted(reply, session: 6))
            XCTAssertTrue(transition.commandTransmitted(reply, session: 7))
            XCTAssertEqual(transition.phase, action == .positive ? .awaitingResponse : .cancelled)
            XCTAssertFalse(transition.preferenceConfirmed)
        }
        var reverse = try XCTUnwrap(SonyConnectionTransition(original: .stableConnection, target: .soundQuality,
            supportedModes: modes, session: 7, generation: .v1))
        reverse.commandTransmitted(reverse.requestPayload, session: 7)
        XCTAssertTrue(reverse.receiveAlert(alert, session: 7))
        XCTAssertEqual(reverse.targetMode, .soundQuality)
        let offeredReply = try XCTUnwrap(reverse.respond(to: alert, action: .positive))
        XCTAssertEqual(reverse.targetMode, .stableConnection)
        XCTAssertEqual(offeredReply, [0x98, 1, 1, 1])
        reverse.commandTransmitted(offeredReply, session: 7)
        XCTAssertFalse(reverse.commandTransmitted(reverse.requestPayload, session: 7))
        reverse.readbackTransmitted(session: 7)
        reverse.receiveReadback(.soundQuality, session: 7)
        XCTAssertFalse(reverse.preferenceConfirmed)
        reverse.readbackTransmitted(session: 7)
        reverse.receiveReadback(.stableConnection, session: 7)
        XCTAssertEqual(reverse.phase, .confirmed)
        XCTAssertFalse(reverse.receiveAlert(alert, session: 7))
        var modernTransition = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .stableConnection,
            supportedModes: modes, session: 7))
        modernTransition.commandTransmitted(modernTransition.requestPayload, session: 7)
        XCTAssertFalse(modernTransition.receiveAlert(alert, session: 7))
    }

    func testLegacyQualityRecoveryNeedsFreshOwnedReadbackAndNeverReplaysTheSetter() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .stableConnection,
            supportedModes: modes, session: 8, generation: .v1))
        transition.commandTransmitted(transition.requestPayload, session: 8)
        transition.readbackTransmitted(session: 8)
        XCTAssertTrue(transition.controlLost(session: 8))
        XCTAssertEqual(transition.phase, .recovering)
        XCTAssertFalse(transition.receiveReadback(.stableConnection, session: 8))
        XCTAssertFalse(transition.timeout())
        XCTAssertTrue(transition.controlReady(session: 9))
        XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, session: 9))
        XCTAssertFalse(transition.receiveReadback(.stableConnection, session: 9))
        XCTAssertTrue(transition.receiveNotification(.stableConnection, stream: .none, session: 9))
        XCTAssertEqual(transition.phase, .verifying)
        XCTAssertTrue(transition.readbackTransmitted(session: 9))
        XCTAssertFalse(transition.receiveReadback(.stableConnection, session: 8))
        XCTAssertTrue(transition.receiveReadback(.unknown(2), session: 9))
        XCTAssertFalse(transition.preferenceConfirmed)
        transition.readbackTransmitted(session: 9)
        transition.receiveReadback(.soundQuality, session: 9)
        XCTAssertEqual(transition.phase, .verifying)
        XCTAssertTrue(transition.timeout())
        XCTAssertTrue(transition.retryRecovery())
        XCTAssertTrue(transition.controlReady(session: 10))
        transition.readbackTransmitted(session: 10)
        transition.receiveReadback(.stableConnection, session: 10)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertNil(transition.requiredStream)
    }

    func testFirstPairingRequiresTransmittedPositiveReplyAndStandbyOnInSameSession() throws {
        for (messageID, action): (UInt8, SonyConnectionAlertAction) in [(0x10, .positive), (0x10, .negative), (0x11, .positive)] {
            var transition = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
            transition.commandTransmitted(transition.requestPayload, session: 1)
            XCTAssertFalse(transition.receiveLEStandby(true, session: 1))
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, messageID, 0, 1]))
            transition.receiveAlert(alert, session: 1)
            let reply = try XCTUnwrap(transition.respond(to: alert, action: action))
            XCTAssertFalse(transition.receiveLEStandby(true, session: 1))
            transition.commandTransmitted(reply, session: 1)
            XCTAssertFalse(transition.receiveLEStandby(true, session: 0))
            XCTAssertFalse(transition.receiveLEStandby(false, session: 1))
            XCTAssertEqual(transition.receiveLEStandby(true, session: 1), messageID == 0x10 && action == .positive)
            if messageID == 0x10 && action == .positive {
                XCTAssertEqual(transition.phase, .pairingRequired)
                XCTAssertFalse(transition.isFinished)
                XCTAssertFalse(transition.timeout())
                XCTAssertFalse(transition.recoveryFailed())
                XCTAssertFalse(transition.controlLost(session: 1))
                XCTAssertEqual(transition.phase, .pairingRequired)
            }
        }
    }

    func testCheckingPairingRequiresFreshReadbackAndOriginalPreferenceRemainsUnconfirmed() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
        transition.commandTransmitted(transition.requestPayload, session: 1)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, 0x10, 0, 1]))
        transition.receiveAlert(alert, session: 1)
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .positive))
        transition.commandTransmitted(reply, session: 1)
        transition.readbackTransmitted(session: 1)
        transition.receiveLEStandby(true, session: 1)
        XCTAssertFalse(transition.receiveReadback(.lowLatency, session: 1))
        XCTAssertFalse(transition.receiveNotification(.lowLatency, stream: .leAudio, session: 1))
        XCTAssertTrue(transition.retryRecovery())
        XCTAssertTrue(transition.controlReady(session: 2))
        XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, session: 2))
        transition.readbackTransmitted(session: 2)
        transition.receiveReadback(.soundQuality, session: 2)
        XCTAssertEqual(transition.phase, .pairingRequired)
        XCTAssertFalse(transition.preferenceConfirmed)
        XCTAssertTrue(transition.retryRecovery())
        XCTAssertTrue(transition.controlReady(session: 3))
        transition.readbackTransmitted(session: 3)
        transition.receiveReadback(.lowLatency, session: 3)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertTrue(transition.preferenceConfirmed)
    }

    func testOnlySupportedKnownChangesCanBeQueuedAndTransmissionMustMatch() throws {
        XCTAssertNil(SonyConnectionTransition(original: .soundQuality, target: .soundQuality, supportedModes: modes, session: 1))
        XCTAssertNil(SonyConnectionTransition(original: .unknown(3), target: .lowLatency, supportedModes: modes, session: 1))
        XCTAssertNil(SonyConnectionTransition(original: .soundQuality, target: .unknown(3), supportedModes: modes + [.unknown(3)], session: 1))
        XCTAssertNil(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: [.soundQuality], session: 1))
        for (target, payload): (SonyConnectionMode, [UInt8]) in [
            (.soundQuality, [0xE8, 0x05, 0x00, 0x00]),
            (.stableConnection, [0xE8, 0x05, 0x01, 0x00]),
            (.lowLatency, [0xE8, 0x05, 0x02, 0x00]),
        ] {
            let original: SonyConnectionMode = target == .lowLatency ? .soundQuality : .lowLatency
            var transition = try XCTUnwrap(SonyConnectionTransition(original: original, target: target, supportedModes: modes, session: 2))
            XCTAssertEqual(transition.requestPayload, payload)
            XCTAssertFalse(transition.commandTransmitted(payload, session: 1))
            XCTAssertFalse(transition.commandTransmitted([0xE6, 0x05], session: 2))
            XCTAssertFalse(transition.readbackTransmitted(session: 2))
            XCTAssertFalse(transition.receiveNotification(target, stream: .none, session: 2))
            XCTAssertEqual(transition.phase, .queued)
            XCTAssertTrue(transition.commandTransmitted(payload, session: 2))
            XCTAssertEqual(transition.phase, .awaitingResponse)
            XCTAssertFalse(transition.commandTransmitted(payload, session: 2))
        }
    }

    func testMatchingAlertPausesTimeoutAndQueuesOnlyItsAllowedReply() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
        transition.commandTransmitted(transition.requestPayload, session: 1)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, 0x11, 0x01, 0x18, 0x01]))
        let unrelated = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x00, 0x74, 0x01]))
        let unknownAction = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, 0x11, 0x00, 0xFF]))
        XCTAssertFalse(transition.receiveAlert(unrelated, session: 1))
        XCTAssertFalse(transition.receiveAlert(unknownAction, session: 1))
        XCTAssertFalse(transition.receiveAlert(alert, session: 0))
        XCTAssertTrue(transition.receiveAlert(alert, session: 1))
        XCTAssertTrue(transition.awaitingUser)
        XCTAssertEqual(transition.alert, alert)
        XCTAssertFalse(transition.timeout())
        XCTAssertFalse(transition.readbackTransmitted(session: 1))
        XCTAssertFalse(transition.receiveNotification(.lowLatency, stream: .leAudio, session: 1))
        XCTAssertNil(transition.respond(to: unrelated, action: .positive))
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .positive))
        XCTAssertEqual(reply, [0x98, 0x06, 0x11, 0x01])
        XCTAssertEqual(transition.phase, .replyQueued(alert, .positive))
        XCTAssertFalse(transition.timeout())
        XCTAssertFalse(transition.commandTransmitted([0x98, 0x06, 0x11, 0x00], session: 1))
        XCTAssertTrue(transition.commandTransmitted(reply, session: 1))
        XCTAssertEqual(transition.phase, .awaitingResponse)
    }

    func testNegativeReplyCancelsOnlyWhenTransmittedAndConfirmationOnlySendsNothing() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .lowLatency, target: .soundQuality, supportedModes: modes, session: 1))
        transition.commandTransmitted(transition.requestPayload, session: 1)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x00, 0x74, 0x01]))
        transition.receiveAlert(alert, session: 1)
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .negative))
        XCTAssertEqual(reply, [0x98, 0x00, 0x74, 0x00])
        XCTAssertFalse(transition.isFinished)
        transition.commandTransmitted(reply, session: 1)
        XCTAssertEqual(transition.phase, .cancelled)
        XCTAssertFalse(transition.preferenceConfirmed)
        XCTAssertFalse(transition.receiveNotification(.soundQuality, stream: .classicAudio, session: 1))

        for actionType: UInt8 in [0x00, 0x02] {
            var confirming = try XCTUnwrap(SonyConnectionTransition(original: .lowLatency, target: .soundQuality, supportedModes: modes, session: 1))
            confirming.commandTransmitted(confirming.requestPayload, session: 1)
            let confirmation = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x00, 0x74, actionType]))
            confirming.receiveAlert(confirmation, session: 1)
            XCTAssertNil(confirming.respond(to: confirmation, action: .negative))
            if actionType == 0x00 {
                XCTAssertNil(confirming.respond(to: confirmation, action: .positive))
                XCTAssertTrue(confirming.acknowledge(confirmation))
                XCTAssertEqual(confirming.phase, .awaitingResponse)
            } else {
                XCTAssertFalse(confirming.acknowledge(confirmation))
                XCTAssertEqual(confirming.respond(to: confirmation, action: .positive), [0x98, 0x00, 0x74, 0x01])
            }
        }
    }

    func testReadbackMustFollowFreshQueryAndClassicPreferenceDoesNotClaimCodec() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .stableConnection, target: .soundQuality, supportedModes: modes, session: 5))
        transition.commandTransmitted(transition.requestPayload, session: 5)
        XCTAssertFalse(transition.receiveReadback(.soundQuality, session: 5))
        transition.readbackTransmitted(session: 5)
        XCTAssertFalse(transition.readbackTransmitted(session: 5))
        XCTAssertFalse(transition.receiveReadback(.soundQuality, session: 4))
        XCTAssertTrue(transition.receiveReadback(.unknown(3), session: 5))
        XCTAssertFalse(transition.receiveReadback(.soundQuality, session: 5))
        XCTAssertEqual(transition.phase, .awaitingResponse)
        transition.readbackTransmitted(session: 5)
        transition.receiveReadback(.stableConnection, session: 5)
        XCTAssertFalse(transition.preferenceConfirmed)
        transition.readbackTransmitted(session: 5)
        transition.receiveReadback(.soundQuality, session: 5)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertTrue(transition.preferenceConfirmed)
        XCTAssertNil(transition.requiredStream)
    }

    func testCrossTransportNeedsNewControlSessionAndFreshPreferenceReadback() throws {
        for (original, target, stream): (SonyConnectionMode, SonyConnectionMode, SonyConnectionStream) in [
            (.soundQuality, .lowLatency, .leAudio),
            (.lowLatency, .stableConnection, .classicAudio),
        ] {
            var transition = try XCTUnwrap(SonyConnectionTransition(original: original, target: target, supportedModes: modes, session: 8))
            transition.commandTransmitted(transition.requestPayload, session: 8)
            transition.readbackTransmitted(session: 8)
            transition.receiveReadback(target, session: 8)
            XCTAssertTrue(transition.preferenceConfirmed)
            XCTAssertEqual(transition.phase, .reconnecting)
            XCTAssertNil(transition.requiredStream)
            let payload: [UInt8] = target == .lowLatency ? [0x99, 0x06, 0x11, 0x00, 0x00] : [0x99, 0x00, 0x75, 0x00]
            let confirmation = try XCTUnwrap(SonyConnectionAlert(payload: payload))
            XCTAssertTrue(transition.receiveAlert(confirmation, session: 8))
            XCTAssertTrue(transition.acknowledge(confirmation))
            XCTAssertEqual(transition.phase, .reconnecting)
            XCTAssertFalse(transition.receiveNotification(target, stream: .unknown(0xFF), session: 8))
            XCTAssertTrue(transition.receiveNotification(target, stream: stream, session: 8))
            XCTAssertEqual(transition.requiredStream, stream)
            XCTAssertFalse(transition.timeout())
            transition.controlLost(session: 8)
            XCTAssertEqual(transition.phase, .recovering)
            XCTAssertFalse(transition.commandTransmitted(transition.requestPayload, session: 8))
            XCTAssertFalse(transition.controlReady(session: 7))
            XCTAssertFalse(transition.controlReady(session: 8))
            XCTAssertTrue(transition.controlReady(session: 9))
            XCTAssertEqual(transition.phase, .verifying)
            XCTAssertTrue(transition.receiveAlert(confirmation, session: 9))
            XCTAssertTrue(transition.acknowledge(confirmation))
            XCTAssertEqual(transition.phase, .verifying)
            var replyPayload = payload
            replyPayload[replyPayload.count - 1] = 0x01
            let lateAlert = try XCTUnwrap(SonyConnectionAlert(payload: replyPayload))
            XCTAssertTrue(transition.receiveAlert(lateAlert, session: 9))
            let reply = try XCTUnwrap(transition.respond(to: lateAlert, action: .positive))
            XCTAssertTrue(transition.commandTransmitted(reply, session: 9))
            XCTAssertEqual(transition.phase, .verifying)
            XCTAssertFalse(transition.receiveReadback(target, session: 9))
            transition.receiveNotification(target, stream: .none, session: 9)
            XCTAssertEqual(transition.phase, .verifying)
            transition.readbackTransmitted(session: 9)
            XCTAssertFalse(transition.receiveReadback(target, session: 8))
            transition.receiveReadback(target, session: 9)
            XCTAssertEqual(transition.phase, .confirmed)
            XCTAssertEqual(transition.requiredStream, stream)
        }
    }

    func testStreamSwitchRequiresReconnectionEvenWithinClassicAndUnrelatedPacketsCannotFinish() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .stableConnection, target: .soundQuality, supportedModes: modes, session: 1))
        transition.commandTransmitted(transition.requestPayload, session: 1)
        XCTAssertFalse(transition.receiveNotification(.stableConnection, stream: .classicAudio, session: 1))
        XCTAssertFalse(transition.receiveNotification(.soundQuality, stream: .unknown(0xFF), session: 1))
        XCTAssertFalse(transition.preferenceConfirmed)
        XCTAssertTrue(transition.receiveNotification(.soundQuality, stream: .leAudio, session: 1))
        XCTAssertEqual(transition.requiredStream, .leAudio)
        transition.receiveNotification(.soundQuality, stream: .classicAudio, session: 1)
        XCTAssertEqual(transition.phase, .reconnecting)
        transition.readbackTransmitted(session: 1)
        transition.receiveReadback(.soundQuality, session: 1)
        XCTAssertEqual(transition.phase, .reconnecting)
        transition.controlReady(session: 2)
        transition.readbackTransmitted(session: 2)
        transition.receiveReadback(.soundQuality, session: 2)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertEqual(transition.requiredStream, .classicAudio)
    }

    func testSourceLossNeverReplaysAndTimeoutDoesNotRunWhileUserOrRecoveryIsPending() throws {
        var queued = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
        queued.controlLost(session: 1)
        XCTAssertEqual(queued.phase, .failed)
        XCTAssertFalse(queued.controlReady(session: 2))
        XCTAssertFalse(queued.commandTransmitted(queued.requestPayload, session: 1))

        var sent = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
        sent.commandTransmitted(sent.requestPayload, session: 1)
        sent.controlLost(session: 1)
        XCTAssertEqual(sent.phase, .recovering)
        XCTAssertFalse(sent.timeout())
        XCTAssertFalse(sent.readbackTransmitted(session: 1))
        sent.controlReady(session: 2)
        XCTAssertTrue(sent.timeout())
        XCTAssertEqual(sent.phase, .failed)
        XCTAssertFalse(sent.readbackTransmitted(session: 2))
        XCTAssertFalse(sent.receiveNotification(.lowLatency, stream: .none, session: 2))

        var exhausted = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
        XCTAssertFalse(exhausted.recoveryFailed())
        exhausted.commandTransmitted(exhausted.requestPayload, session: 1)
        exhausted.controlLost(session: 1)
        XCTAssertTrue(exhausted.recoveryFailed())
        XCTAssertTrue(exhausted.isFinished)
        XCTAssertFalse(exhausted.controlReady(session: 2))
        XCTAssertFalse(exhausted.commandTransmitted(exhausted.requestPayload, session: 2))
        XCTAssertTrue(exhausted.retryRecovery())
        XCTAssertFalse(exhausted.retryRecovery())
        XCTAssertFalse(exhausted.commandTransmitted(exhausted.requestPayload, session: 1))
        XCTAssertTrue(exhausted.controlReady(session: 2))
        exhausted.readbackTransmitted(session: 2)
        exhausted.receiveReadback(.soundQuality, session: 2)
        XCTAssertFalse(exhausted.preferenceConfirmed)
        XCTAssertEqual(exhausted.phase, .verifying)

        for action: SonyConnectionAlertAction in [.negative, .positive] {
            var replying = try XCTUnwrap(SonyConnectionTransition(original: .soundQuality, target: .lowLatency, supportedModes: modes, session: 1))
            replying.commandTransmitted(replying.requestPayload, session: 1)
            let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x06, 0x11, 0x00, 0x01]))
            replying.receiveAlert(alert, session: 1)
            let reply = try XCTUnwrap(replying.respond(to: alert, action: action))
            replying.controlLost(session: 1)
            XCTAssertEqual(replying.phase, .recovering)
            XCTAssertNil(replying.respond(to: alert, action: action))
            XCTAssertFalse(replying.commandTransmitted(reply, session: 1))
            replying.controlReady(session: 2)
            replying.readbackTransmitted(session: 2)
            replying.receiveReadback(.soundQuality, session: 2)
            XCTAssertEqual(replying.phase, .verifying)
            XCTAssertFalse(replying.preferenceConfirmed)
        }
    }

    func testLateSameCategoryAlertAndStreamDirectiveRetainConfirmedPreferenceContext() throws {
        var transition = try XCTUnwrap(SonyConnectionTransition(original: .stableConnection, target: .soundQuality, supportedModes: modes, session: 3))
        transition.commandTransmitted(transition.requestPayload, session: 3)
        transition.readbackTransmitted(session: 3)
        transition.receiveReadback(.soundQuality, session: 3)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertTrue(transition.isFinished)
        let alert = try XCTUnwrap(SonyConnectionAlert(payload: [0x99, 0x00, 0x76, 0x01]))
        XCTAssertFalse(transition.receiveAlert(alert, session: 2))
        XCTAssertTrue(transition.receiveAlert(alert, session: 3))
        XCTAssertTrue(transition.preferenceConfirmed)
        XCTAssertTrue(transition.awaitingUser)
        XCTAssertFalse(transition.timeout())
        let reply = try XCTUnwrap(transition.respond(to: alert, action: .positive))
        transition.commandTransmitted(reply, session: 3)
        transition.readbackTransmitted(session: 3)
        transition.receiveReadback(.soundQuality, session: 3)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertFalse(transition.receiveNotification(.stableConnection, stream: .classicAudio, session: 3))
        XCTAssertFalse(transition.receiveNotification(.soundQuality, stream: .classicAudio, session: 2))
        XCTAssertTrue(transition.receiveNotification(.soundQuality, stream: .classicAudio, session: 3))
        XCTAssertEqual(transition.phase, .reconnecting)
        XCTAssertEqual(transition.requiredStream, .classicAudio)
        XCTAssertTrue(transition.preferenceConfirmed)
        transition.controlReady(session: 4)
        transition.readbackTransmitted(session: 4)
        transition.receiveReadback(.soundQuality, session: 4)
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertFalse(transition.controlLost(session: 4))
        XCTAssertEqual(transition.phase, .confirmed)
        XCTAssertFalse(transition.controlReady(session: 5))
        transition.readbackTransmitted(session: 5)
        transition.receiveReadback(.soundQuality, session: 5)
        XCTAssertEqual(transition.phase, .confirmed)
    }
}
