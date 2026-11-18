import XCTest
@testable import Acouplet

@MainActor
final class SonyCapabilityAcquisitionTests: XCTestCase {
    func testColdCapabilitiesRequireReplyAndACKBeforeNoiseStatusOrEffects() throws {
        for replyFirst in [false, true] {
            let controller = makeController(functions: functions + [0x62, 0x41, 0x42])
            defer { controller.simulateControlLoss() }
            let start = payloads(controller).count - 1
            let replies = [identityReply()] + capabilityReplies
            let queries: [[UInt8]] = [[0x02, 0]] + capabilityQueries
            for (index, reply) in replies.enumerated() {
                let frame = try XCTUnwrap(controller.simulatedPendingFrame)
                XCTAssertEqual(frame.payload, queries[index])
                XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, queries[index])
                XCTAssertEqual(Array(payloads(controller).dropFirst(start)), Array(queries.prefix(index + 1)))
                controller.requestCurrentSettings()
                if replyFirst {
                    controller.simulateProtocolMessage(reply)
                    XCTAssertEqual(controller.simulatedPendingFrame, frame)
                    XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, queries[index])
                    acknowledge(frame, on: controller)
                } else {
                    acknowledge(frame, on: controller)
                    XCTAssertNil(controller.simulatedPendingFrame)
                    XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, queries[index])
                    controller.simulateProtocolMessage(reply)
                }
            }
            XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
            XCTAssertEqual(Array(payloads(controller).dropFirst(start)), queries + [[0x60, 2]])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x60, 2])
            assertCapabilities(controller)
            XCTAssertNil(controller.firmwareVersion)
            XCTAssertFalse(controller.isReady)
            XCTAssertFalse(controller.canControlMusicVolume)
            XCTAssertFalse(controller.canSetDSEE)
            XCTAssertFalse(controller.canSetAutomaticPowerOff)
        }
    }

    func testCustomCapabilitiesWorkWithoutKnownModelOrFirmware() throws {
        for model in ["WH-1000XM3", "MDR arbitrary model"] {
            let controller = makeController(model: model)
            defer { controller.simulateControlLoss() }
            try completeCapabilities(controller)
            assertCapabilities(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.firmwareVersion)
            completeLiveReads(controller, firmware: "99.7.3", volume: 47)
            XCTAssertEqual(controller.firmwareVersion, "99.7.3")
            assertCapabilities(controller)
            XCTAssertEqual(controller.playback.volume, 47)
            XCTAssertTrue(controller.canControlMusicVolume)
            XCTAssertTrue(controller.canSetDSEE)
            XCTAssertTrue(controller.canChangeConnectionMode)
            XCTAssertTrue(controller.canSetAutomaticPowerOff)
        }
    }

    func testAcceptedCapabilityReplyKeepsItsCommandRetryableUntilACK() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let queries: [[UInt8]] = [[0x02, 0]] + capabilityQueries
        for (query, reply) in zip(queries, [identityReply()] + capabilityReplies) {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, query)
            XCTAssertTrue(controller.canRetryRead(frame))
            controller.simulateProtocolMessage(reply)
            XCTAssertTrue(controller.canRetryRead(frame))
            controller.simulateLegacyCapabilityReadTimeout()
            XCTAssertEqual(controller.simulatedPendingFrame, frame)
            XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, query)
            acknowledge(frame, on: controller)
        }
        assertCapabilities(controller)
        XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
        XCTAssertTrue(controller.isReady)
    }

    func testRetriedPlaybackCapabilityReadAcceptsReplyBeforeOrAfterACK() async throws {
        for replyFirst in [false, true] {
            let controller = makeController(functions: [0xA1])
            defer { controller.simulateControlLoss() }
            try exchange(identityReply(), query: [0x02, 0], on: controller)
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, [0xA0, 1])
            controller.simulateLegacyCapabilityReadTimeout()
            controller.simulateAcknowledgmentTimeout()
            for _ in 0..<8 { await Task.yield() }
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
            if replyFirst {
                controller.simulateProtocolMessage(capabilityReplies[0])
                XCTAssertEqual(controller.simulatedPendingFrame, frame)
                acknowledge(frame, on: controller)
            } else {
                acknowledge(frame, on: controller)
                XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, frame.payload)
                controller.simulateProtocolMessage(capabilityReplies[0])
            }
            XCTAssertEqual(controller.playback.musicVolumeRange, 0...72)
            XCTAssertNil(controller.playbackReadError)
            XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
            XCTAssertTrue(controller.isReady)
        }
    }

    func testPersistedCacheNeedsFreshIdentityAndFreshLiveStateOnReconnect() throws {
        let suite = "dev.baglayan.Acouplet.capability-acquisition-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = makeController(defaults: defaults)
        try completeCapabilities(original)
        completeLiveReads(original, volume: 12)
        XCTAssertTrue(original.canControlMusicVolume)
        XCTAssertTrue(original.canSetDSEE)
        XCTAssertTrue(original.canSetAutomaticPowerOff)
        original.simulateControlLoss()

        let restored = makeController(defaults: defaults)
        defer { restored.simulateControlLoss() }
        XCTAssertFalse(restored.playback.hasReceivedCapabilities)
        XCTAssertNil(restored.dseeType)
        XCTAssertNil(restored.automaticPowerOff?.options)
        for reply in capabilityReplies { restored.simulateProtocolMessage(reply) }
        XCTAssertFalse(restored.playback.hasReceivedCapabilities)
        XCTAssertNil(restored.dseeType)
        try exchange(identityReply(), query: [0x02, 0], on: restored)
        XCTAssertNil(restored.simulatedLegacyCapabilityQuery)
        XCTAssertTrue(capabilityQueriesSent(restored).isEmpty)
        assertCapabilities(restored)
        XCTAssertNil(restored.playback.available)
        XCTAssertNil(restored.playback.volume)
        XCTAssertNil(restored.dseeAvailable)
        XCTAssertNil(restored.dseeMode)
        XCTAssertNil(restored.automaticPowerOff?.available)
        XCTAssertNil(restored.automaticPowerOff?.current)
        XCTAssertFalse(restored.canControlMusicVolume)
        XCTAssertFalse(restored.canSetDSEE)
        XCTAssertFalse(restored.canSetAutomaticPowerOff)

        acknowledgeAll(restored)
        XCTAssertTrue(payloads(restored).contains([0xA2, 1]))
        restored.simulateProtocolMessage([0xA3, 1, 0, 2])
        acknowledgeAll(restored)
        XCTAssertTrue(payloads(restored).contains([0xA6, 1, 0x20]))
        XCTAssertFalse(restored.canControlMusicVolume)
        restored.simulateProtocolMessage([0xA7, 1, 0x20, 47])
        XCTAssertTrue(restored.canControlMusicVolume)
        XCTAssertEqual(restored.playback.volume, 47)
        XCTAssertFalse(restored.canSetDSEE)
        XCTAssertFalse(restored.canSetAutomaticPowerOff)
        completeLiveReads(restored, volume: 47)
        XCTAssertTrue(restored.canSetDSEE)
        XCTAssertTrue(restored.canSetAutomaticPowerOff)
        XCTAssertTrue(capabilityQueriesSent(restored).isEmpty)
    }

    func testChangedIdentityCounterOrProtocolFetchesCapabilitiesAgain() throws {
        let suite = "dev.baglayan.Acouplet.capability-acquisition-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = makeController(defaults: defaults)
        try completeCapabilities(original)
        original.simulateControlLoss()
        for (identifier, counter, version): (String, UInt8, UInt16) in [
            ("different-capabilities", 7, 0x0210), ("能力-é", 8, 0x0210), ("能力-é", 7, 0x0211),
        ] {
            let controller = makeController(defaults: defaults, version: version)
            defer { controller.simulateControlLoss() }
            try exchange(identityReply(identifier: identifier, counter: counter), query: [0x02, 0], on: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA0, 1])
            XCTAssertFalse(controller.playback.hasReceivedCapabilities)
            XCTAssertNil(controller.dseeType)
            XCTAssertNil(controller.automaticPowerOff?.options)
            for (query, reply) in zip(capabilityQueries, capabilityReplies) {
                try exchange(reply, query: query, on: controller)
            }
            XCTAssertEqual(capabilityQueriesSent(controller), capabilityQueries)
            assertCapabilities(controller)
        }
    }

    func testChangedCounterInvalidatesCachedCapabilitiesBeforeIdentityACK() throws {
        let suite = "dev.baglayan.Acouplet.capability-acquisition-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = makeController(defaults: defaults)
        try completeCapabilities(original)
        original.simulateControlLoss()

        let changed = makeController(defaults: defaults)
        changed.simulateProtocolMessage(identityReply(counter: 8))
        XCTAssertEqual(changed.simulatedPendingFrame?.payload, [0x02, 0])
        changed.simulateControlLoss()

        let restored = makeController(defaults: defaults)
        defer { restored.simulateControlLoss() }
        try exchange(identityReply(), query: [0x02, 0], on: restored)
        XCTAssertFalse(restored.playback.hasReceivedCapabilities)
        for (query, reply) in zip(capabilityQueries, capabilityReplies) {
            try exchange(reply, query: query, on: restored)
        }
        XCTAssertEqual(capabilityQueriesSent(restored), capabilityQueries)
    }

    func testMissingIdentityCannotReuseCacheAndMissingRepliesDoNotInventCapabilities() throws {
        let suite = "dev.baglayan.Acouplet.capability-acquisition-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = makeController(defaults: defaults)
        try completeCapabilities(original)
        original.simulateControlLoss()
        let controller = makeController(defaults: defaults)
        defer { controller.simulateControlLoss() }
        let session = controller.simulatedControlSession
        for query in [[0x02, 0]] + capabilityQueries {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, query)
            acknowledge(frame, on: controller)
            controller.simulateLegacyCapabilityReadTimeout()
        }
        XCTAssertEqual(capabilityQueriesSent(controller), capabilityQueries)
        XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        completeLiveReads(controller)
        for reply in [identityReply()] + capabilityReplies { controller.simulateProtocolMessage(reply) }
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        XCTAssertNil(controller.playback.musicVolumeRange)
        XCTAssertNil(controller.dseeType)
        XCTAssertNil(controller.supportedConnectionModes)
        XCTAssertNil(controller.automaticPowerOff?.options)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canSetDSEE)
        XCTAssertFalse(controller.canChangeConnectionMode)
        XCTAssertFalse(controller.canSetAutomaticPowerOff)
    }

    func testOneMissingCapabilityDisablesOnlyItsFeatureAndRejectsLateReply() throws {
        for missing in capabilityQueries.indices {
            let controller = makeController()
            defer { controller.simulateControlLoss() }
            try exchange(identityReply(), query: [0x02, 0], on: controller)
            for (index, query) in capabilityQueries.enumerated() {
                if index == missing {
                    let frame = try XCTUnwrap(controller.simulatedPendingFrame)
                    XCTAssertEqual(frame.payload, query)
                    acknowledge(frame, on: controller)
                    XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, query)
                    controller.simulateLegacyCapabilityReadTimeout()
                } else {
                    try exchange(capabilityReplies[index], query: query, on: controller)
                }
            }
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
            let playbackError = controller.playbackReadError
            XCTAssertEqual(playbackError, missing == 0
                ? String(localized: "Playback information was not received. Reconnect the headphones to try again.") : nil)
            completeLiveReads(controller)
            XCTAssertEqual(controller.playback.available, true)
            XCTAssertEqual(controller.playbackReadError, playbackError)
            controller.simulateProtocolMessage(capabilityReplies[missing])
            XCTAssertEqual(controller.canControlMusicVolume, missing != 0)
            XCTAssertEqual(controller.canChangeConnectionMode, missing != 1)
            XCTAssertEqual(controller.canSetDSEE, missing != 2)
            XCTAssertEqual(controller.canSetAutomaticPowerOff, missing != 3)
            XCTAssertEqual(controller.playback.musicVolumeRange, missing == 0 ? nil : 0...72)
            XCTAssertEqual(controller.dseeType, missing == 2 ? nil : .extreme)
            XCTAssertEqual(controller.automaticPowerOff?.options?.map(\.rawValue), missing == 3 ? nil : [2, 0x10, 0x11])
        }
    }

    func testUnownedMalformedAndWrongTableRepliesCannotCompleteAcquisition() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        let identity = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage(identityReply(), type: 0x0E)
        controller.simulateProtocolMessage([0x03, 0, 7, 2, 0x61])
        for reply in capabilityReplies { controller.simulateProtocolMessage(reply) }
        XCTAssertEqual(controller.simulatedPendingFrame, identity)
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        XCTAssertNil(controller.dseeType)
        XCTAssertNil(controller.automaticPowerOff?.options)
        try exchange(identityReply(), query: [0x02, 0], on: controller)
        for (index, query) in capabilityQueries.enumerated() {
            let frame = try XCTUnwrap(controller.simulatedPendingFrame)
            XCTAssertEqual(frame.payload, query)
            acknowledge(frame, on: controller)
            controller.simulateProtocolMessage(capabilityReplies[index], type: 0x0E)
            controller.simulateProtocolMessage(Array(capabilityReplies[index].dropLast()))
            for reply in capabilityReplies.suffix(from: index + 1) { controller.simulateProtocolMessage(reply) }
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, query)
            controller.simulateProtocolMessage(capabilityReplies[index])
        }
        assertCapabilities(controller)
        for reply: [UInt8] in [[0xA1, 1, 31, 1, 1], [0xE1, 1, 1], [0xE1, 2, 0, 0], [0xF1, 4, 1, 0x11]] {
            controller.simulateProtocolMessage(reply)
        }
        assertCapabilities(controller)
    }

    func testCapabilityReplyBeforeNativeWriteCannotSupplyLaterQuery() throws {
        let controller = makeController(functions: [0xA1])
        defer { controller.simulateControlLoss() }
        let identity = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage(identityReply())
        controller.defersSimulatedWrites = true
        acknowledge(identity, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xA0, 1])
        controller.simulateProtocolMessage(capabilityReplies[0])
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        controller.completeSimulatedWrite()
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeAll(controller)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, [0xA0, 1])
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        controller.simulateProtocolMessage(capabilityReplies[0])
        XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...72)
        XCTAssertTrue(controller.isReady)
    }

    func testResetClearsAcquisitionAndRejectsRetiredSessionReplies() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        try exchange(identityReply(), query: [0x02, 0], on: controller)
        try exchange(capabilityReplies[0], query: [0xA0, 1], on: controller)
        let session = controller.simulatedControlSession
        XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, [0xE0, 1])
        controller.simulateControlLoss()
        XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        controller.simulateLegacyCapabilityReadTimeout()
        XCTAssertNil(controller.simulatedPendingFrame)
        connect(controller)
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage(identityReply(identifier: "new-session"), session: session)
        for reply in capabilityReplies { controller.simulateProtocolMessage(reply, session: session) }
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(controller.simulatedLegacyCapabilityQuery, [0x02, 0])
        try exchange(identityReply(identifier: "new-session"), query: [0x02, 0], on: controller)
        let capability = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.simulateProtocolMessage(capabilityReplies[0], session: session)
        XCTAssertEqual(controller.simulatedPendingFrame, capability)
        XCTAssertFalse(controller.playback.hasReceivedCapabilities)
        for (query, reply) in zip(capabilityQueries, capabilityReplies) {
            try exchange(reply, query: query, on: controller)
        }
        assertCapabilities(controller)
        XCTAssertTrue(controller.isReady)
    }

    func testExpiredCapabilityReadPreventsReusingItsTransport() throws {
        for expireIdentity in [false, true] {
            let controller = makeController(functions: [0xE2])
            defer { controller.simulateControlLoss() }
            let identity = try XCTUnwrap(controller.simulatedPendingFrame)
            if expireIdentity {
                acknowledge(identity, on: controller)
                controller.simulateLegacyCapabilityReadTimeout()
                try exchange(capabilityReplies[2], query: [0xE0, 2], on: controller)
            } else {
                try exchange(identityReply(), query: [0x02, 0], on: controller)
                acknowledge(try XCTUnwrap(controller.simulatedPendingFrame), on: controller)
                controller.simulateLegacyCapabilityReadTimeout()
            }
            completeLiveReads(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.simulatedPendingFrame)
            let protocolReads = payloads(controller).filter { $0 == [0, 0] }
            let session = controller.simulatedControlSession
            controller.simulateSameTransportHandshake()
            XCTAssertFalse(controller.isReady)
            XCTAssertEqual(controller.linkState, .disconnected)
            XCTAssertGreaterThan(controller.simulatedControlSession, session)
            XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
            XCTAssertEqual(payloads(controller).filter { $0 == [0, 0] }, protocolReads)
            controller.simulateProtocolMessage(identityReply(), session: session)
            controller.simulateProtocolMessage(capabilityReplies[2], session: session)
            XCTAssertNil(controller.simulatedLegacyCapabilityQuery)
            XCTAssertNil(controller.dseeType)
        }
    }

    func testDiscoveryTimeoutCannotInterleaveWithCapabilityAcquisition() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 0x40, 0x10], beginConnection: true)
        acknowledgeAll(controller)
        controller.simulateProtocolMessage([0x07, 0, 1, 0xA1])
        try exchange(identityReply(), query: [0x02, 0], on: controller)
        let capability = try XCTUnwrap(controller.simulatedPendingFrame)
        acknowledge(capability, on: controller)
        let before = payloads(controller)
        controller.simulateDiscoveryReadTimeout([0x04, 1])
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertEqual(payloads(controller), before)
        controller.simulateProtocolMessage(capabilityReplies[0])
        let alert = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(alert.payload, [0x94, 1, 0])
        acknowledge(alert, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x04, 1])
        XCTAssertTrue(controller.isReady)
    }

    func testDiscoveryRetryCannotBeQueuedAheadOfCapabilityIdentity() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WH-1000XM3", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 0x40, 0x10], beginConnection: true)
        for _ in 0..<3 { acknowledge(try XCTUnwrap(controller.simulatedPendingFrame), on: controller) }
        let support = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(support.payload, [0x06, 0])
        controller.simulateDiscoveryReadTimeout([0x04, 1])
        for _ in 0..<8 { await Task.yield() }
        controller.simulateProtocolMessage([0x07, 0, 1, 0xA1])
        acknowledge(support, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x02, 0])
        try exchange(identityReply(), query: [0x02, 0], on: controller)
        try exchange(capabilityReplies[0], query: [0xA0, 1], on: controller)
        let alert = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(alert.payload, [0x94, 1, 0])
        acknowledge(alert, on: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x04, 1])
    }

    func testExplicitUnavailableCapabilitiesDoNotBecomeTimeoutsOrDefaults() throws {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        try exchange(identityReply(), query: [0x02, 0], on: controller)
        for (query, reply) in zip(capabilityQueries, [[UInt8(0xA1), 1, 0, 1, 1], [0xE1, 1, 0xFF],
                                                       [0xE1, 2, 0xFF, 0xFF], [0xF1, 4, 0]]) {
            try exchange(reply, query: query, on: controller)
        }
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.playback.hasReceivedCapabilities)
        XCTAssertNil(controller.playback.musicVolumeRange)
        XCTAssertNil(controller.dseeType)
        XCTAssertEqual(controller.automaticPowerOff?.options, [])
        completeLiveReads(controller)
        XCTAssertFalse(controller.canControlMusicVolume)
        XCTAssertFalse(controller.canSetDSEE)
        XCTAssertFalse(controller.canChangeConnectionMode)
        XCTAssertFalse(controller.canSetAutomaticPowerOff)
        let session = controller.simulatedControlSession
        controller.refresh()
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    private let functions: [UInt8] = [0xA1, 0xE1, 0xE2, 0xF4]
    private let capabilityQueries: [[UInt8]] = [[0xA0, 1], [0xE0, 1], [0xE0, 2], [0xF0, 4]]
    private let capabilityReplies: [[UInt8]] = [[0xA1, 1, 73, 1, 1], [0xE1, 1, 0], [0xE1, 2, 2, 0], [0xF1, 4, 3, 2, 0x10, 0x11]]

    private func makeController(defaults: UserDefaults? = nil, model: String = "MDR arbitrary model",
                                version: UInt16 = 0x0210, functions: [UInt8]? = nil) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        connect(controller, model: model, version: version, functions: functions)
        return controller
    }

    private func connect(_ controller: SonyHeadphonesController, model: String = "MDR arbitrary model",
                         version: UInt16 = 0x0210, functions: [UInt8]? = nil) {
        let functions = functions ?? self.functions
        controller.simulateDeviceConnection(named: model, controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, UInt8(version >> 8), UInt8(version & 0xFF)], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array(model.utf8)
        controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
        controller.simulateProtocolMessage([0x05, 3, 0x20, 0])
        controller.simulateProtocolMessage([0x07, 0, UInt8(functions.count)] + functions)
        XCTAssertEqual(controller.protocolInformation?.generation, .v1)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x02, 0])
    }

    private func identityReply(identifier: String = "能力-é", counter: UInt8 = 7) -> [UInt8] {
        let bytes = Array(identifier.utf8)
        return [0x03, 0, counter, UInt8(bytes.count)] + bytes
    }

    private func completeCapabilities(_ controller: SonyHeadphonesController) throws {
        try exchange(identityReply(), query: [0x02, 0], on: controller)
        for (query, reply) in zip(capabilityQueries, capabilityReplies) {
            try exchange(reply, query: query, on: controller)
        }
    }

    private func completeLiveReads(_ controller: SonyHeadphonesController, firmware: String = "99.7.3", volume: UInt8 = 47) {
        let firmwareBytes = Array(firmware.utf8)
        let replies: [[UInt8]] = [[0x05, 2, UInt8(firmwareBytes.count)] + firmwareBytes,
                                  [0xE3, 2, 0], [0xE7, 2, 0, 1], [0xE3, 1, 0], [0xE7, 1, 0, 1],
                                  [0xF3, 4, 0], [0xF7, 4, 1, 2, 2], [0xA3, 1, 0, 2], [0xA7, 1, 0x20, volume]]
        acknowledgeAll(controller)
        for reply in replies {
            controller.simulateProtocolMessage(reply)
            acknowledgeAll(controller)
        }
    }

    private func exchange(_ reply: [UInt8], query: [UInt8], on controller: SonyHeadphonesController) throws {
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(frame.payload, query)
        controller.simulateProtocolMessage(reply)
        acknowledge(frame, on: controller)
    }

    private func assertCapabilities(_ controller: SonyHeadphonesController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(controller.playback.musicVolumeRange, 0...72, file: file, line: line)
        XCTAssertEqual(controller.dseeType, .extreme, file: file, line: line)
        XCTAssertEqual(controller.supportedConnectionModes, [.soundQuality, .stableConnection], file: file, line: line)
        XCTAssertEqual(controller.automaticPowerOff?.options?.map(\.rawValue), [2, 0x10, 0x11], file: file, line: line)
    }

    private func acknowledge(_ frame: SonyFrame, on controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<64 {
            guard let frame = controller.simulatedPendingFrame else { return }
            acknowledge(frame, on: controller)
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload)
    }

    private func capabilityQueriesSent(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        payloads(controller).filter { capabilityQueries.contains($0) }
    }
}
