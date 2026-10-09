import XCTest
@testable import Acouplet

final class SonyAudioFeaturesTests: XCTestCase {
    func testBothEarbudsRequireExplicitConnectionStatus() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x11])
        XCTAssertEqual(audio.queryPayloads, [[0x12, 0x01]])
        XCTAssertNil(audio.leftConnected)
        XCTAssertNil(audio.rightConnected)
        XCTAssertTrue(audio.update([0x13, 0x01, 0x01, 0x01]))
        XCTAssertEqual(audio.leftConnected, true)
        XCTAssertEqual(audio.rightConnected, true)
        let previous = audio
        for payload: [UInt8] in [[0x13, 0x01, 0x01], [0x15, 0x01, 0x01, 0x01, 0x00]] {
            XCTAssertFalse(audio.update(payload))
            XCTAssertEqual(audio, previous)
        }
        XCTAssertTrue(audio.update([0x15, 0x01, 0x00, 0xFE]))
        XCTAssertEqual(audio.leftConnected, false)
        XCTAssertNil(audio.rightConnected)
        var unsupported = SonyAudioFeatures()
        XCTAssertFalse(unsupported.update([0x13, 0x01, 0x01, 0x01]))
        XCTAssertNil(SonyConnectionMode.unknown(0xFF).sonyValue)
    }

    func testWF1000XM5CapturedCodecAndDSEEReplies() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE2])
        XCTAssertEqual(audio.queryPayloads, [[0x12, 0x02], [0xE0, 0x01], [0xE2, 0x01], [0xE6, 0x01]])
        XCTAssertTrue(audio.update([0x13, 0x02, 0x02]))
        XCTAssertTrue(audio.update([0xE1, 0x01, 0x02]))
        XCTAssertTrue(audio.update([0xE3, 0x01, 0x00]))
        XCTAssertTrue(audio.update([0xE7, 0x01, 0x01]))
        XCTAssertEqual(audio.codec, .aac)
        XCTAssertEqual(audio.dseeType, .extreme)
        XCTAssertEqual(audio.dseeAvailable, true)
        XCTAssertEqual(audio.dseeMode, .automatic)
        XCTAssertEqual(audio.dseeSetPayload(.off), [0xE8, 0x01, 0x00])
        XCTAssertEqual(audio.dseeSetPayload(.automatic), [0xE8, 0x01, 0x01])
    }

    func testNotificationsKeepAvailabilitySeparateFromConfiguredMode() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE2])
        XCTAssertNil(audio.dseeAvailable)
        XCTAssertNil(audio.dseeMode)
        XCTAssertNil(audio.dseeSetPayload(.automatic))
        XCTAssertTrue(audio.update([0xE9, 0x01, 0x01]))
        XCTAssertTrue(audio.update([0xE5, 0x01, 0x01]))
        XCTAssertEqual(audio.dseeMode, .automatic)
        XCTAssertEqual(audio.dseeAvailable, false)
        XCTAssertNil(audio.dseeSetPayload(.off))
        XCTAssertTrue(audio.update([0x15, 0x02, 0x30]))
        XCTAssertEqual(audio.codec, .lc3)
        XCTAssertTrue(audio.update([0xE5, 0x01, 0x00]))
        XCTAssertTrue(audio.update([0xE9, 0x01, 0x00]))
        XCTAssertEqual(audio.dseeAvailable, true)
        XCTAssertEqual(audio.dseeMode, .off)
    }

    func testOnlyAdvertisedDialectCanBeQueriedParsedOrWritten() {
        var unsupported = SonyAudioFeatures(supportedFunctions: [0xE0, 0xE1, 0xE3])
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        XCTAssertFalse(unsupported.update([0x13, 0x02, 0x02]))
        XCTAssertFalse(unsupported.update([0xE1, 0x01, 0x02]))
        XCTAssertFalse(unsupported.update([0xE3, 0x01, 0x00]))
        XCTAssertFalse(unsupported.update([0xE7, 0x01, 0x01]))
        XCTAssertNil(unsupported.dseeSetPayload(.automatic))
        XCTAssertEqual(SonyAudioFeatures(supportedFunctions: [0x12]).queryPayloads, [[0x12, 0x02]])
        XCTAssertEqual(SonyAudioFeatures(supportedFunctions: [0xE2]).queryPayloads, [[0xE0, 0x01], [0xE2, 0x01], [0xE6, 0x01]])
    }

    func testUnrecognizedCodecAndDSEEModeReplaceStaleValuesAndPreventWrites() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE2])
        XCTAssertTrue(audio.update([0x13, 0x02, 0x02]))
        XCTAssertTrue(audio.update([0xE3, 0x01, 0x00]))
        XCTAssertTrue(audio.update([0xE7, 0x01, 0x01]))
        XCTAssertTrue(audio.update([0x15, 0x02, 0x03]))
        XCTAssertEqual(audio.codec, .unknown(0x03))
        XCTAssertEqual(audio.codec?.title, "Unknown")
        XCTAssertTrue(audio.update([0xE9, 0x01, 0xFF]))
        XCTAssertEqual(audio.dseeMode, .unknown(0xFF))
        XCTAssertNil(audio.dseeSetPayload(.off))
        XCTAssertTrue(audio.update([0xE9, 0x01, 0x00]))
        XCTAssertNil(audio.dseeSetPayload(.unknown(0xFF)))
        XCTAssertEqual(audio.dseeSetPayload(.automatic), [0xE8, 0x01, 0x01])
    }

    func testMalformedAndOtherDialectPayloadsPreserveState() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE2])
        for payload: [UInt8] in [[0x13, 0x02, 0x02], [0xE1, 0x01, 0x02], [0xE3, 0x01, 0x00], [0xE7, 0x01, 0x01]] {
            XCTAssertTrue(audio.update(payload))
        }
        let previous = audio
        for payload: [UInt8] in [
            [], [0x13], [0xE1, 0x01], [0xE3, 0x01], [0xE7, 0x01],
            [0xE7, 0x05, 0x01], [0xE8, 0x01, 0x00], [0xE7, 0x01, 0x00, 0x00],
        ] {
            XCTAssertFalse(audio.update(payload))
            XCTAssertEqual(audio, previous)
        }
    }

    func testUnknownDSEEAvailabilityClearsPermissionToWrite() {
        var audio = SonyAudioFeatures(supportedFunctions: [0xE2])
        XCTAssertTrue(audio.update([0xE1, 0x01, 0x02]))
        XCTAssertTrue(audio.update([0xE3, 0x01, 0x00]))
        XCTAssertTrue(audio.update([0xE7, 0x01, 0x01]))
        XCTAssertNotNil(audio.dseeSetPayload(.off))
        XCTAssertTrue(audio.update([0xE5, 0x01, 0xFF]))
        XCTAssertNil(audio.dseeAvailable)
        XCTAssertNil(audio.dseeSetPayload(.off))
        XCTAssertTrue(audio.update([0xE1, 0x01, 0xFF]))
        XCTAssertNil(audio.dseeType)
    }

    func testConnectionModeQueriesRequireAdvertisedNewerDialect() {
        var unsupported = SonyAudioFeatures(supportedFunctions: [0xE1, 0xE3])
        XCTAssertFalse(unsupported.supportsConnectionMode)
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        for payload: [UInt8] in [
            [0xE1, 0x05, 0x02, 0x00, 0x01, 0x00],
            [0xE3, 0x05, 0x00, 0x00], [0xE5, 0x05, 0x00, 0x00],
            [0xE7, 0x05, 0x00], [0xE9, 0x05, 0x02, 0x01],
        ] {
            XCTAssertFalse(unsupported.update(payload))
        }
        let audio = SonyAudioFeatures(supportedFunctions: [0xE7])
        XCTAssertTrue(audio.supportsConnectionMode)
        XCTAssertEqual(audio.queryPayloads, [[0xE0, 0x05], [0xE2, 0x05], [0xE6, 0x05]])
        XCTAssertNil(audio.supportedConnectionModes)
        XCTAssertNil(audio.connectionModeLDACExclusions)
        XCTAssertNil(audio.connectionModeStatus)
        XCTAssertNil(audio.connectionModeAdditionalStatus)
        XCTAssertNil(audio.connectionModeAvailable)
        XCTAssertNil(audio.connectionMode)
        XCTAssertNil(audio.lastConnectionModeSwitchingStream)
        XCTAssertEqual(SonyAudioFeatures(supportedFunctions: [0x12, 0xE2, 0xE7]).queryPayloads, [
            [0x12, 0x02], [0xE0, 0x01], [0xE2, 0x01], [0xE6, 0x01],
            [0xE0, 0x05], [0xE2, 0x05], [0xE6, 0x05],
        ])
    }

    func testConnectionModeCapabilityAvailabilityAndPreferenceAreSeparate() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE7])
        XCTAssertTrue(audio.update([0x13, 0x02, 0x02]))
        XCTAssertTrue(audio.update([0xE1, 0x05, 0x03, 0x00, 0x01, 0x02, 0x01, 0x00]))
        XCTAssertEqual(audio.supportedConnectionModes, [.soundQuality, .stableConnection, .lowLatency])
        XCTAssertEqual(audio.connectionModeLDACExclusions, [.gattConnectable])
        XCTAssertNil(audio.connectionMode)
        XCTAssertTrue(audio.update([0xE3, 0x05, 0x00, 0x01]))
        XCTAssertEqual(audio.connectionModeAvailable, true)
        XCTAssertEqual(audio.connectionModeAdditionalStatus, 0x01)
        XCTAssertTrue(audio.update([0xE7, 0x05, 0x02]))
        XCTAssertEqual(audio.connectionMode, .lowLatency)
        XCTAssertNil(audio.lastConnectionModeSwitchingStream)
        XCTAssertEqual(audio.codec, .aac)
        XCTAssertTrue(audio.update([0xE5, 0x05, 0x01, 0x00]))
        XCTAssertEqual(audio.connectionModeAvailable, false)
        XCTAssertEqual(audio.connectionMode, .lowLatency)
        XCTAssertTrue(audio.update([0xE1, 0x05, 0x02, 0x00, 0x01, 0x00]))
        XCTAssertEqual(audio.supportedConnectionModes, [.soundQuality, .stableConnection])
        XCTAssertEqual(audio.connectionModeLDACExclusions, [])
        XCTAssertEqual(audio.connectionMode, .lowLatency)
    }

    func testConnectionModeUnknownValuesReplaceStaleStateWithoutLosingRawValues() {
        var audio = SonyAudioFeatures(supportedFunctions: [0xE7])
        XCTAssertTrue(audio.update([0xE3, 0x05, 0x00, 0x00]))
        XCTAssertTrue(audio.update([0xE7, 0x05, 0x00]))
        XCTAssertTrue(audio.update([0xE1, 0x05, 0x03, 0x00, 0x03, 0xFF, 0x02, 0x00, 0xFE]))
        XCTAssertEqual(audio.supportedConnectionModes, [.soundQuality, .unknown(0x03), .unknown(0xFF)])
        XCTAssertEqual(audio.connectionModeLDACExclusions, [.gattConnectable, .unknown(0xFE)])
        XCTAssertTrue(audio.update([0xE5, 0x05, 0xFF, 0xA5]))
        XCTAssertNil(audio.connectionModeAvailable)
        XCTAssertEqual(audio.connectionModeStatus, 0xFF)
        XCTAssertEqual(audio.connectionModeAdditionalStatus, 0xA5)
        XCTAssertTrue(audio.update([0xE7, 0x05, 0xFF]))
        XCTAssertEqual(audio.connectionMode, .unknown(0xFF))
        XCTAssertTrue(audio.update([0xE9, 0x05, 0x03, 0xFE]))
        XCTAssertEqual(audio.connectionMode, .unknown(0x03))
        XCTAssertEqual(audio.lastConnectionModeSwitchingStream, .unknown(0xFE))
    }

    func testConnectionModeStreamNotificationDoesNotBecomeCodecOrGetReplyData() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE7])
        XCTAssertTrue(audio.update([0x13, 0x02, 0x02]))
        XCTAssertTrue(audio.update([0xE9, 0x05, 0x02, 0x01]))
        XCTAssertEqual(audio.connectionMode, .lowLatency)
        XCTAssertEqual(audio.lastConnectionModeSwitchingStream, .leAudio)
        XCTAssertEqual(audio.codec, .aac)
        XCTAssertTrue(audio.update([0xE7, 0x05, 0x01]))
        XCTAssertEqual(audio.connectionMode, .stableConnection)
        XCTAssertEqual(audio.lastConnectionModeSwitchingStream, .leAudio)
        XCTAssertTrue(audio.update([0xE9, 0x05, 0x00, 0x02]))
        XCTAssertEqual(audio.connectionMode, .soundQuality)
        XCTAssertEqual(audio.lastConnectionModeSwitchingStream, .classicAudio)
        XCTAssertTrue(audio.update([0xE9, 0x05, 0x01, 0x00]))
        XCTAssertEqual(audio.lastConnectionModeSwitchingStream, SonyConnectionStream.none)
    }

    func testConnectionModeMalformedLengthsAndCountsPreserveAllState() {
        var audio = SonyAudioFeatures(supportedFunctions: [0x12, 0xE2, 0xE7])
        let capability: [UInt8] = [0xE1, 0x05, 0x03, 0x00, 0x01, 0x02, 0x01, 0x00]
        XCTAssertTrue(audio.update(capability))
        XCTAssertTrue(audio.update([0xE3, 0x05, 0x00, 0x00]))
        XCTAssertTrue(audio.update([0xE9, 0x05, 0x01, 0x02]))
        let previous = audio
        for length in 0..<capability.count {
            XCTAssertFalse(audio.update(Array(capability.prefix(length))))
            XCTAssertEqual(audio, previous)
        }
        for payload: [UInt8] in [
            capability + [0x00],
            [0xE1, 0x05, 0x00, 0x02, 0x00, 0x01],
            [0xE1, 0x05, 0x01, 0x00, 0x01, 0x00],
            [0xE1, 0x05, 0xFF, 0x00, 0x01, 0x00],
            [0xE1, 0x05, 0x02, 0x00, 0x01, 0xFF],
            [0xE3, 0x05, 0x00], [0xE5, 0x05, 0x00],
            [0xE3, 0x05, 0x00, 0x00, 0x00], [0xE5, 0x05, 0x00, 0x00, 0x00],
            [0xE7, 0x05], [0xE7, 0x05, 0x00, 0x00],
            [0xE9, 0x05, 0x00], [0xE9, 0x05, 0x00, 0x00, 0x00],
            [0xE8, 0x05, 0x00, 0x00], [0xE7, 0x02, 0x00],
            [0x13, 0x02, 0x00, 0x00], [0xE1, 0x01, 0x00, 0x00],
            [0xE3, 0x01, 0x00, 0x00], [0xE9, 0x01, 0x00, 0x00],
        ] {
            XCTAssertFalse(audio.update(payload), "Unexpected payload: \(payload)")
            XCTAssertEqual(audio, previous)
        }
    }

    @MainActor
    func testBLESessionCannotBecomeReadyBeforeMatchingIdentity() {
        for hash in ["ABCDEF12", "ABCDEF13"] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateProtocolMessage([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00],
                beginConnection: true, expectedBLEHash: "ABCDEF12"
            )
            acknowledgeSimulatedCommands(controller)
            func deliver(_ payload: [UInt8]) {
                controller.simulateProtocolMessage(payload)
                acknowledgeSimulatedCommands(controller)
            }
            deliver([0x07, 0x00, 0x02, 0x6B, 0x00, 0x14, 0x00])
            let noise: [UInt8] = [0x69, 0x17, 0x01, 0x01, 0x00, 0x00, 0x0A]
            deliver(noise)
            XCTAssertFalse(controller.isReady)
            XCTAssertEqual(controller.linkState, .handshaking)
            XCTAssertNil(controller.noiseControlMode)
            deliver([0x11, 0x04] + Array(("00:11:22:33:44:55" + hash).utf8))
            if hash == "ABCDEF12" {
                XCTAssertFalse(controller.isReady)
                deliver(noise)
                XCTAssertTrue(controller.isReady)
            } else {
                XCTAssertFalse(controller.isReady)
                XCTAssertNotNil(controller.bluetoothLEError)
                XCTAssertNil(controller.bluetoothLEHash)
            }
        }
    }

    @MainActor
    func testControllerReadsFullProtocolVersionAndBLEHashOnlyFromSupportedTableOne() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, begin: Bool = false) {
            controller.simulateProtocolMessage(payload, type: type, beginConnection: begin)
        }
        deliver([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00], begin: true)
        XCTAssertEqual(controller.protocolVersion, 0x03003018)
        acknowledgeSimulatedCommands(controller)
        let identity: [UInt8] = [0x11, 0x04] + Array("00:11:22:33:44:55abcdef12".utf8)
        deliver(identity)
        XCTAssertNil(controller.bluetoothLEHash)
        deliver([0x07, 0x00, 0x03, 0x6B, 0x00, 0x11, 0x00, 0x14, 0x00])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x10, 0x04])
        acknowledgeSimulatedCommands(controller)
        deliver(identity, type: 0x0E)
        XCTAssertNil(controller.bluetoothLEHash)
        deliver(identity)
        XCTAssertEqual(controller.bluetoothLEHash, "ABCDEF12")
        deliver([0x13, 0x01, 0x01, 0x01])
        XCTAssertEqual(controller.audioFeatures.leftConnected, true)
        XCTAssertEqual(controller.audioFeatures.rightConnected, true)
        controller.simulateDeviceConnection(named: nil)
        XCTAssertNil(controller.protocolVersion)
        XCTAssertNil(controller.bluetoothLEHash)
        XCTAssertNil(controller.audioFeatures.leftConnected)
    }

    @MainActor
    func testControllerNegotiatesBothTablesAndDispatchesCodecAndDSEE() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, beginConnection: Bool = false) {
            controller.simulateProtocolMessage(payload, type: type, beginConnection: beginConnection)
            acknowledgeSimulatedCommands(controller)
        }
        deliver([0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00], beginConnection: true)
        deliver([0x07, 0x00, 0x03, 0x6B, 0x00, 0x12, 0x00])
        XCTAssertTrue(controller.supportedFunctions.isEmpty)
        deliver([0x07, 0x00, 0x05, 0x6B, 0x00, 0x12, 0x00, 0xE2, 0x00, 0xFF, 0x00, 0xE7, 0x00])
        XCTAssertEqual(controller.supportedFunctions, [0x6B, 0x12, 0xE2, 0xFF, 0xE7])
        deliver([0xE1, 0x01, 0x02])
        controller.simulateProtocolMessage([0x67, 0x17, 0x01, 0x01, 0x00, 0x00, 0x0A])
        var queries: [[UInt8]] = []
        while let frame = controller.simulatedPendingFrame {
            queries.append(frame.payload)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTAssertFalse(queries.contains([0xE0, 0x01]))
        XCTAssertTrue(queries.contains([0xE0, 0x05]))
        XCTAssertTrue(queries.contains([0xE2, 0x05]))
        XCTAssertTrue(queries.contains([0xE6, 0x05]))
        deliver([0xE1, 0x05, 0x03, 0x00, 0x01, 0x02, 0x01, 0x00])
        deliver([0xE3, 0x05, 0x00, 0x00])
        deliver([0xE7, 0x05, 0x00])
        XCTAssertEqual(controller.audioFeatures.connectionMode, .soundQuality)
        XCTAssertEqual(controller.audioFeatures.connectionModeAvailable, true)
        XCTAssertTrue(controller.isReady)
        deliver([0x07, 0x00, 0x02, 0x42, 0x00, 0x32, 0x00], type: 0x0E)
        XCTAssertEqual(controller.supportedFunctions2, [0x42, 0x32])
        deliver([0x13, 0x02, 0x02], type: 0x0E)
        XCTAssertNil(controller.audioFeatures.codec)
        deliver([0x13, 0x02, 0x02])
        XCTAssertEqual(controller.audioFeatures.codec, .aac)
        deliver([0xE1, 0x01, 0x02])
        deliver([0xE3, 0x01, 0x00])
        deliver([0xE7, 0x01, 0x01])
        controller.setDSEE(.off)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.audioFeatures.dseeMode, .automatic)
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x00])
        deliver([0xE7, 0x01, 0x01])
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x00])
        deliver([0xE7, 0x01, 0x00])
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x00])
        XCTAssertEqual(controller.audioFeatures.dseeMode, .automatic)
        deliver([0xE9, 0x01, 0x00])
        XCTAssertEqual(controller.audioFeatures.dseeMode, .off)
        XCTAssertNil(controller.pendingChanges[.dsee])
        deliver([0xE5, 0x01, 0x01])
        controller.setDSEE(.automatic)
        XCTAssertEqual(controller.audioFeatures.dseeMode, .off)
        deliver([0x15, 0x02, 0x10])
        XCTAssertEqual(controller.audioFeatures.codec, .ldac)
        controller.simulateDeviceConnection(named: nil)
        XCTAssertEqual(controller.audioFeatures, SonyAudioFeatures())
        XCTAssertTrue(controller.supportedFunctions.isEmpty)
        XCTAssertTrue(controller.supportedFunctions2.isEmpty)
        XCTAssertNil(controller.lastSyncDate)
    }

    @MainActor
    func testLateConfirmationClearsTimeoutAndDoesNotConfirmAnotherRequest() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setDSEE(.off)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.audioFeatures.dseeMode, .automatic)
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x00])
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertNil(controller.pendingChanges[.dsee])
        XCTAssertNotNil(controller.settingErrors[.dsee])
        controller.simulateProtocolMessage([0xE9, 0x01, 0x00])
        XCTAssertEqual(controller.audioFeatures.dseeMode, .off)
        XCTAssertNil(controller.settingErrors[.dsee])
        controller.setDSEE(.automatic)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xE9, 0x01, 0x00])
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x01])
        controller.simulateDeviceConnection(named: nil)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertTrue(controller.settingErrors.isEmpty)
    }

    @MainActor
    func testModernDSEETimeoutRequiresFreshOwnedReadAndPreservesFailedChange() async {
        for (hasOldPoll, expires) in [(false, false), (true, false), (false, true)] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            if hasOldPoll {
                controller.refresh()
                acknowledgeSimulatedCommands(controller)
            }
            controller.setDSEE(.off)
            acknowledgeSimulatedCommands(controller)
            controller.simulateSettingTimeout(.dsee)
            for _ in 0..<4 { await Task.yield() }
            acknowledgeSimulatedCommands(controller)
            let issue = controller.settingErrors[.dsee]
            XCTAssertNotNil(issue)
            XCTAssertNil(controller.pendingChanges[.dsee])
            XCTAssertFalse(controller.canSetDSEE)
            let writes = controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x01, 0] }.count
            controller.setDSEE(.off)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0xE8, 0x01, 0] }.count, writes)
            if expires {
                controller.simulateSystemReadTimeout([0xE6, 0x01])
                for _ in 0..<4 { await Task.yield() }
            }
            if hasOldPoll || expires {
                controller.simulateProtocolMessage([0xE7, 0x01, 0])
                XCTAssertEqual(controller.dseeMode, expires ? nil : .automatic)
                XCTAssertFalse(controller.canSetDSEE)
                XCTAssertEqual(controller.settingErrors[.dsee], issue)
                acknowledgeSimulatedCommands(controller)
            }
            controller.simulateProtocolMessage([0xE7, 0x01, 0xFF])
            XCTAssertFalse(controller.canSetDSEE)
            controller.simulateProtocolMessage([0xE7, 0x01, 1])
            XCTAssertEqual(controller.dseeMode, .automatic)
            XCTAssertTrue(controller.canSetDSEE)
            XCTAssertEqual(controller.settingErrors[.dsee], issue)
            controller.simulateProtocolMessage([0xE7, 0x01, 0])
            XCTAssertEqual(controller.dseeMode, .automatic)
            XCTAssertEqual(controller.settingErrors[.dsee], issue)
            controller.setDSEE(.off)
            XCTAssertEqual(controller.pendingChanges[.dsee], [0])
        }
    }

    @MainActor
    func testModernDSEEReadExpiryReleasesFailedHoldOnlyWhileModeIsUnavailable() async {
        for expiresBeforeWriteTimeout in [false, true] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeSimulatedCommands(controller)
            controller.setDSEE(.off)
            acknowledgeSimulatedCommands(controller)
            if expiresBeforeWriteTimeout {
                controller.simulateSystemReadTimeout([0xE6, 1])
                for _ in 0..<4 { await Task.yield() }
                XCTAssertEqual(controller.pendingChanges[.dsee], [0])
            }
            controller.simulateSettingTimeout(.dsee)
            for _ in 0..<4 { await Task.yield() }
            let issue = controller.settingErrors[.dsee]
            if !expiresBeforeWriteTimeout {
                controller.simulateSystemReadTimeout([0xE6, 1])
                for _ in 0..<4 { await Task.yield() }
            }
            XCTAssertNotNil(issue)
            XCTAssertNil(controller.dseeMode)
            XCTAssertFalse(controller.canSetDSEE)
            XCTAssertTrue(controller.canPerformConfirmedSettingChange(.dsee))
            XCTAssertEqual(controller.settingErrors[.dsee], issue)
            controller.simulateProtocolMessage([0xE7, 1, 0])
            XCTAssertNil(controller.dseeMode)
            XCTAssertFalse(controller.canSetDSEE)
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xE7, 1, 1])
            XCTAssertTrue(controller.canSetDSEE)
            XCTAssertEqual(controller.settingErrors[.dsee], issue)
        }
    }

    @MainActor
    func testSameTransportHandshakeKeepsOnlyErrorsForRetainedExpiredReads() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.setDSEE(.off)
        acknowledgeSimulatedCommands(controller)
        controller.simulateSettingTimeout(.dsee)
        for _ in 0..<4 { await Task.yield() }
        acknowledgeSimulatedCommands(controller)
        controller.simulateSystemReadTimeout([0xE6, 1])
        for _ in 0..<4 { await Task.yield() }
        let issue = controller.settingErrors[.dsee]
        controller.setPlaybackVolume(20)
        acknowledgeSimulatedCommands(controller)
        controller.simulateSettingTimeout(.playbackVolume)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(issue)
        XCTAssertNotNil(controller.settingErrors[.playbackVolume])
        controller.simulateSameTransportHandshake()
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(controller.settingErrors[.dsee], issue)
        XCTAssertNil(controller.settingErrors[.playbackVolume])
    }

    @MainActor
    func testDisconnectedSessionCannotApplyItsDelayedSimulatedReply() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulatedReady: true)
        controller.setDSEE(.off)
        controller.simulateDeviceConnection(named: nil)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(controller.audioFeatures.dseeMode, .automatic)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    @MainActor
    func testQueuedSettingCannotBeConfirmedBeforeItIsSent() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.refreshEqualizer()
        controller.setDSEE(.off)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 0x00])
        let reply: [UInt8] = [0xE9, 0x01, 0x00]
        controller.simulateProtocolMessage(reply)
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x00])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xE9, 0x05, 0x02, 0x01])
        XCTAssertEqual(controller.audioFeatures.connectionMode, .lowLatency)
        XCTAssertEqual(controller.pendingChanges[.dsee], [0x00])
        controller.simulateProtocolMessage(reply)
        XCTAssertNil(controller.pendingChanges[.dsee])
    }
}

@MainActor
func acknowledgeSimulatedCommands(_ controller: SonyHeadphonesController) {
    while let frame = controller.simulatedPendingFrame {
        replyToOrdinaryNoiseMetadata(frame, controller: controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
    }
}
