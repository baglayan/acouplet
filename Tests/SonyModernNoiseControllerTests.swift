import XCTest
@testable import Acouplet

@MainActor
final class SonyModernNoiseControllerTests: XCTestCase {
    private let variants: [(function: UInt8, inquiry: UInt8)] = [
        (0x61, 0x01), (0x62, 0x11), (0x63, 0x12), (0x64, 0x13), (0x65, 0x14),
        (0x66, 0x21), (0x67, 0x22), (0x68, 0x15), (0x6A, 0x16), (0x6B, 0x17),
        (0x6C, 0x18), (0x6D, 0x19)
    ]

    func testEveryAdvertisedDialectAcquiresItsOwnValidatedMetadataBeforeParameters() {
        for (function, inquiry) in variants {
            let controller = beginDiscovery([function])
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.noiseControl?.inquiryType, inquiry)
            XCTAssertEqual(noiseQueries(controller), [[0x60, inquiry]])
            deliver([0x63, inquiry, 0], to: controller)
            deliver(parameter(inquiry), to: controller)
            XCTAssertNil(controller.noiseControl?.available)
            XCTAssertNil(controller.noiseControl?.state)
            deliver(capability(inquiry), type: 0x0E, to: controller)
            XCTAssertNil(controller.noiseControl?.capabilities)
            deliver(capability(inquiry) + [0], to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(noiseQueries(controller), [[0x60, inquiry]])
            deliver(capability(inquiry), to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(noiseQueries(controller), [[0x60, inquiry], [0x62, inquiry]])
            deliver([0x63, inquiry, 255], to: controller)
            XCTAssertFalse(noiseQueries(controller).contains([0x66, inquiry]))
            deliver([0x63, inquiry, 0], to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(noiseQueries(controller), [[0x60, inquiry], [0x62, inquiry], [0x66, inquiry]])
            deliver(parameter(inquiry), to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.noiseControlMode, .off)
            XCTAssertEqual(controller.ambientLevel, inquiry == 1 || [0x11, 0x12, 0x21].contains(inquiry) ? 0 : 5)
            XCTAssertEqual(controller.availableNoiseModes, controller.noiseControl?.supportedModes)
            XCTAssertEqual(controller.ambientLevelRange != nil, controller.noiseControl?.supportsAmbientLevel)
        }
    }

    func testCapabilityAndStatusRepliesNeedTheirQueryAcknowledgmentBeforeAdvancing() {
        for inquiry: UInt8 in [0x01, 0x14, 0x17, 0x19] {
            let function = variants.first { $0.inquiry == inquiry }!.function
            let controller = beginDiscovery([function], acknowledgeQueries: false)
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x60, inquiry])
            deliver(capability(inquiry), to: controller)
            XCTAssertEqual(noiseQueries(controller), [[0x60, inquiry]])
            acknowledgeOne(controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x62, inquiry])
            deliver([0x63, inquiry, 0], to: controller)
            XCTAssertEqual(noiseQueries(controller), [[0x60, inquiry], [0x62, inquiry]])
            acknowledgeOne(controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x66, inquiry])
            deliver(parameter(inquiry), to: controller)
            acknowledgeAll(controller)
            XCTAssertTrue(controller.canChangeNoiseControl)
        }
    }

    func testSelectionPrefersCombinedModernDialectAndKeepsToggleIndependent() {
        let controller = beginDiscovery([0x61, 0x62, 0x65, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D])
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.noiseControl?.inquiryType, 0x19)
        XCTAssertNotNil(controller.noiseToggle)
        XCTAssertNil(controller.noiseTest)
        XCTAssertEqual(noiseQueries(controller), [[0x60, 0x19]])
        let toggle = readyController(functions: [0x69])
        defer { toggle.simulateControlLoss() }
        XCTAssertNil(toggle.noiseControl)
        XCTAssertTrue(toggle.availableNoiseModes.isEmpty)
        XCTAssertFalse(toggle.canChangeNoiseControl)
        XCTAssertTrue(toggle.canSetNoiseToggle)
    }

    func testEveryModeWriteUsesItsDialectAndRequiresBothAcknowledgmentAndMatchingState() {
        for (function, inquiry) in variants {
            let controller = readyController(functions: [function])
            defer { controller.simulateControlLoss() }
            controller.setNoiseControl(inquiry == 1 ? .anc : .ambient)
            let expected = ambientWrite(inquiry)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, expected)
            XCTAssertEqual(controller.pendingChanges[.noiseControl], Array(expected.dropFirst()))
            XCTAssertTrue(controller.canRetryBasicCommand(SonyFrame(type: 0x0C, sequence: 0, payload: expected)))
            XCTAssertFalse(controller.canRetryBasicCommand(SonyFrame(type: 0x0E, sequence: 0, payload: expected)))
            deliver([0x69] + expected.dropFirst(), type: 0x0E, to: controller)
            deliver(Array(([0x69] + expected.dropFirst()).dropLast()), to: controller)
            XCTAssertNotNil(controller.pendingChanges[.noiseControl])
            deliver([0x69] + expected.dropFirst(), to: controller)
            XCTAssertNotNil(controller.pendingChanges[.noiseControl])
            acknowledgeAll(controller)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
            XCTAssertEqual(controller.noiseControlMode, inquiry == 1 ? .anc : .ambient)
            XCTAssertFalse(controller.focusOnVoice)
            XCTAssertFalse(controller.canRetryBasicCommand(SonyFrame(type: 0x0C, sequence: 0, payload: expected)))
        }
    }

    func testAcknowledgmentAloneRequestsAnOwnedReadbackAndCannotConfirmTheWrite() {
        let controller = readyController(functions: [0x65])
        defer { controller.simulateControlLoss() }
        controller.setNoiseControl(.ambient)
        let expected = ambientWrite(0x14)
        acknowledgeAll(controller)
        XCTAssertEqual(noiseQueries(controller).last, [0x66, 0x14])
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        deliver(parameter(0x14), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        deliver([0x69] + expected.dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
    }

    func testNewerContradictingNotificationInvalidatesConfirmationReceivedBeforeAcknowledgment() {
        let controller = readyController(functions: [0x64])
        defer { controller.simulateControlLoss() }
        controller.setNoiseControl(.ambient)
        deliver([0x69] + ambientWrite(0x13).dropFirst(), to: controller)
        deliver([0x69] + parameter(0x13).dropFirst(), to: controller)
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlMode, .off)
        deliver([0x67] + ambientWrite(0x13).dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
    }

    func testOldPollCannotUndoANotificationOrConfirmANewerWrite() {
        let controller = readyController(functions: [0x6A])
        defer { controller.simulateControlLoss() }
        controller.requestCurrentSettings()
        acknowledgeAll(controller)
        deliver([0x63, 0x16, 0], to: controller)
        acknowledgeAll(controller)
        controller.setNoiseControl(.ambient)
        acknowledgeAll(controller)
        deliver([0x69] + ambientWrite(0x16).dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        controller.setNoiseControl(.off)
        acknowledgeAll(controller)
        var off = ambientWrite(0x16)
        off[3] = 0
        let count = noiseQueries(controller).filter { $0 == [0x66, 0x16] }.count
        deliver([0x67] + off.dropFirst(), to: controller)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        acknowledgeAll(controller)
        XCTAssertEqual(noiseQueries(controller).filter { $0 == [0x66, 0x16] }.count, count + 1)
        deliver([0x67] + off.dropFirst(), to: controller)
        XCTAssertEqual(controller.noiseControlMode, .off)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
    }

    func testAvailabilityNotificationWinsOverOutstandingStatusReturn() {
        let controller = readyController(functions: [0x63])
        defer { controller.simulateControlLoss() }
        controller.requestCurrentSettings()
        acknowledgeAll(controller)
        deliver([0x65, 0x12, 1], to: controller)
        deliver([0x63, 0x12, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        let writes = controller.simulatedTransmittedFrames
        controller.setNoiseControl(.anc)
        XCTAssertEqual(controller.simulatedTransmittedFrames, writes)
        deliver([0x63, 0x12, 0], to: controller)
        acknowledgeAll(controller)
        deliver(parameter(0x12), to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testDeferredModeWriteIsCancelledIfAvailabilityChangesBeforeTransmission() {
        let controller = readyController(functions: [0x6A])
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setNoiseControl(.ambient)
        deliver([0x65, 0x16, 1], to: controller)
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == ambientWrite(0x16) })
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertNotNil(controller.settingErrors[.noiseControl])
        XCTAssertTrue(controller.isReady)
    }

    func testNotificationBeginningBeforeSetTransmissionCannotConfirmIt() {
        for split in [1, 4, 9] {
            let controller = readyController(functions: [0x65])
            defer { controller.simulateControlLoss() }
            deliver([0x69] + parameter(0x14).dropFirst(), to: controller)
            acknowledgeAll(controller)
            let sequence = controller.simulatedTransmittedFrames.last(where: { $0.type == 1 })!.sequence
            let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: sequence, payload: [0x69] + ambientWrite(0x14).dropFirst())
            controller.defersSimulatedWrites = true
            controller.setNoiseControl(.ambient)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, ambientWrite(0x14))
            controller.simulateProtocolData(encoded.prefix(split))
            controller.completeSimulatedWrite()
            controller.simulateProtocolData(encoded.dropFirst(split))
            controller.completeSimulatedWrite()
            controller.defersSimulatedWrites = false
            acknowledgeAll(controller)
            XCTAssertNotNil(controller.pendingChanges[.noiseControl])
            deliver([0x69] + ambientWrite(0x14).dropFirst(), to: controller)
            XCTAssertNil(controller.pendingChanges[.noiseControl])
        }
    }

    func testNCSSIsAnExplicitStateAndPreservesItsAmbientFields() {
        let controller = readyController(functions: [0x6C])
        defer { controller.simulateControlLoss() }
        controller.setNoiseCancellingSS()
        let expected: [UInt8] = [0x68, 0x18, 1, 1, 2, 0, 5]
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, expected)
        acknowledgeAll(controller)
        deliver([0x67] + expected.dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertNil(controller.noiseControlMode)
        XCTAssertEqual(controller.noiseControlDisplayState?.isNoiseCancellingSS, true)
        XCTAssertTrue(controller.diagnosticReport.contains("Noise control: NCSS"))
        XCTAssertTrue(controller.canChangeNoiseControl)
        acknowledgeAll(controller)
        controller.setNoiseControl(.ambient)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, ambientWrite(0x18))
    }

    func testToggleIsIndependentAndRequiresAcknowledgedValidState() {
        let controller = readyController(functions: [0x65, 0x69])
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.canSetNoiseToggle)
        controller.setNoiseToggle(4)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x68, 0x30, 4])
        deliver([0x69, 0x30, 4], type: 0x0E, to: controller)
        deliver([0x69, 0x30, 255], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseToggle])
        deliver([0x69, 0x30, 4], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseToggle])
        XCTAssertEqual(controller.noiseControlMode, .off)
        acknowledgeAll(controller)
        XCTAssertNil(controller.pendingChanges[.noiseToggle])
        XCTAssertEqual(controller.noiseToggle?.selected, 4)
        XCTAssertTrue(controller.canChangeNoiseControl)
        deliver([0x65, 0x30, 1], to: controller)
        XCTAssertFalse(controller.canSetNoiseToggle)
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testNoiseTestFinishesWithAcknowledgedOutStatusBeforeApplyingSelectedMode() {
        let controller = readyController(functions: [0x6C])
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.canStartNoiseTest)
        controller.startNoiseTest()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x64, 0x40, 0])
        XCTAssertTrue(controller.isRunningHeadphoneTest)
        deliver([0x65, 0x40, 0], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseTest])
        acknowledgeAll(controller)
        XCTAssertTrue(controller.canFinishNoiseTest)
        controller.finishNoiseTest(noiseCancellingSS: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x64, 0x40, 1])
        deliver([0x65, 0x40, 1], to: controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        acknowledgeOne(controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x68, 0x18, 1, 1, 2, 0, 5])
        acknowledgeAll(controller)
        deliver([0x67, 0x18, 1, 1, 2, 0, 5], to: controller)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertEqual(controller.noiseControlDisplayState?.isNoiseCancellingSS, true)
    }

    func testExternalTestExitDoesNotApplyAModeAndOldSessionCannotReenter() {
        let controller = readyController(functions: [0x6C])
        defer { controller.simulateControlLoss() }
        controller.startNoiseTest()
        acknowledgeAll(controller)
        deliver([0x63, 0x40, 0], to: controller)
        XCTAssertTrue(controller.canFinishNoiseTest)
        deliver([0x65, 0x40, 1], to: controller)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        connect(controller, functions: [0x61])
        finishDiscovery(controller, functions: [0x61])
        controller.simulateProtocolMessage([0x65, 0x40, 0], session: session)
        controller.simulateProtocolMessage([0x69, 1, 1, 1, 1], session: session)
        XCTAssertNil(controller.noiseTest)
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertEqual(controller.noiseControlMode, .off)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testTimedOutTestStartRequiresFreshOwnedStatusBeforeAnotherOperation() async {
        let controller = readyController(functions: [0x6C])
        defer { controller.simulateControlLoss() }
        controller.startNoiseTest()
        acknowledgeAll(controller)
        controller.simulateSettingTimeout(.noiseTest)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(controller.settingErrors[.noiseTest])
        XCTAssertFalse(controller.canStartNoiseTest)
        XCTAssertFalse(controller.canFinishNoiseTest)
        deliver([0x63, 0x40, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertNil(controller.settingErrors[.noiseTest])
        XCTAssertTrue(controller.canFinishNoiseTest)
    }

    func testBinaryAmbientPresetUsesOnlyAdvertisedControls() {
        for function: UInt8 in [0x62, 0x63, 0x66] {
            let controller = readyController(functions: [function])
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.canApplyNoisePreset(mode: .ambient, ambientLevel: 17, focusOnVoice: false))
            controller.applyPreset(mode: .ambient, ambientLevel: 17, focusOnVoice: false)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, ambientWrite(controller.noiseControl!.inquiryType))
        }
    }

    func testDeferredNoiseTestStartRechecksNoiseAvailability() {
        let controller = readyController(functions: [0x6C])
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.startNoiseTest()
        deliver([0x65, 0x18, 1], to: controller)
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x64, 0x40, 0] })
        XCTAssertNil(controller.pendingChanges[.noiseTest])
        XCTAssertNotNil(controller.settingErrors[.noiseTest])
        XCTAssertFalse(controller.isRunningHeadphoneTest)
    }

    func testExternalExitBeforeDeferredFinishCancelsModeSelectionAndReleasesControls() {
        let controller = readyController(functions: [0x6C])
        defer { controller.simulateControlLoss() }
        controller.startNoiseTest()
        acknowledgeAll(controller)
        deliver([0x63, 0x40, 0], to: controller)
        controller.defersSimulatedWrites = true
        controller.finishNoiseTest(noiseCancellingSS: true)
        deliver([0x65, 0x40, 1], to: controller)
        controller.completeSimulatedWrite()
        controller.defersSimulatedWrites = false
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x64, 0x40, 1] || $0.payload.first == 0x68 })
        XCTAssertNil(controller.pendingChanges[.noiseTest])
        XCTAssertFalse(controller.isRunningHeadphoneTest)
        XCTAssertTrue(controller.canChangeNoiseControl)
        XCTAssertTrue(controller.canStartNoiseTest)
    }

    func testTerminalNotificationAfterInitialChangingStateReleasesTheReadSequence() {
        let controller = beginDiscovery([0x6D])
        defer { controller.simulateControlLoss() }
        deliver(capability(0x19), to: controller)
        acknowledgeAll(controller)
        deliver([0x63, 0x19, 0], to: controller)
        acknowledgeAll(controller)
        var changing = parameter(0x19)
        changing[2] = 0
        deliver(changing, to: controller)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver([0x69] + parameter(0x19).dropFirst(), to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
        let reads = noiseQueries(controller).filter { $0 == [0x62, 0x19] }.count
        controller.requestCurrentSettings()
        acknowledgeAll(controller)
        XCTAssertEqual(noiseQueries(controller).filter { $0 == [0x62, 0x19] }.count, reads + 1)
    }

    func testChangingNotificationSupersedesAnOlderTerminalPollWithoutExtendingItsDeadline() throws {
        for function: UInt8 in [0x62, 0x65, 0x6C] {
            let controller = readyController(functions: [function])
            defer { controller.simulateControlLoss() }
            let inquiry = controller.noiseControl!.inquiryType
            let query: [UInt8] = [0x66, inquiry]
            controller.requestCurrentSettings()
            acknowledgeAll(controller)
            deliver([0x63, inquiry, 0], to: controller)
            acknowledgeAll(controller)
            let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
            let reads = noiseQueries(controller).filter { $0 == query }.count
            var changing = ambientWrite(inquiry)
            changing[0] = 0x69
            changing[2] = 0
            deliver(changing, to: controller)
            deliver(parameter(inquiry), to: controller)
            XCTAssertFalse(controller.canChangeNoiseControl)
            XCTAssertNil(controller.noiseControl?.state)
            XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
            XCTAssertEqual(noiseQueries(controller).filter { $0 == query }.count, reads)
        }
    }

    func testChangingNotificationInvalidatesTerminalConfirmationCachedBeforeAcknowledgment() {
        let controller = readyController(functions: [0x6D])
        defer { controller.simulateControlLoss() }
        controller.setNoiseControl(.ambient)
        deliver([0x69] + ambientWrite(0x19).dropFirst(), to: controller)
        var changing = ambientWrite(0x19)
        changing[0] = 0x69
        changing[2] = 0
        deliver(changing, to: controller)
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.noiseControl])
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver([0x69] + ambientWrite(0x19).dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.noiseControl])
        XCTAssertTrue(controller.canChangeNoiseControl)
    }

    func testChangingNotificationWaitsForTheDelayedOldReplyBeforeSendingRecovery() async throws {
        let controller = readyController(functions: [0x6B])
        defer { controller.simulateControlLoss() }
        let query: [UInt8] = [0x66, 0x17]
        controller.requestCurrentSettings()
        acknowledgeAll(controller)
        deliver([0x63, 0x17, 0], to: controller)
        acknowledgeAll(controller)
        let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
        let reads = noiseQueries(controller).filter { $0 == query }.count
        var changing = ambientWrite(0x17)
        changing[0] = 0x69
        changing[2] = 0
        deliver(changing, to: controller)
        try await Task.sleep(for: .milliseconds(300))
        acknowledgeAll(controller)
        XCTAssertEqual(noiseQueries(controller).filter { $0 == query }.count, reads)
        XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
        XCTAssertFalse(controller.canChangeNoiseControl)
        deliver(parameter(0x17), to: controller)
        XCTAssertFalse(controller.canChangeNoiseControl)
        XCTAssertNil(controller.noiseControl?.state)
        try await Task.sleep(for: .milliseconds(300))
        acknowledgeAll(controller)
        XCTAssertEqual(noiseQueries(controller).filter { $0 == query }.count, reads + 1)
        XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
        deliver([0x67] + ambientWrite(0x17).dropFirst(), to: controller)
        XCTAssertTrue(controller.canChangeNoiseControl)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
    }

    func testTerminalNotificationAfterChangingCannotRetireAnUnconsumedOldRead() throws {
        for oldReply: [UInt8] in [parameter(0x17), [0x67, 0x17, 0, 0, 0, 0, 5], [0x67, 0x17]] {
            let controller = readyController(functions: [0x6B])
            defer { controller.simulateControlLoss() }
            let query: [UInt8] = [0x66, 0x17]
            controller.requestCurrentSettings()
            acknowledgeAll(controller)
            deliver([0x63, 0x17, 0], to: controller)
            acknowledgeAll(controller)
            let deadline = try XCTUnwrap(controller.simulatedNoiseReadTimeoutID(query))
            let reads = noiseQueries(controller).filter { $0 == query }.count
            var changing = ambientWrite(0x17)
            changing[0] = 0x69
            changing[2] = 0
            deliver(changing, to: controller)
            deliver([0x69] + ambientWrite(0x17).dropFirst(), to: controller)
            let state = controller.noiseControl?.state
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.noiseControlMode, .ambient)
            XCTAssertEqual(noiseQueries(controller).filter { $0 == query }.count, reads)
            XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
            deliver(oldReply, to: controller)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertEqual(controller.noiseControlMode, .ambient)
            XCTAssertEqual(controller.noiseControl?.state, state)
            if oldReply.count == 2 {
                acknowledgeAll(controller)
                XCTAssertEqual(noiseQueries(controller).filter { $0 == query }.count, reads)
                XCTAssertEqual(controller.simulatedNoiseReadTimeoutID(query), deadline)
                deliver(parameter(0x17), to: controller)
                XCTAssertEqual(controller.noiseControl?.state, state)
            }
            acknowledgeAll(controller)
            XCTAssertEqual(noiseQueries(controller).filter { $0 == query }.count, reads + 1)
            deliver([0x67] + ambientWrite(0x17).dropFirst(), to: controller)
            XCTAssertTrue(controller.canChangeNoiseControl)
            XCTAssertNil(controller.simulatedNoiseReadTimeoutID(query))
        }
    }

    private func beginDiscovery(_ functions: [UInt8], acknowledgeQueries: Bool = true) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        connect(controller, functions: functions, acknowledgeQueries: acknowledgeQueries)
        return controller
    }

    private func connect(_ controller: SonyHeadphonesController, functions: [UInt8], acknowledgeQueries: Bool = true) {
        controller.simulateDeviceConnection(named: "WH-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        if acknowledgeQueries { acknowledgeAll(controller) }
    }

    private func readyController(functions: [UInt8]) -> SonyHeadphonesController {
        let controller = beginDiscovery(functions)
        finishDiscovery(controller, functions: functions)
        return controller
    }

    private func finishDiscovery(_ controller: SonyHeadphonesController, functions: [UInt8]) {
        if let inquiry = controller.noiseControl?.inquiryType {
            for reply in [capability(inquiry), [0x63, inquiry, 0], parameter(inquiry)] {
                deliver(reply, to: controller)
                acknowledgeAll(controller)
            }
        }
        if functions.contains(0x69) {
            for reply: [UInt8] in [[0x61, 0x30, 2], [0x63, 0x30, 0], [0x67, 0x30, 1]] {
                deliver(reply, to: controller)
                acknowledgeAll(controller)
            }
        }
        if controller.noiseTest != nil {
            deliver([0x63, 0x40, 1], to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertTrue(controller.isReady)
    }

    private func capability(_ inquiry: UInt8) -> [UInt8] {
        if inquiry == 1 { return [0x61, 1] }
        if [0x11, 0x12, 0x21].contains(inquiry) { return [0x61, inquiry, 2, 0, 1] }
        return [0x61, inquiry, 2, 0, 1, 20, 1, 1, 1, 20, 1]
    }

    private func parameter(_ inquiry: UInt8) -> [UInt8] {
        switch inquiry {
        case 1: [0x67, 1, 1, 0, 0]
        case 0x11, 0x12: [0x67, inquiry, 1, 0, 0, 0, 0]
        case 0x15, 0x16: [0x67, inquiry, 1, 0, 0, 2, 0, 5]
        case 0x19: [0x67, inquiry, 1, 0, 0, 0, 5, 1, 2]
        case 0x21: [0x67, inquiry, 1, 0, 0, 0]
        case 0x22: [0x67, inquiry, 1, 0, 0, 5]
        default: [0x67, inquiry, 1, 0, 0, 0, 5]
        }
    }

    private func ambientWrite(_ inquiry: UInt8) -> [UInt8] {
        switch inquiry {
        case 1: [0x68, 1, 1, 1, 1]
        case 0x11, 0x12: [0x68, inquiry, 1, 1, 0, 0, 1]
        case 0x13, 0x14: [0x68, inquiry, 1, 1, 0, 0, 5]
        case 0x15, 0x16: [0x68, inquiry, 1, 1, 1, 2, 0, 5]
        case 0x19: [0x68, inquiry, 1, 1, 1, 0, 5, 1, 2]
        case 0x21: [0x68, inquiry, 1, 1, 0, 1]
        case 0x22: [0x68, inquiry, 1, 1, 0, 5]
        default: [0x68, inquiry, 1, 1, 1, 0, 5]
        }
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func acknowledgeOne(_ controller: SonyHeadphonesController) {
        controller.completeSimulatedWrite()
        guard let frame = controller.simulatedPendingFrame else { return XCTFail("Expected a pending frame.") }
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<150 {
            controller.completeSimulatedWrite()
            guard controller.simulatedPendingFrame != nil else { return }
            acknowledgeOne(controller)
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func noiseQueries(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter {
            $0.type == 0x0C && $0.payload.count == 2 && [0x60, 0x62, 0x66].contains($0.payload[0])
                && $0.payload[1] != 0x30 && $0.payload[1] != 0x40
        }.map(\.payload)
    }
}
