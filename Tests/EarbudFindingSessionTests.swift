import AppKit
import XCTest
@testable import Acouplet

final class EarbudFindingSessionTests: XCTestCase {
    func testWornStartRequiresAnExplicitOverrideForEachAttempt() throws {
        for target in [FastPairRingTarget.left, .right] {
            var session = EarbudFindingSession(target: target, timeoutSeconds: 30)
            let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
            XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
            XCTAssertEqual(session.begin(), [.connect])
            XCTAssertEqual(session.connectionOpened(worn: true), [])
            XCTAssertEqual(session.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(session.mayBeRinging)
            XCTAssertFalse(session.startedWithWearingOverride)
            XCTAssertFalse(session.commandWillSend(command))
            XCTAssertEqual(session.connectionOpened(worn: false), [])
            XCTAssertEqual(session.confirmWearingOverride(worn: true), [.send(command)])
            XCTAssertTrue(session.startedWithWearingOverride)
            XCTAssertEqual(session.phase, .starting)
            XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
            XCTAssertTrue(session.commandWillSend(command))
            XCTAssertFalse(session.commandWillSend(command))
            XCTAssertEqual(session.wearingChanged(true), [])
            XCTAssertEqual(session.receive(.status(status(target.rawValue, timeout: 30))), [])
            XCTAssertEqual(session.phase, .ringing)
            XCTAssertEqual(session.stop(), [.send(.stop)])
            XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
            XCTAssertTrue(session.startedWithWearingOverride)
            var next = EarbudFindingSession(target: target, timeoutSeconds: 30)
            XCTAssertFalse(next.startedWithWearingOverride)
            XCTAssertEqual(next.begin(), [.connect])
            XCTAssertEqual(next.connectionOpened(worn: true), [])
            XCTAssertEqual(next.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(next.commandWillSend(command))
        }
    }

    func testConfirmationUsesTheCurrentWearingStatus() throws {
        for target in [FastPairRingTarget.left, .right] {
            for worn in [false, nil] as [Bool?] {
                var session = EarbudFindingSession(target: target, timeoutSeconds: 30)
                let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
                _ = session.begin()
                _ = session.connectionOpened(worn: true)
                XCTAssertEqual(session.confirmWearingOverride(worn: worn), worn == false ? [.send(command)] : [.close])
                XCTAssertFalse(session.startedWithWearingOverride)
                if worn == false {
                    XCTAssertTrue(session.commandWillSend(command))
                    XCTAssertEqual(session.wearingChanged(true), [.send(.stop)])
                } else {
                    XCTAssertEqual(session.phase, .finished)
                    XCTAssertFalse(session.commandWillSend(command))
                }
                XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
            }
        }
    }

    func testWearingOverrideRearmsAfterRemovalAndNeverIgnoresUnknownStatus() throws {
        for target in [FastPairRingTarget.left, .right] {
            for ringing in [false, true] {
                for worn in [true, nil] as [Bool?] {
                    var session = EarbudFindingSession(target: target, timeoutSeconds: 30)
                    let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
                    _ = session.begin()
                    _ = session.connectionOpened(worn: true)
                    XCTAssertEqual(session.confirmWearingOverride(worn: true), [.send(command)])
                    XCTAssertTrue(session.commandWillSend(command))
                    if ringing { _ = session.receive(.status(status(target.rawValue, timeout: 30))) }
                    XCTAssertEqual(session.wearingChanged(true), [])
                    if worn == true { XCTAssertEqual(session.wearingChanged(false), []) }
                    XCTAssertTrue(session.startedWithWearingOverride)
                    XCTAssertEqual(session.wearingChanged(worn), [.send(.stop)])
                    XCTAssertEqual(session.phase, .stopping)
                    XCTAssertEqual(session.wearingChanged(worn), [])
                    XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
                    XCTAssertFalse(session.commandWillSend(command))
                }
            }
        }
    }

    func testMissingWearingStatusClosesBeforeStartButNeverBlocksStopRetry() throws {
        for target in [FastPairRingTarget.left, .right] {
            let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
            var unknown = EarbudFindingSession(target: target, timeoutSeconds: 30)
            _ = unknown.begin()
            XCTAssertEqual(unknown.connectionOpened(worn: nil), [.close])
            XCTAssertEqual(unknown.phase, .finished)
            XCTAssertFalse(unknown.startedWithWearingOverride)
            XCTAssertEqual(unknown.confirmWearingOverride(worn: true), [])
            XCTAssertFalse(unknown.commandWillSend(command))
            for worn in [true, nil] as [Bool?] {
                var retry = EarbudFindingSession(target: target, timeoutSeconds: 30)
                _ = retry.begin()
                _ = retry.connectionOpened()
                XCTAssertTrue(retry.commandWillSend(command))
                XCTAssertEqual(retry.transportFailed(), [.close])
                XCTAssertEqual(retry.retryStop(), [.connect])
                XCTAssertEqual(retry.connectionOpened(worn: worn), [.send(.stop)])
                XCTAssertEqual(retry.phase, .stopping)
                XCTAssertFalse(retry.startedWithWearingOverride)
                XCTAssertFalse(retry.commandWillSend(command))
                XCTAssertTrue(retry.commandWillSend(.stop))
            }
        }
    }

    func testCancelledOrFailedConfirmationCannotStartLater() throws {
        for target in [FastPairRingTarget.left, .right] {
            for failed in [false, true] {
                var session = EarbudFindingSession(target: target, timeoutSeconds: 30)
                let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
                _ = session.begin()
                _ = session.connectionOpened(worn: true)
                XCTAssertEqual(failed ? session.transportFailed() : session.stop(), [.close])
                XCTAssertEqual(session.phase, failed ? .failed : .finished)
                XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
                XCTAssertEqual(session.connectionOpened(worn: false), [])
                XCTAssertEqual(session.begin(), [])
                XCTAssertFalse(session.commandWillSend(command))
                XCTAssertFalse(session.startedWithWearingOverride)
                XCTAssertFalse(session.mayBeRinging)
            }
        }
    }

    func testStartIsExplicitOneShotAndRequiresItsSendBoundary() throws {
        for target in [FastPairRingTarget.left, .right] {
            var session = EarbudFindingSession(target: target, timeoutSeconds: 20)
            let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 20))
            XCTAssertEqual(session.phase, .idle)
            XCTAssertFalse(session.mayBeRinging)
            XCTAssertEqual(session.connectionOpened(), [])
            XCTAssertEqual(session.begin(), [.connect])
            XCTAssertEqual(session.begin(), [])
            XCTAssertEqual(session.connectionOpened(), [.send(command)])
            XCTAssertEqual(session.connectionOpened(), [])
            XCTAssertFalse(session.mayBeRinging)
            XCTAssertEqual(session.receive(.acknowledgement(status(target.rawValue, timeout: 20))), [])
            XCTAssertEqual(session.phase, .starting)
            XCTAssertFalse(session.commandWillSend(.stop))
            XCTAssertTrue(session.commandWillSend(command))
            XCTAssertFalse(session.commandWillSend(command))
            XCTAssertTrue(session.mayBeRinging)
            XCTAssertEqual(session.receive(.acknowledgement(status(target.rawValue, timeout: 20))), [])
            XCTAssertEqual(session.phase, .ringing)
        }
    }

