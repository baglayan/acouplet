import XCTest
@testable import Acouplet

final class SonyDeviceCoordinatorTests: XCTestCase {
    private let firstAddress = "02:53:4F:4E:59:01"
    private let secondAddress = "02:53:4F:4E:59:02"

    @MainActor
    func testDevicePickerLabelsDistinguishSameModelWithoutChangingRouting() throws {
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: first, among: [first]), "WF-1000XM5")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: first, among: [first, second]), "WF-1000XM5 · 59:01")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: second, among: [first, second]), "WF-1000XM5 · 59:02")
        let renamed = try device(secondAddress, name: "Travel earbuds", model: .wfXM5)
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: renamed, among: [first, renamed]), "Travel earbuds · 59:02")
        let sameSuffix = try device("02:54:4F:4E:59:01", name: first.name, model: first.model)
        let peers = [first, second, sameSuffix]
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: first, among: peers), "WF-1000XM5 · \(first.address)")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: sameSuffix, among: peers), "WF-1000XM5 · \(sameSuffix.address)")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: second, among: peers), "WF-1000XM5 · 59:02")
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        coordinator.select(address: second.address)
        XCTAssertEqual(coordinator.selectedController.address, second.address)
        XCTAssertEqual(coordinator.selectedAddress, second.address)
    }

    @MainActor
    func testSelectionIsDeterministicAndSwitchingAppearsOnlyForMultipleConnectedDevices() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([second, first, first])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        XCTAssertEqual(coordinator.connectedDevices.map(\.address), [firstAddress, secondAddress])
        XCTAssertEqual(coordinator.controllers.count, 2)
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        XCTAssertTrue(coordinator.hasMultipleConnectedDevices)
        let firstController = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let secondController = try XCTUnwrap(coordinator.controller(for: secondAddress))
        coordinator.select(address: secondAddress.replacingOccurrences(of: ":", with: "-").lowercased())
        XCTAssertTrue(coordinator.selectedController === secondController)
        coordinator.reconcileConnectedDevices([first, second])
        XCTAssertTrue(coordinator.selectedController === secondController)
        coordinator.reconcileConnectedDevices([first])
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        XCTAssertTrue(coordinator.selectedController === firstController)
        coordinator.select(address: secondAddress)
        XCTAssertTrue(coordinator.selectedController === firstController)
        coordinator.reconcileConnectedDevices([])
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        XCTAssertTrue(coordinator.selectedController === firstController)
        XCTAssertEqual(coordinator.controllers.count, 2)
        coordinator.reconcileConnectedDevices([second, first])
        XCTAssertTrue(coordinator.controller(for: firstAddress) === firstController)
        XCTAssertTrue(coordinator.controller(for: secondAddress) === secondController)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLDACHandoffRetainsDeviceAndMenuUntilOwnershipEnds() throws {
        for running in [false, true] {
            for state in [LDACState.requested, .connecting, .active(.init(sampleRateHz: 48_000, bitrateKbps: 330, channels: 2)), .stopping] {
                XCTAssertTrue(state.keepsMenuBarVisible(isSessionRunning: running))
            }
            XCTAssertFalse(LDACState.off.keepsMenuBarVisible(isSessionRunning: running))
            XCTAssertFalse(LDACState.waitingForDevice.keepsMenuBarVisible(isSessionRunning: running))
            XCTAssertEqual(LDACState.failed("Test").keepsMenuBarVisible(isSessionRunning: running), running)
        }
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcilePairedDevices([first, second], connectedAddresses: [firstAddress, secondAddress])
        coordinator.setReconnectAutomatically(true, suppressing: firstAddress)
        coordinator.reconcilePairedDevices([first, second], connectedAddresses: [secondAddress])
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        XCTAssertFalse(coordinator.selectedController.simulatedReconnectAutomatically)
        coordinator.select(address: secondAddress)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        coordinator.setReconnectAutomatically(true)
        XCTAssertTrue(try XCTUnwrap(coordinator.controller(for: firstAddress)).simulatedReconnectAutomatically)
    }
    #endif

    @MainActor
    func testPairedDisconnectedDeviceRemainsSelectableWithoutMultiDeviceUI() throws {
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcilePairedDevices([second, first], connectedAddresses: [])
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        XCTAssertEqual(coordinator.selectedController.pinnedAddress, firstAddress)
        XCTAssertEqual(coordinator.connectedDevices, [])
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        XCTAssertFalse(coordinator.selectedController.isDeviceConnected)
        coordinator.reconcilePairedDevices([first, second], connectedAddresses: [secondAddress])
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        coordinator.reconcilePairedDevices([], connectedAddresses: [])
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
    }

    @MainActor
    func testUnfinishedHeadphoneWorkflowRetainsContextWhenAnotherDeviceConnects() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first])
        let controller = coordinator.selectedController
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        XCTAssertTrue(controller.beginEarTipFit())
        let transitionID = try XCTUnwrap(controller.earTipFitTransition?.id)
        controller.simulateControlLoss()
        coordinator.reconcileConnectedDevices([second])
        XCTAssertTrue(coordinator.selectedController === controller)
        XCTAssertEqual(controller.earTipFitTransition?.id, transitionID)
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        coordinator.select(address: secondAddress)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        coordinator.selectForWorkflow(address: firstAddress)
        XCTAssertTrue(coordinator.selectedController === controller)
    }

    @MainActor
    func testPinnedControllersDoNotRetargetOrShareBatteriesCapabilitiesAndCommands() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let earbuds = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let headphones = try XCTUnwrap(coordinator.controller(for: secondAddress))
        XCTAssertTrue(earbuds.acceptsDeviceAddress(firstAddress.replacingOccurrences(of: ":", with: "-")))
        XCTAssertFalse(earbuds.acceptsDeviceAddress(secondAddress))
        XCTAssertFalse(earbuds.acceptsDeviceAddress("invalid"))
        earbuds.simulateDeviceConnection(named: "WH-1000XM6", simulatedAddress: secondAddress)
        XCTAssertEqual(earbuds.address, firstAddress)
        XCTAssertEqual(earbuds.deviceModel, .wfXM5)
        XCTAssertTrue(earbuds.supportedFunctions.contains(0x29))
        XCTAssertFalse(headphones.supportedFunctions.contains(0x29))
        deliver([0x25, 0x09, 31, 0, 47, 0], to: earbuds)
        deliver([0x25, 0x00, 92, 0], to: headphones)
        XCTAssertEqual(earbuds.batteries.left?.level, 31)
        XCTAssertEqual(earbuds.batteries.right?.level, 47)
        XCTAssertEqual(headphones.batteryLevel, 92)
        XCTAssertNil(headphones.batteries.left)
        earbuds.setNoiseControl(.anc)
        XCTAssertNotNil(earbuds.pendingChanges[.noiseControl])
        XCTAssertTrue(headphones.pendingChanges.isEmpty)
        XCTAssertFalse(headphones.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        coordinator.select(address: secondAddress)
        XCTAssertTrue(coordinator.selectedController === headphones)
        XCTAssertNotNil(earbuds.pendingChanges[.noiseControl])
        earbuds.simulateControlLoss()
        XCTAssertTrue(headphones.isReady)
        XCTAssertEqual(headphones.batteryLevel, 92)
    }

    @MainActor
    func testPinnedControllersLoadOnlyTheirVerifiedBLEIdentity() throws {
        let suite = "dev.baglayan.Acouplet.coordinator-identity-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: firstAddress, model: .wfXM5,
            hash: "12345678", peripheralIdentifier: UUID()))
        let second = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: secondAddress, model: .whXM6,
            hash: "ABCDEF12", peripheralIdentifier: UUID()))
        SonyBLEIdentity.save(first, in: defaults)
        SonyBLEIdentity.save(second, in: defaults)
        let earbuds = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: firstAddress, advertisedName: "My earbuds")
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: secondAddress, advertisedName: "My headphones")
        let missing = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: "02:53:4F:4E:59:05")
        let unpinned = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        XCTAssertEqual(earbuds.simulatedSavedIdentity, first)
        XCTAssertEqual(headphones.simulatedSavedIdentity, second)
        XCTAssertEqual(earbuds.deviceModel, .wfXM5)
        XCTAssertEqual(headphones.deviceModel, .whXM6)
        XCTAssertNil(missing.simulatedSavedIdentity)
        XCTAssertNil(unpinned.simulatedSavedIdentity)
    }

    @MainActor
    func testRejectedProtocolPayloadsDoNotPublishAndRepeatedCodecReplyKeepsSyncFresh() throws {
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)])
        let controller = coordinator.selectedController
        defer { controller.simulateControlLoss() }
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for type: UInt8 in [0x0C, 0x0E] {
            for payload: [UInt8] in [[0xFF, 0], [0x51, 0], [0x13, 0x02], [0x43, 0x20]] {
                controller.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: 0, payload: payload))
            }
        }
        XCTAssertEqual(changes, 0)
        let initialSync = controller.lastSyncDate
        deliver([0x15, 0x02, 0x10], to: controller)
        XCTAssertEqual(controller.audioFeatures.codec, .ldac)
        XCTAssertEqual(changes, 2)
        XCTAssertNotEqual(controller.lastSyncDate, initialSync)
        changes = 0
        let previousSync = controller.lastSyncDate
        deliver([0x15, 0x02, 0x10], to: controller)
        XCTAssertEqual(controller.audioFeatures.codec, .ldac)
        XCTAssertEqual(changes, 1)
        XCTAssertNotEqual(controller.lastSyncDate, previousSync)
    }

    @MainActor
    func testMalformedMultipointInventoryStillPublishesStaleState() throws {
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)])
        let controller = coordinator.selectedController
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.multipoint.inventoryIsStale)
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0E, sequence: 0, payload: [0x39, 0x02]))
        XCTAssertTrue(controller.multipoint.inventoryIsStale)
        XCTAssertGreaterThan(changes, 0)
    }

    @MainActor
    func testQuietPollsDoNotPublishAndFifthPollStillRequestsSettings() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first])
        let controller = coordinator.selectedController
        defer { controller.simulateControlLoss() }
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for _ in 0..<4 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(controller.isDeviceConnected)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        controller.simulateAutomaticRefresh()
        XCTAssertGreaterThan(changes, 0)
        XCTAssertFalse(controller.simulatedTransmittedFrames.isEmpty)
    }

    @MainActor
    func testCoordinatorPublishesUpdatedDeviceMetadataAndForwardsControllerChanges() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        coordinator.selectedController.simulateDeviceConnection(named: "WH-1000XM4", simulatedAddress: firstAddress)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(coordinator.connectedDevices.first?.name, "WH-1000XM4")
        XCTAssertEqual(coordinator.connectedDevices.first?.model, .whXM4)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testNativeNoiseActionTargetsItsDeviceIndependentlyOfSelection() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let earbuds = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let headphones = try XCTUnwrap(coordinator.controller(for: secondAddress))
        XCTAssertEqual(coordinator.noiseControlActions.count, 6)
        let identifier = try XCTUnwrap(headphones.noiseControlActions.first { $0.title == NoiseControlMode.anc.title }?.id)
        let action = Task { @MainActor in try await coordinator.performNoiseControlAction(identifier) }
        for _ in 0..<10 { await Task.yield() }
        let frame = try XCTUnwrap(headphones.simulatedPendingFrame)
        XCTAssertEqual(frame.payload.first, 0x68)
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        XCTAssertTrue(earbuds.pendingChanges.isEmpty)
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        deliver([0x69] + frame.payload.dropFirst(), to: headphones)
        try await action.value
        XCTAssertEqual(headphones.noiseControlMode, .anc)
        XCTAssertEqual(earbuds.noiseControlMode, .ambient)
        headphones.simulateControlLoss()
        do {
            try await coordinator.performNoiseControlAction(identifier)
            XCTFail("A stale device action must not fall back to the selected headphones.")
        } catch {
            XCTAssertTrue(error is HeadphoneControlError)
        }
        XCTAssertTrue(earbuds.pendingChanges.isEmpty)
        XCTAssertFalse(earbuds.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSameModelActionsRemainDistinctAndKeepTheirOwnerAcrossSelectionChanges() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
        let actions = coordinator.noiseControlActions
        XCTAssertEqual(Set(actions.map(\.id)).count, 6)
        let ancActions = actions.filter { $0.title == NoiseControlMode.anc.title }
        XCTAssertEqual(Set(ancActions.map(\.modelName)), ["WF-1000XM5 · 59:01", "WF-1000XM5 · 59:02"])
        XCTAssertEqual(Set(ancActions.map(\.controlTitle)), [
            String(localized: "Noise Cancelling") + " · WF-1000XM5 · 59:01", String(localized: "Noise Cancelling") + " · WF-1000XM5 · 59:02",
        ])
        let identifier = try XCTUnwrap(ancActions.first { $0.id.hasPrefix(firstAddress + ":") }?.id)
        coordinator.select(address: secondAddress)
        let action = Task { @MainActor in try await coordinator.performNoiseControlAction(identifier) }
        for _ in 0..<10 { await Task.yield() }
        let frame = try XCTUnwrap(owner.simulatedPendingFrame)
        XCTAssertEqual(frame.payload.first, 0x68)
        coordinator.select(address: firstAddress)
        coordinator.select(address: secondAddress)
        XCTAssertTrue(other.pendingChanges.isEmpty)
        XCTAssertFalse(other.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        deliver([0x69] + frame.payload.dropFirst(), to: owner)
        try await action.value
        XCTAssertEqual(owner.noiseControlMode, .anc)
        XCTAssertEqual(other.noiseControlMode, .ambient)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSavedNoiseActionsWaitForDiscoveryAndSurviveUnreadyDevice() async throws {
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let identifier = "\(firstAddress):wfXM5:anc"
        let started = expectation(description: "Saved action resolution started")
        var completed = false
        let resolution = Task { @MainActor in
            started.fulfill()
            let result = try await coordinator.resolveNoiseControlActions(for: [identifier], startupTimeout: .seconds(1))
            completed = true
            return result
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(completed)
        coordinator.isRunning = true
        coordinator.isDiscovering = true
        coordinator.reconcileConnectedDevices([first])
        coordinator.isDiscovering = false
        let actions = try await resolution.value
        XCTAssertEqual(actions.map(\.id), [identifier])
        XCTAssertTrue(coordinator.noiseControlActions.isEmpty)
        let controller = try XCTUnwrap(coordinator.controller(for: firstAddress))
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        let invalid = try await coordinator.resolveNoiseControlActions(for: [
            "\(secondAddress):wfXM5:anc", "\(firstAddress):whXM5:anc", "\(firstAddress):wfXM5:invalid", "invalid",
        ])
        XCTAssertTrue(invalid.isEmpty)
        do {
            try await coordinator.performNoiseControlAction(identifier)
            XCTFail("A restored identity must not make a disconnected device writable.")
        } catch { XCTAssertTrue(error is HeadphoneControlError) }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        coordinator.retiredControllerAddresses.insert(firstAddress)
        let retired = try await coordinator.resolveNoiseControlActions(for: [identifier])
        XCTAssertTrue(retired.isEmpty)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testNoiseActionWaitsForItsHandshakeWithoutChangingDeviceSelection() async throws {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
        let identifier = try XCTUnwrap(owner.noiseControlActions.first { $0.title == NoiseControlMode.anc.title }?.id)
        owner.simulateProtocolData(Data(), beginConnection: true)
        coordinator.select(address: secondAddress)
        let started = expectation(description: "Noise action waits for handshake")
        let action = Task { @MainActor in
            started.fulfill()
            try await coordinator.performNoiseControlAction(identifier, startupTimeout: .seconds(1))
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(owner.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        XCTAssertTrue(other.simulatedTransmittedFrames.isEmpty)
        owner.simulateDeviceConnection(named: first.name, simulatedAddress: first.address)
        for _ in 0..<20 { await Task.yield() }
        let frame = try XCTUnwrap(owner.simulatedPendingFrame)
        XCTAssertEqual(frame.payload.first, 0x68)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        deliver([0x69] + frame.payload.dropFirst(), to: owner)
        try await action.value
        XCTAssertEqual(owner.noiseControlMode, .anc)
        XCTAssertEqual(other.noiseControlMode, .ambient)
        XCTAssertTrue(other.simulatedTransmittedFrames.isEmpty)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testNoiseStartupWaitEndsOnTimeoutCancellationOrStopWithoutWrites() async throws {
        for ending in ["timeout", "cancel", "stop"] {
            let coordinator = makeCoordinator(connected: false)
            coordinator.isRunning = true
            coordinator.isDiscovering = true
            let identifier = "\(firstAddress):wfXM5:anc"
            let started = expectation(description: "Startup wait \(ending)")
            let resolution = Task { @MainActor in
                started.fulfill()
                return try await coordinator.resolveNoiseControlActions(for: [identifier],
                    startupTimeout: ending == "timeout" ? .milliseconds(50) : .seconds(1))
            }
            await fulfillment(of: [started], timeout: 1)
            if ending == "cancel" { resolution.cancel() }
            if ending == "stop" { coordinator.stop() }
            do {
                let result = try await resolution.value
                XCTAssertEqual(ending, "stop")
                XCTAssertTrue(result.isEmpty)
            } catch {
                if ending == "cancel" { XCTAssertTrue(error is CancellationError) }
                else {
                    XCTAssertEqual(ending, "timeout")
                    XCTAssertEqual(error.localizedDescription, String(localized: "The headphones are still connecting. Try again in a moment."))
                }
            }
            XCTAssertTrue(coordinator.controllers.isEmpty)
        }
    }

    @MainActor
    private func makeCoordinator(connected: Bool = true) -> SonyDeviceCoordinator {
        SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true,
                pinnedAddress: device.address, advertisedName: device.name)
            if connected { controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address) }
            return controller
        }
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSavedSpeakToChatActionsWaitForDiscoveryWithoutInventingAvailability() async throws {
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let identifier = "\(firstAddress):wfXM5:speak-to-chat-on"
        let started = expectation(description: "Saved Speak-to-Chat resolution started")
        var completed = false
        let resolution = Task { @MainActor in
            started.fulfill()
            let result = try await coordinator.resolveSpeakToChatActions(for: [identifier], startupTimeout: .seconds(1))
            completed = true
            return result
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(completed)
        coordinator.isRunning = true
        coordinator.isDiscovering = true
        coordinator.reconcileConnectedDevices([first])
        coordinator.isDiscovering = false
        let restored = try await resolution.value
        XCTAssertEqual(restored.map(\.id), [identifier])
        XCTAssertEqual(restored.first?.enabled, true)
        XCTAssertTrue(coordinator.speakToChatActions.isEmpty)
        let invalid = try await coordinator.resolveSpeakToChatActions(for: [
            "\(secondAddress):wfXM5:speak-to-chat-on", "\(firstAddress):whXM5:speak-to-chat-on",
            "\(firstAddress):wfXM5:speak-to-chat-toggle", "\(firstAddress):wfXM5:anc", "invalid",
        ])
        XCTAssertTrue(invalid.isEmpty)
        do {
            try await coordinator.performSpeakToChatAction(identifier)
            XCTFail("Saved identity does not imply a ready feature.")
        } catch { XCTAssertTrue(error is HeadphoneControlError) }
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        XCTAssertTrue(owner.simulatedTransmittedFrames.isEmpty)
        coordinator.retiredControllerAddresses.insert(firstAddress)
        let retired = try await coordinator.resolveSpeakToChatActions(for: [identifier])
        XCTAssertTrue(retired.isEmpty)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSpeakToChatActionsKeepTheirExactOwnerThroughHandshakeAndSelectionChanges() async throws {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let actions = coordinator.speakToChatActions.filter(\.enabled)
        XCTAssertEqual(Set(actions.map(\.controlTitle)), [
            String(localized: "Turn On Speak-to-Chat") + " · WF-1000XM5 · 59:01", String(localized: "Turn On Speak-to-Chat") + " · WF-1000XM5 · 59:02",
        ])
        let identifier = try XCTUnwrap(actions.first { $0.id.hasPrefix(firstAddress + ":") }?.id)
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
        owner.simulateProtocolData(Data(), beginConnection: true)
        coordinator.select(address: secondAddress)
        let started = expectation(description: "Speak-to-Chat waits for its owner")
        let action = Task { @MainActor in
            started.fulfill()
            try await coordinator.performSpeakToChatAction(identifier, startupTimeout: .seconds(1))
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(owner.simulatedTransmittedFrames.contains { $0.payload.prefix(2) == [0xF8, 0x0C] })
        owner.simulateDeviceConnection(named: first.name, simulatedAddress: first.address)
        for _ in 0..<20 { await Task.yield() }
        let frame = try XCTUnwrap(owner.simulatedPendingFrame)
        XCTAssertEqual(frame.payload, [0xF8, 0x0C, 0, 1])
        XCTAssertTrue(other.simulatedTransmittedFrames.isEmpty)
        owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        deliver([0xF9, 0x0C, 0, 1], to: owner)
        try await action.value
        XCTAssertEqual(owner.systemFeatureState(.speakToChat)?.enabled, true)
        XCTAssertEqual(other.systemFeatureState(.speakToChat)?.enabled, false)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
    }

    private func device(_ address: String, name: String, model: SonyDeviceModel) throws -> SonyConnectedDevice {
        try XCTUnwrap(SonyConnectedDevice(address: address, name: name, model: model))
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: payload))
    }
}
