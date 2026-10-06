import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import SystemBannerUI

@MainActor
final class NativeHUDOpacitySource: ObservableObject {
    @Published var opacity: CGFloat = 0
}

@MainActor
final class NativeHUDOpacityPresenter {
    let contentController = NativeHUDOpacitySource()
}

@main
struct NativeHUDCheck {
    @MainActor
    static func main() {
        alarm(10)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        precondition(app.activationPolicy() == .prohibited)
        app.finishLaunching()
        weak var releasedHUD: SonyNativeHUD?
        weak var releasedPresenter: AnyObject?
        autoreleasepool {
            let hud = SonyNativeHUD()!
            releasedHUD = hud
            releasedPresenter = hud.renderer.owner
            check(hud)
        }
        wait { releasedHUD == nil && releasedPresenter == nil }
        precondition(app.windows.isEmpty)
        alarm(0)
        print("ACOUPLET_NATIVE_HUD_OK")
    }

    @MainActor
    private static func check(_ hud: SonyNativeHUD) {
        let presenter = NativeHUDOpacityPresenter()
        let opacity = NativeBannerOpacity(presenter: presenter)!
        for value: CGFloat in [1, 0.35, 0] {
            presenter.contentController.opacity = value
            precondition(opacity.value == value)
        }
        for value in [0.0, 0.35, 1.0] {
            withExtendedLifetime(hud.glass.make(opacity: value)) {}
        }
        var availabilityChanges = 0
        hud.onAvailable = { availabilityChanges += 1 }
        let content = NativeSonyStatusContent(mode: "Noise Cancellation", symbol: "waveform.slash", opacity: hud.opacity, glass: hud.glass)
        let policy = hud.renderer.delegate as! any SystemBannerPresenterDelegate
        precondition(policy.canSystemBannerStayVisible(for: content))
        let host = NativeBannerHost()
        var dismissals = 0
        host.onDismiss = { transitioning in
            hud.host.onDismiss(transitioning)
            if !transitioning { dismissals += 1 }
        }
        hud.renderer.install(host)
        let image = NSImage(systemSymbolName: "earbuds", accessibilityDescription: nil)!
        let notice = NativeSonyStatusContent(mode: "Firmware 6.1.0 Available", symbol: "", opacity: hud.opacity, glass: hud.glass,
                                            image: image, detail: "Update in Sony | Sound Connect.")
        precondition(notice.accessibilityIdentifier == "sony-device-status")
        let battery = NativeSonyStatusContent(mode: "Left Earbud Low (10%)", symbol: "", opacity: hud.opacity, glass: hud.glass,
                                             image: image, batteryLevel: 10)
        var changedBattery = battery
        changedBattery.batteryLevel = 15
        precondition(battery != changedBattery && notice.batteryLevel == nil && content.batteryLevel == nil)
        let windowType = NSClassFromString("SystemBannerUI.SystemBannerWindow") as! NSPanel.Type
        for (index, current) in [content, notice, battery].enumerated() {
            autoreleasepool {
                let window = windowType.init()
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                precondition(hud.renderer.present(current))
                let hosting = NSHostingView(rootView: hud.renderer.makeView()!)
                hosting.sizingOptions = []
                hosting.frame = NSRect(origin: .zero, size: window.frame.size)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                wait { hud.renderer.isPresenting && hud.opacity.value == 1 }
                render(hosting)
                if current.batteryLevel != nil {
                    precondition(hud.renderer.present(changedBattery))
                    hosting.rootView = hud.renderer.makeView()!
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    render(hosting)
                }
                precondition(hud.renderer.isPresenting)
                precondition(!hud.showNotice(title: "Left Earbud Low (10%)", detail: nil, image: image, anchor: nil))
                if index == 1 {
                    hud.lifetime.onExpire()
                } else {
                    precondition(hud.renderer.dismiss())
                }
                wait { !hud.renderer.isPresenting && dismissals == index + 1 }
                precondition(!window.isVisible && !window.isKeyWindow)
                window.contentView = nil
                window.close()
            }
        }
        precondition(dismissals == 3 && !hud.renderer.isPresenting)
        precondition(availabilityChanges == 3)
        let assertions = Mirror(reflecting: hud.renderer.delegate).children.first { $0.label == "assertions" }!
        precondition(Mirror(reflecting: assertions.value).children.isEmpty)
    }

    @MainActor
    private static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        precondition(condition())
    }

    @MainActor
    private static func render(_ hosting: NSHostingView<AnyView>) {
        wait {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let pixels = UnsafeBufferPointer(start: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            return pixels.contains { $0 != 0 }
        }
    }
}
