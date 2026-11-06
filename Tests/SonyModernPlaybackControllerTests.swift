import XCTest
@testable import Acouplet

@MainActor
final class SonyModernPlaybackControllerTests: XCTestCase {
    func testNegotiatedVariantsAcquireOnlyTheirAdvertisedPlaybackQueries() {
        let variants: [(UInt8, [[UInt8]])] = [
            (0xA2, [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x30], [0xA6, 0x31]]),
            (0xA3, [[0xA0, 2], [0xA2, 2], [0xA6, 2], [0xA6, 0x20], [0xA6, 0x21]]),
            (0xA4, [[0xA0, 3], [0xA2, 3], [0xA6, 3], [0xA6, 0x20]])
        ]
        for (function, queries) in variants {
            let controller = beginDiscovery(function)
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(playbackQueries(controller), [queries[0]])
            for (index, reply) in initialReplies(function).enumerated() {
                XCTAssertEqual(playbackQueries(controller).last, queries[index])
                controller.simulateProtocolMessage(reply)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertEqual(playbackQueries(controller), queries)
            XCTAssertEqual(controller.supportedFunctions, [function])
            XCTAssertEqual(controller.protocolInformation?.generation, .v2)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canControlPlayback)
            XCTAssertTrue(controller.canControlMusicVolume)
            XCTAssertEqual(controller.playback.volume, 12)
            XCTAssertEqual(controller.playback.track?.title, "Title")
            XCTAssertEqual(controller.playback.track?.album, "Album")
            XCTAssertEqual(controller.playback.track?.artist, "Artist")
            XCTAssertEqual(controller.playback.track?.genre, "Genre")
            XCTAssertNil(controller.simulatedPendingFrame)
        }
    }

    func testMusicAndCallWritesUseSelectedInquiriesAndRequireConfirmedValues() {
        for function: UInt8 in [0xA2, 0xA3, 0xA4] {
            let controller = readyController(function)
            defer { controller.simulateControlLoss() }
            let music: UInt8 = function == 0xA2 ? 0x30 : 0x20
            controller.setPlaybackVolume(20)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, music, 20])
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.playback.volume, 12)
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            controller.simulateProtocolMessage(volumeReply(function, inquiry: music, value: 20))
            XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
            XCTAssertTrue(controller.refreshMusicVolume())
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage(statusReply(function))
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(playbackQueries(controller).last, [0xA6, music])
            controller.simulateProtocolMessage(volumeReply(function, inquiry: music, value: 20))
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.playback.volume, 20)
            XCTAssertNil(controller.pendingChanges[.playbackVolume])
            if function == 0xA4 {
                let frames = controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }
                controller.setCallVolume(9)
                controller.simulateProtocolMessage([0xA9, 0x21, 9])
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }, frames)
                XCTAssertFalse(controller.canControlCallVolume)
                XCTAssertNil(controller.playback.callVolume)
                XCTAssertNil(controller.pendingChanges[.callVolume])
                continue
            }
            controller.simulateProtocolMessage(statusReply(function, notification: true, call: 1))
            let call: UInt8 = function == 0xA2 ? 0x31 : 0x21
            XCTAssertTrue(controller.canControlCallVolume)
            controller.setCallVolume(9)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, call, 9])
            XCTAssertEqual(controller.pendingChanges[.callVolume], [9])
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.playback.callVolume, 7)
            XCTAssertEqual(controller.pendingChanges[.callVolume], [9])
            controller.simulateProtocolMessage(volumeReply(function, inquiry: call, value: 9))
            XCTAssertEqual(controller.pendingChanges[.callVolume], [9])
            controller.simulateProtocolMessage(volumeReply(function, inquiry: call, value: 9, notification: true))
            XCTAssertEqual(controller.playback.callVolume, 9)
            XCTAssertNil(controller.pendingChanges[.callVolume])
        }
    }

    func testA3PlaybackAvailabilityDoesNotDisableMusicVolumeAndACKRefreshesInquiryTwo() {
        let controller = readyController(0xA3)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolMessage([0xA5, 2, 0, 2, 0, 1])
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertTrue(controller.canControlMusicVolume)
        let frames = controller.simulatedTransmittedFrames
        controller.controlPlayback(.play)
        XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
        controller.setPlaybackVolume(18)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA8, 0x20, 18])
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [18])
        controller.simulateProtocolMessage([0xA9, 0x20, 18])
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        controller.simulateProtocolMessage([0xA5, 2, 0, 2, 0, 0])
        XCTAssertTrue(controller.canControlPlayback)
        let first = controller.simulatedTransmittedFrames.count
        controller.controlPlayback(.play)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA4, 1, 0, 7])
        acknowledgeSimulatedCommands(controller)
        let sent = controller.simulatedTransmittedFrames.dropFirst(first).map(\.payload)
        XCTAssertTrue(sent.contains([0xA2, 2]))
        XCTAssertTrue(sent.contains([0xA6, 2]))
        XCTAssertFalse(sent.contains([0xA2, 1]))
        XCTAssertFalse(sent.contains([0xA6, 1]))
    }

    func testMalformedMuteRepliesKeepTheReadAndUnknownMuteClearsReportedState() {
        let controller = readyController(0xA2)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolMessage([0xA9, 0x30, 12, 0])
        XCTAssertEqual(controller.playback.musicMuted, true)
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA3, 1, 0, 2, 0])
        acknowledgeSimulatedCommands(controller)
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        let readback = controller.musicVolumeReadbackID
        #endif
        for payload: [UInt8] in [[0xA7, 0x30, 14], [0xA7, 0x30, 14, 0, 0], [0xA7, 0x20, 14]] {
            controller.simulateProtocolMessage(payload)
            XCTAssertEqual(controller.playback.volume, 12)
            XCTAssertEqual(controller.playback.musicMuted, true)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertEqual(controller.musicVolumeReadbackID, readback)
            XCTAssertFalse(controller.hasFreshMusicVolumeReadback)
            #endif
        }
        controller.simulateProtocolMessage([0xA7, 0x30, 14, 255])
        XCTAssertEqual(controller.playback.volume, 14)
        XCTAssertNil(controller.playback.musicMuted)
        controller.simulateProtocolMessage([0xA9, 0x31, 7, 255])
        XCTAssertNil(controller.playback.callMuted)
        controller.simulateProtocolMessage([0xA9, 0x30, 14, 1])
        XCTAssertEqual(controller.playback.musicMuted, false)
    }

    func testMuteNotificationBeforeWriteTransmissionCannotConfirmTheWrite() {
        let controller = readyController(0xA2)
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setPlaybackVolume(20)
        controller.simulateProtocolMessage([0xA9, 0x30, 20, 0])
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.pendingChanges[.playbackVolume], [20])
        controller.defersSimulatedWrites = false
        controller.simulateProtocolMessage([0xA9, 0x30, 20, 1])
        XCTAssertNil(controller.pendingChanges[.playbackVolume])
        XCTAssertEqual(controller.playback.musicMuted, false)
    }

    func testNewA3AvailabilityNotificationSupersedesAnOlderOwnedStatusReply() {
        let controller = readyController(0xA3)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.refreshMusicVolume())
        acknowledgeSimulatedCommands(controller)
        let previousReads = playbackQueries(controller).filter { $0 == [0xA2, 2] }.count
        controller.simulateProtocolMessage([0xA5, 2, 0, 2, 0, 1])
        controller.simulateProtocolMessage([0xA3, 2, 0, 2, 0, 0])
        XCTAssertEqual(controller.playback.playbackControlAvailable, false)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertTrue(controller.canControlMusicVolume)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(playbackQueries(controller).filter { $0 == [0xA2, 2] }.count, previousReads + 1)
        controller.simulateProtocolMessage([0xA3, 2, 0, 2, 0, 1])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xA7, 0x20, 14])
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertEqual(controller.playback.volume, 14)
        controller.simulateProtocolMessage([0xA5, 2, 0, 2, 0, 0])
        XCTAssertTrue(controller.canControlPlayback)
    }

    private func beginDiscovery(_ function: UInt8) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        XCTAssertFalse(controller.isReady)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let name = Array("WF-1000XM5".utf8)
        controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
        controller.simulateProtocolMessage([0x05, 3, 0, 1])
        controller.simulateProtocolMessage([0x07, 0, 1, function, 0])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.protocolInformation?.generation, .v2)
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        return controller
    }

    private func readyController(_ function: UInt8) -> SonyHeadphonesController {
        let controller = beginDiscovery(function)
        for reply in initialReplies(function) {
            controller.simulateProtocolMessage(reply)
            acknowledgeSimulatedCommands(controller)
        }
        XCTAssertTrue(controller.canControlMusicVolume)
        XCTAssertNil(controller.simulatedPendingFrame)
        return controller
    }

    private func initialReplies(_ function: UInt8) -> [[UInt8]] {
        let inquiry: UInt8 = function == 0xA3 ? 2 : function == 0xA4 ? 3 : 1
        let names: [UInt8] = ["Title", "Album", "Artist", "Genre"].flatMap { [2, UInt8($0.utf8.count)] + Array($0.utf8) }
        let music: UInt8 = function == 0xA2 ? 0x30 : 0x20
        let call: UInt8 = function == 0xA2 ? 0x31 : 0x21
        return [[0xA1, inquiry, 31] + (function == 0xA4 ? [] : [16]), statusReply(function),
                [0xA7, inquiry] + names, volumeReply(function, inquiry: music, value: 12)]
            + (function == 0xA4 ? [] : [volumeReply(function, inquiry: call, value: 7)])
    }

    private func statusReply(_ function: UInt8, notification: Bool = false, call: UInt8 = 0) -> [UInt8] {
        let inquiry: UInt8 = function == 0xA3 ? 2 : function == 0xA4 ? 3 : 1
        return [notification ? 0xA5 : 0xA3, inquiry, 0, 2] + (function == 0xA4 ? [] : [call])
            + (function == 0xA2 ? [] : [0])
    }

    private func volumeReply(_ function: UInt8, inquiry: UInt8, value: UInt8, notification: Bool = false) -> [UInt8] {
        [notification ? 0xA9 : 0xA7, inquiry, value] + (function == 0xA2 ? [1] : [])
    }

    private func playbackQueries(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && [0xA0, 0xA2, 0xA6].contains($0.payload.first) }.map(\.payload)
    }
}
