import XCTest
@testable import Acouplet

final class SonyLegacyPlaybackTests: XCTestCase {
    func testLegacyVolumeUsesTheAdvertisedPlaybackInquiry() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        XCTAssertEqual(playback.generation, .v1)
        XCTAssertEqual(playback.queryPayloads, [[0xA0, 1], [0xA2, 1], [0xA6, 1, 0x20]])
        XCTAssertFalse(playback.hasReceivedCapabilities)
        XCTAssertTrue(playback.update([0xA7, 1, 0x20, 12]))
        XCTAssertNil(playback.volume)
        XCTAssertNil(playback.volumePayload(20))
        XCTAssertTrue(playback.update([0xA1, 1, 31, 1, 1]))
        XCTAssertTrue(playback.hasReceivedCapabilities)
        XCTAssertEqual(playback.volume, 12)
        XCTAssertNil(playback.volumePayload(20))
        XCTAssertTrue(playback.update([0xA3, 1, 0, 2]))
        XCTAssertEqual(playback.state, .paused)
        XCTAssertTrue(playback.canControlMusicVolume)
        for volume in 0...30 { XCTAssertEqual(playback.volumePayload(volume), [0xA8, 1, 0x20, UInt8(volume)]) }
        for volume in [Int.min, -1, 31, Int.max] { XCTAssertNil(playback.volumePayload(volume)) }
        XCTAssertTrue(playback.update([0xA9, 1, 0x20, 20]))
        XCTAssertEqual(playback.volume, 20)
    }

    func testLegacyReadKeysRetainTheVolumeSubtype() {
        let playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        XCTAssertEqual(playback.capabilityQueryPayload, [0xA0, 1])
        XCTAssertEqual(playback.statusQueryPayload, [0xA2, 1])
        XCTAssertEqual(playback.musicVolumeQueryPayload, [0xA6, 1, 0x20])
        XCTAssertEqual(playback.queryPayload(for: [0xA1, 1, 31, 1, 1]), [0xA0, 1])
        for opcode: UInt8 in [0xA3, 0xA5] {
            XCTAssertEqual(playback.queryPayload(for: [opcode, 1, 0, 2]), [0xA2, 1])
        }
        XCTAssertEqual(playback.queryPayload(for: [0xA6, 1, 0x20]), [0xA6, 1, 0x20])
        for opcode: UInt8 in [0xA7, 0xA8, 0xA9] {
            XCTAssertEqual(playback.queryPayload(for: [opcode, 1, 0x20, 12]), [0xA6, 1, 0x20])
        }
        for invalid: [UInt8] in [[], [0xA7], [0xA1, 2], [0xA3, 2, 0, 2], [0xA6, 1],
                                [0xA6, 0x20], [0xA6, 1, 0x20, 0], [0xA6, 1, 0x21], [0xA6, 2, 0x20],
                                [0xA7, 0x20, 12], [0xA7, 1, 0x20], [0xA7, 1, 0x20, 12, 0],
                                [0xA9, 1, 0x21, 12], [0xA9, 2, 0x20, 12], [0xA4, 1, 0, 7]] {
            XCTAssertNil(playback.queryPayload(for: invalid))
        }
    }

    func testLegacyVolumeCountsIncludeZeroOneAndTheUnsignedMaximum() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        playback.update([0xA3, 1, 0, 2])
        playback.update([0xA7, 1, 0x20, 0])
        XCTAssertTrue(playback.update([0xA1, 1, 0, 1, 1]))
        XCTAssertTrue(playback.hasReceivedCapabilities)
        XCTAssertNil(playback.musicVolumeRange)
        XCTAssertNil(playback.volume)
        XCTAssertNil(playback.volumePayload(0))
        XCTAssertTrue(playback.update([0xA1, 1, 1, 1, 1]))
        XCTAssertEqual(playback.musicVolumeRange, 0...0)
        XCTAssertEqual(playback.volume, 0)
        XCTAssertEqual(playback.volumePayload(0), [0xA8, 1, 0x20, 0])
        XCTAssertNil(playback.volumePayload(1))
        XCTAssertTrue(playback.update([0xA1, 1, 255, 1, 1]))
        XCTAssertEqual(playback.musicVolumeRange, 0...254)
        XCTAssertTrue(playback.update([0xA9, 1, 0x20, 254]))
        XCTAssertEqual(playback.volume, 254)
        XCTAssertEqual(playback.volumePayload(254), [0xA8, 1, 0x20, 254])
        XCTAssertNil(playback.volumePayload(255))
        XCTAssertTrue(playback.update([0xA9, 1, 0x20, 255]))
        XCTAssertNil(playback.volume)
        XCTAssertFalse(playback.canControlMusicVolume)
        XCTAssertNil(playback.volumePayload(0))
        playback.update([0xA7, 1, 0x20, 20])
        XCTAssertTrue(playback.update([0xA1, 1, 20, 1, 1]))
        XCTAssertEqual(playback.musicVolumeRange, 0...19)
        XCTAssertNil(playback.volume)
        playback.update([0xA9, 1, 0x20, 19])
        XCTAssertTrue(playback.canControlMusicVolume)
        XCTAssertTrue(playback.update([0xA1, 1, 0, 1, 1]))
        XCTAssertNil(playback.musicVolumeRange)
        XCTAssertNil(playback.volume)
        XCTAssertFalse(playback.canControlMusicVolume)
        XCTAssertNil(playback.volumePayload(0))
    }

    func testLegacyAvailabilityControlsVolumeIndependentlyOfPlaybackState() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        playback.update([0xA1, 1, 31, 1, 1])
        playback.update([0xA7, 1, 0x20, 12])
        for state: UInt8 in [0, 1, 2, 3, 255] {
            XCTAssertTrue(playback.update([0xA5, 1, 0, state]))
            XCTAssertEqual(playback.state, SonyPlaybackState(rawValue: state))
            XCTAssertEqual(playback.available, true)
            XCTAssertTrue(playback.canControlMusicVolume)
            XCTAssertEqual(playback.volumePayload(20), [0xA8, 1, 0x20, 20])
            XCTAssertNil(playback.musicCallStatus)
            for availability: UInt8 in [1, 2, 255] {
                XCTAssertTrue(playback.update([0xA5, 1, availability, state]))
                XCTAssertEqual(playback.available, availability == 1 ? false : nil)
                XCTAssertFalse(playback.canControlMusicVolume)
                XCTAssertNil(playback.volumePayload(20))
            }
        }
    }

    func testLegacyPlaybackCommandsRequireAdvertisedControlTypeAndAvailability() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        let commands: [(SonyPlaybackCommand, UInt8)] = [(.play, 7), (.pause, 1), (.next, 2), (.previous, 3)]
        XCTAssertNil(playback.commandPayload(.play))
        for controlType: UInt8 in [0, 1, 2, 255] {
            XCTAssertTrue(playback.update([0xA1, 1, 0, controlType, 0]))
            XCTAssertEqual(playback.supportsPlaybackCommands, controlType == 1)
            for availability: UInt8 in [0, 1, 255] {
                for state: UInt8 in [0, 1, 2, 3, 255] {
                    XCTAssertTrue(playback.update([0xA5, 1, availability, state]))
                    let enabled = controlType == 1 && availability == 0 && state != 255
                    XCTAssertEqual(playback.canControl, enabled)
                    for (command, value) in commands {
                        XCTAssertEqual(playback.commandPayload(command), enabled ? [0xA4, 1, 0, value] : nil)
                    }
                }
            }
            XCTAssertFalse(playback.canControlMusicVolume)
            XCTAssertFalse(playback.canControlCallVolume)
            XCTAssertNil(playback.callVolumePayload(0))
        }
    }

    func testMalformedAndOtherDialectReportsCannotChangeLegacyState() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        let reports: [[UInt8]] = [[0xA1, 1, 31, 1, 1], [0xA3, 1, 0, 2], [0xA5, 1, 0, 1],
                                 [0xA7, 1, 0x20, 12], [0xA9, 1, 0x20, 20]]
        for report in reports { XCTAssertTrue(playback.update(report)) }
        let prior = playback
        for report in reports {
            for count in 0..<report.count {
                XCTAssertFalse(playback.update(Array(report.prefix(count))))
                XCTAssertEqual(playback, prior)
            }
            XCTAssertFalse(playback.update(report + [0]))
            XCTAssertEqual(playback, prior)
        }
        for invalid: [UInt8] in [[0xA1, 2, 31, 1, 1], [0xA3, 2, 0, 2], [0xA5, 2, 0, 1],
                                [0xA7, 2, 0x20, 12], [0xA9, 1, 0x21, 12], [0xA9, 1, 0xFF, 12],
                                [0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0], [0xA5, 1, 0, 1, 1],
                                [0xA7, 0x20, 12], [0xA9, 0x21, 12], [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0],
                                [0xA6, 1, 0x20], [0xA8, 1, 0x20, 12]] {
            XCTAssertFalse(playback.update(invalid))
            XCTAssertEqual(playback, prior)
        }
    }

    func testLegacyPlaybackRequiresTheAdvertisedFunction() {
        var playback = SonyPlayback(supportedFunctions: [0xA2], generation: .v1)
        XCTAssertFalse(playback.isSupported)
        XCTAssertTrue(playback.queryPayloads.isEmpty)
        for report: [UInt8] in [[0xA1, 1, 31, 1, 1], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]] {
            XCTAssertFalse(playback.update(report))
        }
        XCTAssertFalse(playback.hasReceivedCapabilities)
        XCTAssertNil(playback.volume)
        XCTAssertFalse(playback.canControlMusicVolume)
        XCTAssertNil(playback.volumePayload(0))
    }

    func testLegacyTrackMetadataUsesSeparateCapabilityAndFieldTypes() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        let title: [UInt8] = [0xA7, 1, 0, 2, 3] + Array("曲".utf8)
        playback.update([0xA1, 1, 0, 1, 0])
        playback.update([0xA3, 1, 0, 2])
        XCTAssertFalse(playback.update(title))
        XCTAssertTrue(playback.legacyMetadataQueryPayloads.isEmpty)
        playback.update([0xA1, 1, 0, 0, 1])
        XCTAssertFalse(playback.supportsPlaybackCommands)
        XCTAssertEqual(playback.legacyMetadataQueryPayloads, [[0xA6, 1, 0], [0xA6, 1, 1], [0xA6, 1, 2], [0xA6, 1, 3]])
        XCTAssertEqual(playback.queryPayload(for: title), [0xA6, 1, 0])
        XCTAssertTrue(playback.update(title))
        XCTAssertEqual(playback.track?.title, "曲")
        XCTAssertTrue(playback.update([0xA7, 1, 1, 2, 5] + Array("Album".utf8)))
        XCTAssertEqual(playback.track?.album, "Album")
        XCTAssertTrue(playback.update([0xA7, 1, 0, 1, 0]))
        XCTAssertNil(playback.track?.title)
        XCTAssertEqual(playback.track?.album, "Album")
        for invalid in [[UInt8(0xA7), 1, 0, 2, 2, 0x41], [0xA7, 1, 0, 2, 1, 0xFF],
                        [0xA7, 1, 0x10, 2, 1, 0x41], [0xA9, 1, 0, 2, 1, 0x41]] {
            XCTAssertFalse(playback.update(invalid))
        }
        playback.update([0xA5, 1, 0, 3])
        XCTAssertNil(playback.track)
        XCTAssertFalse(playback.canReadLegacyMetadata)
        XCTAssertTrue(playback.update(title))
        XCTAssertNil(playback.track)
    }
}