    func testCancelBeforeWritePreventsAllDelayedStarts() throws {
        for openFirst in [false, true] {
            var session = EarbudFindingSession(target: .left, timeoutSeconds: 20)
            let command = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 20))
            XCTAssertEqual(session.begin(), [.connect])
            if openFirst { XCTAssertEqual(session.connectionOpened(), [.send(command)]) }
            XCTAssertEqual(session.stop(), [.close])
            XCTAssertEqual(session.phase, .finished)
            XCTAssertFalse(session.mayBeRinging)
            XCTAssertEqual(session.connectionOpened(), [])
            XCTAssertFalse(session.commandWillSend(command))
            XCTAssertEqual(session.begin(), [])
            XCTAssertEqual(session.stop(), [])
        }
    }

    func testCancelWhileStartAcknowledgementIsPendingSendsStopImmediately() throws {
        var session = try startedSession()
        XCTAssertEqual(session.stop(), [.send(.stop)])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertEqual(session.receive(.acknowledgement(nil)), [])
        XCTAssertEqual(session.receive(.acknowledgement(status(2, timeout: 20))), [])
        XCTAssertEqual(session.receive(.status(status(2, timeout: 20))), [])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.stop(), [])
        XCTAssertFalse(session.commandWillSend(.stop))
        XCTAssertEqual(session.receive(.acknowledgement(status(0))), [.close])
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.mayBeRinging)
        XCTAssertEqual(session.receive(.status(status(2, timeout: 20))), [.send(.stop)])
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertEqual(session.begin(), [])
    }

    func testPeerRingBeforeStartOrAfterCompletionRequiresStop() throws {
        for phase in [EarbudFindingSession.Phase.connecting, .awaitingWearingConfirmation, .starting, .finished] {
            var session = EarbudFindingSession(target: .left, timeoutSeconds: 30)
            _ = session.begin()
            if phase != .connecting { _ = session.connectionOpened(worn: phase != .starting) }
            if phase == .finished { _ = session.stop() }
            XCTAssertEqual(session.phase, phase)
            XCTAssertFalse(session.mayBeRinging)
            XCTAssertEqual(session.receive(.status(status(1, timeout: 30))), [.send(.stop)])
            XCTAssertEqual(session.phase, .stopping)
            XCTAssertTrue(session.mayBeRinging)
            XCTAssertFalse(session.commandWillSend(try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30))))
            XCTAssertEqual(session.receive(.acknowledgement(status(0))), [])
            XCTAssertTrue(session.commandWillSend(.stop))
            XCTAssertEqual(session.receive(.acknowledgement(status(0))), [.close])
            XCTAssertFalse(session.mayBeRinging)
        }
    }

    func testWrongSideBothAndUnverifiedTimeoutStopInsteadOfConfirmingRinging() throws {
        for report in [status(1, timeout: 20), status(3, timeout: 20), status(2), status(2, timeout: 0), status(2, timeout: 19), status(2, timeout: 21)] {
            for response in [FastPairRingResponse.status(report), .acknowledgement(report)] {
                var session = try startedSession()
                XCTAssertEqual(session.receive(response), [.send(.stop)])
                XCTAssertEqual(session.phase, .stopping)
                XCTAssertTrue(session.mayBeRinging)
            }
        }
    }

    func testMissingAcknowledgementNeverRetriesStartOrConfirmsSilence() throws {
        var session = try startedSession()
        XCTAssertEqual(session.receive(.acknowledgement(nil)), [])
        XCTAssertEqual(session.acknowledgementExpired(), [.send(.stop)])
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertEqual(session.acknowledgementExpired(), [.close])
        XCTAssertEqual(session.phase, .unconfirmed)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.acknowledgementExpired(), [])
        XCTAssertEqual(session.begin(), [])
        XCTAssertEqual(session.connectionOpened(), [])
        XCTAssertEqual(session.receive(.acknowledgement(status(2, timeout: 20))), [])
    }

    func testRejectionsRequestStopEvenWhenReportingZeroBeforeStartConfirmation() throws {
        for reason in [FastPairRingRejection.unsupported, .busy, .disallowed, .invalidAuthentication, .redundant] {
            for report in [nil, status(0), status(2, timeout: 20)] {
                var session = try startedSession()
                XCTAssertEqual(session.receive(.rejection(reason, report)), [.send(.stop)])
                XCTAssertEqual(session.rejection, reason)
                XCTAssertTrue(session.mayBeRinging)
                XCTAssertTrue(session.commandWillSend(.stop))
                XCTAssertEqual(session.receive(.rejection(reason, status(0))), [.close])
                XCTAssertEqual(session.phase, .finished)
                XCTAssertFalse(session.mayBeRinging)
            }
        }
    }

    func testPeerStoppingNaturallyClearsRiskAfterConfirmedRinging() throws {
        var session = try startedSession()
        XCTAssertEqual(session.receive(.acknowledgement(status(2, timeout: 20))), [])
        XCTAssertEqual(session.receive(.status(status(0))), [.close])
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.mayBeRinging)
        XCTAssertEqual(session.deadlineExpired(), [])
        XCTAssertEqual(session.transportFailed(), [])
    }

    func testZeroStateBeforeStartConfirmationRequiresAnExplicitStop() throws {
        for response in [FastPairRingResponse.status(status(0)), .acknowledgement(status(0))] {
            var session = try startedSession()
            XCTAssertEqual(session.receive(response), [.send(.stop)])
            XCTAssertEqual(session.phase, .stopping)
            XCTAssertTrue(session.mayBeRinging)
            XCTAssertEqual(session.receive(response), [])
            XCTAssertEqual(session.phase, .stopping)
            XCTAssertTrue(session.commandWillSend(.stop))
            XCTAssertEqual(session.receive(response), [.close])
            XCTAssertFalse(session.mayBeRinging)
        }
    }

    func testDeadlineAllowsStopAcknowledgementBeforeClosing() throws {
        var session = try startedSession()
        XCTAssertEqual(session.receive(.acknowledgement(status(2, timeout: 20))), [])
        XCTAssertEqual(session.deadlineExpired(), [.send(.stop)])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertFalse(session.commandWillSend(.stop))
        XCTAssertEqual(session.deadlineExpired(), [])
        XCTAssertEqual(session.acknowledgementExpired(), [.close])
        XCTAssertEqual(session.phase, .unconfirmed)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.begin(), [])
    }

    func testDeadlineDoesNotRepeatPreviouslyRequestedStop() throws {
        var session = try startedSession()
        XCTAssertEqual(session.stop(), [.send(.stop)])
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertEqual(session.deadlineExpired(), [])
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertEqual(session.receive(.status(status(0))), [.close])
        XCTAssertFalse(session.mayBeRinging)
    }

    func testTransportFailureBeforeAndAfterWriteHaveDifferentCertainty() throws {
        var before = EarbudFindingSession(target: .left, timeoutSeconds: 20)
        _ = before.begin()
        XCTAssertEqual(before.transportFailed(), [.close])
        XCTAssertEqual(before.phase, .failed)
        XCTAssertFalse(before.mayBeRinging)
        XCTAssertEqual(before.connectionOpened(), [])
        var after = try startedSession()
        XCTAssertEqual(after.transportFailed(), [.close])
        XCTAssertEqual(after.phase, .unconfirmed)
        XCTAssertTrue(after.mayBeRinging)
        XCTAssertEqual(after.transportFailed(), [])
    }

    func testPreWriteRefusalCannotBeUsedToClearAPreviouslyAttemptedCommand() throws {
        let command = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 20))
        var before = EarbudFindingSession(target: .left, timeoutSeconds: 20)
        _ = before.begin()
        _ = before.connectionOpened()
        XCTAssertEqual(before.commandWasNotSent(command), [.close])
        XCTAssertEqual(before.phase, .failed)
        XCTAssertFalse(before.mayBeRinging)
        XCTAssertFalse(before.commandWillSend(command))
        var after = try startedSession()
        XCTAssertEqual(after.commandWasNotSent(command), [])
        XCTAssertTrue(after.mayBeRinging)
        XCTAssertEqual(after.transportFailed(), [.close])
        XCTAssertEqual(after.phase, .unconfirmed)
    }

    func testRefusedStopPreservesUncertaintyAndSessionIdentityIsDistinct() throws {
        var session = try startedSession()
        XCTAssertNotEqual(session.id, try startedSession().id)
        XCTAssertEqual(session.stop(), [.send(.stop)])
        XCTAssertEqual(session.commandWasNotSent(.stop), [.close])
        XCTAssertEqual(session.phase, .unconfirmed)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertFalse(session.commandWillSend(.stop))
    }

    func testExplicitRetryReconnectsOnlyToStopAndCanConfirmSilence() throws {
        var session = try startedSession()
        let id = session.id
        XCTAssertEqual(session.transportFailed(), [.close])
        XCTAssertEqual(session.stop(), [])
        XCTAssertEqual(session.deadlineExpired(), [])
        XCTAssertEqual(session.retryStop(), [.connect])
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.phase, .connecting)
        XCTAssertTrue(session.isRetryingStop)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.retryStop(), [])
        XCTAssertEqual(session.begin(), [])
        XCTAssertEqual(session.connectionOpened(), [.send(.stop)])
        XCTAssertEqual(session.connectionOpened(), [])
        XCTAssertEqual(session.phase, .stopping)
        let start = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 20))
        XCTAssertFalse(session.commandWillSend(start))
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertEqual(session.receive(.status(status(0))), [.close])
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.mayBeRinging)
        XCTAssertFalse(session.isRetryingStop)
        XCTAssertEqual(session.retryStop(), [])
    }

    func testRetryIgnoresStatusUntilStopIsAttemptedAndNeverRevivesStart() throws {
        var session = try startedSession()
        _ = session.stop()
        XCTAssertTrue(session.commandWillSend(.stop))
        _ = session.acknowledgementExpired()
        _ = session.retryStop()
        for response in [FastPairRingResponse.status(status(0)), .acknowledgement(status(0)), .acknowledgement(status(2, timeout: 20))] {
            XCTAssertEqual(session.receive(response), [])
            XCTAssertEqual(session.phase, .connecting)
            XCTAssertTrue(session.mayBeRinging)
        }
        XCTAssertEqual(session.connectionOpened(), [.send(.stop)])
        XCTAssertEqual(session.receive(.acknowledgement(status(0))), [])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertEqual(session.receive(.acknowledgement(nil)), [])
        XCTAssertEqual(session.receive(.acknowledgement(status(2, timeout: 20))), [])
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertEqual(session.receive(.acknowledgement(status(0))), [.close])
        XCTAssertFalse(session.mayBeRinging)
    }

    func testCancellingRetryConnectionRetainsUncertaintyAndPreventsDelayedWrites() throws {
        for useDeadline in [false, true] {
            var session = try startedSession()
            _ = session.transportFailed()
            _ = session.retryStop()
            XCTAssertEqual(useDeadline ? session.deadlineExpired() : session.stop(), [.close])
            XCTAssertEqual(session.phase, .unconfirmed)
            XCTAssertTrue(session.mayBeRinging)
            XCTAssertFalse(session.isRetryingStop)
            XCTAssertEqual(session.connectionOpened(), [])
            XCTAssertFalse(session.commandWillSend(.stop))
            XCTAssertEqual(session.begin(), [])
        }
    }

    func testRetryConnectionFailureRemainsUnconfirmedWithoutAutomaticRetry() throws {
        var session = try startedSession()
        _ = session.transportFailed()
        _ = session.retryStop()
        XCTAssertEqual(session.transportFailed(), [.close])
        XCTAssertEqual(session.phase, .unconfirmed)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertFalse(session.isRetryingStop)
        XCTAssertEqual(session.stop(), [])
        XCTAssertEqual(session.deadlineExpired(), [])
        XCTAssertEqual(session.acknowledgementExpired(), [])
        XCTAssertEqual(session.connectionOpened(), [])
        XCTAssertEqual(session.retryStop(), [.connect])
        XCTAssertEqual(session.connectionOpened(), [.send(.stop)])
    }

    func testRetryStopIsUnavailableWithoutAnUnconfirmedAudibleAttempt() throws {
        var idle = EarbudFindingSession(target: .left, timeoutSeconds: 20)
        XCTAssertEqual(idle.retryStop(), [])
        _ = idle.begin()
        XCTAssertEqual(idle.retryStop(), [])
        _ = idle.transportFailed()
        XCTAssertEqual(idle.phase, .failed)
        XCTAssertEqual(idle.retryStop(), [])
        var started = try startedSession()
        XCTAssertEqual(started.retryStop(), [])
        _ = started.receive(.acknowledgement(status(2, timeout: 20)))
        XCTAssertEqual(started.retryStop(), [])
        _ = started.stop()
        XCTAssertEqual(started.retryStop(), [])
        XCTAssertTrue(started.commandWillSend(.stop))
        _ = started.receive(.status(status(0)))
        XCTAssertEqual(started.retryStop(), [])
    }

    private func startedSession() throws -> EarbudFindingSession {
        var session = EarbudFindingSession(target: .left, timeoutSeconds: 20)
        _ = session.begin()
        _ = session.connectionOpened()
        let command = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 20))
        XCTAssertTrue(session.commandWillSend(command))
        return session
    }

    private func status(_ components: UInt8, timeout: UInt8? = nil) -> FastPairRingStatus {
        FastPairRingStatus(payload: [components] + (timeout.map { [$0] } ?? []))!
    }
}

