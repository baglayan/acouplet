import AppKit
import XCTest
@testable import Acouplet

final class SonyNoiseModeHUDTests: XCTestCase {
    func testOnlyDistinctUnsolicitedLiveModeChangesCreateAnEvent() {
        func change(deviceID: String? = "02-53-4F-4E-59-03", previous: NoiseControlMode? = .anc,
                    mode: NoiseControlMode = .ambient, unsolicited: Bool = true,
                    localCommand: Bool = false) -> SonyNoiseModeChange? {
            SonyNoiseModeChange(deviceID: deviceID, session: 7, deviceName: "WF-1000XM5",
                                previousMode: previous, mode: mode,
                                isUnsolicited: unsolicited, hasLocalCommand: localCommand)
        }

        let event = change()
        XCTAssertEqual(event?.mode, .ambient)
        XCTAssertEqual(event?.session, 7)
        XCTAssertEqual(event?.deviceID, "02-53-4F-4E-59-03")
        XCTAssertNil(change(deviceID: nil))
        XCTAssertNil(change(deviceID: ""))
        XCTAssertNil(change(previous: nil))
        XCTAssertNil(change(mode: .anc))
        XCTAssertNil(change(unsolicited: false))
        XCTAssertNil(change(localCommand: true))
        XCTAssertEqual(change(previous: .ambient, mode: .off)?.mode, .off)
        XCTAssertEqual(change(previous: .anc, mode: .wind)?.mode, .wind)
    }

