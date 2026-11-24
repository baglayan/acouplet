import XCTest
@testable import Acouplet

final class SonySourceControllerTests: XCTestCase {
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testXM5HandshakeReadsOwnedSourceBeforeBootstrappingPlayback() throws {
        enum Table2Delivery: CaseIterable { case beforeAcknowledgment, afterAcknowledgment, withheld }
        let profile = SonyHeadphonesController(startAutomatically: false, simulated: true)
        profile.simulateDeviceConnection(named: "WF-1000XM5", galleryModel: .wfXM5)
        let functions = profile.supportedFunctions.sorted()
        let functions2 = profile.supportedFunctions2.sorted()
        profile.simulateControlLoss()
        let supportFunctions: [UInt8] = [0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }
        let table2Functions: [UInt8] = [0x07, 0, UInt8(functions2.count)] + functions2.flatMap { [$0, 0] }
        let localAddress = "02:00:00:00:00:01"
        let playbackQueries: [[UInt8]] = [[0xA0, 1], [0xA2, 1], [0xA6, 1], [0xA6, 0x20]]

        for delivery in Table2Delivery.allCases {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            var playbackBeforeSource = false
            for _ in 0..<128 {
                guard let frame = controller.simulatedPendingFrame else { break }
                let query = frame.payload
                let reply: [UInt8]?
                if frame.type == 0x0E {
                    switch query {
                    case [0x06, 0]: reply = delivery == .withheld ? nil : table2Functions
                    case [0x36, 2]: reply = inventory(command: 0x37, selected: 1)
                    default: reply = nil
                    }
                } else {
                    switch query {
                    case [0x04, 1]: reply = [0x05, 1, 10] + Array("WF-1000XM5".utf8)
                    case [0x04, 3]: reply = [0x05, 3, 0x30, 1]
                    case [0x06, 0]: reply = supportFunctions
                    case [0x60, 0x17]: reply = [0x61, 0x17, 2, 0, 1, 20, 1, 1, 1, 20, 1]
                    case [0x62, 0x17]: reply = [0x63, 0x17, 0]
                    case [0x66, 0x17]: reply = [0x67, 0x17, 1, 1, 0, 0, 10]
                    case [0xA0, 1]: reply = [0xA1, 1, 31, 16]
                    case [0xA2, 1]: reply = [0xA3, 1, 0, 2, 0]
                    case [0xA6, 1]: reply = [0xA7, 1, 1, 0, 1, 0, 1, 0, 1, 0]
                    case [0xA6, 0x20]: reply = [0xA7, 0x20, 17]
                    default: reply = nil
                    }
                }
                let replyBeforeAcknowledgment = frame.type == 0x0E && query == [0x06, 0] && delivery == .beforeAcknowledgment
                if let reply, replyBeforeAcknowledgment { deliver(reply, type: frame.type, to: controller) }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
                if let reply, !replyBeforeAcknowledgment { deliver(reply, type: frame.type, to: controller) }
                if controller.hasCurrentMusicVolumeRead, !controller.hasCurrentMusicSourceContext(for: localAddress) {
                    playbackBeforeSource = true
                }
            }
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.playback.volume, 17)
            XCTAssertTrue(controller.hasFreshMusicVolumeReadback)
            let frames = controller.simulatedTransmittedFrames.filter { $0.type != 1 }
            XCTAssertEqual(frames.filter { $0.type == 0x0E && $0.payload == [0x06, 0] }.count, 1)
            if delivery == .withheld {
                XCTAssertFalse(controller.hasCurrentTable2Capabilities)
                XCTAssertFalse(controller.hasCurrentMusicSourceContext(for: localAddress))
                XCTAssertTrue(playbackBeforeSource)
                XCTAssertTrue(controller.canControlMusicVolume)
                continue
            }
            let ready = try XCTUnwrap(frames.firstIndex { $0.type == 0x0C && $0.payload == [0x66, 0x17] })
            let inventory = try XCTUnwrap(frames.firstIndex { $0.type == 0x0E && $0.payload == [0x36, 2] })
            XCTAssertLessThanOrEqual(inventory - ready, 3, "Source inventory should follow T2 discovery and at most one pending read")
            XCTAssertTrue(controller.hasCurrentMusicSourceContext(for: localAddress))
            XCTAssertFalse(playbackBeforeSource)
            XCTAssertEqual(frames.filter { $0.type == 0x0E && $0.payload == [0x36, 2] }.count, 1)
            XCTAssertEqual(frames.filter { $0.type == 0x0C && playbackQueries.contains($0.payload) }.map(\.payload), playbackQueries)
        }
    }

    @MainActor
    func testLDACPreparationRequiresFreshSourceAndPreservesSourceKeeping() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0x32, 0x31])
        defer { controller.simulateControlLoss() }
        deliver([0x39, 2, 1], to: controller)
        XCTAssertEqual(controller.ldacPreparationIssue(for: "02:00:00:00:00:01"), .readingSources)

        deliver([0x33, 2, 0, 0], to: controller)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        deliver([0x37, 1, 1], to: controller)
        let mac = try XCTUnwrap(controller.multipoint.devices.first)
        XCTAssertEqual(controller.ldacPreparationIssue(for: mac.address), .selectMac(mac))
        XCTAssertNil(controller.ldacPreparationIssue(for: controller.multipoint.selectedSource?.address))

        deliver([0x37, 1, 0], to: controller)
        XCTAssertEqual(controller.ldacPreparationIssue(for: mac.address), .selectMac(nil))
        XCTAssertEqual(controller.ldacPreparationIssue(for: nil), .unknownLocalAddress)

        deliver([0x37, 1, 0xFF], to: controller)
        XCTAssertEqual(controller.ldacPreparationIssue(for: mac.address), .readingSources)

        deliver([0x39, 2, 1], to: controller)
        XCTAssertEqual(controller.ldacPreparationIssue(for: mac.address), .readingSources)
    }

    @MainActor
    func testLDACSourceConfirmationRequiresNotificationOrOwnedReadback() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        var sources: [String?] = []
        let observer = controller.musicSourceConfirmations.sink { sources.append($0?.address) }
        defer { observer.cancel() }

        let local = "02:00:00:00:00:01"
        let remote = "02:00:00:00:00:02"
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        deliver([0x39, 2, 1], to: controller)
        XCTAssertTrue(sources.isEmpty)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(sources, [remote])

        let mac = try XCTUnwrap(controller.multipoint.devices.first { $0.address == local })
        acknowledgeAll(controller)
        let phoneGeneration = controller.playbackSourceGeneration
        controller.selectAudioSource(mac)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertEqual(controller.multipoint.selectedSource?.address, local)
        XCTAssertEqual(controller.playbackSourceGeneration, phoneGeneration + 1)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        XCTAssertEqual(sources, [remote])
        deliver([0x3D, 1, 0] + Array(local.utf8), to: controller)
        XCTAssertEqual(sources, [remote])
        acknowledgeAll(controller)
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        XCTAssertEqual(controller.playbackSourceGeneration, phoneGeneration + 1)
        XCTAssertEqual(sources, [remote, local])

        deliver(inventory(command: 0x39, selected: 0), to: controller)
        XCTAssertEqual(sources, [remote, local, nil])
        controller.simulateControlLoss()
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(sources, [remote, local, nil])
    }

    @MainActor
    func testExpiredQueuedLDACSourceDoesNotWriteAfterReplacement() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let mac = "02:00:00:00:00:01"
        let phone = "02:00:00:00:00:02"
        let replacement = "02:00:00:00:00:03"
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        acknowledgeAll(controller)
        controller.setDSEE(.off)
        XCTAssertNotNil(controller.simulatedPendingFrame)
        controller.selectAudioSource(try XCTUnwrap(controller.multipoint.devices.first { $0.address == phone }), isCurrent: { true })
        let expired = try XCTUnwrap(controller.sourceTransition?.requestID)
        XCTAssertTrue(controller.isQueuedAudioSourceSelection(expired))
        controller.cancelQueuedAudioSourceSelection(expired, expired: true)
        XCTAssertEqual(controller.sourceTransition?.failureMessage, String(localized: "The headphones did not confirm the audio source change in time."))
        XCTAssertFalse(controller.isQueuedAudioSourceSelection(expired))

        deliver([0x39, 2, 2] + entry(address: mac, id: 1, name: "MacBook Pro")
                + entry(address: replacement, id: 2, name: "Other phone") + [1], to: controller)
        controller.selectAudioSource(try XCTUnwrap(controller.multipoint.devices.first { $0.address == replacement }), isCurrent: { true })
        let current = try XCTUnwrap(controller.sourceTransition?.requestID)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.starts(with: [0x3C, 1]) }.map(\.payload),
                       [[0x3C, 1] + Array(replacement.utf8)])
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        controller.cancelQueuedAudioSourceSelection(current, expired: true)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
    }
    #endif

    @MainActor
    func testClassicInventorySelectionKeepsReadOwnershipAndConfirmsItsSchema() throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0x30, 0x31])
        defer { controller.simulateControlLoss() }
        controller.refreshDevices()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.multipoint.inventoryInquiryType, 0)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x36, 0] })
        let firstAddress = "02:00:00:00:00:01"
        let secondAddress = "02:00:00:00:00:02"
        let first = Array(firstAddress.utf8) + [1, 1, 0x41]
        let second = Array(secondAddress.utf8) + [2, 1, 0x42]
        deliver([0x31, 0, 8, 2, 0], to: controller)
        deliver([0x33, 0, 0, 0], to: controller)
        deliver([0x37, 0, 2] + first + second + [1], to: controller)
        deliver([0x37, 1, 1], to: controller)
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.selectAudioSource(phone)
        acknowledgeAll(controller)
        deliver([0x3D, 1, 0] + Array(secondAddress.utf8), to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        deliver([0x37, 0, 2] + first + second + [2], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        XCTAssertEqual(controller.multipoint.selectedSource?.address, secondAddress)
    }

    @MainActor
    func testAudioSourceNoticesIgnoreInitialRepeatedAndStaleInventory() {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        var changes: [SonyMultipointDevice] = []
        let observer = controller.audioSourceChanges.sink { changes.append($0) }
        defer { observer.cancel() }
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertTrue(changes.isEmpty)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        deliver([0x39, 2, 1], to: controller)
        XCTAssertEqual(changes.count, 1)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone", "MacBook Pro"])
        controller.simulateControlLoss()
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.count, 2)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.count, 2)
    }

    @MainActor
    func testDiagnosticCodecReadDoesNotCarryAcrossSourceOrControlSession() {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let unavailable = "Headphone codec observed with selected source: Unavailable"
        let phoneLDAC = "Headphone codec observed with selected source: Phone connection 2. Headphones report LDAC."
        let otherSource = entry(address: "02:00:00:00:00:01", id: 1, name: "Laptop")
        let phone = Array("02:00:00:00:00:02".utf8) + [2, 0, 2, 0x0C, 5] + Array("Phone".utf8)
        deliver([0x13, 2, 0x10], type: 0x0C, to: controller)
        XCTAssertEqual(controller.audioCodec, .ldac)
        XCTAssertTrue(controller.diagnosticReport.contains(unavailable))

        controller.refreshDevices()
        acknowledgeAll(controller)
        deliver([0x37, 2, 2] + otherSource + phone + [1], to: controller)
        acknowledgeAll(controller)
        deliver([0x39, 2, 2] + otherSource + phone + [2], to: controller)
        deliver([0x13, 2, 0x10], type: 0x0C, to: controller)
        XCTAssertTrue(controller.diagnosticReport.contains(unavailable))
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x12, 2] }.count, 2)
        deliver([0x13, 2, 0x10], type: 0x0C, to: controller)
        XCTAssertTrue(controller.diagnosticReport.contains(phoneLDAC))

        deliver([0x39, 2, 2] + otherSource + phone + [2], to: controller)
        XCTAssertTrue(controller.diagnosticReport.contains(phoneLDAC))
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x12, 2] }.count, 2)
        deliver([0x39, 2, 2], to: controller)
        XCTAssertTrue(controller.diagnosticReport.contains(unavailable))
        deliver([0x39, 2, 2] + otherSource + phone + [2], to: controller)
        deliver([0x15, 2, 0x10], type: 0x0C, to: controller)
        XCTAssertTrue(controller.diagnosticReport.contains(unavailable))

        let previousSession = controller.simulatedControlSession
        controller.simulateControlLoss()
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x13, 2, 0x10], session: previousSession)
        XCTAssertTrue(controller.diagnosticReport.contains(unavailable))
    }

    @MainActor
    func testDiagnosticCodecUsesClassicInventoryWithoutInferringDeviceType() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0x30])
        controller.refreshDevices()
        acknowledgeAll(controller)
        let source = Array("02:00:00:00:00:02".utf8) + [2, 5] + Array("Phone".utf8)
        deliver([0x37, 0, 1] + source + [2], to: controller)
        acknowledgeAll(controller)
        deliver([0x13, 2, 0x10], type: 0x0C, to: controller)
        XCTAssertTrue(controller.diagnosticReport.contains("Headphone codec observed with selected source: Source connection 2. Headphones report LDAC."))

        deliver([0x15, 2, 0x02], type: 0x0C, to: controller)
        XCTAssertEqual(controller.audioCodec, .aac)
        XCTAssertTrue(controller.diagnosticReport.contains("Headphone codec observed with selected source: Unavailable"))
    }

    @MainActor
    func testDiagnosticCodecPreservesHeadphoneIndicatorWithoutSourceInventory() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0x34])
        controller.refreshDevices()
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        deliver([0x13, 2, 0x10], type: 0x0C, to: controller)
        XCTAssertEqual(controller.audioCodec, .ldac)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x12, 2] })
        XCTAssertTrue(controller.diagnosticReport.contains("Headphone codec observed with selected source: Unavailable"))
    }

    @MainActor
    func testUnsolicitedAudioSourceNoticeDuringUnrelatedConnectionChanges() {
        for multipointChange in [false, true] {
            let controller = preparedController()
            defer { controller.simulateControlLoss() }
            var changes: [SonyMultipointDevice] = []
            let observer = controller.audioSourceChanges.sink { changes.append($0) }
            defer { observer.cancel() }
            deliver(inventory(command: 0x39, selected: 1), to: controller)
            if multipointChange {
                controller.setMultipointEnabled(false)
                XCTAssertEqual(controller.multipointTransition?.phase, .awaitingResponse)
            } else {
                controller.setConnectionMode(.stableConnection)
                XCTAssertEqual(controller.connectionTransition?.phase, .awaitingResponse)
            }
            deliver(inventory(command: 0x39, selected: 2), to: controller)
            XCTAssertEqual(changes.map(\.name), ["Phone"])
        }
    }

    @MainActor
    func testReusedHandshakeResetsAudioSourceNoticeBaseline() {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        var changes: [SonyMultipointDevice] = []
        let observer = controller.audioSourceChanges.sink { changes.append($0) }
        defer { observer.cancel() }
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        controller.setMultipointEnabled(false)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        controller.simulateMultipointTimeout()
        acknowledgeAll(controller)
        deliver([0xD7, 0xD2, 0, 0], type: 0x0C, to: controller)
        XCTAssertTrue(controller.canCheckMultipointChange)
        let session = controller.notificationSession
        controller.checkMultipointChange()
        XCTAssertGreaterThan(controller.notificationSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        acknowledgeAll(controller)
        deliver([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], type: 0x0C, to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, 4, 0x31, 0, 0x32, 0, 0x20, 0, 0x14, 0], type: 0x0C, to: controller)
        acknowledgeAll(controller)
        deliver([0x11, 4] + Array("02:53:4F:4E:59:01ABCDEF12".utf8), type: 0x0C, to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        deliver([0x07, 0, 3, 0x31, 0, 0x32, 0, 0x20, 0], to: controller)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(changes.map(\.name), ["Phone", "Phone"])
    }

    @MainActor
    func testSelectionReleasesKeepingAndWaitsForMatchingResultAndOwnedReadback() throws {
        let controller = preparedController()
        var changes: [SonyMultipointDevice] = []
        let observer = controller.audioSourceChanges.sink { changes.append($0) }
        defer { observer.cancel() }
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.setSourceKeeping(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x38, 0x01, 0])
        acknowledgeAll(controller)
        deliver([0x37, 0x01, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingKeeping)
        deliver([0x39, 0x01, 0, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x38, 0x01, 1])
        XCTAssertNotNil(controller.connectionModeUnavailableReason(.stableConnection))
        deliver([0x39, 0x01, 1, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .queuedSelection)
        deliver([0x3D, 0x01, 0] + Array(phone.address.utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .queuedSelection)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        deliver([0x3D, 0x01, 0] + Array("02:00:00:00:00:01".utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        deliver([0x3D, 0x01, 0] + Array(phone.address.utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        acknowledgeAll(controller)
        let playbackCapabilityQuery = controller.playback.capabilityQueryPayload
        let capabilityReadsBeforeSwitch = controller.simulatedTransmittedFrames.filter { $0.payload == playbackCapabilityQuery }.count
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == playbackCapabilityQuery }.count, capabilityReadsBeforeSwitch)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        XCTAssertEqual(controller.multipoint.selectedSource?.address, phone.address)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        XCTAssertEqual(changes.map(\.name), ["Phone"])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == playbackCapabilityQuery }.count, capabilityReadsBeforeSwitch + 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testEarlierInventoryReadCannotBecomeSwitchConfirmation() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        XCTAssertNil(controller.sourceControlUnavailableReason)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        acknowledgeAll(controller)
        controller.refreshDevices()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload == [0x36, 2] }.count, 1)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x3C })
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        acknowledgeAll(controller)
        deliver([0x3D, 1, 0] + Array(phone.address.utf8), to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
    }

    @MainActor
    func testQueuedSourceSelectionRevalidatesTargetAfterEarlierInventoryRead() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.refreshDevices()
        acknowledgeAll(controller)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        deliver([0x37, 2, 2] + entry(address: "02:00:00:00:00:01", id: 1, name: "MacBook Pro")
                + entry(address: phone.address, id: 0, name: "Phone") + [1], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x3C })
    }

    @MainActor
    func testGuardedSourceSelectionIsRevokedWhenPlaybackMovesAwayAndBackBeforeWrite() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        let generation = controller.playbackSourceGeneration
        controller.defersSimulatedWrites = true
        controller.selectAudioSource(phone, isCurrent: { controller.playbackSourceGeneration == generation })
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload.first, 0x3C)
        deliver(inventory(command: 0x39, selected: 2), to: controller)
        deliver(inventory(command: 0x39, selected: 1), to: controller)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        XCTAssertEqual(controller.playbackSourceGeneration, generation + 2)
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x3C })
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
    }

    @MainActor
    func testQueuedSourceSelectionFailsOnEarlierInventoryReadTimeoutWithoutSendingIt() async throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.refreshDevices()
        acknowledgeAll(controller)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        controller.simulateInventoryReadTimeout()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertNotNil(controller.sourceControlUnavailableReason)
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertNil(controller.sourceControlUnavailableReason)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.first == 0x3C })
    }

    @MainActor
    func testUnresolvedOwnedReadbackBlocksAnotherSourceSelection() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.selectAudioSource(phone)
        acknowledgeAll(controller)
        deliver([0x3D, 1, 0] + Array(phone.address.utf8), to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .verifying)
        controller.simulateSourceTimeout()
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        let previous = controller.sourceTransition?.requestID
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.requestID, previous)
        deliver(inventory(command: 0x37, selected: 1), to: controller)
        XCTAssertNil(controller.sourceControlUnavailableReason)
    }

    @MainActor
    func testQueueDelayDoesNotTimeoutAndControlLossNeverReplaysMutation() {
        let controller = preparedController()
        controller.setDSEE(.off)
        controller.setSourceKeeping(true)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        controller.simulateSourceTimeout()
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingKeeping)
        controller.simulateControlLoss()
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertNil(controller.simulatedPendingFrame)
        let writes = controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x38 }.count
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x38 }.count, writes)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateControlLoss()
    }

    @MainActor
    func testQueuedSourceInvalidationKeepsControlsAndTransmitsFollowingQueuedCommand() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        let session = controller.simulatedControlSession
        controller.setDSEE(.off)
        let previous = try XCTUnwrap(controller.simulatedPendingFrame)
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        controller.refreshEqualizer()
        deliver([0x39, 2, 2] + entry(address: "02:00:00:00:00:01", id: 1, name: "MacBook Pro")
                + entry(address: phone.address, id: 0, name: "Phone") + [1], to: controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - previous.sequence, payload: []))
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertFalse(controller.simulatedSourceTimeoutPending)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.prefix(2) == [0x3C, 1] })
        let next = try XCTUnwrap(controller.simulatedPendingFrame)
        XCTAssertEqual(next.payload, controller.equalizer.parameterQueryPayload)
        XCTAssertEqual(next.sequence, 1 - previous.sequence)
        acknowledgeAll(controller)
        controller.simulateSourceTimeout()
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertFalse(controller.simulatedSourceTimeoutPending)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
    }

    @MainActor
    func testUnownedCapabilitiesCannotStealReadbackOrCancelQueuedWrites() throws {
        let controller = preparedController()
        defer { controller.simulateControlLoss() }
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.selectAudioSource(phone)
        acknowledgeAll(controller)
        let functions = controller.supportedFunctions2.sorted()
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingSelection)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        deliver([0x3D, 1, 0] + Array(phone.address.utf8), to: controller)
        acknowledgeAll(controller)
        deliver(inventory(command: 0x37, selected: 2), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .complete)
        controller.setDSEE(.off)
        controller.setSourceKeeping(true)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        let session = controller.simulatedControlSession
        let pending = controller.simulatedPendingFrame
        deliver([0x07, 0, 2, 0x31, 0, 0x32, 0], to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .queued)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.supportedFunctions2.sorted(), functions)
        XCTAssertEqual(controller.simulatedPendingFrame, pending)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x38, 1, 0] })
        acknowledgeAll(controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .awaitingKeeping)
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x38, 1, 0] })
    }

    @MainActor
    func testCallFailureAndMalformedInventoryDoNotSelectOrRetry() throws {
        let controller = preparedController()
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.selectAudioSource(phone)
        acknowledgeAll(controller)
        deliver([0x3D, 1, 2] + Array(phone.address.utf8), to: controller)
        XCTAssertEqual(controller.sourceTransition?.phase, .failed)
        XCTAssertEqual(controller.sourceTransition?.failureMessage, String(localized: "Finish the phone call before changing the audio source."))
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x39, 2, 1], to: controller)
        XCTAssertTrue(controller.multipoint.inventoryIsStale)
        let request = controller.sourceTransition?.requestID
        controller.selectAudioSource(phone)
        XCTAssertEqual(controller.sourceTransition?.requestID, request)
        controller.simulateControlLoss()
    }

    @MainActor
    private func preparedController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        var count = 0
        while let frame = controller.simulatedPendingFrame, count < 50 {
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func inventory(command: UInt8, selected: UInt8) -> [UInt8] {
        [command, 2, 2] + entry(address: "02:00:00:00:00:01", id: 1, name: "MacBook Pro")
            + entry(address: "02:00:00:00:00:02", id: 2, name: "Phone") + [selected]
    }

    private func entry(address: String, id: UInt8, name: String) -> [UInt8] {
        Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(name.utf8.count)] + Array(name.utf8)
    }
}
