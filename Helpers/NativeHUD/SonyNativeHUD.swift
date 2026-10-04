import AppKit
import Combine
import Darwin
import OSLog
import SwiftUI
import SystemBannerUI

@MainActor
final class NativeBannerRenderer {
    private typealias MetadataAccessor = @convention(thin) (UInt) -> (Any.Type, UInt)
    private typealias OpaqueMetadataAccessor = @convention(thin) (UInt, UnsafeRawPointer?, UnsafeRawPointer, UInt32) -> (Any.Type, UInt)
    private typealias ConformanceAccessor = @convention(thin) (Any.Type, UnsafeRawPointer) -> UnsafeRawPointer?

    let presenter: UnsafeMutableRawPointer
    let owner: AnyObject
    let delegate: AnyObject
    private let viewType: Any.Type
    private let witness: UnsafeMutableRawPointer
    private let presentFunction: UnsafeMutableRawPointer
    private let viewFunction: UnsafeMutableRawPointer
    private let isPresentingFunction: UnsafeMutableRawPointer
    private let dismissFunction: UnsafeMutableRawPointer
    private let hostSetter: UnsafeMutableRawPointer
    private let hostWitness: UnsafeMutableRawPointer

    init?() {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SystemBannerUI.framework/SystemBannerUI", RTLD_NOW | RTLD_LOCAL),
              let runtime = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOW | RTLD_LOCAL),
              let presenterMetadata = dlsym(framework, "$s14SystemBannerUI0aB9PresenterCMa"),
              let initializer = dlsym(framework, "$s14SystemBannerUI0aB9PresenterCACycfC"),
              let opaqueDescriptor = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC04makeB4View3forQrSi_tFQOMQ"),
              let opaqueAccessor = dlsym(runtime, "swift_getOpaqueTypeMetadata"),
              let conforms = dlsym(runtime, "swift_conformsToProtocol"),
              let contentProtocol = dlsym(framework, "$s14SystemBannerUI0aB7ContentMp"),
              let hostProtocol = dlsym(framework, "$s14SystemBannerUI0aB16PresentationHostMp"),
              let delegateProtocol = dlsym(framework, "$s14SystemBannerUI0aB17PresenterDelegateMp"),
              let presentFunction = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC7presentySbxAA0aB7ContentRzlFTj"),
              let viewFunction = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC04makeB4View3forQrSi_tFTj"),
              let isPresentingFunction = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC012isPresentingaB02ofSbAA0aB7Content_pXp_tFTj"),
              let dismissFunction = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC7dismiss8animated10completionS2b_yyctFTj"),
              let hostSetter = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC16presentationHostAA0ab12PresentationF0_pSgvsTj"),
              let delegateSetter = dlsym(framework, "$s14SystemBannerUI0aB9PresenterC8delegateAA0abD8Delegate_pSgvsTj"),
              let delegateMetadata = dlsym(framework, "$s14SystemBannerUI0aB18AssertionPresenterCMa"),
              let delegateInitializer = dlsym(framework, "$s14SystemBannerUI0aB18AssertionPresenterCACycfC"),
              let hostWitness = unsafeBitCast(conforms, to: ConformanceAccessor.self)(NativeBannerHost.self, hostProtocol),
              let witness = unsafeBitCast(conforms, to: ConformanceAccessor.self)(NativeSonyStatusContent.self, contentProtocol) else { return nil }
        let presenterType = unsafeBitCast(presenterMetadata, to: MetadataAccessor.self)(0).0
        guard let presenter = native_banner_init(initializer, unsafeBitCast(presenterType, to: UnsafeMutableRawPointer.self)) else { return nil }
        let owner = Unmanaged<AnyObject>.fromOpaque(presenter).takeRetainedValue()
        let delegateType = unsafeBitCast(delegateMetadata, to: MetadataAccessor.self)(0).0
        guard let delegateWitness = unsafeBitCast(conforms, to: ConformanceAccessor.self)(delegateType, delegateProtocol),
              let delegatePointer = native_banner_init(delegateInitializer, unsafeBitCast(delegateType, to: UnsafeMutableRawPointer.self)) else { return nil }
        let delegate = Unmanaged<AnyObject>.fromOpaque(delegatePointer).takeRetainedValue()
        native_banner_set_host(delegateSetter, delegatePointer, UnsafeMutableRawPointer(mutating: delegateWitness), presenter)
        self.presenter = presenter
        self.owner = owner
        self.delegate = delegate
        self.witness = UnsafeMutableRawPointer(mutating: witness)
        self.viewType = unsafeBitCast(opaqueAccessor, to: OpaqueMetadataAccessor.self)(0, nil, opaqueDescriptor, 0).0
        self.presentFunction = presentFunction
        self.viewFunction = viewFunction
        self.isPresentingFunction = isPresentingFunction
        self.dismissFunction = dismissFunction
        self.hostSetter = hostSetter
        self.hostWitness = UnsafeMutableRawPointer(mutating: hostWitness)
    }

    func install(_ host: NativeBannerHost) {
        native_banner_set_host(hostSetter, Unmanaged.passUnretained(host).toOpaque(), hostWitness, presenter)
    }

    func present(_ content: NativeSonyStatusContent) -> Bool {
        withUnsafePointer(to: content) {
            native_banner_present(presentFunction, $0, unsafeBitCast(NativeSonyStatusContent.self, to: UnsafeMutableRawPointer.self), witness, presenter)
        }
    }

    func makeView() -> AnyView? {
        func make<T>(_ type: T.Type) -> AnyView? {
            let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
            native_banner_make_view(viewFunction, value, 3, presenter)
            let nativeValue = value.move()
            value.deallocate()
            return AnyView(_fromValue: nativeValue)
        }
        return _openExistential(viewType, do: make)
    }

    var isPresenting: Bool {
        native_banner_is_presenting(isPresentingFunction, unsafeBitCast(NativeSonyStatusContent.self, to: UnsafeMutableRawPointer.self), witness, presenter)
    }

    func dismiss() -> Bool {
        native_banner_dismiss(dismissFunction, true, presenter)
    }
}

