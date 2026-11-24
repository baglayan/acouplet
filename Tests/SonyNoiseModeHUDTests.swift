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
    @MainActor
    func testDynamicIslandRequiresTouchAndAHardwareFrameOnTheBuiltInDisplay() throws {
        guard #available(macOS 27.3, *) else { throw XCTSkip("Mac Live Activities require macOS 27.3") }
        let screen = IslandTestScreen()
        let displays = NSScreen.screens.compactMap(\.cgDirectDisplayID)
        screen.hardwareFrame = NSRect(x: 800, y: 1120, width: 80, height: 20)
        screen.testDisplayID = displays.first { CGDisplayIsBuiltin($0) == 0 } ?? kCGNullDirectDisplay
        XCTAssertFalse(screen.hasAcoupletDynamicIsland)
        guard let builtIn = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw XCTSkip("A built-in display is required to exercise the hardware-frame query")
        }
        screen.testDisplayID = builtIn
        screen.testTouchCapabilities = []
        XCTAssertFalse(screen.hasAcoupletDynamicIsland)
        screen.testTouchCapabilities = .multiTouch
        XCTAssertTrue(screen.hasAcoupletDynamicIsland)
        screen.hasHardwareFrameSelector = false
        XCTAssertFalse(screen.hasAcoupletDynamicIsland)
        screen.hasHardwareFrameSelector = true
        screen.hardwareFrame = .zero
        XCTAssertGreaterThan(screen.safeAreaInsets.top, 0)
        XCTAssertFalse(screen.hasAcoupletDynamicIsland)
    }

    @MainActor
    func testStatusActivityCoalescesReplacementsAndEndsBeforePendingNoticesRetry() async throws {
        let lifetime = BannerLifetime()
        let updated = expectation(description: "Latest mode delivered")
        let available = expectation(description: "Ended activity released")
        var events: [String] = []
        let activity = SonyStatusActivity(lifetime: lifetime, canPresent: { _ in true }) { state in
            events.append(state.title)
            return .init(isActive: { true }, update: { state in
                events.append(state.title)
                updated.fulfill()
            }, end: { events.append("ended") })
        }
        activity.onAvailable = { available.fulfill() }
        func present(_ title: String, replacing: Bool = false) -> SonyStatusActivity.Presentation {
            activity.present(.init(title: title, subtitle: nil, systemImage: "headphones", percent: nil),
                             anchorView: nil, replacing: replacing)
        }
        XCTAssertEqual(present("Low Battery"), .accepted)
        let first = try XCTUnwrap(lifetime.timer)
        XCTAssertEqual(present("Firmware"), .busy)
        XCTAssertTrue(lifetime.timer === first)
        XCTAssertEqual(present("Ambient", replacing: true), .accepted)
        XCTAssertEqual(present("Off", replacing: true), .accepted)
        XCTAssertFalse(first.isValid)
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(events, ["Low Battery", "Off"])
        try XCTUnwrap(lifetime.timer).fire()
        XCTAssertEqual(present("Firmware"), .busy)
        activity.dismiss()
        await fulfillment(of: [available], timeout: 2)
        XCTAssertEqual(events, ["Low Battery", "Off", "ended"])
        XCTAssertNil(lifetime.timer)
    }

    @MainActor
    func testNoiseChangesDuringActivityDismissalPresentTheLatestModeForTheSameSession() async throws {
        let owner = SonyHeadphonesController(startAutomatically: false, simulated: true)
        owner.simulateDeviceConnection(named: "WF-1000XM5")
        defer { owner.simulateControlLoss() }
        let address = try XCTUnwrap(SonyBLEIdentity.normalizedAddress(owner.address))
        let replayed = expectation(description: "Latest noise change presented after dismissal")
        var symbols: [String] = []
        let activity = SonyStatusActivity(canPresent: { _ in true }) { state in
            symbols.append(state.systemImage)
            if symbols.count == 2 { replayed.fulfill() }
            return .init(isActive: { true }, update: { _ in XCTFail("Updated a dismissed activity") }, end: {})
        }
        let hud = SonyNoiseModeHUD(statusActivity: activity)
        func show(_ mode: NoiseControlMode) {
            let event = SonyNoiseModeChange(deviceID: address, session: owner.notificationSession, deviceName: owner.deviceName,
                                            previousMode: .wind, mode: mode, isUnsolicited: true, hasLocalCommand: false)!
            hud.show(event, headphones: owner)
        }
        show(.ambient)
        hud.dismiss()
        show(.anc)
        show(.off)
        await fulfillment(of: [replayed], timeout: 2)
        XCTAssertEqual(symbols, [NoiseControlMode.ambient.symbol, NoiseControlMode.off.symbol])
        hud.dismiss()
    }

    #if DEBUG
    @MainActor
    func testActivityRequestDenialAndIneligibleDisplayUseTheExistingFallback() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let image = NSImage(size: NSSize(width: 20, height: 20))
        for eligible in [false, true] {
            var attempts = 0
            let activity = SonyStatusActivity(canPresent: { _ in eligible }) { _ in
                attempts += 1
                return nil
            }
            let hud = SonyNoiseModeHUD(statusActivity: activity)
            let title = "Status activity fallback"
            XCTAssertTrue(hud.showNoticePreview(title: title, detail: nil, image: image, headphones: controller))
            XCTAssertEqual(attempts, eligible ? 1 : 0)
            XCTAssertTrue(NSApp.windows.contains { $0.title == title && $0.isVisible })
            XCTAssertFalse(hud.showNoticePreview(title: title, detail: nil, image: image, headphones: controller))
            hud.dismiss()
            XCTAssertFalse(NSApp.windows.contains { $0.title == title && $0.isVisible })
        }
    }

    @MainActor
    func testStatusActivityKeepsControllerOwnershipAndMenuSuppression() async {
        let owner = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let other = SonyHeadphonesController(startAutomatically: false, simulated: true)
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let removed = expectation(description: "Owner removed")
        let available = expectation(description: "Pending notices may retry")
        let opened = expectation(description: "Menu opened")
        var states: [AcoupletStatusAttributes.ContentState] = []
        let activity = SonyStatusActivity(canPresent: { _ in true }) { state in
            states.append(state)
            let ended = states.count == 1 ? removed : opened
            return .init(isActive: { true }, update: { _ in XCTFail("Unexpected replacement") },
                         end: { ended.fulfill() })
        }
        let hud = SonyNoiseModeHUD(statusActivity: activity)
        hud.onAvailable = { available.fulfill() }
        func present() -> Bool {
            hud.showNoticePreview(title: "Firmware", detail: "Open Sound Connect", image: image, headphones: owner)
        }
        XCTAssertTrue(present())
        XCTAssertFalse(NSApp.windows.contains { $0.title == "Firmware" && $0.isVisible })
        hud.dismiss(for: other)
        hud.dismissIfControllerRemoved(from: [owner])
        XCTAssertFalse(present())
        hud.dismissIfControllerRemoved(from: [other])
        await fulfillment(of: [removed, available], timeout: 2)
        XCTAssertTrue(present())
        hud.setMenuVisible(true)
        XCTAssertFalse(present())
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last?.subtitle, "Open Sound Connect")
    }
    #endif

    @MainActor
    func testNativeHUDProbeAllowsFutureSystemVersionsAboveItsDeploymentTarget() {
        for version in [OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1),
                        OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)] {
            XCTAssertTrue(SonyNativeHUDProbe.supports(version: version))
        }
        for version in [OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 9),
                        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)] {
            XCTAssertFalse(SonyNativeHUDProbe.supports(version: version))
        }
    }

    @MainActor
    func testNativeHUDProbeRequiresCompletedChecksAndCleanExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "probe")
        for (body, expected) in [("echo ACOUPLET_NATIVE_HUD_OK", true),
                                 ("echo ACOUPLET_NATIVE_HUD_OK; exit 7", false),
                                 ("echo incomplete", false),
                                 ("exit 0", false),
                                 ("kill -KILL $$", false)] {
            try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let passed = await SonyNativeHUDProbe(executableURL: executable).check()
            XCTAssertEqual(passed, expected, body)
        }
        try FileManager.default.removeItem(at: executable)
        let missing = await SonyNativeHUDProbe(executableURL: executable).check()
        XCTAssertFalse(missing)
    }

    @MainActor
    func testNativeHUDProbeSharesOneAttemptAndRetainsSuccessOrFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "probe")
        for (body, expected) in [("echo ACOUPLET_NATIVE_HUD_OK", true), ("exit 1", false)] {
            let script = "#!/bin/sh\n/bin/rm -- \"$0\"\n/bin/sleep 0.1\n" + body + "\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let probe = SonyNativeHUDProbe(executableURL: executable)
            async let first = probe.check()
            async let second = probe.check()
            let results = await (first, second)
            XCTAssertEqual(results.0, expected)
            XCTAssertEqual(results.1, expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path))
            let repeated = await probe.check()
            XCTAssertEqual(repeated, expected)
        }
    }

    @MainActor
    func testNativeHUDProbeTimesOutWithoutBlockingTheMainActorAndKillsTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "probe")
        let pidFile = directory.appending(path: "pid")
        let script = "#!/bin/sh\necho $$ > \"${0%/*}/pid\"\nexec /bin/sleep 30\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let probe = SonyNativeHUDProbe(executableURL: executable, timeout: 1)
        let start = ContinuousClock.now
        let attempt = Task { await probe.check() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let passed = await attempt.value
        XCTAssertFalse(passed)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<20 {
            if kill(pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let repeated = await probe.check()
        XCTAssertFalse(repeated)
    }

    @MainActor
    func testFallbackFrameRemainsOnTheAnchorScreenOrCentersWithoutAnAnchor() {
        let screen = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        let size = NSSize(width: 400, height: 66)
        func placement(anchorX: CGFloat) -> BannerPlacement {
            .desktop(screen: screen, visibleFrame: screen,
                     anchor: (NSRect(x: anchorX, y: 1055, width: 30, height: 25), 1055))
        }
        let left = placement(anchorX: -1910).fallbackFrame(size: size)
        let right = placement(anchorX: -40).fallbackFrame(size: size)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(left.maxY, screen.maxY - 8)
        XCTAssertEqual(right.maxY, screen.maxY - 8)
        let centered = BannerPlacement.desktop(screen: screen, visibleFrame: screen, anchor: nil).fallbackFrame(size: size)
        XCTAssertEqual(centered.midX, screen.midX)
        XCTAssertEqual(centered.maxY, screen.maxY - 8)
        let small = NSRect(x: 100, y: 200, width: 300, height: 40)
        XCTAssertEqual(BannerPlacement.desktop(screen: small, visibleFrame: small, anchor: nil).fallbackFrame(size: size), small)
    }

    @MainActor
    func testPresentationMatchesTheFocusedDisplayWithMultipleScreens() {
        XCTAssertTrue(BannerPlacement.isActiveDisplay(2, activeID: 2, displayCount: 2))
        XCTAssertFalse(BannerPlacement.isActiveDisplay(1, activeID: 2, displayCount: 2))
        XCTAssertFalse(BannerPlacement.isActiveDisplay(2, activeID: nil, displayCount: 2))
        XCTAssertFalse(BannerPlacement.isActiveDisplay(nil, activeID: nil, displayCount: 2))
        XCTAssertTrue(BannerPlacement.isActiveDisplay(2, activeID: nil, displayCount: 1))
    }

    @MainActor
    func testFullScreenUsesOnlyTheActiveDisplaysCurrentSpace() {
        let desktop = ["type": 0]
        let fullScreen = ["type": 4]
        let displays: [[String: Any]] = [
            ["Display Identifier": "left", "Current Space": desktop, "Spaces": [desktop, fullScreen]],
            ["Display Identifier": "right", "Current Space": fullScreen],
        ]
        XCTAssertFalse(BannerPlacement.isFullScreen(activeDisplay: "left", separateSpaces: true, displays: displays))
        XCTAssertTrue(BannerPlacement.isFullScreen(activeDisplay: "right", separateSpaces: true, displays: displays))
        XCTAssertFalse(BannerPlacement.isFullScreen(activeDisplay: "missing", separateSpaces: true, displays: displays))
        let shared: [[String: Any]] = [["Display Identifier": "Main", "Current Space": fullScreen]]
        XCTAssertTrue(BannerPlacement.isFullScreen(activeDisplay: "right", separateSpaces: false, displays: shared))
    }

    @MainActor
    func testFullScreenCentersBothRenderersBelowTheRevealedMenuBar() {
        let screen = NSRect(x: -1440, y: 220, width: 1440, height: 900)
        let nativeSize = NSSize(width: 367, height: 160)
        let fallbackSize = NSSize(width: 240, height: 66)
        for height: CGFloat in [24, 39] {
            let placement = BannerPlacement.fullScreen(screen: screen, menuBarHeight: height)
            let native = placement.nativeTopLeft(size: nativeSize)
            let fallback = placement.fallbackFrame(size: fallbackSize)
            XCTAssertEqual(native.x + nativeSize.width / 2, screen.midX)
            XCTAssertEqual(fallback.midX, screen.midX)
            XCTAssertEqual(native.y, screen.maxY - height)
            XCTAssertEqual(fallback.maxY, native.y - 10)
        }
        let anchor = NSRect(x: -300, y: screen.maxY - 26, width: 32, height: 26)
        let desktop = BannerPlacement.desktop(screen: screen, visibleFrame: screen, anchor: (anchor, anchor.minY - 1))
        XCTAssertEqual(desktop.nativeTopLeft(size: nativeSize), NSPoint(x: anchor.midX - nativeSize.width / 2, y: anchor.minY - 1))
        XCTAssertEqual(desktop.fallbackFrame(size: fallbackSize).midX, anchor.midX)
        XCTAssertEqual(desktop.fallbackFrame(size: fallbackSize).maxY, anchor.minY - 8)
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
        controller.simulateProtocolMessage(anc)
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

#if !ACOUPLET_PUBLIC_APIS_ONLY
@available(macOS 27.3, *)
private final class IslandTestScreen: NSScreen {
    var testDisplayID = kCGNullDirectDisplay
    var testTouchCapabilities: NSScreen.TouchCapabilities = .multiTouch
    var hasHardwareFrameSelector = true
    @objc(_centerHUDHardwareFrame) var hardwareFrame = NSRect.zero
    override var __cgDirectDisplayID: CGDirectDisplayID { testDisplayID }
    override var touchCapabilities: NSScreen.TouchCapabilities { testTouchCapabilities }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0) }

    override func responds(to selector: Selector!) -> Bool {
        if selector == NSSelectorFromString("_centerHUDHardwareFrame") { return hasHardwareFrameSelector }
        return super.responds(to: selector)
    }
}
#endif
