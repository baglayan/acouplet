import XCTest
@testable import Acouplet

final class SonySoundPressureTests: XCTestCase {
    private let levelQueryPayload: [UInt8] = [0x5A, 3]

    func testOnlyNegotiatedDialectAcceptsT2Replies() {
        for functions: Set<UInt8> in [[], [0x54, 0x55]] {
            var pressure = SonySoundPressure(supportedFunctions: functions)
            XCTAssertFalse(pressure.isSupported)
            XCTAssertTrue(pressure.queryPayloads.isEmpty)
            for payload in validPayloads { XCTAssertFalse(pressure.update(payload)) }
        }
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        XCTAssertTrue(pressure.isSupported)
        XCTAssertEqual(pressure.queryPayloads, [[0x50, 3], [0x56, 3]])
        XCTAssertEqual(pressure.levelQueryPayload, levelQueryPayload)
        let prior = pressure
        for payload in validPayloads {
            for type: UInt8 in [0, 0x0C, 0x10, 0xFF] {
                XCTAssertFalse(pressure.update(payload, frameType: type))
                XCTAssertEqual(pressure, prior)
            }
            for inquiry: UInt8 in [0, 1, 2, 4, 5, 0xFF] {
                var wrongInquiry = payload
                wrongInquiry[1] = inquiry
                XCTAssertFalse(pressure.update(wrongInquiry))
                XCTAssertEqual(pressure, prior)
            }
        }
    }

