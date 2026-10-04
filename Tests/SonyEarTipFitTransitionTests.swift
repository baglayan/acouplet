import XCTest
@testable import Acouplet

final class SonyEarTipFitTransitionTests: XCTestCase {
    func testInitialReadsRequireTransmissionAndEveryOwnedReply() {
        var transition = SonyEarTipFitTransition(session: 7)
        var model = SonyEarTipFit(supportedFunctions: [0xF6])
        for payload in initialReplies {
            XCTAssertFalse(deliver(payload, to: &transition, model: &model))
        }
        XCTAssertNil(model.capability)
        XCTAssertEqual(transition.phase, .checking)
        XCTAssertTrue(transition.blocksCommands)
        XCTAssertFalse(transition.canDismiss)
        for (index, payload) in initialReplies.enumerated() {
            let query = [payload[0] - 1, payload[1]]
            transition.transmitted(query, session: 8)
            XCTAssertFalse(deliver(payload, to: &transition, model: &model))
            transition.transmitted(query, session: 7)
            XCTAssertFalse(deliver(payload, to: &transition, model: &model, session: 8))
            XCTAssertTrue(deliver(payload, to: &transition, model: &model))
            XCTAssertFalse(deliver(payload, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, index == 2 ? .ready : .checking)
        }
        XCTAssertFalse(deliver([0xFB, 6, 0, 0, 255, 255, 255, 255], to: &transition, model: &model))
        XCTAssertFalse(deliver([0xF5, 5, 0, 0, 1, 0], to: &transition, model: &model))
        XCTAssertFalse(deliver([], to: &transition, model: &model))
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.waitingForReport)
        XCTAssertFalse(transition.shouldStartAgain)
    }

    func testUnavailableOrExternallyOwnedModeNeverEntersOrCancelsIt() {
        for (status, operation): ([UInt8], [UInt8]) in [
            ([0xF3, 6, 1, 0, 1, 0], initialReplies[2]),
            ([0xF3, 6, 0, 1, 1, 0], initialReplies[2]),
            ([0xF3, 6, 0, 0, 1, 1], initialReplies[2]),
            (initialReplies[1], [0xF7, 6, 1, 0, 1, 0, 1, 255])
        ] {
            var transition = SonyEarTipFitTransition(session: 7)
            var model = SonyEarTipFit(supportedFunctions: [0xF6])
            for payload in [initialReplies[0], status, operation] {
                transition.transmitted([payload[0] - 1, payload[1]], session: 7)
                XCTAssertTrue(deliver(payload, to: &transition, model: &model))
            }
            XCTAssertEqual(transition.phase, .unavailable)
            XCTAssertFalse(transition.start(model: model))
            XCTAssertFalse(transition.blocksCommands)
            XCTAssertTrue(transition.canDismiss)
            XCTAssertNil(transition.expectedPayload)
            transition.cancel()
            XCTAssertEqual(transition.phase, .finished)
            XCTAssertNil(transition.expectedPayload)
        }
    }