@MainActor
final class SonyLegacyPlaybackOrderTests: XCTestCase {
    func testStartupRequestsPlaybackBeforeLegacyIndicatorsAndSoundEffects() {
        for replyFirst in [false, true] {
            let controller = beginDiscovery()
            defer { controller.simulateControlLoss() }
            XCTAssertFalse(controller.playback.hasReceivedCapabilities)
            XCTAssertFalse(controller.canControlMusicVolume)
            completeCapabilities(controller, replyFirst: replyFirst)
            XCTAssertEqual(orderedQueries(controller), capabilityQueries)
            completeReads(controller, replyFirst: replyFirst, volume: 12)
            XCTAssertEqual(orderedQueries(controller), capabilityQueries + [[0xA2, 1]] + optionalQueries + [[0xA6, 1, 0x20]])
            XCTAssertTrue(controller.playback.hasReceivedCapabilities)
            XCTAssertTrue(controller.canControlMusicVolume)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            #endif
            XCTAssertEqual(controller.playback.musicVolumeRange, 0...30)
            XCTAssertEqual(controller.playback.state, .paused)
            XCTAssertEqual(controller.playback.volume, 12)
            XCTAssertTrue(controller.canSetDSEE)
            XCTAssertTrue(controller.legacySurround.canSet)
            XCTAssertTrue(controller.legacySoundPosition.canSet)
        }
    }

