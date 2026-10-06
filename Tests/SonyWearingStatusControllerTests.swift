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
        advertiseChecker(on: controller)
        XCTAssertTrue(controller.wearingStatus.isSupported)
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == SonyWearingStatus.queryPayload })
        XCTAssertNil(controller.wearingStatus.state)
        XCTAssertNil(controller.wearingStatusReadID)
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

    func testConnectionAndCapabilityChangesRetirePendingRead() throws {
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
        XCTAssertNotNil(controller.refreshWearingStatus())
        acknowledgeAll(controller)
        deliver([0x07, 0, 0], to: controller)
        XCTAssertFalse(controller.wearingStatus.isSupported)
        advertiseChecker(on: controller)
        XCTAssertNil(controller.refreshWearingStatus())
        deliver([0xF3, 0, 4], to: controller)
        XCTAssertNil(controller.wearingStatusReadID)
        XCTAssertNil(controller.wearingStatus.state)
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
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        advertiseChecker(on: controller)
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
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        advertiseChecker(on: controller)
        return controller
    }

    private func advertiseChecker(on controller: SonyHeadphonesController) {
        deliver([0x07, 0, 1, 0xF0, 0], to: controller)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<200 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, session: UInt64? = nil, to controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: 0, payload: payload), session: session)
    }
}
