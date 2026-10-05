import XCTest
@testable import Acouplet

final class SonyHeadGesturePracticeTests: XCTestCase {
    func testWireStateAndRepeatedGestureEventsRemainSeparate() {
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        XCTAssertTrue(model.isSupported)
        XCTAssertNil(model.available)
        XCTAssertNil(model.mode)
        XCTAssertTrue(model.update([0xF3, 0x10, 0]))
        XCTAssertEqual(model.available, true)
        XCTAssertNil(model.mode)
        XCTAssertTrue(model.update([0xF5, 0x10, 0, 0]))
        XCTAssertEqual(model.mode, .in)
        for revision: UInt64 in 1...2 {
            XCTAssertTrue(model.update([0xF9, 0x10, 0]))
            XCTAssertEqual(model.receivedGesture, .nod)
            XCTAssertEqual(model.gestureRevision, revision)
        }
        XCTAssertTrue(model.update([0xF9, 0x10, 1]))
        XCTAssertEqual(model.receivedGesture, .shake)
        XCTAssertEqual(model.gestureRevision, 3)
        XCTAssertEqual(model.count(for: .nod), 2)
        XCTAssertEqual(model.count(for: .shake), 1)
        XCTAssertTrue(model.update([0xF9, 0x10, 1]))
        XCTAssertTrue(model.update([0xF9, 0x10, 1]))
        XCTAssertEqual(model.count(for: .nod), 2)
        XCTAssertEqual(model.count(for: .shake), 3)
        XCTAssertTrue(model.update([0xF3, 0x10, 1]))
        XCTAssertEqual(model.available, false)
        XCTAssertEqual(model.mode, .in)
        XCTAssertTrue(model.update([0xF5, 0x10, 1, 0]))
        XCTAssertEqual(model.mode, .out)
        XCTAssertEqual(model.available, true)
        XCTAssertEqual(model.gestureRevision, 5)
        XCTAssertEqual(SonyHeadGesturePractice.queryPayload, [0xF2, 0x10])
        XCTAssertEqual(SonyHeadGesturePractice.enterPayload, [0xF4, 0x10, 0])
        XCTAssertEqual(SonyHeadGesturePractice.exitPayload, [0xF4, 0x10, 1])
    }

    func testResetGestureEventsPreservesKnownModeAndAvailability() {
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        XCTAssertTrue(model.update([0xF5, 0x10, 0, 1]))
        XCTAssertTrue(model.update(nod))
        XCTAssertEqual(model.gestureRevision, 1)
        model.resetGestureEvents()
        XCTAssertNil(model.receivedGesture)
        XCTAssertEqual(model.gestureRevision, 0)
        XCTAssertEqual(model.count(for: .nod), 0)
        XCTAssertEqual(model.count(for: .shake), 0)
        XCTAssertEqual(model.mode, .in)
        XCTAssertEqual(model.available, false)
        XCTAssertTrue(model.isSupported)
    }

    func testMalformedUnsupportedAndWrongDialectPacketsDoNotChangeState() {
        var unsupported = SonyHeadGesturePractice(supportedFunctions: [0xF6, 0xF7])
        XCTAssertFalse(unsupported.update([0xF3, 0x10, 0]))
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        XCTAssertTrue(model.update([0xF5, 0x10, 1, 0]))
        let before = model
        for payload: [UInt8] in [
            [], [0xF3], [0xF3, 0x10], [0xF3, 0x10, 0, 0], [0xF3, 0x10, 2],
            [0xF5, 0x10, 0], [0xF5, 0x10, 0, 0, 0], [0xF5, 0x10, 2, 0], [0xF5, 0x10, 0, 2],
            [0xF9, 0x10], [0xF9, 0x10, 0, 0], [0xF9, 0x10, 2], [0xF9, 0x10, 255],
            [0xF3, 0x0F, 0], [0xF7, 0x10, 0], [0xFD, 0x10, 0]
        ] {
            XCTAssertFalse(model.update(payload), "\(payload)")
            XCTAssertEqual(model, before)
        }
        XCTAssertFalse(model.update([0xF9, 0x10, 0], frameType: 0x0E))
        XCTAssertEqual(model, before)
    }

