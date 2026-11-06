import CoreAudio
import XCTest
@testable import Acouplet

final class SonyPlaybackTests: XCTestCase {
    @MainActor
    func testInitialPlaybackQueriesWaitForBothTheirReplyAndACK() throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            for replyFirst in [false, true] {
                let controller = makeNoNoiseController(generation: generation, functions: [0xA1])
                defer { controller.simulateControlLoss() }
                let replies = initialPlaybackReplies(generation: generation)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA0 }.count, 1)
                XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA2 || $0.payload.first == 0xA6 })
                controller.simulateProtocolMessage(replies[0])
                for reply in replies.dropFirst() {
                    let frame = try XCTUnwrap(controller.simulatedPendingFrame)
                    XCTAssertEqual(frame.payload, controller.playback.queryPayload(for: reply))
                    if replyFirst {
                        controller.simulateProtocolMessage(reply)
                        XCTAssertEqual(controller.simulatedPendingFrame, frame)
                        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
                    } else {
                        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
                        XCTAssertNil(controller.simulatedPendingFrame)
                        controller.simulateProtocolMessage(reply)
                    }
                }
                XCTAssertNil(controller.simulatedPendingFrame)
                XCTAssertEqual(controller.playback.volume, 12)
                XCTAssertTrue(controller.canControlMusicVolume)
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { [0xA0, 0xA2, 0xA6].contains($0.payload.first) }.map(\.payload), controller.playback.queryPayloads)
            }
        }
    }

    @MainActor
    func testPlaybackAcquisitionIgnoresMismatchedMalformedAndUnknownStatusReplies() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        for reply: [UInt8] in [[0xA3, 2, 0, 2, 0], [0xA3, 1, 0, 2], [0xA3, 1, 2, 2, 0],
                               [0xA3, 1, 0, 4, 0], [0xA3, 1, 0, 2, 2]] {
            controller.simulateProtocolMessage(reply)
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA6, 0x20] })
        }
        controller.simulateProtocolMessage([0xA3, 1, 1, 2, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
        XCTAssertEqual(controller.playback.available, false)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 12])
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(controller.canControlMusicVolume)
    }

    @MainActor
    func testWaitingPlaybackReplyAllowsIndependentCommandsAndNotifications() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.setDSEE(.off)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 1, 0])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xE9, 1, 0])
        XCTAssertNil(controller.pendingChanges[.dsee])
        controller.simulateProtocolMessage([0xA5, 1, 0, 2, 0])
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA2, 1])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
    }

    @MainActor
    func testPlaybackReadTimeoutAbortsItsSequenceAndRefusesNewOwnershipUntilLateReply() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulatePlaybackReadTimeout([0xA2, 1])
        for _ in 0..<8 { await Task.yield() }
        let error = controller.playbackReadError
        XCTAssertNotNil(error)
        XCTAssertFalse(controller.refreshMusicVolume())
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.isReady)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertNil(controller.simulatedPendingFrame)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertNil(controller.musicStatusReadbackID)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        #endif
        XCTAssertTrue(controller.refreshMusicVolume())
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA2, 1])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 12])
        XCTAssertNil(controller.playbackReadError)
    }

    @MainActor
    func testPlaybackAcquisitionResetCannotResumeFromAnOldReply() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0], session: session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.refreshMusicVolume())
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA2, 1])
    }

    @MainActor
    func testOptionalPlaybackTimeoutPreservesCoalescedFullAndMusicVolumeRefreshes() async {
        let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
        defer { controller.simulateControlLoss() }
        for reply in initialPlaybackReplies(generation: .v2).prefix(2) {
            controller.simulateProtocolMessage(reply)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA6, 1] })
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA6, 0x20] })
        controller.refresh()
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.simulatePlaybackReadTimeout([0xA6, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA2, 1])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 0x20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 12])
        XCTAssertEqual(controller.playback.volume, 12)
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 1] }.count, 1)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        #endif
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testReplacementVolumeReadCannotUseThePreviousReadAcknowledgment() throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeNoNoiseController(generation: generation, functions: [0xA1])
            defer { controller.simulateControlLoss() }
            for reply in initialPlaybackReplies(generation: generation) {
                controller.simulateProtocolMessage(reply)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            XCTAssertTrue(controller.refreshMusicVolume())
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage(generation == .v1 ? [0xA3, 1, 0, 2] : [0xA3, 1, 0, 2, 0])
            let old = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(old.payload, controller.playback.musicVolumeQueryPayload)
            controller.simulateProtocolMessage(generation == .v1 ? [0xA9, 1, 0x20, 13] : [0xA9, 0x20, 13])
            controller.simulateProtocolMessage(generation == .v1 ? [0xA7, 1, 0x20, 14] : [0xA7, 0x20, 14])
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - old.sequence, payload: []))
            let replacement = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(replacement.payload, old.payload)
            XCTAssertNotEqual(replacement.sequence, old.sequence)
            controller.simulateProtocolMessage(generation == .v1 ? [0xA7, 1, 0x20, 14] : [0xA7, 0x20, 14])
            XCTAssertEqual(controller.playback.volume, 14)
            XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - replacement.sequence, payload: []))
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        }
    }

    @MainActor
    func testRequiredMusicReadRecoveryStartsFreshSessionWithoutLateReply() async {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let legacy = generation == .v1
            let replies = initialPlaybackReplies(generation: generation)
            for missing: [UInt8] in [[0xA0, 1], [0xA2, 1], legacy ? [0xA6, 1, 0x20] : [0xA6, 0x20]] {
                let controller = makeNoNoiseController(generation: generation, functions: [0xA1])
                defer { controller.simulateControlLoss() }
                for reply in replies {
                    if controller.playback.queryPayload(for: reply) == missing { break }
                    controller.simulateProtocolMessage(reply)
                    acknowledgeSimulatedCommands(controller)
                }
                XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == missing })
                let frames = controller.simulatedTransmittedFrames
                let previousSession = controller.simulatedControlSession
                XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
                XCTAssertEqual(controller.simulatedControlSession, previousSession)
                XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
                controller.simulatePlaybackReadTimeout(missing)
                for _ in 0..<8 { await Task.yield() }
                XCTAssertNotNil(controller.playbackReadError)
                XCTAssertTrue(controller.recoverMusicVolumeIfNeeded())
                XCTAssertGreaterThan(controller.simulatedControlSession, previousSession)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
                XCTAssertFalse(controller.isReady)
                XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
                XCTAssertNil(controller.musicStatusReadbackID)
                XCTAssertNil(controller.musicVolumeReadbackID)
                let session = controller.simulatedControlSession
                XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
                XCTAssertEqual(controller.simulatedControlSession, session)
                controller.simulateProtocolMessage(legacy ? [0x01, 0, 2, 0x10] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 1])
                acknowledgeSimulatedCommands(controller)
                controller.simulateProtocolMessage(legacy ? [0x07, 0, 1, 0xA1] : [0x07, 0, 1, 0xA1, 0])
                acknowledgeSimulatedCommands(controller)
                controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
                let currentFrames = controller.simulatedTransmittedFrames
                for reply in replies { controller.simulateProtocolMessage(reply, session: previousSession) }
                controller.simulateProtocolMessage(legacy ? [0xA9, 1, 0x20, 29] : [0xA9, 0x20, 29], session: previousSession)
                XCTAssertEqual(controller.simulatedTransmittedFrames, currentFrames)
                XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
                XCTAssertNil(controller.playback.musicVolumeRange)
                XCTAssertNil(controller.playback.volume)
                XCTAssertNil(controller.musicStatusReadbackID)
                XCTAssertNil(controller.musicVolumeReadbackID)
                for reply in replies {
                    if controller.playback.queryPayload(for: reply) == controller.playback.musicVolumeQueryPayload {
                        XCTAssertNotNil(controller.musicStatusReadbackID)
                        XCTAssertNil(controller.musicVolumeReadbackID)
                        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
                    }
                    controller.simulateProtocolMessage(reply)
                    acknowledgeSimulatedCommands(controller)
                }
                XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
                XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
                XCTAssertEqual(controller.playback.volume, 12)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
            }
        }
    }

    @MainActor
    func testMusicReadRecoveryWaitsForPendingSettingWithoutRefreshing() async {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeNoNoiseController(generation: generation, functions: [0xA1])
            defer { controller.simulateControlLoss() }
            for reply in initialPlaybackReplies(generation: generation) {
                controller.simulateProtocolMessage(reply)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertTrue(controller.refreshMusicVolume())
            acknowledgeSimulatedCommands(controller)
            controller.setPlaybackVolume(20)
            acknowledgeSimulatedCommands(controller)
            controller.simulatePlaybackReadTimeout([0xA2, 1])
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNotNil(controller.playbackReadError)
            let session = controller.simulatedControlSession
            let frames = controller.simulatedTransmittedFrames
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
            XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
            controller.simulateProtocolMessage(generation == .v1 ? [0xA9, 1, 0x20, 20] : [0xA9, 0x20, 20])
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertTrue(controller.recoverMusicVolumeIfNeeded())
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
        }
    }

    @MainActor
    func testMusicReadRecoveryDoesNotReopenDuringTerminationOrSleep() async {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            for terminating in [false, true] {
                let controller = makeNoNoiseController(generation: generation, functions: [0xA1])
                defer { controller.simulateControlLoss() }
                controller.simulatePlaybackReadTimeout([0xA0, 1])
                for _ in 0..<8 { await Task.yield() }
                XCTAssertNotNil(controller.playbackReadError)
                if terminating {
                    controller.beginTermination()
                } else {
                    controller.systemWillSleep()
                }
                let session = controller.simulatedControlSession
                let frames = controller.simulatedTransmittedFrames
                XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
                controller.refresh()
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
                if terminating {
                    controller.cancelTermination()
                    XCTAssertTrue(controller.recoverMusicVolumeIfNeeded())
                    XCTAssertGreaterThan(controller.simulatedControlSession, session)
                }
            }
        }
    }
    #endif

    @MainActor
    func testNegotiatedLegacyPlaybackUsesExactVolumeQueriesAndConfirmedWrites() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA0 || $0.payload.first == 0xA2 || $0.payload.first == 0xA6 }.map(\.payload),
                       [[0xA0, 1]])
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { [0xA0, 0xA2, 0xA6].contains($0.payload.first) }.map(\.payload),
                       [[0xA0, 1], [0xA2, 1], [0xA6, 1, 0x20]])
        XCTAssertEqual(controller.playback.volume, 12)
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlCallVolume)
        XCTAssertNil(controller.playback.musicCallStatus)
        controller.setPlaybackVolume(20)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 1, 0x20, 20])
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.playback.volume, 12)
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 20])
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
    }

    @MainActor
    func testLegacyVolumeIgnoresOtherDialectAndUnownedReturns() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        for payload: [UInt8] in [[0xA1, 1, 41, 16], [0xA3, 1, 0, 1, 0], [0xA7, 0x20, 20],
                                [0xA9, 0x21, 7], [0xA7, 1, 0x20, 20], [0xA9, 1, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
            XCTAssertEqual(controller.playback.volume, 12)
            XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
            XCTAssertNil(controller.playback.callVolume)
            XCTAssertNil(controller.playback.musicCallStatus)
        }
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 20], type: 0x0E)
        XCTAssertEqual(controller.playback.volume, 12)
        controller.setCallVolume(5)
        controller.controlPlayback(.play)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testLegacyOldPollCannotConfirmANewerWrite() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        controller.setPlaybackVolume(20)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 20])
        XCTAssertEqual(controller.playback.volume, 12)
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 1, 0x20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 20])
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
    }

    @MainActor
    func testFreshVolumeReadReconcilesTimeoutWithoutConfirmingTheFailedWrite() async {
        for hasOldPoll in [false, true] {
            let controller = makeNoNoiseController(generation: .v1, functions: [0xA1, 0xE1])
            defer { controller.simulateControlLoss() }
            for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12],
                                    [0xE1, 1, 0], [0xE3, 1, 0], [0xE7, 1, 0, 0]] {
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertTrue(controller.canChangeConnectionMode)
            if hasOldPoll {
                XCTAssertTrue(controller.refreshMusicVolume())
                acknowledgeSimulatedCommands(controller)
                controller.simulateProtocolMessage([0xA3, 1, 0, 2])
            }
            controller.setPlaybackVolume(20)
            acknowledgeSimulatedCommands(controller)
            controller.simulateSettingTimeout(.playbackVolume)
            for _ in 0..<4 { await Task.yield() }
            let issue = controller.settingErrors[.playbackVolume]
            XCTAssertNotNil(issue)
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertFalse(controller.canChangeConnectionMode)
            if hasOldPoll {
                controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
                XCTAssertEqual(controller.playback.volume, 12)
                XCTAssertFalse(controller.canChangeConnectionMode)
            } else {
                XCTAssertTrue(controller.refreshMusicVolume())
            }
            acknowledgeSimulatedCommands(controller)
            if !hasOldPoll {
                controller.simulateProtocolMessage([0xA3, 1, 0, 2])
                acknowledgeSimulatedCommands(controller)
            }
            controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
            XCTAssertEqual(controller.playback.volume, 14)
            XCTAssertTrue(controller.canChangeConnectionMode)
            XCTAssertEqual(controller.settingErrors[.playbackVolume], issue)
        }
    }

    @MainActor
    func testLegacyQueuedVolumeCancellationAndDeferredNotificationRetainWriteOwnership() async throws {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.refreshMusicVolume())
        let change = Task { @MainActor in
            try await controller.performConfirmedSettingChange(.playbackVolume) { controller.setPlaybackVolume(20) }
        }
        for _ in 0..<100 where controller.pendingChanges[.playbackVolume] == nil { await Task.yield() }
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        change.cancel()
        do { try await change.value; XCTFail("Cancelled legacy volume change completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 1, 0x20, 20] })
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertTrue(controller.isReady)
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
        }
        controller.defersSimulatedWrites = true
        controller.setPlaybackVolume(21)
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 21])
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [21])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [21])
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 21])
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.playback.volume, 21)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLegacyVolumeAdmissionRefreshNeedsBothNewOwnedReadbacks() {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.playback.generation, .v1)
        for payload in initialPlaybackReplies(generation: .v1) {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        let initialStatus = controller.musicStatusReadbackID
        let initialVolume = controller.musicVolumeReadbackID
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
        XCTAssertEqual(controller.musicVolumeReadbackID, initialVolume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        XCTAssertNotEqual(controller.musicStatusReadbackID, initialStatus)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA2, 1])
        XCTAssertEqual(controller.musicVolumeReadbackID, initialVolume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 12])
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        let status = controller.musicStatusReadbackID
        let volume = controller.musicVolumeReadbackID
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        XCTAssertEqual(controller.musicStatusReadbackID, status)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        XCTAssertNotEqual(controller.musicStatusReadbackID, status)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 14])
        XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        let latestStatus = controller.musicStatusReadbackID
        let latestVolume = controller.musicVolumeReadbackID
        controller.simulateProtocolMessage([0xA5, 1, 1, 2])
        controller.simulateProtocolMessage([0xA9, 1, 0x20, 15])
        XCTAssertEqual(controller.musicStatusReadbackID, latestStatus)
        XCTAssertEqual(controller.musicVolumeReadbackID, latestVolume)
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        XCTAssertTrue(controller.refreshMusicVolume())
        controller.simulateControlLoss()
        XCTAssertNil(controller.musicStatusReadbackID)
        XCTAssertNil(controller.musicVolumeReadbackID)
        XCTAssertFalse(controller.refreshMusicVolume())
    }
    @MainActor
    func testLegacyVolumeAdmissionPreservesSessionAfterOptionalReadExpiry() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WH-XB900N")
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x07, 0, 5, 0xA1, 0xE2, 0xF4, 0x41, 0x42])
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        controller.simulateLegacyDSEEReadTimeout([0xE0, 2])
        controller.simulateInitialFeatureReadTimeout()
        for _ in 0..<4 { await Task.yield() }
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xF0, 4] })
        controller.simulateSystemReadTimeout([0xF0, 4])
        controller.simulateInitialFeatureReadTimeout()
        controller.simulateLegacySoundEffectReadTimeout([0x40, 1, 1])
        controller.simulateLegacySoundEffectReadTimeout([0x40, 2, 1])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(controller.settingErrors[.dsee])
        XCTAssertNotNil(controller.settingErrors[.automaticPowerOff])
        XCTAssertNotNil(controller.settingErrors[.legacySoundEffect(.surround)])
        XCTAssertNotNil(controller.settingErrors[.legacySoundEffect(.soundPosition)])
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        let session = controller.simulatedControlSession
        let volume = controller.musicVolumeReadbackID
        let transmitted = controller.simulatedTransmittedFrames.count
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(Array(controller.simulatedTransmittedFrames.dropFirst(transmitted).map(\.payload)), [[0xA2, 1]])
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2])
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA6, 1, 0x20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 0x20, 13])
        XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.refresh()
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
    }

    @MainActor
    func testLegacyAdmissionRefreshRetiresTimedOutReadsWithoutGrantingFreshness() async throws {
        let controller = makeLegacyPlaybackController()
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        let status = controller.musicStatusReadbackID
        let volume = controller.musicVolumeReadbackID
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulatePlaybackReadTimeout([0xA2, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertFalse(controller.refreshMusicVolume())
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 13]] {
            controller.simulateProtocolMessage(payload)
        }
        XCTAssertEqual(controller.musicStatusReadbackID, status)
        XCTAssertEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA3, 1, 0, 2], [0xA7, 1, 0x20, 14]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertNotEqual(controller.musicStatusReadbackID, status)
        XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
        XCTAssertNil(controller.playbackReadError)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
    }
    #endif

    @MainActor
    func testRefreshWithoutNoiseControlsRenewsAdvertisedPlaybackBatteryAndEqualizer() {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let legacy = generation == .v1
            let controller = makeNoNoiseController(generation: generation, functions: legacy ? [0x11, 0x51, 0xA1] : [0x20, 0x50, 0xA1])
            defer { controller.simulateControlLoss() }
            let eqType: UInt8 = legacy ? 1 : 0
            let bands = SonyEqualizerBand.legacy.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
            let replies: [[UInt8]] = [[0x51, eqType, 6, 21, 1, 0xA0, 0], [0x53, eqType, 0],
                                     [0x5B, eqType, 6] + bands, [0x57, eqType, 0xA0, 6, 10, 10, 10, 10, 10, 10],
                                     legacy ? [0x11, 0, 70, 0] : [0x23, 0, 70, 0]] + initialPlaybackReplies(generation: generation)
            for payload in replies {
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.canControlMusicVolume)
            XCTAssertEqual(controller.batteryLevel, 70)
            XCTAssertEqual(controller.equalizer.settings, .flat)
            XCTAssertNil(controller.simulatedPendingFrame)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            let status = controller.musicStatusReadbackID
            let volume = controller.musicVolumeReadbackID
            #endif
            let count = controller.simulatedTransmittedFrames.count
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            let queries = controller.simulatedTransmittedFrames.dropFirst(count).filter { $0.type == 0x0C }.map(\.payload)
            XCTAssertEqual(queries, legacy ? [[0x10, 0], [0x56, 1], [0xA2, 1]]
                           : [[0x22, 0], [0x56, 0], [0xA2, 1]])
            for payload: [UInt8] in [legacy ? [0x11, 0, 68, 0] : [0x23, 0, 68, 0],
                                    [0x57, eqType, 0xA0, 6, 11, 10, 10, 10, 10, 10]] {
                controller.simulateProtocolMessage(payload)
            }
            for payload in initialPlaybackReplies(generation: generation).dropFirst() {
                let reply = payload == (legacy ? [0xA7, 1, 0x20, 12] : [0xA7, 0x20, 12])
                    ? Array(payload.dropLast()) + [14] : payload
                controller.simulateProtocolMessage(reply)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertEqual(controller.simulatedTransmittedFrames.dropFirst(count).filter { $0.type == 0x0C }.map(\.payload),
                           legacy ? [[0x10, 0], [0x56, 1], [0xA2, 1], [0xA6, 1, 0x20]]
                           : [[0x22, 0], [0x56, 0], [0xA2, 1], [0xA6, 1], [0xA6, 0x20], [0xA6, 0x21]])
            XCTAssertEqual(controller.batteryLevel, 68)
            XCTAssertEqual(controller.equalizer.settings?.values.first, 1)
            XCTAssertEqual(controller.playback.volume, 14)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertNotEqual(controller.musicStatusReadbackID, status)
            XCTAssertNotEqual(controller.musicVolumeReadbackID, volume)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            #endif
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    @MainActor
    func testRefreshWithoutNoiseControlsDoesNotInventUnadvertisedSettings() {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeNoNoiseController(generation: generation, functions: [])
            defer { controller.simulateControlLoss() }
            let count = controller.simulatedTransmittedFrames.count
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.simulatedTransmittedFrames.dropFirst(count).filter { $0.type == 0x0C }.isEmpty)
            XCTAssertNil(controller.batteryLevel)
            XCTAssertFalse(controller.equalizer.isSupported)
            XCTAssertFalse(controller.playback.isSupported)
            XCTAssertTrue(controller.availableNoiseModes.isEmpty)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    func testCapturedWFRepliesAndAdvertisedDialect() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        XCTAssertEqual(playback.queryPayloads, [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x20], [0xA6, 0x21]])
        XCTAssertFalse(playback.canControl)
        XCTAssertTrue(playback.update([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0]))
        XCTAssertNil(playback.track?.title)
        XCTAssertTrue(playback.update([0xA7, 0x20, 12]))
        XCTAssertNil(playback.volume)
        XCTAssertTrue(playback.update([0xA1, 1, 31, 16]))
        XCTAssertEqual(playback.volume, 12)
        XCTAssertNil(playback.volumePayload(20))
        XCTAssertTrue(playback.update([0xA3, 1, 0, 2, 0]))
        XCTAssertEqual(playback.state, .paused)
        XCTAssertTrue(playback.canControl)
        for command in [SonyPlaybackCommand.play, .pause, .next, .previous] {
            XCTAssertEqual(playback.commandPayload(command), [0xA4, 1, 0, command.rawValue])
        }
        for volume in 0...30 { XCTAssertEqual(playback.volumePayload(volume), [0xA8, 0x20, UInt8(volume)]) }
        for volume in [Int.min, -1, 31, Int.max] { XCTAssertNil(playback.volumePayload(volume)) }
        var unsupported = SonyPlayback(supportedFunctions: [0xA5])
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        XCTAssertFalse(unsupported.update([0xA3, 1, 0, 2, 0]))
        XCTAssertFalse(unsupported.update([0xA1, 1, 31, 16]))
        XCTAssertFalse(unsupported.update([0xA7, 0x20, 12]))
        XCTAssertFalse(unsupported.update([0xA7, 0x21, 7]))
        XCTAssertNil(unsupported.commandPayload(.play))
        XCTAssertNil(unsupported.callVolumePayload(7))
    }

    func testMetadataHasFourByteCountedUTF8FieldsAndUnknownReportsClearText() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        let payload: [UInt8] = [0xA9, 1] + name("Şarkı 🎵") + name("Album") + name("Artist") + name("Unidentified field")
        XCTAssertTrue(playback.update(payload))
        XCTAssertEqual(playback.track?.title, "Şarkı 🎵")
        XCTAssertEqual(playback.track?.album, "Album")
        XCTAssertEqual(playback.track?.artist, "Artist")
        let prior = playback
        for count in 0..<payload.count {
            XCTAssertFalse(playback.update(Array(payload.prefix(count))))
            XCTAssertEqual(playback, prior)
        }
        for invalid in [payload + [0], [0xA7, 1, 2, 1, 0xFF, 1, 0, 1, 0, 1, 0], [0xA7, 1, 2, 255, 0]] {
            XCTAssertFalse(playback.update(invalid))
            XCTAssertEqual(playback, prior)
        }
        XCTAssertTrue(playback.update([0xA7, 1] + name("Old title", status: 0xFF) + name("", status: 1)
                                      + name("Old artist", status: 0) + name("", status: 1)))
        XCTAssertNil(playback.track?.title)
        XCTAssertNil(playback.track?.album)
        XCTAssertNil(playback.track?.artist)
    }

    func testVolumeCapabilitiesAreCountsAndNeverInventARange() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        playback.update([0xA3, 1, 0, 2, 0])
        playback.update([0xA7, 0x20, 0])
        playback.update([0xA7, 0x21, 0])
        XCTAssertNil(playback.musicVolumeRange)
        XCTAssertNil(playback.callVolumeRange)
        XCTAssertNil(playback.volume)
        XCTAssertNil(playback.callVolume)
        XCTAssertNil(playback.volumePayload(0))
        XCTAssertTrue(playback.update([0xA1, 1, 1, 255]))
        XCTAssertEqual(playback.musicVolumeRange, 0...0)
        XCTAssertEqual(playback.callVolumeRange, 0...254)
        XCTAssertEqual(playback.volume, 0)
        XCTAssertEqual(playback.callVolume, 0)
        XCTAssertEqual(playback.volumePayload(0), [0xA8, 0x20, 0])
        XCTAssertNil(playback.volumePayload(1))
        playback.update([0xA5, 1, 0, 0, 1])
        XCTAssertEqual(playback.callVolumePayload(254), [0xA8, 0x21, 254])
        for value in [Int.min, -1, 255, Int.max] { XCTAssertNil(playback.callVolumePayload(value)) }
        playback.update([0xA9, 0x21, 255])
        XCTAssertNil(playback.callVolume)
        XCTAssertNil(playback.callVolumePayload(0))
        playback.update([0xA7, 0x21, 254])
        XCTAssertEqual(playback.callVolume, 254)
        playback.update([0xA1, 1, 255, 1])
        XCTAssertEqual(playback.musicVolumeRange, 0...254)
        XCTAssertEqual(playback.callVolumeRange, 0...0)
        XCTAssertNil(playback.callVolume)
        playback.update([0xA9, 0x21, 0])
        XCTAssertEqual(playback.callVolumePayload(0), [0xA8, 0x21, 0])
    }

    func testVolumeContextIsSeparateFromMusicPlaybackState() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        playback.update([0xA1, 1, 31, 16])
        playback.update([0xA7, 0x20, 12])
        playback.update([0xA7, 0x21, 7])
        for state: UInt8 in [0, 1, 2, 3, 255] {
            playback.update([0xA5, 1, 0, state, 1])
            XCTAssertFalse(playback.canControl)
            XCTAssertFalse(playback.canControlMusicVolume)
            XCTAssertTrue(playback.canControlCallVolume)
            XCTAssertNil(playback.volumePayload(12))
            XCTAssertEqual(playback.callVolumePayload(15), [0xA8, 0x21, 15])
            XCTAssertNil(playback.callVolumePayload(16))
            playback.update([0xA5, 1, 0, state, 0])
            XCTAssertTrue(playback.canControlMusicVolume)
            XCTAssertFalse(playback.canControlCallVolume)
            XCTAssertEqual(playback.volumePayload(30), [0xA8, 0x20, 30])
            XCTAssertNil(playback.callVolumePayload(7))
        }
        playback.update([0xA9, 0x20, 31])
        XCTAssertNil(playback.volume)
        XCTAssertEqual(playback.callVolume, 7)
        XCTAssertFalse(playback.canControlMusicVolume)
    }

    func testUnavailableUnknownContextAndMalformedReportsPreserveHonestState() {
        var playback = SonyPlayback(supportedFunctions: [0xA1])
        XCTAssertTrue(playback.update([0xA1, 1, 31, 16]))
        XCTAssertTrue(playback.update([0xA7, 0x20, 0]))
        XCTAssertTrue(playback.update([0xA7, 0x21, 0]))
        for status: [UInt8] in [[0xA3, 1, 1, 2, 0], [0xA5, 1, 0xFF, 2, 0],
                               [0xA5, 1, 1, 0, 1], [0xA5, 1, 0xFF, 1, 1], [0xA5, 1, 0, 1, 0xFF]] {
            XCTAssertTrue(playback.update(status))
            XCTAssertNil(playback.commandPayload(.next))
            XCTAssertNil(playback.volumePayload(1))
            XCTAssertNil(playback.callVolumePayload(1))
        }
        XCTAssertTrue(playback.update([0xA5, 1, 0, 1, 0]))
        XCTAssertEqual(playback.volumePayload(0), [0xA8, 0x20, 0])
        let prior = playback
        for invalid: [UInt8] in [[0xA3, 1, 0, 1], [0xA3, 1, 0, 1, 0, 0], [0xA5, 2, 0, 1, 0],
                                [0xA1, 1, 31], [0xA1, 1, 31, 16, 0], [0xA1, 1, 0, 16], [0xA1, 1, 31, 0],
                                [0xA1, 2, 31, 16], [0xA9, 1, 31, 16], [0xA7, 0x20], [0xA7, 0x20, 12, 0],
                                [0xA7, 0x21], [0xA9, 0x21, 12, 0], [0xA9, 0x30, 12], [0xA8, 0x20, 12]] {
            XCTAssertFalse(playback.update(invalid))
            XCTAssertEqual(playback, prior)
        }
        XCTAssertTrue(playback.update([0xA9, 0x20, 31]))
        XCTAssertNil(playback.volume)
        XCTAssertNil(playback.volumePayload(12))
    }

    @MainActor
    func testActionsAreSentOnceWithoutKeyReleaseAndAcknowledgmentIsNotPlaybackConfirmation() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        XCTAssertEqual(controller.pendingPlaybackCommand, .play)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA4, 1, 0, 7])
        controller.controlPlayback(.next)
        controller.setConnectionMode(.lowLatency)
        XCTAssertNil(controller.connectionTransition)
        XCTAssertNotNil(controller.sourceControlUnavailableReason)
        XCTAssertNotNil(controller.multipointUnavailableReason)
        acknowledgeSimulatedCommands(controller)
        XCTAssertNil(controller.pendingPlaybackCommand)
        XCTAssertEqual(controller.playback.state, .paused)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA4 }.map(\.payload), [[0xA4, 1, 0, 7]])
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA2, 1] })
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA6, 1] })
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertEqual(controller.playback.state, .playing)
        controller.controlPlayback(.next)
        acknowledgeSimulatedCommands(controller)
        controller.controlPlayback(.next)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA4, 1, 0, 2] }.count, 2)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA4, 1, 0, 0] })
        controller.simulateControlLoss()
        XCTAssertFalse(controller.playback.isSupported)
        XCTAssertNil(controller.pendingPlaybackCommand)
    }

    @MainActor
    func testVolumeRequiresMatchingT1ReadbackAndDoesNotAcceptCallVolume() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setPlaybackVolume(0)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 0])
        XCTAssertEqual(controller.playback.volume, 12)
        acknowledgeSimulatedCommands(controller)
        for (type, payload): (UInt8, [UInt8]) in [(0x0E, [0xA9, 0x20, 0]), (0x0C, [0xA9, 0x21, 0]),
                                                 (0x0C, [0xA7, 0x20, 1]), (0x0C, [0xA7, 0x20, 31])] {
            controller.simulateProtocolMessage(payload, type: type)
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [0])
        }
        controller.simulateProtocolMessage([0xA9, 0x20, 0])
        XCTAssertEqual(controller.playback.volume, 0)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        controller.simulateControlLoss()
        XCTAssertNil(controller.playback.volume)
    }

    @MainActor
    func testCancelledQueuedMusicVolumeCannotTransmitWithUnchangedSource() async throws {
        for hasInventory in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: hasInventory ? nil : [])
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.multipoint.supportsInventory, hasInventory)
            XCTAssertTrue(controller.canControlMusicVolume)
            let source = controller.multipoint.selectedSource?.address
            let session = controller.simulatedControlSession
            controller.refreshEqualizer()
            let blocker = try XCTUnwrap(controller.simulatedPendingFrame)
            let change = Task { @MainActor in
                try await controller.performConfirmedSettingChange(.playbackVolume) { controller.setPlaybackVolume(20) }
            }
            for _ in 0..<100 where controller.pendingChanges[.playbackVolume] == nil { await Task.yield() }
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            XCTAssertEqual(controller.simulatedPendingFrame, blocker)
            change.cancel()
            do { try await change.value; XCTFail("Cancelled volume change completed") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.multipoint.selectedSource?.address, source)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    @MainActor
    func testRevokedMusicVolumeIntentCannotTransmitFromCommandOrTransportQueue() throws {
        for deferred in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            let source = controller.multipoint.selectedSource?.address
            let intent = UUID()
            var currentIntent = intent
            if deferred { controller.defersSimulatedWrites = true }
            else { controller.refreshEqualizer() }
            controller.setPlaybackVolume(20) { currentIntent == intent }
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            currentIntent = UUID()
            if deferred {
                controller.completeSimulatedWrite()
                controller.defersSimulatedWrites = false
            } else { acknowledgeSimulatedCommands(controller) }
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.multipoint.selectedSource?.address, source)
            XCTAssertTrue(controller.isReady)
            controller.setPlaybackVolume(21)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 21])
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 21] })
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA9, 0x20, 21])
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.playback.volume, 21)
        }
    }

    @MainActor
    func testDeferredUIVolumeCannotTransmitAfterSourceChangesBeforeItsFirstByte() {
        for selected: UInt8 in [2, 1] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            XCTAssertTrue(controller.canControlMusicVolume)
            controller.defersSimulatedWrites = true
            controller.setPlaybackVolume(20)
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
            if selected == 1 {
                controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
            }
            controller.completeSimulatedWrite()
            controller.defersSimulatedWrites = false
            for _ in 0..<20 { controller.completeSimulatedWrite() }
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.multipoint.selectedSource?.address, selected == 1 ? "02:00:00:00:00:01" : "02:00:00:00:00:02")
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    @MainActor
    func testCancellationAfterMusicVolumeTransmissionRetainsConfirmation() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        var isCurrent = true
        let change = Task { @MainActor in
            try await controller.performConfirmedSettingChange(.playbackVolume) {
                controller.setPlaybackVolume(20) { isCurrent }
            }
        }
        for _ in 0..<100 where controller.pendingChanges[.playbackVolume] == nil { await Task.yield() }
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA8, 0x20, 20] })
        isCurrent = false
        change.cancel()
        do { try await change.value; XCTFail("Cancelled volume change completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA9, 0x20, 20])
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.playback.volume, 20)
        XCTAssertTrue(controller.isReady)
    }

    @MainActor
    func testCallVolumeUsesItsOwnRangeAndMatchingT1ReportedConfirmation() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0xA5, 1, 0, 0, 1])
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertTrue(controller.canControlCallVolume)
        controller.setCallVolume(16)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setCallVolume(0)
        XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0C)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x21, 0])
        XCTAssertEqual(controller.playback.callVolume, 7)
        XCTAssertFalse(controller.canControlCallVolume)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.pendingChanges[.callVolume], [0])
        for (type, payload): (UInt8, [UInt8]) in [(0x0E, [0xA9, 0x21, 0]), (0x0C, [0xA9, 0x20, 0]),
                                                 (0x0C, [0xA7, 0x21, 0, 0]), (0x0C, [0xA9, 0x21, 16]),
                                                 (0x0C, [0xA9, 0x21, 255]), (0x0C, [0xA7, 0x21, 1])] {
            controller.simulateProtocolMessage(payload, type: type)
            XCTAssertEqual(controller.pendingChanges[.callVolume], [0])
        }
        controller.simulateProtocolMessage([0xA9, 0x21, 0])
        XCTAssertEqual(controller.playback.callVolume, 0)
        XCTAssertNil(controller.pendingChanges[.callVolume])
        XCTAssertTrue(controller.canControlCallVolume)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xA8 }.map(\.payload), [[0xA8, 0x21, 0]])
        controller.simulateControlLoss()
        XCTAssertNil(controller.playback.callVolume)
        XCTAssertNil(controller.playback.callVolumeRange)
    }

    @MainActor
    func testQueuedCallVolumeAbortsWhenCallEndsOrReportedRangeShrinks() {
        for change: [UInt8] in [[0xA5, 1, 0, 2, 0], [0xA1, 1, 31, 8]] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateProtocolMessage([0xA5, 1, 0, 0, 1])
            controller.refreshEqualizer()
            controller.setCallVolume(15)
            XCTAssertEqual(controller.pendingChanges[.callVolume], [15])
            controller.simulateProtocolMessage(change)
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA8 })
            XCTAssertEqual(controller.lastErrorMessage, "Playback controls changed while waiting. Reconnect the headphones and try again.")
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA8 })
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testOldSourceCapabilityAndCallVolumeCannotInitializeTheNewSource() {
        for waitingForCallVolume in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
            acknowledgeSimulatedCommands(controller)
            XCTAssertNil(controller.playback.musicVolumeRange)
            XCTAssertNil(controller.playback.callVolumeRange)
            if waitingForCallVolume {
                for reply in initialPlaybackReplies(generation: .v2).dropLast() {
                    controller.simulateProtocolMessage(reply)
                    acknowledgeSimulatedCommands(controller)
        }
        }
        controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
        controller.simulateProtocolMessage(waitingForCallVolume ? [0xA7, 0x21, 9] : [0xA1, 1, 31, 16])
        XCTAssertNil(controller.playback.musicVolumeRange)
        XCTAssertNil(controller.playback.callVolumeRange)
        XCTAssertNil(controller.playback.callVolume)
        controller.simulateProtocolMessage([0xA9, 0x21, 9])
        XCTAssertNil(controller.playback.callVolume)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA0, 1] }.count, 2)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x21] }.count, waitingForCallVolume ? 1 : 0)
        for reply: [UInt8] in [[0xA1, 1, 41, 11], [0xA3, 1, 0, 2, 0], [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0],
                               [0xA7, 0x20, 12], [0xA7, 0x21, 4]] {
            controller.simulateProtocolMessage(reply)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...40)
        XCTAssertEqual(controller.playback.callVolumeRange, 0...10)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA6, 0x21] }.count, waitingForCallVolume ? 2 : 1)
        XCTAssertEqual(controller.playback.callVolume, 4)
      }
    }

    @MainActor
    func testQueuedActionsAndVolumeAbortWhenACallStartsWithoutReplay() {
        for volume in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.refreshEqualizer()
            if volume { controller.setPlaybackVolume(15) } else { controller.controlPlayback(.next) }
            controller.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
            acknowledgeSimulatedCommands(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA4 || $0.payload.first == 0xA8 })
            XCTAssertEqual(controller.lastErrorMessage, "Playback controls changed while waiting. Reconnect the headphones and try again.")
            XCTAssertNil(controller.pendingPlaybackCommand)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            XCTAssertNil(controller.pendingPlaybackCommand)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
    }

    @MainActor
    func testSourceChangeClearsPlaybackAndRequestsFreshStateWithoutConfirmingOldVolume() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0xA9, 1] + name("Mac track") + name("Album") + name("Artist") + name(""))
        controller.setPlaybackVolume(20)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        XCTAssertTrue(controller.playback.isSupported)
        XCTAssertNil(controller.playback.state)
        XCTAssertNil(controller.playback.volume)
        XCTAssertNil(controller.playback.track)
        XCTAssertFalse(controller.canControlPlayback)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload == [0xA0, 1] })
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA2 || $0.payload.first == 0xA6 })
        controller.simulateProtocolMessage([0xA9, 0x20, 20])
        XCTAssertNotNil(controller.pendingChanges[.playbackVolume])
        XCTAssertFalse(controller.canControlPlayback)
        controller.simulateControlLoss()
    }

    @MainActor
    func testSourceChangeDuringConnectionTransitionDefersPlaybackQueries() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setConnectionMode(.lowLatency)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        XCTAssertNil(controller.playback.state)
        XCTAssertFalse(controller.canControlPlayback)
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0xA2 || $0.payload.first == 0xA6 })
        controller.simulateControlLoss()
    }

    @MainActor
    func testOldSourceRepliesCannotRestorePlaybackBeforeReplacementReadsTransmit() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        XCTAssertNil(controller.playback.state)
        let stale: [UInt8] = [0xA3, 1, 0, 1, 0]
        controller.simulateProtocolMessage(stale)
        XCTAssertNil(controller.playback.state)
        controller.simulateProtocolMessage(stale)
        XCTAssertNil(controller.playback.state)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertNil(controller.playback.state)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA2, 1] }.count, 1)
        controller.simulateProtocolMessage([0xA1, 1, 31, 16])
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA2, 1] }.count, 2)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        XCTAssertEqual(controller.playback.state, .paused)
        let staleTrack: [UInt8] = [0xA7, 1] + name("Mac track") + name("Album") + name("Artist") + name("")
        controller.simulateProtocolMessage(staleTrack)
        XCTAssertNil(controller.playback.track)
        acknowledgeSimulatedCommands(controller)
        let freshTrack: [UInt8] = [0xA7, 1] + name("Phone track") + name("Album") + name("Artist") + name("")
        controller.simulateProtocolMessage(freshTrack)
        XCTAssertEqual(controller.playback.track?.title, "Phone track")
        controller.simulateControlLoss()
    }

    @MainActor
    func testSameLinkHandshakeWaitsForOldPlaybackReplies() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.setConnectionMode(.lowLatency)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xE9, 5, 2, 1])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting)
        controller.simulateProtocolMessage([0xA3, 1, 0, 1, 0])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.simulateProtocolMessage([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(controller.connectionTransition?.phase, .verifying)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        XCTAssertNil(controller.playbackReadError)
        controller.simulateControlLoss()
    }

    @MainActor
    func testMultipointRecoveryClosesLinkWithUnansweredPlaybackReads() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        controller.setMultipointEnabled(false)
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        XCTAssertFalse(controller.canCheckMultipointChange)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xD6, 0xD2])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xD7, 0xD2, 0, 0])
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.canCheckMultipointChange)
        controller.checkMultipointChange()
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertFalse(controller.isReady)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertNil(controller.playbackReadError)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testOptionalPlaybackTimeoutPreservesMusicVolumeAndFreshLDACReadback() async {
        for missing: [UInt8] in [[0xA6, 1], [0xA6, 0x21]] {
            let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
            defer { controller.simulateControlLoss() }
            let replies: [[UInt8]] = [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0],
                                     [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]]
            for payload in replies {
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            for payload in replies.dropFirst() {
                if controller.playback.queryPayload(for: payload) == missing { break }
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertTrue(controller.canControlMusicVolume)
            controller.simulatePlaybackReadTimeout(missing)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNotNil(controller.playbackReadError)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canControlPlayback)
            XCTAssertTrue(controller.canControlMusicVolume)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            let session = controller.simulatedControlSession
            let frames = controller.simulatedTransmittedFrames
            XCTAssertFalse(controller.recoverMusicVolumeIfNeeded())
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
            let previousReadback = controller.musicVolumeReadbackID
            #endif
            XCTAssertTrue(controller.refreshMusicVolume())
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA7, 0x20, 12])
            XCTAssertNotNil(controller.playbackReadError)
            XCTAssertTrue(controller.canControlMusicVolume)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            let readback = controller.musicVolumeReadbackID
            XCTAssertNotEqual(readback, previousReadback)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            #endif
            controller.setPlaybackVolume(20)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 20])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xA9, 0x20, 20])
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            XCTAssertEqual(controller.playback.volume, 20)
            for payload in replies where controller.playback.queryPayload(for: payload) == missing {
                controller.simulateProtocolMessage(payload)
            }
            XCTAssertNil(controller.playbackReadError)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertEqual(controller.musicVolumeReadbackID, readback)
            #endif
        }
    }

    @MainActor
    func testPlaybackVolumeTimeoutsOnlyBlockTheirOwnVolumeControl() async {
        for call in [false, true] {
            for missing: [UInt8] in [[0xA6, 0x20], [0xA6, 0x21]] {
                let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
                defer { controller.simulateControlLoss() }
                for payload: [UInt8] in [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, call ? 1 : 0],
                                        [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]] {
                    controller.simulateProtocolMessage(payload)
                    acknowledgeSimulatedCommands(controller)
            }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            for payload: [UInt8] in [[0xA3, 1, 0, 2, call ? 1 : 0], [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0],
                                    [0xA7, 0x20, 12], [0xA7, 0x21, 7]] {
                if controller.playback.queryPayload(for: payload) == missing { break }
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
            controller.simulatePlaybackReadTimeout(missing)
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNotNil(controller.playbackReadError)
            XCTAssertEqual(controller.canControlMusicVolume, !call && missing != [0xA6, 0x20])
            XCTAssertEqual(controller.canControlCallVolume, call && missing != [0xA6, 0x21])
            XCTAssertEqual(controller.canControlPlayback, !call)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertEqual(controller.hasCurrentMusicVolumeControl, !call && missing != [0xA6, 0x20])
            XCTAssertEqual(controller.hasFreshMusicVolumeReadback, !call && missing != [0xA6, 0x20])
            #endif
          }
        }
    }

    @MainActor
    func testPlaybackStatusTimeoutAndCallStateStillBlockMusicVolume() async {
        let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        for state: UInt8 in [1, 2, 0xFF] {
            controller.simulateProtocolMessage([0xA5, 1, 0, 2, state])
            XCTAssertFalse(controller.canControlMusicVolume)
            XCTAssertFalse(controller.canControlPlayback)
            XCTAssertEqual(controller.canControlCallVolume, state == 1)
        }
        controller.simulateProtocolMessage([0xA5, 1, 0, 2, 0])
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 12])
        controller.simulatePlaybackReadTimeout([0xA2, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canControlCallVolume)
        let frames = controller.simulatedTransmittedFrames
        controller.setPlaybackVolume(20)
        XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        #endif
    }

    @MainActor
    func testPlaybackCapabilityTimeoutBlocksControlsWithCachedVolumeRange() async {
        let controller = makeNoNoiseController(generation: .v2, functions: [0xA1])
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.simulateProtocolMessage([0xA1, 1, 31, 16])
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA3, 1, 0, 2, 0], [0xA7, 0x20, 12],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
        }
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
        XCTAssertTrue(controller.canControlMusicVolume)
        controller.simulatePlaybackReadTimeout([0xA0, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canControlCallVolume)
    }

    @MainActor
    func testMissingPlaybackReadStopsControlsWithoutRepeatedQueriesAndLateReplyRecovers() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.controlPlayback(.play)
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(8_100))
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xA2, 1] }.count, 1)
        controller.simulateProtocolMessage([0xA3, 1, 0, 1, 0])
        XCTAssertNotNil(controller.playbackReadError)
        XCTAssertTrue(controller.canControlPlayback)
        controller.simulateProtocolMessage([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0])
        XCTAssertNil(controller.playbackReadError)
        XCTAssertTrue(controller.canControlPlayback)
        controller.simulateControlLoss()
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testModernLDACSettingsRefreshPreservesSessionAndRefreshesSourceAfterOptionalExpiry() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        controller.simulateEqualizerReadTimeout()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        let session = controller.simulatedControlSession
        let readback = controller.musicVolumeReadbackID
        let transmitted = controller.simulatedTransmittedFrames.count
        controller.requestCurrentSettings()
        acknowledgeSimulatedCommands(controller)
        let frames = Array(controller.simulatedTransmittedFrames.dropFirst(transmitted))
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(frames.contains { $0.type == 0x0C && $0.payload == [0xA2, 1] })
        XCTAssertFalse(frames.contains { $0.type == 0x0C && $0.payload == [0xA6, 0x20] })
        XCTAssertTrue(frames.contains { $0.type == 0x0E && $0.payload == [0x36, 2] })
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0x37] + sourceInventory(selected: 2).dropFirst(), type: 0x0E)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: "02:00:00:00:00:01"))
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA1, 1, 31, 16])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        controller.simulateProtocolMessage([0xA7, 0x20, 14])
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA3, 1, 0, 2, 0], [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0],
                                [0xA7, 0x20, 14], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.simulatedTransmittedFrames.dropFirst(transmitted).contains { $0.type == 0x0C && $0.payload == [0xA6, 0x20] })
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: "02:00:00:00:00:01"))
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.refresh()
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
    }

    @MainActor
    func testNativeLDACSourceWaitsForCurrentCapabilitiesAndLocalInventory() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        var addressLookups = 0
        func localAddress() -> String? {
            addressLookups += 1
            return "02:00:00:00:00:01"
        }
        XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 1)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0x05, 1, 10] + Array("WF-1000XM5".utf8), [0x05, 3, 0, 1],
                                [0x07, 0, 2, 0x6B, 0, 0xA1, 0],
                                [0x61, 0x17, 2, 0, 1, 20, 1, 1, 1, 20, 1],
                                [0x63, 0x17, 0], [0x67, 0x17, 1, 1, 0, 0, 10]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        for payload: [UInt8] in [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 4], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertFalse(controller.multipoint.supportsInventory)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x06, 0] }.count, 1)
        controller.simulateProtocolMessage([0x07, 0, 1, 0x32, 0], type: 0x0E)
        XCTAssertTrue(controller.multipoint.supportsInventory)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 1)
        controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
        XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 2)
        controller.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
        XCTAssertTrue(controller.multipoint.supportsInventory)
        XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 3)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: "02:00:00:00:00:02"))
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: nil))
        controller.simulateProtocolMessage([0x39, 2, 1], type: 0x0E)
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 3)
        controller.simulateControlLoss()
        XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress()))
        XCTAssertEqual(addressLookups, 3)
    }

    @MainActor
    func testNativeLDACSourceAdmitsConfirmedEmptyOrAbsentCapabilityTable() {
        for advertised in [true, false] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            var addressLookups = 0
            func localAddress() -> String? {
                addressLookups += 1
                return nil
            }
            let protocolReply: [UInt8] = [0x01, 0, 3, 0, 0x30, 0x18, 0, advertised ? 0 : 1]
            controller.simulateProtocolMessage(protocolReply, beginConnection: true)
            XCTAssertEqual(controller.hasCurrentMusicSourceContext(for: localAddress()), !advertised)
            XCTAssertEqual(addressLookups, 0)
            acknowledgeSimulatedCommands(controller)
            for payload: [UInt8] in [[0x05, 1, 10] + Array("WF-1000XM5".utf8), [0x05, 3, 0, 1], [0x07, 0, 0]] {
                controller.simulateProtocolMessage(payload)
            }
            acknowledgeSimulatedCommands(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x06, 0] }.count, advertised ? 1 : 0)
            controller.simulateProtocolMessage([0x07, 0, 1], type: 0x0E)
            XCTAssertEqual(controller.hasCurrentMusicSourceContext(for: localAddress()), !advertised)
            XCTAssertEqual(addressLookups, 0)
            controller.simulateProtocolMessage([0x07, 0, 0], type: 0x0E)
            XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
            XCTAssertEqual(addressLookups, 0)
            controller.simulateProtocolMessage([0x07, 0, 1, 0x32, 0], type: 0x0E)
            XCTAssertTrue(controller.supportedFunctions2.isEmpty)
            XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress()))
            XCTAssertEqual(addressLookups, 0)
            controller.simulateProtocolMessage(protocolReply, beginConnection: true)
            XCTAssertEqual(controller.hasCurrentMusicSourceContext(for: localAddress()), !advertised)
            XCTAssertEqual(addressLookups, 0)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testNativeLDACVolumeContextSurvivesPendingWriteAndRejectsSourceOrCallLoss() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage(sourceInventory(selected: 2), type: 0x0E)
        acknowledgeSimulatedCommands(controller)
        for payload: [UInt8] in [[0xA1, 1, 41, 16], [0xA3, 1, 0, 2, 0],
                                [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0], [0xA7, 0x20, 12], [0xA7, 0x21, 7]] {
            controller.simulateProtocolMessage(payload)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertNotNil(controller.musicVolumeReadbackID)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        XCTAssertTrue(controller.beginHeadGesturePractice())
        let practice = try XCTUnwrap(controller.headGesturePracticeTransition?.id)
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        XCTAssertFalse(controller.canPerformConfirmedSettingChange(.playbackVolume))
        let writes = controller.simulatedTransmittedFrames
        controller.setPlaybackVolume(19)
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage([0xF3, 0x10, 0])
        acknowledgeSimulatedCommands(controller)
        controller.cancelHeadGesturePractice(id: practice)
        controller.dismissHeadGesturePractice(id: practice)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        let readback = controller.musicVolumeReadbackID
        controller.setPlaybackVolume(20)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 20])
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        controller.simulateProtocolMessage([0xA9, 0x20, 20])
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        controller.refresh()
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 20])
        XCTAssertEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0])
        controller.simulateProtocolMessage([0xA7, 0x20, 20])
        XCTAssertNotEqual(controller.musicVolumeReadbackID, readback)
        XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
        controller.simulateProtocolMessage([0xA7, 0x21, 7])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 1])
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage([0xA5, 1, 0, 1, 0])
        XCTAssertTrue(controller.hasCurrentMusicVolumeControl)
        controller.simulateProtocolMessage(sourceInventory(selected: 1), type: 0x0E)
        XCTAssertFalse(controller.hasCurrentMusicVolumeControl)
        controller.simulateControlLoss()
        XCTAssertNil(controller.musicVolumeReadbackID)
    }

    func testNativeLDACAdmissionRejectsAliveButHiddenOrIneligibleOutput() {
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 1, defaultOutput: 0, systemOutput: 0))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 1, defaultOutput: 1, systemOutput: 1))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 0, defaultOutput: 0, systemOutput: 1))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 1, hidden: 0, defaultOutput: 1, systemOutput: 0))
        XCTAssertFalse(LDACNativeOutput.canSelect(alive: 0, hidden: 0, defaultOutput: 1, systemOutput: 1))
        XCTAssertTrue(LDACNativeOutput.canSelect(alive: 1, hidden: 0, defaultOutput: 1, systemOutput: 1))
    }

    func testNativeLDACControlsUseReportedRangeAndOnlyRestoreOwnedRoutes() {
        let controls = LDACNativeVolume(scalar: 0.5, muted: false)
        XCTAssertEqual(controls.volume(in: 0...40), 20)
        XCTAssertEqual(controls.volume(in: 0...254), 127)
        XCTAssertEqual(controls.volume(in: 0...0), 0)
        XCTAssertEqual(LDACNativeVolume.scalar(for: 12, range: 0...40), 0.3, accuracy: 0.00001)
        XCTAssertEqual(LDACNativeVolume.scalar(for: 0, range: 0...0), 0)
        XCTAssertTrue(LDACNativeVolume.shouldRestore(currentUID: LDACNativeOutput.uid, savedUID: "Sony-native"))
        XCTAssertFalse(LDACNativeVolume.shouldRestore(currentUID: "New-user-output", savedUID: "Sony-native"))
        XCTAssertFalse(LDACNativeVolume.shouldRestore(currentUID: LDACNativeOutput.uid, savedUID: LDACNativeOutput.uid))
    }

    func testNativeLDACTransfersVolumeAndMuteOnlyForTheTargetBluetoothOutput() {
        let address = "02:53:4F:4E:59:01"
        for uid in [address, "02-53-4f-4e-59-01", address + ":output"] {
            XCTAssertTrue(LDACNativeOutput.canTransferControls(uid: uid, transport: kAudioDeviceTransportTypeBluetooth, address: address))
        }
        for uid in ["BuiltInSpeakerDevice", "USB-DAC", "02:53:4F:4E:59:02:output", address + "0", "", "invalid-address!!"] {
            XCTAssertFalse(LDACNativeOutput.canTransferControls(uid: uid, transport: kAudioDeviceTransportTypeBluetooth, address: address))
        }
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetoothLE,
                          kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate] {
            XCTAssertFalse(LDACNativeOutput.canTransferControls(uid: address, transport: transport, address: address))
        }
        XCTAssertFalse(LDACNativeOutput.canTransferControls(uid: address, transport: kAudioDeviceTransportTypeBluetooth, address: ""))
    }
    #endif

    @MainActor
    private func makeNoNoiseController(generation: SonyProtocolInfo.Generation, functions: [UInt8]) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4")
        let protocolPayload: [UInt8] = generation == .v1 ? [0x01, 0, 2, 0x10] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 1]
        controller.simulateProtocolMessage(protocolPayload, beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let payload = [0x07, 0, UInt8(functions.count)] + (generation == .v1 ? functions : functions.flatMap { [$0, 0] })
        controller.simulateProtocolMessage(payload)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        XCTAssertEqual(controller.protocolInformation?.generation, generation)
        XCTAssertTrue(controller.availableNoiseModes.isEmpty)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func initialPlaybackReplies(generation: SonyProtocolInfo.Generation) -> [[UInt8]] {
        generation == .v1 ? [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]]
            : [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0], [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0],
               [0xA7, 0x20, 12], [0xA7, 0x21, 7]]
    }

    @MainActor
    private func makeLegacyPlaybackController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4")
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x07, 0, 1, 0xA1])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func sourceInventory(selected: UInt8) -> [UInt8] {
        let entries: [UInt8] = [("02:00:00:00:00:01", UInt8(1), "MacBook Pro"), ("02:00:00:00:00:02", UInt8(2), "Phone")]
            .flatMap { address, id, title in Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(title.utf8.count)] + Array(title.utf8) }
        return [0x39, 2, 2] + entries + [selected]
    }

    private func name(_ value: String, status: UInt8 = 2) -> [UInt8] {
        [status, UInt8(value.utf8.count)] + Array(value.utf8)
    }
}