    func testNoiseModeActionsRemainBoundToTheirOriginatingDeviceSession() {
        let change = SonyNoiseModeChange(deviceID: "02:53:4F:4E:59:03", session: 7, deviceName: "WF-1000XM5",
                                        previousMode: .anc, mode: .ambient, isUnsolicited: true, hasLocalCommand: false)!
        XCTAssertTrue(change.matches(deviceID: "02:53:4F:4E:59:03", session: 7))
        XCTAssertFalse(change.matches(deviceID: "02:53:4F:4E:59:04", session: 7))
        XCTAssertFalse(change.matches(deviceID: "02:53:4F:4E:59:03", session: 8))
        XCTAssertFalse(change.matches(deviceID: nil, session: 7))
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func testPrivateHUDRequiresTheVerifiedSystemAndFrameworkABI() {
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        XCTAssertTrue(SonyNativeHUDABI.supports(version: version, build: "26B5091g", uuid: SonyNativeHUDABI.frameworkUUID))
        XCTAssertFalse(SonyNativeHUDABI.supports(version: version, build: "26B5091h", uuid: SonyNativeHUDABI.frameworkUUID))
        XCTAssertFalse(SonyNativeHUDABI.supports(version: version, build: "26B5091g", uuid: UUID()))
        XCTAssertFalse(SonyNativeHUDABI.supports(version: version, build: "26B5091g", uuid: nil))
        XCTAssertFalse(SonyNativeHUDABI.supports(version: OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0),
                                               build: "26B5091g", uuid: SonyNativeHUDABI.frameworkUUID))
        for version in [OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)] {
            XCTAssertFalse(SonyNativeHUDABI.supports(version: version, build: "26B5091g", uuid: SonyNativeHUDABI.frameworkUUID))
        }
    }

    @MainActor
    func testFallbackFrameRemainsOnTheAnchorScreenOrCentersWithoutAnAnchor() {
        let screen = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        let size = NSSize(width: 400, height: 66)
        let left = SonyNoiseModeHUD.fallbackFrame(size: size, screen: screen,
                                                 anchor: NSRect(x: -1910, y: 1055, width: 30, height: 25))
        let right = SonyNoiseModeHUD.fallbackFrame(size: size, screen: screen,
                                                  anchor: NSRect(x: -40, y: 1055, width: 30, height: 25))
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(left.maxY, screen.maxY - 8)
        XCTAssertEqual(right.maxY, screen.maxY - 8)
        let centered = SonyNoiseModeHUD.fallbackFrame(size: size, screen: screen, anchor: nil)
        XCTAssertEqual(centered.midX, screen.midX)
        XCTAssertEqual(centered.maxY, screen.maxY - 8)
        let smallScreen = NSRect(x: 100, y: 200, width: 300, height: 40)
        XCTAssertEqual(SonyNoiseModeHUD.fallbackFrame(size: size, screen: smallScreen, anchor: nil), smallScreen)
    }

    @MainActor
    func testFallbackLifetimeRenewsAndNotifiesOnceAfterExpiry() throws {
        let lifetime = BannerLifetime()
        var expirations = 0
        lifetime.onExpire = { expirations += 1 }
        lifetime.presented()
        let first = try XCTUnwrap(lifetime.timer)
        lifetime.presented()
        let replacement = try XCTUnwrap(lifetime.timer)
        XCTAssertFalse(first.isValid)
        XCTAssertFalse(first === replacement)
        XCTAssertTrue((3.9...4).contains(replacement.fireDate.timeIntervalSinceNow))
        replacement.fire()
        XCTAssertEqual(expirations, 1)
        XCTAssertNil(lifetime.timer)
        replacement.fire()
        XCTAssertEqual(expirations, 1)
        lifetime.presented()
        let dismissed = try XCTUnwrap(lifetime.timer)
        lifetime.dismissed()
        XCTAssertFalse(dismissed.isValid)
        XCTAssertNil(lifetime.timer)
    }

    #endif

    @MainActor
    func testSimulatedModePacketsDoNotEmitLiveEvents() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        defer { controller.simulateControlLoss() }
        var changes: [SonyNoiseModeChange] = []
        let observation = controller.noiseModeChanges.sink { changes.append($0) }
        defer { observation.cancel() }
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        XCTAssertTrue(changes.isEmpty)
        let anc: [UInt8] = [0x69, 0x19, 1, 1, 0, 0, 12, 0, 0]
        controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x0C, sequence: 0, payload: anc))
        XCTAssertEqual(controller.noiseControlMode, .anc)
        XCTAssertTrue(changes.isEmpty)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLowBatteryUsesTheModelsExistingPartIcons() throws {
        for model in SonyDeviceModel.allCases where model.symbol != nil {
            if model.isEarbuds {
                for (part, name) in [(SonyLowBatteryPolicy.Part.left, model.leftSymbol), (.right, model.rightSymbol)] {
                    let source = try XCTUnwrap(name.flatMap(NSImage.init(named:)))
                    let image = try XCTUnwrap(SonyNoiseModeHUD.lowBatteryImage(model: model, part: part))
                    XCTAssertEqual(image.size.width, source.size.width)
                    XCTAssertEqual(image.size.height, source.size.height)
                    XCTAssertTrue(image.isTemplate)
                }
                let source = try XCTUnwrap(model.caseSymbol.flatMap(NSImage.init(named:)))
                XCTAssertTrue(SonyNoiseModeHUD.lowBatteryImage(model: model, part: .caseBattery) === source)
            } else {
                let source = try XCTUnwrap(model.symbol.flatMap(NSImage.init(named:)))
                XCTAssertTrue(SonyNoiseModeHUD.lowBatteryImage(model: model, part: .headphones) === source)
            }
        }
        XCTAssertNil(SonyNoiseModeHUD.lowBatteryImage(model: .unknown, part: .headphones))
    }

    @MainActor
    func testNewModelsHaveBatterySymbolsWithoutInventedCustomAssets() throws {
        for model in SonyDeviceModel.allCases where model != .unknown && model.symbol == nil {
            if model.isEarbuds {
                for part: SonyLowBatteryPolicy.Part in [.left, .right, .caseBattery] {
                    _ = try XCTUnwrap(SonyNoiseModeHUD.lowBatteryImage(model: model, part: part))
                }
            } else {
                _ = try XCTUnwrap(SonyNoiseModeHUD.lowBatteryImage(model: model, part: .headphones))
                XCTAssertNil(SonyNoiseModeHUD.lowBatteryImage(model: model, part: .caseBattery))
            }
        }
    }

    @MainActor
    func testEarbudBatteryIconsOnlyTintFreshDischargingConnectedReadingsRed() throws {
        let date = Date()
        func reading(_ part: SonyLowBatteryPolicy.Part, _ level: Int, charging: Bool = false,
                     age: TimeInterval = 0) -> SonyLowBatteryPolicy.Reading {
            .init(part: part, level: level, isCharging: charging, observedAt: date.addingTimeInterval(-age))
        }
        let snapshots: [([SonyLowBatteryPolicy.Reading], Bool?, Bool?, Bool, Bool)] = [
            ([reading(.left, 10), reading(.right, 80)], true, true, true, false),
            ([reading(.left, 10), reading(.right, 15)], true, true, true, true),
            ([reading(.left, 10, age: 46), reading(.right, 15)], true, true, false, true),
            ([reading(.left, 10, charging: true), reading(.right, 15)], true, true, false, true),
            ([reading(.left, 10), reading(.right, 15)], false, true, false, true),
            ([reading(.right, 15)], nil, true, false, true),
            ([reading(.left, 101), reading(.right, 21)], true, true, false, false),
        ]
        for (readings, leftConnected, rightConnected, leftLow, rightLow) in snapshots {
            let image = try XCTUnwrap(SonyNoiseModeHUD.lowBatteryImage(model: .wfXM5, part: .left, readings: readings,
                                                                      leftConnected: leftConnected,
                                                                      rightConnected: rightConnected, at: date))
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var redLeft = 0
            var redRight = 0
            for x in 0..<pixels.pixelsWide {
                for y in 0..<pixels.pixelsHigh {
                    guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.2,
                          color.redComponent > color.greenComponent + 0.2,
                          color.redComponent > color.blueComponent + 0.2 else { continue }
                    if x < pixels.pixelsWide / 2 { redLeft += 1 }
                    else { redRight += 1 }
                }
            }
            XCTAssertEqual(redLeft > 0, leftLow)
            XCTAssertEqual(redRight > 0, rightLow)
        }
    }
    #endif
}