@MainActor
final class EarbudFinderEligibilityTests: XCTestCase {
    func testFindingWaitsForPendingMusicAndCallVolumeChanges() {
        for isCall in [false, true] {
            let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
            headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
            defer { headphones.simulateControlLoss() }
            setFirmware("6.1.0", on: headphones)
            let finder = EarbudFinderController(headphones: headphones)
            XCTAssertTrue(finder.canPlay(.left))
            if isCall {
                headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0xA5, 1, 0, 1, 1]))
                headphones.setCallVolume(15)
            } else {
                headphones.setPlaybackVolume(15)
            }
            XCTAssertNotNil(headphones.pendingChanges[isCall ? .callVolume : .playbackVolume])
            XCTAssertFalse(finder.canPlay(.left))
            XCTAssertFalse(finder.canPlay(.right))
            XCTAssertNil(finder.session)
        }
    }

    func testLateFirmwareEnablesAnUntouchedSheetWithoutStartingSound() async {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        defer { headphones.simulateControlLoss() }
        let finder = EarbudFinderController(headphones: headphones)
        XCTAssertFalse(finder.canPlay(.left))
        XCTAssertFalse(headphones.supportsEarbudFinding)
        XCTAssertFalse(headphones.beginEarbudFinder())
        XCTAssertNil(headphones.earbudFinder)
        XCTAssertNil(headphones.firmwareVersion)
        setFirmware("6.1.0", on: headphones)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(finder.canPlay(.left))
        XCTAssertTrue(finder.canPlay(.right))
        XCTAssertTrue(headphones.supportsEarbudFinding)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertNil(finder.session)
        XCTAssertFalse(finder.isBusy)
    }

    func testFindingRequiresVerifiedDeviceReportedModelAndFirmware() {
        for (model, firmware, allowed) in [(SonyDeviceModel.wfXM5, "6.1.0", true),
                                         (.wfXM5, "6.0.0", false), (.wfXM5, "6.1.1", false),
                                         (.wfXM4, "6.1.0", false), (.whXM5, "6.1.0", false)] {
            let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
            headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: model)
            defer { headphones.simulateControlLoss() }
            setFirmware(firmware, on: headphones)
            let finder = EarbudFinderController(headphones: headphones)
            XCTAssertEqual(finder.canPlay(.left), allowed)
            XCTAssertEqual(finder.canPlay(.right), allowed)
            XCTAssertEqual(headphones.supportsEarbudFinding, allowed)
            XCTAssertEqual(headphones.beginEarbudFinder(), allowed)
            XCTAssertEqual(headphones.earbudFinder != nil, allowed)
            XCTAssertNil(finder.session)
        }

        let renamed = SonyHeadphonesController(startAutomatically: false, simulated: true)
        renamed.simulateDeviceConnection(named: "WF-1000XM5")
        defer { renamed.simulateControlLoss() }
        setFirmware("6.1.0", on: renamed)
        let finder = EarbudFinderController(headphones: renamed)
        XCTAssertNil(renamed.deviceInformation.model)
        XCTAssertFalse(finder.canPlay(.left))
        XCTAssertFalse(finder.canPlay(.right))
        XCTAssertFalse(renamed.supportsEarbudFinding)
        XCTAssertFalse(renamed.beginEarbudFinder())
        XCTAssertNil(renamed.earbudFinder)
    }

    func testFindingRequiresConnectedSideAndCurrentUndismissedControlSession() {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        defer { headphones.simulateControlLoss() }
        setFirmware("6.1.0", on: headphones)
        let finder = EarbudFinderController(headphones: headphones)
        XCTAssertTrue(finder.canPlay(.left))
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x15, 1, 0, 1]))
        XCTAssertFalse(finder.canPlay(.left))
        XCTAssertTrue(finder.canPlay(.right))
        finder.dismiss()
        XCTAssertFalse(finder.canPlay(.right))
        XCTAssertNil(finder.session)

        let oldSession = EarbudFinderController(headphones: headphones)
        XCTAssertTrue(oldSession.canPlay(.right))
        setFirmware("6.1.1", on: headphones)
        XCTAssertFalse(oldSession.canPlay(.right))
        headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        setFirmware("6.1.0", on: headphones)
        XCTAssertFalse(oldSession.canPlay(.right))
        XCTAssertTrue(EarbudFinderController(headphones: headphones).canPlay(.right))
    }

    private func setFirmware(_ firmware: String, on headphones: SonyHeadphonesController) {
        let bytes = Array(firmware.utf8)
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x05, 2, UInt8(bytes.count)] + bytes))
    }
}

