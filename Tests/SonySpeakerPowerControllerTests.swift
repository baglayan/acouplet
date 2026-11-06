import XCTest
@testable import Acouplet

final class SonySpeakerPowerControllerTests: XCTestCase {
    private let settings: [(setting: SonyHeadphonesController.Setting, type: UInt8, inquiry: UInt8)] = [
        (.powerSavingMode, 0x0C, 0x06), (.bluetoothStandby, 0x0C, 0x0D), (.autoStandby, 0x0E, 0x00),
    ]

    @MainActor
    func testSpeakerQueriesRequireTheirAdvertisedTableAndChargeInUseHasNoQuery() {
        for supported in [false, true] {
            let controller = makeController(functions: supported ? [0x26, 0x2D] : [0x20, 0x21],
                                            functions2: supported ? [0x20, 0x21] : [0x26, 0x2D, 0x21])
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.powerFeatures.supportsChargeInUse)
            for item in settings {
                XCTAssertEqual(controller.simulatedTransmittedFrames.contains { $0.type == item.type && $0.payload == [0x26, item.inquiry] }, supported)
                set(item.setting, enabled: true, controller: controller)
                XCTAssertNil(controller.pendingChanges[item.setting])
                XCTAssertFalse(canSet(item.setting, controller: controller))
            }
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x26, 0x01] })
        }
    }

    @MainActor
    func testSpeakerSettersWaitForMatchingDeviceStateAfterAcknowledgment() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(canSet(item.setting, controller: controller))
            set(item.setting, enabled: true, controller: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.type, item.type)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, item.inquiry, 0])
            acknowledgeAll(controller)
            XCTAssertNotNil(controller.pendingChanges[item.setting])
            XCTAssertFalse(canSet(item.setting, controller: controller))
            XCTAssertEqual(enabled(item.setting, controller: controller), false)
            deliver([0x29, item.inquiry, 0], type: item.type == 0x0C ? 0x0E : 0x0C, to: controller)
            XCTAssertNotNil(controller.pendingChanges[item.setting])
            deliver([0x29, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNil(controller.settingErrors[item.setting])
            XCTAssertEqual(enabled(item.setting, controller: controller), true)
            XCTAssertTrue(canSet(item.setting, controller: controller))
        }
    }

    @MainActor
    func testPreChangeReadCannotConfirmSpeakerSettingAndFreshReadCan() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            set(item.setting, enabled: true, controller: controller)
            acknowledgeAll(controller)
            deliver([0x27, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNotNil(controller.pendingChanges[item.setting])
            XCTAssertEqual(enabled(item.setting, controller: controller), false)
            acknowledgeAll(controller)
            deliver([0x27, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertEqual(enabled(item.setting, controller: controller), true)
        }
    }

    @MainActor
    func testSpeakerNotificationStartingBeforeSetterDoesNotConfirmIt() {
        for item in settings {
            let encoded = SonyFrameCodec.encode(type: item.type, sequence: 1, payload: [0x29, item.inquiry, 0])
            for split in 1..<encoded.count {
                let controller = makeReadyController()
                defer { controller.simulateControlLoss() }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: item.type, sequence: 0, payload: [0x25, item.inquiry, 0]))
                controller.simulateProtocolData(encoded.prefix(split))
                set(item.setting, enabled: true, controller: controller)
                controller.simulateProtocolData(encoded.dropFirst(split))
                acknowledgeAll(controller)
                XCTAssertNotNil(controller.pendingChanges[item.setting])
                deliver([0x29, item.inquiry, 0], type: item.type, to: controller)
                XCTAssertNil(controller.pendingChanges[item.setting])
            }
        }
    }

    @MainActor
    func testQueuedSpeakerSettersRevalidateAvailability() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            let blocking: SonyHeadphonesController.Setting = item.setting == .powerSavingMode ? .autoStandby : .powerSavingMode
            set(blocking, enabled: true, controller: controller)
            set(item.setting, enabled: true, controller: controller)
            deliver([0x25, item.inquiry, 1], type: item.type, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == item.type && $0.payload == [0x28, item.inquiry, 0] })
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNotNil(controller.settingErrors[item.setting])
            XCTAssertFalse(canSet(item.setting, controller: controller))
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testSpeakerReadTimeoutRejectsOldReplyAndRecoversWithFreshRead() async {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            controller.simulatePowerReadTimeout([0x26, item.inquiry], type: item.type)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(enabled(item.setting, controller: controller))
            XCTAssertFalse(canSet(item.setting, controller: controller))
            let session = controller.simulatedControlSession
            deliver([0x27, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNil(enabled(item.setting, controller: controller))
            acknowledgeAll(controller)
            deliver([0x27, item.inquiry, 1], type: item.type, to: controller)
            XCTAssertEqual(enabled(item.setting, controller: controller), false)
            XCTAssertTrue(canSet(item.setting, controller: controller))
            XCTAssertEqual(controller.simulatedControlSession, session)
        }
    }

    @MainActor
    func testSpeakerSettingTimeoutBlocksRetryUntilCurrentStateArrives() async {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            set(item.setting, enabled: true, controller: controller)
            acknowledgeAll(controller)
            controller.simulateSettingTimeout(item.setting)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNotNil(controller.settingErrors[item.setting])
            XCTAssertFalse(canSet(item.setting, controller: controller))
            deliver([0x29, item.inquiry, 1], type: item.type, to: controller)
            XCTAssertNil(controller.settingErrors[item.setting])
            XCTAssertTrue(canSet(item.setting, controller: controller))
        }
    }

    @MainActor
    func testBluetoothStandbyWarningPreservesUserChoiceAndWaitsForDeviceState() throws {
        let choices: [(type: UInt8, action: SonyConnectionAlertAction?)] = [(0, nil), (1, .negative), (1, .positive), (2, .positive)]
        for choice in choices {
            let controller = makeReadyController(bluetoothEnabled: true)
            defer { controller.simulateControlLoss() }
            controller.setBluetoothStandby(false)
            acknowledgeAll(controller)
            deliver([0x99, 6, 0x0A, 2, 0x12, 0xFE, choice.type], to: controller)
            let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
            let requestID = try XCTUnwrap(controller.bluetoothStandbyAlertRequestID)
            XCTAssertEqual(alert.affectedFeatures.map(\.rawValue), [0x12, 0xFE])
            XCTAssertNil(controller.simulatedSettingTimeoutWork(.bluetoothStandby))
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
            controller.respondToBluetoothStandbyAlert(alert, action: choice.action, requestID: UUID())
            XCTAssertEqual(controller.bluetoothStandbyAlert, alert)
            controller.respondToBluetoothStandbyAlert(alert, action: choice.action, requestID: requestID)
            acknowledgeAll(controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
            XCTAssertNotNil(controller.pendingChanges[.bluetoothStandby])
            let replies = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x98 }.map(\.payload)
            XCTAssertEqual(replies, choice.action.map { [[0x98, 6, 0x0A, $0.rawValue]] } ?? [])
            controller.respondToBluetoothStandbyAlert(alert, action: choice.action, requestID: requestID)
            deliver([0x99, 6, 0x0A, 2, 0x12, 0xFE, choice.type], to: controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
            let expected: UInt8 = choice.action == .negative ? 0 : 1
            deliver([0x29, 0x0D, expected], to: controller)
            XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
            XCTAssertEqual(controller.powerFeatures.bluetoothStandby?.enabled, expected == 0)
            XCTAssertTrue(controller.canSetBluetoothStandby)
        }
    }

    @MainActor
    func testBluetoothStandbyOnlyOwnsValidWarningsForTransmittedDisable() {
        let controller = makeReadyController()
        defer { controller.simulateControlLoss() }
        let warning: [UInt8] = [0x99, 6, 0x0A, 0, 1]
        deliver(warning, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        controller.setBluetoothStandby(true)
        acknowledgeAll(controller)
        deliver(warning, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        deliver([0x29, 0x0D, 0], to: controller)
        controller.setPowerSavingMode(true)
        controller.setBluetoothStandby(false)
        deliver(warning, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        acknowledgeAll(controller)
        for payload: [UInt8] in [[0x99, 0, 0x0A, 1], [0x99, 6, 0x0A, 0, 3], [0x99, 6, 0x0B, 0, 1]] {
            deliver(payload, to: controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
        }
        deliver(warning, type: 0x0E, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        deliver(warning, to: controller)
        XCTAssertNotNil(controller.bluetoothStandbyAlert)
        controller.simulateControlLoss()
        XCTAssertNil(controller.bluetoothStandbyAlert)
        XCTAssertNil(controller.bluetoothStandbyAlertRequestID)
        XCTAssertNil(controller.powerFeatures.bluetoothStandby)
    }

    @MainActor
    func testBluetoothStandbyWarningStartingBeforeDisableIsNotOwned() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x99, 6, 0x0A, 0, 1])
        for split in 1..<encoded.count {
            let controller = makeReadyController(bluetoothEnabled: true)
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0x0D, 0]))
            controller.simulateProtocolData(encoded.prefix(split))
            controller.setBluetoothStandby(false)
            controller.simulateProtocolData(encoded.dropFirst(split))
            acknowledgeAll(controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
            deliver([0x99, 6, 0x0A, 0, 1], to: controller)
            XCTAssertNotNil(controller.bluetoothStandbyAlert)
        }
    }

    @MainActor
    func testBluetoothStandbyOldTimeoutCannotExpireAlertOrItsReply() async throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        acknowledgeAll(controller)
        let timeout = try XCTUnwrap(controller.simulatedSettingTimeoutWork(.bluetoothStandby))
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        let requestID = controller.bluetoothStandbyAlertRequestID
        timeout.perform()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.bluetoothStandbyAlert, alert)
        deliver([0x29, 0x0D, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.bluetoothStandby])
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: requestID)
        acknowledgeAll(controller)
        timeout.perform()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(controller.pendingChanges[.bluetoothStandby])
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x29, 0x0D, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
    }

    @MainActor
    func testBluetoothStandbyQueuedReplyIsDiscardedWhenAvailabilityChanges() throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: controller.bluetoothStandbyAlertRequestID)
        deliver([0x25, 0x0D, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
        XCTAssertNotNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x27, 0x0D, 0], to: controller)
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
        XCTAssertFalse(controller.canSetBluetoothStandby)
    }

    @MainActor
    func testDeferredSpeakerWritesRevalidateBeforeTransportSendsThem() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            set(item.setting, enabled: true, controller: controller)
            deliver([0x25, item.inquiry, 1], type: item.type, to: controller)
            controller.defersSimulatedWrites = false
            controller.completeSimulatedWrite()
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == item.type && $0.payload == [0x28, item.inquiry, 0] })
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNotNil(controller.settingErrors[item.setting])
        }
    }

    @MainActor
    func testDeferredBluetoothStandbyReplyRevalidatesBeforeTransportSendsIt() throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        acknowledgeAll(controller)
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        controller.defersSimulatedWrites = true
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: controller.bluetoothStandbyAlertRequestID)
        deliver([0x25, 0x0D, 1], to: controller)
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
        XCTAssertNotNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x27, 0x0D, 0], to: controller)
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
    }

    @MainActor
    func testBluetoothStandbyAvailabilityLossDismissesOutstandingWarning() throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        acknowledgeAll(controller)
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        let requestID = controller.bluetoothStandbyAlertRequestID
        deliver([0x25, 0x0D, 1], to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: requestID)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        deliver([0x27, 0x0D, 0], to: controller)
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x25, 0x0D, 0], to: controller)
        XCTAssertTrue(controller.canSetBluetoothStandby)
    }

    @MainActor
    private func makeController(functions: [UInt8] = [0x26, 0x2D], functions2: [UInt8] = [0x20, 0x21]) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM5".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0, 0], to: controller)
        let functions = [UInt8(0x6B)] + functions
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, UInt8(functions2.count)] + functions2.flatMap { [$0, 0] }, type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    @MainActor
    private func makeReadyController(bluetoothEnabled: Bool = false) -> SonyHeadphonesController {
        let controller = makeController()
        for item in settings {
            if item.setting == .autoStandby { deliver([0x21, 0, 0], type: item.type, to: controller) }
            deliver([0x23, item.inquiry, 0], type: item.type, to: controller)
            deliver([0x27, item.inquiry, item.setting == .bluetoothStandby && bluetoothEnabled ? 0 : 1], type: item.type, to: controller)
        }
        return controller
    }

    @MainActor
    private func set(_ setting: SonyHeadphonesController.Setting, enabled: Bool, controller: SonyHeadphonesController) {
        switch setting {
        case .powerSavingMode: controller.setPowerSavingMode(enabled)
        case .bluetoothStandby: controller.setBluetoothStandby(enabled)
        case .autoStandby: controller.setAutoStandby(enabled)
        default: XCTFail("Unexpected speaker setting")
        }
    }

    @MainActor
    private func canSet(_ setting: SonyHeadphonesController.Setting, controller: SonyHeadphonesController) -> Bool {
        switch setting {
        case .powerSavingMode: controller.canSetPowerSavingMode
        case .bluetoothStandby: controller.canSetBluetoothStandby
        default: controller.canSetAutoStandby
        }
    }

    @MainActor
    private func enabled(_ setting: SonyHeadphonesController.Setting, controller: SonyHeadphonesController) -> Bool? {
        switch setting {
        case .powerSavingMode: controller.powerFeatures.powerSavingMode?.enabled
        case .bluetoothStandby: controller.powerFeatures.bluetoothStandby?.enabled
        default: controller.powerFeatures.autoStandby?.enabled
        }
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Simulated command queue did not drain")
    }
}
