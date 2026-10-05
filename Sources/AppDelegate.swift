import AppKit
import AppIntents
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment.live()

    private var globalHotKeyController: GlobalHotKeyController?
    private var menuBarController: MenuBarController?
    private var cancellables = Set<AnyCancellable>()
    private var deviceAlertObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var testTerminationObserver: AnyCancellable?
    var openSettings: (() -> Void)?
    #if DEBUG
    private var uiTestWindow: NSWindow?
    #endif

    override init() {
        super.init()
        if #available(macOS 27.0, *) {
            AppDependencyManager.shared.add(dependency: HeadphoneIntentControls(
                actions: { [self] in environment.devices.noiseControlActions },
                resolve: { [self] identifiers in try await environment.devices.resolveNoiseControlActions(for: identifiers) },
                perform: { [self] identifier in try await environment.devices.performNoiseControlAction(identifier) }))
            AppDependencyManager.shared.add(dependency: HeadphoneIntentSpeakToChat(
                actions: { [self] in environment.devices.speakToChatActions },
                resolve: { [self] identifiers in try await environment.devices.resolveSpeakToChatActions(for: identifiers) },
                perform: { [self] identifier in try await environment.devices.performSpeakToChatAction(identifier) }))
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            environment.settings.setLaunchAtLogin(false)
            if let error = environment.settings.launchAtLoginError {
                print(error)
                exit(EXIT_FAILURE)
            }
            exit(EXIT_SUCCESS)
        }
        if !isRunningTests,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        #if MENU_BAR_APP
        NSApp.setActivationPolicy(.accessory)
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("-ui-testing") {
            if CommandLine.arguments.contains("--light-appearance") {
                NSApp.appearance = NSAppearance(named: .aqua)
            } else if CommandLine.arguments.contains("--dark-appearance") {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
        #endif
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["ACOUPLET_TESTING"] == "1" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            CommandLine.arguments.contains("-ui-testing") ||
            CommandLine.arguments.contains("--ui-test-host")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(
            environment: environment,
            showSettings: { [weak self] in self?.showSettings() }
        )
        #if DEBUG
        if #available(macOS 27.0, *), CommandLine.arguments.contains("--open-equalizer-intent") {
            Task {
                do {
                    let _: Void = try await OpenHeadphoneViewIntent(target: .equalizer)(donate: false)
                } catch {
                    assertionFailure(error.localizedDescription)
                }
            }
        }
        if CommandLine.arguments.contains("--ui-test-host") {
            let controller = NSHostingController(rootView: SelectedDeviceView(devices: environment.devices) {
                #if ACOUPLET_PUBLIC_APIS_ONLY
                UITestHostView(showSettings: self.showSettings)
                    .environmentObject(self.environment.settings)
                #else
                UITestHostView(showSettings: self.showSettings, noiseModeHUD: self.environment.noiseModeHUD, ldac: self.environment.ldac)
                    .environmentObject(self.environment.settings)
                    #if ACOUPLET_SPARKLE
                    .environmentObject(self.environment.updater)
                    #endif
                #endif
            })
            let window = NSWindow(contentViewController: controller)
            window.title = "Headphone Controls"
            window.isReleasedWhenClosed = false
            window.setContentSize(controller.view.fittingSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            uiTestWindow = window
        }
        #endif
        let launchType = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true
        if !CommandLine.arguments.contains("--background-service"),
           isDefaultLaunch || CommandLine.arguments.contains("--manual-launch"),
           (!isRunningTests || CommandLine.arguments.contains("--manual-launch")),
           launchType != keyAELaunchedAsLogInItem, launchType != keyAELaunchedAsServiceItem {
            showSettings()
        }
        environment.devices.$controllers
            .sink { [weak self] controllers in self?.observeDeviceAlerts(controllers) }
            .store(in: &cancellables)
        guard !isRunningTests else { return }
        environment.settings.enableLaunchAtLoginByDefault()
        #if ACOUPLET_SPARKLE
        environment.updater.start()
        #endif
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        environment.notifications.start()
        environment.settings.$experimentalLDACEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.environment.ldac.updateInstalledDriverIfNeeded() }
            }
            .store(in: &cancellables)
        #endif
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.environment.devices.systemWillSleep()
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                self?.environment.ldac.suspend()
                #endif
            }
            .store(in: &cancellables)
        workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.environment.devices.systemDidWake() }
            .store(in: &cancellables)
        environment.devices.start()
        #if MENU_BAR_APP || HYBRID_APP
        globalHotKeyController = GlobalHotKeyController { [weak self] in
            self?.environment.headphones.toggleNoiseControl()
        }
        environment.settings.$globalShortcutEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.environment.settings.globalShortcutError = self.globalHotKeyController?.setEnabled(enabled)
            }
            .store(in: &cancellables)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        environment.ldac.refreshDriverState()
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        if environment.ldac.isSessionRunning {
            environment.ldac.stop(reason: "app is terminating") { [weak self] in
                guard let self else { sender.reply(toApplicationShouldTerminate: true); return }
                let reply = self.applicationShouldTerminate(sender)
                if reply != .terminateLater { sender.reply(toApplicationShouldTerminate: reply == .terminateNow) }
            }
            return .terminateLater
        }
        #endif
        let controllers = environment.devices.controllers.filter {
            $0.earTipFitTransition?.canDismiss == false || $0.headGesturePracticeTransition?.canDismiss == false
                || $0.legacyOptimizerTransition?.canDismiss == false
        }
        guard !controllers.isEmpty else { return .terminateNow }
        testTerminationObserver = Publishers.MergeMany(controllers.map { $0.objectWillChange.eraseToAnyPublisher() })
            .receive(on: DispatchQueue.main)
            .first { _ in controllers.allSatisfy {
                $0.earTipFitTransition?.canDismiss != false && $0.headGesturePracticeTransition?.canDismiss != false
                    && $0.legacyOptimizerTransition?.canDismiss != false
            } }
            .sink { [weak self] _ in
                let interrupted = controllers.first {
                    $0.earTipFitTransition?.phase == .interrupted || $0.headGesturePracticeTransition?.phase == .interrupted
                        || $0.legacyOptimizerTransition?.phase == .interrupted
                }
                if let interrupted, let self {
                    self.environment.devices.selectForWorkflow(address: interrupted.address)
                    self.environment.settings.selectedSettingsPane = "headphones"
                    self.showSettings()
                }
                sender.reply(toApplicationShouldTerminate: interrupted == nil)
                self?.testTerminationObserver = nil
            }
        for headphones in controllers {
            if let transition = headphones.earTipFitTransition { headphones.cancelEarTipFit(id: transition.id) }
            if let transition = headphones.headGesturePracticeTransition { headphones.cancelHeadGesturePractice(id: transition.id) }
            if let transition = headphones.legacyOptimizerTransition { headphones.cancelLegacyOptimizer(id: transition.id) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
        menuBarController = nil
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        environment.noiseModeHUD.dismiss()
        #endif
        environment.devices.stop()
    }

    private func observeDeviceAlerts(_ controllers: [SonyHeadphonesController]) {
        let identifiers = Set(controllers.map(ObjectIdentifier.init))
        deviceAlertObservers = deviceAlertObservers.filter { identifiers.contains($0.key) }
        for controller in controllers where deviceAlertObservers[ObjectIdentifier(controller)] == nil {
            deviceAlertObservers[ObjectIdentifier(controller)] = controller.$connectionTransition
                .map { $0?.alert != nil }
                .combineLatest(controller.$multipointTransition.map { $0?.alert != nil })
                .map { $0 || $1 }
                .removeDuplicates()
                .sink { [weak self, weak controller] needsConfirmation in
                    guard needsConfirmation, let self, let controller else { return }
                    self.environment.devices.selectForWorkflow(address: controller.address)
                    self.showSettings()
                }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings() {
        openSettings?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppSettingsScene: Scene {
    let environment: AppEnvironment

    var body: some Scene {
        Settings {
            SettingsWindowContent(environment: environment)
                .environmentObject(environment.settings)
        }
        .windowResizability(.contentSize)
    }
}

private struct SettingsWindowContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var isVisible = false
    let environment: AppEnvironment

    var body: some View {
        ZStack {
            if isVisible {
                SelectedDeviceView(devices: environment.devices) {
                    SettingsView()
                        .environmentObject(environment.audioRoute)
                        #if ACOUPLET_SPARKLE
                        .environmentObject(environment.updater)
                        #endif
                        #if !ACOUPLET_PUBLIC_APIS_ONLY
                        .environmentObject(environment.notifications)
                        .environmentObject(environment.ldac)
                        #endif
                }
            }
        }
        .frame(width: 720, height: settings.selectedSettingsPane == "general" ? 540 : 600)
        .background {
            SettingsWindowVisibilityReader { visible in
                if isVisible != visible { isVisible = visible }
                #if DEBUG
                if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.isVisible = visible }
                #endif
            }
        }
        #if DEBUG
        .background {
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbeView() }
        }
        #endif
    }
}

private struct SettingsWindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleReport()
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observation: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            let names = [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification]
            observation = Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
                .filter { [weak window] notification in notification.object as? NSWindow === window }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    if notification.name == NSWindow.willCloseNotification { self?.onChange?(false) }
                    else { self?.reportVisibility() }
                }
            scheduleReport()
        }

        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in self?.reportVisibility() }
        }

        private func reportVisibility() {
            onChange?(window?.isVisible == true && window?.isMiniaturized == false)
        }
    }
}

#if DEBUG
@MainActor
enum SettingsLifecycleProbe {
    static let isEnabled = CommandLine.arguments.contains("-ui-testing") && CommandLine.arguments.contains("--settings-lifecycle")
    static var phase = "unknown"
    static var isVisible = false
    static var bodyEvaluations = 0
    static var appearances = 0
    static var disappearances = 0

    static var snapshot: String { "\(phase)|\(isVisible)|\(bodyEvaluations)|\(appearances)|\(disappearances)" }

    static func recordBody() {
        if isEnabled { bodyEvaluations += 1 }
    }
}

private struct SettingsLifecycleProbeView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: scenePhase, initial: true) { _, phase in
                SettingsLifecycleProbe.phase = String(describing: phase)
            }
    }
}
#endif
