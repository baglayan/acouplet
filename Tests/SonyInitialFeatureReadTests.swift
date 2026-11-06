import XCTest
@testable import Acouplet

@MainActor
final class SonyInitialFeatureReadTests: XCTestCase {
    func testInitialAudioAndSystemQueriesRequireOwnedReplyAndACK() throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            for replyFirst in [false, true] {
                let controller = makeController(generation: generation)
                defer { controller.simulateControlLoss() }
                let replies = initialReplies(generation: generation)
                let queries = replies.map { [$0[0] - 1, $0[1]] }
                for (index, reply) in replies.enumerated() {
                    let frame = try XCTUnwrap(controller.simulatedPendingFrame)
                    XCTAssertEqual(frame.payload, queries[index])
                    XCTAssertEqual(featureQueries(controller), Array(queries.prefix(index + 1)))
                    if replyFirst {
                        controller.simulateProtocolMessage(reply)
                        XCTAssertEqual(controller.simulatedPendingFrame, frame)
                        acknowledge(frame, on: controller)
                    } else {
                        acknowledge(frame, on: controller)
                        XCTAssertNil(controller.simulatedPendingFrame)
                        controller.simulateProtocolMessage(reply)
                    }
                }
                XCTAssertNil(controller.simulatedPendingFrame)
                XCTAssertEqual(featureQueries(controller), queries)
                XCTAssertTrue(controller.canSetDSEE)
                XCTAssertTrue(controller.isReady)
                XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
                if generation == .v1 {
                    XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, true)
                } else {
                    XCTAssertEqual(controller.systemFeatures.voiceAssistant?.current?.rawValue, 0x30)
                }
            }
        }
    }

    func testInitialCapabilitiesIgnoreUnownedMalformedUnknownAndNotificationValues() throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeController(generation: generation)
            defer { controller.simulateControlLoss() }
            let legacy = generation == .v1
            let replies = initialReplies(generation: generation)
            let query = try XCTUnwrap(controller.simulatedPendingFrame).payload
            acknowledgeSimulatedCommands(controller)
            for reply: [UInt8] in [[0xE1, legacy ? 1 : 2, 0], [0xE1, query[1]],
                                  legacy ? [0xE1, 2, 0xFF, 0] : [0xE1, 1, 0xFF],
                                  [0xE5, query[1], 0], legacy ? [0xE9, 2, 0, 1] : [0xE9, 1, 1], replies[3]] {
                controller.simulateProtocolMessage(reply)
                XCTAssertNil(controller.simulatedPendingFrame)
                XCTAssertEqual(featureQueries(controller), [query])
            }
            controller.simulateProtocolMessage(replies[0])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE2, query[1]])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xE3, query[1], 1])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE6, query[1]])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage(replies[2])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF0, replies[3][1]])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage(legacy ? [0xF1, 3, 0xFF] : [0xF1, 4, 0xFF, 1, 0x30])
            XCTAssertNil(controller.simulatedPendingFrame)
            controller.simulateProtocolMessage(replies[3])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF2, replies[3][1]])
            XCTAssertFalse(controller.canSetDSEE)
        }
    }

    func testInitialFeatureTimeoutSkipsOnlyItsGroupAndRefreshCannotBypassIt() async throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeController(generation: generation)
            defer { controller.simulateControlLoss() }
            let replies = initialReplies(generation: generation)
            let first = try XCTUnwrap(controller.simulatedPendingFrame).payload
            acknowledgeSimulatedCommands(controller)
            controller.requestCurrentSettings()
            XCTAssertEqual(featureQueries(controller), [first])
            controller.simulateInitialFeatureReadTimeout()
            for _ in 0..<8 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF0, replies[3][1]])
            controller.simulateProtocolMessage(replies[0])
            XCTAssertFalse(featureQueries(controller).contains([0xE2, first[1]]))
            for reply in replies.suffix(3) {
                controller.simulateProtocolMessage(reply)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.canSetDSEE)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(featureQueries(controller), [first] + replies.suffix(3).map { [$0[0] - 1, $0[1]] })
        }
    }

    func testWaitingInitialSystemCapabilityAllowsIndependentDSEECommandAndNotification() throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeController(generation: generation)
            defer { controller.simulateControlLoss() }
            let replies = initialReplies(generation: generation)
            for reply in replies.prefix(3) {
                controller.simulateProtocolMessage(reply)
                acknowledgeSimulatedCommands(controller)
            }
            XCTAssertTrue(controller.canSetDSEE)
            XCTAssertNil(controller.simulatedPendingFrame)
            controller.setDSEE(.off)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, generation == .v1 ? [0xE8, 2, 0, 0] : [0xE8, 1, 0])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage(generation == .v1 ? [0xE9, 2, 0, 0] : [0xE9, 1, 0])
            XCTAssertNil(controller.pendingChanges[.dsee])
            XCTAssertEqual(controller.dseeMode, .off)
            XCTAssertFalse(featureQueries(controller).contains([0xF2, replies[3][1]]))
            controller.simulateProtocolMessage(replies[3])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF2, replies[3][1]])
        }
    }

    func testInitialFeatureReadsResumeAfterOptimizerWithoutSkippingPendingReply() throws {
        let controller = makeController(generation: .v1, functions: [0xE2, 0xF3, 0x81])
        defer { controller.simulateControlLoss() }
        let replies = initialReplies(generation: .v1)
        let queries = replies.map { [$0[0] - 1, $0[1]] }
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.beginLegacyOptimizer())
        let id = try XCTUnwrap(controller.legacyOptimizerTransition?.id)
        controller.simulateProtocolMessage(replies[0])
        controller.requestCurrentSettings()
        XCTAssertEqual(featureQueries(controller), [queries[0]])
        for reply: [UInt8] in [[0x81, 1, 5, 1, 3, 1, 4], [0x83, 1, 0, 0], [0x87, 1, 1, 0, 1, 10]] {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, [reply[0] - 1, reply[1]])
            controller.simulateProtocolMessage(reply)
            acknowledge(frame, on: controller)
        }
        XCTAssertEqual(controller.legacyOptimizerTransition?.phase, .ready)
        controller.dismissLegacyOptimizer(id: id)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        controller.requestCurrentSettings()
        for (index, reply) in replies.enumerated().dropFirst() {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, queries[index])
            if index == 1 {
                controller.requestCurrentSettings()
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
            }
            acknowledge(frame, on: controller)
            if index == 1 { controller.requestCurrentSettings() }
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(featureQueries(controller), Array(queries.prefix(index + 1)))
            controller.simulateProtocolMessage(reply)
        }
        XCTAssertEqual(featureQueries(controller), queries)
        XCTAssertTrue(controller.canSetDSEE)
        XCTAssertEqual(controller.systemFeatureState(.pauseOnRemoval)?.enabled, true)
        XCTAssertTrue(controller.isReady)
    }

    func testNewerStatusNotificationRequiresReplacementBeforeInitialParameterQuery() throws {
        let controller = makeController(generation: .v2)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolMessage([0xE1, 1, 2])
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0xE5, 1, 1])
        controller.simulateProtocolMessage([0xE3, 1, 0])
        let replacement = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(replacement.payload, [0xE2, 1])
        XCTAssertEqual(controller.audioFeatures.dseeAvailable, false)
        XCTAssertFalse(featureQueries(controller).contains([0xE6, 1]))
        controller.simulateProtocolMessage([0xE3, 1, 1])
        XCTAssertEqual(controller.simulatedPendingFrame, replacement)
        acknowledge(replacement, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE6, 1])
        XCTAssertEqual(featureQueries(controller).filter { $0 == [0xE2, 1] }.count, 2)
    }

    func testInitialStatusResponseBeforeNativeWriteCannotAdvanceAcquisition() throws {
        let controller = makeController(generation: .v2)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolMessage([0xE1, 1, 2])
        let capability = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.defersSimulatedWrites = true
        acknowledge(capability, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE2, 1])
        controller.simulateProtocolMessage([0xE3, 1, 0])
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        XCTAssertNil(controller.audioFeatures.dseeAvailable)
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(featureQueries(controller).contains([0xE6, 1]))
        controller.simulateProtocolMessage([0xE3, 1, 0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE6, 1])
    }

    func testResetRejectsOldSessionCapabilitiesDuringNewInitialAcquisition() throws {
        for generation in [SonyProtocolInfo.Generation.v1, .v2] {
            let controller = makeController(generation: generation)
            defer { controller.simulateControlLoss() }
            acknowledgeSimulatedCommands(controller)
            let oldSession = controller.simulatedControlSession
            controller.simulateControlLoss()
            connect(controller, generation: generation)
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            let reply = initialReplies(generation: generation)[0]
            controller.simulateProtocolMessage(reply, session: oldSession)
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertNil(controller.dseeType)
            acknowledge(frame, on: controller)
            XCTAssertNil(controller.simulatedPendingFrame)
            controller.simulateProtocolMessage(reply)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE2, reply[1]])
        }
    }

    func testTouchCapabilityAddsCustomReadAfterStatusAndSelection() throws {
        let controller = makeController(generation: .v2, functions: [0xF3], firstQuery: [0xF0, 3])
        defer { controller.simulateControlLoss() }
        let replies: [[UInt8]] = [[0xF1, 3, 1, 1, 1, 0x10, 1, 0x10, 0, 1, 0, 0x20, 1, 0x20],
                                  [0xF3, 3, 1, 0], [0xF7, 3, 1, 0x10], [0xFB, 3, 1, 0x10, 1, 0, 0x20]]
        for reply in replies {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, [reply[0] - 1, 3])
            controller.simulateProtocolMessage(reply)
            acknowledge(frame, on: controller)
        }
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(featureQueries(controller), [[0xF0, 3], [0xF2, 3], [0xF6, 3], [0xFA, 3]])
        XCTAssertNotNil(controller.touchAssignments.customizedActions)
    }

    func testInitialConnectionModeUsesExistingReadbackLedgerAndWaitsForACK() throws {
        for (function, inquiry): (UInt8, UInt8) in [(0xE1, 0), (0xE3, 2), (0xE7, 5)] {
            for replyFirst in [false, true] {
                let controller = makeController(generation: .v2, functions: [function, 0xF4],
                                                firstQuery: [inquiry == 5 ? 0xE0 : 0xE2, inquiry])
                defer { controller.simulateControlLoss() }
                if inquiry == 5 {
                    controller.simulateProtocolMessage([0xE1, inquiry, 2, 0, 1, 0])
                }
                acknowledgeSimulatedCommands(controller)
                controller.simulateProtocolMessage(inquiry == 0 ? [0xE3, inquiry, 0] : [0xE3, inquiry, 0, 0])
                let mode = try XCTUnwrap(controller.simulatedPendingFrame)
                XCTAssertEqual(mode.payload, [0xE6, inquiry])
                XCTAssertEqual(controller.simulatedModeReadbackCount, 1)
                if replyFirst {
                    controller.simulateProtocolMessage([0xE7, inquiry, 0])
                    XCTAssertEqual(controller.simulatedPendingFrame, mode)
                    XCTAssertEqual(controller.simulatedModeReadbackCount, 0)
                    acknowledge(mode, on: controller)
                } else {
                    acknowledge(mode, on: controller)
                    XCTAssertNil(controller.simulatedPendingFrame)
                    controller.simulateProtocolMessage([0xE7, inquiry, 0])
                }
                XCTAssertEqual(controller.simulatedModeReadbackCount, 0)
                XCTAssertEqual(controller.connectionMode, .soundQuality)
                XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF0, 4])
            }
        }
    }

    func testConnectionChangeReadbackDoesNotReplaceInitialModeReadOwner() throws {
        for replyFirst in [false, true] {
            let controller = makeController(generation: .v2, functions: [0xE7, 0xF4, 0x90], firstQuery: [0xE0, 5])
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolMessage([0xE1, 5, 2, 0, 1, 0])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0xE3, 5, 0, 0])
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.simulatedModeReadbackCount, 1)
            controller.simulateProtocolMessage([0xE9, 5, 0, 0])
            controller.setConnectionMode(.stableConnection)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 5, 1, 0])
            acknowledgeSimulatedCommands(controller)
            controller.simulateProtocolMessage([0x99, 0, 0x77, 1])
            let alert = try XCTUnwrap(controller.connectionTransition?.alert)
            controller.respondToConnectionAlert(alert, action: .positive)
            acknowledge(try XCTUnwrap(controller.simulatedPendingFrame), on: controller)
            let transitionRead = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(transitionRead.payload, [0xE6, 5])
            XCTAssertEqual(controller.simulatedModeReadbackCount, 2)
            if !replyFirst {
                acknowledge(transitionRead, on: controller)
                XCTAssertNil(controller.simulatedPendingFrame)
            }
            controller.simulateProtocolMessage([0xE7, 5, 0])
            XCTAssertEqual(controller.simulatedModeReadbackCount, 1)
            XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
            if replyFirst {
                XCTAssertEqual(controller.simulatedPendingFrame, transitionRead)
                acknowledge(transitionRead, on: controller)
            }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF0, 4])
            controller.simulateProtocolMessage([0xE7, 5, 1])
            XCTAssertEqual(controller.simulatedModeReadbackCount, 0)
            XCTAssertEqual(controller.connectionTransition?.phase, .confirmed)
            XCTAssertEqual(featureQueries(controller).filter { $0 == [0xE6, 5] }.count, 2)
        }
    }

    private func makeController(generation: SonyProtocolInfo.Generation, functions: [UInt8]? = nil,
                                firstQuery: [UInt8]? = nil) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        connect(controller, generation: generation, functions: functions, firstQuery: firstQuery)
        return controller
    }

    private func connect(_ controller: SonyHeadphonesController, generation: SonyProtocolInfo.Generation,
                         functions: [UInt8]? = nil, firstQuery: [UInt8]? = nil) {
        let legacy = generation == .v1
        let functions = functions ?? [0xE2, legacy ? 0xF3 : 0xF4]
        let firstQuery = firstQuery ?? [0xE0, legacy ? 2 : 1]
        controller.simulateDeviceConnection(named: "WH-1000XM4")
        controller.simulateProtocolMessage(legacy ? [0x01, 0, 2, 0x10] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolMessage([0x07, 0, UInt8(functions.count)] + (legacy ? functions : functions.flatMap { [$0, 0] }))
        for _ in 0..<64 {
            guard let frame = controller.simulatedPendingFrame, frame.payload != firstQuery else { break }
            acknowledge(frame, on: controller)
        }
        controller.simulateProtocolMessage([0x05, 2, 5] + Array("1.0.0".utf8))
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, firstQuery)
    }

    private func initialReplies(generation: SonyProtocolInfo.Generation) -> [[UInt8]] {
        generation == .v1 ? [[0xE1, 2, 0, 0], [0xE3, 2, 0], [0xE7, 2, 0, 1],
                             [0xF1, 3, 0], [0xF3, 3, 0], [0xF7, 3, 0, 1]]
            : [[0xE1, 1, 2], [0xE3, 1, 0], [0xE7, 1, 1],
               [0xF1, 4, 0, 1, 0x30], [0xF3, 4, 0], [0xF7, 4, 0x30]]
    }

    private func acknowledge(_ frame: SonyFrame, on controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
    }

    private func featureQueries(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && [0xE0, 0xE2, 0xE6, 0xF0, 0xF2, 0xF6, 0xFA].contains($0.payload.first) }.map(\.payload)
    }
}
