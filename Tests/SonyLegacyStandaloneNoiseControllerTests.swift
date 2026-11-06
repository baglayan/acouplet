import XCTest
@testable import Acouplet

@MainActor
final class SonyLegacyStandaloneNoiseControllerTests: XCTestCase {
    func testFirstConnectionReadsEachAdvertisedStandaloneDomainWithoutCombinedNoise() {
        for inquiries: [UInt8] in [[1], [3], [1, 3]] {
            let controller = beginDiscovery(inquiries: inquiries)
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.isReady)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            acknowledgeAll(controller)
            for inquiry in inquiries {
                for command: UInt8 in [0x60, 0x62, 0x66] {
                    XCTAssertTrue(payloads(controller).contains([command, inquiry]))
                }
                XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
                for reply in replies(inquiry) { deliver(reply, to: controller) }
                XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry))
            }
            XCTAssertFalse(payloads(controller).contains([0x60, 2]))
            XCTAssertNil(controller.legacyControls?.noiseCapability)
            XCTAssertTrue(controller.availableNoiseModes.isEmpty)
            XCTAssertTrue(controller.isReady)
        }
    }

    func testReturnsRequireWrittenQueriesAndExactTableWhileMalformedRepliesKeepOwnership() {
        let controller = beginDiscovery(inquiries: [1, 3], deferWrites: true)
        defer { controller.simulateControlLoss() }
        for inquiry: UInt8 in [1, 3] {
            for reply in replies(inquiry) { deliver(reply, to: controller) }
            XCTAssertNil(controller.standaloneNoiseControl(inquiry)?.capability)
            XCTAssertNil(controller.standaloneNoiseControl(inquiry)?.available)
            XCTAssertNil(controller.standaloneNoiseControl(inquiry)?.state)
        }
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        for inquiry: UInt8 in [1, 3] {
            for reply in replies(inquiry) { deliver(reply, type: 0x0E, to: controller) }
            deliver([0x61, inquiry], to: controller)
            deliver([0x63, inquiry, 255], to: controller)
            deliver([0x67, inquiry], to: controller)
            XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
            for reply in replies(inquiry) { deliver(reply, to: controller) }
            XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry))
            deliver(parameter(inquiry, enabled: true), to: controller)
            deliver([0x63, inquiry, 1], to: controller)
            XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, false)
            XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.available, true)
        }
    }

    func testSetConfirmationUsesOwnedReadAndMatchingDomainIncludingDeclaredNCTypeOne() {
        for inquiry: UInt8 in [1, 3] {
            let controller = readyController(ncType: 1)
            defer { controller.simulateControlLoss() }
            controller.setStandaloneNoiseControl(inquiry, enabled: true)
            acknowledgeAll(controller)
            XCTAssertTrue(payloads(controller).contains(inquiry == 1 ? [0x68, 1, 0, 1] : [0x68, 3, 1, 0, 0, 1]))
            let pending = controller.pendingChanges[.noiseControl]
            XCTAssertEqual(pending?.first, inquiry)
            controller.refresh()
            acknowledgeAll(controller)
            XCTAssertTrue(payloads(controller).contains([0x66, inquiry]))
            let other: UInt8 = inquiry == 1 ? 3 : 1
            deliver(parameter(other, enabled: true, notification: true), to: controller)
            deliver(parameter(inquiry, enabled: true), type: 0x0E, to: controller)
            XCTAssertEqual(controller.pendingChanges[.noiseControl], pending)
            deliver(parameter(inquiry, enabled: true, ncType: 1), to: controller)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, true)
        }
    }

    func testStandaloneReadRetriesRequireAdvertisedInquiryAndCorrectTable() {
        for inquiries: [UInt8] in [[1], [3], [1, 3]] {
            let controller = readyController(inquiries: inquiries)
            defer { controller.simulateControlLoss() }
            for inquiry: UInt8 in [1, 2, 3, 255] {
                for command: UInt8 in [0x60, 0x62, 0x66] {
                    let payload = [command, inquiry]
                    XCTAssertEqual(controller.canRetryRead(SonyFrame(type: 0x0C, sequence: 0, payload: payload)), inquiries.contains(inquiry))
                    XCTAssertFalse(controller.canRetryRead(SonyFrame(type: 0x0E, sequence: 0, payload: payload)))
                }
            }
        }
    }

    func testStandaloneSetRetriesPreserveFrameAndRequireOwnedValidPendingValue() async throws {
        for inquiry: UInt8 in [1, 3] {
            let controller = readyController(inquiries: [inquiry], ncType: 1)
            defer { controller.simulateControlLoss() }
            controller.setStandaloneNoiseControl(inquiry, enabled: true)
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, inquiry == 1 ? [0x68, 1, 0, 1] : [0x68, 3, 1, 0, 0, 1])
            XCTAssertTrue(controller.availableNoiseModes.isEmpty)
            XCTAssertTrue(controller.canRetryBasicCommand(frame))
            XCTAssertFalse(controller.canRetryBasicCommand(SonyFrame(type: 0x0E, sequence: frame.sequence, payload: frame.payload)))
            let invalid: [[UInt8]] = inquiry == 1
                ? [[0x68, 1, 0, 0], [0x68, 1, 255, 1], [0x68, 3, 1, 0, 0, 1]]
                : [[0x68, 3, 0, 0, 0, 0], [0x68, 3, 1, 255, 0, 1], [0x68, 3, 1, 0, 255, 1], [0x68, 1, 0, 1]]
            for payload in invalid + [[0x68, 255, 0, 1]] {
                XCTAssertFalse(controller.canRetryBasicCommand(SonyFrame(type: 0x0C, sequence: frame.sequence, payload: payload)))
            }
            let pending = controller.pendingChanges[.noiseControl]
            let count = controller.simulatedTransmittedFrames.filter { $0 == frame }.count
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, count + 1)
            XCTAssertEqual(controller.pendingChanges[.noiseControl], pending)
            acknowledgeAll(controller)
            deliver(parameter(inquiry, enabled: true, notification: true, ncType: 1), to: controller)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            XCTAssertFalse(controller.canRetryBasicCommand(frame))
        }
    }

    func testOldPollCannotUndoNotificationOrConfirmALaterSet() {
        for inquiry: UInt8 in [1, 3] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            let reads = payloads(controller).filter { $0 == [0x66, inquiry] }.count
            deliver(parameter(inquiry, enabled: true, notification: true), to: controller)
            controller.setStandaloneNoiseControl(inquiry, enabled: false)
            acknowledgeAll(controller)
            deliver(parameter(inquiry, enabled: false), to: controller)
            XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, true)
            XCTAssertNotNil(controller.pendingChanges[.noiseControl])
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == [0x66, inquiry] }.count, reads + 1)
            deliver(parameter(inquiry, enabled: false), to: controller)
            XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, false)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
        }
    }

    func testAvailabilityNotificationSupersedesOldReturnAndDisablesOnlyItsDomain() {
        for inquiry: UInt8 in [1, 3] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0x65, inquiry, 1], to: controller)
            deliver([0x63, inquiry, 0], to: controller)
            XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
            XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry == 1 ? 3 : 1))
            let sent = payloads(controller)
            controller.setStandaloneNoiseControl(inquiry, enabled: true)
            XCTAssertEqual(payloads(controller), sent)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            deliver([0x65, inquiry, 0], to: controller)
            XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry))
        }
    }

    func testNotificationStartingBeforeSetTransmissionCannotConfirmAfterward() {
        for inquiry: UInt8 in [1, 3] {
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: parameter(inquiry, enabled: true, notification: true))
            for split in 1...encoded.count {
                let controller = readyController(inquiries: [inquiry])
                defer { controller.simulateControlLoss() }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0,
                    payload: parameter(inquiry, enabled: false, notification: true)))
                controller.defersSimulatedWrites = true
                controller.setStandaloneNoiseControl(inquiry, enabled: true)
                let pending = controller.pendingChanges[.noiseControl]
                controller.simulateProtocolData(encoded.prefix(split))
                controller.completeSimulatedWrite()
                if split < encoded.count { controller.simulateProtocolData(encoded.dropFirst(split)) }
                controller.completeSimulatedWrite()
                XCTAssertNotNil(pending)
                XCTAssertEqual(controller.pendingChanges[.noiseControl], pending)
                controller.defersSimulatedWrites = false
                acknowledgeAll(controller)
                deliver(parameter(inquiry, enabled: true, notification: true), to: controller)
                XCTAssertNil(controller.pendingChanges[.noiseControl])
            }
        }
    }

    func testParameterReturnStartingBeforeQueryCannotConsumeTheNewRead() {
        for inquiry: UInt8 in [1, 3] {
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: parameter(inquiry, enabled: true))
            for split in [1, encoded.count / 2, encoded.count - 1] {
                let controller = readyController(inquiries: [inquiry])
                defer { controller.simulateControlLoss() }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0,
                    payload: parameter(inquiry, enabled: false, notification: true)))
                controller.defersSimulatedWrites = true
                controller.refresh()
                for _ in 0..<100 {
                    guard let frame = controller.simulatedPendingFrame, frame.payload != [0x66, inquiry] else { break }
                    controller.completeSimulatedWrite()
                    controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
                }
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x66, inquiry])
                controller.simulateProtocolData(encoded.prefix(split))
                controller.completeSimulatedWrite()
                controller.simulateProtocolData(encoded.dropFirst(split))
                controller.completeSimulatedWrite()
                XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, false)
                controller.defersSimulatedWrites = false
                acknowledgeAll(controller)
                deliver(parameter(inquiry, enabled: true), to: controller)
                XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, true)
            }
        }
    }

    func testReadTimeoutStartsAtTransmissionAndLateReturnMustDrainBeforeFreshRecovery() async {
        for inquiry: UInt8 in [1, 3] {
            for missing in replies(inquiry) {
                let query: [UInt8] = [missing[0] - 1, inquiry]
                let controller = beginDiscovery(inquiries: [1, 3], deferWrites: true)
                defer { controller.simulateControlLoss() }
                controller.simulateSystemReadTimeout(query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNil(controller.settingErrors[.noiseControl])
                controller.defersSimulatedWrites = false
                controller.completeSimulatedWrite()
                acknowledgeAll(controller)
                for domain: UInt8 in [1, 3] {
                    for reply in replies(domain) where reply != missing { deliver(reply, to: controller) }
                }
                let session = controller.simulatedControlSession
                controller.simulateSystemReadTimeout(query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                XCTAssertEqual(controller.simulatedControlSession, session)
                XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
                XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry == 1 ? 3 : 1))
                let count = payloads(controller).filter { $0 == query }.count
                deliver(Array(missing.dropLast()), to: controller)
                acknowledgeAll(controller)
                XCTAssertEqual(payloads(controller).filter { $0 == query }.count, count)
                deliver(missing, to: controller)
                XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
                acknowledgeAll(controller)
                XCTAssertEqual(payloads(controller).filter { $0 == query }.count, count + 1)
                deliver(missing, to: controller)
                XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry))
                XCTAssertNil(controller.settingErrors[.noiseControl])
                XCTAssertEqual(controller.simulatedControlSession, session)
            }
        }
    }

    func testTimedOutSetRecoversFromAFreshOwnedReturnWithoutRequiringNotification() async {
        for inquiry: UInt8 in [1, 3] {
            let controller = readyController(inquiries: [inquiry])
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            controller.setStandaloneNoiseControl(inquiry, enabled: true)
            acknowledgeAll(controller)
            controller.simulateSettingTimeout(.noiseControl)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            XCTAssertNotNil(controller.settingErrors[.noiseControl])
            XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
            deliver(parameter(inquiry, enabled: false), to: controller)
            XCTAssertFalse(controller.canSetStandaloneNoiseControl(inquiry))
            acknowledgeAll(controller)
            deliver(parameter(inquiry, enabled: true), to: controller)
            XCTAssertNil(controller.settingErrors[.noiseControl])
            XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry))
            XCTAssertEqual(controller.standaloneNoiseControl(inquiry)?.enabled, true)
        }
    }

    func testCombinedAndOtherStandaloneNotificationsCannotClearStandaloneUncertainty() async {
        let controller = readyController(inquiries: [1, 2, 3])
        defer { controller.simulateControlLoss() }
        controller.setStandaloneNoiseControl(1, enabled: true)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.pendingChanges[.noiseControl], [1, 1])
        controller.simulateSettingTimeout(.noiseControl)
        for _ in 0..<4 { await Task.yield() }
        let error = controller.settingErrors[.noiseControl]
        XCTAssertNotNil(error)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertFalse(controller.canSetStandaloneNoiseControl(1))
        deliver([0x69, 2, 1, 2, 2, 1, 0, 0], to: controller)
        deliver(parameter(3, enabled: true, notification: true), to: controller)
        XCTAssertEqual(controller.settingErrors[.noiseControl], error)
        XCTAssertFalse(controller.canSetStandaloneNoiseControl(1))
        deliver(parameter(1, enabled: true, notification: true), to: controller)
        XCTAssertNil(controller.settingErrors[.noiseControl])
        XCTAssertTrue(controller.canSetStandaloneNoiseControl(1))
    }

    func testTimedOutCombinedPollDoesNotSuppressStandaloneParameterReads() async {
        let controller = readyController(inquiries: [1, 2, 3])
        defer { controller.simulateControlLoss() }
        controller.requestCurrentSettings()
        acknowledgeAll(controller)
        deliver([0x69, 2, 1, 2, 0, 1, 0, 12], to: controller)
        for inquiry: UInt8 in [1, 3] {
            for reply in replies(inquiry) { deliver(reply, to: controller) }
        }
        controller.simulateNoiseReadTimeout([0x66, 2])
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        let count = payloads(controller).filter { $0 == [0x66, 1] }.count
        controller.requestCurrentSettings()
        acknowledgeAll(controller)
        XCTAssertEqual(payloads(controller).filter { $0 == [0x66, 1] }.count, count + 1)
        deliver(parameter(1, enabled: true), to: controller)
        XCTAssertEqual(controller.standaloneNoiseControl(1)?.enabled, true)
    }

    func testSessionResetDiscardsOldRepliesPendingWritesAndReadTimeouts() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.setStandaloneNoiseControl(3, enabled: true)
        acknowledgeAll(controller)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        connect(controller, inquiries: [1])
        acknowledgeAll(controller)
        for reply in replies(1) { deliver(reply, to: controller) }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        deliver(parameter(3, enabled: true, notification: true), session: session, to: controller)
        deliver(parameter(1, enabled: true, notification: true), session: session, to: controller)
        controller.simulateSystemReadTimeout([0x66, 3])
        controller.simulateSettingTimeout(.noiseControl)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(controller.standaloneNoiseControl(3))
        XCTAssertEqual(controller.standaloneNoiseControl(1)?.enabled, false)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertNil(controller.settingErrors[.noiseControl])
        XCTAssertTrue(controller.canSetStandaloneNoiseControl(1))
    }

    private func beginDiscovery(inquiries: [UInt8], deferWrites: Bool = false) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        connect(controller, inquiries: inquiries, deferWrites: deferWrites)
        return controller
    }

    private func connect(_ controller: SonyHeadphonesController, inquiries: [UInt8], deferWrites: Bool = false) {
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WH-1000XM3".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0x20, 0], to: controller)
        controller.defersSimulatedWrites = deferWrites
        deliver([0x07, 0, UInt8(inquiries.count)] + inquiries.map { 0x60 + $0 }, to: controller)
        if inquiries.contains(2) {
            acknowledgeAll(controller)
            deliver([0x61, 2, 2, 3, 1, 2, 0, 20, 1, 20], to: controller)
            deliver([0x63, 2, 0], to: controller)
            acknowledgeAll(controller)
            deliver([0x67, 2, 1, 2, 0, 1, 0, 12], to: controller)
        }
    }

    private func readyController(inquiries: [UInt8] = [1, 3], ncType: UInt8 = 0) -> SonyHeadphonesController {
        let controller = beginDiscovery(inquiries: inquiries)
        acknowledgeAll(controller)
        for inquiry in inquiries where inquiry != 2 {
            for reply in replies(inquiry, ncType: ncType) { deliver(reply, to: controller) }
            XCTAssertTrue(controller.canSetStandaloneNoiseControl(inquiry))
        }
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func replies(_ inquiry: UInt8, ncType: UInt8 = 0) -> [[UInt8]] {
        let capability: [UInt8] = inquiry == 1 ? [0x61, 1, ncType] : [0x61, 3, 0, 2, 0, 2, 1, 2]
        return [capability, [0x63, inquiry, 0], parameter(inquiry, enabled: false, ncType: ncType)]
    }

    private func parameter(_ inquiry: UInt8, enabled: Bool, notification: Bool = false, ncType: UInt8 = 0) -> [UInt8] {
        let command: UInt8 = notification ? 0x69 : 0x67
        return inquiry == 1 ? [command, 1, ncType, enabled ? 1 : 0] : [command, 3, enabled ? 1 : 0, 0, 0, enabled ? 1 : 0]
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, session: UInt64? = nil, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<150 {
            controller.completeSimulatedWrite()
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload)
    }
}
