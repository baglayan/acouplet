import XCTest
@testable import Acouplet

@MainActor
final class SonyLegacyIndicatorsControllerTests: XCTestCase {
    func testNegotiatedFunctionsGateEachIndicatorAndOnlyItsLegacyQuery() {
        for mask in 0..<8 {
            let advertised = reads.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element.function }
            let controller = beginDiscovery(functions: advertised)
            defer { controller.simulateControlLoss() }
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.protocolInformation?.generation, .v1)
            XCTAssertEqual(controller.deviceModel, .wfXM4)
            XCTAssertEqual(controller.supportsCodecStatus, mask & 1 != 0)
            XCTAssertEqual(controller.supportsUpscalingStatus, mask & 2 != 0)
            XCTAssertEqual(controller.supportsConnectionStatus, mask & 4 != 0)
            for (index, read) in reads.enumerated() {
                XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, mask & (1 << index) != 0 ? 1 : 0)
                deliver(read.reply, to: controller)
                deliver(read.notification, to: controller)
            }
            var expected = SonyLegacyIndicators(supportedFunctions: Set(advertised))
            for read in reads { expected.update(read.notification) }
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertEqual(controller.audioCodec, expected.codec)
            XCTAssertEqual(controller.upscalingIndicatorType, expected.upscalingType)
            XCTAssertEqual(controller.upscalingIndicatorStatus, expected.upscalingStatus)
            XCTAssertEqual(controller.leftConnected, expected.leftConnected)
            XCTAssertEqual(controller.rightConnected, expected.rightConnected)
            XCTAssertEqual(controller.audioFeatures, SonyAudioFeatures())
            XCTAssertFalse(payloads(controller).contains([0x12, 1]))
            XCTAssertFalse(payloads(controller).contains([0x12, 2]))
        }
    }

    func testRepliesRequireCompletedTransmissionAndMalformedRepliesKeepOwnership() throws {
        for read in reads {
            let controller = beginDiscovery(functions: [read.function])
            defer { controller.simulateControlLoss() }
            let empty = controller.legacyIndicators
            deliver(read.reply, to: controller)
            XCTAssertEqual(controller.legacyIndicators, empty)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            controller.simulateLegacyOptionalReadTimeout(read.query)
            controller.defersSimulatedWrites = true
            advance(to: read.query, on: controller)
            controller.defersSimulatedWrites = false
            deliver(read.reply, to: controller)
            XCTAssertEqual(controller.legacyIndicators, empty)
            XCTAssertFalse(payloads(controller).contains(read.query))
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            controller.completeSimulatedWrite()
            acknowledgeAll(controller)
            let timeout = try XCTUnwrap(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            let malformed = [Array(read.reply.dropLast()), read.reply + [0],
                             [read.reply[0], read.reply[1] + 1] + Array(read.reply.dropFirst(2))]
            for reply in malformed { deliver(reply, to: controller) }
            deliver(read.reply, type: 0x0E, to: controller)
            XCTAssertEqual(controller.legacyIndicators, empty)
            XCTAssertEqual(controller.simulatedLegacyOptionalReadTimeoutID(read.query), timeout)
            deliver(read.reply, to: controller)
            var expected = empty
            expected.update(read.reply)
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            deliver([read.reply[0]] + read.notification.dropFirst(), to: controller)
            XCTAssertEqual(controller.legacyIndicators, expected)
        }
    }

    func testReplyStartingBeforeTheQueryCannotConsumeItsLaterOwnership() {
        for read in reads {
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1,
                                               payload: [read.reply[0]] + read.notification.dropFirst())
            for split in 1..<encoded.count {
                let controller = readyController()
                defer { controller.simulateControlLoss() }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: read.reply))
                let previous = controller.legacyIndicators
                controller.defersSimulatedWrites = true
                controller.refresh()
                advance(to: read.query, on: controller)
                controller.simulateProtocolData(encoded.prefix(split))
                controller.completeSimulatedWrite()
                controller.simulateProtocolData(encoded.dropFirst(split))
                controller.completeSimulatedWrite()
                XCTAssertEqual(controller.legacyIndicators, previous)
                XCTAssertNotNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
                controller.defersSimulatedWrites = false
                acknowledgeAll(controller)
                let reply = [read.reply[0]] + read.notification.dropFirst()
                deliver(reply, to: controller)
                var expected = previous
                expected.update(reply)
                XCTAssertEqual(controller.legacyIndicators, expected)
                XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            }
        }
    }

    func testNewerNotificationsSupersedeOwnedRepliesWithoutLosingOtherIndicators() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        var expected = controller.legacyIndicators
        for read in reads {
            deliver(read.notification, to: controller)
            expected.update(read.notification)
            deliver(Array(read.reply.dropLast()), to: controller)
            XCTAssertNotNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            deliver(read.reply, to: controller)
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
        }
        controller.refresh()
        acknowledgeAll(controller)
        for read in reads { deliver(read.reply, to: controller) }
        XCTAssertEqual(controller.audioCodec, .ldac)
        XCTAssertEqual(controller.upscalingIndicatorType, .dseeHXAI)
        XCTAssertEqual(controller.upscalingIndicatorStatus, .valid)
        XCTAssertEqual(controller.leftConnected, true)
        XCTAssertEqual(controller.rightConnected, false)
    }

    func testUnknownIndicatorValuesStayUnknownAndUpscalingCannotSetDSEE() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        for (raw, codec): (UInt8, SonyAudioCodec) in [(0, .unsettled), (0xFF, .other), (3, .unknown(3))] {
            deliver([0x1B, 0, raw], to: controller)
            XCTAssertEqual(controller.audioCodec, codec)
        }
        deliver([0x17, 0, 1, 2], to: controller)
        XCTAssertEqual(controller.upscalingIndicatorType, .dsee)
        XCTAssertEqual(controller.upscalingIndicatorStatus, .invalid)
        deliver([0x17, 0, 0xFF, 0xFE], to: controller)
        XCTAssertNil(controller.upscalingIndicatorType)
        XCTAssertNil(controller.upscalingIndicatorStatus)
        XCTAssertEqual(controller.legacyIndicators.upscalingTypeValue, 0xFF)
        XCTAssertEqual(controller.legacyIndicators.upscalingStatusValue, 0xFE)
        deliver([0x27, 1, 2, 0], to: controller)
        XCTAssertNil(controller.leftConnected)
        XCTAssertEqual(controller.rightConnected, false)
        deliver([0x27, 1, 1, 0xFF], to: controller)
        XCTAssertEqual(controller.leftConnected, true)
        XCTAssertNil(controller.rightConnected)
        XCTAssertTrue(controller.supportsUpscalingStatus)
        XCTAssertFalse(controller.supportsDSEE)
        XCTAssertNil(controller.dseeMode)
        let written = payloads(controller)
        controller.setDSEE(.automatic)
        XCTAssertEqual(payloads(controller), written)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testLegacyIndicatorsAndModernBatteryMessagesCannotCrossGenerationsOrTables() {
        let legacy = readyController()
        defer { legacy.simulateControlLoss() }
        let indicators = legacy.legacyIndicators
        let batteries = legacy.batteries
        for read in reads { deliver(read.notification, type: 0x0E, to: legacy) }
        for payload: [UInt8] in [[0x15, 2, 2], [0x15, 1, 0, 1], [0x25, 0, 91, 0], [0x25, 1, 73, 0, 84, 0]] {
            deliver(payload, to: legacy)
        }
        XCTAssertEqual(legacy.legacyIndicators, indicators)
        XCTAssertEqual(legacy.batteries, batteries)
        XCTAssertEqual(legacy.audioFeatures, SonyAudioFeatures())

        let modern = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { modern.simulateControlLoss() }
        modern.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(modern.protocolInformation?.generation, .v2)
        let audio = modern.audioFeatures
        let modernBatteries = modern.batteries
        for read in reads {
            deliver(read.reply, to: modern)
            deliver(read.notification, to: modern)
        }
        XCTAssertEqual(modern.legacyIndicators, SonyLegacyIndicators())
        XCTAssertEqual(modern.audioFeatures, audio)
        XCTAssertEqual(modern.batteries, modernBatteries)
        XCTAssertEqual(modern.audioCodec, audio.codec)
        XCTAssertEqual(modern.leftConnected, audio.leftConnected)
        XCTAssertEqual(modern.rightConnected, audio.rightConnected)
        XCTAssertFalse(modern.supportsUpscalingStatus)
        deliver([0x25, 0x09, 73, 0, 84, 0, 20, 20], to: modern)
        XCTAssertEqual(modern.batteries.left?.level, 73)
        XCTAssertEqual(modern.batteries.right?.level, 84)
        XCTAssertEqual(modern.legacyIndicators, SonyLegacyIndicators())
        XCTAssertEqual(modern.audioFeatures, audio)
    }

    func testTimeoutClearsOnlyItsIndicatorAndLateReplyRequestsFreshOwnedState() async {
        for read in reads {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            let session = controller.simulatedControlSession
            let noise = controller.noiseControlDisplayState
            let count = payloads(controller).filter { $0 == read.query }.count
            controller.simulateLegacyOptionalReadTimeout(read.query)
            for _ in 0..<4 { await Task.yield() }
            var expected = SonyLegacyIndicators(supportedFunctions: Set(reads.map(\.function)))
            for other in reads where other.query != read.query { expected.update(other.reply) }
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.noiseControlDisplayState, noise)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            deliver(Array(read.reply.dropLast()), to: controller)
            for _ in 0..<10 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, count)
            deliver(read.reply, to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, count + 1)
            XCTAssertNotNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            deliver(read.reply, to: controller)
            expected.update(read.reply)
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            XCTAssertNil(controller.lastErrorMessage)
        }
    }

    func testNotificationsBeforeOrAfterTimeoutRecoverStateAndLateRepliesCannotRewindIt() async {
        for read in reads {
            for notificationFirst in [false, true] {
                let controller = readyController()
                defer { controller.simulateControlLoss() }
                controller.refresh()
                acknowledgeAll(controller)
                var expected = controller.legacyIndicators
                expected.update(read.notification)
                if notificationFirst { deliver(read.notification, to: controller) }
                controller.simulateLegacyOptionalReadTimeout(read.query)
                for _ in 0..<4 { await Task.yield() }
                if !notificationFirst { deliver(read.notification, to: controller) }
                XCTAssertEqual(controller.legacyIndicators, expected)
                let count = payloads(controller).filter { $0 == read.query }.count
                deliver(read.reply, to: controller)
                acknowledgeAll(controller)
                XCTAssertEqual(controller.legacyIndicators, expected)
                XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, count + 1)
                let fresh = [read.reply[0]] + read.notification.dropFirst()
                deliver(fresh, to: controller)
                XCTAssertEqual(controller.legacyIndicators, expected)
                XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
            }
        }
    }

    func testSameTransportHandshakeRetainsExpiredIndicatorOwnershipUntilDrained() async {
        for read in reads {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            for other in reads where other.query != read.query { deliver(other.reply, to: controller) }
            deliver([0x63, 2, 0], to: controller)
            deliver([0x67, 2, 1, 2, 0, 1, 0, 12], to: controller)
            controller.simulateLegacyOptionalReadTimeout(read.query)
            for _ in 0..<4 { await Task.yield() }
            let count = payloads(controller).filter { $0 == read.query }.count
            let session = controller.simulatedControlSession
            controller.simulateSameTransportHandshake()
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
            negotiate(controller, functions: reads.map(\.function), beginConnection: false)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            let empty = controller.legacyIndicators
            XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, count)
            deliver(Array(read.reply.dropLast()), to: controller)
            XCTAssertEqual(controller.legacyIndicators, empty)
            XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, count)
            deliver(read.reply, to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(controller.legacyIndicators, empty)
            XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, count + 1)
            deliver(read.reply, to: controller)
            var expected = empty
            expected.update(read.reply)
            XCTAssertEqual(controller.legacyIndicators, expected)
            XCTAssertNil(controller.simulatedLegacyOptionalReadTimeoutID(read.query))
        }
    }

    func testRepeatedRefreshesCoalesceQueuedAndTransmittedIndicatorReads() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        for _ in 0..<10 {
            controller.refresh()
            controller.simulateAutomaticRefresh()
        }
        acknowledgeAll(controller)
        for _ in 0..<10 {
            controller.refresh()
            controller.simulateAutomaticRefresh()
        }
        acknowledgeAll(controller)
        for read in reads {
            XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, 2)
            deliver(read.reply, to: controller)
        }
        controller.refresh()
        acknowledgeAll(controller)
        for read in reads { XCTAssertEqual(payloads(controller).filter { $0 == read.query }.count, 3) }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
    }

    func testDisconnectAndRenegotiationClearIndicatorsAndRejectPreviousSessionMessages() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        for read in reads {
            deliver(read.notification, session: session, to: controller)
            controller.simulateLegacyOptionalReadTimeout(read.query)
        }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.legacyIndicators, SonyLegacyIndicators())
        XCTAssertFalse(controller.supportsCodecStatus)
        XCTAssertFalse(controller.supportsUpscalingStatus)
        XCTAssertFalse(controller.supportsConnectionStatus)
        XCTAssertNil(controller.audioCodec)
        XCTAssertNil(controller.leftConnected)
        XCTAssertNil(controller.rightConnected)
        negotiate(controller, functions: reads.map(\.function))
        let empty = controller.legacyIndicators
        for read in reads {
            deliver(read.reply, session: session, to: controller)
            controller.simulateLegacyOptionalReadTimeout(read.query)
        }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.legacyIndicators, empty)
        acknowledgeAll(controller)
        var expected = empty
        for read in reads {
            deliver(read.reply, to: controller)
            expected.update(read.reply)
        }
        XCTAssertEqual(controller.legacyIndicators, expected)
        XCTAssertTrue(controller.isReady)
    }

    @available(macOS 27.0, *)
    func testPreferenceSnapshotExposesReadOnlyLegacyIndicatorsAndRoundTrips() async throws {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        let server = SonyPreferencePaneServer(devices: SonyDeviceCoordinator(controller: controller))
        try server.start()
        defer { server.stop() }
        let reply = await server.reply(to: .init(version: SonyPreferencePaneWire.version, id: UUID(), action: .snapshot))
        XCTAssertNil(reply.error)
        let snapshot = try XCTUnwrap(reply.snapshot)
        let device = try XCTUnwrap(snapshot.devices.first)
        XCTAssertEqual(device.codec, SonyAudioCodec.ldac.title)
        XCTAssertEqual(device.upscalingType, SonyLegacyIndicators.UpscalingType.dseeHXAI.title)
        XCTAssertEqual(device.upscalingStatus, SonyLegacyIndicators.UpscalingStatus.valid.title)
        XCTAssertNil(device.dsee)
        XCTAssertNil(device.dseeTitle)
        XCTAssertEqual(try JSONDecoder().decode(SonyPreferencePaneSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    private func beginDiscovery(functions: [UInt8]? = nil) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        negotiate(controller, functions: functions ?? reads.map(\.function))
        return controller
    }

    private func negotiate(_ controller: SonyHeadphonesController, functions: [UInt8], beginConnection: Bool = true) {
        controller.simulateProtocolMessage([0x01, 0, 2, 0x10], beginConnection: beginConnection)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM4".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0x30, 0xFF], to: controller)
        deliver([0x07, 0, UInt8(functions.count + 1), 0x62] + functions, to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15], to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver([0x67, 2, 1, 2, 0, 1, 0, 12], to: controller)
    }

    private func readyController() -> SonyHeadphonesController {
        let controller = beginDiscovery()
        acknowledgeAll(controller)
        deliver([0x05, 2, 5] + Array("1.2.3".utf8), to: controller)
        for read in reads { deliver(read.reply, to: controller) }
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func advance(to query: [UInt8], on controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { break }
            if frame.payload == query { return }
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The requested indicator query was not queued.")
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, session: UInt64? = nil,
                         to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }

    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload)
    }

    private var reads: [(function: UInt8, query: [UInt8], reply: [UInt8], notification: [UInt8])] {
        [(0x13, [0x18, 0], [0x19, 0, 0x10], [0x1B, 0, 2]),
         (0x12, [0x14, 0], [0x15, 0, 2, 1], [0x17, 0, 1, 2]),
         (0x17, [0x24, 1], [0x25, 1, 1, 0], [0x27, 1, 0, 1])]
    }
}