    func testRefreshRequestsPlaybackBeforeLegacyIndicatorsAndSoundEffects() {
        for replyFirst in [false, true] {
            let controller = beginDiscovery()
            defer { controller.simulateControlLoss() }
            completeCapabilities(controller, replyFirst: replyFirst)
            completeReads(controller, replyFirst: replyFirst, volume: 12)
            let first = orderedQueries(controller).count
            let session = controller.simulatedControlSession
            controller.requestCurrentSettings()
            completeReads(controller, replyFirst: replyFirst, volume: 18)
            XCTAssertEqual(Array(orderedQueries(controller).dropFirst(first)),
                           [[0xA2, 1], [0x18, 0], [0x14, 0], [0x46, 1], [0x46, 2], [0xA6, 1, 0x20]])
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canControlMusicVolume)
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            #endif
            XCTAssertEqual(controller.playback.volume, 18)
        }
    }

    private func beginDiscovery() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 0x40, 0x10], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        let name = Array("WH-1000XM3".utf8)
        controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
        controller.simulateProtocolMessage([0x05, 3, 0x20, 0])
        controller.simulateProtocolMessage([0x07, 0, 8, 0xA1, 0xE1, 0xE2, 0xF4, 0x41, 0x42, 0x12, 0x13])
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.protocolInformation?.generation, .v1)
        XCTAssertEqual(controller.protocolInformation?.version, 0x4010)
        return controller
    }

    private func completeCapabilities(_ controller: SonyHeadphonesController, replyFirst: Bool) {
        let replies: [[UInt8]] = [[0x03, 0, 1, 3, 0x58, 0x4D, 0x33], [0xA1, 1, 31, 1, 0],
                                 [0xE1, 1, 0], [0xE1, 2, 0, 0], [0xF1, 4, 2, 0x10, 0x11]]
        for (query, reply) in zip(capabilityQueries, replies) {
            guard let frame = controller.simulatedPendingFrame else {
                XCTFail("Missing capability query: \(query)")
                return
            }
            XCTAssertEqual(frame.payload, query)
            XCTAssertFalse(controller.isReady)
            if replyFirst {
                controller.simulateProtocolMessage(reply)
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
                acknowledge(frame, on: controller)
            } else {
                acknowledge(frame, on: controller)
                XCTAssertNil(controller.simulatedPendingFrame)
                controller.simulateProtocolMessage(reply)
            }
        }
        XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
        XCTAssertTrue(controller.isReady)
    }

    private func completeReads(_ controller: SonyHeadphonesController, replyFirst: Bool, volume: UInt8) {
        var delayedReplies: [[UInt8]] = []
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { break }
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains(frame))
            let reply: [UInt8]
            switch frame.payload {
            case [0x94, 1, 0]:
                acknowledge(frame, on: controller)
                continue
            case [0x04, 2]: reply = [0x05, 2, 5] + Array("4.5.2".utf8)
            case [0xA2, 1]: reply = [0xA3, 1, 0, 2]
            case [0xA6, 1, 0x20]:
                let playback = controller.playback
                XCTAssertEqual(delayedReplies.count, controller.legacySurround.status == nil ? 4 : 2)
                for delayed in delayedReplies { controller.simulateProtocolMessage(delayed) }
                delayedReplies = []
                XCTAssertEqual(controller.playback, playback)
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
                reply = [0xA7, 1, 0x20, volume]
            case [0xE2, 2]: reply = [0xE3, 2, 0]
            case [0xE6, 2]: reply = [0xE7, 2, 0, 1]
            case [0xE2, 1]: reply = [0xE3, 1, 0]
            case [0xE6, 1]: reply = [0xE7, 1, 0, 0]
            case [0xF2, 4]: reply = [0xF3, 4, 0]
            case [0xF6, 4]: reply = [0xF7, 4, 1, 0x10, 3]
            case [0x18, 0]: reply = [0x19, 0, 0x20]
            case [0x14, 0]: reply = [0x15, 0, 0, 1]
            case [0x40, 1, 1]: reply = [0x41, 1, 3, 0, 0, 2, 0, 3, 0]
            case [0x40, 2, 1]: reply = [0x41, 2, 1]
            case [0x42, 1], [0x42, 2], [0x46, 1], [0x46, 2]:
                delayedReplies.append([frame.payload[0] + 1, frame.payload[1], 0])
                acknowledge(frame, on: controller)
                continue
            default:
                XCTFail("Unexpected query: \(frame.payload)")
                return
            }
            if replyFirst {
                controller.simulateProtocolMessage(reply)
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
                acknowledge(frame, on: controller)
            } else {
                acknowledge(frame, on: controller)
                controller.simulateProtocolMessage(reply)
            }
        }
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(delayedReplies.isEmpty)
    }

    private func acknowledge(_ frame: SonyFrame, on controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
    }

    private func orderedQueries(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter {
            $0.type == 0x0C && (capabilityQueries.contains($0.payload) || optionalQueries.contains($0.payload) || [0xA2, 0xA6].contains($0.payload.first))
        }.map(\.payload)
    }

    private var capabilityQueries: [[UInt8]] {
        [[0x02, 0], [0xA0, 1], [0xE0, 1], [0xE0, 2], [0xF0, 4]]
    }

    private var optionalQueries: [[UInt8]] {
        [[0x18, 0], [0x14, 0], [0x40, 1, 1], [0x42, 1], [0x46, 1], [0x40, 2, 1], [0x42, 2], [0x46, 2]]
    }
}
