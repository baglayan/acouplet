import AppKit
import Combine
import Foundation
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
        let presenter = NativeHUDOpacityPresenter()
        let opacity = NativeBannerOpacity(presenter: presenter)!
        for value: CGFloat in [1, 0.35, 0] {
            presenter.contentController.opacity = value
            precondition(opacity.value == value)
        }
        let hud = SonyNativeHUD()!
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
        precondition(hud.renderer.present(content))
        let view = hud.renderer.makeView()!
        precondition(hud.renderer.isPresenting)
        let image = NSImage(size: NSSize(width: 26, height: 26))
        precondition(!hud.showNotice(title: "Left Earbud Low (10%)", detail: nil, image: image, anchor: nil))
        precondition(hud.renderer.dismiss())
        withExtendedLifetime((hud, host, view)) {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        precondition(dismissals == 1 && !hud.renderer.isPresenting)
        let notice = NativeSonyStatusContent(mode: "Firmware 6.1.0 Available", symbol: "", opacity: hud.opacity, glass: hud.glass,
                                            image: image, detail: "Update in Sony | Sound Connect.")
        precondition(notice.accessibilityIdentifier == "sony-device-status")
        precondition(hud.renderer.present(notice))
        let noticeView = hud.renderer.makeView()!
        hud.lifetime.onExpire()
        precondition(!hud.showNotice(title: "Left Earbud Low (10%)", detail: nil, image: image, anchor: nil))
        withExtendedLifetime((hud, host, noticeView)) {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        precondition(dismissals == 2 && !hud.renderer.isPresenting)
        let battery = NativeSonyStatusContent(mode: "Left Earbud Low (10%)", symbol: "", opacity: hud.opacity, glass: hud.glass,
                                             image: image, batteryLevel: 10)
        var changedBattery = battery
        changedBattery.batteryLevel = 15
        precondition(battery != changedBattery && notice.batteryLevel == nil && content.batteryLevel == nil)
        precondition(hud.renderer.present(battery))
        let batteryView = hud.renderer.makeView()!
        precondition(hud.renderer.dismiss())
        withExtendedLifetime((hud, host, batteryView)) {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        precondition(dismissals == 3 && !hud.renderer.isPresenting)
        precondition(availabilityChanges == 3)
        let assertions = Mirror(reflecting: hud.renderer.delegate).children.first { $0.label == "assertions" }!
        precondition(Mirror(reflecting: assertions.value).children.isEmpty)
        precondition(NSApplication.shared.windows.isEmpty)
        print("PASS synchronous opacity, native delegate/host witnesses, mode/notice/battery content, exit rejects notices, native dismissal callback; no assertion or window")
    }
}
