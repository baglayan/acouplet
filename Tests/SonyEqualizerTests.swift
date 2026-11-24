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

    func testEmptyMetadataInvalidStepsAndULTNeverBecomeOrdinaryWritableEQ() {
        var equalizer = prepared()
        XCTAssertTrue(equalizer.update([0x5B, 0, 0]))
        XCTAssertEqual(equalizer.bandInformation, [])
        XCTAssertNotNil(equalizer.rawValues)
        XCTAssertNil(equalizer.settings)
        XCTAssertFalse(equalizer.canEdit)
        for steps: UInt8 in [0, 1] {
            XCTAssertNil(prepared(steps: steps).flatSettings)
        }
        var ult = SonyEqualizer(supportedFunctions: [0x53])
        XCTAssertTrue(ult.update([0x51, 3, 6, 21, 5, 2, 0, 0, 0xA0, 0]))
        XCTAssertEqual(ult.inquiryType, 3)
        XCTAssertEqual(ult.capabilities?.ultAdditionalSteps, 5)
        XCTAssertEqual(ult.capabilities?.presets.map(\.id), [0, 0xA0])
        XCTAssertEqual(ult.queryPayloads, [[0x50, 3, 1]])
        XCTAssertNil(ult.parameterQueryPayload)
        XCTAssertFalse(ult.update([0x53, 3, 0]))
        XCTAssertFalse(ult.update([0x57, 3, 0xA0, 6, 10, 10, 10, 10, 10, 10]))
        XCTAssertNil(ult.presetPayload(0))
        XCTAssertNil(ult.settingsPayload(.flat))
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