@MainActor
final class NativeBannerHost: SystemBannerPresentationHost {
    var onDismiss: @MainActor (Bool) -> Void = { _ in }
    var onKeepAlive: @MainActor (Int) -> Void = { _ in }

    nonisolated func presenter(_ presenter: SystemBannerPresenter, stayVisibleFor reasons: [SystemBannerKeepAliveReason]) {
        let count = reasons.count
        MainActor.assumeIsolated { onKeepAlive(count) }
    }

    nonisolated func presenterDidDismissSystemBanner(_ presenter: SystemBannerPresenter, transitioning: Bool) {
        MainActor.assumeIsolated { onDismiss(transitioning) }
    }
}

@MainActor
final class NativeBannerOpacity: ObservableObject {
    @Published private(set) var value: CGFloat = 0
    private let controller: AnyObject
    private var sourceObservation: AnyCancellable?
    private var opacityObservation: AnyCancellable?

    init?(presenter: AnyObject) {
        guard let value = Mirror(reflecting: presenter).children.first(where: { $0.label == "contentController" })?.value,
              let observable = value as? any ObservableObject else { return nil }
        controller = value as AnyObject
        func initialize<C: ObservableObject>(_ value: C) -> AnyCancellable {
            value.objectWillChange.sink { _ in }
        }
        sourceObservation = _openExistential(observable, do: initialize)
        guard var published = Mirror(reflecting: controller).children.first(where: { $0.label == "_opacity" })?.value as? Published<CGFloat> else { return nil }
        opacityObservation = published.projectedValue.sink { [weak self] value in self?.value = value }
    }
}

@MainActor
final class NativeControlCenterGlass {
    private typealias MetadataAccessor = @convention(thin) (UInt) -> (Any.Type, UInt)
    private let type: Any.Type
    private let controlCenter: UnsafeMutableRawPointer
    private let identity: UnsafeMutableRawPointer
    private let mix: UnsafeMutableRawPointer
    private let explicit: UnsafeMutableRawPointer

    init?() {
        guard let framework = dlopen("/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore", RTLD_NOW | RTLD_LOCAL),
              let metadata = dlsym(framework, "$s7SwiftUI6_GlassVMa"),
              let controlCenter = dlsym(framework, "$s7SwiftUI6_GlassV13controlCenterACvgZ"),
              let identity = dlsym(framework, "$s7SwiftUI6_GlassV8identityACvgZ"),
              let mix = dlsym(framework, "$s7SwiftUI6_GlassV3mix4with2byA2C_SdtF"),
              let explicit = dlsym(framework, "$s7SwiftUI5GlassV8explicitAcA01_C0V_tcfC") else { return nil }
        type = unsafeBitCast(metadata, to: MetadataAccessor.self)(0).0
        self.controlCenter = controlCenter
        self.identity = identity
        self.mix = mix
        self.explicit = explicit
    }