    @MainActor
    func testControllerQueriesAndDisplaysEachNegotiatedVariant() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        for inquiry: UInt8 in 0...3 {
            controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0x50 + inquiry])
            XCTAssertEqual(controller.soundPressure.inquiryType, inquiry)
            XCTAssertEqual(controller.soundPressure.queryPayloads, [[0x56, inquiry]])
            XCTAssertEqual(controller.soundPressure.available, true)
            controller.refreshSoundPressure()
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x5A, inquiry])
            acknowledgeSimulatedCommands(controller)
            deliver([0x5B, (inquiry + 1) % 4, 75, 0xFF], to: controller)
            XCTAssertNil(controller.soundPressure.reading)
            XCTAssertTrue(controller.isReadingSoundPressure)
            deliver([0x5B, inquiry, 75, 0xFF], to: controller)
            XCTAssertEqual(controller.soundPressure.reading, .decibels(75))
            XCTAssertFalse(controller.isReadingSoundPressure)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testControllerReadsCurrentExposureAndCompletesBatchedHistory() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", simulatedTable2Functions: [0x53])
        defer { controller.simulateControlLoss() }
        let left: [UInt8] = [1, 0, 0, 0, 9, 0, 1, 5, 0x07, 0x27, 0x0E, 0, 3]
        let right: [UInt8] = [2, 0, 0, 0, 9, 0, 1, 5, 0x07, 0x27, 0x0E, 0, 5]

        controller.readExposure(current: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x52, 3])
        acknowledgeSimulatedCommands(controller)
        deliver([0x53, 3, 1, 2] + left + right, to: controller)
        XCTAssertEqual(controller.currentExposure?.listeningMinutes, 5)
        XCTAssertEqual(controller.currentExposure?.averageDecibels, 100)
        XCTAssertEqual(controller.currentExposure?.ambientMinutes, 8)
        XCTAssertNil(controller.exposureHistory)

        controller.defersSimulatedWrites = true
        controller.readExposure(current: false)
        controller.defersSimulatedWrites = false
        let final: [UInt8] = [0x55, 3, 2, 2, 2] + left + right
        deliver(final, to: controller)
        XCTAssertNil(controller.exposureHistory)
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x54, 3, 1, 1] + Array(repeating: 0, count: 12))
        acknowledgeSimulatedCommands(controller)

        deliver([0x55, 3, 1, 1, 1] + left, to: controller)
        deliver(Array(final.dropLast()), to: controller)
        XCTAssertTrue(controller.isReadingExposure)
        XCTAssertNil(controller.exposureHistory)
        deliver(final, to: controller)
        XCTAssertFalse(controller.isReadingExposure)
        XCTAssertEqual(controller.exposureHistory?.listeningMinutes, 5)
        XCTAssertEqual(controller.exposureHistory?.averageDecibels, 100)
        XCTAssertEqual(controller.exposureHistory?.ambientMinutes, 8)
        XCTAssertNil(controller.exposureReadError)
    }

    @MainActor
    func testExposureTransferErrorStopsTransferAndReconnectClearsState() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", simulatedTable2Functions: [0x50])
        defer { controller.simulateControlLoss() }
        controller.readExposure(current: false)
        acknowledgeSimulatedCommands(controller)
        deliver([0x55, 0, 4, 0], to: controller)
        XCTAssertFalse(controller.isReadingExposure)
        XCTAssertNotNil(controller.exposureReadError)
        XCTAssertNil(controller.exposureHistory)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x54, 0, 3] + Array(repeating: 0, count: 6))
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.canReadExposure)
        controller.simulateDeviceConnection(named: "WH-1000XM5", simulatedTable2Functions: [0x50])
        XCTAssertTrue(controller.canReadExposure)
        XCTAssertNil(controller.exposureReadError)
    }

    @MainActor
    func testControllerConfirmsModeOnlyFromMatchingTable2Notification() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", simulatedTable2Functions: [0x52])
        defer { controller.simulateControlLoss() }
        deliver([0x59, 2, 1, 1], to: controller)
        controller.setSoundPressureMode(.preview)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 2, 1, 0])
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.soundPressure.mode, .off)
        deliver([0x59, 3, 1, 0], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.soundPressureMode])
        deliver([0x59, 2, 1, 0], to: controller)
        XCTAssertEqual(controller.soundPressure.mode, .preview)
        XCTAssertNil(controller.pendingChanges[.soundPressureMode])
    }

    @MainActor
    func testVolumeProtectionReportsSafeVolumeAndConfirmsOnlyEnabledMaxVolumeWrites() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", simulatedTable2Functions: [0x54, 0x55])
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.volumeProtection.queryPayloads, [[0x50, 5], [0x52, 5], [0x56, 5]])
        XCTAssertNil(controller.volumeProtection.safeVolumeEnabled)
        deliver([0x59, 4, 1, 0], to: controller)
        deliver([0x55, 4, 1], to: controller)
        XCTAssertEqual(controller.volumeProtection.safeVolumeEnabled, true)
        XCTAssertEqual(controller.volumeProtection.automaticallyLimiting, false)
        XCTAssertEqual(controller.volumeProtection.hearingProfile, .sensitive)

        controller.enableMaxVolume()
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x51, 5, 1, 31], to: controller)
        deliver([0x53, 5, 1], to: controller)
        deliver([0x57, 5, 3], to: controller)
        controller.setMaxVolumePreset(.percent30)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.enableMaxVolume()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x54, 5, 0])
        acknowledgeSimulatedCommands(controller)
        deliver([0x53, 5, 0], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.maxVolumeEnabled])
        XCTAssertEqual(controller.volumeProtection.maxVolumeEnabled, false)
        deliver([0x55, 5, 0], to: controller)
        XCTAssertEqual(controller.volumeProtection.maxVolumeEnabled, true)
        XCTAssertNil(controller.pendingChanges[.maxVolumeEnabled])

        controller.setMaxVolumePreset(.percent30)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 5, 0])
        acknowledgeSimulatedCommands(controller)
        deliver([0x59, 5, 0], to: controller)
        XCTAssertEqual(controller.volumeProtection.limitPreset, .percent30)
        XCTAssertNil(controller.pendingChanges[.maxVolumePreset])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.dropFirst().first == 4 })
    }

    func testVolumeProtectionKeepsUnknownStatesAndRejectsUnadvertisedStates() {
        var model = SonyVolumeProtection(supportedFunctions: [0x54])
        XCTAssertTrue(model.queryPayloads.isEmpty)
        XCTAssertNil(model.safeVolumeEnabled)
        XCTAssertNil(model.automaticallyLimiting)
        XCTAssertFalse(model.update([0x53, 5, 0]))
        XCTAssertFalse(model.update([0x59, 4, 1, 0], frameType: 0x0C))
        XCTAssertFalse(model.update([0x59, 4, 1, 2]))
        XCTAssertTrue(model.update([0x59, 4, 0, 0]))
        XCTAssertEqual(model.safeVolumeEnabled, true)
        XCTAssertEqual(model.automaticallyLimiting, true)
        XCTAssertNil(model.enablePayload)
    }

    @MainActor
    func testUSBProtectionReportsOnlyNegotiatedStatusAndDiscardsStaleReads() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", controlBusy: true)
        defer { controller.simulateControlLoss() }
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x07, 0, 1, 0x90, 0], type: 0x0C, to: controller)
        acknowledgeSimulatedCommands(controller)
        XCTAssertTrue(controller.usbProtection.ports.isEmpty)
        deliver([0x07, 0, 1, 0x23, 0], to: controller)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.usbProtection.queryPayloads, [[0x20, 2], [0x22, 2]])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E }.map(\.payload),
                       [[0x06, 0], [0x20, 2], [0x22, 2]])
        deliver([0x21, 2, 0], to: controller)
        deliver([0x25, 2, 0], type: 0x0C, to: controller)
        deliver([0x25, 3, 0], to: controller)
        XCTAssertNil(controller.usbProtection.ports[.moisture]?.detected)
        XCTAssertNil(controller.usbProtection.ports[.overheat])
        XCTAssertEqual(controller.usbProtection.ports[.moisture]?.monitoring, .whileNotCharging)
        deliver([0x25, 2, 0], to: controller)
        deliver([0x23, 2, 1], to: controller)
        XCTAssertEqual(controller.usbProtection.ports[.moisture]?.detected, true)
        XCTAssertTrue(controller.usbProtection.queryPayloads.isEmpty)
        deliver([0x25, 2, 1], to: controller)
        XCTAssertEqual(controller.usbProtection.ports[.moisture]?.detected, false)
        controller.simulateControlLoss()
        XCTAssertTrue(controller.usbProtection.ports.isEmpty)
    }

    @MainActor
    func testUSBCautionAcknowledgementPreservesDeviceReportedProtectionState() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", simulatedTable2Functions: [0x23, 0x24])
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.usbProtection.queryPayloads, [[0x20, 2], [0x22, 2], [0x20, 3], [0x22, 3]])
        deliver([0x25, 2, 0], to: controller)
        deliver([0x25, 3, 0], to: controller)
        deliver([0x99, 0, 0x92, 2], type: 0x0C, to: controller)
        deliver([0x99, 0, 0x94, 2], type: 0x0C, to: controller)
        XCTAssertTrue(controller.usbProtection.cautions.isEmpty)
        deliver([0x99, 0, 0x91, 2], type: 0x0C, to: controller)
        deliver([0x99, 0, 0x95, 2], type: 0x0C, to: controller)
        let session = controller.notificationSession
        controller.acknowledgeUSBCaution(.moisture, expectedSession: session &+ 1)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.acknowledgeUSBCaution(.moisture, expectedSession: session)
        XCTAssertEqual(controller.simulatedPendingFrame?.type, 0x0C)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 0x91, 1])
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.usbProtection.cautions.contains(.moisture))
        XCTAssertEqual(controller.usbProtection.ports[.moisture]?.detected, true)
        controller.acknowledgeUSBCaution(.overheat, expectedSession: session)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 0x95, 1])
        acknowledgeSimulatedCommands(controller)
        deliver([0x29, 3, 1], to: controller)
        XCTAssertFalse(controller.usbProtection.cautions.contains(.overheat))
        XCTAssertEqual(controller.usbProtection.heatAcknowledgementAccepted, false)
        controller.acknowledgeUSBCaution(.overheat, expectedSession: session)
        XCTAssertNil(controller.simulatedPendingFrame)
        deliver([0x29, 3, 0], to: controller)
        XCTAssertFalse(controller.usbProtection.cautions.contains(.overheat))
        XCTAssertEqual(controller.usbProtection.heatAcknowledgementAccepted, true)
        XCTAssertEqual(controller.usbProtection.ports[.overheat]?.detected, true)
        deliver([0x25, 3, 1], to: controller)
        XCTAssertEqual(controller.usbProtection.ports[.overheat]?.detected, false)
    }

    func testCapabilityUsesUnsignedFieldsAndPositiveIntervalWithoutScalingLevel() {
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        XCTAssertNil(pressure.intervalSeconds)
        XCTAssertTrue(pressure.update([0x51, 3, 0xFE, 0x89, 0xAB, 0xCD, 0xEF, 5, 0xFF]))
        XCTAssertEqual(pressure.roundBase, 0xFE)
        XCTAssertEqual(pressure.timestampBase, 0x89ABCDEF)
        XCTAssertEqual(pressure.minimumInterval, 5)
        XCTAssertEqual(pressure.intervalSeconds, 5)
        XCTAssertEqual(pressure.logCapacity, 0xFF)
        XCTAssertEqual(pressure.queryPayloads, [[0x56, 3]])
        XCTAssertTrue(pressure.update([0x5B, 3, 80, 0xFF]))
        XCTAssertEqual(pressure.reading, .decibels(80))
        for interval: UInt8 in [0, 1, 255] {
            XCTAssertTrue(pressure.update([0x51, 3, 1, 0, 0, 0, 0, interval, 0]))
            XCTAssertEqual(pressure.minimumInterval, interval)
            XCTAssertEqual(pressure.intervalSeconds, interval == 0 ? nil : Int(interval))
        }
    }

    func testCapturedSentinelAndNumericReasonsDoNotInventMeasurements() {
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        XCTAssertTrue(pressure.update([0x5B, 3, 0xFF, 0]))
        XCTAssertEqual(pressure.reading, .notPlaying)
        for level: UInt8 in [0, 80, 254, 255] {
            for (reason, reading): (UInt8, SonySoundPressureReading) in [(0, .notPlaying), (1, .inCall), (2, .notWorn)] {
                XCTAssertTrue(pressure.update([0x5B, 3, level, reason]))
                XCTAssertEqual(pressure.reading, reading)
            }
        }
        for level: UInt8 in [0, 80, 254] {
            XCTAssertTrue(pressure.update([0x5B, 3, level, 0xFF]))
            XCTAssertEqual(pressure.reading, .decibels(Int(level)))
            XCTAssertTrue(pressure.update([0x5B, 3, level, 3]))
            XCTAssertEqual(pressure.reading, .unknown(level: level, reason: 3))
        }
        let prior = pressure
        for reason: UInt8 in [3, 254, 255] {
            XCTAssertFalse(pressure.update([0x5B, 3, 0xFF, reason]))
            XCTAssertEqual(pressure, prior)
        }
    }

    func testAvailabilityAndModeLayoutsStayIndependentAndInvalidateOldReadings() {
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        XCTAssertTrue(pressure.update([0x57, 3, 0]))
        XCTAssertEqual(pressure.available, true)
        XCTAssertNil(pressure.measurementEnabled)
        XCTAssertNil(pressure.previewEnabled)
        XCTAssertTrue(pressure.update([0x59, 3, 0, 1]))
        XCTAssertEqual(pressure.measurementEnabled, true)
        XCTAssertEqual(pressure.previewEnabled, false)
        XCTAssertEqual(pressure.available, true)
        XCTAssertTrue(pressure.update([0x5B, 3, 80, 0xFF]))
        XCTAssertTrue(pressure.update([0x59, 3, 0, 1]))
        XCTAssertEqual(pressure.reading, .decibels(80))
        XCTAssertTrue(pressure.update([0x59, 3, 1, 1]))
        XCTAssertNil(pressure.reading)
        XCTAssertEqual(pressure.measurementEnabled, false)
        for availability: UInt8 in [1, 2, 255] {
            XCTAssertTrue(pressure.update([0x5B, 3, 80, 0xFF]))
            XCTAssertTrue(pressure.update([0x57, 3, availability]))
            XCTAssertNil(pressure.reading)
            XCTAssertEqual(pressure.available, availability == 1 ? false : nil)
            XCTAssertEqual(pressure.measurementEnabled, false)
        }
        for mode: [UInt8] in [[0x59, 3, 0, 0], [0x59, 3, 2, 0], [0x59, 3, 2, 0], [0x59, 3, 0, 0xFF]] {
            XCTAssertTrue(pressure.update([0x5B, 3, 80, 0xFF]))
            XCTAssertTrue(pressure.update(mode))
            XCTAssertNil(pressure.reading)
        }
        XCTAssertEqual(pressure.measurementEnabled, true)
        XCTAssertNil(pressure.previewEnabled)
        XCTAssertNil(pressure.available)
    }

    func testStoppedRequiresBothRecordingAndPreviewToBeExplicitlyOff() {
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        XCTAssertFalse(pressure.isStopped)
        for recording: UInt8 in [0, 1, 0xFF] {
            for preview: UInt8 in [0, 1, 0xFF] {
                XCTAssertTrue(pressure.update([0x59, 3, recording, preview]))
                XCTAssertEqual(pressure.isStopped, recording == 1 && preview == 1,
                               "Recording \(recording), preview \(preview)")
            }
        }
    }

    func testMalformedPayloadsPreservePriorStateAndDoNotCrossParseReplyKinds() {
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        for payload in validPayloads { XCTAssertTrue(pressure.update(payload)) }
        let prior = pressure
        for payload in validPayloads {
            for count in 0..<payload.count {
                XCTAssertFalse(pressure.update(Array(payload.prefix(count))))
                XCTAssertEqual(pressure, prior)
            }
            XCTAssertFalse(pressure.update(payload + [0]))
            XCTAssertEqual(pressure, prior)
        }
        for payload: [UInt8] in [[0x57, 3, 0, 1], [0x59, 3, 0], [0x53, 3, 80, 0xFF],
                                 [0x55, 3, 80, 0xFF], [0x58, 3, 0, 1], [0x5A, 3], [0x5D, 3, 80, 0xFF]] {
            XCTAssertFalse(pressure.update(payload))
            XCTAssertEqual(pressure, prior)
        }
    }

    func testSourceInvalidationClearsOnlyReadingAndResetClearsAllObservations() {
        var pressure = SonySoundPressure(supportedFunctions: [0x53])
        for payload in validPayloads { XCTAssertTrue(pressure.update(payload)) }
        pressure.invalidateReading()
        XCTAssertNil(pressure.reading)
        XCTAssertTrue(pressure.isSupported)
        XCTAssertEqual(pressure.intervalSeconds, 5)
        XCTAssertEqual(pressure.available, true)
        XCTAssertEqual(pressure.measurementEnabled, true)
        pressure = SonySoundPressure(supportedFunctions: [0x53])
        XCTAssertTrue(pressure.isSupported)
        XCTAssertNil(pressure.minimumInterval)
        XCTAssertNil(pressure.intervalSeconds)
        XCTAssertNil(pressure.available)
        XCTAssertNil(pressure.measurementEnabled)
        XCTAssertNil(pressure.previewEnabled)
        XCTAssertNil(pressure.reading)
    }

    @MainActor
    func testControllerAcceptsOnlyAValidReplyAfterItsReadTransmits() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        XCTAssertNil(controller.soundPressure.reading)
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertNil(controller.soundPressure.reading)
        controller.defersSimulatedWrites = true
        controller.refreshSoundPressure()
        controller.defersSimulatedWrites = false
        XCTAssertTrue(controller.isReadingSoundPressure)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == levelQueryPayload })
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertNil(controller.soundPressure.reading)
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        deliver([0x5B, 3, 80, 0xFF], type: 0x0C, to: controller)
        for payload: [UInt8] in [[0x5B, 3, 80], [0x5B, 3, 80, 0xFF, 0], [0x5B, 2, 80, 0xFF], [0x5B, 3, 0xFF, 0xFF]] {
            deliver(payload, to: controller)
            XCTAssertNil(controller.soundPressure.reading)
            XCTAssertTrue(controller.isReadingSoundPressure)
        }
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertEqual(controller.soundPressure.reading, .decibels(80))
        XCTAssertFalse(controller.isReadingSoundPressure)
        deliver([0x5B, 3, 100, 0xFF], to: controller)
        XCTAssertEqual(controller.soundPressure.reading, .decibels(80))
    }

    @MainActor
    func testBusyQueueDoesNotRetainLevelReadsAfterViewAvailabilityOrModeChanges() {
        for change in 0..<3 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.refreshEqualizer()
            XCTAssertFalse(controller.canRefreshSoundPressure)
            controller.refreshSoundPressure(automatically: true)
            controller.refreshSoundPressure()
            XCTAssertFalse(controller.isReadingSoundPressure)
            controller.refreshDevices()
            switch change {
            case 0: controller.invalidateSoundPressureReading()
            case 1: deliver([0x57, 3, 1], to: controller)
            default: deliver([0x59, 3, 1, 1], to: controller)
            }
            acknowledgeSimulatedCommands(controller)
            let commands = controller.simulatedTransmittedFrames.filter { $0.type != 0x01 }
            XCTAssertFalse(commands.contains { $0.payload == levelQueryPayload })
            XCTAssertTrue(commands.contains { $0.type == 0x0E && $0.payload == [0x36, 2] })
            XCTAssertEqual(commands.map(\.sequence), commands.indices.map { UInt8($0 % 2) })
            XCTAssertNil(controller.simulatedPendingFrame)
            XCTAssertFalse(controller.isReadingSoundPressure)
            XCTAssertNil(controller.soundPressureReadError)
            XCTAssertTrue(controller.isReady)
            deliver([0x57, 3, 0], to: controller)
            deliver([0x59, 3, 0, 1], to: controller)
            controller.refreshSoundPressure()
            XCTAssertTrue(controller.isReadingSoundPressure)
            acknowledgeSimulatedCommands(controller)
            deliver([0x5B, 3, 80, 0xFF], to: controller)
            XCTAssertEqual(controller.soundPressure.reading, .decibels(80))
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        }
    }

    @MainActor
    func testControllerReadsPreviewRecordingAndUnknownModesWithoutStartingMeasurement() {
        let cases: [(mode: [UInt8], readable: Bool)] = [
            ([0x59, 3, 1, 0], true),
            ([0x59, 3, 0, 1], true),
            ([0x59, 3, 1, 1], false),
            ([0x59, 3, 0xFF, 0xFF], true),
            ([0x59, 3, 1, 0xFF], true),
        ]
        for testCase in cases {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            deliver(testCase.mode, to: controller)
            XCTAssertEqual(controller.soundPressure.available, true)
            XCTAssertEqual(controller.canRefreshSoundPressure, testCase.readable, "\(testCase.mode)")
            controller.refreshSoundPressure(automatically: true)
            controller.refreshSoundPressure()
            acknowledgeSimulatedCommands(controller)
            XCTAssertEqual(controller.isReadingSoundPressure, testCase.readable)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E }.map(\.payload),
                           testCase.readable ? [levelQueryPayload] : [])
            deliver([0x5B, 3, 80, 0xFF], to: controller)
            XCTAssertEqual(controller.soundPressure.reading, testCase.readable ? .decibels(80) : nil)
            XCTAssertFalse(controller.isReadingSoundPressure)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x58 })
        }
    }

    @MainActor
    func testControllerDiscardsOldReadsAfterAvailabilityModeSourceOrViewChanges() {
        for change in 0..<6 {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            defer { controller.simulateControlLoss() }
            controller.refreshSoundPressure()
            acknowledgeSimulatedCommands(controller)
            switch change {
            case 0:
                deliver([0x57, 3, 1], to: controller)
                XCTAssertFalse(controller.canRefreshSoundPressure)
                deliver([0x57, 3, 0], to: controller)
            case 1:
                deliver([0x59, 3, 1, 1], to: controller)
                deliver([0x59, 3, 0, 1], to: controller)
            case 2:
                deliver(sourceInventory(selected: 2), to: controller)
                acknowledgeSimulatedCommands(controller)
            case 3:
                controller.invalidateSoundPressureReading()
            case 4:
                deliver([0x59, 3, 0xFF, 0xFF], to: controller)
            default:
                deliver([0x59, 3, 1, 0], to: controller)
            }
            controller.refreshSoundPressure()
            deliver([0x5B, 3, 80, 0xFF], to: controller)
            XCTAssertNil(controller.soundPressure.reading, "Change \(change)")
            XCTAssertFalse(controller.isReadingSoundPressure)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        }
    }

    @MainActor
    func testRefreshRespectsAdvertisedMinimumIntervalAndDoesNotInventAutomaticCadence() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        deliver([0x51, 3, 1, 0, 0, 0, 0, 1, 16], to: controller)
        controller.refreshSoundPressure()
        acknowledgeSimulatedCommands(controller)
        for _ in 0..<3 { controller.refreshSoundPressure(automatically: true) }
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        controller.refreshSoundPressure()
        controller.refreshSoundPressure(automatically: true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        try await Task.sleep(for: .milliseconds(1_100))
        controller.refreshSoundPressure(automatically: true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 2)
        deliver([0x5B, 3, 81, 0xFF], to: controller)
        deliver([0x51, 3, 1, 0, 0, 0, 0, 0, 16], to: controller)
        controller.refreshSoundPressure(automatically: true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 2)
        XCTAssertFalse(controller.isReadingSoundPressure)
    }

    @MainActor
    func testTimedOutReadKeepsOwnershipUntilLateReplyAndNeverShowsThatLateMeasurement() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.refreshSoundPressure()
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(8_100))
        XCTAssertNotNil(controller.soundPressureReadError)
        XCTAssertFalse(controller.isReadingSoundPressure)
        XCTAssertFalse(controller.canRefreshSoundPressure)
        XCTAssertTrue(controller.isReady)
        controller.refreshSoundPressure()
        controller.refreshSoundPressure(automatically: true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertNil(controller.soundPressure.reading)
        XCTAssertNotNil(controller.soundPressureReadError)
        controller.refreshSoundPressure(automatically: true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        controller.refreshSoundPressure()
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 2)
        deliver([0x5B, 3, 82, 0xFF], to: controller)
        XCTAssertEqual(controller.soundPressure.reading, .decibels(82))
        XCTAssertNil(controller.soundPressureReadError)
    }

    @MainActor
    func testInvalidatedReadTimeoutKeepsOwnershipWithoutReportingAnObsoleteError() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.refreshSoundPressure()
        acknowledgeSimulatedCommands(controller)
        controller.invalidateSoundPressureReading()
        try await Task.sleep(for: .milliseconds(8_100))
        XCTAssertNil(controller.soundPressureReadError)
        XCTAssertNil(controller.soundPressure.reading)
        XCTAssertFalse(controller.isReadingSoundPressure)
        XCTAssertFalse(controller.canRefreshSoundPressure)
        controller.refreshSoundPressure()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 1)
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertNil(controller.soundPressure.reading)
        controller.refreshSoundPressure(automatically: true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 2)
        deliver([0x5B, 3, 82, 0xFF], to: controller)
        XCTAssertEqual(controller.soundPressure.reading, .decibels(82))
        XCTAssertNil(controller.soundPressureReadError)
    }

    @MainActor
    func testLevelAcknowledgmentFailureSuspendsAutomaticReadsAcrossReconnectUntilExplicitRefresh() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let other = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        other.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: "02:00:00:00:00:02")
        defer { controller.simulateControlLoss(); other.simulateControlLoss() }
        let session = controller.simulatedControlSession
        controller.refreshSoundPressure(automatically: true)
        other.refreshEqualizer()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, levelQueryPayload)
        XCTAssertFalse(controller.soundPressureAutomaticRefreshSuspended)
        let frame = try XCTUnwrap(controller.simulatedPendingFrame)
        let otherFrame = try XCTUnwrap(other.simulatedPendingFrame)
        controller.simulateAcknowledgmentTimeout()
        other.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(other.isReady)
        XCTAssertFalse(controller.soundPressureAutomaticRefreshSuspended)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame, frame)
        XCTAssertEqual(other.simulatedPendingFrame, otherFrame)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0 == frame }.count, 2)
        XCTAssertEqual(other.simulatedTransmittedFrames.filter { $0 == otherFrame }.count, 2)
        controller.simulateAcknowledgmentTimeout()
        other.simulateAcknowledgmentTimeout()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.linkState, .failed("Headphones did not acknowledge a command."))
        XCTAssertEqual(other.linkState, .failed("Headphones did not acknowledge a command."))
        XCTAssertTrue(controller.soundPressureAutomaticRefreshSuspended)
        XCTAssertFalse(other.soundPressureAutomaticRefreshSuspended)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        controller.refreshSoundPressure()
        XCTAssertTrue(controller.soundPressureAutomaticRefreshSuspended)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.soundPressureAutomaticRefreshSuspended)
        XCTAssertNil(controller.soundPressureReadError)
        for _ in 0..<3 { controller.refreshSoundPressure(automatically: true) }
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 2)
        controller.refreshSoundPressure()
        XCTAssertFalse(controller.soundPressureAutomaticRefreshSuspended)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 3)
        acknowledgeSimulatedCommands(controller)
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertEqual(controller.soundPressure.reading, .decibels(80))
        XCTAssertNil(controller.soundPressureReadError)
        deliver([0x51, 3, 1, 0, 0, 0, 0, 1, 16], to: controller)
        try await Task.sleep(for: .milliseconds(1_100))
        controller.refreshSoundPressure(automatically: true)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == levelQueryPayload }.count, 4)
        acknowledgeSimulatedCommands(controller)
    }

    @MainActor
    func testSameLinkHandshakeWaitsForOutstandingLevelReply() async {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.refreshSoundPressure()
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.setConnectionMode(.lowLatency)
        acknowledgeSimulatedCommands(controller)
        deliver([0xE9, 5, 2, 1], type: 0x0C, to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.connectionTransition?.phase, .reconnecting)
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.linkState, .handshaking)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0, 0])
        XCTAssertNil(controller.soundPressure.reading)
        XCTAssertFalse(controller.isReadingSoundPressure)
    }

    @MainActor
    func testExplicitMultipointRecoveryClosesLinkWithOutstandingLevelRead() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.refreshSoundPressure()
        acknowledgeSimulatedCommands(controller)
        controller.setMultipointEnabled(false)
        acknowledgeSimulatedCommands(controller)
        let session = controller.simulatedControlSession
        controller.simulateMultipointTimeout()
        XCTAssertEqual(controller.multipointTransition?.phase, .verifying)
        XCTAssertFalse(controller.canCheckMultipointChange)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xD6, 0xD2])
        acknowledgeSimulatedCommands(controller)
        deliver([0xD7, 0xD2, 0, 0], type: 0x0C, to: controller)
        XCTAssertEqual(controller.multipointTransition?.phase, .failed)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertTrue(controller.canCheckMultipointChange)
        controller.checkMultipointChange()
        XCTAssertEqual(controller.multipointTransition?.phase, .recovering)
        XCTAssertFalse(controller.isReady)
        XCTAssertGreaterThan(controller.simulatedControlSession, session)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(controller.isReadingSoundPressure)
        XCTAssertNil(controller.soundPressureReadError)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xD8 }.count, 1)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func sourceInventory(selected: UInt8) -> [UInt8] {
        let entries: [UInt8] = [("02:00:00:00:00:01", UInt8(1), "MacBook Pro"), ("02:00:00:00:00:02", UInt8(2), "Phone")]
            .flatMap { address, id, title in Array(address.utf8) + [id, 0x2A, 0x41, 4, UInt8(title.utf8.count)] + Array(title.utf8) }
        return [0x39, 2, 2] + entries + [selected]
    }

    private var validPayloads: [[UInt8]] {
        [[0x51, 3, 1, 0, 0, 0, 0, 5, 0x10], [0x57, 3, 0], [0x59, 3, 0, 1], [0x5B, 3, 80, 0xFF]]
    }
}