    func testDiscoveryRequiresOwnedAvailabilityAndKeepsModeUnknown() {
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        var transition = SonyHeadGesturePracticeTransition(session: 7)
        XCTAssertEqual(transition.initialQueries, [[0xF2, 0x10]])
        XCTAssertFalse(deliver(available, to: &transition, model: &model))
        transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 8)
        XCTAssertFalse(deliver(available, to: &transition, model: &model))
        transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
        XCTAssertFalse(deliver(available, to: &transition, model: &model, session: 8))
        XCTAssertFalse(deliver([0xF3, 0x10, 255], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .checking)
        XCTAssertTrue(transition.waitingForReport)
        XCTAssertTrue(deliver(available, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .ready)
        XCTAssertNil(model.mode)
        XCTAssertFalse(transition.waitingForReport)
        XCTAssertFalse(deliver(available, to: &transition, model: &model))
        XCTAssertTrue(transition.start(model: model))
        XCTAssertEqual(transition.expectedPayload, SonyHeadGesturePractice.enterPayload)
    }

    func testCheckingRetainsKnownForeignModeWithoutAdvancingBeforeOwnedRead() {
        for queryWasTransmitted in [false, true] {
            var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
            var transition = SonyHeadGesturePracticeTransition(session: 7)
            if queryWasTransmitted { transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7) }
            XCTAssertFalse(deliver(modeIn, to: &transition, model: &model, session: 8))
            XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
            XCTAssertEqual(model.mode, .in)
            XCTAssertEqual(transition.phase, .checking)
            XCTAssertFalse(transition.start(model: model))
            XCTAssertNil(transition.expectedPayload)
            if !queryWasTransmitted {
                XCTAssertFalse(deliver(available, to: &transition, model: &model))
                transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
            }
            XCTAssertTrue(deliver(available, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .unavailable)
            XCTAssertEqual(model.mode, .in)
            XCTAssertFalse(transition.start(model: model))
            XCTAssertNil(transition.expectedPayload)
        }
    }

    func testUnavailableAndKnownForeignModeNeverEnterOrFinishPractice() {
        for foreignMode in [false, true] {
            var (transition, model) = ready()
            XCTAssertTrue(deliver(foreignMode ? modeIn : [0xF5, 0x10, 1, 1], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .unavailable)
            XCTAssertFalse(transition.start(model: model))
            XCTAssertNil(transition.expectedPayload)
            XCTAssertTrue(transition.canDismiss)
            XCTAssertFalse(transition.blocksCommands)
            transition.cancel()
            XCTAssertEqual(transition.phase, .finished)
            XCTAssertNil(transition.expectedPayload)
        }
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        XCTAssertTrue(model.update(modeIn))
        var transition = SonyHeadGesturePracticeTransition(session: 7)
        transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
        XCTAssertTrue(deliver(available, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .unavailable)
        XCTAssertNil(transition.expectedPayload)
    }

    func testEntryNeedsReportedModeAfterTransmissionAndEventsOnlyCountDuringPractice() {
        var (transition, model) = ready()
        XCTAssertFalse(deliver(nod, to: &transition, model: &model))
        XCTAssertTrue(transition.start(model: model))
        XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .entering)
        XCTAssertFalse(deliver(nod, to: &transition, model: &model))
        transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 8)
        XCTAssertFalse(transition.commandTransmitted)
        transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7)
        XCTAssertEqual(transition.phase, .entering)
        XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .practicing)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.waitingForReport)
        XCTAssertTrue(deliver(nod, to: &transition, model: &model))
        XCTAssertTrue(deliver(nod, to: &transition, model: &model))
        XCTAssertEqual(model.gestureRevision, 2)
        transition.cancel()
        XCTAssertFalse(deliver(nod, to: &transition, model: &model))
        XCTAssertEqual(model.gestureRevision, 2)
    }

    func testCancelBeforeStartDrainsOwnedDiscoveryWithoutSendingFinish() {
        for queryWasTransmitted in [false, true] {
            var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
            var transition = SonyHeadGesturePracticeTransition(session: 7)
            if queryWasTransmitted { transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7) }
            transition.cancel()
            XCTAssertEqual(transition.phase, .checking)
            XCTAssertTrue(transition.blocksCommands)
            XCTAssertFalse(transition.canDismiss)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .checking)
            if !queryWasTransmitted {
                XCTAssertFalse(deliver(available, to: &transition, model: &model))
                transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
            }
            XCTAssertTrue(deliver(available, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .finished)
            XCTAssertTrue(transition.shouldDismiss)
            XCTAssertFalse(transition.blocksCommands)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(deliver(available, to: &transition, model: &model))
            XCTAssertFalse(deliver(modeIn, to: &transition, model: &model))
        }
        var (transition, model) = ready()
        transition.cancel()
        XCTAssertEqual(transition.phase, .finished)
        XCTAssertTrue(transition.shouldDismiss)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(deliver(available, to: &transition, model: &model))
        var pending = SonyHeadGesturePracticeTransition(session: 7)
        pending.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
        pending.cancel()
        pending.timeout()
        XCTAssertEqual(pending.phase, .interrupted)
        XCTAssertTrue(pending.blocksCommands)
        XCTAssertNil(pending.expectedPayload)
        XCTAssertFalse(deliver(available, to: &pending, model: &model))
    }

    func testOrdinaryAvailabilityLossDrainsPreparationAndCleansUpOwnedPractice() {
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        var checking = SonyHeadGesturePracticeTransition(session: 7)
        checking.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
        checking.unavailable()
        XCTAssertEqual(checking.phase, .checking)
        XCTAssertTrue(checking.blocksCommands)
        XCTAssertNil(checking.expectedPayload)
        XCTAssertTrue(deliver(available, to: &checking, model: &model))
        XCTAssertEqual(checking.phase, .unavailable)
        XCTAssertFalse(checking.start(model: model))
        XCTAssertNil(checking.expectedPayload)
        var (prepared, _) = ready()
        prepared.unavailable()
        XCTAssertEqual(prepared.phase, .unavailable)
        XCTAssertNil(prepared.expectedPayload)
        for didEnter in [false, true] {
            var (transition, model) = self.ready()
            XCTAssertTrue(transition.start(model: model))
            transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7)
            if didEnter { XCTAssertTrue(deliver(modeIn, to: &transition, model: &model)) }
            transition.unavailable()
            XCTAssertEqual(transition.phase, .leaving)
            XCTAssertEqual(transition.expectedPayload, SonyHeadGesturePractice.exitPayload)
            transition.transmitted(SonyHeadGesturePractice.exitPayload, session: 7)
            transition.unavailable()
            XCTAssertTrue(transition.commandTransmitted)
            XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .finished)
            XCTAssertFalse(transition.shouldDismiss)
            XCTAssertNotNil(transition.message)
        }
    }

    func testCancelDuringEntryWaitsForFinishHandoffAndReportedModeOut() {
        for startHandedOff in [false, true] {
            var (transition, model) = ready()
            XCTAssertTrue(transition.start(model: model))
            if startHandedOff { transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7) }
            transition.cancel()
            XCTAssertEqual(transition.phase, .leaving)
            XCTAssertEqual(transition.expectedPayload, SonyHeadGesturePractice.exitPayload)
            transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7)
            XCTAssertFalse(transition.commandTransmitted)
            XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
            XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .leaving)
            transition.transmitted(SonyHeadGesturePractice.exitPayload, session: 7)
            XCTAssertTrue(transition.commandTransmitted)
            transition.cancel()
            XCTAssertTrue(transition.commandTransmitted)
            XCTAssertEqual(transition.phase, .leaving)
            XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .finished)
            XCTAssertTrue(transition.shouldDismiss)
            XCTAssertNil(transition.expectedPayload)
        }
    }

    func testAvailabilityLossCleansUpOwnedModeAndUnsolicitedExitIsVisible() {
        for isOut in [false, true] {
            var (transition, model) = practicing()
            XCTAssertTrue(deliver([0xF5, 0x10, isOut ? 1 : 0, 1], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, isOut ? .finished : .leaving)
            XCTAssertNotNil(transition.message)
            XCTAssertFalse(transition.shouldDismiss)
            if !isOut {
                transition.transmitted(SonyHeadGesturePractice.exitPayload, session: 7)
                XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
                XCTAssertEqual(transition.phase, .finished)
                XCTAssertFalse(transition.shouldDismiss)
            }
            XCTAssertFalse(deliver(nod, to: &transition, model: &model))
        }
    }

    func testTimeoutAttemptsOneFinishThenRetainsUnknownOutcomeWithoutReplay() {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7)
        transition.timeout()
        XCTAssertEqual(transition.phase, .leaving)
        XCTAssertEqual(transition.expectedPayload, SonyHeadGesturePractice.exitPayload)
        transition.transmitted(SonyHeadGesturePractice.exitPayload, session: 7)
        transition.timeout()
        XCTAssertEqual(transition.phase, .interrupted)
        XCTAssertTrue(transition.blocksCommands)
        XCTAssertTrue(transition.canDismiss)
        XCTAssertFalse(transition.shouldDismiss)
        XCTAssertNil(transition.expectedPayload)
        transition.cancel()
        transition.timeout()
        XCTAssertFalse(transition.start(model: model))
        XCTAssertFalse(deliver(modeOut, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .interrupted)
        var checking = SonyHeadGesturePracticeTransition(session: 7)
        checking.timeout()
        XCTAssertEqual(checking.phase, .interrupted)
        XCTAssertNil(checking.expectedPayload)
    }

    func testControlLossRejectsOldSessionEventsAndDoesNotReplayPractice() {
        var (transition, model) = practicing()
        XCTAssertFalse(deliver(nod, to: &transition, model: &model, session: 8))
        XCTAssertTrue(deliver(nod, to: &transition, model: &model))
        transition.controlLost()
        XCTAssertEqual(transition.phase, .interrupted)
        XCTAssertTrue(transition.blocksCommands)
        XCTAssertNil(transition.expectedPayload)
        transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7)
        XCTAssertFalse(deliver(nod, to: &transition, model: &model))
        XCTAssertFalse(deliver(modeIn, to: &transition, model: &model, session: 8))
        XCTAssertEqual(model.gestureRevision, 1)
        XCTAssertFalse(transition.start(model: model))
        var replacement = SonyHeadGesturePracticeTransition(session: 8)
        replacement.transmitted(SonyHeadGesturePractice.queryPayload, session: 8)
        XCTAssertFalse(replacement.accepts(available, session: 7))
        XCTAssertNotEqual(transition.id, replacement.id)
    }

    private func ready() -> (SonyHeadGesturePracticeTransition, SonyHeadGesturePractice) {
        var model = SonyHeadGesturePractice(supportedFunctions: [0xFF])
        var transition = SonyHeadGesturePracticeTransition(session: 7)
        transition.transmitted(SonyHeadGesturePractice.queryPayload, session: 7)
        XCTAssertTrue(deliver(available, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .ready)
        return (transition, model)
    }

    private func practicing() -> (SonyHeadGesturePracticeTransition, SonyHeadGesturePractice) {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyHeadGesturePractice.enterPayload, session: 7)
        XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .practicing)
        return (transition, model)
    }

    private func deliver(_ payload: [UInt8], to transition: inout SonyHeadGesturePracticeTransition,
                         model: inout SonyHeadGesturePractice, session: UInt64 = 7) -> Bool {
        guard transition.accepts(payload, session: session), model.update(payload) else { return false }
        transition.receive(payload, model: model)
        return true
    }

    private var available: [UInt8] { [0xF3, 0x10, 0] }
    private var modeIn: [UInt8] { [0xF5, 0x10, 0, 0] }
    private var modeOut: [UInt8] { [0xF5, 0x10, 1, 0] }
    private var nod: [UInt8] { [0xF9, 0x10, 0] }
}