    func testSelectionRequiresOwnedReplyAndIsFrozenForStartAndCancel() {
        for value: UInt8 in [2, 255] {
            var transition = SonyEarTipFitTransition(session: 7, supportsEarpieceSelection: true)
            var model = SonyEarTipFit(supportedFunctions: [0xF6, 0xF7])
            for payload in initialReplies {
                transition.transmitted([payload[0] - 1, payload[1]], session: 7)
                XCTAssertTrue(deliver(payload, to: &transition, model: &model))
            }
            XCTAssertEqual(transition.phase, .checking)
            XCTAssertFalse(transition.start(model: model))
            XCTAssertFalse(deliver([0xF9, 7, value], to: &transition, model: &model))
            XCTAssertFalse(deliver([0xF7, 7, value], to: &transition, model: &model))
            transition.transmitted([0xF6, 7], session: 7)
            XCTAssertFalse(deliver([0xF7, 7, 254], to: &transition, model: &model))
            XCTAssertFalse(deliver([0xF7, 7, value], to: &transition, model: &model, session: 8))
            XCTAssertTrue(deliver([0xF7, 7, 1], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .ready)
            XCTAssertFalse(deliver([0xF7, 7, value], to: &transition, model: &model))
            XCTAssertTrue(deliver([0xF9, 7, value], to: &transition, model: &model))
            XCTAssertTrue(transition.start(model: model))
            XCTAssertEqual(transition.series.rawValue, value)
            XCTAssertFalse(deliver([0xF9, 7, 0], to: &transition, model: &model))
            transition.transmitted(SonyEarTipFit.enterModePayload, session: 7)
            XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
            XCTAssertEqual(transition.expectedPayload, [0xF8, 6, 0, 0, value, 255])
            transition.cancel()
            XCTAssertEqual(transition.expectedPayload, [0xF8, 6, 1, 0, value, 255])
        }
    }

    func testMissingSelectionCannotUseFallbackAndCancellationDrainsItsRead() {
        for cancel in [false, true] {
            var transition = SonyEarTipFitTransition(session: 7, supportsEarpieceSelection: true)
            var model = SonyEarTipFit(supportedFunctions: [0xF6, 0xF7])
            for payload in initialReplies {
                transition.transmitted([payload[0] - 1, payload[1]], session: 7)
                XCTAssertTrue(deliver(payload, to: &transition, model: &model))
            }
            if cancel { transition.cancel() }
            transition.transmitted([0xF6, 7], session: 7)
            XCTAssertEqual(transition.phase, .checking)
            XCTAssertFalse(transition.start(model: model))
            XCTAssertNil(transition.expectedPayload)
            if cancel {
                XCTAssertTrue(deliver([0xF7, 7, 1], to: &transition, model: &model))
                XCTAssertEqual(transition.phase, .finished)
                XCTAssertTrue(transition.shouldDismiss)
            } else {
                transition.timeout()
                XCTAssertEqual(transition.phase, .interrupted)
                XCTAssertNil(transition.expectedPayload)
            }
        }
    }

    func testDiscoveryUsesNotificationsAfterOwnedReadsWhileOtherRepliesArePending() {
        for changedPayload: [UInt8] in [[0xF9, 7, 3], [0xF5, 6, 0, 1, 1, 0], [0xF9, 6, 1, 0, 1, 0, 1, 255]] {
            var transition = SonyEarTipFitTransition(session: 7, supportsEarpieceSelection: true)
            var model = SonyEarTipFit(supportedFunctions: [0xF6, 0xF7])
            for query in transition.initialQueries { transition.transmitted(query, session: 7) }
            XCTAssertFalse(deliver(changedPayload, to: &transition, model: &model))
            for payload in Array(initialReplies.dropFirst()) + [[0xF7, 7, 2]] {
                XCTAssertTrue(deliver(payload, to: &transition, model: &model))
            }
            XCTAssertTrue(deliver(changedPayload, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .checking)
            XCTAssertTrue(deliver(initialReplies[0], to: &transition, model: &model))
            if changedPayload[1] == 7 {
                XCTAssertEqual(transition.phase, .ready)
                XCTAssertTrue(transition.start(model: model))
                XCTAssertEqual(transition.series, .softFitting)
            } else {
                XCTAssertEqual(transition.phase, .unavailable)
                XCTAssertFalse(transition.start(model: model))
            }
        }
    }

    func testModeAndStartedReportsCannotAdvanceBeforeTheirWriteCompletes() {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        XCTAssertEqual(transition.expectedPayload, [0xF4, 6, 1, 1])
        XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .entering)
        transition.transmitted(SonyEarTipFit.enterModePayload, session: 8)
        XCTAssertFalse(transition.commandTransmitted)
        transition.transmitted(SonyEarTipFit.enterModePayload, session: 7)
        XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .starting)
        XCTAssertEqual(transition.expectedPayload, [0xF8, 6, 0, 0, 1, 255])
        XCTAssertTrue(deliver(started, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .starting)
        XCTAssertTrue(deliver(result, to: &transition, model: &model))
        XCTAssertNil(transition.result)
        transition.transmitted(SonyEarTipFit.startPayload(series: .polyurethane), session: 7)
        XCTAssertEqual(transition.phase, .starting)
        XCTAssertTrue(deliver(started, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .measuring)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertTrue(transition.blocksCommands)
    }

    func testOnlyFreshFDInOwnedMeasurementProvidesPerEarResults() {
        var (transition, model) = measuring()
        XCTAssertFalse(deliver([0xFB] + result.dropFirst(), to: &transition, model: &model))
        XCTAssertFalse(deliver(result, to: &transition, model: &model, session: 8))
        XCTAssertTrue(deliver([0xF9, 6, 2, 0, 1, 0, 1, 255], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .measuring)
        XCTAssertNil(transition.result)
        XCTAssertTrue(deliver(result, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .result)
        XCTAssertEqual(transition.result?.left, .good)
        XCTAssertEqual(transition.result?.right, .poor)
        XCTAssertTrue(transition.blocksCommands)
        let accepted = transition.result
        XCTAssertTrue(deliver([0xFD, 6, 1, 0, 255, 255, 255, 255], to: &transition, model: &model))
        XCTAssertEqual(transition.result, accepted)
        XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .finished)
        XCTAssertEqual(transition.result, accepted)
        XCTAssertFalse(transition.shouldDismiss)
    }

    func testOperationIdentityAndModeCountMustMatchTheOwnedAttempt() {
        for (index, value): (Int, UInt8) in [(4, 2), (5, 1), (6, 2), (7, 2)] {
            var (transition, model) = ready()
            XCTAssertTrue(transition.start(model: model))
            transition.transmitted(SonyEarTipFit.enterModePayload, session: 7)
            XCTAssertTrue(deliver([0xF5, 6, 0, 1, 2, 0], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .entering)
            XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
            transition.transmitted(SonyEarTipFit.startPayload(series: .polyurethane), session: 7)
            var other = started
            other[index] = value
            XCTAssertTrue(deliver(other, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .starting)
            XCTAssertTrue(deliver(started, to: &transition, model: &model))
            transition.cancel()
            transition.transmitted(SonyEarTipFit.cancelPayload(series: .polyurethane), session: 7)
            other[2] = 0
            XCTAssertTrue(deliver(other, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .cancelling)
            XCTAssertTrue(deliver([0xF5, 6, 0, 0, 2, 0], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .cancelling)
        }
    }

    func testCancelWaitsForNotStartedThenOwnedModeOutAndRejectsLateResults() {
        var (transition, model) = measuring()
        transition.cancel()
        XCTAssertEqual(transition.phase, .cancelling)
        XCTAssertEqual(transition.expectedPayload, [0xF8, 6, 1, 0, 1, 255])
        XCTAssertTrue(deliver(notStarted, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelling)
        transition.transmitted(SonyEarTipFit.cancelPayload(series: .polyurethane), session: 7)
        XCTAssertEqual(transition.phase, .cancelling)
        XCTAssertTrue(deliver(result, to: &transition, model: &model))
        XCTAssertNil(transition.result)
        XCTAssertTrue(deliver(notStarted, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .leaving)
        XCTAssertEqual(transition.expectedPayload, SonyEarTipFit.exitModePayload)
        XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .leaving)
        transition.transmitted(SonyEarTipFit.exitModePayload, session: 7)
        XCTAssertTrue(deliver([0xF5, 6, 0, 0, 2, 0], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .leaving)
        XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .finished)
        XCTAssertFalse(transition.blocksCommands)
        XCTAssertTrue(transition.canDismiss)
        XCTAssertTrue(transition.shouldDismiss)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(deliver(result, to: &transition, model: &model))
        XCTAssertNil(transition.result)
    }

    func testCancelDuringDiscoveryDrainsOwnedReadsWithoutEnteringMode() {
        var transition = SonyEarTipFitTransition(session: 7)
        var model = SonyEarTipFit(supportedFunctions: [0xF6])
        transition.cancel()
        XCTAssertEqual(transition.phase, .checking)
        for payload in initialReplies {
            transition.transmitted([payload[0] - 1, payload[1]], session: 7)
            XCTAssertTrue(deliver(payload, to: &transition, model: &model))
        }
        XCTAssertEqual(transition.phase, .finished)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.start(model: model))
    }

    func testMeasurementFailureHasNoInventedSealAndStillRequiresModeCleanup() {
        for error: UInt8 in 0...7 {
            var (transition, model) = measuring()
            XCTAssertTrue(deliver([0xF9, 6, 3, error, 1, 0, 1, 255], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .result)
            XCTAssertNil(transition.result)
            XCTAssertNotNil(transition.message)
            XCTAssertTrue(transition.blocksCommands)
            XCTAssertTrue(deliver(result, to: &transition, model: &model))
            XCTAssertNil(transition.result)
            transition.cancel()
            XCTAssertEqual(transition.phase, .leaving)
            XCTAssertEqual(transition.expectedPayload, SonyEarTipFit.exitModePayload)
            transition.transmitted(SonyEarTipFit.exitModePayload, session: 7)
            XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .finished)
        }
    }

    func testTimeoutEscalatesCleanupAndKeepsInterruptedOutcomeBlocked() {
        var checking = SonyEarTipFitTransition(session: 7)
        checking.timeout()
        XCTAssertEqual(checking.phase, .interrupted)
        XCTAssertTrue(checking.blocksCommands)
        XCTAssertTrue(checking.canDismiss)
        var (entering, model) = ready()
        XCTAssertTrue(entering.start(model: model))
        entering.transmitted(SonyEarTipFit.enterModePayload, session: 7)
        entering.timeout()
        XCTAssertEqual(entering.phase, .leaving)
        XCTAssertEqual(entering.expectedPayload, SonyEarTipFit.exitModePayload)
        var (transition, _) = measuring()
        transition.timeout()
        XCTAssertEqual(transition.phase, .cancelling)
        XCTAssertEqual(transition.expectedPayload, SonyEarTipFit.cancelPayload(series: .polyurethane))
        transition.timeout()
        XCTAssertEqual(transition.phase, .leaving)
        XCTAssertEqual(transition.expectedPayload, SonyEarTipFit.exitModePayload)
        transition.timeout()
        XCTAssertEqual(transition.phase, .interrupted)
        XCTAssertTrue(transition.blocksCommands)
        XCTAssertTrue(transition.canDismiss)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.start(model: model))
        XCTAssertFalse(deliver(result, to: &transition, model: &model))
        transition.cancel()
        transition.prepareAgain()
        XCTAssertEqual(transition.phase, .interrupted)
    }

    func testConnectionLossCannotReplayOrAcceptAnotherSessionsResult() {
        var (transition, model) = measuring()
        transition.controlLost()
        let interrupted = transition
        XCTAssertEqual(transition.phase, .interrupted)
        XCTAssertTrue(transition.blocksCommands)
        XCTAssertNil(transition.expectedPayload)
        transition.transmitted(SonyEarTipFit.startPayload(series: .polyurethane), session: 8)
        XCTAssertFalse(deliver(started, to: &transition, model: &model, session: 8))
        XCTAssertFalse(deliver(result, to: &transition, model: &model))
        XCTAssertFalse(deliver(result, to: &transition, model: &model, session: 8))
        XCTAssertFalse(transition.start(model: model))
        XCTAssertEqual(transition, interrupted)
    }

    func testAgainArmsRestartOnlyAfterModeExitAndFreshOwnedReadiness() {
        var (transition, model) = measuring()
        XCTAssertTrue(deliver(result, to: &transition, model: &model))
        XCTAssertEqual(model.operation?.state, .started)
        transition.prepareAgain()
        XCTAssertEqual(transition.phase, .leaving)
        XCTAssertEqual(transition.expectedPayload, SonyEarTipFit.exitModePayload)
        XCTAssertFalse(transition.start(model: model))
        transition.transmitted(SonyEarTipFit.exitModePayload, session: 7)
        XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .checking)
        XCTAssertNil(transition.result)
        XCTAssertNil(transition.expectedPayload)
        for payload in initialReplies {
            XCTAssertFalse(deliver(payload, to: &transition, model: &model))
            transition.transmitted([payload[0] - 1, payload[1]], session: 7)
            XCTAssertTrue(deliver(payload, to: &transition, model: &model))
        }
        XCTAssertEqual(transition.phase, .ready)
        XCTAssertTrue(transition.shouldStartAgain)
        XCTAssertTrue(transition.start(model: model))
        XCTAssertFalse(transition.shouldStartAgain)
        XCTAssertEqual(transition.phase, .entering)
        XCTAssertEqual(transition.expectedPayload, SonyEarTipFit.enterModePayload)
    }

    func testCancellingAReadiedRepeatRemovesAutomaticStartIntent() {
        var (transition, model) = measuring()
        XCTAssertTrue(deliver(result, to: &transition, model: &model))
        transition.prepareAgain()
        transition.transmitted(SonyEarTipFit.exitModePayload, session: 7)
        XCTAssertTrue(deliver(modeOut, to: &transition, model: &model))
        for payload in initialReplies {
            transition.transmitted([payload[0] - 1, payload[1]], session: 7)
            XCTAssertTrue(deliver(payload, to: &transition, model: &model))
        }
        XCTAssertTrue(transition.shouldStartAgain)
        transition.cancel()
        XCTAssertFalse(transition.shouldStartAgain)
        XCTAssertFalse(transition.start(model: model))
        XCTAssertEqual(transition.phase, .finished)
    }

    func testAnotherTestStartingWhileReadyCannotBeTakenOver() {
        var (transition, model) = ready()
        XCTAssertTrue(deliver(started, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .unavailable)
        XCTAssertFalse(transition.start(model: model))
        XCTAssertNil(transition.expectedPayload)
        transition.cancel()
        XCTAssertEqual(transition.phase, .finished)
        XCTAssertNil(transition.expectedPayload)
    }

    private var initialReplies: [[UInt8]] {
        [[0xF1, 6, 10, 1, 1, 4, 0, 1, 2, 3], [0xF3, 6, 0, 0, 1, 0], [0xF7, 6, 0, 0, 1, 0, 1, 255]]
    }

    private var modeIn: [UInt8] { [0xF5, 6, 0, 1, 1, 0] }
    private var modeOut: [UInt8] { [0xF5, 6, 0, 0, 1, 0] }
    private var started: [UInt8] { [0xF9, 6, 1, 0, 1, 0, 1, 255] }
    private var notStarted: [UInt8] { [0xF9, 6, 0, 0, 1, 0, 1, 255] }
    private var result: [UInt8] { [0xFD, 6, 0, 1, 255, 255, 255, 255] }

    private func ready() -> (SonyEarTipFitTransition, SonyEarTipFit) {
        var transition = SonyEarTipFitTransition(session: 7)
        var model = SonyEarTipFit(supportedFunctions: [0xF6])
        for payload in initialReplies {
            transition.transmitted([payload[0] - 1, payload[1]], session: 7)
            XCTAssertTrue(deliver(payload, to: &transition, model: &model))
        }
        XCTAssertEqual(transition.phase, .ready)
        return (transition, model)
    }

    private func measuring() -> (SonyEarTipFitTransition, SonyEarTipFit) {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyEarTipFit.enterModePayload, session: 7)
        XCTAssertTrue(deliver(modeIn, to: &transition, model: &model))
        transition.transmitted(SonyEarTipFit.startPayload(series: .polyurethane), session: 7)
        XCTAssertTrue(deliver(started, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .measuring)
        return (transition, model)
    }

    private func deliver(_ payload: [UInt8], to transition: inout SonyEarTipFitTransition,
                         model: inout SonyEarTipFit, session: UInt64 = 7) -> Bool {
        guard transition.accepts(payload, session: session), model.update(payload) else { return false }
        transition.receive(payload, model: model)
        return true
    }
}
