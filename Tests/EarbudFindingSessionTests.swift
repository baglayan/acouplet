import AppKit
import Combine
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

    func testConfirmationRequiresFreshConsentForAnUnsafeChangeAndAllowsRemoval() throws {
        for target in [FastPairRingTarget.left, .right] {
            for worn in [false, nil] as [Bool?] {
                var session = EarbudFindingSession(target: target, timeoutSeconds: 30)
                let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
                _ = session.begin()
                _ = session.connectionOpened(worn: true)
                if worn == nil {
                    XCTAssertEqual(session.confirmWearingOverride(worn: worn), [])
                    XCTAssertEqual(session.phase, .awaitingWearingConfirmation)
                    XCTAssertNil(session.wearingConfirmationStatus)
                    XCTAssertFalse(session.commandWillSend(command))
                    XCTAssertFalse(session.mayBeRinging)
                }
                XCTAssertEqual(session.confirmWearingOverride(worn: worn), [.send(command)])
                XCTAssertEqual(session.startedWithWearingOverride, worn != false)
                XCTAssertTrue(session.commandWillSend(command))
                if worn == false {
                    XCTAssertEqual(session.wearingChanged(true), [.send(.stop)])
                } else {
                    XCTAssertEqual(session.wearingChanged(nil), [])
                    XCTAssertEqual(session.wearingChanged(true), [.send(.stop)])
                }
                XCTAssertEqual(session.confirmWearingOverride(worn: true), [])
            }
        }
    }

    func testUnknownConsentCannotStartAWornOverrideWithoutFreshConfirmation() throws {
        for target in [FastPairRingTarget.left, .right] {
            var session = EarbudFindingSession(target: target, timeoutSeconds: 30)
            let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
            _ = session.begin()
            _ = session.connectionOpened(worn: nil)

            XCTAssertEqual(session.confirmWearingOverride(worn: true), [])

            XCTAssertEqual(session.phase, .awaitingWearingConfirmation)
            XCTAssertEqual(session.wearingConfirmationStatus, true)
            XCTAssertFalse(session.startedWithWearingOverride)
            XCTAssertFalse(session.mayBeRinging)
            XCTAssertFalse(session.commandWillSend(command))
            XCTAssertEqual(session.confirmWearingOverride(worn: true), [.send(command)])
            XCTAssertTrue(session.startedWithWearingOverride)
            XCTAssertTrue(session.commandWillSend(command))
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

    func testMissingWearingStatusRequiresOverrideButNeverBlocksStopRetry() throws {
        for target in [FastPairRingTarget.left, .right] {
            let command = try XCTUnwrap(FastPairRingCommand.ring(target, timeoutSeconds: 30))
            var unknown = EarbudFindingSession(target: target, timeoutSeconds: 30)
            _ = unknown.begin()
            XCTAssertEqual(unknown.connectionOpened(worn: nil), [])
            XCTAssertEqual(unknown.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(unknown.startedWithWearingOverride)
            XCTAssertFalse(unknown.commandWillSend(command))
            XCTAssertEqual(unknown.confirmWearingOverride(worn: nil), [.send(command)])
            XCTAssertTrue(unknown.startedWithWearingOverride)
            XCTAssertTrue(unknown.commandWillSend(command))
            XCTAssertEqual(unknown.wearingChanged(nil), [])
            XCTAssertEqual(unknown.wearingChanged(false), [])
            XCTAssertEqual(unknown.wearingChanged(nil), [.send(.stop)])
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

    func testAwaitingConfirmationRetainsUnknownWornAndRemovedReadings() {
        var session = EarbudFindingSession(target: .left, timeoutSeconds: 30)
        _ = session.begin()
        _ = session.connectionOpened(worn: nil)
        XCTAssertNil(session.wearingConfirmationStatus)
        XCTAssertEqual(session.wearingChanged(true), [])
        XCTAssertEqual(session.wearingConfirmationStatus, true)
        XCTAssertEqual(session.wearingChanged(false), [])
        XCTAssertEqual(session.wearingConfirmationStatus, false)
        XCTAssertEqual(session.phase, .awaitingWearingConfirmation)
        XCTAssertFalse(session.mayBeRinging)
    }

    func testUnknownWearingStatusBeforeStartRevokesPendingCommandUntilConfirmed() throws {
        var session = EarbudFindingSession(target: .left, timeoutSeconds: 30)
        let command = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30))
        _ = session.begin()
        XCTAssertEqual(session.connectionOpened(worn: false), [.send(command)])
        XCTAssertEqual(session.wearingChanged(nil), [])
        XCTAssertEqual(session.phase, .awaitingWearingConfirmation)
        XCTAssertFalse(session.commandWillSend(command))
        XCTAssertFalse(session.mayBeRinging)
        XCTAssertEqual(session.wearingChanged(false), [])
        XCTAssertEqual(session.phase, .awaitingWearingConfirmation)
        XCTAssertFalse(session.commandWillSend(command))
        XCTAssertEqual(session.confirmWearingOverride(worn: false), [.send(command)])
        XCTAssertFalse(session.startedWithWearingOverride)
        XCTAssertTrue(session.commandWillSend(command))
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
                XCTAssertEqual(session.phase, .stopping)
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

    func testExplicitRetryReconnectsOnlyToStopAndCanConfirmSilence() throws {
        var session = try startedSession()
        let id = session.id
        XCTAssertEqual(session.transportFailed(), [.close])
        XCTAssertEqual(session.stop(), [])
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

    func testRepeatedStopPreservesTheStopRetryConnection() throws {
        var session = try startedSession()
        _ = session.transportFailed()
        _ = session.retryStop()
        XCTAssertEqual(session.stop(), [])
        XCTAssertEqual(session.phase, .connecting)
        XCTAssertTrue(session.mayBeRinging)
        XCTAssertTrue(session.isRetryingStop)
        XCTAssertEqual(session.begin(), [])
        XCTAssertEqual(session.connectionOpened(), [.send(.stop)])
        XCTAssertTrue(session.commandWillSend(.stop))
        XCTAssertEqual(session.receive(.acknowledgement(status(0))), [.close])
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.mayBeRinging)
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
                headphones.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
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
        headphones.simulateProtocolMessage([0x15, 1, 0, 1])
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
        headphones.simulateProtocolMessage([0x05, 2, UInt8(bytes.count)] + bytes)
    }
}

@MainActor
final class EarbudFinderControllerTests: XCTestCase {
    func testExhaustedTable2DiscoveryPublishesUnavailableWithoutRestartingOnRefreshOrReopen() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finder = try finderAwaitingTable2(on: headphones)
        defer { finish(finder, headphones: headphones) }
        XCTAssertEqual(finder.availabilityMessage, String(localized: "Checking the earbuds…"))
        XCTAssertFalse(headphones.hasFailedTable2Discovery)
        XCTAssertFalse(headphones.canRetryDeviceDiscovery)
        headphones.simulateDiscoveryReadTimeout([0x06, 0], type: 0x0E)
        for _ in 0..<8 { await Task.yield() }
        acknowledgeAll(headphones)
        XCTAssertEqual(finder.availabilityMessage, String(localized: "Checking the earbuds…"))
        XCTAssertFalse(headphones.hasFailedTable2Discovery)
        let unavailable = expectation(description: "Finder publishes exhausted discovery")
        var observedFailure = false
        let observation = finder.objectWillChange.sink {
            if headphones.hasFailedTable2Discovery, !observedFailure {
                observedFailure = true
                unavailable.fulfill()
            }
        }
        defer { observation.cancel() }
        headphones.simulateDiscoveryReadTimeout([0x06, 0], type: 0x0E)
        await fulfillment(of: [unavailable], timeout: 1)
        XCTAssertEqual(finder.availabilityMessage, String(localized: "Couldn’t finish checking the earbuds."))
        XCTAssertTrue(headphones.canRetryDeviceDiscovery)
        XCTAssertFalse(finder.canPlay(.left))
        XCTAssertFalse(finder.canPlay(.right))
        finder.play(.left)
        XCTAssertNil(finder.session)
        for _ in 0..<10 {
            headphones.refresh()
            acknowledgeAll(headphones)
        }
        finder.dismiss()
        XCTAssertTrue(headphones.beginEarbudFinder())
        XCTAssertTrue(headphones.earbudFinder === finder)
        XCTAssertEqual(finder.availabilityMessage, String(localized: "Couldn’t finish checking the earbuds."))
        XCTAssertEqual(headphones.simulatedTransmittedFrames.filter {
            $0.type == 0x0E && $0.payload == [0x06, 0]
        }.count, 2)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testLateTable2ReplyRestoresFinderWithoutStartingAnUnauthorizedSound() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finder = try finderAwaitingTable2(on: headphones)
        defer { finish(finder, headphones: headphones) }
        await exhaustTable2Discovery(on: headphones)
        XCTAssertTrue(headphones.hasFailedTable2Discovery)
        headphones.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
        await receiveQueuedUpdates()
        XCTAssertFalse(headphones.hasFailedTable2Discovery)
        XCTAssertFalse(headphones.canRetryDeviceDiscovery)
        XCTAssertNil(finder.availabilityMessage)
        XCTAssertTrue(finder.canPlay(.left))
        XCTAssertNil(finder.session)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.play(.left)
        finder.simulateConnectionOpened()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
    }

    func testExplicitDiscoveryRetryUsesAFreshSessionAndRejectsTheOldReply() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finder = try finderAwaitingTable2(on: headphones)
        defer { finish(finder, headphones: headphones) }
        await exhaustTable2Discovery(on: headphones)
        XCTAssertTrue(headphones.canRetryDeviceDiscovery)
        let oldSession = headphones.simulatedControlSession
        headphones.retryDeviceDiscovery()
        XCTAssertGreaterThan(headphones.simulatedControlSession, oldSession)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(headphones.canRetryDeviceDiscovery)
        XCTAssertTrue(finder.needsNewControlSession)
        headphones.simulateProtocolMessage([0x07, 0, 0], type: 0x0E, session: oldSession)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertFalse(finder.canPlay(.left))
        let replacement = try finderAwaitingTable2(on: headphones, beginConnection: false)
        defer { finish(replacement, headphones: headphones) }
        XCTAssertFalse(replacement === finder)
        XCTAssertEqual(replacement.availabilityMessage, String(localized: "Checking the earbuds…"))
        XCTAssertFalse(replacement.canPlay(.right))
        headphones.simulateProtocolMessage([0x07, 0, 0], type: 0x0E, session: oldSession)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertTrue(replacement.simulatedSentMessages.isEmpty)
        headphones.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
        await receiveQueuedUpdates()
        XCTAssertTrue(headphones.hasCurrentTable2Capabilities)
        XCTAssertTrue(replacement.canPlay(.right))
        XCTAssertNil(replacement.session)
        XCTAssertTrue(replacement.simulatedSentMessages.isEmpty)
        replacement.play(.right)
        replacement.simulateConnectionOpened()
        XCTAssertEqual(replacement.session?.phase, .awaitingWearingConfirmation)
        replacement.confirmWearingOverride(sessionID: try XCTUnwrap(replacement.session?.id))
        XCTAssertTrue(replacement.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testDiscoveryRetryRetiresFailedMultipointWithoutRepeatingTheSetter() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finder = try finderAwaitingTable2(on: headphones, supportedFunctions: [0x11, 0x90, 0xD2])
        defer { finish(finder, headphones: headphones) }
        let title = Array("MULTIPOINT_SETTING".utf8)
        headphones.simulateProtocolMessage([0xD1, 0xD2, 0, 1, UInt8(title.count)] + title + [0])
        acknowledgeAll(headphones)
        headphones.simulateProtocolMessage([0xD3, 0xD2, 0])
        headphones.simulateProtocolMessage([0xD7, 0xD2, 0, 0])
        acknowledgeAll(headphones)
        await exhaustTable2Discovery(on: headphones)
        XCTAssertNil(headphones.multipointUnavailableReason)
        headphones.setMultipointEnabled(false)
        acknowledgeAll(headphones)
        XCTAssertEqual(headphones.multipointTransition?.phase, .awaitingResponse)
        let session = headphones.simulatedControlSession
        XCTAssertFalse(headphones.canRetryDeviceDiscovery)
        headphones.retryDeviceDiscovery()
        XCTAssertEqual(headphones.simulatedControlSession, session)
        headphones.simulateMultipointTimeout()
        acknowledgeAll(headphones)
        XCTAssertEqual(headphones.multipointTransition?.phase, .verifying)
        headphones.simulateMultipointTimeout()
        XCTAssertEqual(headphones.multipointTransition?.phase, .failed)
        XCTAssertTrue(headphones.isReady)
        XCTAssertTrue(headphones.canRetryDeviceDiscovery)

        headphones.retryDeviceDiscovery()
        XCTAssertGreaterThan(headphones.simulatedControlSession, session)
        XCTAssertNil(headphones.multipointTransition)
        XCTAssertNil(headphones.simulatedMultipointRecoveryUsesBLE)
        XCTAssertEqual(headphones.linkState, .handshaking)
        XCTAssertEqual(headphones.simulatedPendingFrame?.payload, [0, 0])
        XCTAssertEqual(headphones.simulatedTransmittedFrames.filter { $0.payload == [0xD8, 0xD2, 0, 1] }.count, 1)
        XCTAssertTrue(finder.needsNewControlSession)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testDiscoveryRetryResumesFailedConnectionVerificationWithoutRepeatingTheSetter() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finder = try finderAwaitingTable2(on: headphones, supportedFunctions: [0x11, 0x90, 0xE7])
        defer { finish(finder, headphones: headphones) }
        for payload: [UInt8] in [[0xE1, 5, 3, 0, 1, 2, 1, 0], [0xE3, 5, 0, 0], [0xE7, 5, 0]] {
            headphones.simulateProtocolMessage(payload)
        }
        acknowledgeAll(headphones)
        await exhaustTable2Discovery(on: headphones)
        XCTAssertNil(headphones.connectionModeUnavailableReason(.stableConnection))
        headphones.setConnectionMode(.stableConnection)
        acknowledgeAll(headphones)
        XCTAssertEqual(headphones.connectionTransition?.phase, .awaitingResponse)
        let session = headphones.simulatedControlSession
        XCTAssertFalse(headphones.canRetryDeviceDiscovery)
        headphones.retryDeviceDiscovery()
        XCTAssertEqual(headphones.simulatedControlSession, session)
        headphones.simulateConnectionModeTimeout()
        XCTAssertEqual(headphones.connectionTransition?.phase, .failed)
        XCTAssertTrue(headphones.isReady)
        XCTAssertTrue(headphones.canRetryDeviceDiscovery)

        headphones.retryDeviceDiscovery()
        XCTAssertGreaterThan(headphones.simulatedControlSession, session)
        XCTAssertEqual(headphones.connectionTransition?.phase, .recovering)
        XCTAssertNil(headphones.connectionModeError)
        XCTAssertEqual(headphones.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 5, 1, 0] }.count, 1)
        XCTAssertTrue(finder.needsNewControlSession)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

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

    func testConfirmedEmptyTable2RequiresAuthenticatedConfirmationWithoutAWearingQuery() throws {
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
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertNil(finder.session?.wearingConfirmationStatus)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
    }

    func testUnownedWearingCapabilityReplyCannotMutateAnActiveFinder() async throws {
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true)
        headphones.simulateDeviceConnection(named: "WF-1000XM5")
        completeFinderHandshake(on: headphones)
        deliver([0x07, 0, 0], to: headphones)
        let finder = EarbudFinderController(headphones: headphones, simulated: true)
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.phase, .starting)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        deliver([0x07, 0, 1, 0xF0, 0], to: headphones)
        XCTAssertFalse(headphones.wearingStatus.isSupported)
        XCTAssertNil(headphones.wearingStatus.leftWorn)
        XCTAssertTrue(finder.wearingDetectionIsUnavailable)
        XCTAssertEqual(finder.session?.phase, .starting)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        XCTAssertFalse(headphones.hasPendingWearingStatusRead)
        finder.stop()
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
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

    func testUnknownWearStatusRequiresAuthenticationFinalConfirmationAndSuccessfulLog() async throws {
        for target in [FastPairRingTarget.left, .right] {
            for saved in [false, true] {
                let (headphones, finder) = readyFinder()
                defer { finish(finder, headphones: headphones) }
                finder.simulatesAuthorizationSaveDelay = true
                finder.play(target)
                finder.simulateConnectionOpened()
                acknowledgeAll(headphones)
                deliver([0xF3, 0, 0xFF], to: headphones)
                await receiveQueuedUpdates()
                XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
                XCTAssertNil(finder.session?.wearingConfirmationStatus)
                let sessionID = try XCTUnwrap(finder.session?.id)
                finder.confirmWearingOverride(sessionID: sessionID)
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                finder.authenticateWearingOverride(sessionID: sessionID)
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: false)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                finder.authenticateWearingOverride(sessionID: sessionID)
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
                XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.isSavingAuthorization)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
                finder.simulateAuthorizationSaveCompletion(succeeded: saved)
                XCTAssertEqual(finder.session?.phase, saved ? .starting : .finished)
                XCTAssertEqual(finder.mayBeRinging, saved)
                XCTAssertEqual(finder.simulatedSentMessages, saved ? [try ringData(target)] : [])
                XCTAssertEqual(finder.simulatedAuthorizationEvents, saved ? [sessionID] : [])
                if saved {
                    XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
                    deliver([0xF5, 0, 0xFF], to: headphones)
                    await receiveQueuedUpdates()
                    XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target)])
                }
            }
        }
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
            let worn = SonyFrameCodec.encode(type: 0x0E, sequence: 1, payload: [0xF5, 0, 0])
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

    func testUnknownOrMalformedWearStatusRequiresFreshAuthenticatedConfirmation() async throws {
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
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
            XCTAssertNil(finder.wearingAuthorization)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
            finder.confirmWearingOverride(sessionID: sessionID)
            XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
            XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
        }
    }

    func testChangedUnsafeWearStatusRequiresNewAuthenticationAndConfirmationAtEveryStage() async throws {
        for target in [FastPairRingTarget.left, .right] {
            for removedBetweenReadings in [false, true] {
                for stage in 0..<3 {
                    let (headphones, finder) = readyFinder()
                    defer { finish(finder, headphones: headphones) }
                    finder.simulatesAuthorizationSaveDelay = true
                    finder.play(target)
                    finder.simulateConnectionOpened()
                    acknowledgeAll(headphones)
                    deliver([0xF3, 0, removedBetweenReadings ? 0 : 0xFF], to: headphones)
                    await receiveQueuedUpdates()
                    let sessionID = try XCTUnwrap(finder.session?.id)
                    finder.authenticateWearingOverride(sessionID: sessionID)
                    let requestID = try XCTUnwrap(finder.simulatedAuthenticationRequestID)
                    if stage > 0 { finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true) }
                    if stage == 2 { finder.confirmWearingOverride(sessionID: sessionID) }
                    let saveID = finder.simulatedAuthorizationSaveRequestID
                    if removedBetweenReadings {
                        deliver([0xF5, 0, target == .left ? 2 : 3], to: headphones)
                        XCTAssertEqual(finder.session?.wearingConfirmationStatus, false)
                    }

                    deliver([0xF5, 0, 0], to: headphones)

                    XCTAssertEqual(finder.session?.wearingConfirmationStatus, true)
                    XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
                    XCTAssertFalse(finder.isAuthenticating)
                    XCTAssertFalse(finder.isSavingAuthorization)
                    XCTAssertNil(finder.wearingAuthorization)
                    finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true, requestID: requestID)
                    if let saveID { finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: saveID) }
                    finder.confirmWearingOverride(sessionID: sessionID)
                    XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                    XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
                    XCTAssertFalse(finder.mayBeRinging)

                    finder.authenticateWearingOverride(sessionID: sessionID)
                    XCTAssertNotEqual(finder.simulatedAuthenticationRequestID, requestID)
                    finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
                    finder.confirmWearingOverride(sessionID: sessionID)
                    XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                    finder.simulateAuthorizationSaveCompletion(succeeded: true)
                    XCTAssertEqual(finder.simulatedSentMessages, [try ringData(target)])
                    XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
                    XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
                }
            }
        }
    }

    func testWearStatusBecomingUnknownDuringLogSaveRejectsTheOldAuthorization() async throws {
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
        deliver([0xF5, 0, 4], to: headphones)
        deliver([0xF5, 0, 0xFF], to: headphones)
        finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: requestID)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertFalse(finder.isSavingAuthorization)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
    }

    func testWearTimeoutRequiresConfirmationWithoutAnotherAmbiguousQueryOrAutomaticStart() async {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        XCTAssertTrue(finder.isCheckingWearing)
        finder.simulateWearingTimeout()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        XCTAssertNil(finder.session?.wearingConfirmationStatus)
        finder.stop()
        finder.play(.right)
        finder.simulateConnectionOpened()
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertTrue(headphones.hasPendingWearingStatusRead)
        XCTAssertEqual(headphones.simulatedTransmittedFrames.filter {
            $0.type == 0x0E && $0.payload == SonyWearingStatus.queryPayload
        }.count, 1)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testRetainedWearQueryCannotUpgradeUnknownAuthorizationToAWornOverride() async throws {
        for worn in [false, true] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.simulatesAuthorizationSaveDelay = true
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            finder.simulateWearingTimeout()
            finder.stop()
            XCTAssertTrue(headphones.hasPendingWearingStatusRead)
            deliver([0xF5, 0, worn ? 0 : 4], to: headphones)
            await receiveQueuedUpdates()
            XCTAssertEqual(headphones.wearingStatus.rightWorn, worn)
            finder.play(.right)
            finder.simulateConnectionOpened()
            XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
            XCTAssertNil(finder.session?.wearingConfirmationStatus)
            XCTAssertTrue(headphones.hasPendingWearingStatusRead)
            let sessionID = try XCTUnwrap(finder.session?.id)
            finder.authenticateWearingOverride(sessionID: sessionID)
            finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
            XCTAssertNil(finder.wearingAuthorization?.wearingStatus)
            finder.confirmWearingOverride(sessionID: sessionID)
            let saveID = try XCTUnwrap(finder.simulatedAuthorizationSaveRequestID)

            finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: saveID)

            if worn {
                XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
                XCTAssertEqual(finder.session?.wearingConfirmationStatus, true)
                XCTAssertFalse(finder.isSavingAuthorization)
                XCTAssertNil(finder.wearingAuthorization)
                XCTAssertFalse(finder.mayBeRinging)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
                finder.simulateAuthorizationSaveCompletion(succeeded: true, requestID: saveID)
                finder.confirmWearingOverride(sessionID: sessionID)
                XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
                finder.authenticateWearingOverride(sessionID: sessionID)
                finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
                XCTAssertEqual(finder.wearingAuthorization?.wearingStatus, true)
                finder.confirmWearingOverride(sessionID: sessionID)
                finder.simulateAuthorizationSaveCompletion(succeeded: true)
            }
            XCTAssertEqual(finder.session?.phase, .starting)
            XCTAssertEqual(finder.session?.startedWithWearingOverride, worn)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.right)])
            XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
        }
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
            XCTAssertTrue(finder.mayBeRinging)
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

    func testStopRetrySurvivesRepeatedStopDismissalAndLifecycleChanges() async throws {
        for opened in [false, true] {
            for interruption in ["stop", "dismiss", "retire", "resign", "hide", "sleep", "displaySleep", "sessionResign", "controlLoss"] {
                let (headphones, finder) = readyFinder()
                defer { finish(finder, headphones: headphones) }
                finder.play(.left)
                finder.simulateConnectionOpened()
                acknowledgeAll(headphones)
                deliver([0xF3, 0, 4], to: headphones)
                await receiveQueuedUpdates()
                finder.simulateTransportFailure()
                let sessionID = try XCTUnwrap(finder.session?.id)
                finder.retryStop()
                if opened { finder.simulateConnectionOpened() }
                switch interruption {
                case "stop": finder.stop()
                case "dismiss": finder.dismiss()
                case "retire": finder.dismiss(retiringTransport: true)
                case "resign": NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
                case "hide": NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
                case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                case "displaySleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
                case "sessionResign": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
                default: headphones.simulateControlLoss(deviceConnected: false)
                }
                await receiveQueuedUpdates()
                XCTAssertEqual(finder.session?.id, sessionID)
                XCTAssertEqual(finder.session?.phase, opened ? .stopping : .connecting, interruption)
                XCTAssertTrue(finder.session?.isRetryingStop == true, interruption)
                XCTAssertTrue(finder.mayBeRinging, interruption)
                XCTAssertTrue(finder.isBusy, interruption)
                finder.simulateConnectionOpened()
                XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()], interruption)
                finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
                XCTAssertEqual(finder.session?.phase, .finished, interruption)
                XCTAssertFalse(finder.mayBeRinging, interruption)
                finder.simulateConnectionOpened()
                finder.retryStop()
                XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()], interruption)
            }
        }
    }

    func testDisplaySleepAndSessionChangeStopWithoutDismissingThePresentedFinder() async throws {
        for notification in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let (headphones, finder) = readyFinder()
            defer { finish(finder, headphones: headphones) }
            finder.play(.left)
            finder.simulateConnectionOpened()
            acknowledgeAll(headphones)
            deliver([0xF3, 0, 4], to: headphones)
            await receiveQueuedUpdates()
            NSWorkspace.shared.notificationCenter.post(name: notification, object: nil)
            XCTAssertEqual(finder.session?.phase, .stopping)
            XCTAssertTrue(finder.mayBeRinging)
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
            finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertEqual(finder.simulatedTransportCloseCount, 1)
            XCTAssertNil(finder.availabilityMessage)
            XCTAssertTrue(finder.canPlay(.right))
            XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        }
    }

    func testScheduledRingingDeadlineSendsOneStopAndRequiresConfirmation() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
        XCTAssertEqual(finder.session?.phase, .ringing)
        XCTAssertEqual(finder.session?.timeoutSeconds, 30)
        finder.simulateRingingTimeout()
        XCTAssertEqual(finder.session?.phase, .stopping)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        finder.simulateRingingTimeout()
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left), try stopData()])
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
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

    func testReopeningClearsThePriorErrorAndFinishedTransportFailureCannotReplaceIt() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 0], to: headphones)
        await receiveQueuedUpdates()
        finder.simulateTransportFailure()
        XCTAssertEqual(finder.session?.phase, .failed)
        XCTAssertNotNil(finder.message)
        finder.dismiss()

        finder.prepareForPresentation()

        XCTAssertNil(finder.message)
        XCTAssertTrue(finder.canPlay(.left))
        finder.simulateTransportFailure()
        XCTAssertNil(finder.message)
        XCTAssertTrue(finder.canPlay(.left))
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    func testConfirmedSilenceCancelsTheActualRingingDeadline() async throws {
        let (headphones, finder) = readyFinder()
        defer { finish(finder, headphones: headphones) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeAll(headphones)
        deliver([0xF3, 0, 4], to: headphones)
        await receiveQueuedUpdates()
        XCTAssertTrue(finder.simulatedRingingTimeoutPending)
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 2, 30]).encoded))
        XCTAssertEqual(finder.session?.phase, .ringing)
        finder.stop()
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.simulatedRingingTimeoutPending)
        let sent = finder.simulatedSentMessages
        finder.simulateRingingTimeout()
        XCTAssertEqual(finder.simulatedSentMessages, sent)
        XCTAssertFalse(finder.mayBeRinging)
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

    func testQueuedSafeStartBecomingUnknownRequiresNewAuthenticatedConfirmation() async throws {
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
        deliver([0xF5, 0, 0xFF], to: headphones)
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        finder.simulateAcknowledgementTimeout()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        release.signal()
        let drained = expectation(description: "Cancelled start queue drained")
        io.write(Data([2]), willSend: { false }) { _ in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(channel.writes, [Data([1])])
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.simulatedChannelIO = nil
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
        XCTAssertEqual(finder.simulatedSentMessages, [try ringData(.left)])
        XCTAssertEqual(finder.simulatedAuthorizationEvents, [sessionID])
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

    private func finderAwaitingTable2(on headphones: SonyHeadphonesController, beginConnection: Bool = true,
                                     supportedFunctions: [UInt8] = [0x11]) throws -> EarbudFinderController {
        if beginConnection { headphones.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true) }
        headphones.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: beginConnection)
        acknowledgeAll(headphones)
        let name = Array("WF-1000XM5".utf8)
        let firmware = Array("6.1.0".utf8)
        let capabilities: [UInt8] = [0x07, 0, UInt8(supportedFunctions.count)] + supportedFunctions.flatMap { [$0, 0] }
        for payload: [UInt8] in [[0x05, 1, UInt8(name.count)] + name, [0x05, 3, 0, 1],
                                capabilities, [0x05, 2, UInt8(firmware.count)] + firmware, [0x13, 1, 1, 1]] {
            headphones.simulateProtocolMessage(payload)
            acknowledgeAll(headphones)
        }
        XCTAssertTrue(headphones.isReady)
        XCTAssertFalse(headphones.hasCurrentTable2Capabilities)
        XCTAssertNotNil(headphones.simulatedDiscoveryReadTimeoutID([0x06, 0], type: 0x0E))
        XCTAssertTrue(headphones.beginEarbudFinder())
        return try XCTUnwrap(headphones.earbudFinder)
    }

    private func exhaustTable2Discovery(on headphones: SonyHeadphonesController) async {
        for _ in 0..<2 {
            headphones.simulateDiscoveryReadTimeout([0x06, 0], type: 0x0E)
            for _ in 0..<8 { await Task.yield() }
            acknowledgeAll(headphones)
        }
    }

    private func completeFinderHandshake(on headphones: SonyHeadphonesController) {
        headphones.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
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
        headphones.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5,
                                            simulatedTable2Functions: [0xF0])
        let firmware = Array("6.1.0".utf8)
        headphones.simulateProtocolMessage([0x05, 2, UInt8(firmware.count)] + firmware)
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
        headphones.simulateProtocolMessage(payload, type: type, session: session)
    }
}
