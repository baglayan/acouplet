import XCTest
@testable import Acouplet

final class SonySpeakerPowerControllerTests: XCTestCase {
    private let settings: [(setting: SonyHeadphonesController.Setting, type: UInt8, inquiry: UInt8)] = [
        (.powerSavingMode, 0x0C, 0x06), (.bluetoothStandby, 0x0C, 0x0D), (.autoStandby, 0x0E, 0x00),
    ]

    @MainActor
    func testAuracastScansJoinsAndLeavesThroughSpeakerReports() {
        let unsupported = makeController(functions: [0x76, 0x77], functions2: [])
        defer { unsupported.simulateControlLoss() }
        deliver([0x75, 6, 0, 0], type: 0x0E, to: unsupported)
        XCTAssertNil(unsupported.auracast.variant)
        XCTAssertFalse(unsupported.canSetAuracast)

        let controller = makeController(functions: [], functions2: [0x76, 0x77])
        defer { controller.simulateControlLoss() }
        let queries: [[UInt8]] = [[0x72, 6], [0x76, 6], [0x72, 9]]
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && queries.contains($0.payload) }.map(\.payload),
                       [[0x72, 6], [0x76, 6]])
        XCTAssertFalse(controller.canSetAuracast)
        deliver([0x73, 6, 0, 0], to: controller)
        XCTAssertFalse(controller.canSetAuracast)
        deliver([0x73, 6, 0, 0], type: 0x0E, to: controller)
        XCTAssertTrue(controller.canSetAuracast)

        controller.setAuracastScan(start: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 7, 0])
        acknowledgeAll(controller)
        deliver([0x79, 7, 0], type: 0x0E, to: controller)
        XCTAssertNil(controller.pendingChanges[.auracastScan])
        XCTAssertEqual(controller.auracast.scan, .scanning)
        controller.setAuracastScan(start: false)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 7, 1])
        acknowledgeAll(controller)
        deliver([0x79, 7, 1], type: 0x0E, to: controller)

        let id = (1...15).map(UInt8.init)
        let station: [UInt8] = id + [0, 4] + Array("Jazz".utf8) + [4] + Array("Live".utf8)
        deliver([0x7D, 7] + station, type: 0x0E, to: controller)
        XCTAssertEqual(controller.auracast.broadcasts.map(\.name), ["Jazz"])
        XCTAssertEqual(controller.auracast.broadcasts.map(\.program), ["Live"])
        controller.setAuracastReception(.start, broadcastID: id)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 8, 0] + id + [0])
        acknowledgeAll(controller)
        deliver([0x77, 6, 1] + station, type: 0x0E, to: controller)
        XCTAssertNil(controller.auracast.current)
        acknowledgeAll(controller)
        deliver([0x79, 8, 1] + id, type: 0x0E, to: controller)
        XCTAssertEqual(controller.auracast.broadcasts.first?.protection, .password)
        XCTAssertNotNil(controller.settingErrors[.auracastReception])
        XCTAssertNil(controller.pendingChanges[.auracastReception])
        controller.setAuracastReception(.start, broadcastID: id, password: "123")
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setAuracastReception(.start, broadcastID: id, password: "1234")
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 8, 0] + id + [4] + Array("1234".utf8))
        XCTAssertEqual(controller.pendingChanges[.auracastReception], [0] + id)
        acknowledgeAll(controller)
        deliver([0x79, 8, 0] + id, type: 0x0E, to: controller)
        XCTAssertNil(controller.auracast.current)
        XCTAssertNotNil(controller.pendingChanges[.auracastReception])
        deliver([0x79, 6, 1] + station, type: 0x0E, to: controller)
        XCTAssertNil(controller.pendingChanges[.auracastReception])
        XCTAssertEqual(controller.auracast.current?.id, id)
        controller.setAuracastReception(.stop, broadcastID: id)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 8, 1] + id + [0])
        acknowledgeAll(controller)
        deliver([0x79, 6, 0] + station, type: 0x0E, to: controller)
        XCTAssertNil(controller.auracast.current)
        XCTAssertEqual(controller.auracast.receiving, false)
        XCTAssertNil(controller.pendingChanges[.auracastReception])
    }

    @MainActor
    func testAuracastClassicOnlyRestrictionUsesReportedPreferenceAndRevalidatesQueue() {
        let controller = makeController(functions: [0x42], functions2: [0x77])
        defer { controller.simulateControlLoss() }
        let queries: [[UInt8]] = [[0x72, 6], [0x76, 6], [0x72, 9]]
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && queries.contains($0.payload) }.map(\.payload),
                       [[0x72, 9]])
        deliver([0x43, 0x0C, 0], to: controller)
        deliver([0x73, 9, 0, 0], type: 0x0E, to: controller)
        XCTAssertFalse(controller.canSetAuracast)
        deliver([0x47, 0x0C, 1], to: controller)
        XCTAssertFalse(controller.canSetAuracast)
        deliver([0x49, 0x0C, 0], to: controller)
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertTrue(controller.canSetAuracast)

        controller.refresh()
        XCTAssertNotNil(controller.simulatedPendingFrame)
        controller.setAuracastScan(start: true)
        XCTAssertNotNil(controller.pendingChanges[.auracastScan])
        deliver([0x49, 0x0C, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.canSetAuracast)
        XCTAssertNil(controller.pendingChanges[.auracastScan])
        XCTAssertNotNil(controller.settingErrors[.auracastScan])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x78, 7, 0] })
        deliver([0x49, 0x0C, 0], to: controller)
        deliver([0x75, 6, 1, 2], type: 0x0E, to: controller)
        XCTAssertEqual(controller.auracast.restriction, .partyChain)
        XCTAssertFalse(controller.canSetAuracast)
    }

    @MainActor
    func testSoundFieldOptimizationUsesTable1AndWaitsForConfirmedState() {
        let queries = SonySoundFieldOptimization.queryPayloads
        let unsupported = makeController(functions: [0x84, 0xEC], functions2: [0x83])
        defer { unsupported.simulateControlLoss() }
        XCTAssertNil(unsupported.audioFeatures.soundFieldOptimization)
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { queries.contains($0.payload) })

        let controller = makeController(functions: [0x83], functions2: [])
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.canSetSoundFieldOptimization)
        XCTAssertNil(controller.audioFeatures.soundFieldOptimization?.enabled)
        deliver([0x83, 0x30, 0, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.canSetSoundFieldOptimization)
        deliver([0x87, 0x30, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { queries.contains($0.payload) }.map(\.payload), queries)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x80, 0x30] })
        XCTAssertTrue(controller.canSetSoundFieldOptimization)
        controller.setSoundFieldOptimization(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x88, 0x30, 0])
        acknowledgeAll(controller)
        deliver([0x89, 0x30, 0], type: 0x0E, to: controller)
        deliver([0x89, 0x30, 0, 0], to: controller)
        deliver([0x89, 0x30, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.soundFieldOptimization])
        XCTAssertEqual(controller.audioFeatures.soundFieldOptimization?.enabled, false)
        deliver([0x89, 0x30, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.soundFieldOptimization])
        XCTAssertEqual(controller.audioFeatures.soundFieldOptimization?.enabled, true)
        controller.setSoundFieldOptimization(false)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x88, 0x30, 1])
    }

    @MainActor
    func testSoundFieldOptimizationRevalidatesQueuedChangeUsingSpeakerStatus() {
        let controller = makeController(functions: [0x26, 0x83, 0x84], functions2: [])
        defer { controller.simulateControlLoss() }
        for report in [[UInt8(0x83), 0x30, 0, 0], [0x87, 0x30, 1],
                       [0x81, 0x31, 1, 2], [0x83, 0x31, 0, 0], [0x87, 0x31, 1, 2],
                       [0x23, 0x06, 0], [0x27, 0x06, 1]] {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertTrue(controller.canSetSoundFieldOptimization)
        XCTAssertTrue(controller.canSetTVSoundBooster)
        controller.setPowerSavingMode(true)
        controller.setSoundFieldOptimization(true)
        XCTAssertNotNil(controller.pendingChanges[.soundFieldOptimization])
        deliver([0x85, 0x30, 1, 5], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.audioFeatures.soundFieldOptimization?.exclusion, .tvSoundBooster)
        XCTAssertFalse(controller.canSetSoundFieldOptimization)
        XCTAssertNotNil(controller.settingErrors[.soundFieldOptimization])
        XCTAssertNil(controller.pendingChanges[.soundFieldOptimization])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x88, 0x30, 0] })
        XCTAssertTrue(controller.canSetTVSoundBooster)
        deliver([0x85, 0x30, 0, 0], to: controller)
        XCTAssertTrue(controller.canSetSoundFieldOptimization)
        controller.setSoundFieldOptimization(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x88, 0x30, 0])
    }

    @MainActor
    func testListeningModeUsesReportedStateAndDispatchesBothCinemaVariants() {
        let unsupported = makeController(functions: [0xE5], functions2: [0xE6, 0xEA])
        defer { unsupported.simulateControlLoss() }
        XCTAssertNil(unsupported.audioFeatures.listeningMode)
        XCTAssertNil(unsupported.audioFeatures.listeningModeAssignments)
        XCTAssertFalse(unsupported.canSetListeningMode(.cinema))
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { SonyListeningModeAssignments.queryPayloads.contains($0.payload) })

        let controller = makeController(functions: [0xE5, 0xE6, 0xEC], functions2: [])
        defer { controller.simulateControlLoss() }
        let reports: [[UInt8]] = [[0xE1, 4, 0], [0xE3, 4, 0], [0xE7, 4, 1],
                                  [0xE1, 10, 3, 1, 2, 3, 0], [0xE3, 10, 0, 0]]
        for report in reports {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertNil(controller.audioFeatures.listeningMode)
        XCTAssertFalse(controller.canSetListeningMode(.cinema))
        deliver([0xE7, 10, 0], to: controller)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .standard)
        XCTAssertEqual(controller.audioFeatures.listeningModeOptions, [.standard, .cinema, .game, .music])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { SonyListeningModeAssignments.queryPayloads.contains($0.payload) })

        controller.setListeningMode(.cinema)
        XCTAssertTrue(controller.isChangingListeningMode)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .standard)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 4, 0])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.map(\.payload), [[0xE8, 4, 0], [0xE8, 10, 1]])
        deliver([0xE9, 10, 1], to: controller)
        XCTAssertTrue(controller.isChangingListeningMode)
        XCTAssertFalse(controller.canSetListeningMode(.standard))
        deliver([0xE9, 4, 0], to: controller)
        XCTAssertFalse(controller.isChangingListeningMode)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .cinema)

        controller.setListeningMode(.standard)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.suffix(2).map(\.payload), [[0xE8, 4, 1], [0xE8, 10, 0]])
        deliver([0xE9, 4, 1], to: controller)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .cinema)
        deliver([0xE9, 10, 0], to: controller)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .standard)
    }

    @MainActor
    func testListeningModeStandardDisablesTheDominantReportedMode() {
        let controller = makeController(functions: [0xE4, 0xE6, 0xE8, 0xE9], functions2: [])
        defer { controller.simulateControlLoss() }
        for report in [[UInt8(0xE1), 7, 0], [0xE3, 7, 0], [0xE7, 7, 0],
                       [0xE1, 6, 0], [0xE3, 6, 0], [0xE7, 6, 0],
                       [0xE1, 3, 0], [0xE3, 3, 0], [0xE7, 3, 0, 2]] {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.audioFeatures.listeningMode, .backgroundMusic)
        controller.setListeningMode(.standard)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 3, 1, 2])
        acknowledgeAll(controller)
        deliver([0xE9, 3, 1, 2], to: controller)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .voiceContents)
        controller.setListeningMode(.standard)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 6, 1])
        acknowledgeAll(controller)
        deliver([0xE9, 6, 1], to: controller)
        XCTAssertEqual(controller.audioFeatures.listeningMode, .soundLeakageReduction)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0xE8 }.map(\.payload), [[0xE8, 3, 1, 2], [0xE8, 6, 1]])
    }

    @MainActor
    func testListeningModeButtonHonorsMandatoryAndReportedOrderAndConfirmsNotification() {
        let controller = makeController(functions: [0xEA], functions2: [])
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.audioFeatures.supportsListeningMode)
        for report in [[UInt8(0xE1), 8, 1, 4, 0, 0, 1, 1, 2, 1, 4, 1], [0xE7, 8, 3, 4, 0, 1], [0xE3, 8, 0, 0]] {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.simulatedTransmittedFrames.map(\.payload).filter {
            SonyListeningModeAssignments.queryPayloads.contains($0)
        }, SonyListeningModeAssignments.queryPayloads)
        XCTAssertEqual(controller.audioFeatures.listeningModeAssignments?.selection, [.music, .standard, .backgroundMusic])
        XCTAssertFalse(controller.canToggleListeningModeAssignment(.standard))
        XCTAssertFalse(controller.canToggleListeningModeAssignment(.game))
        controller.toggleListeningModeAssignment(.standard)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.toggleListeningModeAssignment(.cinema)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 8, 4, 4, 0, 1, 2])
        XCTAssertFalse(controller.canToggleListeningModeAssignment(.music))
        acknowledgeAll(controller)
        deliver([0xE9, 8, 4, 4, 0, 1, 2], type: 0x0E, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.listeningModeAssignments])
        deliver([0xE9, 8, 4, 4, 0, 1, 2], to: controller)
        XCTAssertNil(controller.pendingChanges[.listeningModeAssignments])
        XCTAssertEqual(controller.audioFeatures.listeningModeAssignments?.selection, [.music, .standard, .backgroundMusic, .cinema])
        controller.toggleListeningModeAssignment(.backgroundMusic)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 8, 3, 4, 0, 2])
    }

    @MainActor
    func testListeningModeButtonCancelsQueuedEditsWhenAvailabilityOrAssignmentsChange() {
        for notification in [[UInt8(0xE5), 8, 1, 0], [0xE5, 8, 0, 1], [0xE9, 8, 2, 0, 3]] {
            let controller = makeController(functions: [0x26, 0xEA], functions2: [])
            defer { controller.simulateControlLoss() }
            for report in [[UInt8(0x23), 6, 0], [0x27, 6, 1],
                           [0xE1, 8, 1, 3, 0, 0, 1, 1, 3, 1], [0xE7, 8, 1, 0], [0xE3, 8, 0, 0]] {
                deliver(report, to: controller)
                acknowledgeAll(controller)
            }
            XCTAssertTrue(controller.canToggleListeningModeAssignment(.backgroundMusic))
            controller.setPowerSavingMode(true)
            controller.toggleListeningModeAssignment(.backgroundMusic)
            XCTAssertNotNil(controller.pendingChanges[.listeningModeAssignments])
            deliver(notification, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE8, 8, 2, 0, 1] })
            XCTAssertNil(controller.pendingChanges[.listeningModeAssignments])
            XCTAssertNotNil(controller.settingErrors[.listeningModeAssignments])
        }
    }

    @MainActor
    func testBackgroundMusicPreservesTheOnOffAndRoomPair() {
        let unsupported = makeController(functions: [], functions2: [0xE4, 0xEB])
        defer { unsupported.simulateControlLoss() }
        XCTAssertNil(unsupported.audioFeatures.backgroundMusic)

        let controller = makeController(functions: [0xE4], functions2: [])
        defer { controller.simulateControlLoss() }
        let reports: [[UInt8]] = [[0xE1, 3, 2, 0, 1], [0xE3, 3, 0], [0xE7, 3, 1, 1]]
        for report in reports {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.audioFeatures.backgroundMusic?.inquiry, 3)
        XCTAssertEqual(controller.audioFeatures.backgroundMusic?.exclusions, [0, 1])
        XCTAssertTrue(controller.canSetBackgroundMusic)
        controller.setBackgroundMusicRoom(.large)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 3, 1, 2])
        acknowledgeAll(controller)
        deliver([0xE9, 3, 0, 2], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.backgroundMusic])
        deliver([0xE9, 3, 1, 2], to: controller)
        XCTAssertNil(controller.pendingChanges[.backgroundMusic])
        controller.setBackgroundMusic(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 3, 0, 2])
        acknowledgeAll(controller)
        deliver([0xE9, 3, 0, 2], to: controller)
        XCTAssertEqual(controller.audioFeatures.backgroundMusic?.enabled, true)
    }

    @MainActor
    func testBackgroundMusicUsesEnhancedReasonsAndRechecksLEAudioBeforeWriting() {
        let controller = makeController(functions: [0x26, 0x45, 0xE4, 0xEB], functions2: [])
        defer { controller.simulateControlLoss() }
        XCTAssertEqual(controller.audioFeatures.backgroundMusic?.inquiry, 9)
        deliver([0x23, 0x06, 0], to: controller)
        deliver([0x27, 0x06, 1], to: controller)
        let reports: [[UInt8]] = [[0xE1, 9, 0], [0xE3, 9, 1, 4, 0, 2, 6, 0xFE], [0xE7, 9, 1, 1]]
        for report in reports {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.audioFeatures.backgroundMusic?.reasons, [.calling, .leAudioConnected, .sonyAssistant, .other])
        XCTAssertFalse(controller.canSetBackgroundMusic)
        deliver([0xE5, 3, 0], to: controller)
        XCTAssertFalse(controller.canSetBackgroundMusic)
        deliver([0xE5, 9, 0, 0], to: controller)
        XCTAssertTrue(controller.canSetBackgroundMusic)
        controller.setPowerSavingMode(true)
        controller.setBackgroundMusic(true)
        XCTAssertNotNil(controller.pendingChanges[.backgroundMusic])
        deliver([0x45, 0xF5, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.backgroundMusicConnectionRestriction)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE8, 9, 0, 1] })
        XCTAssertNil(controller.pendingChanges[.backgroundMusic])
        XCTAssertNotNil(controller.settingErrors[.backgroundMusic])
        deliver([0x45, 0xF5, 1], to: controller)
        XCTAssertTrue(controller.canSetBackgroundMusic)
        controller.setBackgroundMusic(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 9, 0, 1])
    }

    @MainActor
    func testCinemaUpmixUsesOnlyAdvertisedTable1Controls() {
        let unsupported = makeController(functions: [], functions2: [0xE5, 0xEC])
        defer { unsupported.simulateControlLoss() }
        XCTAssertTrue(unsupported.audioFeatures.upmix.isEmpty)
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains { $0.payload == [0xE0, 4] || $0.payload == [0xE0, 10] })

        let controller = makeController(functions: [0xE5], functions2: [])
        defer { controller.simulateControlLoss() }
        deliver([0xE1, 4, 1, 0], to: controller)
        acknowledgeAll(controller)
        deliver([0xE3, 4, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0xE7, 4, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.audioFeatures.upmix[.cinema]?.selection, .standard)
        XCTAssertEqual(controller.audioFeatures.upmix[.cinema]?.exclusions, [0])
        XCTAssertFalse(controller.canSetUpmix(.cinema, mode: .cinema))
        deliver([0xE5, 4, 0], to: controller)
        XCTAssertTrue(controller.canSetUpmix(.cinema, mode: .cinema))
        controller.setUpmix(.cinema, mode: .cinema)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 4, 0])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.audioFeatures.upmix[.cinema]?.selection, .standard)
        deliver([0xE9, 4, 0], type: 0x0E, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.upmix(.cinema)])
        deliver([0xE9, 4, 0], to: controller)
        XCTAssertEqual(controller.audioFeatures.upmix[.cinema]?.selection, .cinema)
        XCTAssertNil(controller.pendingChanges[.upmix(.cinema)])
        controller.setUpmix(.cinema, mode: .standard)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 4, 1])
    }

    @MainActor
    func testSeriesUpmixUsesAdvertisedModesAndIndependentStatus() {
        let controller = makeController(functions: [0xE5, 0xEC], functions2: [])
        defer { controller.simulateControlLoss() }
        let reports: [[UInt8]] = [[0xE1, 4, 0], [0xE3, 4, 0], [0xE7, 4, 1],
                                  [0xE1, 10, 2, 2, 3, 2, 0, 1], [0xE3, 10, 0, 1], [0xE7, 10, 0]]
        for report in reports {
            deliver(report, to: controller)
            acknowledgeAll(controller)
        }
        XCTAssertEqual(controller.audioFeatures.upmix[.series]?.selectableModes, [.standard, .game, .music])
        XCTAssertEqual(controller.audioFeatures.upmix[.series]?.preferredEffect, .bravia3DSurround)
        controller.setUpmix(.series, mode: .cinema)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.setUpmix(.series, mode: .game)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xE8, 10, 2])
        acknowledgeAll(controller)
        deliver([0xE9, 10, 2], to: controller)
        XCTAssertNil(controller.pendingChanges[.upmix(.series)])
        XCTAssertEqual(controller.audioFeatures.upmix[.series]?.selection, .game)
        XCTAssertEqual(controller.audioFeatures.upmix[.cinema]?.selection, .standard)
        controller.setUpmix(.cinema, mode: .cinema)
        controller.setUpmix(.series, mode: .music)
        deliver([0xE5, 10, 1, 0], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xE8, 10, 3] })
        XCTAssertNil(controller.pendingChanges[.upmix(.series)])
        XCTAssertNotNil(controller.settingErrors[.upmix(.series)])
        XCTAssertEqual(controller.audioFeatures.upmix[.series]?.preferredEffect, .upmix)
        XCTAssertTrue(controller.audioFeatures.upmix[.cinema]?.available == true)
    }

    @MainActor
    func testTVSoundBoosterReadsOnlyTable1AndConfirmsBothValues() {
        let unsupported = makeController(functions: [], functions2: [0x84])
        defer { unsupported.simulateControlLoss() }
        XCTAssertNil(unsupported.audioFeatures.tvSoundBooster)
        XCTAssertFalse(unsupported.simulatedTransmittedFrames.contains {
            SonyTVSoundBooster.queryPayloads.contains($0.payload)
        })

        let controller = makeController(functions: [0x84], functions2: [])
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.canSetTVSoundBooster)
        for query in SonyTVSoundBooster.queryPayloads {
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && $0.payload == query })
        }
        deliver([0x81, 0x31, 3, 1, 2, 3], to: controller)
        deliver([0x83, 0x31, 0, 0], type: 0x0E, to: controller)
        XCTAssertNil(controller.audioFeatures.tvSoundBooster?.available)
        deliver([0x83, 0x31, 0, 0], to: controller)
        deliver([0x87, 0x31, 1, 4], to: controller)
        XCTAssertEqual(controller.audioFeatures.tvSoundBooster?.exclusions, [.soundEffect, .soundFieldOptimization, .stamina])
        XCTAssertTrue(controller.canSetTVSoundBooster)
        XCTAssertFalse(controller.canSetTVSoundBoosterDelay)
        controller.setTVSoundBooster(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x88, 0x31, 0, 4])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.audioFeatures.tvSoundBooster?.enabled, false)
        deliver([0x89, 0x31, 0, 3], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.tvSoundBooster])
        deliver([0x89, 0x31, 0, 4], to: controller)
        XCTAssertNil(controller.pendingChanges[.tvSoundBooster])
        XCTAssertTrue(controller.canSetTVSoundBoosterDelay)
        controller.setTVSoundBoosterDelay(5)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x88, 0x31, 0, 5])
        acknowledgeAll(controller)
        deliver([0x89, 0x31, 0, 5], to: controller)
        XCTAssertEqual(controller.audioFeatures.tvSoundBooster?.delay, 5)
        XCTAssertNil(controller.pendingChanges[.tvSoundBooster])
        deliver([0x85, 0x31, 0, 1], to: controller)
        XCTAssertTrue(controller.canSetTVSoundBooster)
        XCTAssertFalse(controller.canSetTVSoundBoosterDelay)
        deliver([0x85, 0x31, 1, 0], to: controller)
        XCTAssertFalse(controller.canSetTVSoundBooster)
        XCTAssertFalse(controller.canSetTVSoundBoosterDelay)
    }

    @MainActor
    func testQueuedTVSoundBoosterEditPreservesLatestState() {
        let controller = makeController(functions: [0x26, 0x84], functions2: [])
        defer { controller.simulateControlLoss() }
        deliver([0x23, 0x06, 0], to: controller)
        deliver([0x27, 0x06, 1], to: controller)
        deliver([0x81, 0x31, 0], to: controller)
        deliver([0x83, 0x31, 0, 0], to: controller)
        deliver([0x87, 0x31, 0, 1], to: controller)
        controller.setPowerSavingMode(true)
        controller.setTVSoundBoosterDelay(5)
        XCTAssertNotNil(controller.pendingChanges[.tvSoundBooster])
        deliver([0x89, 0x31, 1, 2], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0x88, 0x31, 0, 5] })
        XCTAssertNil(controller.pendingChanges[.tvSoundBooster])
        XCTAssertNotNil(controller.settingErrors[.tvSoundBooster])
        XCTAssertEqual(controller.audioFeatures.tvSoundBooster?.enabled, false)
        XCTAssertEqual(controller.audioFeatures.tvSoundBooster?.delay, 2)
    }

    @MainActor
    func testKaraokeUsesAdvertisedInquiryAndConfirmsChangesFromTheSpeaker() {
        XCTAssertEqual(SonyKaraoke(supportedFunctions2: [0x72, 0x74]).inquiry, 2)
        XCTAssertTrue(SonyKaraoke(supportedFunctions2: [0x75]).queryPayloads.isEmpty)
        for (function, inquiry): (UInt8, UInt8) in [(0x72, 2), (0x74, 4)] {
            let controller = makeController(functions: [], functions2: [function])
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.karaoke.queryPayloads, [[0x70, inquiry], [0x72, inquiry], [0x76, inquiry]])
            for query in controller.karaoke.queryPayloads {
                XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == query })
            }
            deliver([0x71, inquiry, 8, 1, 0, 2, 3, 4, 5, 6, 7, 2, 0, 3], type: 0x0E, to: controller)
            deliver([0x73, inquiry, 0, 0, 0] + (inquiry == 4 ? [0] : []), type: 0x0E, to: controller)
            deliver([0x77, inquiry, 6, 254, 2, 0, 2, 6, 4, 255], type: 0x0E, to: controller)
            XCTAssertEqual(controller.karaoke.value(.key), -2)
            controller.setKaraokeControls([.key: -6, .echo: 3])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, inquiry, 6, 250, 3, 0, 2, 6, 4])
            acknowledgeAll(controller)
            XCTAssertEqual(controller.karaoke.value(.key), -2)
            XCTAssertNotNil(controller.pendingChanges[.speakerKaraoke(.controls)])
            deliver([0x79, inquiry, 6, 250, 3, 0, 2, 6, 4, 255], type: 0x0E, to: controller)
            XCTAssertEqual(controller.karaoke.value(.key), -6)
            XCTAssertEqual(controller.karaoke.value(.treble), 4)
            XCTAssertNil(controller.pendingChanges[.speakerKaraoke(.controls)])
        }
    }

    @MainActor
    func testEnhancedKaraokeReportsRestrictionsScoresAndLiveMode() {
        let controller = makeController(functions: [], functions2: [0x74, 0x75])
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x76, 5] })
        deliver([0x71, 4, 4, 0, 2, 4, 5, 1, 3], type: 0x0E, to: controller)
        deliver([0x73, 4, 2, 0, 0, 0], type: 0x0E, to: controller)
        deliver([0x77, 4, 2, 1, 1, 255], type: 0x0E, to: controller)
        deliver([0x77, 5, 1], type: 0x0E, to: controller)
        XCTAssertFalse(controller.karaoke.canAdjust(.vocal))
        XCTAssertTrue(controller.karaoke.canAdjust(.echo))
        XCTAssertFalse(controller.canPlayKaraokeSample(.clap))
        controller.playKaraokeSample(.comeOn)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x7C, 4, 3])
        acknowledgeAll(controller)
        controller.setKaraokeScoring(.started)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x74, 4, 1])
        acknowledgeAll(controller)
        deliver([0x75, 4, 2, 0, 1, 0], type: 0x0E, to: controller)
        controller.setKaraokeScoring(.waiting)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x74, 4, 2])
        acknowledgeAll(controller)
        deliver([0x75, 4, 2, 0, 2, 0], type: 0x0E, to: controller)
        deliver([0x79, 4, 2, 1, 1, 86], type: 0x0E, to: controller)
        XCTAssertEqual(controller.karaoke.score, 86)
        XCTAssertEqual(controller.karaoke.scoring, .waiting)
        controller.setLiveKaraoke(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 5, 0])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.karaoke.liveEnabled, false)
        deliver([0x79, 5, 0], type: 0x0E, to: controller)
        XCTAssertEqual(controller.karaoke.liveEnabled, true)
        deliver([0x75, 4, 1, 1, 0, 2, 0, 2], type: 0x0E, to: controller)
        XCTAssertEqual(controller.karaoke.disableReasons, [.tvSoundBooster, .speaking])
        XCTAssertFalse(controller.canPlayKaraokeSample(.comeOn))
        controller.setKaraokeControls([.echo: 3])
        controller.setLiveKaraoke(false)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testQueuedKaraokeCommandsRecheckSpeakerState() {
        let controller = makeController(functions: [], functions2: [0x74, 0x75])
        defer { controller.simulateControlLoss() }
        deliver([0x71, 4, 3, 0, 1, 4, 1, 0], type: 0x0E, to: controller)
        deliver([0x73, 4, 0, 0, 0, 0], type: 0x0E, to: controller)
        deliver([0x77, 4, 2, 1, 0, 255], type: 0x0E, to: controller)
        deliver([0x77, 5, 1], type: 0x0E, to: controller)
        controller.setLiveKaraoke(true)
        controller.setKaraokeControls([.echo: 3])
        controller.playKaraokeSample(.clap)
        deliver([0x79, 4, 2, 1, 2, 255], type: 0x0E, to: controller)
        deliver([0x75, 4, 1, 1, 0, 1, 2], type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains {
            $0.type == 0x0E && ($0.payload.starts(with: [0x78, 4]) || $0.payload == [0x7C, 4, 0])
        })
        XCTAssertEqual(controller.karaoke.value(.key), 2)
        XCTAssertNil(controller.pendingChanges[.speakerKaraoke(.controls)])
        XCTAssertNotNil(controller.settingErrors[.speakerKaraoke(.controls)])
    }

    @MainActor
    func testDJControlUsesAdvertisedInquiryAndPreservesBandsWhenSelectingEffects() {
        XCTAssertEqual(SonyDJControl(supportedFunctions2: [0x70, 0x73]).inquiry, 0)
        for (function, inquiry): (UInt8, UInt8) in [(0x70, 0), (0x73, 3)] {
            let controller = makeController(functions: [], functions2: [function])
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.djControl.inquiry, inquiry)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter {
                $0.type == 0x0E && $0.payload.count == 2 && [0x70, 0x72, 0x76].contains($0.payload[0])
            }.map(\.payload), [[0x70, inquiry], [0x72, inquiry], [0x76, inquiry]])
            deliver([0x71, inquiry, 3, 1, 2, 11, 2, 12], type: 0x0E, to: controller)
            deliver([0x73, inquiry, 1, 1] + (inquiry == 3 ? [0] : []), type: 0x0E, to: controller)
            deliver([0x77, inquiry, 1, 2, 4, 7], type: 0x0E, to: controller)
            controller.setDJEffect(.flanger)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, inquiry, 2, 2, 4, 7])
            acknowledgeAll(controller)
            XCTAssertEqual(controller.djControl.effect, .isolator)
            XCTAssertNotNil(controller.pendingChanges[.speakerDJ])
            deliver([0x79, inquiry, 2, 2, 4, 7], type: 0x0E, to: controller)
            XCTAssertEqual(controller.djControl.effect, .flanger)
            XCTAssertNil(controller.pendingChanges[.speakerDJ])
            controller.setDJEffect(.customEQ, bands: [0, 12])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, inquiry, 11, 2, 0, 12])
            acknowledgeAll(controller)
            deliver([0x79, inquiry, 11, 2, 0, 12], type: 0x0E, to: controller)
            XCTAssertEqual(controller.djControl.bands, [0, 12])
            XCTAssertNil(controller.pendingChanges[.speakerDJ])
            deliver([0x75, inquiry, 0, 1] + (inquiry == 3 ? [0] : []), type: 0x0E, to: controller)
            controller.setDJEffect(.customEQ, bands: [12, 0])
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, inquiry, 11, 2, 12, 0])
            acknowledgeAll(controller)
        }
    }

    @MainActor
    func testDJDragAndSamplerUseSignedCoordinatesAndPreserveFinalStop() {
        let controller = makeController(functions: [], functions2: [0x73])
        defer { controller.simulateControlLoss() }
        deliver([0x71, 3, 2, 1, 15, 1, 12], type: 0x0E, to: controller)
        deliver([0x73, 3, 1, 1, 0], type: 0x0E, to: controller)
        deliver([0x77, 3, 1, 1, 4], type: 0x0E, to: controller)
        controller.updateDJControlDrag(x: -100, y: 100)
        acknowledgeAll(controller)
        controller.updateDJControlDrag(x: -20, y: 20)
        controller.updateDJControlDrag(x: 20, y: -20)
        controller.simulatePartyLightingTick()
        controller.updateDJControlDrag(x: 60, y: -60)
        controller.finishDJControlDrag()
        acknowledgeAll(controller)
        deliver([0x79, 3, 15, 1, 4], type: 0x0E, to: controller)
        controller.playDJControlSample(6)
        acknowledgeAll(controller)
        controller.finishDJControlDrag()
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x7C }.map(\.payload), [
            [0x7C, 3, 0, 156, 100], [0x7C, 3, 2, 20, 236], [0x7C, 3, 1, 60, 196],
            [0x7C, 3, 0, 186, 70], [0x7C, 3, 1, 186, 70],
        ])
        deliver([0x75, 3, 0, 1, 1, 2], type: 0x0E, to: controller)
        XCTAssertEqual(controller.djControl.disableReasons, [.speaking])
        controller.playDJControlSample(0)
        controller.setDJEffect(.isolator)
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testLightingReadsOnlyUseAdvertisedTableAndSetNeedsDeviceState() {
        let capabilities: [UInt8] = [0x71, 0xFC, 0xFE]
        let queries = SonySpeakerLighting(supportedFunctions2: Set(capabilities)).queryPayloads
        for table2 in [false, true] {
            let controller = makeController(functions: table2 ? [] : capabilities, functions2: table2 ? capabilities : [])
            defer { controller.simulateControlLoss() }
            XCTAssertEqual(controller.speakerLighting.isSupported, table2)
            for query in queries {
                XCTAssertEqual(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == query }, table2)
            }
            deliver([0xF7, 0x0E, 0], to: controller)
            XCTAssertNil(controller.speakerLighting.mode)
            controller.setSpeakerLighting(.mode, value: [7])
            XCTAssertNil(controller.pendingChanges[.speakerLighting(.mode)])
        }
    }

    @MainActor
    func testLightingSetsWaitForDeviceAndIgnorePreChangeReads() {
        let controller = makeController(functions: [], functions2: [0xFC, 0xFE])
        defer { controller.simulateControlLoss() }
        deliver([0xF1, 0x0E, 2, 0, 7, 0], type: 0x0E, to: controller)
        deliver([0xF3, 0x0E, 0], type: 0x0E, to: controller)
        deliver([0xF7, 0x0E, 0], type: 0x0E, to: controller)
        deliver([0xF1, 0x10, 2, 0, 2], type: 0x0E, to: controller)
        deliver([0xF7, 0x10, 2], type: 0x0E, to: controller)
        deliver([0xF7, 0x11, 1, 2, 3], type: 0x0E, to: controller)
        controller.requestCurrentSettings()
        acknowledgeAll(controller)

        controller.setSpeakerLighting(.mode, value: [7])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 0x0E, 7])
        acknowledgeAll(controller)
        deliver([0xF7, 0x0E, 7], type: 0x0E, to: controller)
        XCTAssertEqual(controller.speakerLighting.mode, .off)
        XCTAssertNotNil(controller.pendingChanges[.speakerLighting(.mode)])
        acknowledgeAll(controller)
        deliver([0xF7, 0x0E, 7], type: 0x0E, to: controller)
        XCTAssertEqual(controller.speakerLighting.mode, .allFlashing)
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.mode)])

        controller.setSpeakerLighting(.customColor, value: [10, 20, 255])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 0x11, 0, 10, 20, 255])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.speakerLighting.customColor?.bytes, [1, 2, 3])
        deliver([0xF9, 0x11, 10, 20, 255], type: 0x0E, to: controller)
        XCTAssertEqual(controller.speakerLighting.customColor?.bytes, [10, 20, 255])
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.customColor)])
    }

    @MainActor
    func testPartyColorUsesTouchSequenceAndResetPreservesReportedItem() {
        let controller = makeController(functions: [], functions2: [0x71])
        defer { controller.simulateControlLoss() }
        deliver([0x71, 1, 1, 2, 0, 0], type: 0x0E, to: controller)
        deliver([0x73, 1, 0], type: 0x0E, to: controller)
        deliver([0x77, 1, 2], type: 0x0E, to: controller)
        controller.setPartyLightingColor(.init(red: 1, green: 2, blue: 3), x: -100, y: 100)
        acknowledgeAll(controller)
        let frames = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x7C }
        XCTAssertEqual(frames.map(\.type), [0x0E, 0x0E, 0x0E])
        XCTAssertEqual(frames.map(\.payload), [0, 2, 1].map { [0x7C, 1, $0, 156, 100, 1, 2, 3] })
        controller.setSpeakerLighting(.party, value: [0])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x78, 1, 0])
        acknowledgeAll(controller)
        XCTAssertEqual(controller.speakerLighting.partyItem, .customColor)
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.party)])
    }

    @MainActor
    func testPartyDragCoalescesMotionAndEndsWithFinalSampleOnBusyQueue() {
        let controller = makeController(functions: [], functions2: [0x71])
        defer { controller.simulateControlLoss() }
        deliver([0x71, 1, 1, 2, 0, 0], type: 0x0E, to: controller)
        deliver([0x73, 1, 0], type: 0x0E, to: controller)
        deliver([0x77, 1, 2], type: 0x0E, to: controller)
        controller.updatePartyLightingDrag(.init(red: 1, green: 2, blue: 3), x: 4, y: 5)
        acknowledgeAll(controller)
        controller.updatePartyLightingDrag(.init(red: 9, green: 8, blue: 7), x: 6, y: 5)
        controller.updatePartyLightingDrag(.init(red: 10, green: 20, blue: 30), x: -10, y: 10)
        controller.simulatePartyLightingTick()
        controller.updatePartyLightingDrag(.init(red: 100, green: 200, blue: 255), x: 33, y: -33)
        controller.simulatePartyLightingTick()
        controller.finishPartyLightingDrag()
        acknowledgeAll(controller)
        controller.simulatePartyLightingTick()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x7C }.map(\.payload), [
            [0x7C, 1, 0, 4, 5, 1, 2, 3],
            [0x7C, 1, 2, 246, 10, 10, 20, 30],
            [0x7C, 1, 1, 33, 223, 100, 200, 255],
        ])
    }

    @MainActor
    func testLightingColorPreviewSkipsStaleSamplesAndFinishesWithNotificationRequested() {
        let controller = makeController(functions: [], functions2: [0xFE])
        defer { controller.simulateControlLoss() }
        deliver([0xF1, 0x10, 2, 0, 2], type: 0x0E, to: controller)
        deliver([0xF7, 0x10, 2], type: 0x0E, to: controller)
        deliver([0xF7, 0x11, 1, 2, 3], type: 0x0E, to: controller)
        controller.previewSpeakerLightingColor(.init(red: 10, green: 20, blue: 30))
        controller.previewSpeakerLightingColor(.init(red: 100, green: 200, blue: 255))
        controller.simulateLightingColorPreviewTick()
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 0x11, 1, 100, 200, 255])
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.customColor)])
        XCTAssertEqual(controller.speakerLighting.customColor?.bytes, [1, 2, 3])
        controller.previewSpeakerLightingColor(.init(red: 0, green: 0, blue: 0))
        controller.simulateLightingColorPreviewTick()
        controller.setSpeakerLighting(.customColor, value: [1, 2, 3])
        acknowledgeAll(controller)
        controller.simulateLightingColorPreviewTick()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.prefix(2) == [0xF8, 0x11] }.map(\.payload), [
            [0xF8, 0x11, 1, 100, 200, 255], [0xF8, 0x11, 0, 1, 2, 3],
        ])
        XCTAssertNotNil(controller.pendingChanges[.speakerLighting(.customColor)])
        deliver([0xF9, 0x11, 1, 2, 3], type: 0x0E, to: controller)
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.customColor)])
    }

    @MainActor
    func testLightingPreviewCancellationDropsPendingSamplesAndDeferredWrites() {
        let controller = makeController(functions: [], functions2: [0xFE])
        defer { controller.simulateControlLoss() }
        deliver([0xF1, 0x10, 1, 2], type: 0x0E, to: controller)
        deliver([0xF7, 0x10, 2], type: 0x0E, to: controller)
        deliver([0xF7, 0x11, 1, 2, 3], type: 0x0E, to: controller)
        controller.previewSpeakerLightingColor(.init(red: 10, green: 20, blue: 30))
        controller.cancelSpeakerLightingColorPreview()
        controller.simulateLightingColorPreviewTick()
        controller.defersSimulatedWrites = true
        controller.previewSpeakerLightingColor(.init(red: 100, green: 200, blue: 255))
        controller.simulateLightingColorPreviewTick()
        controller.cancelSpeakerLightingColorPreview()
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.prefix(2) == [0xF8, 0x11] })
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.customColor)])
    }

    @MainActor
    func testLightingModeCautionUsesCurrentRequestAndAwaitsConfirmedMode() throws {
        for action in [SonyConnectionAlertAction.negative, .positive] {
            let controller = makeController(functions: [0x90], functions2: [0xFC])
            defer { controller.simulateControlLoss() }
            deliver([0xF1, 0x0E, 2, 0, 7, 1, 0], type: 0x0E, to: controller)
            deliver([0xF3, 0x0E, 0], type: 0x0E, to: controller)
            deliver([0xF7, 0x0E, 0], type: 0x0E, to: controller)
            controller.setSpeakerLighting(.mode, value: [7])
            acknowledgeAll(controller)
            deliver([0x99, 0, 0x88, 1], to: controller)
            let alert = try XCTUnwrap(controller.lightingModeAlert)
            controller.respondToLightingModeAlert(alert, action: action, requestID: UUID())
            XCTAssertEqual(controller.lightingModeAlert, alert)
            controller.respondToLightingModeAlert(alert, action: action, requestID: controller.lightingModeAlertRequestID)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 0x88, action.rawValue])
            acknowledgeAll(controller)
            XCTAssertEqual(controller.speakerLighting.mode, .off)
            XCTAssertEqual(controller.pendingChanges[.speakerLighting(.mode)] != nil, action == .positive)
            if action == .positive {
                deliver([0xF9, 0x0E, 7], type: 0x0E, to: controller)
                XCTAssertEqual(controller.speakerLighting.mode, .allFlashing)
            }
            XCTAssertNil(controller.pendingChanges[.speakerLighting(.mode)])
        }
    }

    @MainActor
    func testDeferredLightingModeWriteRechecksAvailability() {
        let controller = makeController(functions: [], functions2: [0xFC])
        defer { controller.simulateControlLoss() }
        deliver([0xF1, 0x0E, 2, 0, 7, 0], type: 0x0E, to: controller)
        deliver([0xF3, 0x0E, 0], type: 0x0E, to: controller)
        deliver([0xF7, 0x0E, 0], type: 0x0E, to: controller)
        controller.defersSimulatedWrites = true
        controller.setSpeakerLighting(.mode, value: [7])
        deliver([0xF5, 0x0E, 1], type: 0x0E, to: controller)
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == [0xF8, 0x0E, 7] })
        XCTAssertNil(controller.pendingChanges[.speakerLighting(.mode)])
        XCTAssertNotNil(controller.settingErrors[.speakerLighting(.mode)])
        XCTAssertEqual(controller.speakerLighting.mode, .off)
    }

    @MainActor
    func testSpeakerQueriesRequireTheirAdvertisedTableAndChargeInUseHasNoQuery() {
        for supported in [false, true] {
            let controller = makeController(functions: supported ? [0x26, 0x2D] : [0x20, 0x21],
                                            functions2: supported ? [0x20, 0x21] : [0x26, 0x2D, 0x21])
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(controller.powerFeatures.supportsChargeInUse)
            for item in settings {
                XCTAssertEqual(controller.simulatedTransmittedFrames.contains { $0.type == item.type && $0.payload == [0x26, item.inquiry] }, supported)
                set(item.setting, enabled: true, controller: controller)
                XCTAssertNil(controller.pendingChanges[item.setting])
                XCTAssertFalse(canSet(item.setting, controller: controller))
            }
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload == [0x26, 0x01] })
        }
    }

    @MainActor
    func testSpeakerSettersWaitForMatchingDeviceStateAfterAcknowledgment() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            XCTAssertTrue(canSet(item.setting, controller: controller))
            set(item.setting, enabled: true, controller: controller)
            XCTAssertEqual(controller.simulatedPendingFrame?.type, item.type)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x28, item.inquiry, 0])
            acknowledgeAll(controller)
            XCTAssertNotNil(controller.pendingChanges[item.setting])
            XCTAssertFalse(canSet(item.setting, controller: controller))
            XCTAssertEqual(enabled(item.setting, controller: controller), false)
            deliver([0x29, item.inquiry, 0], type: item.type == 0x0C ? 0x0E : 0x0C, to: controller)
            XCTAssertNotNil(controller.pendingChanges[item.setting])
            deliver([0x29, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNil(controller.settingErrors[item.setting])
            XCTAssertEqual(enabled(item.setting, controller: controller), true)
            XCTAssertTrue(canSet(item.setting, controller: controller))
        }
    }

    @MainActor
    func testPreChangeReadCannotConfirmSpeakerSettingAndFreshReadCan() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            set(item.setting, enabled: true, controller: controller)
            acknowledgeAll(controller)
            deliver([0x27, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNotNil(controller.pendingChanges[item.setting])
            XCTAssertEqual(enabled(item.setting, controller: controller), false)
            acknowledgeAll(controller)
            deliver([0x27, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertEqual(enabled(item.setting, controller: controller), true)
        }
    }

    @MainActor
    func testSpeakerNotificationStartingBeforeSetterDoesNotConfirmIt() {
        for item in settings {
            let encoded = SonyFrameCodec.encode(type: item.type, sequence: 1, payload: [0x29, item.inquiry, 0])
            for split in 1..<encoded.count {
                let controller = makeReadyController()
                defer { controller.simulateControlLoss() }
                controller.simulateProtocolData(SonyFrameCodec.encode(type: item.type, sequence: 0, payload: [0x25, item.inquiry, 0]))
                controller.simulateProtocolData(encoded.prefix(split))
                set(item.setting, enabled: true, controller: controller)
                controller.simulateProtocolData(encoded.dropFirst(split))
                acknowledgeAll(controller)
                XCTAssertNotNil(controller.pendingChanges[item.setting])
                deliver([0x29, item.inquiry, 0], type: item.type, to: controller)
                XCTAssertNil(controller.pendingChanges[item.setting])
            }
        }
    }

    @MainActor
    func testQueuedSpeakerSettersRevalidateAvailability() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            let blocking: SonyHeadphonesController.Setting = item.setting == .powerSavingMode ? .autoStandby : .powerSavingMode
            set(blocking, enabled: true, controller: controller)
            set(item.setting, enabled: true, controller: controller)
            deliver([0x25, item.inquiry, 1], type: item.type, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == item.type && $0.payload == [0x28, item.inquiry, 0] })
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNotNil(controller.settingErrors[item.setting])
            XCTAssertFalse(canSet(item.setting, controller: controller))
            XCTAssertTrue(controller.isReady)
        }
    }

    @MainActor
    func testSpeakerReadTimeoutRejectsOldReplyAndRecoversWithFreshRead() async {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            controller.simulatePowerReadTimeout([0x26, item.inquiry], type: item.type)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(enabled(item.setting, controller: controller))
            XCTAssertFalse(canSet(item.setting, controller: controller))
            let session = controller.simulatedControlSession
            deliver([0x27, item.inquiry, 0], type: item.type, to: controller)
            XCTAssertNil(enabled(item.setting, controller: controller))
            acknowledgeAll(controller)
            deliver([0x27, item.inquiry, 1], type: item.type, to: controller)
            XCTAssertEqual(enabled(item.setting, controller: controller), false)
            XCTAssertTrue(canSet(item.setting, controller: controller))
            XCTAssertEqual(controller.simulatedControlSession, session)
        }
    }

    @MainActor
    func testSpeakerSettingTimeoutBlocksRetryUntilCurrentStateArrives() async {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            set(item.setting, enabled: true, controller: controller)
            acknowledgeAll(controller)
            controller.simulateSettingTimeout(item.setting)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNotNil(controller.settingErrors[item.setting])
            XCTAssertFalse(canSet(item.setting, controller: controller))
            deliver([0x29, item.inquiry, 1], type: item.type, to: controller)
            XCTAssertNil(controller.settingErrors[item.setting])
            XCTAssertTrue(canSet(item.setting, controller: controller))
        }
    }

    @MainActor
    func testBluetoothStandbyWarningPreservesUserChoiceAndWaitsForDeviceState() throws {
        let choices: [(type: UInt8, action: SonyConnectionAlertAction?)] = [(0, nil), (1, .negative), (1, .positive), (2, .positive)]
        for choice in choices {
            let controller = makeReadyController(bluetoothEnabled: true)
            defer { controller.simulateControlLoss() }
            controller.setBluetoothStandby(false)
            acknowledgeAll(controller)
            deliver([0x99, 6, 0x0A, 2, 0x12, 0xFE, choice.type], to: controller)
            let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
            let requestID = try XCTUnwrap(controller.bluetoothStandbyAlertRequestID)
            XCTAssertEqual(alert.affectedFeatures.map(\.rawValue), [0x12, 0xFE])
            XCTAssertNil(controller.simulatedSettingTimeoutWork(.bluetoothStandby))
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
            controller.respondToBluetoothStandbyAlert(alert, action: choice.action, requestID: UUID())
            XCTAssertEqual(controller.bluetoothStandbyAlert, alert)
            controller.respondToBluetoothStandbyAlert(alert, action: choice.action, requestID: requestID)
            acknowledgeAll(controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
            XCTAssertNotNil(controller.pendingChanges[.bluetoothStandby])
            let replies = controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x98 }.map(\.payload)
            XCTAssertEqual(replies, choice.action.map { [[0x98, 6, 0x0A, $0.rawValue]] } ?? [])
            controller.respondToBluetoothStandbyAlert(alert, action: choice.action, requestID: requestID)
            deliver([0x99, 6, 0x0A, 2, 0x12, 0xFE, choice.type], to: controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
            let expected: UInt8 = choice.action == .negative ? 0 : 1
            deliver([0x29, 0x0D, expected], to: controller)
            XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
            XCTAssertEqual(controller.powerFeatures.bluetoothStandby?.enabled, expected == 0)
            XCTAssertTrue(controller.canSetBluetoothStandby)
        }
    }

    @MainActor
    func testBluetoothStandbyOnlyOwnsValidWarningsForTransmittedDisable() {
        let controller = makeReadyController()
        defer { controller.simulateControlLoss() }
        let warning: [UInt8] = [0x99, 6, 0x0A, 0, 1]
        deliver(warning, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        controller.setBluetoothStandby(true)
        acknowledgeAll(controller)
        deliver(warning, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        deliver([0x29, 0x0D, 0], to: controller)
        controller.setPowerSavingMode(true)
        controller.setBluetoothStandby(false)
        deliver(warning, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        acknowledgeAll(controller)
        for payload: [UInt8] in [[0x99, 0, 0x0A, 1], [0x99, 6, 0x0A, 0, 3], [0x99, 6, 0x0B, 0, 1]] {
            deliver(payload, to: controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
        }
        deliver(warning, type: 0x0E, to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        deliver(warning, to: controller)
        XCTAssertNotNil(controller.bluetoothStandbyAlert)
        controller.simulateControlLoss()
        XCTAssertNil(controller.bluetoothStandbyAlert)
        XCTAssertNil(controller.bluetoothStandbyAlertRequestID)
        XCTAssertNil(controller.powerFeatures.bluetoothStandby)
    }

    @MainActor
    func testBluetoothStandbyWarningStartingBeforeDisableIsNotOwned() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: [0x99, 6, 0x0A, 0, 1])
        for split in 1..<encoded.count {
            let controller = makeReadyController(bluetoothEnabled: true)
            defer { controller.simulateControlLoss() }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x25, 0x0D, 0]))
            controller.simulateProtocolData(encoded.prefix(split))
            controller.setBluetoothStandby(false)
            controller.simulateProtocolData(encoded.dropFirst(split))
            acknowledgeAll(controller)
            XCTAssertNil(controller.bluetoothStandbyAlert)
            deliver([0x99, 6, 0x0A, 0, 1], to: controller)
            XCTAssertNotNil(controller.bluetoothStandbyAlert)
        }
    }

    @MainActor
    func testBluetoothStandbyOldTimeoutCannotExpireAlertOrItsReply() async throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        acknowledgeAll(controller)
        let timeout = try XCTUnwrap(controller.simulatedSettingTimeoutWork(.bluetoothStandby))
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        let requestID = controller.bluetoothStandbyAlertRequestID
        timeout.perform()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(controller.bluetoothStandbyAlert, alert)
        deliver([0x29, 0x0D, 1], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.bluetoothStandby])
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: requestID)
        acknowledgeAll(controller)
        timeout.perform()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNotNil(controller.pendingChanges[.bluetoothStandby])
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x29, 0x0D, 1], to: controller)
        XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
    }

    @MainActor
    func testBluetoothStandbyQueuedReplyIsDiscardedWhenAvailabilityChanges() throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: controller.bluetoothStandbyAlertRequestID)
        deliver([0x25, 0x0D, 1], to: controller)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
        XCTAssertNotNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x27, 0x0D, 0], to: controller)
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
        XCTAssertFalse(controller.canSetBluetoothStandby)
    }

    @MainActor
    func testDeferredSpeakerWritesRevalidateBeforeTransportSendsThem() {
        for item in settings {
            let controller = makeReadyController()
            defer { controller.simulateControlLoss() }
            controller.defersSimulatedWrites = true
            set(item.setting, enabled: true, controller: controller)
            deliver([0x25, item.inquiry, 1], type: item.type, to: controller)
            controller.defersSimulatedWrites = false
            controller.completeSimulatedWrite()
            acknowledgeAll(controller)
            XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == item.type && $0.payload == [0x28, item.inquiry, 0] })
            XCTAssertNil(controller.pendingChanges[item.setting])
            XCTAssertNotNil(controller.settingErrors[item.setting])
        }
    }

    @MainActor
    func testDeferredBluetoothStandbyReplyRevalidatesBeforeTransportSendsIt() throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        acknowledgeAll(controller)
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        controller.defersSimulatedWrites = true
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: controller.bluetoothStandbyAlertRequestID)
        deliver([0x25, 0x0D, 1], to: controller)
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        XCTAssertNil(controller.pendingChanges[.bluetoothStandby])
        XCTAssertNotNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x27, 0x0D, 0], to: controller)
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
    }

    @MainActor
    func testBluetoothStandbyAvailabilityLossDismissesOutstandingWarning() throws {
        let controller = makeReadyController(bluetoothEnabled: true)
        defer { controller.simulateControlLoss() }
        controller.setBluetoothStandby(false)
        acknowledgeAll(controller)
        deliver([0x99, 6, 0x0A, 0, 1], to: controller)
        let alert = try XCTUnwrap(controller.bluetoothStandbyAlert)
        let requestID = controller.bluetoothStandbyAlertRequestID
        deliver([0x25, 0x0D, 1], to: controller)
        XCTAssertNil(controller.bluetoothStandbyAlert)
        controller.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: requestID)
        acknowledgeAll(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x98 })
        deliver([0x27, 0x0D, 0], to: controller)
        XCTAssertNil(controller.settingErrors[.bluetoothStandby])
        deliver([0x25, 0x0D, 0], to: controller)
        XCTAssertTrue(controller.canSetBluetoothStandby)
    }

    @MainActor
    private func makeController(functions: [UInt8] = [0x26, 0x2D], functions2: [UInt8] = [0x20, 0x21]) -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolMessage([0x01, 0, 0x03, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        let name = Array("WF-1000XM5".utf8)
        deliver([0x05, 1, UInt8(name.count)] + name, to: controller)
        deliver([0x05, 3, 0, 0], to: controller)
        let functions = [UInt8(0x6B)] + functions
        deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, to: controller)
        acknowledgeAll(controller)
        deliver([0x67, 0x17, 1, 1, 0, 0, 10], to: controller)
        acknowledgeAll(controller)
        deliver([0x07, 0, UInt8(functions2.count)] + functions2.flatMap { [$0, 0] }, type: 0x0E, to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    @MainActor
    private func makeReadyController(bluetoothEnabled: Bool = false) -> SonyHeadphonesController {
        let controller = makeController()
        for item in settings {
            if item.setting == .autoStandby { deliver([0x21, 0, 0], type: item.type, to: controller) }
            deliver([0x23, item.inquiry, 0], type: item.type, to: controller)
            deliver([0x27, item.inquiry, item.setting == .bluetoothStandby && bluetoothEnabled ? 0 : 1], type: item.type, to: controller)
        }
        return controller
    }

    @MainActor
    private func set(_ setting: SonyHeadphonesController.Setting, enabled: Bool, controller: SonyHeadphonesController) {
        switch setting {
        case .powerSavingMode: controller.setPowerSavingMode(enabled)
        case .bluetoothStandby: controller.setBluetoothStandby(enabled)
        case .autoStandby: controller.setAutoStandby(enabled)
        default: XCTFail("Unexpected speaker setting")
        }
    }

    @MainActor
    private func canSet(_ setting: SonyHeadphonesController.Setting, controller: SonyHeadphonesController) -> Bool {
        switch setting {
        case .powerSavingMode: controller.canSetPowerSavingMode
        case .bluetoothStandby: controller.canSetBluetoothStandby
        default: controller.canSetAutoStandby
        }
    }

    @MainActor
    private func enabled(_ setting: SonyHeadphonesController.Setting, controller: SonyHeadphonesController) -> Bool? {
        switch setting {
        case .powerSavingMode: controller.powerFeatures.powerSavingMode?.enabled
        case .bluetoothStandby: controller.powerFeatures.bluetoothStandby?.enabled
        default: controller.powerFeatures.autoStandby?.enabled
        }
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            replyToOrdinaryNoiseMetadata(frame, controller: controller)
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("Simulated command queue did not drain")
    }
}
