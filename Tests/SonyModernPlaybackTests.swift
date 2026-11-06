import XCTest
@testable import Acouplet

final class SonyModernPlaybackTests: XCTestCase {
    func testPlaybackVariantsUseTheirCapabilityStatusMetadataAndVolumeInquiries() {
        let expected: [(UInt8, [[UInt8]])] = [
            (0xA1, [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x20], [0xA6, 0x21]]),
            (0xA2, [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x30], [0xA6, 0x31]]),
            (0xA3, [[0xA0, 2], [0xA2, 2], [0xA6, 2], [0xA6, 0x20], [0xA6, 0x21]]),
            (0xA4, [[0xA0, 3], [0xA2, 3], [0xA6, 3], [0xA6, 0x20]])
        ]
        for (function, queries) in expected {
            let playback = SonyPlayback(supportedFunctions: [function])
            XCTAssertTrue(playback.isSupported)
            XCTAssertEqual(playback.queryPayloads, queries)
            for query in queries {
                let response = [query[0] + 1] + query.dropFirst()
                XCTAssertEqual(playback.queryPayload(for: response), query)
            }
            let legacy = SonyPlayback(supportedFunctions: [function], generation: .v1)
            XCTAssertEqual(legacy.isSupported, function == 0xA1)
            XCTAssertFalse(legacy.supportsCallVolume)
            XCTAssertFalse(legacy.supportsMute)
        }
        XCTAssertFalse(SonyPlayback().isSupported)
    }

    func testMixedCapabilitiesPreserveA1ThenUseApplicationFallbackOrder() {
        let all = SonyPlayback(supportedFunctions: [0xA1, 0xA2, 0xA3, 0xA4])
        XCTAssertEqual(all.queryPayloads, SonyPlayback(supportedFunctions: [0xA1]).queryPayloads)
        let mute = SonyPlayback(supportedFunctions: [0xA2, 0xA3, 0xA4])
        XCTAssertEqual(mute.queryPayloads, SonyPlayback(supportedFunctions: [0xA2]).queryPayloads)
        let call = SonyPlayback(supportedFunctions: [0xA3, 0xA4])
        XCTAssertEqual(call.queryPayloads, SonyPlayback(supportedFunctions: [0xA3]).queryPayloads)
    }

    func testMuteVariantReadsMuteStatusAndWritesOnlyVolume() {
        var playback = SonyPlayback(supportedFunctions: [0xA2])
        XCTAssertTrue(playback.update([0xA1, 1, 31, 16]))
        XCTAssertTrue(playback.update([0xA3, 1, 0, 1, 0]))
        XCTAssertTrue(playback.update([0xA7, 0x30, 12, 0]))
        XCTAssertEqual(playback.musicMuted, true)
        XCTAssertEqual(playback.volume, 12)
        XCTAssertEqual(playback.volumePayload(20), [0xA8, 0x30, 20])
        XCTAssertTrue(playback.update([0xA9, 0x30, 13, 1]))
        XCTAssertEqual(playback.musicMuted, false)
        XCTAssertTrue(playback.update([0xA5, 1, 0, 1, 1]))
        XCTAssertTrue(playback.update([0xA7, 0x31, 7, 0]))
        XCTAssertEqual(playback.callMuted, true)
        XCTAssertEqual(playback.callVolumePayload(9), [0xA8, 0x31, 9])
        XCTAssertNil(playback.volumePayload(20))
        XCTAssertNil(playback.callVolumePayload(16))
        XCTAssertNil(playback.callVolumePayload(-1))
        XCTAssertNil(playback.queryPayload(for: [0xA7, 0x20, 12]))
        XCTAssertNil(playback.queryPayload(for: [0xA9, 0x21, 7]))
        let saved = playback
        for payload: [UInt8] in [[0xA7, 0x30, 12], [0xA9, 0x30, 12, 1, 0],
                                [0xA7, 0x20, 12], [0xA9, 0x21, 7]] {
            XCTAssertFalse(playback.update(payload))
            XCTAssertEqual(playback, saved)
        }
        XCTAssertTrue(playback.update([0xA9, 0x31, 7, 2]))
        XCTAssertNil(playback.callMuted)
        XCTAssertEqual(playback.callVolume, 7)
    }

    func testFunctionChangeStatusGatesPlaybackWithoutBlockingVolume() {
        for function: UInt8 in [0xA3, 0xA4] {
            var playback = SonyPlayback(supportedFunctions: [function])
            let inquiry = playback.playbackInquiryType
            XCTAssertTrue(playback.update([0xA1, inquiry, 31] + (function == 0xA3 ? [16] : [])))
            XCTAssertTrue(playback.update([0xA7, 0x20, 12]))
            XCTAssertFalse(playback.hasKnownStatus)
            let status: [UInt8] = [0xA3, inquiry, 0, 1] + (function == 0xA3 ? [0] : [])
            XCTAssertTrue(playback.update(status + [1]))
            XCTAssertTrue(playback.hasKnownStatus)
            XCTAssertEqual(playback.playbackControlAvailable, false)
            XCTAssertFalse(playback.canControl)
            XCTAssertTrue(playback.canControlMusicVolume)
            XCTAssertNil(playback.commandPayload(.pause))
            XCTAssertEqual(playback.volumePayload(20), [0xA8, 0x20, 20])
            XCTAssertTrue(playback.update([0xA5] + status.dropFirst() + [0]))
            XCTAssertTrue(playback.canControl)
            XCTAssertEqual(playback.commandPayload(.pause), [0xA4, function == 0xA4 ? 3 : 1, 0, 1])
            XCTAssertEqual(playback.commandPayload(.play), [0xA4, function == 0xA4 ? 3 : 1, 0, 7])
            XCTAssertEqual(playback.musicCallStatus, function == 0xA3 ? 0 : nil)
            if function == 0xA4 {
                XCTAssertNil(playback.callVolumeRange)
                XCTAssertNil(playback.callVolumeQueryPayload)
                XCTAssertNil(playback.callVolumePayload(7))
                XCTAssertFalse(playback.update([0xA7, 0x21, 7]))
            }
        }
    }

    func testMalformedModernCapabilitiesAndStatusLeaveStateUnchanged() {
        for function: UInt8 in [0xA1, 0xA2, 0xA3, 0xA4] {
            var playback = SonyPlayback(supportedFunctions: [function])
            let inquiry = playback.playbackInquiryType
            let capability: [UInt8] = [0xA1, inquiry, 31] + (function == 0xA4 ? [] : [16])
            let status: [UInt8] = [0xA3, inquiry, 0, 2] + (function == 0xA4 ? [] : [0]) + (inquiry == 1 ? [] : [0])
            XCTAssertTrue(playback.update(capability))
            XCTAssertTrue(playback.update(status))
            let saved = playback
            for payload in [capability, status] {
                for length in 0..<payload.count {
                    XCTAssertFalse(playback.update(Array(payload.prefix(length))))
                    XCTAssertEqual(playback, saved)
                }
                XCTAssertFalse(playback.update(payload + [0]))
                XCTAssertEqual(playback, saved)
                var wrongInquiry = payload
                wrongInquiry[1] = inquiry == 1 ? 2 : 1
                XCTAssertFalse(playback.update(wrongInquiry))
                XCTAssertEqual(playback, saved)
            }
            for index in 2..<capability.count {
                var invalid = capability
                invalid[index] = 0
                XCTAssertFalse(playback.update(invalid))
                XCTAssertEqual(playback, saved)
            }
        }
    }

    func testUnknownStatusFieldsInvalidateControlContext() {
        for function: UInt8 in [0xA1, 0xA2, 0xA3, 0xA4] {
            var playback = SonyPlayback(supportedFunctions: [function])
            let inquiry = playback.playbackInquiryType
            let status: [UInt8] = [0xA3, inquiry, 0, 2] + (function == 0xA4 ? [] : [0]) + (inquiry == 1 ? [] : [0])
            for index in 2..<status.count {
                XCTAssertTrue(playback.update(status))
                XCTAssertTrue(playback.hasKnownStatus)
                XCTAssertTrue(playback.canControl)
                var unknown = status
                unknown[index] = 255
                XCTAssertTrue(playback.update(unknown))
                XCTAssertFalse(playback.hasKnownStatus)
                XCTAssertFalse(playback.canControl)
                XCTAssertNil(playback.commandPayload(.play))
            }
        }
    }

    func testEveryMetadataInquiryParsesAllFourNamesAndRejectsMalformedNames() {
        for function: UInt8 in [0xA1, 0xA2, 0xA3, 0xA4] {
            var playback = SonyPlayback(supportedFunctions: [function])
            let inquiry = playback.playbackInquiryType
            let title = "İstanbul 🎧"
            let longName = String(repeating: "a", count: 128)
            let names: [UInt8] = [2, UInt8(title.utf8.count)] + Array(title.utf8)
                + [1, 0, 0, 0, 2, 128] + Array(longName.utf8)
            XCTAssertTrue(playback.update([0xA7, inquiry] + names))
            XCTAssertEqual(playback.track?.title, title)
            XCTAssertNil(playback.track?.album)
            XCTAssertNil(playback.track?.artist)
            XCTAssertEqual(playback.track?.genre, longName)
            let saved = playback
            let empty: [UInt8] = [1, 0, 1, 0, 1, 0]
            for name: [UInt8] in [[2, 129] + Array(repeating: 65, count: 129), [2, 1, 255], [2, 2, 65]] {
                XCTAssertFalse(playback.update([0xA9, inquiry] + empty + name))
                XCTAssertEqual(playback, saved)
            }
            XCTAssertFalse(playback.update([0xA7, inquiry] + names + [0]))
            XCTAssertFalse(playback.update([0xA7, inquiry] + empty))
            XCTAssertTrue(playback.update([0xA9, inquiry, 255, 1, 65] + empty))
            XCTAssertNil(playback.track?.title)
            XCTAssertTrue(playback.update([0xA9, inquiry] + empty + [1, 0]))
            XCTAssertNil(playback.track?.title)
            XCTAssertNil(playback.track?.genre)
        }
    }
}
