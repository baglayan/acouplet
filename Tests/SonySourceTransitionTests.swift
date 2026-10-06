import XCTest
@testable import Acouplet

final class SonySourceTransitionTests: XCTestCase {
    func testSourceSelectionWaitsForTransmissionMatchingResultAndOwnedFreshReadback() throws {
        var model = readyModel()
        let requestID = UUID()
        var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress.lowercased(), model: model, session: 7, requestID: requestID))
        let selection = [0x3C, 0x01] + Array(secondAddress.utf8)
        let result = [0x3D, 0x01, 0] + Array(secondAddress.utf8)
        XCTAssertEqual(transition.requestID, requestID)
        XCTAssertEqual(transition.targetAddress, secondAddress)
        XCTAssertEqual(transition.expectedPayload, selection)
        XCTAssertFalse(transition.receive(result, model: model, session: 7))
        XCTAssertFalse(transition.commandTransmitted(selection, model: model, session: 6))
        XCTAssertFalse(transition.commandTransmitted([0x36, 2], model: model, session: 7))
        XCTAssertEqual(transition.phase, .queued)
        XCTAssertTrue(transition.validateForTransmission(model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted(selection, model: model, session: 7))
        XCTAssertEqual(transition.phase, .awaitingSelection)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.receive(result, model: model, session: 6))
        XCTAssertFalse(transition.receive([0x3D, 1, 0] + Array(firstAddress.utf8), model: model, session: 7))
        XCTAssertFalse(transition.receive(Array(result.dropLast()), model: model, session: 7))
        XCTAssertFalse(transition.receive(result + [0], model: model, session: 7))
        XCTAssertTrue(model.update(result))
        XCTAssertTrue(transition.receive(result, model: model, session: 7))
        XCTAssertEqual(transition.phase, .queuedReadback)
        XCTAssertEqual(transition.expectedPayload, [0x36, 2])
        XCTAssertFalse(transition.receive(inventory(selected: 2), model: model, session: 7, readbackOwned: true))
        XCTAssertEqual(model.selectedSource?.address, firstAddress)
        XCTAssertTrue(transition.commandTransmitted([0x36, 2], model: model, session: 7))
        XCTAssertEqual(transition.phase, .verifying)
        let reply = inventory(selected: 2)
        XCTAssertTrue(model.update(reply))
        XCTAssertFalse(transition.receive(reply, model: model, session: 7))
        var notification = reply
        notification[0] = 0x39
        XCTAssertFalse(transition.receive(notification, model: model, session: 7, readbackOwned: true))
        XCTAssertTrue(transition.receive(reply, model: model, session: 7, readbackOwned: true))
        XCTAssertEqual(transition.phase, .complete)
        XCTAssertTrue(transition.isFinished)
        XCTAssertNil(transition.expectedPayload)
        XCTAssertFalse(transition.receive(result, model: model, session: 7))
        XCTAssertFalse(transition.timeout())
    }

    func testKeepingReleaseMustSucceedBeforeSelectionIsQueued() throws {
        var model = readyModel(keeping: true)
        var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        XCTAssertEqual(transition.expectedPayload, [0x38, 1, 1])
        XCTAssertTrue(transition.commandTransmitted([0x38, 1, 1], model: model, session: 7))
        XCTAssertEqual(transition.phase, .awaitingKeeping)
        XCTAssertFalse(transition.receive([0x37, 1, 1], model: model, session: 7))
        XCTAssertFalse(transition.receive([0x39, 1, 1], model: model, session: 7))
        XCTAssertTrue(model.update([0x39, 1, 1, 0]))
        XCTAssertTrue(transition.receive([0x39, 1, 1, 0], model: model, session: 7))
        XCTAssertEqual(transition.phase, .queuedSelection)
        XCTAssertEqual(transition.expectedPayload, [0x3C, 1] + Array(secondAddress.utf8))
        XCTAssertFalse(transition.timeout())
        XCTAssertFalse(transition.receive([0x3D, 1, 0] + Array(secondAddress.utf8), model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted([0x3C, 1] + Array(secondAddress.utf8), model: model, session: 7))
        XCTAssertEqual(transition.phase, .awaitingSelection)
    }

    func testKeepingFailuresAreTerminalEvenWhenReportedStateDiffersFromRequest() throws {
        for result: UInt8 in [1, 2, 3, 4, 0xFF] {
            for reported: UInt8 in [0, 1, 0xFF] {
                var model = readyModel(keeping: true)
                var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
                XCTAssertTrue(transition.commandTransmitted([0x38, 1, 1], model: model, session: 7))
                let reply: [UInt8] = [0x39, 1, reported, result]
                XCTAssertTrue(model.update(reply))
                XCTAssertTrue(transition.receive(reply, model: model, session: 7))
                XCTAssertEqual(transition.phase, .failed)
                XCTAssertEqual(transition.failureMessage, SonySourceControlResult(rawValue: result).errorMessage)
                XCTAssertNil(transition.expectedPayload)
                XCTAssertEqual(model.selectedSource?.address, firstAddress)
                XCTAssertFalse(transition.receive([0x39, 1, 1, 0], model: model, session: 7))
            }
        }
        let model = readyModel(keeping: true)
        var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted([0x38, 1, 1], model: model, session: 7))
        XCTAssertTrue(transition.receive([0x39, 1, 0, 0], model: model, session: 7))
        XCTAssertEqual(transition.phase, .failed)
    }

    func testSelectionFailureNeverQueuesReadbackOrChangesConfirmedSelection() throws {
        for result: UInt8 in [1, 2, 3, 4, 0xFE] {
            let model = readyModel()
            var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
            XCTAssertTrue(transition.commandTransmitted(try XCTUnwrap(transition.expectedPayload), model: model, session: 7))
            XCTAssertTrue(transition.receive([0x3D, 1, result] + Array(secondAddress.utf8), model: model, session: 7))
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertEqual(transition.failureMessage, SonySourceControlResult(rawValue: result).errorMessage)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertEqual(model.selectedSource?.address, firstAddress)
        }
    }

    func testQueuedMutationsRevalidateTargetAvailabilityAndKeepingImmediatelyBeforeWrite() throws {
        for change: [UInt8] in [[0x35, 2, 0, 1], [0x37, 2], inventory(secondConnection: 0), [0x37, 1, 0]] {
            var model = readyModel()
            var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
            model.update(change)
            XCTAssertFalse(transition.validateForTransmission(model: model, session: 7))
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertNil(transition.expectedPayload)
        }
        var model = readyModel(keeping: true)
        var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted([0x38, 1, 1], model: model, session: 7))
        XCTAssertTrue(model.update([0x39, 1, 1, 0]))
        XCTAssertTrue(transition.receive([0x39, 1, 1, 0], model: model, session: 7))
        let selection = try XCTUnwrap(transition.expectedPayload)
        XCTAssertTrue(model.update(inventory(secondConnection: 0)))
        XCTAssertFalse(transition.commandTransmitted(selection, model: model, session: 7))
        XCTAssertEqual(transition.phase, .failed)
    }

    func testExplicitKeepingOnlyCompletesFromMatchingResultAndRetainsOriginalTarget() throws {
        for desired in [false, true] {
            var model = readyModel(keeping: !desired)
            var transition = try XCTUnwrap(SonySourceTransition(keeping: desired, model: model, session: 7))
            let value: UInt8 = desired ? 0 : 1
            XCTAssertEqual(transition.requestedKeeping, desired)
            XCTAssertEqual(transition.targetAddress, desired ? firstAddress : nil)
            XCTAssertTrue(transition.commandTransmitted([0x38, 1, value], model: model, session: 7))
            XCTAssertFalse(transition.receive([0x37, 1, value], model: model, session: 7))
            XCTAssertTrue(model.update([0x39, 1, value, 0]))
            XCTAssertTrue(transition.receive([0x39, 1, value, 0], model: model, session: 7))
            XCTAssertEqual(transition.phase, .complete)
            XCTAssertNil(transition.expectedPayload)
        }
        var model = readyModel()
        var queued = try XCTUnwrap(SonySourceTransition(keeping: true, model: model, session: 7))
        var awaiting = queued
        XCTAssertTrue(awaiting.commandTransmitted([0x38, 1, 0], model: model, session: 7))
        XCTAssertTrue(model.update(inventory(selected: 2)))
        XCTAssertFalse(queued.validateForTransmission(model: model, session: 7))
        XCTAssertEqual(queued.phase, .failed)
        XCTAssertTrue(model.update([0x39, 1, 0, 0]))
        XCTAssertTrue(awaiting.receive([0x39, 1, 0, 0], model: model, session: 7))
        XCTAssertEqual(awaiting.phase, .failed)
    }

    func testOwnedReadbackRejectsMalformedUnselectedOrDifferentTarget() throws {
        for reply in [[0x37, 2], inventory(selected: 0), inventory(selected: 1), inventory(selected: 2, secondConnection: 0)] {
            let model = readyModel()
            var transition = try awaitingReadback(model: model)
            XCTAssertTrue(transition.receive(reply, model: model, session: 7, readbackOwned: true))
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(transition.receive(inventory(selected: 2), model: model, session: 7, readbackOwned: true))
        }
    }

    func testSessionLossAndResponseTimeoutAreTerminalWithoutReplay() throws {
        let model = readyModel()
        var queued = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        XCTAssertFalse(queued.timeout())
        XCTAssertFalse(queued.controlLost(session: 6))
        XCTAssertTrue(queued.controlLost(session: 7))
        XCTAssertEqual(queued.phase, .failed)
        XCTAssertFalse(queued.validateForTransmission(model: model, session: 8))
        XCTAssertNil(queued.expectedPayload)
        var selecting = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        XCTAssertTrue(selecting.commandTransmitted(try XCTUnwrap(selecting.expectedPayload), model: model, session: 7))
        XCTAssertTrue(selecting.timeout())
        XCTAssertEqual(selecting.phase, .failed)
        XCTAssertFalse(selecting.receive([0x3D, 1, 0] + Array(secondAddress.utf8), model: model, session: 7))
        var verifying = try awaitingReadback(model: model)
        XCTAssertTrue(verifying.timeout())
        XCTAssertFalse(verifying.receive(inventory(selected: 2), model: model, session: 7, readbackOwned: true))
        XCTAssertEqual(model.selectedSource?.address, firstAddress)
    }

    func testUnknownUnsupportedDisconnectedAndNoOpRequestsAreRejected() {
        let model = readyModel()
        XCTAssertNil(SonySourceTransition(targetAddress: firstAddress, model: model, session: 7))
        XCTAssertNil(SonySourceTransition(targetAddress: "00:00:00:00:00:99", model: model, session: 7))
        XCTAssertNil(SonySourceTransition(targetAddress: secondAddress, model: SonyMultipoint(), session: 7))
        XCTAssertNil(SonySourceTransition(keeping: false, model: model, session: 7))
        XCTAssertNil(SonySourceTransition(keeping: true, model: SonyMultipoint(), session: 7))
    }

    func testCapabilityChangeTerminatesQueuedAndTransmittedRequestsInTheirSession() throws {
        let model = readyModel()
        let queued = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        for initial in [queued, try awaitingReadback(model: model)] {
            var transition = initial
            XCTAssertFalse(transition.capabilitiesChanged(session: 6))
            XCTAssertEqual(transition, initial)
            XCTAssertTrue(transition.capabilitiesChanged(session: 7))
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertEqual(transition.failureMessage, "The headphone settings changed before the audio source change was confirmed.")
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(transition.capabilitiesChanged(session: 7))
            XCTAssertFalse(transition.receive(inventory(selected: 2), model: model, session: 7, readbackOwned: true))
        }
    }

    private let firstAddress = "00:11:22:33:44:55"
    private let secondAddress = "AA:BB:CC:DD:EE:FF"

    private func readyModel(keeping: Bool = false) -> SonyMultipoint {
        var model = SonyMultipoint(supportedFunctions: [0x31, 0x32])
        for payload in [[0x31, 2, 8, 2, 0], [0x33, 2, 0, 0], inventory(), [0x37, 1, keeping ? 0 : 1]] {
            XCTAssertTrue(model.update(payload))
        }
        return model
    }

    private func inventory(selected: UInt8 = 1, secondConnection: UInt8 = 2) -> [UInt8] {
        [0x37, 2, 2] + Array(firstAddress.utf8) + [1, 0, 0, 0, 1, 0x41]
            + Array(secondAddress.utf8) + [secondConnection, 0, 0, 0, 1, 0x42, selected]
    }

    private func awaitingReadback(model: SonyMultipoint) throws -> SonySourceTransition {
        var transition = try XCTUnwrap(SonySourceTransition(targetAddress: secondAddress, model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted(try XCTUnwrap(transition.expectedPayload), model: model, session: 7))
        XCTAssertTrue(transition.receive([0x3D, 1, 0] + Array(secondAddress.utf8), model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted([0x36, 2], model: model, session: 7))
        return transition
    }
}
