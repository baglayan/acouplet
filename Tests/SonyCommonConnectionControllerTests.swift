import XCTest
@testable import Acouplet

@MainActor
final class SonyCommonConnectionControllerTests: XCTestCase {
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
