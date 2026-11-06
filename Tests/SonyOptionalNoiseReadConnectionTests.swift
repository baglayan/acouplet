import XCTest
@testable import Acouplet

@MainActor
final class SonyOptionalNoiseReadConnectionTests: XCTestCase {
    func testMissingInitialNoiseRepliesKeepTheSessionAndInitializeVolume() async {
        for legacy in [false, true] {
            for missing: UInt8 in [0x60, 0x62, 0x66] {
                let controller = beginDiscovery(legacy: legacy)
                defer { controller.simulateControlLoss() }
                let inquiry: UInt8 = legacy ? 2 : 0x17
                let query: [UInt8] = [missing, inquiry]
                if missing != 0x60 {
                    controller.simulateProtocolMessage(capability(legacy: legacy))
                    acknowledgeAll(controller)
                }
                if missing == 0x66 {
                    controller.simulateProtocolMessage([0x63, inquiry, 0])
                    acknowledgeAll(controller)
                }
                let session = controller.simulatedControlSession
                XCTAssertFalse(controller.isReady)
                XCTAssertNotNil(controller.simulatedNoiseReadTimeoutID(query))
                controller.simulateNoiseReadTimeout(query)
                for _ in 0..<4 { await Task.yield() }
                acknowledgeAll(controller)
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
                XCTAssertFalse(controller.canChangeNoiseControl)
                XCTAssertNil(controller.noiseControlMode)
                XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
                XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x50 })
                for reply in playbackReplies(legacy: legacy) {
                    controller.simulateProtocolMessage(reply)
                    acknowledgeAll(controller)
                }
                XCTAssertTrue(controller.canControlMusicVolume)
                XCTAssertEqual(controller.playback.volume, 12)
                let expiredQueries = controller.simulatedTransmittedFrames.filter { $0.payload == query }
                for _ in 0..<3 {
                    controller.requestCurrentSettings()
                    acknowledgeAll(controller)
                }
                XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == query }, expiredQueries)
                let lateReply = missing == 0x60 ? capability(legacy: legacy)
                    : missing == 0x62 ? [0x63, inquiry, 0] : state(legacy: legacy)
                controller.simulateProtocolMessage(lateReply)
                acknowledgeAll(controller)
                XCTAssertFalse(controller.canChangeNoiseControl)
                XCTAssertNil(controller.noiseControlMode)
                XCTAssertEqual(controller.simulatedControlSession, session)
                switch missing {
                case 0x60:
                    XCTAssertNil(controller.noiseControl?.capabilities)
                    XCTAssertNil(controller.legacyControls?.noiseCapability)
                case 0x62:
                    XCTAssertNil(controller.noiseControl?.available)
                    XCTAssertNil(controller.legacyControls?.noiseAvailable)
                default:
                    XCTAssertNil(controller.noiseControl?.state)
                    XCTAssertNil(controller.legacyControls?.noiseState)
                }
            }
        }
    }

    func testExpiredStateReadCannotConfirmAChangeAfterANewerNotification() async {
        for legacy in [false, true] {
            let controller = beginDiscovery(legacy: legacy)
            defer { controller.simulateControlLoss() }
            let inquiry: UInt8 = legacy ? 2 : 0x17
            for reply in [capability(legacy: legacy), [0x63, inquiry, 0], state(legacy: legacy)] {
                controller.simulateProtocolMessage(reply)
                acknowledgeAll(controller)
            }
            let session = controller.simulatedControlSession
            controller.requestCurrentSettings()
            acknowledgeAll(controller)
            controller.simulateProtocolMessage([0x63, inquiry, 0])
            acknowledgeAll(controller)
            controller.simulateNoiseReadTimeout([0x66, inquiry])
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.noiseControlMode)
            XCTAssertFalse(controller.canChangeNoiseControl)
            controller.simulateProtocolMessage(state(legacy: legacy))
            XCTAssertNil(controller.noiseControlMode)
            controller.simulateProtocolMessage([0x69] + state(legacy: legacy).dropFirst())
            XCTAssertTrue(controller.canChangeNoiseControl)
            controller.setNoiseControl(.anc)
            acknowledgeAll(controller)
            let requested = controller.pendingChanges[.noiseControl]
            XCTAssertNotNil(requested)
            if let requested {
                controller.simulateProtocolMessage([0x67] + requested)
                XCTAssertEqual(controller.pendingChanges[.noiseControl], requested)
                XCTAssertEqual(controller.noiseControlMode, .ambient)
                controller.simulateProtocolMessage([0x69] + requested)
            }
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            XCTAssertEqual(controller.noiseControlMode, .anc)
            XCTAssertEqual(controller.simulatedControlSession, session)
        }
    }

    func testNewerAvailabilityNotificationSurvivesItsReadTimeout() async {
        for legacy in [false, true] {
            let controller = beginDiscovery(legacy: legacy)
            defer { controller.simulateControlLoss() }
            let inquiry: UInt8 = legacy ? 2 : 0x17
            controller.simulateProtocolMessage(capability(legacy: legacy))
            acknowledgeAll(controller)
            controller.simulateProtocolMessage([0x65, inquiry, 1])
            controller.simulateNoiseReadTimeout([0x62, inquiry])
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(legacy ? controller.legacyControls?.noiseAvailable : controller.noiseControl?.available, false)
            controller.simulateProtocolMessage([0x63, inquiry, 0])
            XCTAssertEqual(legacy ? controller.legacyControls?.noiseAvailable : controller.noiseControl?.available, false)
        }
    }

    func testMissingNoiseCommandAcknowledgmentStillFailsTheTransport() async {
        for legacy in [false, true] {
            let controller = beginDiscovery(legacy: legacy, acknowledgeNoise: false)
            defer { controller.simulateControlLoss() }
            let session = controller.simulatedControlSession
            XCTAssertEqual(controller.simulatedPendingFrame?.payload.first, 0x60)
            for _ in 0..<2 {
                controller.simulateAcknowledgmentTimeout()
                for _ in 0..<4 { await Task.yield() }
            }
            XCTAssertFalse(controller.isReady)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.linkState, .failed("Headphones did not acknowledge a command."))
        }
    }

    private func beginDiscovery(legacy: Bool, acknowledgeNoise: Bool = true) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: legacy ? "WF-1000XM4" : "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage(legacy ? [0x01, 0, 2, 0x10] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        let functions: [UInt8] = [legacy ? 0x62 : 0x6B, legacy ? 0x51 : 0x50, 0xA1, 0x23]
        controller.simulateProtocolMessage([0x07, 0, UInt8(functions.count)] + (legacy ? functions : functions.flatMap { [$0, 0] }))
        if acknowledgeNoise { acknowledgeAll(controller) }
        return controller
    }

    private func capability(legacy: Bool) -> [UInt8] {
        legacy ? [0x61, 2, 2, 3, 1, 1, 0, 20] : [0x61, 0x17, 1, 0, 1, 20, 1]
    }

    private func state(legacy: Bool) -> [UInt8] {
        legacy ? [0x67, 2, 1, 2, 0, 1, 0, 12] : [0x67, 0x17, 1, 1, 1, 0, 12]
    }

    private func playbackReplies(legacy: Bool) -> [[UInt8]] {
        legacy ? [[0xA1, 1, 31, 1, 0], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, 12]]
            : [[0xA1, 1, 31, 16], [0xA3, 1, 0, 2, 0], [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0],
               [0xA7, 0x20, 12], [0xA7, 0x21, 7]]
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The command queue did not drain.")
    }
}