@MainActor
final class EarbudFinderControllerTests: XCTestCase {
    func testFindingWaitsForAValidCurrentTable2Reply() {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        completeFinderHandshake(on: headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        defer { finish(finder, headphones: headphones) }
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(finder.wearingDetectionIsUnavailable)
        XCTAssertFalse(finder.canPlay(.left))
        XCTAssertFalse(finder.canPlay(.right))
        XCTAssertNotNil(finder.availabilityMessage)
        finder.play(.left)
        XCTAssertNil(finder.session)
        let invalidReplies: [(UInt8, [UInt8])] = [
            (0x0E, [0x07, 0, 1]), (0x0E, [0x07, 0, 0, 0]),
            (0x0E, [0x07, 1, 0]), (0x0C, [0x07, 0, 0]), (0x0D, [0x07, 0, 0]),
        ]
        for (type, payload) in invalidReplies {
            deliver(payload, type: type, to: headphones)
            XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
            XCTAssertFalse(finder.wearingDetectionIsUnavailable)
            XCTAssertFalse(finder.canPlay(.left))
            XCTAssertFalse(finder.canPlay(.right))
            finder.play(.right)
            XCTAssertNil(finder.session)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        }
    }

    func testConfirmedEmptyTable2AllowsFindingWithoutAWearingQuery() throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        completeFinderHandshake(on: headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        defer { finish(finder, headphones: headphones) }
        XCTAssertFalse(finder.canPlay(.left))
        deliver([0x07, 0, 0], to: headphones)
        XCTAssertTrue(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(headphones.wearingStatus.isSupported)
        XCTAssertTrue(finder.wearingDetectionIsUnavailable)
        XCTAssertTrue(finder.canPlay(.left))
        XCTAssertTrue(finder.canPlay(.right))
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        XCTAssertFalse(finder.isCheckingWearing)
        XCTAssertFalse(headphones.hasPendingWearingStatusRead)
        XCTAssertFalse(headphones.simulatedTransmittedFrames.contains {
            $0.type == 0x0E && $0.payload == SonyWearingStatus.queryPayload
        })
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
    }

    func testWearingCapabilityAppearingAfterStartStopsTheSound() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        completeFinderHandshake(on: headphones)
        deliver([0x07, 0, 0], to: headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        XCTAssertEqual(finder.session?.phase, .starting)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        deliver([0x07, 0, 1, 0xF0, 0], to: headphones)
        XCTAssertTrue(headphones.wearingStatus.isSupported)
        XCTAssertNil(headphones.wearingStatus.leftWorn)
        XCTAssertFalse(finder.wearingDetectionIsUnavailable)
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        XCTAssertFalse(headphones.hasPendingWearingStatusRead)
    }

    func testDelayedWearingCapabilityRequiresAFreshReadBeforeFinding() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        completeFinderHandshake(on: headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        defer { finish(finder, headphones: headphones) }
        finder.play(.right)
        XCTAssertNil(finder.session)
        deliver([0x07, 0, 1, 0xF0, 0], to: headphones)
        acknowledgeAll(headphones)
        deliver([0xF5, 0, 4], to: headphones)
        XCTAssertTrue(headphones.hasCurrentTable2Capabilities)
        XCTAssertTrue(headphones.wearingStatus.isSupported)
        XCTAssertEqual(headphones.wearingStatus.rightWorn, false)
        XCTAssertFalse(finder.wearingDetectionIsUnavailable)
        XCTAssertTrue(finder.canPlay(.right))
        XCTAssertFalse(headphones.simulatedTransmittedFrames.contains {
            $0.type == 0x0E && $0.payload == SonyWearingStatus.queryPayload
        })
        finder.play(.right)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        await receiveQueuedUpdates()
        XCTAssertTrue(finder.isCheckingWearing)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        XCTAssertNil(headphones.wearingStatus.rightWorn)
        XCTAssertEqual(finder.session?.phase, .connecting)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertFalse(finder.isCheckingWearing)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right)])
    }

    func testNewControlHandshakeDiscardsThePreviousTable2Receipt() {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        completeFinderHandshake(on: headphones)
        deliver([0x07, 0, 0], to: headphones)
        let oldFinder = EarbudFinderController(headphones: headphones, simulated: true)
        XCTAssertTrue(oldFinder.canPlay(.left))
        let oldSession = headphones.simulatedControlSession
        completeFinderHandshake(on: headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        defer {
            oldFinder.dismiss()
            finish(finder, headphones: headphones)
        }
        XCTAssertFalse(oldFinder.canPlay(.left))
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(finder.wearingDetectionIsUnavailable)
        XCTAssertFalse(finder.canPlay(.left))
        deliver([0x07, 0, 0], session: oldSession, to: headphones)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(finder.canPlay(.left))
        deliver([0x07, 0, 0], to: headphones)
        XCTAssertTrue(headphones.hasCurrentTable2Capabilities)
        XCTAssertTrue(finder.canPlay(.left))
        headphones.simulateControlLoss(deviceConnected: false)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(finder.canPlay(.left))
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testDismissDuringWearReadIgnoresLateReplyAndOpenCallback() async {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        XCTAssertTrue(finder.isCheckingWearing)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        finder.dismiss()
        deliver([0xF3, 0, 4], to: headphones)
        finder.simulateConnectionOpened()
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.isCheckingWearing)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testControlLossAfterFreshWearReplyPreventsDeferredStart() async {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        XCTAssertNotNil(headphones.wearingStatusReadID)
        XCTAssertEqual(finder.session?.phase, .connecting)
        headphones.simulateControlLoss(deviceConnected: false)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testEachSelectedWornEarbudWaitsForConfirmationAndStartsOnlyOnce() async throws {
        for target in [FastPairRingTarget.left, .right] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(target)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, target == .left ? 3 : 2], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.confirmWearingOverride(sessionID: UUID())
            finder.confirmWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            XCTAssertNil(finder.wearingAuthorization)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            finder.authenticateWearingOverride(sessionID: UUID())
            XCTAssertFalse(finder.isAuthenticating)
            finder.authenticateWearingOverride(sessionID: sessionID)
            XCTAssertTrue(finder.isAuthenticating)
            finder.confirmWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: UUID(), succeeded: true)
            XCTAssertTrue(finder.isAuthenticating)
            XCTAssertNil(finder.wearingAuthorization)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            XCTAssertFalse(finder.isAuthenticating)
            XCTAssertEqual(finder.wearingAuthorization?.id, sessionID)
            XCTAssertEqual(finder.wearingAuthorization?.accountName, "Test User")
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            finder.confirmWearingOverride(sessionID: sessionID)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.session?.phase, .starting)
            XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
            XCTAssertTrue(finder.mayBeRinging)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target)])
            XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
            XCTAssertNil(finder.wearingAuthorization)
        }
    }

    func testFailedAuthenticationCanRetryWithoutReplayingItsResult() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: sessionID)
        let failedRequestID = try XCTUnwrap(finder.simulatedAuthenticationRequestID)
        XCTAssertTrue(finder.isAuthenticating)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: false, requestID: failedRequestID)
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertFalse(finder.isAuthenticating)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertNotNil(finder.message)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: failedRequestID)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
        finder.authenticateWearingOverride(sessionID: sessionID)
        let requestID = try XCTUnwrap(finder.simulatedAuthenticationRequestID)
        XCTAssertNotEqual(requestID, failedRequestID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: failedRequestID)
        XCTAssertTrue(finder.isAuthenticating)
        XCTAssertNil(finder.wearingAuthorization)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: requestID)
        XCTAssertEqual(finder.wearingAuthorization?.id, sessionID)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
    }

    func testUncheckingInvalidatesAuthenticationAndRejectsItsResultAfterRechecking() async throws {
        for authenticated in [false, true] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(.right)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            let firstRequestID = try XCTUnwrap(finder.simulatedAuthenticationRequestID)
            if authenticated {
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: firstRequestID)
                XCTAssertNotNil(finder.wearingAuthorization)
            }
            finder.cancelWearingAuthorization()
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(finder.isAuthenticating)
            XCTAssertNil(finder.wearingAuthorization)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: firstRequestID)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertNil(finder.wearingAuthorization)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
            finder.authenticateWearingOverride(sessionID: sessionID)
            let requestID = try XCTUnwrap(finder.simulatedAuthenticationRequestID)
            XCTAssertNotEqual(requestID, firstRequestID)
            for succeeded in [false, true] {
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: succeeded, requestID: firstRequestID)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.isAuthenticating)
                XCTAssertNil(finder.wearingAuthorization)
                XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
            }
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: requestID)
            XCTAssertEqual(finder.wearingAuthorization?.id, sessionID)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right)])
            XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
        }
    }

    func testStartWaitsForSuccessfulAuthorizationSave() async throws {
        for succeeded in [false, true] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.simulatesAuthorizationSaveDelay = true
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            finder.confirmWearingOverride(sessionID: sessionID)
            let requestID = try XCTUnwrap(finder.simulatedAuthorizationSaveRequestID)
            XCTAssertTrue(finder.isSavingAuthorization)
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertFalse(finder.isAuthenticating)
            XCTAssertEqual(finder.simulatedAuthorizationSaveRequestID, requestID)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            finder.simulateAuthorizationSaveCompletion(succeeded: succeeded, requestID: requestID)
            XCTAssertFalse(finder.isSavingAuthorization)
            if succeeded {
                XCTAssertEqual(finder.session?.phase, .starting)
                XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
                XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
                finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: requestID)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
                XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
            } else {
                XCTAssertEqual(finder.session?.phase, .finished)
                XCTAssertFalse(finder.mayBeRinging)
                XCTAssertNotNil(finder.message)
                finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: requestID)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
            }
        }
    }

    func testInterruptedAuthorizationSaveCannotStartLater() async throws {
        for interruption in ["stop", "dismiss", "disconnect", "transportFailure"] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.simulatesAuthorizationSaveDelay = true
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            finder.confirmWearingOverride(sessionID: sessionID)
            let requestID = try XCTUnwrap(finder.simulatedAuthorizationSaveRequestID)
            XCTAssertTrue(finder.isSavingAuthorization)
            switch interruption {
            case "stop": finder.stop()
            case "dismiss": finder.dismiss()
            case "disconnect": headphones.simulateControlLoss(deviceConnected: false)
            default: finder.simulateTransportFailure()
            }
            await receiveQueuedUpdates()
            finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: requestID)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertTrue(finder.session?.isFinished == true, interruption)
            XCTAssertFalse(finder.isSavingAuthorization, interruption)
            XCTAssertNil(finder.wearingAuthorization, interruption)
            XCTAssertFalse(finder.mayBeRinging, interruption)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty, interruption)
        }
    }

    func testUncheckingDuringSaveRequiresANewSaveAfterReauthentication() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.simulatesAuthorizationSaveDelay = true
        finder.play(.right)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        finder.confirmWearingOverride(sessionID: sessionID)
        let firstRequestID = try XCTUnwrap(finder.simulatedAuthorizationSaveRequestID)
        XCTAssertTrue(finder.isSavingAuthorization)
        finder.cancelWearingAuthorization()
        XCTAssertFalse(finder.isSavingAuthorization)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: firstRequestID)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        finder.confirmWearingOverride(sessionID: sessionID)
        let requestID = try XCTUnwrap(finder.simulatedAuthorizationSaveRequestID)
        XCTAssertNotEqual(requestID, firstRequestID)
        for succeeded in [false, true] {
            finder.simulateAuthorizationSaveCompletion(succeeded: succeeded, requestID: firstRequestID)
            XCTAssertTrue(finder.isSavingAuthorization)
            XCTAssertEqual(finder.simulatedAuthorizationSaveRequestID, requestID)
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        }
        finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: requestID)
        XCTAssertFalse(finder.isSavingAuthorization)
        XCTAssertEqual(finder.session?.phase, .starting)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right)])
    }

    func testInterruptedAuthenticationAndFinalConfirmationCannotStartLater() async throws {
        for authenticated in [false, true] {
            for interruption in ["stop", "dismiss", "disconnect", "transportFailure"] {
                let (headphones, finder) = readyFinder()
                defer { finish(finder, headphones: headphones) }
                finder.play(.left)
                finder.simulateConnectionOpened()
                acknowledgeAll(headphones)
                deliver([0xF3, 0, 0], to: headphones)
                await receiveQueuedUpdates()
                let sessionID = try XCTUnwrap(finder.session?.id)
                finder.authenticateWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.isAuthenticating)
                if authenticated {
                    finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
                    XCTAssertNotNil(finder.wearingAuthorization)
                }
                switch interruption {
                case "stop": finder.stop()
                case "dismiss": finder.dismiss()
                case "disconnect": headphones.simulateControlLoss(deviceConnected: false)
                default: finder.simulateTransportFailure()
                }
                await receiveQueuedUpdates()
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.session?.isFinished == true, interruption)
                XCTAssertFalse(finder.isAuthenticating, interruption)
                XCTAssertNil(finder.wearingAuthorization, interruption)
                XCTAssertFalse(finder.mayBeRinging, interruption)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty, interruption)
                XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty, interruption)
            }
        }
    }

    func testExpiredAuthorizationDoesNotStartOrRecordConfirmation() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.right)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertNotNil(finder.wearingAuthorization)
        finder.simulateAuthorizationExpired()
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertFalse(finder.isAuthenticating)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertNotNil(finder.message)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
    }

    func testLosingFocusPreservesAuthenticationButCancelsFinalConfirmation() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: sessionID)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(finder.isAuthenticating)
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertNotNil(finder.wearingAuthorization)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
    }

    func testHidingOrSleepingCancelsPendingAuthentication() async throws {
        for sleeping in [false, true] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            XCTAssertTrue(finder.isAuthenticating)
            if sleeping {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            } else {
                NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
            }
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertFalse(finder.isAuthenticating)
            XCTAssertNil(finder.wearingAuthorization)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
        }
    }

    func testNewAttemptRequiresItsOwnAuthentication() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        let firstSessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: firstSessionID)
        finder.simulateAuthorizationCompletion(sessionID: firstSessionID, succeeded: true)
        XCTAssertNotNil(finder.wearingAuthorization)
        finder.stop()
        XCTAssertEqual(finder.session?.phase, .finished)
        finder.play(.right)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        let sessionID = try XCTUnwrap(finder.session?.id)
        XCTAssertNotEqual(sessionID, firstSessionID)
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        finder.confirmWearingOverride(sessionID: firstSessionID)
        finder.confirmWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: firstSessionID, succeeded: true)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: firstSessionID, succeeded: true)
        XCTAssertTrue(finder.isAuthenticating)
        XCTAssertNil(finder.wearingAuthorization)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertEqual(finder.wearingAuthorization?.id, sessionID)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right)])
        XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
    }

    func testOverrideRearmsWhenRemovalAndReinsertionArriveInOneTurn() async throws {
        for target in [FastPairRingTarget.left, .right] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(target)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target)])
            let removed = SonyFrameCodec.encode(type: 0x0E, sequence: 0, payload: [0xF5, 0, target == .left ? 2 : 3])
            let worn = SonyFrameCodec.encode(type: 0x0E, sequence: 0, payload: [0xF5, 0, 0])
            headphones.simulateProtocolData(removed + worn)
            XCTAssertEqual(finder.session?.phase, .stopping)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target), try stopData()])
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target), try stopData()])
        }
    }

    func testRemovalDuringConfirmationStartsWithoutOverrideAndReinsertionStops() async throws {
        for target in [FastPairRingTarget.left, .right] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(target)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            deliver([0xF5, 0, target == .left ? 2 : 3], to: headphones)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.session?.phase, .starting)
            XCTAssertEqual(finder.session?.startedWithWearingOverride, false)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target)])
            deliver([0xF5, 0, 0], to: headphones)
            XCTAssertEqual(finder.session?.phase, .stopping)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target), try stopData()])
        }
    }

    func testUnknownOrMalformedWearStatusCancelsConfirmationAndRejectsLateConfirmation() async throws {
        for payload: [UInt8] in [[0xF5, 0, 0xFF], [0xF5, 0, 4, 0]] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 0], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            deliver(payload, to: headphones)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
        }
    }

    func testWearTimeoutDoesNotSendAnotherAmbiguousQuery() async {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        XCTAssertTrue(finder.isCheckingWearing)
        finder.simulateWearingTimeout()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        XCTAssertNotNil(finder.message)
        finder.play(.right)
        finder.simulateConnectionOpened()
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        XCTAssertEqual(headphones.simulatedTransmittedFrames.filter {
            $0.type == 0x0E && $0.payload == SonyWearingStatus.queryPayload
        }.count, 1)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testCoalescedStoppedRepliesCannotConfirmANewlySentStop() async throws {
        let acknowledgement = FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0])
        let status = FastPairMessage(group: 4, code: 1, payload: [0])
        let rejection = FastPairMessage(group: 0xFF, code: 2, payload: [2, 4, 1, 0])
        let stoppedAcknowledgement = try XCTUnwrap(acknowledgement.encoded)
        for first in [acknowledgement, status, rejection] {
            for second in [acknowledgement, status, rejection] {
                let (headphones, finder) = readyFinder()
                defer { finish(finder, headphones: headphones) }
                finder.play(.left)
                finder.simulateConnectionOpened()
                acknowledgeAll(headphones)
                deliver([0xF3, 0, 4], to: headphones)
                await receiveQueuedUpdates()
                XCTAssertEqual(finder.session?.phase, .starting)
                let batch = try XCTUnwrap(first.encoded) + XCTUnwrap(second.encoded)
                finder.simulateProtocolData(batch)
                XCTAssertEqual(finder.session?.phase, .stopping)
                XCTAssertTrue(finder.mayBeRinging)
                XCTAssertTrue(finder.isBusy)
                XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) },
                               [try ringData(.left), try stopData()])
                XCTAssertEqual(finder.simulatedSentMessages.filter { $0 == stoppedAcknowledgement }.count,
                               [first, second].filter { $0.group == 4 }.count)
                finder.simulateProtocolData(stoppedAcknowledgement)
                XCTAssertEqual(finder.session?.phase, .finished)
                XCTAssertFalse(finder.mayBeRinging)
                finder.simulateAcknowledgementTimeout()
                finder.simulateConnectionOpened()
                finder.retryStop()
                XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) },
                               [try ringData(.left), try stopData()])
            }
        }
    }

    func testStoppedReplyBufferedBeforeStopCannotConfirmItWhenCompletedLater() async throws {
        let acknowledgement = FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0])
        let status = FastPairMessage(group: 4, code: 1, payload: [0])
        let rejection = FastPairMessage(group: 0xFF, code: 2, payload: [2, 4, 1, 0])
        let stoppedAcknowledgement = try XCTUnwrap(acknowledgement.encoded)
        for explicitStop in [false, true] {
            for staleReply in [acknowledgement, status, rejection] {
                let encoded = try XCTUnwrap(staleReply.encoded)
                for split in 1..<encoded.count {
                    let (headphones, finder) = readyFinder()
                    defer { finish(finder, headphones: headphones) }
                    finder.play(.left)
                    finder.simulateConnectionOpened()
                    acknowledgeAll(headphones)
                    deliver([0xF3, 0, 4], to: headphones)
                    await receiveQueuedUpdates()
                    XCTAssertEqual(finder.session?.phase, .starting)
                    let partial = Data(encoded.prefix(split))
                    if explicitStop {
                        finder.simulateProtocolData(partial)
                        XCTAssertEqual(finder.session?.phase, .starting)
                        finder.stop()
                    } else {
                        finder.simulateProtocolData(stoppedAcknowledgement + partial)
                    }
                    XCTAssertEqual(finder.session?.phase, .stopping)
                    for byte in encoded.dropFirst(split) {
                        finder.simulateProtocolData(Data([byte]))
                        XCTAssertEqual(finder.session?.phase, .stopping)
                        XCTAssertTrue(finder.mayBeRinging)
                    }
                    XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) },
                                   [try ringData(.left), try stopData()])
                    XCTAssertEqual(finder.simulatedSentMessages.filter { $0 == stoppedAcknowledgement }.count,
                                   staleReply.group == 4 ? 1 : 0)
                    finder.simulateProtocolData(stoppedAcknowledgement)
                    XCTAssertEqual(finder.session?.phase, .finished)
                    XCTAssertFalse(finder.mayBeRinging)
                    finder.simulateAcknowledgementTimeout()
                    finder.simulateConnectionOpened()
                    finder.retryStop()
                    XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) },
                                   [try ringData(.left), try stopData()])
                }
            }
        }
    }

    func testRejectedStartStopsAndKeepsTheRefusalAfterSilenceIsConfirmed() async throws {
        let rejection = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 2, payload: [2, 4, 1, 0]).encoded)
        let stopped = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded)
        for stopResponse in [rejection, stopped] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            deliver([0x15, 1, 1, 0], type: 0x0C, to: headphones)
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 4], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
            finder.simulateProtocolData(rejection)
            XCTAssertEqual(finder.session?.phase, .stopping)
            XCTAssertEqual(finder.session?.rejection, .disallowed)
            XCTAssertEqual(finder.message, String(localized: "The earbuds declined the locating-sound request."))
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
            finder.simulateProtocolData(stopResponse)
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertEqual(finder.message, String(localized: "The earbuds declined the locating-sound request."))
            finder.simulateProtocolData(rejection)
            finder.simulateAcknowledgementTimeout()
            finder.simulateConnectionOpened()
            finder.retryStop()
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertEqual(finder.message, String(localized: "The earbuds declined the locating-sound request."))
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        }
    }

    func testRejectedStopDoesNotReportAStartRefusal() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
        XCTAssertEqual(finder.session?.phase, .ringing)
        finder.stop()
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 2, payload: [2, 4, 1]).encoded))
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertNil(finder.message)
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertNil(finder.message)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
    }

    func testStopRetryAfterTransportLossNeverRestartsSound() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.right)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right)])
        finder.simulateTransportFailure()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        finder.retryStop()
        let stopped = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded)
        finder.simulateProtocolData(stopped)
        XCTAssertEqual(finder.session?.phase, .connecting)
        XCTAssertTrue(finder.mayBeRinging)
        finder.simulateConnectionOpened()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right), try stopData()])
        finder.simulateProtocolData(stopped)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        finder.simulateConnectionOpened()
        finder.retryStop()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right), try stopData()])
    }

    func testAcknowledgementTimeoutStopsThenKeepsUnconfirmedSilenceWithoutReplay() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertTrue(finder.canStop)
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
    }

    func testUnconfirmedSoundKeepsDisconnectedMenuIconUntilExplicitStopIsConfirmed() async throws {
        let (headphones, _) = readyFinder()
        XCTAssertTrue(headphones.beginEarbudFinder())
        let finder = try XCTUnwrap(headphones.earbudFinder)
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        finder.simulateTransportFailure()
        headphones.simulateControlLoss(deviceConnected: false)
        finder.dismiss()
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertFalse(finder.isBusy)
        XCTAssertFalse(headphones.isDeviceConnected)
        XCTAssertEqual(headphones.deviceModel, .wfXM5)
        XCTAssertTrue(headphones.showsMenuBarIcon)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        finder.retryStop()
        XCTAssertTrue(headphones.showsMenuBarIcon)
        finder.simulateConnectionOpened()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertFalse(headphones.isDeviceConnected)
        XCTAssertFalse(headphones.showsMenuBarIcon)
        finder.retryStop()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
    }

    func testReopeningReusesTheFinderAndRequiresFreshWearingChecks() async throws {
        let (headphones, _) = readyFinder()
        XCTAssertTrue(headphones.beginEarbudFinder())
        let finder = try XCTUnwrap(headphones.earbudFinder)
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        let firstID = try XCTUnwrap(finder.session?.id)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        finder.dismiss()
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertFalse(finder.needsNewControlSession)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        let stopped = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded)
        finder.simulateProtocolData(stopped)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertEqual(finder.simulatedTransportCloseCount, 0)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        XCTAssertTrue(finder.canPlay(.right))
        finder.play(.right)
        XCTAssertNotEqual(finder.session?.id, firstID)
        finder.simulateConnectionOpened()
        XCTAssertTrue(finder.isCheckingWearing)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 2], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertEqual(finder.simulatedTransportCloseCount, 0)
    }

    func testRetainedStreamIgnoresPartialStatusFromBeforeANewStart() async throws {
        let stale = try XCTUnwrap(FastPairMessage(group: 4, code: 1, payload: [2, 30]).encoded)
        let stopped = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded)
        for split in 1..<stale.count {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 4], to: headphones)
            await receiveQueuedUpdates()
            finder.stop()
            finder.simulateProtocolData(stopped)
            XCTAssertEqual(finder.session?.phase, .finished)
            finder.simulateProtocolData(Data(stale.prefix(split)))
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 4], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .starting)
            finder.simulateProtocolData(Data(stale.dropFirst(split)))
            XCTAssertEqual(finder.session?.phase, .starting)
            XCTAssertTrue(finder.mayBeRinging)
            finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
            XCTAssertEqual(finder.session?.phase, .ringing)
            finder.stop()
            finder.simulateProtocolData(stopped)
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertEqual(finder.simulatedTransportCloseCount, 0)
        }
    }

    func testIdlePeerRingStatusRequestsStopAndExplicitRetirementClosesHealthyTransport() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        finder.stop()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 4, code: 1, payload: [2, 30]).encoded))
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) }, [try stopData()])
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertEqual(finder.simulatedTransportCloseCount, 0)
        finder.requestTransportRetirement()
        XCTAssertEqual(finder.simulatedTransportCloseCount, 1)
        finder.requestTransportRetirement()
        XCTAssertEqual(finder.simulatedTransportCloseCount, 1)
    }

    func testIdlePeerRingPreservesRiskWhenAcknowledgementCannotBeSent() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        finder.stop()
        XCTAssertEqual(finder.session?.phase, .finished)
        finder.simulatesSendFailure = true
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 4, code: 1, payload: [2, 30]).encoded))
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertEqual(finder.simulatedTransportCloseCount, 1)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testPeerRingDuringPreparationCancelsWearCheckAndAuthorization() async throws {
        for confirming in [false, true] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(.left)
            finder.simulateConnectionOpened()
            if confirming {
                acknowledgeAll(headphones)
                deliver([0xF3, 0, 0], to: headphones)
                await receiveQueuedUpdates()
                finder.authenticateWearingOverride(sessionID: try XCTUnwrap(finder.session?.id))
                XCTAssertTrue(finder.isAuthenticating)
            } else {
                XCTAssertTrue(finder.isCheckingWearing)
            }
            finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 4, code: 1, payload: [1, 30]).encoded))
            XCTAssertEqual(finder.session?.phase, .stopping)
            XCTAssertTrue(finder.mayBeRinging)
            XCTAssertFalse(finder.isCheckingWearing)
            XCTAssertFalse(finder.isAuthenticating)
            XCTAssertNil(finder.wearingAuthorization)
            XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) }, [try stopData()])
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 4], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .stopping)
            XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) }, [try stopData()])
        }
    }

    func testReconnectKeepsUnconfirmedSoundUntilStopBeforeCreatingAFreshFinder() async throws {
        let (headphones, _) = readyFinder()
        XCTAssertTrue(headphones.beginEarbudFinder())
        let finder = try XCTUnwrap(headphones.earbudFinder)
        defer { finish(finder, headphones: headphones) }
        finder.play(.right)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        finder.simulateTransportFailure()
        headphones.simulateControlLoss(deviceConnected: false)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertFalse(headphones.supportsEarbudFinding)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        headphones.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        completeFinderHandshake(on: headphones)
        XCTAssertTrue(headphones.supportsEarbudFinding)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        deliver([0x07, 0, 1, 0xF0, 0], to: headphones)
        acknowledgeAll(headphones)
        await receiveQueuedUpdates()
        XCTAssertTrue(headphones.hasCurrentTable2Capabilities)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        finder.retryStop()
        finder.simulateConnectionOpened()
        let stopped = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded)
        finder.simulateProtocolData(stopped)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertTrue(finder.needsNewControlSession)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(headphones.beginEarbudFinder())
        let replacement = try XCTUnwrap(headphones.earbudFinder)
        XCTAssertFalse(replacement === finder)
        XCTAssertFalse(replacement.needsNewControlSession)
        XCTAssertNil(replacement.session)
        XCTAssertTrue(replacement.canPlay(.left))
        XCTAssertTrue(replacement.canPlay(.right))
        finder.simulateConnectionOpened()
        finder.simulateProtocolData(stopped)
        finder.simulateAcknowledgementTimeout()
        finder.retryStop()
        await receiveQueuedUpdates()
        XCTAssertTrue(headphones.earbudFinder === replacement)
        XCTAssertNil(replacement.session)
        XCTAssertTrue(replacement.simulatedSentMessages.isEmpty)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right), try stopData()])
    }

    func testDisconnectBeforeSoundStartsDoesNotRetainMenuIcon() async throws {
        let (headphones, _) = readyFinder()
        XCTAssertTrue(headphones.beginEarbudFinder())
        let finder = try XCTUnwrap(headphones.earbudFinder)
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        XCTAssertEqual(finder.session?.phase, .connecting)
        headphones.simulateControlLoss(deviceConnected: false)
        await receiveQueuedUpdates()
        finder.simulateConnectionOpened()
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertFalse(headphones.showsMenuBarIcon)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testQueuedStartIsCancelledBeforeNativeAdmission() async throws {
        for interruption in ["stop", "dismiss", "timeout", "wearing"] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            let started = expectation(description: "Preceding write started")
            let drained = expectation(description: "Write queue drained")
            let release = DispatchSemaphore(value: 0)
            let channel = RFCOMMChannelIOTests.TestChannel(onFirstWrite: {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            })
            let io = RFCOMMChannelIO(channel: channel)
            io.write(Data([1])) { _ in drained.fulfill() }
            await fulfillment(of: [started], timeout: 2)
            finder.simulatedChannelIO = io
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 4], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(finder.session?.phase, .starting)
            XCTAssertFalse(finder.mayBeRinging)
            switch interruption {
            case "stop": finder.stop()
            case "dismiss": finder.dismiss()
            case "timeout": finder.simulateAcknowledgementTimeout()
            default:
                deliver([0xF5, 0, 0], to: headphones)
                await receiveQueuedUpdates()
            }
            XCTAssertEqual(finder.session?.phase, .finished)
            release.signal()
            await fulfillment(of: [drained], timeout: 2)
            let cancelled = expectation(description: "Cancelled queue drained")
            io.write(Data([2]), willSend: { false }) { status in
                XCTAssertNotEqual(status, 0)
                cancelled.fulfill()
            }
            await fulfillment(of: [cancelled], timeout: 2)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            XCTAssertEqual(finder.simulatedTransportCloseCount, 0)
            XCTAssertEqual(channel.writes, [Data([1])])
        }
    }

    func testPeerRingBeforeQueuedStartAdmissionCancelsStartAndRequestsStop() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        let started = expectation(description: "Preceding write started")
        let release = DispatchSemaphore(value: 0)
        let channel = RFCOMMChannelIOTests.TestChannel(onFirstWrite: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let io = RFCOMMChannelIO(channel: channel)
        io.write(Data([1])) { _ in }
        await fulfillment(of: [started], timeout: 2)
        finder.simulatedChannelIO = io
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .starting)
        XCTAssertFalse(finder.mayBeRinging)
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 4, code: 1, payload: [1, 30]).encoded))
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertTrue(finder.mayBeRinging)
        let stopped = try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded)
        finder.simulateProtocolData(stopped)
        XCTAssertEqual(finder.session?.phase, .stopping)
        release.signal()
        let drained = expectation(description: "Queued start cancellation and stop drained")
        io.write(Data([2]), willSend: { false }) { _ in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertEqual(finder.simulatedSentMessages.filter { $0.prefix(2) == Data([4, 1]) }, [try stopData()])
        XCTAssertFalse(channel.writes.contains(try ringData(.left)))
        XCTAssertEqual(finder.simulatedTransportCloseCount, 0)
        finder.simulateProtocolData(stopped)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
    }

    func testBlockedNativeStartRetiresQueuedStopOnTimeout() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        let started = expectation(description: "Locating write started")
        let release = DispatchSemaphore(value: 0)
        let channel = RFCOMMChannelIOTests.TestChannel(onFirstWrite: {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let io = RFCOMMChannelIO(channel: channel)
        finder.simulatedChannelIO = io
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(finder.mayBeRinging)
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .stopping)
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertTrue(finder.mayBeRinging)
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertFalse(finder.isBusy)
        release.signal()
        let drained = expectation(description: "Retired stop queue drained")
        io.write(Data([2])) { status in
            XCTAssertNotEqual(status, 0)
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        XCTAssertEqual(channel.writes, [try ringData(.left)])
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
    }

    private func completeFinderHandshake(on headphones: SonyHeadphonesController) {
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0,
            payload: [0x01, 0, 3, 0, 0x30, 0x18, 0, 0]), beginConnection: true)
        acknowledgeAll(headphones)
        let name = Array("WF-1000XM5".utf8)
        let firmware = Array("6.1.0".utf8)
        for payload: [UInt8] in [[0x05, 1, UInt8(name.count)] + name, [0x07, 0, 1, 0x11, 0],
                                [0x05, 2, UInt8(firmware.count)] + firmware, [0x13, 1, 1, 1]] {
            deliver(payload, type: 0x0C, to: headphones)
            acknowledgeAll(headphones)
        }
        XCTAssertTrue(headphones.isReady)
        XCTAssertEqual(headphones.deviceInformation.model, .wfXM5)
        XCTAssertEqual(headphones.firmwareVersion, "6.1.0")
        XCTAssertEqual(headphones.audioFeatures.leftConnected, true)
        XCTAssertEqual(headphones.audioFeatures.rightConnected, true)
    }

    private func readyFinder() -> (SonyHeadphonesController, EarbudFinderController) {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        let firmware = Array("6.1.0".utf8)
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0,
                                                             payload: [0x05, 2, UInt8(firmware.count)] + firmware))
        deliver([0x07, 0, 1, 0xF0, 0], to: headphones)
        acknowledgeAll(headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        XCTAssertTrue(headphones.wearingStatus.isSupported)
        XCTAssertTrue(finder.canPlay(.left))
        XCTAssertTrue(finder.canPlay(.right))
        return (headphones, finder)
    }

    private func finish(_ finder: EarbudFinderController, headphones: SonyHeadphonesController) {
        finder.dismiss()
        finder.simulateTransportFailure()
        headphones.simulateControlLoss()
    }

    private func ringData(_ target: FastPairRingTarget) throws -> Data {
        try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30)?.message.encoded)
    }

    private func stopData() throws -> Data {
        try XCTUnwrap(FastPairRingCommand.stop.message.encoded)
    }

    private func receiveQueuedUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func acknowledgeAll(_ headphones: SonyHeadphonesController) {
        for _ in 0..<200 {
            guard let frame = headphones.simulatedPendingFrame else { return }
            headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, session: UInt64? = nil, to headphones: SonyHeadphonesController) {
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: 0, payload: payload), session: session)
    }
}
