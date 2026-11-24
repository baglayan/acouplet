import XCTest
@testable import Acouplet

@MainActor
final class SonyCommonConnectionControllerTests: XCTestCase {
    func testConnectionTimeSendsOncePerAdvertisedClassicSessionAndOwnsItsApplicationACK() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        let protocolReply: [UInt8] = [0x01, 0, 3, 0, 0x30, 0x18, 0, 0]
        let acknowledgment: [UInt8] = [0x19, 0x05]
        let confirmation = "Headphone connection time synchronized"
        controller.simulateProtocolMessage(protocolReply, beginConnection: true)
        let firstSession = controller.simulatedControlSession
        deliver(acknowledgment, to: controller)
        XCTAssertFalse(controller.diagnosticReport.contains(confirmation))

        finishNegotiation(controller, functions: [0x16, 0x17])
        let sent = controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload.starts(with: [0x18, 0x05]) }
        XCTAssertEqual(sent.map { $0.payload.count }, [20])
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.diagnosticReport.contains(confirmation))
        deliver(acknowledgment, type: 0x0E, to: controller)
        XCTAssertFalse(controller.diagnosticReport.contains(confirmation))
        deliver(acknowledgment + [0x00], to: controller)
        deliver(acknowledgment, to: controller)
        XCTAssertEqual(controller.diagnosticReport.components(separatedBy: confirmation).count, 2)

        controller.simulateProtocolMessage(protocolReply, beginConnection: true)
        finishNegotiation(controller, functions: [0x16])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload.starts(with: [0x18, 0x05]) }.count, 2)
        controller.simulateProtocolMessage(acknowledgment, session: firstSession)
        XCTAssertEqual(controller.diagnosticReport.components(separatedBy: confirmation).count, 2)
        deliver(acknowledgment, to: controller)
        XCTAssertEqual(controller.diagnosticReport.components(separatedBy: confirmation).count, 3)
    }

    func testConnectionTimeDoesNotSendOnLEOrForFirmwareReconnectCapability() throws {
        for (functions, bluetoothLE): ([UInt8], Bool) in [([0x17], false), ([0x16], true)] {
            let controller = try readyController(functions: functions, bluetoothLE: bluetoothLE)
            defer { controller.simulateControlLoss() }
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && $0.payload.starts(with: [0x18, 0x05]) })
            XCTAssertTrue(controller.isReady)
        }
    }

    func testClassicLEAudioStandbyOwnsReadsAndFollowsCurrentNotifications() throws {
        let controller = try readyController(functions: [0x42])
        defer { controller.simulateControlLoss() }
        let queryPayloads: [[UInt8]] = [[0x42, 0x0C], [0x46, 0x0C]]
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && queryPayloads.contains($0.payload) }.map(\.payload),
                       queryPayloads)
        let oldSession = controller.simulatedControlSession

        deliver([0x45, 0x0C, 1], type: 0x0E, to: controller)
        deliver([0x43, 0x0C, 2], to: controller)
        deliver([0x47, 0x0C, 0, 0], to: controller)
        XCTAssertEqual(controller.leAudioStandby, SonyLEAudioStandby())
        deliver([0x43, 0x0C, 0], to: controller)
        deliver([0x49, 0x0C, 1], to: controller)
        deliver([0x47, 0x0C, 0], to: controller)
        XCTAssertEqual(controller.leAudioStandby.available, true)
        XCTAssertEqual(controller.leAudioStandby.enabled, false)

        deliver([0x45, 0x0C, 1], to: controller)
        deliver([0x49, 0x0C, 0], to: controller)
        XCTAssertEqual(controller.leAudioStandby.available, false)
        XCTAssertEqual(controller.leAudioStandby.enabled, true)
        XCTAssertTrue(controller.diagnosticReport.contains("Headphone LE Audio standby: On, setting available: No"))
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.starts(with: [0x48, 0x0C]) })

        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        finishNegotiation(controller, functions: [0x42])
        XCTAssertEqual(controller.leAudioStandby, SonyLEAudioStandby())
        controller.simulateProtocolMessage([0x49, 0x0C, 0], session: oldSession)
        XCTAssertNil(controller.leAudioStandby.enabled)
        deliver([0x47, 0x0C, 1], to: controller)
        XCTAssertEqual(controller.leAudioStandby.enabled, false)
    }

    func testLEAudioDevicePreferenceUsesSettingOnlyAndWaitsForDeviceReports() async throws {
        let controller = try readyController(functions: [0x42], table2: [0x77])
        defer { controller.simulateControlLoss() }
        deliver([0x73, 9, 0, 0], type: 0x0E, to: controller)
        XCTAssertFalse(controller.canSetLEAudioStandby)
        XCTAssertFalse(controller.canSetAuracast)
        deliver([0x43, 0x0C, 0], to: controller)
        deliver([0x47, 0x0C, 1], to: controller)
        XCTAssertTrue(controller.canSetLEAudioStandby)
        let session = controller.simulatedControlSession

        controller.setLEAudioStandby(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x48, 0x0C, 0, 1])
        XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0C)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.leAudioStandby.enabled, false)
        XCTAssertFalse(controller.canSetAuracast)
        deliver([0x49, 0x0C, 0], type: 0x0E, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.leAudioStandby])
        deliver([0x49, 0x0C, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.leAudioStandby])
        XCTAssertTrue(controller.canSetAuracast)

        controller.setLEAudioStandby(false)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x48, 0x0C, 1, 1])
        acknowledgeAll(controller)
        let read = SonyLEAudioStandby.Field.setting.inquiry
        for _ in 0..<40 {
            if controller.simulatedPendingFrame?.payload == read { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, read)
        XCTAssertEqual(controller.leAudioStandby.enabled, true)
        deliver([0x47, 0x0C, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.leAudioStandby.enabled, false)
        XCTAssertNil(controller.pendingChanges[.leAudioStandby])
        XCTAssertFalse(controller.canSetAuracast)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    func testLEAudioDevicePreferenceRevalidatesQueueAndDeclinesOwnedDisconnectAlert() throws {
        let controller = try readyController(functions: [0x42])
        defer { controller.simulateControlLoss() }
        deliver([0x43, 0x0C, 0], to: controller)
        deliver([0x47, 0x0C, 1], to: controller)
        controller.refresh()
        XCTAssertNotNil(controller.simulatedPendingFrame)
        controller.setLEAudioStandby(true)
        deliver([0x45, 0x0C, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertNil(controller.pendingChanges[.leAudioStandby])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.starts(with: SonyLEAudioStandby.writePrefix) })

        deliver([0x45, 0x0C, 0], to: controller)
        controller.setLEAudioStandby(true)
        acknowledgeAll(controller)
        deliver([0x99, 0x00, 0x2C, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.leAudioStandby])
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x99, 0x06, 0x0F, 1, 0x10, 1], to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0x06, 0x0F, 0])
        acknowledgeAll(controller)
        XCTAssertNil(controller.pendingChanges[.leAudioStandby])
        XCTAssertNotNil(controller.settingErrors[.leAudioStandby])
        XCTAssertEqual(controller.leAudioStandby.enabled, false)
        XCTAssertTrue(controller.isReady)
    }

    func testLEAudioTable2ReadsReportedCompatibilityAndModeOverClassicControls() throws {
        let controller = try readyController(functions: [0x42], table2: [0x60, 0x61, 0x62])
        defer { controller.simulateControlLoss() }
        let expected: [[UInt8]] = [[0x60, 1], [0x60, 2], [0x62, 2], [0x66, 2]]
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && expected.contains($0.payload) }.map(\.payload), expected)
        XCTAssertTrue(controller.leAudioCapabilities.supportsHostStateNotification)
        deliver([0x61, 1, 4], to: controller)
        XCTAssertNil(controller.leAudioCapabilities.compatibilityVersion)
        deliver([0x61, 1, 4], type: 0x0E, to: controller)
        deliver([0x61, 2, 2, 0], type: 0x0E, to: controller)
        XCTAssertNil(controller.leAudioCapabilities.supportedModes)
        deliver([0x61, 2, 2, 0, 2], type: 0x0E, to: controller)
        deliver([0x65, 2, 1], type: 0x0E, to: controller)
        deliver([0x63, 2, 0], type: 0x0E, to: controller)
        deliver([0x67, 2, 2], type: 0x0E, to: controller)
        XCTAssertEqual(controller.leAudioCapabilities.compatibilityVersion, 4)
        XCTAssertEqual(controller.leAudioCapabilities.supportedModes, [.highReliability, .lowLatencyWithEQRestriction])
        XCTAssertEqual(controller.leAudioCapabilities.modeAvailable, false)
        XCTAssertEqual(controller.leAudioCapabilities.mode, .lowLatencyWithEQRestriction)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x68 })

        let unsupported = try readyController(functions: [0x42], table2: [0x60])
        defer { unsupported.simulateControlLoss() }
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { $0.type == 0x0E && expected.contains($0.payload) })
        deliver([0x61, 1, 4], type: 0x0E, to: unsupported)
        deliver([0x67, 2, 2], type: 0x0E, to: unsupported)
        XCTAssertNil(unsupported.leAudioCapabilities.compatibilityVersion)
        XCTAssertNil(unsupported.leAudioCapabilities.mode)
    }

    func testLEAudioStandbyDoesNotReadUnadvertisedOrBluetoothLEControllers() throws {
        for (functions, usesLE): ([UInt8], Bool) in [([0x40], false), ([0x42], true)] {
            let controller = try readyController(functions: functions, bluetoothLE: usesLE)
            defer { controller.simulateControlLoss() }
            for payload: [UInt8] in [[0x43, 0x0C, 0], [0x45, 0x0C, 0], [0x47, 0x0C, 0], [0x49, 0x0C, 0]] {
                deliver(payload, to: controller)
            }
            let queryPayloads: [[UInt8]] = [[0x42, 0x0C], [0x46, 0x0C]]
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && queryPayloads.contains($0.payload) })
            XCTAssertEqual(controller.leAudioStandby, SonyLEAudioStandby())
            XCTAssertTrue(controller.isReady)
        }
    }

    func testConfirmationKeepsCurrentControlsUsableAndDoesNotChangeTarget() throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        let address = controller.address
        let acknowledgments = controller.simulatedTransmittedFrames.filter { $0.type == 0x01 }.count
        deliver(reconnection(.underConfirmation), to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.address, address)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x01 }.count, acknowledgments + 1)
    }

    func testLEAudioRestrictionsUseIndependentTablesAndDoNotTreatClassicControlsAsClassicAudio() throws {
        let controller = try readyController(functions: [0x12, 0x47, 0x4D, 0x4E], table2: [0x6F])
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && $0.payload == [0x42, 0xFD] })
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x62, 0xFE] })
        XCTAssertNil(controller.leAudioUnavailableReason(.voiceAssistant))

        deliver([0x43, 0xFE, 1], to: controller)
        deliver([0x45, 0xFE, 0], to: controller)
        deliver([0x43, 0xFE, 1], to: controller)
        XCTAssertEqual(controller.leAudioRestrictions.status[.voiceAssistant]?.reason, .leAudioPriority)
        XCTAssertNotNil(controller.leAudioUnavailableReason(.voiceAssistant))
        XCTAssertNil(controller.leAudioUnavailableReason(.linkAutoSwitch))

        deliver([0x65, 0xFE, 2], type: 0x0E, to: controller)
        XCTAssertEqual(controller.leAudioRestrictions.status[.linkAutoSwitch]?.reason, .leAudioSwitchOn)
        XCTAssertNotNil(controller.leAudioUnavailableReason(.linkAutoSwitch))
        deliver([0x45, 0xFE, 1], to: controller)
        XCTAssertNil(controller.leAudioUnavailableReason(.voiceAssistant))

        deliver([0x15, 0x02, 0x30], to: controller)
        XCTAssertNotNil(controller.leAudioUnavailableReason(.connectionPreference))
        XCTAssertNotNil(controller.leAudioUnavailableReason(.pairedDevices))
        XCTAssertNotNil(controller.leAudioUnavailableReason(.voiceAssistant))
        XCTAssertNil(controller.leAudioUnavailableReason(.voiceAssistantWakeWord))
        XCTAssertFalse(controller.usesBluetoothLE)

        deliver([0x15, 0x02, 2], to: controller)
        XCTAssertNil(controller.leAudioUnavailableReason(.connectionPreference))
        XCTAssertNil(controller.leAudioUnavailableReason(.pairedDevices))
        XCTAssertNil(controller.leAudioUnavailableReason(.voiceAssistant))
        XCTAssertNotNil(controller.leAudioUnavailableReason(.linkAutoSwitch))

        controller.simulateControlLoss()
        XCTAssertTrue(controller.leAudioRestrictions.supported.isEmpty)
        XCTAssertTrue(controller.leAudioRestrictions.status.isEmpty)
    }

    func testAssistantAndWakeWordUseSeparateRestrictionsWhenTheirSettersAreAvailable() throws {
        let controller = try readyController(functions: [0x4E, 0x4F, 0xF4, 0xF5])
        defer { controller.simulateControlLoss() }
        for payload: [UInt8] in [[0xF3, 5, 0], [0xF7, 5, 1], [0xF1, 4, 3, 2, 0x30, 0x31], [0xF3, 4, 0], [0xF7, 4, 0x30]] {
            deliver(payload, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertTrue(controller.canSetVoiceAssistant)
        XCTAssertTrue(controller.canSetSystemFeature(.voiceAssistantWakeWord))

        deliver([0x45, 0xFE, 2], to: controller)
        XCTAssertFalse(controller.canSetVoiceAssistant)
        XCTAssertTrue(controller.canSetSystemFeature(.voiceAssistantWakeWord))
        controller.setVoiceAssistant(SonyVoiceAssistantOption(rawValue: 0x31))
        XCTAssertNil(controller.simulatedPendingFrame)

        deliver([0x45, 0xFE, 1], to: controller)
        deliver([0x45, 0xFF, 0], to: controller)
        XCTAssertTrue(controller.canSetVoiceAssistant)
        XCTAssertFalse(controller.canSetSystemFeature(.voiceAssistantWakeWord))
        controller.setSystemFeature(.voiceAssistantWakeWord, enabled: true)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    func testBluetoothLEControlTransportDoesNotRestrictAdvertisedFeatureWithoutAudioEvidence() throws {
        let controller = try readyController(functions: [0x12, 0x4E], bluetoothLE: true)
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.usesBluetoothLE)
        deliver([0x43, 0xFE, 1], to: controller)
        deliver([0x15, 0x02, 2], to: controller)
        XCTAssertNil(controller.leAudioUnavailableReason(.voiceAssistant))
    }

    func testCommonNotificationsRequireValidAdvertisedTableOneV2Payload() throws {
        for functions: [UInt8] in [[], [0x1A], [0x1C]] {
            let controller = try readyController(functions: functions)
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            let malformed: [[UInt8]] = [Array(reconnection(.execute).dropLast()), reconnection(.execute) + [0],
                [0x19, 0x08, 2] + Array("00:11:22:33:44:55".utf8), [0x19, 0x0A, 0]]
            for payload in malformed { deliver(payload, to: controller) }
            deliver(reconnection(.execute), type: 0x0E, to: controller)
            deliver([0x19, 0x0A], type: 0x0E, to: controller)
            if !functions.contains(0x1A) { deliver(reconnection(.execute), to: controller) }
            if !functions.contains(0x1C) { deliver([0x19, 0x0A], to: controller) }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.retrySecondsRemaining)
        }
        let legacy = try readyController()
        defer { legacy.simulateControlLoss() }
        legacy.simulateProtocolMessage([0x01, 0, 0x40, 0], beginConnection: true)
        let session = legacy.simulatedControlSession
        deliver(reconnection(.execute), to: legacy)
        deliver([0x19, 0x0A], to: legacy)
        XCTAssertEqual(legacy.simulatedControlSession, session)
        XCTAssertEqual(legacy.linkState, .handshaking)
        XCTAssertNil(legacy.retrySecondsRemaining)
    }

    func testExecuteWaitsForItsACKAndRepeatedNotificationsCannotRestartRecovery() throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        let address = controller.address
        controller.defersSimulatedWrites = true
        deliver(reconnection(.execute), to: controller)
        deliver(reconnection(.execute), to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertEqual(controller.address, address)
        XCTAssertEqual(controller.simulatedRecoveryAddress, address)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNotNil(controller.simulatedCommonConnectionRetry())
        XCTAssertNotNil(controller.retrySecondsRemaining)
        let recoveringSession = controller.simulatedControlSession
        controller.completeSimulatedWrite()
        deliver(reconnection(.execute), to: controller)
        XCTAssertEqual(controller.simulatedControlSession, recoveringSession)
        XCTAssertEqual(controller.address, address)
        XCTAssertFalse(controller.usesBluetoothLE)
    }

    func testClassicRecoveryIsBoundedAndExplicitRefreshCanRetryAfterFailure() async throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        controller.setReconnectAutomatically(false)
        deliver(reconnection(.execute), to: controller)
        let retry = try XCTUnwrap(controller.simulatedCommonConnectionRetry())
        retry()
        await settle()
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertNil(controller.retrySecondsRemaining)
        controller.simulateHandshakeTimeout()
        await settle()
        guard case .failed = controller.linkState else { return XCTFail("Recovery did not finish with an error.") }
        let session = controller.simulatedControlSession
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
        XCTAssertNil(controller.retrySecondsRemaining)
        for _ in 0..<6 { controller.simulateAutomaticRefresh() }
        retry()
        await settle()
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertFalse(controller.simulatedReconnectAutomatically)
        controller.refresh()
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
    }

    func testPhysicalReconnectionResumesAutomaticRecoveryAfterFailedExecute() async throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        deliver(reconnection(.execute), to: controller)
        try XCTUnwrap(controller.simulatedCommonConnectionRetry())()
        await settle()
        controller.simulateHandshakeTimeout()
        await settle()
        let session = controller.simulatedControlSession
        controller.simulateAutomaticRefresh(deviceConnected: false)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.simulateAutomaticRefresh(deviceConnected: true)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.simulatedReconnectAutomatically)
    }

    func testSuccessfulRecoveryClearsThePendingRequest() async throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        let address = controller.address
        deliver(reconnection(.execute), to: controller)
        try XCTUnwrap(controller.simulatedCommonConnectionRetry())()
        await settle()
        negotiate(controller, functions: [0x1A, 0x1C])
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.address, address)
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
        XCTAssertNil(controller.retrySecondsRemaining)
        deliver(reconnection(.execute), to: controller)
        XCTAssertNotNil(controller.simulatedCommonConnectionRetry())
    }

    func testOldACKAndRetryCannotReconnectAReplacementDevice() async throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        deliver(reconnection(.execute), to: controller)
        controller.defersSimulatedWrites = false
        controller.simulateDeviceConnection(named: "WH-1000XM5", simulatedAddress: "02:00:00:00:00:02")
        let replacementSession = controller.simulatedControlSession
        controller.completeSimulatedWrite()
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, replacementSession)
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        finishNegotiation(controller, functions: [0x1A, 0x1C])
        deliver(reconnection(.execute), to: controller)
        let retry = try XCTUnwrap(controller.simulatedCommonConnectionRetry())
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: "02:00:00:00:00:03")
        let session = controller.simulatedControlSession
        retry()
        await settle()
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.address, "02:00:00:00:00:03")
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    func testExplicitRefreshCancelsPendingRecoveryAndItsCapturedCallback() async throws {
        let controller = try readyController()
        defer { controller.simulateControlLoss() }
        deliver(reconnection(.execute), to: controller)
        let retry = try XCTUnwrap(controller.simulatedCommonConnectionRetry())
        controller.refresh()
        let session = controller.simulatedControlSession
        retry()
        await settle()
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
    }

    func testGATTRecoveryRetainsTheCurrentPeripheralAndDoesNotFallBackToClassic() async throws {
        let controller = try readyController(bluetoothLE: true)
        defer { controller.simulateControlLoss() }
        let target = controller.simulatedBLEIdentityTarget
        let address = controller.address
        deliver(reconnection(.execute), to: controller)
        try XCTUnwrap(controller.simulatedCommonConnectionRetry())()
        await settle()
        XCTAssertTrue(controller.usesBluetoothLE)
        XCTAssertEqual(controller.address, address)
        XCTAssertEqual(controller.simulatedBLEIdentityTarget, target)
        XCTAssertEqual(controller.linkState, .opening)
        controller.simulateBLEDisconnect("Connection failed")
        guard case .failed = controller.linkState else { return XCTFail("Recovery did not finish with an error.") }
        let session = controller.simulatedControlSession
        for _ in 0..<6 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertNil(controller.simulatedCommonConnectionRetry())
        XCTAssertFalse(controller.usesBluetoothLE)
    }

    func testGATTReleaseWaitsForACKAndHoldsAutomaticReconnectWithoutChangingPreference() throws {
        let classic = try readyController()
        defer { classic.simulateControlLoss() }
        let classicSession = classic.simulatedControlSession
        deliver([0x19, 0x0A], to: classic)
        XCTAssertEqual(classic.simulatedControlSession, classicSession)
        XCTAssertTrue(classic.isReady)
        let controller = try readyController(bluetoothLE: true)
        defer { controller.simulateControlLoss() }
        let transport = try XCTUnwrap(controller.simulatedBLETransport)
        let disconnected = try XCTUnwrap(transport.onDisconnect)
        let session = controller.simulatedControlSession
        controller.defersSimulatedWrites = true
        deliver([0x19, 0x0A], to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.usesBluetoothLE)
        XCTAssertEqual(controller.simulatedControlSession, session)
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        XCTAssertNil(controller.simulatedBLETransport)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertEqual(controller.linkState, .disconnected)
        let releasedSession = controller.simulatedControlSession
        disconnected("Late disconnect")
        for _ in 0..<6 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedControlSession, releasedSession)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertTrue(controller.simulatedReconnectAutomatically)
        XCTAssertNil(controller.retrySecondsRemaining)
        controller.refresh()
        XCTAssertEqual(controller.linkState, .handshaking)
    }

    func testSharedDisconnectDirectiveAcceptsHBSAndPASWithoutBroadeningTWSRequests() throws {
        for functions: [UInt8] in [[0x41], []] {
            let controller = try readyController(functions: functions, table2: functions.isEmpty ? [0x64] : [])
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            deliver([0x49, 0x0C, 0], to: controller)
            deliver([0x49, 0x0D], to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            controller.defersSimulatedWrites = true
            deliver([0x49, 0x0F], to: controller)
            XCTAssertEqual(controller.simulatedControlSession, session)
            controller.defersSimulatedWrites = false
            controller.completeSimulatedWrite()
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertNotNil(controller.retrySecondsRemaining)
            XCTAssertFalse(controller.usesBluetoothLE)
        }
    }

    private func readyController(functions: [UInt8] = [0x1A, 0x1C], table2: [UInt8] = [],
                                 bluetoothLE: Bool = false) throws -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        if bluetoothLE {
            controller.connectBluetoothLE()
            try XCTUnwrap(controller.simulatedPreparingBLETransport?.onPrepared)()
            controller.simulateBluetoothLEReady(identifier: UUID(), name: "WF-1000XM5")
            negotiate(controller, functions: functions + [0x14], table2: table2)
        } else {
            controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            finishNegotiation(controller, functions: functions, table2: table2)
        }
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.simulatedPendingFrame)
        return controller
    }

    private func negotiate(_ controller: SonyHeadphonesController, functions: [UInt8], table2: [UInt8] = []) {
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], to: controller)
        finishNegotiation(controller, functions: functions, table2: table2)
    }

    private func finishNegotiation(_ controller: SonyHeadphonesController, functions: [UInt8], table2: [UInt8] = []) {
        acknowledgeAll(controller)
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        acknowledgeAll(controller)
        if functions.contains(0x14) {
            deliver([0x11, 0x04] + Array("00:11:22:33:44:55ABCDEF12".utf8), to: controller)
            acknowledgeAll(controller)
        }
        deliver([0x07, 0, UInt8(table2.count)] + table2.flatMap { [$0, 0] }, type: 0x0E, to: controller)
        acknowledgeAll(controller)
    }

    private func reconnection(_ type: SonyCommonConnection.RequestType) -> [UInt8] {
        [0x19, 0x08, type.rawValue] + Array("11:22:33:44:55:66".utf8)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<200 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
