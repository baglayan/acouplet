#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
import ColorSync

@MainActor
enum BannerPlacement {
    case desktop(screen: NSRect, visibleFrame: NSRect, anchor: (frame: NSRect, windowBottom: CGFloat)?)
    case fullScreen(screen: NSRect, menuBarHeight: CGFloat)

    static func current(anchorView: NSView?) -> (screen: NSScreen, placement: BannerPlacement, isActiveDisplay: Bool)? {
        let active = activeDisplay?()
        let screen: NSScreen
        let placement: BannerPlacement
        if let fullScreen = active?.fullScreen {
            screen = fullScreen
            let key = "_revealedMenuBarHeight"
            let revealedHeight = screen.responds(to: NSSelectorFromString(key)) ? screen.value(forKey: key) as? CGFloat : nil
            let height = revealedHeight ?? NSStatusBar.system.thickness
            placement = .fullScreen(screen: screen.frame, menuBarHeight: max(height, screen.safeAreaInsets.top))
        } else if let anchorView, !anchorView.isHiddenOrHasHiddenAncestor,
                  let window = anchorView.window, window.isVisible, let anchorScreen = window.screen {
            screen = anchorScreen
            let frame = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            placement = .desktop(screen: screen.frame, visibleFrame: screen.visibleFrame, anchor: (frame, window.frame.minY))
        } else {
            guard let fallback = NSScreen.main ?? NSScreen.screens.first else { return nil }
            screen = fallback
            placement = .desktop(screen: screen.frame, visibleFrame: screen.visibleFrame, anchor: nil)
        }
        let isActive = isActiveDisplay(displayID(of: screen), activeID: active?.id, displayCount: NSScreen.screens.count)
        return (screen, placement, isActive)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func isActiveDisplay(_ targetID: CGDirectDisplayID?, activeID: CGDirectDisplayID?, displayCount: Int) -> Bool {
        if displayCount == 1 { return true }
        guard let activeID else { return false }
        return targetID == activeID
    }

    private static let activeDisplay: (() -> (id: CGDirectDisplayID?, fullScreen: NSScreen?)?)? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connection = dlsym(framework, "SLSMainConnectionID"),
              let activeMenuBar = dlsym(framework, "SLSCopyActiveMenuBarDisplayIdentifier"),
              let displaySpaces = dlsym(framework, "SLSCopyManagedDisplaySpaces") else { return nil }
        let mainConnection = unsafeBitCast(connection, to: (@convention(c) () -> Int32).self)
        let copyActiveDisplay = unsafeBitCast(activeMenuBar, to: (@convention(c) (Int32) -> Unmanaged<CFString>?).self)
        let copyDisplaySpaces = unsafeBitCast(displaySpaces, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
        return {
            let cid = mainConnection()
            guard let display = copyActiveDisplay(cid)?.takeRetainedValue() as String? else { return nil }
            let id = display == "Main" ? nil : CGDisplayGetDisplayIDFromUUID(CFUUIDCreateFromString(nil, display as CFString))
            guard let spaces = copyDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
                  isFullScreen(activeDisplay: display, separateSpaces: NSScreen.screensHaveSeparateSpaces, displays: spaces) else { return (id, nil) }
            if let id { return (id, NSScreen.screens.first { displayID(of: $0) == id }) }
            return (nil, NSScreen.main ?? NSScreen.screens.first)
        }
    }()

    static func isFullScreen(activeDisplay: String, separateSpaces: Bool, displays: [[String: Any]]) -> Bool {
        let identifier = separateSpaces ? activeDisplay : "Main"
        let display = displays.first { ($0["Display Identifier"] as? String) == identifier }
        let current = display?["Current Space"] as? [String: Any]
        return current?["type"] as? Int == 4
    }

    func nativeTopLeft(size: NSSize) -> NSPoint {
        switch self {
        case let .fullScreen(screen, menuBarHeight):
            return NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - menuBarHeight)
        case let .desktop(screen, _, anchor):
            let center = anchor?.frame.midX ?? screen.midX
            let top = anchor?.windowBottom ?? screen.maxY - (size.height - 121)
            let left = max(screen.minX, min(center - size.width / 2, screen.maxX - size.width + 20))
            return NSPoint(x: left, y: top)
        }
    }

    func fallbackFrame(size: NSSize) -> NSRect {
        let bounds: NSRect
        let anchor: NSRect?
        let gap: CGFloat
        switch self {
        case let .fullScreen(screen, menuBarHeight):
            bounds = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - menuBarHeight)
            anchor = nil
            gap = 10
        case let .desktop(_, visibleFrame, menuAnchor):
            bounds = visibleFrame
            anchor = menuAnchor?.frame
            gap = 8
        }
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let left = max(bounds.minX, min((anchor?.midX ?? bounds.midX) - width / 2, bounds.maxX - width))
        let top = min(anchor?.minY ?? bounds.maxY, bounds.maxY) - gap
        return NSRect(x: left, y: max(bounds.minY, top - height), width: width, height: height)
    }
}
#endif
