import XCTest
@testable import Acouplet

@MainActor
final class SonyDeviceCoordinatorLifecycleTests: XCTestCase {
    func testManagedControllersShareDiscoveryInventoryWithoutRepeatingScans() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.setReconnectAutomatically(false)
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [], pairedDeviceInventory: [])
        var scans = 0
        for controller in devices.controllers {
            XCTAssertNotNil(controller.pairedDeviceInventory)
            XCTAssertTrue(controller.pairedDevices(automatically: true, discover: { scans += 1; return [] }).isEmpty)
            XCTAssertFalse(controller.simulatedReconnectAutomatically)
        }
        XCTAssertEqual(scans, 0)
        devices.systemWillSleep()
        XCTAssertTrue(devices.controllers.allSatisfy { $0.pairedDeviceInventory == nil })
    }

    func testManualAndStandaloneDiscoveryReadFreshInventory() {
        let controller = SonyHeadphonesController(displayOnly: true)
        var scans = 0
        XCTAssertTrue(controller.pairedDevices(automatically: true, discover: { scans += 1; return [] }).isEmpty)
        XCTAssertEqual(scans, 1)
        controller.pairedDeviceInventory = []
        XCTAssertTrue(controller.pairedDevices(automatically: false, discover: { scans += 1; return [] }).isEmpty)
        XCTAssertEqual(scans, 2)
        XCTAssertTrue(controller.pairedDevices(automatically: true, discover: { scans += 1; return [] }).isEmpty)
        XCTAssertEqual(scans, 2)
    }

    func testDiscoveryStartsPinnedControllersWithSharedPreferenceAndRetainsActiveRecovery() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.setReconnectAutomatically(false)
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        let first = try XCTUnwrap(devices.controller(for: earbuds.address))
        let second = try XCTUnwrap(devices.controller(for: headphones.address))
        XCTAssertFalse(first.simulatedReconnectAutomatically)
        XCTAssertFalse(second.simulatedReconnectAutomatically)
        devices.select(address: earbuds.address)
        first.setConnectionMode(.lowLatency)
        first.simulateControlLoss()
        XCTAssertEqual(first.connectionTransition?.phase, .recovering)
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        XCTAssertEqual(devices.controllers.count, 2)
        XCTAssertTrue(devices.selectedController === first)
        XCTAssertEqual(first.connectionTransition?.phase, .recovering)
        devices.setReconnectAutomatically(true)
        XCTAssertTrue(first.simulatedReconnectAutomatically)
        XCTAssertTrue(second.simulatedReconnectAutomatically)
    }

    func testSleepAndStopInvalidateEveryRetainedControllerAndBlockNewDiscovery() throws {
        let devices = makeCoordinator()
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        let first = try XCTUnwrap(devices.controller(for: earbuds.address))
        let second = try XCTUnwrap(devices.controller(for: headphones.address))
        devices.select(address: headphones.address)
        XCTAssertTrue(first.beginEarTipFit())
        second.setDSEE(.off)
        XCTAssertNotNil(second.pendingChanges[.dsee])
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        let sessions = devices.controllers.map(\.simulatedControlSession)
        devices.systemWillSleep()
        XCTAssertEqual(first.earTipFitTransition?.phase, .interrupted)
        XCTAssertTrue(second.pendingChanges.isEmpty)
        for (index, controller) in devices.controllers.enumerated() {
            XCTAssertGreaterThan(controller.simulatedControlSession, sessions[index])
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertNil(controller.simulatedPendingFrame)
        }
        let third = try XCTUnwrap(SonyConnectedDevice(address: "02:00:00:00:00:03", name: "WF-1000XM4", model: .wfXM4))
        devices.reconcileDiscoveredDevices([third], connectedAddresses: [third.address])
        XCTAssertNil(devices.controller(for: third.address))
        let writes = devices.controllers.map(\.simulatedTransmittedFrames)
        devices.stop()
        devices.systemDidWake()
        XCTAssertFalse(devices.isRunning)
        XCTAssertEqual(devices.controllers.map(\.simulatedTransmittedFrames), writes)
    }

    func testDisplayOnlyControllerDoesNotInitializeBluetooth() async {
        let unexpectedInitialization = expectation(description: "Display-only controller stays inert")
        unexpectedInitialization.isInverted = true
        let controller = SonyHeadphonesController(displayOnly: true)
        controller.start(authorization: { .denied }, initializeBluetooth: { unexpectedInitialization.fulfill() })
        await fulfillment(of: [unexpectedInitialization], timeout: 0.05)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertTrue(controller.address.isEmpty)
        controller.reportBluetoothAuthorization(.denied)
        XCTAssertEqual(controller.statusText, String(localized: "Bluetooth access is not allowed."))
        controller.reportBluetoothAuthorization(.allowedAlways)
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testForgottenIdleDeviceStopsAndRestartsOnlyWhenRediscovered() throws {
        let devices = makeCoordinator()
        defer { devices.stop() }
        devices.isRunning = true
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        let first = try XCTUnwrap(devices.controller(for: earbuds.address))
        first.simulateControlLoss()
        let session = first.simulatedControlSession
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        XCTAssertGreaterThan(first.simulatedControlSession, session)
        XCTAssertEqual(first.linkState, .disconnected)
        XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
        let stoppedSession = first.simulatedControlSession
        devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
        XCTAssertEqual(first.simulatedControlSession, stoppedSession)
        devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
        XCTAssertFalse(devices.retiredControllerAddresses.contains(earbuds.address))
        XCTAssertTrue(devices.controller(for: earbuds.address) === first)
        XCTAssertEqual(first.simulatedPendingFrame?.payload, [0, 0])
    }

    func testLiveClassicSessionSurvivesEitherBudLossAndDiscoveryInventoryGap() throws {
        for connections: [UInt8] in [[0, 1], [1, 0]] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            devices.reconcileDiscoveredDevices([earbuds, headphones], connectedAddresses: [earbuds.address, headphones.address])
            devices.select(address: earbuds.address)
            let controller = try XCTUnwrap(devices.controller(for: earbuds.address))
            let session = controller.simulatedControlSession
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x15, 0x01] + connections))
            controller.simulateAutomaticRefresh()
            devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
            XCTAssertTrue(controller.hasOpenControlTransport)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertEqual(controller.audioFeatures.leftConnected, connections[0] == 1)
            XCTAssertEqual(controller.audioFeatures.rightConnected, connections[1] == 1)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(devices.selectedController === controller)
            XCTAssertTrue(devices.connectedDevices.contains { $0.address == earbuds.address })
            XCTAssertFalse(devices.retiredControllerAddresses.contains(earbuds.address))

            controller.simulateControlLoss(deviceConnected: false)
            devices.reconcileDiscoveredDevices([headphones], connectedAddresses: [headphones.address])
            XCTAssertFalse(controller.hasOpenControlTransport)
            XCTAssertFalse(controller.isReady)
            XCTAssertFalse(devices.connectedDevices.contains { $0.address == earbuds.address })
            XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
            XCTAssertEqual(devices.selectedAddress, headphones.address)
        }
    }

    func testStopRejectsDelayedBluetoothInitialization() async throws {
        let initializationStarted = expectation(description: "Injected initialization started")
        let initializationReleased = expectation(description: "Injected initialization released")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = SonyHeadphonesController(startAutomatically: false)
        controller.start(authorization: { .denied }, initializeBluetooth: {
            initializationStarted.fulfill()
            release.wait()
            initializationReleased.fulfill()
        })
        await fulfillment(of: [initializationStarted], timeout: 1)
        controller.stop()
        release.signal()
        await fulfillment(of: [initializationReleased], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testDiscoveryGapPreservesManualBLEAttemptButRetiresAutomaticWait() throws {
        for automatic in [false, true] {
            let devices = makeCoordinator()
            defer { devices.stop() }
            devices.isRunning = true
            let other = try XCTUnwrap(SonyConnectedDevice(address: headphones.address, name: earbuds.name, model: earbuds.model))
            devices.reconcileDiscoveredDevices([earbuds, other], connectedAddresses: [earbuds.address, other.address])
            let first = try XCTUnwrap(devices.controller(for: earbuds.address))
            let second = try XCTUnwrap(devices.controller(for: other.address))
            devices.select(address: earbuds.address)
            first.simulateBLEReconnectWait(automatic: automatic, priorBluetoothLE: automatic, classicConnected: false)
            let session = first.simulatedControlSession
            let writes = first.simulatedTransmittedFrames
            let otherSession = second.simulatedControlSession

            devices.reconcileDiscoveredDevices([other], connectedAddresses: [other.address])
            XCTAssertEqual(first.simulatedTransmittedFrames, writes)
            XCTAssertEqual(second.simulatedControlSession, otherSession)
            XCTAssertTrue(second.isReady)
            if automatic {
                XCTAssertGreaterThan(first.simulatedControlSession, session)
                XCTAssertEqual(first.linkState, .disconnected)
                XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
                XCTAssertTrue(devices.selectedController === second)
            } else {
                XCTAssertEqual(first.simulatedControlSession, session)
                XCTAssertEqual(first.linkState, .opening)
                XCTAssertFalse(devices.retiredControllerAddresses.contains(earbuds.address))
                XCTAssertTrue(devices.selectedController === first)
                first.simulateControlLoss()
                devices.reconcileDiscoveredDevices([other], connectedAddresses: [other.address])
                XCTAssertTrue(devices.retiredControllerAddresses.contains(earbuds.address))
                XCTAssertTrue(devices.selectedController === second)
            }
        }
    }

    private func makeCoordinator() -> SonyDeviceCoordinator {
        SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(displayOnly: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true,
                                                      pinnedAddress: device.address, advertisedName: device.name)
            controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address)
            return controller
        }
    }

    private var earbuds: SonyConnectedDevice {
        SonyConnectedDevice(address: "02:00:00:00:00:01", name: "WF-1000XM5", model: .wfXM5)!
    }

    private var headphones: SonyConnectedDevice {
        SonyConnectedDevice(address: "02:00:00:00:00:02", name: "WH-1000XM5", model: .whXM5)!
    }
}
