import Foundation
import XCTest
@testable import Acouplet

final class SonyEqualizerTests: XCTestCase {
    func testStandaloneSoundEffectRequiresGlobalAndPerModeAvailability() {
        let equalizer = SonyEqualizer(supportedFunctions: [0x54])
        XCTAssertFalse(equalizer.isSupported)
        XCTAssertFalse(equalizer.customSoundEffect.isSupported)
        XCTAssertFalse(equalizer.customEQ.isSupported)
        XCTAssertFalse(SonyEqualizer(supportedFunctions: [0x54], generation: .v1).soundEffect.isSupported)
        var effect = equalizer.soundEffect
        XCTAssertEqual(effect.queryPayloads, [[0x50, 0x30, 1], [0x52, 0x30], [0x56, 0x30]])
        XCTAssertTrue(effect.update([0x51, 0x30, 5, 3, 0, 4, 6, 0xFF, 1, 0]))
        XCTAssertEqual(effect.modes, [.ult2, .off, .custom])
        XCTAssertTrue(effect.update([0x57, 0x30, 0]))
        XCTAssertNil(effect.setPayload(.ult2))
        XCTAssertTrue(effect.update([0x53, 0x30, 0, 3, 0, 0, 3, 0, 6, 0]))
        XCTAssertEqual(effect.setPayload(.ult2), [0x58, 0x30, 3])
        XCTAssertNil(effect.setPayload(.off))
        XCTAssertNil(effect.setPayload(.custom))
        XCTAssertNil(effect.setPayload(.live))
        XCTAssertTrue(effect.update([0x55, 0x30, 1, 1, 3, 0]))
        XCTAssertNil(effect.setPayload(.ult2))
        let retained = effect
        for malformed: [UInt8] in [[0x51, 0x30, 1, 3], [0x53, 0x30, 0, 1, 3, 2], [0x53, 0x30, 0, 2, 3, 0, 3, 0],
                                  [0x59, 0x30, 0xFE], [0x59, 0x33, 0, 0]] { XCTAssertFalse(effect.update(malformed)) }
        XCTAssertEqual(effect, retained)
    }

    func testStandaloneCustomEQHasIndependentBandLayoutAndLevelRange() {
        let equalizer = SonyEqualizer(supportedFunctions: [0x55])
        XCTAssertFalse(equalizer.isSupported)
        XCTAssertFalse(equalizer.soundEffect.isSupported)
        XCTAssertFalse(equalizer.customSoundEffect.isSupported)
        XCTAssertFalse(SonyEqualizer(supportedFunctions: [0x55], generation: .v1).customEQ.isSupported)
        var custom = equalizer.customEQ
        XCTAssertEqual(custom.queryPayloads, [[0x50, 0x31, 1], [0x52, 0x31], [0x56, 0x31], [0x5A, 0x31]])
        XCTAssertTrue(custom.update([0x51, 0x31, 3, 21]))
        XCTAssertTrue(custom.update([0x57, 0x31, 3, 7, 9, 10]))
        XCTAssertTrue(custom.update([0x53, 0x31, 0]))
        XCTAssertNil(custom.setPayload([8, 9, 10]))
        XCTAssertTrue(custom.update([0x5B, 0x31, 3, 1, 0, 100, 2, 0, 1, 2, 0, 4]))
        XCTAssertEqual(custom.bands?.map(\.frequency), [100, 1_000, 4_000])
        XCTAssertEqual(custom.setPayload([8, 9, 10]), [0x58, 0x31, 3, 8, 9, 10])
        XCTAssertNil(custom.setPayload([7, 9, 10]))
        XCTAssertNil(custom.setPayload([21, 9, 10]))
        XCTAssertNil(custom.setPayload([9, 10]))
        XCTAssertTrue(custom.update([0x55, 0x31, 1]))
        XCTAssertNil(custom.setPayload([8, 9, 10]))
        let retained = custom
        for malformed: [UInt8] in [[0x51, 0x31, 2], [0x55, 0x31, 2], [0x59, 0x31, 1], [0x5B, 0x31, 0, 3],
                                  [0x59, 0x35, 3, 2, 9, 10]] { XCTAssertFalse(custom.update(malformed)) }
        XCTAssertEqual(custom, retained)
    }

