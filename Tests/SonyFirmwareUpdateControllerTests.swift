import XCTest
@testable import Acouplet

final class SonyFirmwareUpdateControllerTests: XCTestCase {
    @MainActor
    func testV2IdentityRequiresTransmittedTable1ReadAndResetsWithSession() {
        let controller = preparedController(legacy: false)
        defer { controller.simulateControlLoss() }
        let reply: [UInt8] = [0x37, 0x02] + field("HP002") + field("MDRID296300") + field("US") + field("English") + field("12345") + [0]
        deliver(reply, to: controller)
        XCTAssertNil(controller.firmwareUpdateIdentity)
        controller.defersSimulatedWrites = true
        controller.requestFirmwareUpdateIdentity()
        deliver(reply, to: controller)
        XCTAssertNil(controller.firmwareUpdateIdentity)
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        XCTAssertNil(controller.firmwareUpdateIdentity)
        controller.defersSimulatedWrites = false
        deliver(reply, type: 0x0E, to: controller)
        XCTAssertNil(controller.firmwareUpdateIdentity)
        deliver(reply, to: controller)
        XCTAssertEqual(controller.firmwareUpdateIdentity?.serviceID, "MDRID296300")
        let changedReply: [UInt8] = [0x37, 0x02] + field("HP002") + field("MDRID296302") + field("CN") + field("Chinese") + field("12345")
        deliver(changedReply, to: controller)
        XCTAssertEqual(controller.firmwareUpdateIdentity?.serviceID, "MDRID296300")
        controller.requestFirmwareUpdateIdentity()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload.first == 0x36 }.map(\.payload), [[0x36, 0x02]])
        XCTAssertNil(controller.firmwareUpdateSession)
        controller.simulateControlLoss()
        deliver(reply, to: controller)
        XCTAssertNil(controller.firmwareUpdateIdentity)
    }

    @MainActor
    func testLegacyIdentityUsesTwoSeparateOwnedReads() {
        let controller = preparedController(legacy: true)
        defer { controller.simulateControlLoss() }
        controller.requestFirmwareUpdateIdentity()
        acknowledgeAll(controller)
        deliver([0x37, 0x03] + field("MDRID294300"), to: controller)
        XCTAssertNil(controller.firmwareUpdateIdentity)
        deliver([0x37, 0x02] + field("HP002"), to: controller)
        XCTAssertEqual(controller.firmwareUpdateIdentity?.serviceID, "MDRID294300")
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x36 }.map(\.payload), [[0x36, 0x02], [0x36, 0x03]])
    }

    @MainActor
    private func preparedController(legacy: Bool) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        let protocolReply: [UInt8] = legacy ? [1, 0, 2, 0x10] : [1, 0, 3, 0, 0x30, 0x18, 0, 0]
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: protocolReply), beginConnection: true)
        acknowledgeAll(controller)
        deliver([0x05, 0x01] + field(legacy ? "WH-1000XM4" : "WF-1000XM5"), to: controller)
        deliver(legacy ? [7, 0, 2, 0x62, 0x30] : [7, 0, 2, 0x6B, 1, 0x32, 1], to: controller)
        acknowledgeAll(controller)
        deliver(legacy ? [0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15] : [0x61, 0x17, 1, 0, 2, 18, 3], to: controller)
        deliver(legacy ? [0x63, 2, 0] : [0x63, 0x17, 0], to: controller)
        acknowledgeAll(controller)
        deliver(legacy ? [0x67, 2, 1, 2, 0, 1, 0, 12] : [0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func field(_ string: String) -> [UInt8] { [UInt8(string.utf8.count)] + Array(string.utf8) }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: type, sequence: 0, payload: payload))
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The command queue did not drain.")
    }
}
