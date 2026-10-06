import Foundation
import CoreBluetooth
import AppKit
import XCTest
@testable import Acouplet

final class SonyProtocolTests: XCTestCase {
    #if ACOUPLET_NO_SONY_ARTWORK
    private let expectsProductArtwork = false
    #else
    private let expectsProductArtwork = true
    #endif

    func testReconnectBackoffCapsAtThirtySeconds() {
        XCTAssertEqual((0...6).map(ReconnectBackoff.delay), [2, 4, 8, 15, 30, 30, 30])
    }

    func testFrameRoundTripIncludingEscapedBytes() {
        let payload: [UInt8] = [0x68, 0x3C, 0x3D, 0x3E, 0x01]
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 1, payload: payload)
        XCTAssertEqual(SonyFrameCodec.decode(encoded), SonyFrame(type: 0x0C, sequence: 1, payload: payload))
    }

    func testStreamReassemblesSplitFrames() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x00, 0x00])
        var stream = SonyFrameStream()
        XCTAssertTrue(stream.append(encoded.prefix(3)).isEmpty)
        XCTAssertEqual(stream.append(encoded.dropFirst(3)).first?.payload, [0x00, 0x00])
    }

    func testRejectsInvalidFrameSequence() {
        let encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 255, payload: [0x23, 0x00, 50, 0])
        XCTAssertNil(SonyFrameCodec.decode(encoded))
    }

    func testStreamRecoversFromNoiseAndUnterminatedFrames() {
        let expected = SonyFrame(type: 0x0C, sequence: 0, payload: [0x3C, 0x3D, 0x3E])
        let encoded = SonyFrameCodec.encode(type: expected.type, sequence: expected.sequence, payload: expected.payload)
        var stream = SonyFrameStream()
        XCTAssertTrue(stream.append(Data(repeating: 0, count: 100_000)).isEmpty)
        XCTAssertTrue(stream.append(Data([SonyFrameCodec.header, 0, 0])).isEmpty)
        XCTAssertEqual(stream.append(encoded + encoded), [expected, expected])
        XCTAssertTrue(stream.append(Data([SonyFrameCodec.header])).isEmpty)
        for _ in 0..<20 {
            XCTAssertTrue(stream.append(Data(repeating: 0, count: 65_536)).isEmpty)
        }
        XCTAssertEqual(stream.append(encoded), [expected])
    }

    func testStreamRejectsOversizedFramesButAcceptsFollowingFrame() {
        let oversized = SonyFrameCodec.encode(type: 0x0C, sequence: 0,
                                             payload: [UInt8](repeating: 0, count: SonyFrameStream.maximumFrameLength))
        let valid = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x06, 0])
        var stream = SonyFrameStream()
        XCTAssertEqual(stream.append(oversized + valid).map(\.payload), [[0x06, 0]])
    }

    func testRejectsBadChecksum() {
        var encoded = SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x06, 0x00])
        encoded[encoded.count - 2] ^= 0x01
        XCTAssertNil(SonyFrameCodec.decode(encoded))
    }

    func testEqualizerPresetProtocolValues() {
        XCTAssertEqual(EqualizerPreset.off.rawValue, 0x00)
        XCTAssertEqual(EqualizerPreset.bassBoost.rawValue, 0x16)
        XCTAssertEqual(EqualizerPreset.manual.rawValue, 0xA0)
        XCTAssertFalse(EqualizerPreset.selectableCases.contains(.manual))
    }

    func testCustomEqualizerPayloadRoundTripAndClamping() {
        let settings = EqualizerSettings(clearBass: 12, bands: [-12, -4, 0, 6, 14])
        XCTAssertEqual(settings, EqualizerSettings(clearBass: 10, bands: [-10, -4, 0, 6, 10]))
        XCTAssertEqual(settings.sonySetPayload, [0x58, 0x00, 0xA0, 0x06, 20, 0, 6, 10, 16, 20])

        let response = [UInt8(0x57)] + Array(settings.sonySetPayload.dropFirst())
        XCTAssertEqual(EqualizerSettings(sonyPayload: response), settings)
    }
    func testDeviceIdentitySelectsEarbudArtwork() {
        let earbuds = SonyDeviceModel(name: "Listener’s WF-1000XM5")
        XCTAssertEqual(earbuds, .wfXM5)
        XCTAssertEqual(earbuds.artwork, expectsProductArtwork ? "WFXM5Hero" : nil)
        XCTAssertEqual(SonyDeviceModel(name: "wh-1000xm5").artwork, expectsProductArtwork ? "XM5Hero" : nil)
        XCTAssertNil(SonyDeviceModel(name: "Other headphones").artwork)
    }

    func testFinishArtworkMatchesOnlySourceDerivedModelAndColorPairs() {
        let nonblack: [SonyDeviceModel: [UInt8: String]] = [
            .wfXM5: [0x03: "Silver"], .wfXM4: [0x03: "Silver"],
            .whXM5: [0x03: "Silver"], .whXM4: [0x03: "Silver"], .whXM3: [0x03: "Silver"],
            .whCH720N: [0x02: "White", 0x05: "Blue", 0x06: "Pink"]
        ]
        let artworkModels: Set<SonyDeviceModel> = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                                   .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        var recognized = 0
        for model in SonyDeviceModel.allCases {
            XCTAssertNil(model.artworkSuffix(for: nil))
            for raw in UInt8.min...UInt8.max {
                let expected = artworkModels.contains(model) && raw == 0x01 ? "" : nonblack[model]?[raw]
                let suffix = model.artworkSuffix(for: SonyDeviceColor(rawValue: raw))
                XCTAssertEqual(suffix, expected, "\(model.name) color \(raw)")
                if suffix != nil { recognized += 1 }
            }
        }
        XCTAssertEqual(recognized, 19)
    }

    @MainActor
    func testMenuBarEarbudsKeepTheirIntrinsicSize() {
        let models: [(SonyDeviceModel, CGFloat)] = [(.wfXM5, 22), (.wfXM6, 25), (.wfXM4, 24), (.wfXM3, 27)]
        for (model, width) in models {
            let image = DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true)
            XCTAssertEqual(image.size, NSSize(width: width, height: 18), model.name)
            XCTAssertTrue(image.isTemplate)
        }
    }

    @MainActor
    func testChargingCaseIconsAndOfficialArtworkAreAvailable() throws {
        for model in [SonyDeviceModel.wfXM5, .wfXM6] {
            let image = DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true, chargingCase: true)
            let symbol = try XCTUnwrap(NSImage(named: try XCTUnwrap(model.caseSymbol)))
            XCTAssertEqual(image.size, symbol.size)
            XCTAssertEqual(image.tiffRepresentation, symbol.tiffRepresentation)
            XCTAssertTrue(image.isTemplate)
        }
        for asset in ["wfXM5OpenCaseProduct", "wfXM5OpenCaseProductSilver", "wfXM5OpenCaseProductSmokyPink", "wfXM6OpenCaseProduct", "wfXM6OpenCaseProductSilver"] {
            XCTAssertEqual(NSImage(named: asset) != nil, expectsProductArtwork, asset)
        }
    }

    @MainActor
    func testMenuBarBatteryWarningsKeepEachSideSeparate() throws {
        XCTAssertNil(DeviceIcon.batteryColor(for: nil))
        for level: UInt8 in [0, 9, 10, 19, 20, 21, 100] {
            let expected: NSColor? = level <= 20 ? .systemRed : nil
            XCTAssertEqual(DeviceIcon.batteryColor(for: BatteryReading(level: level, charging: 0)), expected)
        }
        let batteries = SonyBatteries(left: BatteryReading(level: 20, charging: 0), right: BatteryReading(level: 21, charging: 0))
        let image = DeviceIcon.menuBarImage(model: .wfXM5, leftConnected: true, rightConnected: true, batteries: batteries)
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 22, height: 18))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
                pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            var redLeft = 0, redRight = 0, yellowLeft = 0, yellowRight = 0
            var healthyRight = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    guard color.alphaComponent > 0.8 else { continue }
                    if color.redComponent > 0.7 && color.greenComponent < 0.5 {
                        if x < bitmap.pixelsWide / 2 { redLeft += 1 } else { redRight += 1 }
                    }
                    if color.redComponent > 0.7 && color.greenComponent > 0.6 && color.blueComponent < 0.5 {
                        if x < bitmap.pixelsWide / 2 { yellowLeft += 1 } else { yellowRight += 1 }
                    }
                    let healthyColor = appearance == .darkAqua
                        ? color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.7
                        : color.redComponent < 0.3 && color.greenComponent < 0.3 && color.blueComponent < 0.3
                    if x >= bitmap.pixelsWide / 2, healthyColor {
                        healthyRight += 1
                    }
                }
            }
            XCTAssertGreaterThan(redLeft, 0)
            XCTAssertEqual(yellowRight, 0)
            XCTAssertEqual(redRight, 0)
            XCTAssertEqual(yellowLeft, 0)
            XCTAssertGreaterThan(healthyRight, 0, appearance.rawValue)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "WF warning colors — \(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(DeviceIcon.menuBarImage(model: .wfXM5, leftConnected: false, rightConnected: false, batteries: batteries).isTemplate)
        XCTAssertFalse(DeviceIcon.menuBarImage(model: .whXM5, leftConnected: nil, rightConnected: nil,
            batteries: SonyBatteries(single: BatteryReading(level: 9, charging: 0))).isTemplate)
        for mode in NoiseControlMode.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil), mode.symbol)
        }
    }

    @MainActor
    func testGenericEarbudIconsPreservePerEarWarningsAndConnectionOpacity() throws {
        for model in [SonyDeviceModel.wfL900, .wfG700N] {
            let batteries = SonyBatteries(left: BatteryReading(level: 20, charging: 0), right: BatteryReading(level: 80, charging: 0))
            let image = DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true, batteries: batteries)
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            var red = [0, 0]
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.8, color.redComponent > 0.7, color.greenComponent < 0.5 {
                        red[x < bitmap.pixelsWide / 2 ? 0 : 1] += 1
                    }
                }
            }
            XCTAssertGreaterThan(red[0], 0, model.name)
            XCTAssertEqual(red[1], 0, model.name)
            let disconnected = DeviceIcon.menuBarImage(model: model, leftConnected: false, rightConnected: true, batteries: batteries)
            XCTAssertTrue(disconnected.isTemplate)
            let dimmed = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(disconnected.tiffRepresentation)))
            var opacity: [CGFloat] = [0, 0]
            for x in 0..<dimmed.pixelsWide {
                for y in 0..<dimmed.pixelsHigh {
                    let side = x < dimmed.pixelsWide / 2 ? 0 : 1
                    opacity[side] = max(opacity[side], try XCTUnwrap(dimmed.colorAt(x: x, y: y)).alphaComponent)
                }
            }
            XCTAssertGreaterThan(opacity[0], 0)
            XCTAssertLessThanOrEqual(opacity[0], 0.36)
            XCTAssertGreaterThan(opacity[1], 0.8)
            XCTAssertTrue(DeviceIcon.menuBarImage(model: model, leftConnected: true, rightConnected: true, chargingCase: true).isTemplate)
        }
        for model in [SonyDeviceModel.wiC100, .srsULT10] {
            XCTAssertFalse(DeviceIcon.menuBarImage(model: model, leftConnected: nil, rightConnected: nil,
                batteries: SonyBatteries(single: BatteryReading(level: 20, charging: 0))).isTemplate)
        }
    }

    func testDistinctSonyFamilyIdentitiesAndSymbols() {
        let models: [SonyDeviceModel] = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                        .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        XCTAssertEqual(Set(models.compactMap(\.symbol)).count, models.count)
        for model in models {
            XCTAssertEqual(SonyDeviceModel(name: model.name), model)
            XCTAssertEqual(SonyDeviceModel(name: "LE_" + model.name), model)
            XCTAssertEqual(model.caseSymbol != nil, model.isEarbuds)
            XCTAssertEqual(model.leftSymbol != nil, model.isEarbuds)
            XCTAssertEqual(model.rightSymbol != nil, model.isEarbuds)
            XCTAssertEqual(model.systemSymbol, model.isEarbuds ? "earbuds.stemless" : "headphones")
        }
        XCTAssertEqual(SonyDeviceModel(name: "WH-ULT900N"), .whULT900N)
        XCTAssertEqual(SonyDeviceModel(name: "WH-1000XX"), .wh1000XX)
        XCTAssertEqual(SonyDeviceModel(name: "WH-1000XM4C"), .whXM4C)
        XCTAssertEqual(SonyDeviceModel(name: "WF-1000XM50"), .unknown)
        XCTAssertEqual(SonyDeviceModel(name: "WF-1000XM5 WH-1000XM5"), .unknown)
        XCTAssertEqual(SonyDeviceModel(name: "NotWF-1000XM5"), .unknown)
    }

    func testRequestedSonyModelsHaveDistinctIdentitiesAndFormFactors() {
        let groups: [(SonyDeviceModel.FormFactor, [SonyDeviceModel])] = [
            (.earbuds, [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .wf1000X,
                        .wfL900, .wfLC900, .wfLS910N, .wfL910, .wfLS900N, .wfL900UC,
                        .wfC500, .wfC510, .wfC700N, .wfC710N, .wfH800, .wfSP700N, .wfSP800N, .wfSP900, .wfG700N]),
            (.onEarHeadphones, [.whCH520, .whCH530, .whCH535, .whH800, .whH810, .whXB700]),
            (.overEarHeadphones, [.whXM6, .whXM5, .whXM4, .whXM4C, .whXM3, .whXM2, .wh1000XX,
                                 .whCH700N, .whCH720N, .whCH730N, .whCH735N, .whH900N, .whH910N,
                                 .whXB900N, .whXB910N, .whULT900N, .mdrXB950B1, .mdrXB950N1, .whG910N]),
            (.neckbandEarbuds, [.wi1000X, .wi1000XM2, .wiC100, .wiC600N, .wiH700, .wiSP600N]),
            (.neckbandSpeaker, [.htAN7, .srsNS7, .srsNS7R]),
            (.portableSpeaker, [.srsLS1, .srsULT10, .srsULT30, .srsULT50, .srsULT70]),
            (.towerSpeaker, [.srsULT500, .srsULT700, .srsULT900, .srsULT900AC, .srsULT1000, .srsULT3000])
        ]
        let models = groups.flatMap { $0.1 }
        XCTAssertEqual(models.count, 65)
        XCTAssertEqual(Set(models).count, 65)
        XCTAssertEqual(Set(SonyDeviceModel.allCases), Set(models + [.unknown]))
        for (formFactor, models) in groups {
            for model in models {
                XCTAssertEqual(model.formFactor, formFactor, model.name)
                XCTAssertEqual(model.isEarbuds, formFactor == .earbuds, model.name)
                XCTAssertEqual(model.isSpeaker, [.neckbandSpeaker, .portableSpeaker, .towerSpeaker].contains(formFactor), model.name)
                XCTAssertEqual(SonyDeviceModel(name: model.name.lowercased()), model)
                XCTAssertEqual(SonyDeviceModel(name: "LE_" + model.name), model)
                XCTAssertEqual(SonyDeviceModel(name: "Listener’s " + model.name), model)
                XCTAssertEqual(SonyDeviceModel(name: "Not" + model.name), .unknown)
                XCTAssertEqual(SonyDeviceModel(name: model.name + "Z"), .unknown)
            }
        }
        let artworkModels: Set<SonyDeviceModel> = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                                   .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        for model in SonyDeviceModel.allCases where !artworkModels.contains(model) {
            XCTAssertNil(model.artwork, model.name)
            #if DEBUG
            XCTAssertTrue(model.galleryArtworkFinishes.isEmpty, model.name)
            #endif
        }
        XCTAssertEqual(SonyDeviceModel.wi1000X.systemSymbol, "earbuds.stemless")
        XCTAssertEqual(SonyDeviceModel.srsULT900.systemSymbol, "hifispeaker")
        XCTAssertEqual(SonyDeviceModel.htAN7.systemSymbol, "hifispeaker")
        XCTAssertEqual(SonyDeviceModel.unknown.systemSymbol, "speaker.wave.2")
    }

    func testAllRecognizedModelsHaveBundledCustomMiniIcons() throws {
        let models = SonyDeviceModel.allCases.filter { $0 != .unknown }
        XCTAssertEqual(models.count, 65)
        XCTAssertEqual(Set(models.compactMap(\.symbol)).count, models.count)
        for model in models {
            let symbol = try XCTUnwrap(model.symbol, model.name)
            XCTAssertNotNil(NSImage(named: symbol), symbol)
            if model.isEarbuds {
                let left = try XCTUnwrap(model.leftSymbol, model.name)
                let right = try XCTUnwrap(model.rightSymbol, model.name)
                let chargingCase = try XCTUnwrap(model.caseSymbol, model.name)
                let filledCase = try XCTUnwrap(model.filledCaseSymbol, model.name)
                XCTAssertNotEqual(left, right, model.name)
                XCTAssertTrue(left.hasSuffix("EarbudLeft"), left)
                XCTAssertTrue(right.hasSuffix("EarbudRight"), right)
                for name in [left, right, chargingCase, filledCase] {
                    XCTAssertNotNil(NSImage(named: name), name)
                }
            } else {
                XCTAssertNil(model.leftSymbol, model.name)
                XCTAssertNil(model.rightSymbol, model.name)
                XCTAssertNil(model.caseSymbol, model.name)
            }
        }
        XCTAssertNil(SonyDeviceModel.unknown.symbol)
    }

    func testSonyCommercialNamesDoNotCollideAcrossFamilies() {
        let aliases: [String: SonyDeviceModel] = [
            "LinkBuds": .wfL900, "LinkBuds Clip": .wfLC900, "LinkBuds Fit": .wfLS910N,
            "LinkBuds Open": .wfL910, "LinkBuds S": .wfLS900N, "LinkBuds UC": .wfL900UC,
            "LinkBuds Speaker": .srsLS1, "INZONE Buds": .wfG700N, "INZONE H9 II": .whG910N,
            "BRAVIA Theatre U": .htAN7, "ULT FIELD 1": .srsULT10, "ULT FIELD 3": .srsULT30,
            "ULT FIELD 5": .srsULT50, "ULT FIELD 7": .srsULT70, "ULT TOWER 5": .srsULT500,
            "ULT TOWER 7": .srsULT700, "ULT TOWER 9": .srsULT900, "ULT TOWER 9AC": .srsULT900AC,
            "ULT TOWER 10": .srsULT1000, "ULT TOWER MAX": .srsULT3000,
            "ULT WEAR": .whULT900N, "1000X THE COLLEXION": .wh1000XX
        ]
        for (name, model) in aliases {
            XCTAssertEqual(SonyDeviceModel(name: name), model)
            XCTAssertEqual(SonyDeviceModel(name: "LE_" + name), model)
            XCTAssertEqual(SonyDeviceModel(name: "Listener’s " + name), model)
        }
        for name in ["LinkBuds S2", "LinkBuds Unknown", "ULT TOWER 90", "INZONE H9",
                     "WH-1000XM4CC", "SRS-ULT900AC2", "SRS-NS7R2", "WH-CH5350",
                     "WH-CH530 series", "LE_WH-CH530 series", "WH-CH730N series", "LE_WH-CH730N series",
                     "WH-1000XM4 WH-1000XM4C", "LinkBuds S WF-L900",
                     "WF-LS900N LinkBuds Fit", "WF-1000XM5 SRS-ULT10"] {
            XCTAssertEqual(SonyDeviceModel(name: name), .unknown, name)
        }
        XCTAssertEqual(SonyDeviceModel(name: "LinkBuds S (WF-LS900N)"), .wfLS900N)
        XCTAssertEqual(SonyDeviceModel(name: "ULT TOWER 9AC (SRS-ULT900AC)"), .srsULT900AC)
    }

    func testSonyModelNameBoundariesHandleUnicodeAndRepeatedAliases() {
        let names: [String: SonyDeviceModel] = [
            "🎧 WF-1000XM5": .wfXM5, "ß WF-1000XM5": .wfXM5,
            "NotWF-1000XM5 / WF-1000XM5": .wfXM5,
            "WF-1000XM5 / WF-1000XM5": .wfXM5, "WF-1000XM5_custom": .wfXM5,
            "WH-CH530\tSERIES": .unknown, "WH-CH530 SERIES2": .whCH530,
            "LinkBuds\tS": .unknown
        ]
        for (name, model) in names {
            XCTAssertEqual(SonyDeviceModel(name: name), model, name)
        }
    }

    func testProtocolGenerationComesFromTheNegotiatedResponse() {
        let legacy = SonyProtocolInfo(payload: [0x01, 0, 0x02, 0x10])
        XCTAssertEqual(legacy?.generation, .v1)
        XCTAssertEqual(legacy?.version, 0x0210)
        XCTAssertEqual(legacy?.supportsTable1, true)
        XCTAssertEqual(legacy?.supportsTable2, false)
        let current = SonyProtocolInfo(payload: [0x01, 0, 0x03, 0, 0x30, 0x18, 0, 1])
        XCTAssertEqual(current?.generation, .v2)
        XCTAssertEqual(current?.version, 0x03003018)
        XCTAssertEqual(current?.supportsTable2, false)
        for malformed: [UInt8] in [[], [0x01, 0, 3], [0x01, 0, 3, 0, 1], [0x01, 0, 3, 0, 0, 0, 2, 0]] {
            XCTAssertNil(SonyProtocolInfo(payload: malformed))
        }
    }

    func testReportedModelAndColorPreserveUnknownAndDefaultValues() {
        var info = SonyDeviceInformation()
        XCTAssertNil(info.model)
        XCTAssertNil(info.color)
        let name = Array("WF-1000XM6".utf8)
        XCTAssertTrue(info.update([0x05, 0x01, UInt8(name.count)] + name))
        XCTAssertEqual(info.model, .wfXM6)
        XCTAssertTrue(info.update([0x05, 0x03, 0x30, 0x00]))
        XCTAssertEqual(info.series, 0x30)
        XCTAssertEqual(info.color?.rawValue, 0)
        XCTAssertEqual(info.color?.title, String(localized: "Default"))
        XCTAssertTrue(info.update([0x05, 0x03, 0x11, 0x11]))
        XCTAssertEqual(info.color?.title, String(localized: "Black") + "-I")
        XCTAssertTrue(info.update([0x05, 0x03, 0xFF, 0xFF]))
        XCTAssertEqual(info.series, 0xFF)
        XCTAssertEqual(info.color?.rawValue, 0xFF)
        XCTAssertEqual(info.color?.title, String(format: String(localized: "Unknown (0x%02X)"), 0xFF))
        let previous = info
        for malformed: [UInt8] in [[0x05, 0x03, 1], [0x05, 0x03, 1, 2, 3],
                                    [0x05, 0x01, 2, 0xFF, 0xFE], [0x05, 0x01, 1, 0],
                                    [0x05, 0x01, 2, 65], [0x05, 0x01, 0]] {
            XCTAssertFalse(info.update(malformed))
            XCTAssertEqual(info, previous)
        }
        let unrecognized = Array("Future Sony headphones".utf8)
        XCTAssertTrue(info.update([0x05, 0x01, UInt8(unrecognized.count)] + unrecognized))
        XCTAssertEqual(info.model, .unknown)
    }

    func testBatteryQueriesFollowAdvertisedTopologyAndThresholdVariant() {
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: []), [])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x20]), [0x00])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x21, 0x22]), [0x01, 0x02])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x28, 0x29, 0x2A]), [0x08, 0x09, 0x0A])
        XCTAssertEqual(SonyBatteries.queryTypes(supportedFunctions: [0x20, 0x28, 0x21, 0x29, 0x22, 0x2A]), [0x00, 0x01, 0x02])
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x01, 70, 0, 80, 1]))
        XCTAssertEqual(batteries.left?.level, 70)
        XCTAssertEqual(batteries.right?.level, 80)
        XCTAssertTrue(batteries.update([0x25, 0x02, 90, 0]))
        XCTAssertEqual(batteries.caseBattery?.level, 90)
        XCTAssertTrue(batteries.update([0x23, 0x09, 71, 0, 81, 1, 20, 20]))
        XCTAssertTrue(batteries.update([0x23, 0x0A, 91, 0, 20]))
        XCTAssertEqual(batteries.left?.level, 71)
        XCTAssertEqual(batteries.caseBattery?.level, 91)
        XCTAssertTrue(batteries.update([0x23, 0x08, 65, 0, 20]))
        XCTAssertEqual(batteries.single?.level, 65)
        XCTAssertNil(batteries.left)
        XCTAssertNil(batteries.right)
        XCTAssertFalse(batteries.update([0x23, 0x01, 10, 0, 20]))
    }

    func testEarbudBatteryRepliesNotificationsAndUnavailableEarbud() {
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x09, 78, 0, 82, 1]))
        XCTAssertEqual(batteries.left?.level, 78)
        XCTAssertEqual(batteries.right?.level, 82)
        XCTAssertEqual(batteries.right?.isCharging, true)
        XCTAssertEqual(batteries.level, 78)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 64, 0]))
        XCTAssertEqual(batteries.caseBattery?.level, 64)
        XCTAssertEqual(batteries.level, 78)
        XCTAssertTrue(batteries.update([0x25, 0x09, 255, 0, 62, 0]))
        XCTAssertNil(batteries.left)
        XCTAssertEqual(batteries.level, 62)
        XCTAssertTrue(batteries.update([0x25, 0x09, 0, 0, 32, 0]))
        XCTAssertNil(batteries.left)
        XCTAssertEqual(batteries.level, 32)
        XCTAssertFalse(batteries.isCharging)
    }

    func testBatteryParserRejectsTruncatedAndUnrelatedPackets() {
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x23, 0x00, 45, 1]))
        let previous = batteries
        for packet: [UInt8] in [[], [0x23], [0x23, 0x09, 45, 0], [0x57, 0x00, 12, 0], [0x23, 0xFF, 12, 0]] {
            XCTAssertFalse(batteries.update(packet))
            XCTAssertEqual(batteries, previous)
        }
        XCTAssertTrue(batteries.update([0x25, 0x00, 255, 0]))
        XCTAssertNil(batteries.level)
        XCTAssertNil(BatteryReading(level: 50, charging: 7))
    }

    func testBatteryChargingStatesPreserveUnknownAndChargedLevelsAcrossV2Topologies() {
        for command: UInt8 in [0x23, 0x25] {
            for type: UInt8 in [0x00, 0x08, 0x02, 0x0A] {
                for state: UInt8 in [2, 3] {
                    var batteries = SonyBatteries()
                    let payload = [command, type, 73, state] + (type >= 8 ? [20] : [])
                    XCTAssertTrue(batteries.update(payload))
                    let reading = type == 0 || type == 8 ? batteries.single : batteries.caseBattery
                    XCTAssertEqual(reading?.level, 73)
                    XCTAssertEqual(reading?.chargingState, state == 2 ? .unknown : .charged)
                    XCTAssertEqual(reading?.isCharging, false)
                }
            }
            for type: UInt8 in [0x01, 0x09] {
                var batteries = SonyBatteries()
                let payload = [command, type, 73, 2, 84, 3] + (type == 9 ? [20, 20] : [])
                XCTAssertTrue(batteries.update(payload))
                XCTAssertEqual(batteries.left?.level, 73)
                XCTAssertEqual(batteries.left?.chargingState, .unknown)
                XCTAssertEqual(batteries.right?.level, 84)
                XCTAssertEqual(batteries.right?.chargingState, .charged)
                XCTAssertFalse(batteries.isCharging)
            }
        }
    }

    func testBatteryChargingStateWireValuesRemainSpecificToProtocolGeneration() {
        XCTAssertEqual(BatteryReading(level: 0, charging: 0xF0, generation: .v1)?.chargingState, .unknown)
        XCTAssertNil(BatteryReading(level: 50, charging: 0xF0))
        XCTAssertNil(BatteryReading(level: 50, charging: 2, generation: .v1))
        XCTAssertNil(BatteryReading(level: 50, charging: 3, generation: .v1))
        XCTAssertNil(BatteryReading(level: 101, charging: 3))
        XCTAssertNil(BatteryReading(level: 50, charging: 0xFF))
        XCTAssertEqual(BatteryReading(level: 50, charging: 1)?.isCharging, true)
        XCTAssertEqual(BatteryReading(level: 50, charging: 1, generation: .v1)?.isCharging, true)
    }

    @MainActor
    func testBluetoothInitializationDoesNotBlockLaunchOrRepeatDuringRefresh() async {
        for authorization: CBManagerAuthorization in [.notDetermined, .allowedAlways] {
            let started = expectation(description: "Bluetooth initialization started")
            let finished = expectation(description: "Bluetooth initialization finished")
            let permissionResponse = DispatchSemaphore(value: 0)
            var controller: SonyHeadphonesController? = SonyHeadphonesController(startAutomatically: false)
            controller?.start(authorization: { authorization }) {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                XCTAssertEqual(permissionResponse.wait(timeout: .now() + 5), .success)
                finished.fulfill()
            }
            await fulfillment(of: [started], timeout: 2)
            controller?.refresh()
            controller?.connect()
            controller?.start(initializeBluetooth: { XCTFail("Initialization must run only once") })
            XCTAssertEqual(controller?.linkState, .searching)
            XCTAssertEqual(controller?.statusText, authorization == .notDetermined ? String(localized: "Waiting for Bluetooth permission…") : String(localized: "Searching…"))
            XCTAssertEqual(controller?.address, "")
            XCTAssertNil(controller?.controlChannelID)
            weak var pendingController = controller
            controller = nil
            XCTAssertNil(pendingController)
            permissionResponse.signal()
            await fulfillment(of: [finished], timeout: 2)
        }
    }

    @MainActor
    func testDeniedBluetoothAuthorizationDoesNotContinueToDeviceDiscovery() async {
        for authorization: CBManagerAuthorization in [.denied, .restricted] {
            let stopped = expectation(description: "Bluetooth access denied")
            let controller = SonyHeadphonesController(startAutomatically: false)
            let observation = controller.$linkState.sink { state in
                if state == .failed(String(localized: "Bluetooth access is not allowed.")) { stopped.fulfill() }
            }
            controller.start(authorization: { authorization }, initializeBluetooth: {})
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertEqual(controller.statusText, String(localized: "Bluetooth access is not allowed."))
            XCTAssertEqual(controller.address, "")
            XCTAssertFalse(controller.isReady)
            observation.cancel()
        }
    }

    @MainActor
    func testOfflineSimulationCannotOpenBluetooth() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.start()
        controller.setReconnectAutomatically(true)
        controller.refresh()
        controller.connect()
        XCTAssertEqual(controller.linkState, .disconnected)
        XCTAssertEqual(controller.address, "")
        XCTAssertNil(controller.controlChannelID)
    }

    @MainActor
    func testBluetoothStartupHonorsSavedAutomaticReconnectPreference() throws {
        let suite = "dev.baglayan.Acouplet.startup-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for reconnect in [false, true] {
            let saved = SettingsStore(defaults: defaults)
            saved.reconnectAutomatically = reconnect
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateControlLoss()
            let environment = AppEnvironment(settings: SettingsStore(defaults: defaults), headphones: controller,
                                             audioRoute: MacAudioRouteObserver(startAutomatically: false))
            XCTAssertEqual(controller.simulatedReconnectAutomatically, reconnect)
            controller.simulateBluetoothInitialization()
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, reconnect ? [0, 0] : nil)
            XCTAssertEqual(controller.linkState, reconnect ? .handshaking : .disconnected)
            XCTAssertEqual(environment.settings.reconnectAutomatically, reconnect)
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testModeChangeCancelsPendingAmbientSliderWrite() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        controller.setAmbientLevel(14)
        controller.setNoiseControl(.anc)
        let payload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x69] + payload.dropFirst()))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x68 }.count, 1)
    }

    #if DEBUG
    @MainActor
    func testLegacyBLEProtocolDoesNotEnterV2HandshakeOrRetry() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WH-1000XM4", controlBusy: true)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x01, 0, 2, 0x10]),
                                       beginConnection: true, expectedBLEHash: "ABCDEF12")
        XCTAssertEqual(controller.protocolInformation?.generation, .v1)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(controller.statusText, String(localized: "These headphones need a Bluetooth Classic connection for their controls."))
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        XCTAssertNil(controller.retrySecondsRemaining)
        let frames = controller.simulatedTransmittedFrames
        for _ in 0..<5 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(controller.simulatedTransmittedFrames, frames)
        XCTAssertFalse(frames.contains { $0.payload == [0x06, 0] || $0.payload == [0x04, 1] })
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x07, 0, 1, 0x6D, 1]))
        XCTAssertTrue(controller.supportedFunctions.isEmpty)
    }

    @MainActor
    func testOwnedModelReadOverridesAdvertisedIdentityAndResetsWithSession() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        let name = Array("WH-CH720N".utf8)
        let modelReply: [UInt8] = [0x05, 0x01, UInt8(name.count)] + name
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: modelReply))
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0,
                                                            payload: [0x01, 0, 0x03, 0, 0x30, 0x18, 0, 1]), beginConnection: true)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: modelReply))
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x05, 0x03, 0x30, 0x00]))
        XCTAssertEqual(controller.deviceModel, .whCH720N)
        XCTAssertEqual(controller.deviceName, "WF-1000XM5")
        XCTAssertEqual(controller.deviceInformation.color?.title, String(localized: "Default"))
        XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
        controller.simulateControlLoss()
        XCTAssertNil(controller.deviceInformation.modelName)
        XCTAssertNil(controller.deviceInformation.color)
        XCTAssertNil(controller.protocolInformation)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: modelReply))
        XCTAssertNil(controller.deviceInformation.modelName)
    }

    @MainActor
    func testMenuBarVisibilityFollowsPhysicalSupportedDeviceConnection() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        XCTAssertFalse(controller.showsMenuBarIcon)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(controller.showsMenuBarIcon)
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.showsMenuBarIcon)
        controller.simulateDeviceConnection(named: nil)
        XCTAssertFalse(controller.showsMenuBarIcon)
        controller.simulateDeviceConnection(named: "WH-1000XM5")
        XCTAssertTrue(controller.showsMenuBarIcon)
        XCTAssertEqual(controller.deviceModel, .whXM5)
        controller.simulateDeviceConnection(named: "Other headphones")
        XCTAssertFalse(controller.showsMenuBarIcon)
    }

    @MainActor
    func testGalleryModelsKeepImplementedCapabilitiesAndUnknownFinishesSeparate() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let models: [SonyDeviceModel] = [.wfXM6, .wfXM5, .wfXM4, .wfXM3, .whXM6, .whXM5,
                                        .whXM4, .whXM3, .whCH720N, .whULT900N, .wh1000XX]
        for model in models {
            controller.simulateGalleryDevice(model: model)
            let legacy = [.wfXM4, .wfXM3, .whXM4, .whXM3].contains(model)
            XCTAssertEqual(controller.deviceModel, model, model.name)
            XCTAssertTrue(controller.isReady, model.name)
            XCTAssertNil(controller.deviceInformation.color, model.name)
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork, model.name)
            XCTAssertNil(controller.firmwareVersion, model.name)
            XCTAssertEqual(controller.protocolInformation?.generation, legacy ? .v1 : .v2, model.name)
            XCTAssertEqual(controller.legacyControls != nil, legacy, model.name)
            XCTAssertEqual(controller.batteries.left != nil, model.isEarbuds, model.name)
            XCTAssertEqual(controller.batteries.right != nil, model.isEarbuds, model.name)
            XCTAssertEqual(controller.batteries.caseBattery != nil, model.isEarbuds, model.name)
            XCTAssertEqual(controller.batteries.single != nil, !model.isEarbuds, model.name)
            XCTAssertEqual(controller.earTipFit.isSupported, [.wfXM5, .wfXM6].contains(model), model.name)
            XCTAssertEqual(controller.headGesturePractice.isSupported,
                           [.wfXM5, .wfXM6, .whXM6, .wh1000XX].contains(model), model.name)
            XCTAssertEqual(controller.touchAssignments.keys != nil, [.wfXM5, .wfXM6].contains(model), model.name)
            XCTAssertEqual(controller.equalizer.isSupported, ![.whULT900N, .wh1000XX].contains(model), model.name)
            if legacy {
                XCTAssertEqual(controller.equalizer.generation, .v1, model.name)
                XCTAssertEqual(controller.equalizer.inquiryType, 1, model.name)
                XCTAssertEqual(controller.equalizer.capabilities?.bandCount, 6, model.name)
                XCTAssertEqual(controller.equalizer.flatSettings?.levelRange, -10...10, model.name)
                XCTAssertTrue(controller.equalizer.requiresManualSelection, model.name)
                XCTAssertFalse(controller.equalizer.canEdit, model.name)
            }
            if [.wfXM6, .whXM6].contains(model) {
                XCTAssertEqual(controller.equalizer.capabilities?.bandCount, 10, model.name)
            }
            XCTAssertEqual(controller.systemFeatures[.speakToChat] != nil,
                           !legacy && ![.whCH720N, .whULT900N].contains(model), model.name)
            XCTAssertEqual(controller.systemFeatures[.pauseOnRemoval] != nil, !legacy && model != .whCH720N, model.name)
            XCTAssertEqual(controller.systemFeatures.multipoint != nil, !legacy && model != .wfXM6, model.name)
            XCTAssertEqual(controller.audioFeatures.supportedConnectionModes?.contains(.lowLatency) == true,
                           [.wfXM5, .wfXM6, .whXM6, .wh1000XX].contains(model), model.name)
            let dsee: SonyDSEEType = [.wfXM3, .whXM3].contains(model) ? .hx
                : [.whCH720N, .whULT900N].contains(model) ? .dsee : model == .wh1000XX ? .ultimate : .extreme
            XCTAssertEqual(controller.dseeType, dsee, model.name)
            XCTAssertTrue(controller.canSetDSEE, model.name)
            XCTAssertEqual(controller.powerFeatures.batteryCare != nil, [.wfXM6, .wh1000XX].contains(model), model.name)
            XCTAssertEqual(controller.powerFeatures.autoPowerSave != nil, model == .wfXM6, model.name)
            if model == .whCH720N { XCTAssertEqual(controller.systemFeatures.automaticPowerOff?.inquiryType, 0x04) }
            for mode in [NoiseControlMode.off, .anc, .ambient] {
                controller.simulateGalleryDevice(model: model, noiseMode: mode)
                XCTAssertEqual(controller.noiseControlMode, mode, model.name)
                if legacy { XCTAssertEqual(controller.legacyControls?.noiseState?.mode, mode, model.name) }
            }
            XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty, model.name)
        }
        for model in [SonyDeviceModel.wfXM5, .whXM5] {
            controller.simulateGalleryDevice(model: model, color: 1)
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
            controller.simulateGalleryDevice(model: model)
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
            XCTAssertNil(controller.deviceInformation.color)
        }
    }

    @MainActor
    func testFinishGalleryUsesBundledPartsWithoutChangingReportedColor() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let finishes: [(SonyDeviceModel, UInt8, String, [String])] = [
            (.wfXM5, 0x03, "Silver", ["WFXM5FrontSilver", "wfXM5CaseProductSilver"]),
            (.wfXM4, 0x03, "Silver", ["wfXM4ProductSilver", "wfXM4ProductLeftSilver", "wfXM4ProductRightSilver", "wfXM4CaseProductSilver"]),
            (.whXM5, 0x03, "Silver", ["XM5HeroSilver"]),
            (.whXM4, 0x03, "Silver", ["whXM4ProductSilver"]),
            (.whXM3, 0x03, "Silver", ["whXM3ProductSilver"]),
            (.whCH720N, 0x02, "White", ["whCH720NProductWhite"]),
            (.whCH720N, 0x05, "Blue", ["whCH720NProductBlue"]),
            (.whCH720N, 0x06, "Pink", ["whCH720NProductPink"])
        ]
        for (model, color, suffix, assets) in finishes {
            controller.simulateGalleryDevice(model: model, color: color)
            XCTAssertEqual(controller.deviceModel, model)
            XCTAssertEqual(controller.deviceInformation.color?.rawValue, color)
            XCTAssertEqual(controller.deviceInformation.color?.title, String(localized: String.LocalizationValue(suffix)))
            XCTAssertEqual(controller.productArtworkSuffix, suffix)
            for asset in assets { XCTAssertEqual(NSImage(named: asset) != nil, expectsProductArtwork, asset) }
            controller.simulateGalleryDevice(model: model)
            XCTAssertNil(controller.deviceInformation.color)
            XCTAssertEqual(controller.productArtworkSuffix, "")
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
        }
        for (model, color) in [(SonyDeviceModel.wfXM6, UInt8(0x03)), (.whXM5, 0x13), (.whCH720N, 0x00), (.wfXM5, 0xFE)] {
            controller.simulateGalleryDevice(model: model, color: color)
            XCTAssertEqual(controller.deviceInformation.color?.rawValue, color)
            XCTAssertEqual(controller.productArtworkSuffix, "")
            XCTAssertEqual(controller.usesProductArtwork, expectsProductArtwork)
        }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
    }

    @MainActor
    func testNamedVisualFinishGalleryLeavesDeviceColorUnread() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        var count = 0
        for model in SonyDeviceModel.allCases {
            for (finish, suffix) in model.galleryArtworkFinishes {
                controller.simulateGalleryDevice(model: model, visualFinish: finish)
                XCTAssertEqual(controller.productArtworkSuffix, suffix)
                XCTAssertNil(controller.deviceInformation.color)
                let product = model == .wfXM5 ? "WFXM5Front" : model == .whXM5 ? "XM5Hero" : model.rawValue + "Product"
                XCTAssertEqual(NSImage(named: product + suffix) != nil, expectsProductArtwork, "\(model.name) \(finish)")
                if model.isEarbuds {
                    XCTAssertEqual(NSImage(named: model.rawValue + "CaseProduct" + suffix) != nil, expectsProductArtwork)
                    if model != .wfXM5 {
                        for side in ["Left", "Right"] {
                            XCTAssertEqual(NSImage(named: model.rawValue + "Product" + side + suffix) != nil, expectsProductArtwork)
                        }
                    }
                }
                controller.simulateGalleryDevice(model: model)
                XCTAssertEqual(controller.productArtworkSuffix, "")
                XCTAssertNil(controller.deviceInformation.color)
                count += 1
            }
        }
        XCTAssertEqual(count, 34)
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
    }
    #endif

    @MainActor
    func testSimulatedControlsAndOfflineState() async throws {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertEqual(controller.deviceModel, .wfXM5)
        XCTAssertEqual(controller.batteryLevel, 78)
        controller.setNoiseControl(.anc)
        let noisePayload = try XCTUnwrap(controller.simulatedPendingFrame?.payload)
        XCTAssertEqual(controller.noiseControlMode, .ambient)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x69] + noisePayload.dropFirst()))
        XCTAssertEqual(controller.noiseControlMode, .anc)
        controller.applyPreset(mode: .ambient, ambientLevel: 8, focusOnVoice: true)
        XCTAssertEqual(controller.ambientLevel, 8)
        XCTAssertTrue(controller.focusOnVoice)
        controller.setEqualizerPreset(.bright)
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x59, 0x00, 0x10, 0x00]))
        XCTAssertEqual(controller.equalizerPreset, .bright)
        controller.setCustomEqualizer(.flat)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst()))
        XCTAssertEqual(controller.equalizerPreset, .manual)
        let offline = SonyHeadphonesController(startAutomatically: false)
        XCTAssertFalse(offline.isReady)
        XCTAssertNil(offline.batteryLevel)
        XCTAssertEqual(offline.deviceModel, .unknown)
    }

}