    func make(opacity: Double) -> Glass {
        func make<T>(_ type: T.Type) -> Glass {
            let controlCenter = UnsafeMutablePointer<T>.allocate(capacity: 1)
            let identity = UnsafeMutablePointer<T>.allocate(capacity: 1)
            let mixed = UnsafeMutablePointer<T>.allocate(capacity: 1)
            let result = UnsafeMutablePointer<Glass>.allocate(capacity: 1)
            native_glass_get(self.controlCenter, controlCenter)
            native_glass_get(self.identity, identity)
            native_glass_mix(mix, mixed, identity, 1 - opacity, controlCenter)
            controlCenter.deinitialize(count: 1)
            identity.deinitialize(count: 1)
            native_glass_explicit(explicit, result, mixed)
            let glass = result.move()
            controlCenter.deallocate()
            identity.deallocate()
            mixed.deallocate()
            result.deallocate()
            return glass
        }
        return _openExistential(type, do: make)
    }
}

struct NativeSonyStatusContent: SystemBannerContent, Sendable {
    let mode: String
    let symbol: String
    let opacity: NativeBannerOpacity
    let glass: NativeControlCenterGlass
    var image: NSImage? = nil
    var detail: String? = nil
    var batteryLevel: Int? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.symbol == rhs.symbol && lhs.opacity === rhs.opacity && lhs.image === rhs.image && lhs.detail == rhs.detail && lhs.batteryLevel == rhs.batteryLevel
    }

    var description: String { mode }
    var banner: NativeSonyStatusView {
        MainActor.assumeIsolated { NativeSonyStatusView(mode: mode, symbol: symbol, opacity: opacity, glass: glass, image: image, detail: detail, batteryLevel: batteryLevel) }
    }
    var expanded: EmptyView { EmptyView() }
    var compactLeading: EmptyView { EmptyView() }
    var compactTrailing: EmptyView { EmptyView() }
    var minimal: EmptyView { EmptyView() }
    var accessibilityLabel: Text { Text(detail.map { mode + ". " + $0 } ?? mode) }
    var duration: Double? { nil }
    var kind: Int { 3 }
    var preferredPresentationVariant: SystemBannerVariant { .banner }
    var presentationVariants: [SystemBannerVariant] { [.banner] }
    var priority: Int { 0 }
    var targetDisplayID: UInt32? { nil }
    var wantsDismissButton: Bool { false }
    var accessibilityIdentifier: String? { image == nil ? "sony-noise-status" : "sony-device-status" }
}

