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

    func testLegacyVolumeDoesNotGrantTransportCallOrMetadataControls() {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        playback.update([0xA3, 1, 0, 1])
        playback.update([0xA7, 1, 0x20, 12])
        for controlType: UInt8 in [0, 1, 255] {
            for metadataType: UInt8 in [0, 1, 255] {
                XCTAssertTrue(playback.update([0xA1, 1, 31, controlType, metadataType]))
                XCTAssertTrue(playback.canControlMusicVolume)
                XCTAssertFalse(playback.canControl)
                XCTAssertFalse(playback.canControlCallVolume)
                XCTAssertNil(playback.musicCallStatus)
                XCTAssertNil(playback.callVolumeRange)
                XCTAssertNil(playback.callVolume)
                XCTAssertNil(playback.track)
                XCTAssertNil(playback.callVolumePayload(0))
                for command in [SonyPlaybackCommand.play, .pause, .next, .previous] {
                    XCTAssertNil(playback.commandPayload(command))
                }
            }
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
}