    @MainActor
    func testStandaloneSpeakerEQOwnsReadbacksAndRevokesDeferredEdits() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "SRS-ULT1000", controlBusy: true)
        defer { controller.simulateControlLoss() }
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C) {
            controller.simulateProtocolMessage(payload, type: type)
            acknowledgeSimulatedCommands(controller)
        }
        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x07, 0, 2, 0x54, 0, 0x55, 0])
        let queries = controller.equalizer.soundEffect.queryPayloads + controller.equalizer.customEQ.queryPayloads
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && queries.contains($0.payload) }.map(\.payload), queries)
        deliver([0x51, 0x30, 3, 0, 2, 3, 0])
        deliver([0x53, 0x30, 0, 3, 0, 0, 2, 1, 3, 0])
        deliver([0x57, 0x30, 0])
        deliver([0x51, 0x31, 2, 21])
        deliver([0x53, 0x31, 0])
        deliver([0x57, 0x31, 2, 9, 11])
        deliver([0x5B, 0x31, 2, 1, 0, 100, 2, 0, 4])
        controller.setSoundEffect(.ult1)
        XCTAssertNil(controller.pendingChanges[.soundEffect])
        controller.setSoundEffect(.ult2)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x30, 3])
        deliver([0x59, 0x30, 3], type: 0x0E)
        deliver([0x57, 0x30, 3])
        XCTAssertEqual(controller.pendingChanges[.soundEffect], [3])
        deliver([0x59, 0x30, 3])
        XCTAssertNil(controller.pendingChanges[.soundEffect])

        let original = controller.equalizer.customEQ
        controller.defersSimulatedWrites = true
        controller.setCustomEQLevels([10, 11], basedOn: original)
        let setter: [UInt8] = [0x58, 0x31, 2, 10, 11]
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, setter)
        controller.simulateProtocolMessage([0x55, 0x31, 1])
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == setter })
        XCTAssertNil(controller.pendingChanges[.customEQ])
        deliver([0x55, 0x31, 0])
        deliver([0x59, 0x31, 2, 13, 11])
        controller.setCustomEQLevels([10, 11], basedOn: original)
        XCTAssertNil(controller.pendingChanges[.customEQ])
        controller.setCustomEQLevels([10, 11], basedOn: controller.equalizer.customEQ)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, setter)
        deliver([0x59, 0x33, 3, 0])
        XCTAssertEqual(controller.pendingChanges[.customEQ], [2, 10, 11])
        deliver([0x59, 0x31, 2, 10, 11])
        XCTAssertNil(controller.pendingChanges[.customEQ])
        XCTAssertEqual(controller.equalizer.customEQ.values, [10, 11])
        controller.simulateControlLoss()
        XCTAssertFalse(controller.equalizer.customEQ.isSupported)
        XCTAssertFalse(controller.equalizer.soundEffect.isSupported)
    }

    func testCustomSoundEffectRequiresReportedModesAndLevelRange() {
        XCTAssertFalse(SonyEqualizer(supportedFunctions: [0x59]).isSupported)
        XCTAssertFalse(SonyEqualizer(supportedFunctions: [0x59], generation: .v1).customSoundEffect.isSupported)
        var sound = SonyEqualizer(supportedFunctions: [0x59]).customSoundEffect
        XCTAssertEqual(sound.queryPayloads, [[0x50, 0x33], [0x5A, 0x33], [0x56, 0x33]])
        XCTAssertTrue(sound.update([0x51, 0x33, 2, 1, 2, 6, 3]))
        XCTAssertEqual(sound.effects, [.live, .ult2])
        XCTAssertTrue(sound.update([0x5B, 0x33, 2, 1, 0, 200, 0x10, 0, 1]))
        XCTAssertTrue(sound.update([0x57, 0x33, 6, 0, 2, 2, 9, 10, 2, 12, 14]))
        XCTAssertEqual(sound.values, [9, 10])
        XCTAssertNil(sound.editableValues)
        XCTAssertNil(sound.selectPayload(.custom))
        XCTAssertFalse(sound.update([0x51, 0x31, 2, 21, 0]))
        XCTAssertEqual(sound.selectPayload(.ult2), [0x58, 0x33, 3])
        XCTAssertEqual(sound.resetPayload(.live), [0x58, 0x34, 6])
        XCTAssertTrue(sound.update([0x59, 0x33, 3, 0]))
        XCTAssertEqual(sound.values, [12, 14])
        XCTAssertTrue(sound.update([0x59, 0x34, 3, 2, 10, 10]))
        XCTAssertEqual(sound.values, [10, 10])
        XCTAssertTrue(sound.update([0x59, 0x36, 0xFF, 1, 0, 0]))
        XCTAssertTrue(sound.isExcludedByStamina)
        XCTAssertNil(sound.selectPayload(.ult2))

        var editable = SonyEqualizer(supportedFunctions: [0x59]).customSoundEffect
        for packet: [UInt8] in [[0x51, 0x33, 2, 21, 2, 6, 3],
                               [0x5B, 0x33, 2, 1, 0, 200, 0x10, 0, 1],
                               [0x57, 0x33, 6, 0, 2, 2, 9, 10, 2, 12, 14]] { XCTAssertTrue(editable.update(packet)) }
        XCTAssertEqual(editable.editableValues, [9, 10])
        XCTAssertEqual(editable.editPayload(.live, values: [7, 20]), [0x58, 0x35, 0, 6, 2, 7, 20])
        XCTAssertEqual(editable.editPayload(.live, values: [7, 20], preview: true), [0x58, 0x35, 1, 6, 2, 7, 20])
        XCTAssertNil(editable.editPayload(.live, values: [7, 21]))
        XCTAssertNil(editable.editPayload(.ult2, values: [7, 20]))
        let retained = editable
        for packet: [UInt8] in [[0x51, 0x33, 2, 21, 2, 6, 0xFE], [0x5B, 0x33, 2, 1, 0, 200],
                               [0x57, 0x33, 6, 0, 2, 2, 9], [0x59, 0x33, 6, 1, 0],
                               [0x59, 0x36, 0xFF, 0, 1, 1]] { XCTAssertFalse(editable.update(packet)) }
        XCTAssertEqual(editable, retained)
    }

    @MainActor
    func testCustomSoundEffectConfirmsOwnedCommandsAndRejectsSupersededEdit() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "SRS-ULT1000", controlBusy: true)
        defer { controller.simulateControlLoss() }
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C) {
            controller.simulateProtocolMessage(payload, type: type)
            acknowledgeSimulatedCommands(controller)
        }

        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x07, 0, 1, 0x59, 0])
        let queries = controller.equalizer.customSoundEffect.queryPayloads
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && queries.contains($0.payload) }.map(\.payload), queries)
        deliver([0x51, 0x33, 2, 21, 2, 6, 3])
        deliver([0x5B, 0x33, 2, 1, 0, 200, 0x10, 0, 1])
        deliver([0x57, 0x33, 6, 0, 2, 2, 9, 10, 2, 12, 14])

        controller.selectCustomSoundEffect(.ult2)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x33, 3])
        deliver([0x59, 0x33, 3, 0], type: 0x0E)
        deliver([0x57, 0x33, 3, 0, 2, 2, 9, 10, 2, 12, 14])
        XCTAssertEqual(controller.pendingChanges[.customSoundEffect], [0x33, 3])
        deliver([0x59, 0x33, 3, 0])
        XCTAssertNil(controller.pendingChanges[.customSoundEffect])
        XCTAssertEqual(controller.equalizer.customSoundEffect.values, [12, 14])

        controller.editCustomSoundEffect(.ult2, values: [11, 14], basedOn: [9, 10])
        XCTAssertNil(controller.pendingChanges[.customSoundEffect])
        controller.defersSimulatedWrites = true
        let superseded: [UInt8] = [0x58, 0x35, 0, 3, 2, 11, 14]
        controller.editCustomSoundEffect(.ult2, values: [11, 14], basedOn: [12, 14])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, superseded)
        controller.simulateProtocolMessage([0x59, 0x36, 3, 0, 2, 15, 14])
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == superseded })

        controller.editCustomSoundEffect(.ult2, values: [11, 14], basedOn: [15, 14])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, superseded)
        deliver([0x59, 0x36, 3, 0, 2, 11, 14])
        XCTAssertEqual(controller.pendingChanges[.customSoundEffect], Array(superseded.dropFirst()))
        deliver([0x59, 0x35, 3, 2, 11, 14])
        XCTAssertNil(controller.pendingChanges[.customSoundEffect])

        controller.resetCustomSoundEffect(.ult2)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x34, 3])
        deliver([0x59, 0x34, 6, 2, 8, 10])
        XCTAssertEqual(controller.pendingChanges[.customSoundEffect], [0x34, 3])
        deliver([0x59, 0x34, 3, 2, 10, 10])
        XCTAssertNil(controller.pendingChanges[.customSoundEffect])
        XCTAssertEqual(controller.equalizer.customSoundEffect.values, [10, 10])
        controller.simulateControlLoss()
        XCTAssertNil(controller.equalizer.customSoundEffect.selectedEffect)
    }

    func testULTButtonAssignmentUsesReportedModesAndSelectionLimits() {
        let equalizer = SonyEqualizer(supportedFunctions: [0x58])
        XCTAssertFalse(equalizer.isSupported)
        XCTAssertFalse(SonyEqualizer(supportedFunctions: [0x58], generation: .v1).ultSoundEffectAssignment.isSupported)
        XCTAssertFalse(SonyEqualizer(supportedFunctions: [0x59]).ultSoundEffectAssignment.isSupported)
        var assignment = equalizer.ultSoundEffectAssignment
        XCTAssertEqual(assignment.queryPayloads, [[0x50, 0x40], [0x56, 0x40]])
        XCTAssertTrue(assignment.update([0x57, 0x40, 4, 6, 0, 0, 0, 2, 1, 4, 1]))
        XCTAssertNil(assignment.setPayload(.ult1, enabled: true))
        XCTAssertTrue(assignment.update([0x51, 0x40, 2, 3]))
        XCTAssertEqual(assignment.entries?.map(\.id), [.live, .off, .ult1, .custom])
        XCTAssertNil(assignment.setPayload(.off, enabled: false))
        XCTAssertNil(assignment.setPayload(.flat, enabled: true))
        XCTAssertEqual(assignment.setPayload(.ult1, enabled: true), [0x58, 0x40, 4, 6, 0, 0, 0, 2, 0, 4, 1])
        let original = assignment
        for malformed: [UInt8] in [[0x51, 0x40, 3, 2], [0x59, 0x40, 1, 0], [0x59, 0x40, 1, 0xFF, 0],
                                  [0x57, 0x40, 1, 0, 2], [0x57, 0x40, 2, 6, 0, 6, 1]] {
            XCTAssertFalse(assignment.update(malformed))
        }
        XCTAssertEqual(assignment, original)
        XCTAssertTrue(assignment.update([0x59, 0x40, 4, 6, 0, 0, 0, 2, 0, 4, 1]))
        XCTAssertNil(assignment.setPayload(.custom, enabled: true))
        XCTAssertNil(assignment.setPayload(.live, enabled: true))
        XCTAssertEqual(assignment.setPayload(.live, enabled: false), [0x58, 0x40, 4, 6, 1, 0, 0, 2, 0, 4, 1])
    }

    @MainActor
    func testULTButtonAssignmentUsesTableOneAndRejectsSupersededWrites() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "SRS-ULT1000", controlBusy: true)
        defer { controller.simulateControlLoss() }
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C) {
            controller.simulateProtocolMessage(payload, type: type)
            acknowledgeSimulatedCommands(controller)
        }

        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x07, 0, 1, 0x58, 0])
        let queries = controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload.dropFirst().first == 0x40 }.map(\.payload)
        XCTAssertEqual(queries, [[0x50, 0x40], [0x56, 0x40]])
        deliver([0x51, 0x40, 2, 3], type: 0x0E)
        XCTAssertNil(controller.equalizer.ultSoundEffectAssignment.selectionCount)
        deliver([0x51, 0x40, 2, 3])
        let original: [UInt8] = [4, 3, 0, 0, 0, 2, 1, 4, 1]
        let requested: [UInt8] = [4, 3, 0, 0, 0, 2, 0, 4, 1]
        deliver([0x57, 0x40] + original)
        controller.setULTSoundEffectAssignment(.off, enabled: false)
        XCTAssertNil(controller.pendingChanges[.ultSoundEffectAssignment])
        controller.setULTSoundEffectAssignment(.ult1, enabled: true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x40] + requested)
        deliver([0x59, 0x40] + requested, type: 0x0E)
        deliver([0x57, 0x40] + requested)
        XCTAssertEqual(controller.pendingChanges[.ultSoundEffectAssignment], requested)
        deliver([0x59, 0x40] + requested)
        XCTAssertNil(controller.pendingChanges[.ultSoundEffectAssignment])
        XCTAssertEqual(controller.equalizer.ultSoundEffectAssignment.entries?.filter(\.enabled).map(\.id), [.ult2, .off, .ult1])

        controller.defersSimulatedWrites = true
        controller.setULTSoundEffectAssignment(.off, enabled: false)
        let superseded = [0x58, 0x40, 4, 3, 0, 0, 1, 2, 0, 4, 1] as [UInt8]
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, superseded)
        controller.simulateProtocolMessage([0x59, 0x40, 4, 3, 0, 0, 0, 2, 1, 4, 0])
        controller.defersSimulatedWrites = false
        controller.completeSimulatedWrite()
        acknowledgeSimulatedCommands(controller)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload == superseded })
        XCTAssertNil(controller.pendingChanges[.ultSoundEffectAssignment])
        XCTAssertEqual(controller.equalizer.ultSoundEffectAssignment.entries?.filter(\.enabled).map(\.id), [.ult2, .off, .custom])
        controller.simulateControlLoss()
        XCTAssertFalse(controller.equalizer.ultSoundEffectAssignment.isSupported)
        XCTAssertNil(controller.equalizer.ultSoundEffectAssignment.entries)
    }

    func testTurnKeyEqualizerCapabilitiesAreIndependentOfThePresetEditor() {
        let legacy = SonyEqualizer(supportedFunctions: [0x56, 0x5B], generation: .v1).turnKey
        XCTAssertFalse(legacy.supportsImport)
        XCTAssertFalse(legacy.supportsManagement)

        let importer = SonyEqualizer(supportedFunctions: [0x56])
        XCTAssertFalse(importer.isSupported)
        XCTAssertTrue(importer.turnKey.queryPayloads.isEmpty)
        XCTAssertEqual(importer.turnKey.importPayload(" AQID\n"), [0x58, 0x32, 3, 1, 2, 3])
        XCTAssertNil(importer.turnKey.importPayload("AQI!"))
        XCTAssertNil(importer.turnKey.importPayload(Data(repeating: 0x01, count: 256).base64EncodedString()))
        XCTAssertNil(importer.turnKey.deletePayload(0xB0))

        var manager = SonyEqualizer(supportedFunctions: [0x5B]).turnKey
        XCTAssertNil(manager.importPayload("AQID"))
        XCTAssertEqual(manager.queryPayloads, [[0x50, 0x37, 1], [0x52, 0x37]])
        XCTAssertTrue(manager.update([0x51, 0x37, 2, 0xB0, 0xFF]))
        XCTAssertTrue(manager.update([0x53, 0x37, 0]))
        XCTAssertEqual(manager.limit, .maximum)
        XCTAssertEqual(manager.deletePayload(0xB0), [0x58, 0x37, 0xB0])
        XCTAssertNil(manager.deletePayload(0xB1))
        XCTAssertNil(manager.deletePayload(0xFF))
        for malformed: [UInt8] in [[0x51, 0x37, 2, 0xB1], [0x51, 0x37, 1, 0x25], [0x53, 0x37, 2]] {
            XCTAssertFalse(manager.update(malformed))
        }
        XCTAssertEqual(manager.deletablePresets, [0xB0, 0xFF])
        XCTAssertEqual(manager.limit, .maximum)
    }

    @MainActor
    func testTurnKeyEqualizerControllerConfirmsOnlyTheTransmittedOperation() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", controlBusy: true)
        defer { controller.simulateControlLoss() }
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C) {
            controller.simulateProtocolMessage(payload, type: type)
            acknowledgeSimulatedCommands(controller)
        }

        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x07, 0, 2, 0x56, 0, 0x5B, 0])
        for query in SonyTurnKeyEqualizer(supportsImport: true, supportsManagement: true).queryPayloads {
            XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && $0.payload == query })
        }
        deliver([0x51, 0x37, 1, 0xB0], type: 0x0E)
        XCTAssertNil(controller.equalizer.turnKey.deletablePresets)
        deliver([0x51, 0x37, 1, 0xB0])
        deliver([0x53, 0x37, 0])
        controller.importTurnKeyEqualizer("AQID")
        controller.deleteTurnKeyEqualizerPreset(0xB1)
        XCTAssertNil(controller.pendingChanges[.turnKeyEQ])

        controller.deleteTurnKeyEqualizerPreset(0xB0)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x37, 0xB0])
        deliver([0x59, 0x32, 0])
        XCTAssertEqual(controller.pendingChanges[.turnKeyEQ], [0x37, 0xB0])
        deliver([0x59, 0x37, 0], type: 0x0E)
        XCTAssertEqual(controller.pendingChanges[.turnKeyEQ], [0x37, 0xB0])
        deliver([0x59, 0x37, 0])
        XCTAssertNil(controller.pendingChanges[.turnKeyEQ])
        XCTAssertNil(controller.equalizer.turnKey.deletablePresets)
        XCTAssertEqual(controller.equalizer.turnKey.lastCompletedOperation, 0x37)

        deliver([0x51, 0x37, 0])
        deliver([0x53, 0x37, 1])
        controller.importTurnKeyEqualizer("AQID")
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x32, 3, 1, 2, 3])
        deliver([0x59, 0x32, 2])
        XCTAssertNil(controller.pendingChanges[.turnKeyEQ])
        XCTAssertNotNil(controller.settingErrors[.turnKeyEQ])
        XCTAssertNil(controller.equalizer.turnKey.lastCompletedOperation)
        XCTAssertNil(controller.equalizer.presetID)

        deliver([0x99, 0, 0x93, 1])
        XCTAssertTrue(controller.turnKeyImportActions.isEmpty)
        for action: SonyConnectionAlertAction in [.negative, .positive] {
            controller.importTurnKeyEqualizer("AQID")
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x32, 3, 1, 2, 3])
            deliver([0x99, 0, 0x93, 1], type: 0x0E)
            deliver([0x59, 0x32, 0])
            XCTAssertTrue(controller.turnKeyImportActions.isEmpty)
            XCTAssertNil(controller.equalizer.turnKey.lastCompletedOperation)
            deliver([0x99, 0, 0x93, 1])
            XCTAssertEqual(controller.turnKeyImportActions, [.negative, .positive])
            controller.respondToTurnKeyEqualizerImport(action)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x98, 0, 0x93, action.rawValue])
            XCTAssertNil(controller.equalizer.turnKey.lastCompletedOperation)
            acknowledgeSimulatedCommands(controller)
            XCTAssertNil(controller.pendingChanges[.turnKeyEQ])
            XCTAssertEqual(controller.equalizer.turnKey.lastCompletedOperation, action == .positive ? 0x32 : nil)
        }
        deliver([0x99, 0, 0x96, 0])
        XCTAssertNil(controller.equalizer.turnKey.deletablePresets)
        controller.simulateControlLoss()
        XCTAssertFalse(controller.equalizer.turnKey.supportsManagement)
    }

    func testLRBalanceCorrectionUsesItsOwnCapabilityAndParameter() {
        let legacy = SonyEqualizer(supportedFunctions: [0x5A], generation: .v1)
        XCTAssertFalse(legacy.lrBalanceCorrection.isSupported)
        var state = SonyEqualizer(supportedFunctions: [0x5A]).lrBalanceCorrection
        XCTAssertEqual(state.queryPayloads, [[0x50, 0x51, 1], [0x52, 0x50], [0x52, 0x51], [0x56, 0x50]])
        XCTAssertTrue(state.update([0x51, 0x51, 7, 0, 32]))
        XCTAssertTrue(state.update([0x53, 0x50, 0]))
        XCTAssertTrue(state.update([0x53, 0x51, 1]))
        XCTAssertTrue(state.update([0x57, 0x50, 2]))
        XCTAssertEqual(state.adjustmentCapability, [7, 0, 32])
        XCTAssertEqual(state.available, true)
        XCTAssertEqual(state.adjustmentAvailable, false)
        XCTAssertEqual(state.mode, .offNotInitialized)
        XCTAssertNil(state.setPayload(enabled: true))
        let uninitialized = state
        XCTAssertFalse(state.update([0x59, 0x50, 3]))
        XCTAssertFalse(state.update([0x59, 0x51, 0]))
        XCTAssertFalse(state.update([0x55, 0x50, 0, 1]))
        XCTAssertEqual(state, uninitialized)
        XCTAssertTrue(state.update([0x59, 0x50, 0xFF]))
        XCTAssertEqual(state.mode, .outOfRange)
        XCTAssertNil(state.setPayload(enabled: true))
        XCTAssertTrue(state.update([0x59, 0x50, 1]))
        XCTAssertEqual(state.setPayload(enabled: true), [0x58, 0x50, 0])
        XCTAssertTrue(state.update([0x55, 0x50, 1]))
        XCTAssertNil(state.setPayload(enabled: true))
    }

    @MainActor
    func testLRBalanceCorrectionControllerRequiresSetupAndConfirmsExistingCorrection() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM5", controlBusy: true)
        defer { controller.simulateControlLoss() }
        func deliver(_ payload: [UInt8], type: UInt8 = 0x0C) {
            controller.simulateProtocolMessage(payload, type: type)
            acknowledgeSimulatedCommands(controller)
        }

        controller.simulateProtocolMessage([0x01, 0, 3, 0, 0x30, 0x18, 0, 1], beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x07, 0, 1, 0x5A, 0])
        let queries = controller.simulatedTransmittedFrames.filter { $0.type == 0x0C && $0.payload.count >= 2
            && (0x50...0x51).contains($0.payload[1]) }.map(\.payload)
        XCTAssertEqual(queries, [[0x50, 0x51, 1], [0x52, 0x50], [0x52, 0x51], [0x56, 0x50]])
        deliver([0x51, 0x51, 7, 0, 32])
        deliver([0x53, 0x50, 0])
        deliver([0x53, 0x51, 0])
        deliver([0x57, 0x50, 2])
        XCTAssertEqual(controller.equalizer.lrBalanceCorrection.mode, .offNotInitialized)
        controller.setLRBalanceCorrection(true)
        XCTAssertFalse(controller.canSetLRBalanceCorrection)
        XCTAssertNil(controller.simulatedPendingFrame)

        deliver([0x59, 0x50, 1], type: 0x0E)
        XCTAssertEqual(controller.equalizer.lrBalanceCorrection.mode, .offNotInitialized)
        deliver([0x59, 0x50, 1])
        XCTAssertTrue(controller.canSetLRBalanceCorrection)
        controller.setLRBalanceCorrection(true)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x50, 0])
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x50, 0])
        XCTAssertNotNil(controller.pendingChanges[.lrBalanceCorrection])
        deliver([0x59, 0x51, 0, 0])
        XCTAssertEqual(controller.equalizer.lrBalanceCorrection.mode, .off)
        deliver([0x59, 0x50, 0])
        XCTAssertEqual(controller.equalizer.lrBalanceCorrection.mode, .on)
        XCTAssertNil(controller.pendingChanges[.lrBalanceCorrection])
        controller.setLRBalanceCorrection(false)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x50, 1])
        acknowledgeSimulatedCommands(controller)
        deliver([0x59, 0x50, 1])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.starts(with: [0x58, 0x51]) })
        controller.simulateControlLoss()
        XCTAssertFalse(controller.equalizer.lrBalanceCorrection.isSupported)
    }

    func testStandaloneBassBoostKeepsSignedRangesSeparateFromPresetEqualizer() {
        for (generation, function, inquiry, preset): (SonyProtocolInfo.Generation, UInt8, UInt8, UInt8) in [
            (.v1, 0x52, 2, 0x51), (.v2, 0x51, 1, 0x50),
        ] {
            XCTAssertFalse(SonyEqualizer(supportedFunctions: [function], generation: generation).isSupported)
            var equalizer = SonyEqualizer(supportedFunctions: [function, preset], generation: generation)
            XCTAssertTrue(equalizer.isSupported)
            XCTAssertEqual(equalizer.bassBoost.queryPayloads, [[0x50, inquiry, 1], [0x52, inquiry], [0x56, inquiry]])
            XCTAssertTrue(equalizer.bassBoost.update([0x57, inquiry, 0xFB]))
            XCTAssertNil(equalizer.bassBoost.level)
            XCTAssertTrue(equalizer.bassBoost.update([0x51, inquiry, 0xF8, 12]))
            XCTAssertEqual(equalizer.bassBoost.range, -8...12)
            XCTAssertEqual(equalizer.bassBoost.level, -5)
            XCTAssertNil(equalizer.bassBoost.setPayload(12))
            XCTAssertTrue(equalizer.bassBoost.update([0x53, inquiry, 0]))
            XCTAssertEqual(equalizer.bassBoost.setPayload(-8), [0x58, inquiry, 0xF8])
            XCTAssertEqual(equalizer.bassBoost.setPayload(12), [0x58, inquiry, 12])
            XCTAssertNil(equalizer.bassBoost.setPayload(-9))
            XCTAssertNil(equalizer.bassBoost.setPayload(13))
            let previous = equalizer.bassBoost
            for payload: [UInt8] in [[0x51, inquiry, 0x80, 12], [0x51, inquiry, 12, 5], [0x51, inquiry, 1],
                                     [0x53, inquiry, 0, 0], [0x55, inquiry, 0xFF], [0x59, inquiry, 0x80],
                                     [0x59, inquiry + 1, 0], [0x59, inquiry, 0, 0]] {
                XCTAssertFalse(equalizer.bassBoost.update(payload))
                XCTAssertEqual(equalizer.bassBoost, previous)
            }
            XCTAssertTrue(equalizer.bassBoost.update([0x55, inquiry, 1]))
            XCTAssertNil(equalizer.bassBoost.setPayload(12))
            XCTAssertNil(equalizer.presetID)
        }
    }

    @MainActor
    func testBassBoostControllerRequiresFreshTableOneDataAndConfirmsOnlyNewLevel() throws {
        for (legacy, function, inquiry): (Bool, UInt8, UInt8) in [(true, 0x52, 2), (false, 0x51, 1)] {
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            defer { controller.simulateControlLoss() }
            func acknowledgeCommands() {
                for _ in 0..<40 {
                    guard let frame = controller.simulatedPendingFrame else { return }
                    controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
                }
            }
            controller.simulateDeviceConnection(named: "WF-1000XM4", controlBusy: true)
            controller.simulateProtocolMessage(legacy ? [0x01, 0, 2, 0x10] : [0x01, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
            acknowledgeCommands()
            if legacy {
                let name = Array("WF-1000XM4".utf8)
                controller.simulateProtocolMessage([0x05, 1, UInt8(name.count)] + name)
                controller.simulateProtocolMessage([0x05, 3, 0x30, 0xFF])
            }
            controller.simulateProtocolMessage([0x07, 0, 1, function] + (legacy ? [] : [0xFF]))
            acknowledgeCommands()
            XCTAssertTrue(controller.isReady)
            let queries = [[UInt8(0x50), inquiry, 1], [0x52, inquiry], [0x56, inquiry]]
            for query in queries {
                XCTAssertTrue(controller.simulatedTransmittedFrames.contains { $0.type == 0x0C && $0.payload == query })
            }
            controller.simulateProtocolMessage([0x51, inquiry, 0xF8, 12], type: 0x0E)
            XCTAssertNil(controller.equalizer.bassBoost.range)
            controller.setBassBoost(5)
            XCTAssertNil(controller.pendingChanges[.bassBoost])
            controller.simulateProtocolMessage([0x51, inquiry, 0xF8, 12])
            controller.simulateProtocolMessage([0x53, inquiry, 0])
            controller.simulateProtocolMessage([0x57, inquiry, 0xFA])
            acknowledgeCommands()
            XCTAssertEqual(controller.equalizer.bassBoost.level, -6)
            XCTAssertTrue(controller.canSetBassBoost)

            controller.requestCurrentSettings()
            acknowledgeCommands()
            controller.setBassBoost(-3)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, inquiry, 0xFD])
            acknowledgeCommands()
            controller.simulateProtocolMessage([0x57, inquiry, 0xFD])
            XCTAssertEqual(controller.equalizer.bassBoost.level, -6)
            XCTAssertNotNil(controller.pendingChanges[.bassBoost])
            acknowledgeCommands()
            controller.simulateProtocolMessage([0x59, inquiry, 0xFD])
            XCTAssertEqual(controller.equalizer.bassBoost.level, -3)
            XCTAssertNil(controller.pendingChanges[.bassBoost])
            XCTAssertNil(controller.pendingChanges[.equalizer])
            controller.simulateProtocolMessage([0x55, inquiry, 1])
            XCTAssertFalse(controller.canSetBassBoost)
        }
    }

    func testAdvertisedPresetOrderNamesAndUnknownIdentityArePreserved() {
        var equalizer = SonyEqualizer(supportedFunctions: [0x50])
        let name = Array("Göğüs".utf8)
        XCTAssertTrue(equalizer.update([0x51, 0, 255, 255, 3, 0x31, 0, 0x77, UInt8(name.count)] + name + [0, 0]))
        XCTAssertEqual(equalizer.capabilities?.bandCount, 255)
        XCTAssertEqual(equalizer.capabilities?.levelSteps, 255)
        XCTAssertEqual(equalizer.capabilities?.presets.map(\.id), [0x31, 0x77, 0])
        XCTAssertEqual(equalizer.capabilities?.presets.map(\.title), ["Clear", "Göğüs", "Off"])
        XCTAssertTrue(equalizer.update([0x57, 0, 0xFE, 0]))
        XCTAssertEqual(equalizer.presetID, 0xFE)
        XCTAssertEqual(equalizer.presetTitle, "Preset FE")
        XCTAssertNil(equalizer.presetPayload(0x31))
        XCTAssertTrue(equalizer.update([0x53, 0, 0]))
        XCTAssertEqual(equalizer.presetPayload(0x31), [0x58, 0, 0x31, 0])
        XCTAssertNil(equalizer.presetPayload(0x10))
        XCTAssertNil(equalizer.presetPayload(0xFE))
        XCTAssertFalse(equalizer.canEdit)
    }

    func testMalformedPacketsDoNotReplaceValidatedState() {
        var equalizer = prepared()
        let previous = equalizer
        for payload: [UInt8] in [
            [], [0x51], [0x51, 0, 6, 21, 1], [0x51, 0, 6, 21, 1, 0, 2, 65],
            [0x51, 0, 6, 21, 1, 0, 1, 0xFF], [0x51, 0, 6, 21, 0, 0],
            [0x53, 0], [0x53, 0, 0, 0], [0x5B, 0, 1, 1, 0],
            [0x5B, 0, 1, 1, 0, 31, 0], [0x57, 0, 0xA0, 2, 10],
            [0x59, 0, 0xA0, 0, 10], [0x57, 2, 0xA0, 0],
            [0x59, 0, 0xA0, 5, 10, 10, 10, 10, 10],
            [0x59, 0, 0xA0, 6, 21, 10, 10, 10, 10, 10],
        ] {
            XCTAssertFalse(equalizer.update(payload), "\(payload)")
            XCTAssertEqual(equalizer, previous)
        }
    }

    func testMetadataDecodesUInt16AndKeepsClearBassAtItsActualIndex() throws {
        let layout = Array(SonyEqualizerBand.legacy.dropFirst()) + [.clearBass]
        var equalizer = prepared(layout: layout)
        XCTAssertEqual(equalizer.bandInformation, layout)
        XCTAssertEqual(equalizer.bandInformation?[2].value, 2_500)
        XCTAssertTrue(equalizer.update([0x59, 0, 0xA0, 6, 11, 12, 13, 14, 15, 16]))
        let settings = try XCTUnwrap(equalizer.settings)
        XCTAssertEqual(settings.clearBass, 6)
        XCTAssertEqual(settings.bands, [1, 2, 3, 4, 5])
        XCTAssertEqual(equalizer.settingsPayload(settings), [0x58, 0, 0xA0, 6, 11, 12, 13, 14, 15, 16])
        XCTAssertNil(equalizer.settingsPayload(.flat))
        XCTAssertTrue(equalizer.update([0x59, 0, 0x31, 0]))
        XCTAssertEqual(equalizer.rawValues, [11, 12, 13, 14, 15, 16])
        XCTAssertEqual(equalizer.settings, settings)
    }

    func testTenBandProfilesKeepTheirLayoutRangeAndAllValues() throws {
        let equalizer = prepared(layout: SonyEqualizerBand.tenBand, steps: 13)
        var settings = try XCTUnwrap(equalizer.flatSettings)
        settings[9] = 99
        settings[0] = -99
        XCTAssertEqual(settings.levelRange, -6...6)
        XCTAssertEqual(settings.values, [-6, 0, 0, 0, 0, 0, 0, 0, 0, 6])
        let restored = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(equalizer.settingsPayload(restored), [0x58, 0, 0xA0, 10, 0, 6, 6, 6, 6, 6, 6, 6, 6, 12])
        XCTAssertNil(equalizer.settingsPayload(.flat))
        XCTAssertNil(prepared().settingsPayload(restored))
        XCTAssertEqual(SonyEqualizerBand(informationType: 2, value: 16).frequency, 16_000)
    }

    func testLegacyProfilesNormalizeButNewProfilesRejectCorruptionInsteadOfTruncating() throws {
        let old = Data(#"{"clearBass":99,"bands":[-99,4]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EqualizerSettings.self, from: old),
                       EqualizerSettings(clearBass: 10, bands: [-10, 4, 0, 0, 0]))
        let short = EqualizerSettings(layout: SonyEqualizerBand.tenBand, levelSteps: 13, values: [0, 0])
        XCTAssertThrowsError(try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(short)))
        var outOfRange = EqualizerSettings(layout: SonyEqualizerBand.tenBand, levelSteps: 13, values: Array(repeating: 0, count: 10))
        outOfRange.values[9] = 7
        XCTAssertThrowsError(try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(outOfRange)))
        XCTAssertNil(prepared(layout: SonyEqualizerBand.tenBand, steps: 13).settingsPayload(outOfRange))
    }

    func testAdvertisedLayoutsAndEvenLevelsRoundTripAcrossWritableDialects() throws {
        let layout: [SonyEqualizerBand] = [
            SonyEqualizerBand(informationType: 2, value: 3), .clearBass,
            SonyEqualizerBand(informationType: 1, value: 80),
        ]
        for (generation, type): (SonyProtocolInfo.Generation, UInt8) in [(.v1, 1), (.v2, 0), (.v2, 4)] {
            var equalizer = prepared(layout: layout, steps: 12, type: type, generation: generation, advertisedBandCount: 1)
            XCTAssertTrue(equalizer.canEdit)
            XCTAssertEqual(equalizer.flatSettings?.levelRange, -5...6)
            XCTAssertTrue(equalizer.update([0x59, type, 0xA0, 3, 0, 11, 5]))
            let settings = try XCTUnwrap(equalizer.settings)
            XCTAssertEqual(settings.layout, layout)
            XCTAssertEqual(settings.values, [-5, 6, 0])
            XCTAssertEqual(settings.clearBass, 6)
            XCTAssertEqual(settings.bands, [-5, 0])
            let restored = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(settings))
            let payload: [UInt8] = [0x58, type, generation == .v1 ? 0xFF : 0xA0, 3, 0, 11, 5]
            XCTAssertEqual(equalizer.settingsPayload(restored), payload)
            XCTAssertTrue(equalizer.acceptsSetPayload(payload))
            XCTAssertEqual(equalizer.confirmationValue(payload), equalizer.confirmationValue([0x59, type, 0xA0, 3, 0, 11, 5]))

            var clamped = settings
            clamped[0] = -99
            clamped[1] = 99
            XCTAssertEqual(clamped, settings)
            let previous = equalizer
            for invalid: [UInt8] in [[0x59, type, 0xA0, 2, 0, 11], [0x59, type, 0xA0, 3, 0, 12, 5]] {
                XCTAssertFalse(equalizer.update(invalid))
                XCTAssertEqual(equalizer, previous)
            }
            XCTAssertNil(equalizer.settingsPayload(EqualizerSettings(layout: layout.reversed(), levelSteps: 12, values: settings.values)))
            XCTAssertNil(equalizer.settingsPayload(EqualizerSettings(layout: layout, levelSteps: 12, values: [-6, 6, 0])))
            XCTAssertNil(equalizer.settingsPayload(EqualizerSettings(layout: layout, levelSteps: 12, values: [-5, 7, 0])))
        }
    }

    func testUnlabelledAndRepeatedFrequencyBandsPreserveTheirAdvertisedPositions() throws {
        let layout = [0, 1_750, 1_750].map { SonyEqualizerBand(informationType: 1, value: UInt16($0)) }
            + [SonyEqualizerBand(informationType: 0x7F, value: 0xBEEF)]
        var equalizer = prepared(layout: layout, steps: 255)
        XCTAssertTrue(equalizer.update([0x59, 0, 0xA0, 4, 0, 127, 128, 254]))
        let settings = try XCTUnwrap(equalizer.settings)
        XCTAssertEqual(settings.layout, layout)
        XCTAssertEqual(settings.values, [-127, 0, 1, 127])
        XCTAssertEqual(equalizer.settingsPayload(settings), [0x58, 0, 0xA0, 4, 0, 127, 128, 254])
        XCTAssertEqual(try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testUnavailableStateInvalidatesQueuedCurveAndPresetWrites() throws {
        var equalizer = prepared()
        let curve = try XCTUnwrap(equalizer.settingsPayload(.flat))
        let preset = try XCTUnwrap(equalizer.presetPayload(0))
        XCTAssertTrue(equalizer.acceptsSetPayload(curve))
        XCTAssertTrue(equalizer.acceptsSetPayload(preset))
        XCTAssertFalse(equalizer.acceptsSetPayload([0x58, 0, 0xA0, 6, 21, 10, 10, 10, 10, 10]))
        XCTAssertTrue(equalizer.update([0x55, 0, 1]))
        XCTAssertFalse(equalizer.acceptsSetPayload(curve))
        XCTAssertFalse(equalizer.acceptsSetPayload(preset))
        XCTAssertNotNil(equalizer.settings)
        XCTAssertTrue(equalizer.update([0x55, 0, 0xFE]))
        XCTAssertEqual(equalizer.status, 0xFE)
        XCTAssertNil(equalizer.available)
    }

    func testNoncustomizableAndErrorCodeDialectsUseTheirOwnSchemas() {
        var noncustomizable = prepared(type: 2)
        XCTAssertEqual(noncustomizable.presetPayload(0), [0x58, 2, 0, 0])
        XCTAssertFalse(noncustomizable.canEdit)
        XCTAssertNil(noncustomizable.settingsPayload(.flat))
        XCTAssertFalse(noncustomizable.update([0x55, 0, 0]))
        XCTAssertEqual(noncustomizable.parameterQueryPayload, [0x56, 2])

        var withErrors = prepared(type: 4)
        XCTAssertTrue(withErrors.update([0x55, 4, 1, 2, 0x01, 0xEF]))
        XCTAssertEqual(withErrors.errorCodes, [0x01, 0xEF])
        XCTAssertFalse(withErrors.canSelectPreset)
        XCTAssertFalse(withErrors.update([0x53, 4, 0]))
        XCTAssertFalse(withErrors.update([0x53, 4, 0, 2, 0x01]))
        XCTAssertTrue(withErrors.update([0x53, 4, 0, 0]))
        XCTAssertEqual(withErrors.settingsPayload(.flat).map { Array($0.prefix(2)) }, [0x58, 4])
        XCTAssertEqual(withErrors.parameterQueryPayload, [0x56, 4])
    }

    func testEmptyMetadataAndInvalidStepsNeverBecomeWritableEQ() {
        var equalizer = prepared()
        XCTAssertTrue(equalizer.update([0x5B, 0, 0]))
        XCTAssertEqual(equalizer.bandInformation, [])
        XCTAssertNotNil(equalizer.rawValues)
        XCTAssertNil(equalizer.settings)
        XCTAssertFalse(equalizer.canEdit)
        for steps: UInt8 in [0, 1] {
            XCTAssertNil(prepared(steps: steps).flatSettings)
        }
    }

    func testULTWritesPreserveTheOtherFieldsAndClearBassStoresAnUnshiftedLevel() throws {
        var equalizer = SonyEqualizer(supportedFunctions: [0x53])
        XCTAssertEqual(equalizer.queryPayloads, [[0x50, 3, 1], [0x52, 3], [0x5A, 3], [0x56, 3]])
        XCTAssertTrue(equalizer.update([0x51, 3, 3, 21, 4, 3, 0, 0, 0x10, 0, 0xA1, 0]))
        XCTAssertTrue(equalizer.update([0x5B, 3, 3, 1, 1, 0x90, 0x10, 0, 1, 2, 0, 2]))
        XCTAssertTrue(equalizer.update([0x53, 3, 0]))
        XCTAssertFalse(equalizer.canSelectPreset)
        XCTAssertTrue(equalizer.update([0x57, 3, 0x10, 2, 3, 0, 19, 10]))
        XCTAssertTrue(equalizer.canEdit)
        XCTAssertFalse(equalizer.requiresManualSelection)
        XCTAssertEqual(equalizer.clearBassIndex, 1)
        var curve = try XCTUnwrap(equalizer.settings)
        XCTAssertEqual(curve.values, [-10, 9, 0])
        XCTAssertEqual(equalizer.displayedLevel(curve[0], at: 0), -10)
        XCTAssertEqual(equalizer.displayedLevel(curve[1], at: 1), 10)
        XCTAssertEqual(equalizer.settingLevel(5, at: 1), 1)
        XCTAssertEqual(equalizer.settingLevel(-9, at: 1), -10)
        let mode = try XCTUnwrap(equalizer.ultModePayload(.off))
        XCTAssertEqual(mode, [0x58, 3, 0x10, 0, 3, 0, 19, 10])
        XCTAssertTrue(equalizer.acceptsSetPayload(mode, changingULTMode: true))
        XCTAssertFalse(equalizer.acceptsSetPayload(mode))
        let preset = try XCTUnwrap(equalizer.presetPayload(0))
        XCTAssertEqual(preset, [0x58, 3, 0, 2, 0])
        XCTAssertTrue(equalizer.confirms(equalizer.confirmationValue(preset),
                                         value: equalizer.confirmationValue([0x59, 3, 0, 2, 3, 5, 8, 9])))
        XCTAssertFalse(equalizer.confirms(equalizer.confirmationValue(preset),
                                          value: equalizer.confirmationValue([0x59, 3, 0, 1, 3, 5, 8, 9])))
        XCTAssertFalse(equalizer.confirms(equalizer.confirmationValue(mode),
                                          value: equalizer.confirmationValue([0x59, 3, 0x10, 0, 3, 0, 18, 10])))
        curve[1] = equalizer.settingLevel(5, at: 1)
        XCTAssertEqual(equalizer.settingsPayload(curve), [0x58, 3, 0x10, 2, 3, 0, 11, 10])
        XCTAssertFalse(equalizer.acceptsSetPayload([0x58, 3, 0x10, 1, 3, 0, 11, 10]))

        XCTAssertTrue(equalizer.update([0x5B, 3, 3, 0x10, 0, 1, 0x10, 0, 1, 2, 0, 2]))
        XCTAssertNil(equalizer.clearBassIndex)
        XCTAssertEqual(equalizer.displayedLevel(9, at: 1), 9)
        XCTAssertTrue(equalizer.update([0x59, 3, 0xA1, 2, 0]))
        XCTAssertNil(equalizer.rawValues)
        XCTAssertNil(equalizer.settings)
        XCTAssertNil(equalizer.ultModePayload(.ult1))
        XCTAssertFalse(equalizer.update([0x59, 3, 0xA1, 2, 128] + Array(repeating: 0, count: 128)))
        XCTAssertFalse(equalizer.update([0x55, 3, 0, 0]))
        XCTAssertTrue(equalizer.update([0x55, 3, 1]))
        XCTAssertFalse(equalizer.canSelectPreset)
        XCTAssertFalse(equalizer.acceptsSetPayload(preset))
        XCTAssertTrue(equalizer.update([0x55, 3, 0]))
        XCTAssertTrue(equalizer.update([0x59, 3, 0xA1, 255, 3, 7, 8, 9]))
        XCTAssertNil(equalizer.ultMode)
        XCTAssertNil(equalizer.presetPayload(0))
    }

    private func prepared(layout: [SonyEqualizerBand] = SonyEqualizerBand.legacy, steps: UInt8 = 21,
                          type: UInt8 = 0, generation: SonyProtocolInfo.Generation = .v2,
                          advertisedBandCount: UInt8? = nil) -> SonyEqualizer {
        let function: UInt8 = generation == .v1 ? 0x51 : type == 4 ? 0x57 : type == 2 ? 0x52 : 0x50
        var equalizer = SonyEqualizer(supportedFunctions: [function], generation: generation)
        XCTAssertTrue(equalizer.update([0x51, type, advertisedBandCount ?? UInt8(layout.count), steps, 2, 0, 0, 0xA0, 0]))
        let metadata: [UInt8] = layout.flatMap { [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)] }
        XCTAssertTrue(equalizer.update([0x5B, type, UInt8(layout.count)] + metadata))
        XCTAssertTrue(equalizer.update(type == 4 ? [0x53, type, 0, 0] : [0x53, type, 0]))
        XCTAssertTrue(equalizer.update([0x57, type, 0xA0, UInt8(layout.count)]
            + Array(repeating: steps > 0 ? (steps - 1) / 2 : 0, count: layout.count)))
        return equalizer
    }
}