final class SonyEqualizerControllerTests: XCTestCase {
    @MainActor
    func testNotificationReceivedBeforeTransmissionCannotConfirmAfterItsDelayedAcknowledgment() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setEqualizerPreset(.bright)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0x10])
        deliver([0x59, 0, 0x10, 0], to: controller)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0x10])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.payload, [0x58, 0, 0x10, 0])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.type, 0x01)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0x10])
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        deliver([0x59, 0, 0x10, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizer])
        XCTAssertNil(controller.settingErrors[.equalizer])
        XCTAssertEqual(controller.equalizerPreset, .bright)
    }

    @MainActor
    func testResponseReceivedBeforeReadTransmissionCannotOwnTheReadAfterItsDelayedAcknowledgment() {
        let controller = makeController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        deliver([0x57, 0, 0x10, 0], to: controller)
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.payload, [0x56, 0])
        controller.completeSimulatedWrite()
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.type, 0x01)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNil(controller.equalizerReadbackID)
        controller.defersSimulatedWrites = false
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0, 0x16, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
    }

    @MainActor
    func testManualPresetSelectionAcceptsTheStoredCurveInItsReply() {
        let controller = makeController()
        controller.setEqualizerPreset(.manual)
        XCTAssertEqual(controller.pendingChanges[.equalizer], [0xA0])
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.equalizerPreset, .manual)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertNil(controller.settingErrors[.equalizer])
    }

    @MainActor
    func testTenBandCurveUsesAdvertisedRangeAndRejectsLegacyProfile() async throws {
        let controller = makeController()
        deliver([0x51, 0, 10, 13, 2, 0x30, 0, 0xA0, 0], to: controller)
        let metadata: [UInt8] = SonyEqualizerBand.tenBand.flatMap {
            [$0.informationType, UInt8($0.value >> 8), UInt8($0.value & 0xFF)]
        }
        deliver([0x5B, 0, 10] + metadata, to: controller)
        deliver([0x57, 0, 0x30, 0], to: controller)
        controller.setCustomEqualizer(.flat)
        XCTAssertNotNil(controller.settingErrors[.equalizer])
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        var draft = try XCTUnwrap(controller.equalizer.flatSettings)
        draft[0] = -6
        draft[9] = 6
        controller.setCustomEqualizer(draft)
        try await Task.sleep(for: .milliseconds(180))
        let payload: [UInt8] = [0x58, 0, 0xA0, 10, 0, 6, 6, 6, 6, 6, 6, 6, 6, 12]
        XCTAssertEqual(controller.simulatedTransmittedFrames.last?.payload, payload)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + payload.dropFirst(), to: controller)
        XCTAssertEqual(controller.customEqualizer, draft)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertNil(controller.settingErrors[.equalizer])
    }

    @MainActor
    func testManualEqualizerRequiresACompleteMatchingTransmittedReadback() async throws {
        let controller = makeController()
        let settings = EqualizerSettings(clearBass: 10, bands: [-10, -4, 0, 6, 10])
        controller.refreshEqualizer()
        controller.setCustomEqualizer(settings)
        XCTAssertTrue(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        XCTAssertEqual(controller.customEqualizer, .flat)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 0x00])
        let reply = [UInt8(0x59)] + settings.sonySetPayload.dropFirst()
        deliver(reply, to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        acknowledgeSimulatedCommands(controller)
        let readback = controller.equalizerReadbackID
        for payload: [UInt8] in [
            [0x57, 0x00, 0xA0],
            Array(reply.dropLast()),
            reply + [0],
            [0x59, 0x00, 0xA0, 5, 20, 0, 6, 10, 16],
            [0x59, 0x00, 0xA0, 6, 255, 0, 6, 10, 16, 20],
            [0x59, 0x01, 0xA0, 6, 20, 0, 6, 10, 16, 20],
        ] {
            deliver(payload, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.equalizer])
            XCTAssertEqual(controller.customEqualizer, settings)
            XCTAssertEqual(controller.equalizerReadbackID, readback)
        }
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver(reply, to: controller)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.customEqualizer, settings)
        XCTAssertNil(controller.settingErrors[.equalizer])
    }

    @MainActor
    func testRapidEditsKeepOnePendingWriteAndOnlyTheLatestDraft() async throws {
        let controller = makeController()
        let first = EqualizerSettings(clearBass: 1, bands: [1, 0, 0, 0, 0])
        let skipped = EqualizerSettings(clearBass: 3, bands: [2, 0, 0, 0, 0])
        let latest = EqualizerSettings(clearBass: 5, bands: [4, 0, 0, 0, 0])
        controller.setCustomEqualizer(.flat)
        controller.setCustomEqualizer(first)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.setCustomEqualizer(skipped)
        controller.setCustomEqualizer(latest)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.map(\.payload), [first.sonySetPayload])
        deliver([0x59] + first.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, latest.sonySetPayload)
        XCTAssertTrue(controller.isEqualizerUpdatePending)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + first.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizer])
        deliver([0x59] + latest.sonySetPayload.dropFirst(), to: controller)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.customEqualizer, latest)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload.first == 0x58 }.map(\.payload), [first.sonySetPayload, latest.sonySetPayload])
    }

    @MainActor
    func testPresetChangeSupersedesTheWaitingCustomDraftWithoutOptimism() async throws {
        let controller = makeController()
        controller.setCustomEqualizer(.flat)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.setCustomEqualizer(EqualizerSettings(clearBass: 4, bands: [1, 1, 1, 1, 1]))
        controller.setEqualizerPreset(.bright)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x58, 0x00, 0x10, 0x00])
        acknowledgeSimulatedCommands(controller)
        deliver([0x69, 0x19, 1, 1, 0, 0, 10, 0, 0], to: controller)
        XCTAssertTrue(controller.isEqualizerUpdatePending)
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x00, 0x10, 6, 10, 10, 10, 10, 10, 10], to: controller)
        XCTAssertEqual(controller.equalizerPreset, .bright)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
    }

    @MainActor
    func testEqualizerTimeoutIsVisibleAndALateMatchingReplyClearsIt() async throws {
        let controller = makeController()
        let settings = EqualizerSettings(clearBass: 3, bands: [1, 2, 3, 4, 5])
        controller.setCustomEqualizer(settings)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertEqual(controller.settingErrors[.equalizer], "Headphones did not confirm the change.")
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        deliver([0x57] + settings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNil(controller.settingErrors[.equalizer])
        XCTAssertEqual(controller.customEqualizer, settings)
    }

    @MainActor
    func testExplicitSyncRequiresAValidReplyAndSerializesLaterEdits() async throws {
        let controller = makeController()
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        let originalReadback = controller.equalizerReadbackID
        let settings = EqualizerSettings(clearBass: 2, bands: [2, 2, 2, 2, 2])
        controller.setCustomEqualizer(settings)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x58 })
        deliver([0x59] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.equalizerReadbackID, originalReadback)
        deliver([0x57, 0x00, 0xA0, 6, 21, 10, 10, 10, 10, 10], to: controller)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        deliver([0x57] + EqualizerSettings.flat.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotEqual(controller.equalizerReadbackID, originalReadback)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, settings.sonySetPayload)
        acknowledgeSimulatedCommands(controller)
        deliver([0x59] + settings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertEqual(controller.customEqualizer, settings)
    }

    @MainActor
    func testExplicitSyncTimeoutCanBeRetriedWithoutChangingConfirmedSettings() async throws {
        let controller = makeController()
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.settingErrors[.equalizerReadback], "Headphones did not return equalizer settings.")
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
        XCTAssertEqual(controller.customEqualizer, .flat)
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertNotNil(controller.settingErrors[.equalizerReadback])
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 1)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNil(controller.equalizerReadbackID)
        controller.refreshEqualizer(trackConfirmation: true)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
    }

    @MainActor
    func testExplicitSyncWaitsForTheBackgroundReplyThenSendsItsOwnRead() {
        let controller = makeController()
        controller.refreshEqualizer()
        controller.refreshEqualizer()
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 1)
        let oldSettings = EqualizerSettings(clearBass: 1, bands: [1, 1, 1, 1, 1])
        deliver([0x57] + oldSettings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNil(controller.equalizerReadbackID)
        XCTAssertNotNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x56, 0x00])
        acknowledgeSimulatedCommands(controller)
        let currentSettings = EqualizerSettings(clearBass: 4, bands: [2, 2, 2, 2, 2])
        deliver([0x57] + currentSettings.sonySetPayload.dropFirst(), to: controller)
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertEqual(controller.customEqualizer, currentSettings)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 2)
    }

    @MainActor
    func testUnansweredBackgroundReadDoesNotReassignItsLateReplyToSync() async throws {
        let controller = makeController()
        controller.refreshEqualizer()
        acknowledgeSimulatedCommands(controller)
        controller.refreshEqualizer(trackConfirmation: true)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertNil(controller.pendingChanges[.equalizerReadback])
        XCTAssertNotNil(controller.settingErrors[.equalizerReadback])
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x56, 0x00] }.count, 1)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNil(controller.equalizerReadbackID)
        controller.refreshEqualizer(trackConfirmation: true)
        acknowledgeSimulatedCommands(controller)
        deliver([0x57, 0x00, 0x16, 0], to: controller)
        XCTAssertNotNil(controller.equalizerReadbackID)
        XCTAssertNil(controller.settingErrors[.equalizerReadback])
    }

    @MainActor
    func testDisconnectCancelsDebouncePendingRequestsAndAutomaticReplay() async throws {
        let controller = makeController()
        let settings = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        controller.setCustomEqualizer(settings)
        controller.simulateDeviceConnection(named: nil)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.payload.first == 0x58 })
        controller.setCustomEqualizer(settings)
        try await Task.sleep(for: .milliseconds(180))
        acknowledgeSimulatedCommands(controller)
        controller.setCustomEqualizer(.flat)
        let session = controller.simulatedControlSession
        let sentCount = controller.simulatedTransmittedFrames.count
        controller.simulateDeviceConnection(named: nil)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: [0x59] + settings.sonySetPayload.dropFirst()), session: session)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(controller.simulatedTransmittedFrames.count, sentCount)
        XCTAssertFalse(controller.isEqualizerUpdatePending)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
        XCTAssertTrue(controller.settingErrors.isEmpty)
        XCTAssertEqual(controller.equalizerPreset, .bassBoost)
    }

    @MainActor
    private func makeController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: payload))
    }
}
