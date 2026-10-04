import XCTest
@testable import Acouplet

final class SonyLegacyOptimizerTransitionTests: XCTestCase {
    private let capability: [UInt8] = [0x81, 1, 5, 1, 3, 1, 4]
    private let measurements: [UInt8] = [0x87, 1, 1, 1, 1, 10]

    func testPreparationRequiresFreshSequentialReadsAndRetainsMalformedOwnership() {
        var model = SonyLegacyOptimizer(supportedFunctions: [0x81])
        var transition = SonyLegacyOptimizerTransition(session: 7)
        XCTAssertEqual(transition.pendingQueries, [[0x80, 1]])
        XCTAssertFalse(deliver(capability, to: &transition, model: &model))
        transition.transmitted([0x80, 1], session: 8)
        XCTAssertFalse(transition.waitingForReport)
        transition.transmitted([0x80, 1], session: 7)
        XCTAssertTrue(transition.waitingForReport)
        XCTAssertFalse(deliver(Array(capability.dropLast()), to: &transition, model: &model))
        XCTAssertFalse(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertTrue(deliver(capability, to: &transition, model: &model))
        XCTAssertEqual(transition.pendingQueries, [[0x82, 1]])
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(transition.pendingQueries, [[0x86, 1]])
        transition.transmitted([0x86, 1], session: 7)
        XCTAssertFalse(deliver(measurements, to: &transition, model: &model, session: 8))
        XCTAssertTrue(deliver(measurements, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .ready)
        XCTAssertNil(transition.result)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.hasOutstandingReads)
        XCTAssertTrue(transition.start(model: model))
        XCTAssertFalse(transition.waitingForReport)
        XCTAssertEqual(transition.expectedPayload, SonyLegacyOptimizer.startPayload)
    }

    func testInitialStatusNotificationRequiresFreshReadInsteadOfStaleIdleBaseline() {
        var model = SonyLegacyOptimizer(supportedFunctions: [0x81])
        var transition = SonyLegacyOptimizerTransition(session: 7)
        transition.transmitted([0x80, 1], session: 7)
        XCTAssertTrue(deliver(capability, to: &transition, model: &model))
        XCTAssertFalse(deliver([0x85, 1, 0, 1], to: &transition, model: &model))
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x85, 1, 0, 1], to: &transition, model: &model))

        var cancelled = transition
        var cancelledModel = model
        cancelled.cancel()
        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &cancelled, model: &cancelledModel))
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertTrue(cancelled.shouldDismiss)
        XCTAssertEqual(cancelledModel.status?.phase, .personal)

        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(model.status?.phase, .personal)
        XCTAssertEqual(transition.phase, .checking)
        XCTAssertFalse(transition.start(model: model))
        XCTAssertEqual(transition.pendingQueries, [[0x82, 1]])
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x83, 1, 0, 1], to: &transition, model: &model))
        XCTAssertEqual(transition.pendingQueries, [[0x86, 1]])
        transition.transmitted([0x86, 1], session: 7)
        XCTAssertTrue(deliver(measurements, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .unavailable)
        XCTAssertFalse(transition.start(model: model))
        XCTAssertNil(transition.expectedPayload)
    }

    func testRunNeedsTransmittedStartAndTerminalStateBeforeFreshResult() {
        var (transition, model) = ready(baseline: 0x11)
        XCTAssertTrue(transition.start(model: model))
        XCTAssertTrue(deliver([0x85, 1, 0, 1], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .starting)
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        XCTAssertEqual(transition.phase, .starting)
        XCTAssertTrue(deliver([0x85, 1, 0, 0x11], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .starting)
        XCTAssertTrue(deliver([0x85, 1, 0, 2], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .running)
        XCTAssertFalse(deliver(measurements, to: &transition, model: &model))
        XCTAssertTrue(deliver([0x85, 1, 0, 0x11], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .readingResult)
        XCTAssertNil(transition.result)
        XCTAssertEqual(transition.pendingQueries, [[0x86, 1]])
        XCTAssertFalse(deliver([0x89, 1, 1, 1, 1, 9], to: &transition, model: &model))
        transition.transmitted([0x86, 1], session: 7)
        XCTAssertTrue(deliver([0x89, 1, 1, 1, 1, 9], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .readingResult)
        XCTAssertNil(transition.result)
        XCTAssertTrue(transition.hasOutstandingReads)
        XCTAssertTrue(deliver(measurements, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .completed)
        XCTAssertFalse(transition.hasOutstandingReads)
        XCTAssertEqual(transition.result?.pressureAtmospheres, 1)
    }

    func testFastCompletionRequiresIdleBaselineAndOwnedPostStartRead() {
        for baseline: UInt8 in [0, 0x11] {
            var (transition, model) = ready(baseline: baseline)
            XCTAssertTrue(transition.start(model: model))
            transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
            XCTAssertTrue(deliver([0x85, 1, 0, 0x11], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, .starting)
            XCTAssertFalse(deliver([0x83, 1, 0, 0x11], to: &transition, model: &model))
            transition.transmitted([0x82, 1], session: 7)
            XCTAssertTrue(deliver([0x83, 1, 0, 0x11], to: &transition, model: &model))
            XCTAssertEqual(transition.phase, baseline == 0 ? .readingResult : .starting)
        }
    }

    func testCancelOwnsItsStatusAndDoesNotTreatDeferredStartCompletionAsCancel() {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.cancel()
        XCTAssertEqual(transition.phase, .cancelling)
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        XCTAssertFalse(transition.commandTransmitted)
        XCTAssertTrue(deliver([0x85, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelling)
        transition.transmitted(SonyLegacyOptimizer.cancelPayload, session: 7)
        XCTAssertTrue(deliver([0x85, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelled)
        XCTAssertFalse(transition.blocksCommands)
        XCTAssertTrue(transition.shouldDismiss)

        (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        transition.transmitted([0x82, 1], session: 7)
        transition.cancel()
        transition.transmitted(SonyLegacyOptimizer.cancelPayload, session: 7)
        XCTAssertTrue(transition.pendingQueries.isEmpty)
        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelling)
        XCTAssertEqual(transition.pendingQueries, [[0x82, 1]])
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelled)
    }

    func testFinishedRacingWithCancelRequiresOwnResultAndUnknownStopRemainsUnknown() {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        XCTAssertTrue(deliver([0x85, 1, 0, 0x10], to: &transition, model: &model))
        transition.cancel()
        transition.transmitted(SonyLegacyOptimizer.cancelPayload, session: 7)
        XCTAssertTrue(deliver([0x85, 1, 0, 0x11], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .readingResult)
        XCTAssertFalse(transition.shouldDismiss)
        transition.transmitted([0x86, 1], session: 7)
        XCTAssertTrue(deliver(measurements, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .completed)
        XCTAssertEqual(transition.message, "Optimization finished before cancellation.")

        (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        transition.timeout()
        XCTAssertEqual(transition.phase, .cancelling)
        transition.transmitted(SonyLegacyOptimizer.cancelPayload, session: 7)
        transition.timeout()
        XCTAssertEqual(transition.phase, .interrupted)
        XCTAssertTrue(transition.canDismiss)
        XCTAssertTrue(transition.blocksCommands)
        XCTAssertNil(transition.result)
        transition.controlLost()
        transition.cancel()
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(deliver([0x85, 1, 0, 0], to: &transition, model: &model))
    }

    func testLateStatusReplyCannotReplaceNewerProgressAndFreshReadCanFinish() {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x85, 1, 0, 1], to: &transition, model: &model))
        XCTAssertTrue(transition.isSupersededStatusResponse([0x83, 1, 0, 0]))
        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(model.status?.phase, .personal)
        XCTAssertEqual(transition.phase, .running)
        XCTAssertEqual(transition.pendingQueries, [[0x82, 1]])
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x83, 1, 0, 0x11], to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .readingResult)
    }

    func testCompletionRetainsEarlierStatusReadUntilItDrainsOrTimesOut() {
        var (transition, model) = ready()
        XCTAssertTrue(transition.start(model: model))
        transition.transmitted(SonyLegacyOptimizer.startPayload, session: 7)
        transition.transmitted([0x82, 1], session: 7)
        XCTAssertTrue(deliver([0x85, 1, 0, 1], to: &transition, model: &model))
        XCTAssertTrue(deliver([0x85, 1, 0, 0x11], to: &transition, model: &model))
        transition.transmitted([0x86, 1], session: 7)
        XCTAssertTrue(deliver(measurements, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .completed)
        XCTAssertFalse(transition.canDismiss)
        XCTAssertTrue(transition.waitingForReport)
        var timedOut = transition
        timedOut.timeout()
        XCTAssertEqual(timedOut.phase, .interrupted)
        XCTAssertTrue(timedOut.canDismiss)
        XCTAssertTrue(timedOut.hasOutstandingReads)
        XCTAssertNotNil(timedOut.result)
        XCTAssertTrue(deliver([0x83, 1, 0, 0], to: &transition, model: &model))
        XCTAssertEqual(model.status?.phase, .completed)
        XCTAssertTrue(transition.canDismiss)
        XCTAssertFalse(transition.hasOutstandingReads)
        XCTAssertTrue(transition.pendingQueries.isEmpty)
    }

    func testForeignRunAndCancelledPreparationNeverStartOrCancelTheHeadphones() {
        var (transition, model) = ready(baseline: 1)
        XCTAssertEqual(transition.phase, .unavailable)
        XCTAssertFalse(transition.start(model: model))
        transition.cancel()
        XCTAssertNil(transition.expectedPayload)
        XCTAssertEqual(transition.phase, .cancelled)
        transition = SonyLegacyOptimizerTransition(session: 7)
        transition.transmitted([0x80, 1], session: 7)
        transition.cancel()
        XCTAssertTrue(transition.pendingQueries.isEmpty)
        XCTAssertTrue(deliver(capability, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelled)
        XCTAssertNil(transition.expectedPayload)
    }

    func testCancelDuringInitialWriteRetainsTheCompletedQueryForDraining() {
        var model = SonyLegacyOptimizer(supportedFunctions: [0x81])
        var transition = SonyLegacyOptimizerTransition(session: 7)
        transition.cancel(hasPendingQuery: true)
        XCTAssertEqual(transition.phase, .checking)
        XCTAssertTrue(transition.pendingQueries.isEmpty)
        XCTAssertFalse(transition.canDismiss)
        transition.transmitted([0x80, 1], session: 7)
        XCTAssertTrue(transition.hasOutstandingReads)
        XCTAssertTrue(transition.waitingForReport)
        XCTAssertTrue(deliver(capability, to: &transition, model: &model))
        XCTAssertEqual(transition.phase, .cancelled)
        XCTAssertFalse(transition.hasOutstandingReads)
        XCTAssertTrue(transition.shouldDismiss)
        XCTAssertTrue(transition.pendingQueries.isEmpty)
    }

    private func ready(baseline: UInt8 = 0) -> (SonyLegacyOptimizerTransition, SonyLegacyOptimizer) {
        var transition = SonyLegacyOptimizerTransition(session: 7)
        var model = SonyLegacyOptimizer(supportedFunctions: [0x81])
        for payload in [capability, [0x83, 1, 0, baseline], measurements] {
            for query in transition.pendingQueries { transition.transmitted(query, session: 7) }
            XCTAssertTrue(deliver(payload, to: &transition, model: &model))
        }
        return (transition, model)
    }

    private func deliver(_ payload: [UInt8], to transition: inout SonyLegacyOptimizerTransition,
                         model: inout SonyLegacyOptimizer, session: UInt64 = 7) -> Bool {
        var updated = model
        guard transition.accepts(payload, session: session), updated.update(payload) else { return false }
        let superseded = transition.isSupersededStatusResponse(payload)
        transition.receive(payload, model: updated)
        if !superseded { model = updated }
        return true
    }
}
