import XCTest
@testable import Acouplet

@MainActor
final class SonyWearingStatusControllerTests: XCTestCase {
    func testCheckerRequiresAdvertisedCapabilityAndIsNeverPolled() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF5, 0, 4], to: controller)
        XCTAssertNil(controller.wearingStatus.state)
        let supported = readyController()
        defer { supported.simulateControlLoss() }
        XCTAssertTrue(supported.wearingStatus.isSupported)
        for _ in 0..<5 { supported.simulateAutomaticRefresh() }
        acknowledgeAll(supported)
        XCTAssertFalse(supported.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == SonyWearingStatus.queryPayload })
        XCTAssertNil(supported.wearingStatus.state)
        XCTAssertNil(supported.wearingStatusReadID)
    }

    func testOnlyWrittenOwnedReplySatisfiesFreshRead() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertNil(controller.wearingStatus.state)
        controller.defersSimulatedWrites = true
        let request = try XCTUnwrap(controller.refreshWearingStatus())
        controller.defersSimulatedWrites = false
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.wearingStatus.state)
        controller.completeSimulatedWrite()
        deliver([0xF3, 0, 4], type: 0x0C, to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        deliver([0xF3, 0, 2], to: controller)
        XCTAssertEqual(controller.wearingStatusReadID, request)
        XCTAssertEqual(controller.wearingStatus.leftWorn, false)
        XCTAssertEqual(controller.wearingStatus.rightWorn, true)
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.refreshWearingStatus())
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.wearingStatus.state)
    }

    func testTimedOutReadBlocksRetryUntilItsLateReplyIsDrained() async throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let first = try XCTUnwrap(controller.refreshWearingStatus())
        acknowledgeAll(controller)
        controller.simulateWearingStatusReadTimeout()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.wearingStatus.state)
        let second = try XCTUnwrap(controller.refreshWearingStatus())
        XCTAssertNotEqual(first, second)
        deliver([0xF3, 0, 0], to: controller)
        XCTAssertEqual(controller.wearingStatusReadID, second)
        XCTAssertEqual(controller.wearingStatus.leftWorn, true)
        XCTAssertEqual(controller.wearingStatus.rightWorn, true)
    }

    func testNotificationSupersedesReadAndMalformedReportInvalidatesKnownRemoval() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        XCTAssertNotNil(controller.refreshWearingStatus())
        acknowledgeAll(controller)
        deliver([0xF5, 0, 0], to: controller)
        XCTAssertEqual(controller.wearingStatus.state, .bothWorn)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertEqual(controller.wearingStatus.state, .bothWorn)
        XCTAssertNil(controller.wearingStatusReadID)
        let request = try XCTUnwrap(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertEqual(controller.wearingStatusReadID, request)
        deliver([0xF5, 0, 4, 0], to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.wearingStatus.state)
        deliver([0xF5, 0, 0xFF], to: controller)
        XCTAssertNil(controller.wearingStatus.leftWorn)
        XCTAssertNil(controller.wearingStatus.rightWorn)
    }

    func testConnectionChangeRetiresReadAndUnownedCapabilitiesCannotChangeSupport() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        deliver([0x15, 1, 1, 1], type: 0x0C, to: controller)
        XCTAssertNotNil(controller.refreshWearingStatus())
        acknowledgeAll(controller)
        deliver([0x15, 1, 1, 0], type: 0x0C, to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.wearingStatus.state)
        let request = try XCTUnwrap(controller.refreshWearingStatus())
        acknowledgeAll(controller)
        deliver([0x07, 0, 0], to: controller)
        XCTAssertTrue(controller.wearingStatus.isSupported)
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertEqual(controller.wearingStatusReadID, request)
        XCTAssertEqual(controller.wearingStatus.leftWorn, false)
        XCTAssertEqual(controller.wearingStatus.rightWorn, false)
        XCTAssertNotNil(controller.refreshWearingStatus())
    }

    func testControlLossAndLateWriteCannotPopulateNewSession() throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        XCTAssertNotNil(controller.refreshWearingStatus())
        controller.defersSimulatedWrites = false
        let oldSession = controller.simulatedControlSession
        controller.simulateControlLoss(deviceConnected: false)
        XCTAssertFalse(controller.wearingStatus.isSupported)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.refreshWearingStatus())
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0xF0])
        let request = try XCTUnwrap(controller.refreshWearingStatus())
        controller.completeSimulatedWrite()
        deliver([0xF3, 0, 4], session: oldSession, to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        deliver([0xF3, 0, 0], to: controller)
        XCTAssertEqual(controller.wearingStatusReadID, request)
        XCTAssertEqual(controller.wearingStatus.state, .bothWorn)
    }

    private func readyController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0xF0])
        return controller
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<200 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, session: UInt64? = nil, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }
}