struct NativeSonyStatusView: View {
    let mode: String
    let symbol: String
    @ObservedObject var opacity: NativeBannerOpacity
    let glass: NativeControlCenterGlass
    let image: NSImage?
    let detail: String?
    let batteryLevel: Int?

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .renderingMode(image.isTemplate ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 26))
                }
            }
                .foregroundStyle(.white)
                .frame(width: 39, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode)
                    .fontWeight(.medium)
                if let detail { Text(detail).font(.caption) }
            }
            if let batteryLevel {
                Gauge(value: Double(batteryLevel), in: 0...100) {} currentValueLabel: {
                    Text("\(batteryLevel)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(batteryLevel <= 20 ? Color(nsColor: .systemRed) : .green)
                    .fixedSize()
                    .scaleEffect(28.0 / 58.0)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Battery level")
                    .accessibilityValue("\(batteryLevel) percent")
                    .accessibilityIdentifier("sonyHUD.batteryRing")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 16)
        .padding(.trailing, 31)
        .padding(.vertical, 18)
        .frame(height: 66)
        .opacity(opacity.value)
        .glassEffect(glass.make(opacity: opacity.value), in: Capsule(style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
final class SonyNativeHUD {
    let renderer: NativeBannerRenderer
    let opacity: NativeBannerOpacity
    let glass: NativeControlCenterGlass
    let host = NativeBannerHost()
    let lifetime = BannerLifetime()
    var onAvailable: () -> Void = {}
    private weak var anchorView: NSView?
    private var panel: NSPanel?
    private var nativeWindowSize = NSSize.zero
    private var hostingView: NSHostingView<AnyView>?
    private var isDismissing = false
    private var queuedContent: (mode: String, symbol: String)?
    #if DEBUG
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.baglayan.Acouplet", category: "NativeHUDGeometry")
    #endif

    init?() {
        guard let renderer = NativeBannerRenderer(), let opacity = NativeBannerOpacity(presenter: renderer.owner),
              let glass = NativeControlCenterGlass(), NSClassFromString("SystemBannerUI.SystemBannerWindow") is NSPanel.Type else { return nil }
        self.renderer = renderer
        self.opacity = opacity
        self.glass = glass
        lifetime.onExpire = { [weak self] in self?.dismissNative() }
        host.onKeepAlive = { [weak self] count in self?.lifetime.keepAliveChanged(count) }
        host.onDismiss = { [weak self] transitioning in
            guard let self, !transitioning else { return }
            #if DEBUG
            logGeometry("dismissal completed")
            #endif
            lifetime.dismissed()
            isDismissing = false
            if let content = queuedContent {
                queuedContent = nil
                _ = show(mode: content.mode, symbol: content.symbol, anchor: anchorView)
            } else {
                panel?.orderOut(nil)
                onAvailable()
            }
        }
        renderer.install(host)
    }

    func showNotice(title: String, detail: String?, image: NSImage, anchor: NSView?, batteryLevel: Int? = nil) -> Bool {
        guard !isDismissing, !renderer.isPresenting else { return false }
        return show(mode: title, symbol: "", anchor: anchor, image: image, detail: detail, batteryLevel: batteryLevel)
    }

    func show(mode: String, symbol: String, anchor: NSView?, image: NSImage? = nil, detail: String? = nil, batteryLevel: Int? = nil) -> Bool {
        anchorView = anchor
        if isDismissing {
            queuedContent = (mode, symbol)
            return true
        }
        if panel == nil {
            guard let nativeWindowClass = NSClassFromString("SystemBannerUI.SystemBannerWindow") as? NSPanel.Type else { return false }
            let panel = nativeWindowClass.init()
            nativeWindowSize = panel.frame.size
            self.panel = panel
        }
        position()
        #if DEBUG
        logGeometry("before present: \(mode)")
        #endif
        guard renderer.present(NativeSonyStatusContent(mode: mode, symbol: symbol, opacity: opacity, glass: glass, image: image, detail: detail, batteryLevel: batteryLevel)),
              let view = renderer.makeView() else { return false }
        if let hostingView {
            hostingView.rootView = view
        } else {
            let contentView = NSView(frame: NSRect(origin: .zero, size: nativeWindowSize))
            let hostingView = NSHostingView(rootView: view)
            hostingView.sizingOptions = []
            hostingView.frame = contentView.bounds
            hostingView.autoresizingMask = [.width, .height]
            contentView.addSubview(hostingView)
            panel?.contentView = contentView
            self.hostingView = hostingView
        }
        panel?.title = image == nil ? "Noise Control" : mode
        #if DEBUG
        logGeometry("hosting updated: \(mode)")
        #endif
        position()
        panel?.orderFrontRegardless()
        #if DEBUG
        logGeometry("ordered: \(mode)")
        DispatchQueue.main.async { [weak self] in self?.logGeometry("entry next runloop: \(mode)") }
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logGeometry("entry \(delay)s: \(mode)")
            }
        }
        #endif
        lifetime.presented()
        return true
    }

    #if DEBUG
    private func logGeometry(_ phase: String) {
        let panelFrame = panel.map { NSStringFromRect($0.frame) } ?? "nil"
        let hostingFrame = hostingView.map { NSStringFromRect($0.frame) } ?? "nil"
        let hostingBounds = hostingView.map { NSStringFromRect($0.bounds) } ?? "nil"
        let fitting = hostingView.map { NSStringFromSize($0.fittingSize) } ?? "nil"
        let intrinsic = hostingView.map { NSStringFromSize($0.intrinsicContentSize) } ?? "nil"
        let nativeSize = NSStringFromSize(nativeWindowSize)
        let anchorFrame = anchorView.flatMap { view in
            view.window.map { NSStringFromRect($0.convertToScreen(view.convert(view.bounds, to: nil))) }
        } ?? "nil"
        let anchorWindow = anchorView?.window.map { NSStringFromRect($0.frame) } ?? "nil"
        let anchorVisible = anchorView.map { $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor } ?? false
        let screen = (anchorView?.window?.screen ?? panel?.screen).map { NSStringFromRect($0.frame) } ?? "nil"
        logger.notice("\(phase, privacy: .public); panel=\(panelFrame, privacy: .public), nativeSize=\(nativeSize, privacy: .public), hosting=\(hostingFrame, privacy: .public), bounds=\(hostingBounds, privacy: .public), fitting=\(fitting, privacy: .public), intrinsic=\(intrinsic, privacy: .public), anchor=\(anchorFrame, privacy: .public), anchorWindow=\(anchorWindow, privacy: .public), anchorVisible=\(anchorVisible, privacy: .public), screen=\(screen, privacy: .public)")
    }
    #endif

    private func position() {
        guard let panel else { return }
        let screen: NSScreen
        let center: CGFloat
        let top: CGFloat
        if let anchorView, !anchorView.isHiddenOrHasHiddenAncestor,
           let window = anchorView.window, window.isVisible, let anchorScreen = window.screen {
            let anchor = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            screen = anchorScreen
            center = anchor.midX
            top = window.frame.minY
        } else {
            guard let fallback = NSScreen.main ?? NSScreen.screens.first else { return }
            screen = fallback
            center = screen.frame.midX
            top = screen.frame.maxY - (nativeWindowSize.height - 121)
        }
        let left = max(screen.frame.minX, min(center - nativeWindowSize.width / 2, screen.frame.maxX - nativeWindowSize.width + 20))
        panel.setFrameTopLeftPoint(NSPoint(x: left, y: top))
    }

    private func dismissNative() {
        guard !isDismissing, renderer.isPresenting else { return }
        isDismissing = true
        lifetime.dismissed()
        if !renderer.dismiss() {
            isDismissing = false
            panel?.orderOut(nil)
        }
    }

    func dismiss() {
        queuedContent = nil
        lifetime.dismissed()
        panel?.orderOut(nil)
        dismissNative()
    }
}

@_cdecl("sony_native_hud_create")
@MainActor
public func sonyNativeHUDCreate() -> UnsafeMutableRawPointer? {
    guard let hud = SonyNativeHUD() else { return nil }
    return Unmanaged.passRetained(hud).toOpaque()
}

@_cdecl("sony_native_hud_show")
@MainActor
public func sonyNativeHUDShow(_ context: UnsafeMutableRawPointer, _ mode: UnsafePointer<CChar>, _ symbol: UnsafePointer<CChar>, _ anchor: UnsafeMutableRawPointer?) -> Bool {
    let hud = Unmanaged<SonyNativeHUD>.fromOpaque(context).takeUnretainedValue()
    let view = anchor.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    return hud.show(mode: String(cString: mode), symbol: String(cString: symbol), anchor: view)
}

@_cdecl("sony_native_hud_show_notice")
@MainActor
public func sonyNativeHUDShowNotice(_ context: UnsafeMutableRawPointer, _ title: UnsafePointer<CChar>, _ detail: UnsafePointer<CChar>?, _ image: UnsafeMutableRawPointer, _ anchor: UnsafeMutableRawPointer?) -> Bool {
    let hud = Unmanaged<SonyNativeHUD>.fromOpaque(context).takeUnretainedValue()
    let image = Unmanaged<NSImage>.fromOpaque(image).takeUnretainedValue()
    let view = anchor.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    return hud.showNotice(title: String(cString: title), detail: detail.map { String(cString: $0) }, image: image, anchor: view)
}

@_cdecl("sony_native_hud_show_battery_notice")
@MainActor
public func sonyNativeHUDShowBatteryNotice(_ context: UnsafeMutableRawPointer, _ title: UnsafePointer<CChar>, _ image: UnsafeMutableRawPointer, _ batteryLevel: Int32, _ anchor: UnsafeMutableRawPointer?) -> Bool {
    let hud = Unmanaged<SonyNativeHUD>.fromOpaque(context).takeUnretainedValue()
    let image = Unmanaged<NSImage>.fromOpaque(image).takeUnretainedValue()
    let view = anchor.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    return hud.showNotice(title: String(cString: title), detail: nil, image: image, anchor: view, batteryLevel: Int(batteryLevel))
}

@_cdecl("sony_native_hud_set_available")
@MainActor
public func sonyNativeHUDSetAvailable(_ context: UnsafeMutableRawPointer, _ callback: (@convention(c) (UnsafeMutableRawPointer) -> Void)?, _ userContext: UnsafeMutableRawPointer?) {
    let hud = Unmanaged<SonyNativeHUD>.fromOpaque(context).takeUnretainedValue()
    hud.onAvailable = {
        if let callback, let userContext { callback(userContext) }
    }
}

@_cdecl("sony_native_hud_dismiss")
@MainActor
public func sonyNativeHUDDismiss(_ context: UnsafeMutableRawPointer) {
    Unmanaged<SonyNativeHUD>.fromOpaque(context).takeUnretainedValue().dismiss()
}

@_cdecl("sony_native_hud_destroy")
@MainActor
public func sonyNativeHUDDestroy(_ context: UnsafeMutableRawPointer) {
    let hud = Unmanaged<SonyNativeHUD>.fromOpaque(context).takeRetainedValue()
    hud.dismiss()
}
