import AppKit
import ServiceManagement
import SwiftUI

private enum ListeningPreset: String, CaseIterable, Identifiable {
    case focus, office, aware

    var id: Self { self }
    var title: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .office: String(localized: "Office")
        case .aware: String(localized: "Aware")
        }
    }
    var symbol: String {
        switch self {
        case .focus: "moon"
        case .office: "person.2"
        case .aware: "figure.walk"
        }
    }
    var mode: NoiseControlMode { self == .focus ? .anc : .ambient }
    var level: Int {
        switch self {
        case .focus: 10
        case .office: 8
        case .aware: 20
        }
    }
    var focusOnVoice: Bool { self == .office }
}

struct MenuBarHeadphoneControls {
    let address: String
    let model: SonyDeviceModel
    let session: UInt64
    let batteries: SonyBatteries
    let isChargingInCase: Bool
    let leftConnected: Bool?
    let rightConnected: Bool?
    let noiseModes: [NoiseControlMode]
    let noiseMode: NoiseControlMode?
    let showsVoiceSpotlight: Bool
    let voiceSpotlightSelected: Bool
    let ambientLevelRange: ClosedRange<Int>?
    let ambientLevel: Int
    let ambientLevelStep: Int
    let supportsVoiceFocus: Bool
    let focusOnVoice: Bool
    let showsMultipoint: Bool
    let multipoint: SonyMultipoint
    let equalizer: SonyEqualizer
    let legacySurround: SonyLegacySoundEffect
    let legacySoundPosition: SonyLegacySoundEffect
    let dsee: DSEEControl.Presentation?
    let supportsPowerOff: Bool

    @MainActor
    init(_ headphones: SonyHeadphonesController) {
        address = headphones.address
        model = headphones.deviceModel
        session = headphones.notificationSession
        batteries = headphones.batteries
        isChargingInCase = headphones.isChargingInCase
        leftConnected = headphones.leftConnected
        rightConnected = headphones.rightConnected
        noiseModes = headphones.availableNoiseModes
        noiseMode = headphones.noiseControlMode
        showsVoiceSpotlight = headphones.noiseControl?.inquiryType == 0x18
        voiceSpotlightSelected = headphones.noiseControlDisplayState?.isNoiseCancellingSS == true
        ambientLevelRange = headphones.ambientLevelRange
        ambientLevel = headphones.ambientLevel
        ambientLevelStep = headphones.ambientLevelStep
        supportsVoiceFocus = headphones.supportsVoiceFocus
        focusOnVoice = headphones.focusOnVoice
        showsMultipoint = MultipointSettingControl.showsMenuEntry(for: headphones)
        multipoint = headphones.multipoint
        equalizer = headphones.equalizer
        legacySurround = headphones.legacySurround
        legacySoundPosition = headphones.legacySoundPosition
        dsee = headphones.supportsDSEE ? DSEEControl.Presentation(headphones) : nil
        supportsPowerOff = headphones.supportsPowerOff
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
extension LDACState {
    var isEnabledInMenuBar: Bool {
        switch self {
        case .waitingForDevice, .waitingForMac, .requested, .connecting, .active: true
        case .off, .stopping, .failed: false
        }
    }

    var showsMenuBarProgress: Bool {
        switch self {
        case .requested, .connecting, .stopping: true
        default: false
        }
    }

    func locksMenuBarHeadphoneControls(controlsReady: Bool) -> Bool {
        switch self {
        case .requested, .connecting, .stopping: true
        case .active: !controlsReady
        case .off, .waitingForDevice, .waitingForMac, .failed: false
        }
    }
}

extension LDACController {
    func locksMenuBarHeadphoneControls(for headphones: SonyHeadphonesController) -> Bool {
        if multipointShutdownAddress == headphones.address { return true }
        guard targetAddress == headphones.address else { return false }
        return state.locksMenuBarHeadphoneControls(controlsReady: headphones.isReady)
    }

    func retainedMenuBarHeadphoneControls(for headphones: SonyHeadphonesController) -> MenuBarHeadphoneControls? {
        guard locksMenuBarHeadphoneControls(for: headphones),
              headphones.powerOffState == nil, !headphones.headphoneTestNeedsRecovery, !headphones.isBluetoothAccessDenied,
              let origin = menuBarControlOrigin, origin.controller == ObjectIdentifier(headphones) else { return nil }
        let controls = if case .active = state {
            headphones.lastReadyMenuBarControls
        } else {
            menuBarControlsAtHandoff ?? headphones.lastReadyMenuBarControls
        }
        guard let retained = controls, retained.session >= origin.session,
              retained.address == headphones.address, retained.model == headphones.deviceModel else { return nil }
        return retained
    }
}
#endif

struct MenuBarView: View {
    let showSettings: () -> Void
    var closeMenu: (() -> Void)? = nil
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @EnvironmentObject private var settings: SettingsStore
    private var selectMultipointSource = MultipointSourceSelection()
    #if ACOUPLET_SPARKLE
    @EnvironmentObject private var updater: AppUpdater
    #endif
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableHeight: CGFloat
    @State private var presentedMode: NoiseControlMode?
    @State private var powerOffTarget: PowerOffTarget?
    @State private var showsPowerOffConfirmation = false
    @State private var showsMultipoint = false

    private struct PowerOffTarget {
        let controller: SonyHeadphonesController
        let session: UInt64
        let name: String
    }

    init(showSettings: @escaping () -> Void, closeMenu: (() -> Void)? = nil, initialScreenHeight: CGFloat? = nil) {
        self.showSettings = showSettings
        self.closeMenu = closeMenu
        _availableHeight = State(initialValue: (initialScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 720) - 16)
    }

    var body: some View {
        let retained = retainedHeadphoneControls
        let presentation = retained ?? (showsHeadphoneControls ? MenuBarHeadphoneControls(headphones) : nil)
        let locksHeadphoneControls = self.locksHeadphoneControls
        let controlPanel = controls(presentation, locksHeadphoneControls: locksHeadphoneControls)
        VStack(spacing: 0) {
            if !showsConnectOnly {
                header(retained)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
            }
            if !headphones.usbProtection.cautions.isEmpty || headphones.usbProtection.ports.values.contains(where: { $0.detected == true }) {
                VStack(alignment: .leading, spacing: 8) {
                    USBProtectionNotice(headphones: headphones)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            ViewThatFits(in: .vertical) {
                controlPanel
                ScrollView {
                    controlPanel
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("headphones.controlsScroll")
            }
            #if ACOUPLET_SPARKLE
            if updater.hasPendingUpdate {
                Divider()
                Button {
                    dismissMenu()
                    updater.checkForUpdates()
                } label: {
                    Label("Update Available…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderless)
                .tint(nil)
                .accessibilityIdentifier("menu.updateAvailable")
            }
            #endif
            Divider()
            footer(retained, locksHeadphoneControls: locksHeadphoneControls)
        }
        .frame(width: 360)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .windowResizeAnchorIfAvailable(.topLeading)
        .background(PanelScreenHeightReader { availableHeight = $0 }.accessibilityHidden(true))
        .font(.body)
        .controlSize(.regular)
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("headphones.dashboard")
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: showsConnectOnly)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: presentation != nil)
        .onChange(of: presentation?.noiseMode, initial: true) { _, mode in
            withAnimation(presentedMode != nil && mode != nil && !reduceMotion ? .smooth(duration: 0.2) : nil) {
                presentedMode = mode
            }
        }
        .onChange(of: locksHeadphoneControls) { _, locked in
            if locked {
                showsMultipoint = false
                showsPowerOffConfirmation = false
            }
        }
        .alert("Turn Off \(powerOffTarget?.name ?? "")?", isPresented: $showsPowerOffConfirmation, presenting: powerOffTarget) { target in
            Button("Cancel", role: .cancel) {}
            Button("Turn Off") {
                if !self.locksHeadphoneControls { target.controller.powerOff(expectedSession: target.session) }
            }
        } message: { _ in
            Text("Audio will stop on all connected devices. You’ll need to turn the headphones on again before reconnecting.")
        }
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
    }

    private var showsHeadphoneControls: Bool {
        headphones.isReady && headphones.powerOffState == nil && !headphones.headphoneTestNeedsRecovery
    }

    private var showsConnectOnly: Bool {
        headphones.linkState == .disconnected && !headphones.isDeviceConnected
            && headphones.powerOffState == nil && !headphones.headphoneTestNeedsRecovery
            && headphones.lastErrorMessage == nil && !showsLDACSession
    }

    private var showsLDACSession: Bool {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        return ldac.keepsMenuBarVisible(forAddress: headphones.address)
        #else
        return false
        #endif
    }

    private var locksHeadphoneControls: Bool {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        ldac.locksMenuBarHeadphoneControls(for: headphones)
        #else
        false
        #endif
    }

    private var retainedHeadphoneControls: MenuBarHeadphoneControls? {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        devices.isSystemSleeping ? nil : ldac.retainedMenuBarHeadphoneControls(for: headphones)
        #else
        nil
        #endif
    }

    private var maximumHeight: CGFloat {
        #if DEBUG
        if CommandLine.arguments.contains("--compact-panel") { return 480 }
        #endif
        return availableHeight
    }

    private func controls(_ presentation: MenuBarHeadphoneControls?, locksHeadphoneControls: Bool) -> some View {
        let controlsDisabled = locksHeadphoneControls || (headphones.isRunningHeadphoneTest && !headphones.headphoneTestNeedsRecovery)
            || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false
        return VStack(alignment: .leading, spacing: 16) {
            if !showsLDACSession {
                HeadphoneConnectionView(connectOnly: showsConnectOnly)
                    .disabled(controlsDisabled)
            }
            Group {
                if let presentation {
                    if headphones.isRunningHeadphoneTest {
                        Text("A headphone test is open in Settings.").font(.caption)
                    }
                    if !presentation.noiseModes.isEmpty {
                        listeningModes(presentation)
                        presets
                        modeDetails(presentation)
                    }
                }
            }
            .disabled(controlsDisabled)
            if let presentation, presentation.showsMultipoint {
                multipointControl(presentation.multipoint)
                    .disabled(locksHeadphoneControls)
            }
            if let presentation {
                Group {
                    if presentation.equalizer.isSupported { equalizer(presentation.equalizer) }
                    if presentation.equalizer.bassBoost.inquiryType != nil {
                        BassBoostControl(effect: presentation.equalizer.bassBoost)
                    }
                    if presentation.legacySurround.isSupported {
                        LegacySoundEffectControl(kind: .surround, displayedEffect: presentation.legacySurround)
                    }
                    if presentation.legacySoundPosition.isSupported {
                        LegacySoundEffectControl(kind: .soundPosition, displayedEffect: presentation.legacySoundPosition)
                    }
                    if let dsee = presentation.dsee { DSEEControl(presentation: dsee) }
                }
                .disabled(controlsDisabled)
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            if showsLDACSession || (settings.experimentalLDACEnabled && ((showsHeadphoneControls && ldac.canEnable(forAddress: headphones.address))
                || (ldac.targetAddress == headphones.address && ldac.state != .off))) {
                ldacControl
            }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func multipointControl(_ multipoint: SonyMultipoint) -> some View {
        let selectSource: @MainActor (SonyMultipointDevice) -> Void = { [headphones] in
            selectMultipointSource($0, on: headphones)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Multipoint")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showsMultipoint = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .tint(nil)
                .controlSize(.small)
                .accessibilityLabel("Manage Devices")
                .accessibilityIdentifier("multipoint.open")
                .help("Manage Devices")
                .background {
                    MultipointPopover(isPresented: $showsMultipoint, headphones: headphones, settings: settings,
                                       maximumHeight: min(availableHeight, 480), selectSource: selectSource)
                        .accessibilityHidden(true)
                }
            }
            MultipointSourcePicker(displayedMultipoint: multipoint, selectSource: selectSource)
            if let message = headphones.sourceTransition?.failureMessage ?? headphones.deviceActionTransition?.failureMessage {
                Text(message).font(.caption)
            }
            Divider()
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private var ldacState: LDACState { ldac.targetAddress == headphones.address ? ldac.state : .off }
    private var isTurningOffMultipointForLDAC: Bool { ldac.multipointShutdownAddress == headphones.address }

    private var ldacStatusText: String {
        switch ldacState {
        case .off: String(localized: "Off")
        case .waitingForDevice: String(localized: "Waiting for headphones…")
        case .waitingForMac: String(localized: "Waiting for this Mac…")
        case .requested: ldac.audioCaptureAccess == .checking ? String(localized: "Checking permission…") : String(localized: "Requested…")
        case .connecting: ldac.isRecovering ? String(localized: "Reconnecting…") : String(localized: "Connecting…")
        case .active(let format):
            String(localized: "\((Double(format.sampleRateHz) / 1_000).formatted()) kHz · \(format.bitrateKbps) kb/s")
                + (format.channels == 2 ? "" : String(localized: " · \(format.channels) channels"))
        case .stopping: String(localized: "Restoring audio…")
        case .failed: String(localized: "Failed")
        }
    }

    private var ldacControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LDAC")
                Menu {
                    Picker("Sample Rate", selection: $settings.ldacConfiguration.sampleRate) {
                        ForEach(LDACSampleRate.allCases, id: \.self) { rate in
                            Text(rate.displayName).tag(rate)
                        }
                    }
                    Picker("Playback Quality", selection: $settings.ldacConfiguration.quality) {
                        ForEach(LDACQuality.allCases, id: \.self) { quality in
                            let configuration = LDACConfiguration(sampleRate: settings.ldacConfiguration.sampleRate, quality: quality)
                            Text(configuration.qualityDisplayName).tag(quality)
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .tint(nil)
                .controlSize(.small)
                .fixedSize()
                .disabled(!ldac.canChangeConfiguration)
                .accessibilityLabel("LDAC Settings")
                .help("LDAC Settings")
                .accessibilityIdentifier("audio.ldacSettings")
                Spacer()
                if ldacState.showsMenuBarProgress || isTurningOffMultipointForLDAC {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isTurningOffMultipointForLDAC ? String(localized: "Turning off multipoint…") : ldacStatusText)
                        .accessibilityIdentifier("audio.ldacFormat")
                    if case .active(let format) = ldacState,
                       let rate = format.sourceSampleRateHz, rate != format.sampleRateHz {
                        Text("Mac PCM \((Double(rate) / 1_000).formatted()) kHz")
                            .accessibilityIdentifier("audio.ldacSourceRate")
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Toggle("LDAC", isOn: Binding(
                    get: { ldacState.isEnabledInMenuBar },
                    set: { ldac.setEnabled($0, forAddress: headphones.address, configuration: settings.ldacConfiguration) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(settings.tintColor)
                .disabled(!ldacState.isEnabledInMenuBar && (isTurningOffMultipointForLDAC || !ldac.canEnable(forAddress: headphones.address) || !ldac.canStartOrInstallDriver))
                .accessibilityValue(ldacStatusText)
                .accessibilityIdentifier("audio.ldac")
                .alert("Turn off multipoint for LDAC?", isPresented: Binding(
                    get: { ldac.multipointConflictAddress == headphones.address },
                    set: { if !$0, ldac.multipointConflictAddress == headphones.address { ldac.resolveMultipointConflict(turnOffMultipoint: false) } }
                )) {
                    Button("Turn Off Multipoint") { ldac.resolveMultipointConflict(turnOffMultipoint: true) }
                        .accessibilityIdentifier("audio.ldacTurnOffMultipoint")
                    Button("Keep Multipoint", role: .cancel) { ldac.resolveMultipointConflict(turnOffMultipoint: false) }
                        .accessibilityIdentifier("audio.ldacKeepMultipoint")
                } message: {
                    Text("These headphones offer LDAC only when multipoint is off. Turning it off can disconnect the headphones and any other connected device.")
                }
            }
            if !ldac.isSessionRunning, !isTurningOffMultipointForLDAC, ldacState != .waitingForDevice { LDACDriverGuidance() }
            if case .active = ldacState, let error = ldac.sampleRateChangeError {
                Text(error)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("audio.ldacRateChangeError")
            }
            if case .failed(let error) = ldacState {
                if ldac.audioCaptureAccess == .permissionRequired {
                    LDACPermissionGuidance()
                } else {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
        }
    }

    #endif

    private func header(_ retained: MenuBarHeadphoneControls?) -> some View {
        let showsBatteries = headphones.isReady || retained != nil
        let batteries = retained?.batteries ?? headphones.batteries
        let leftConnected = retained.map(\.leftConnected) ?? headphones.leftConnected
        let rightConnected = retained.map(\.rightConnected) ?? headphones.rightConnected
        return VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(headphones.deviceName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, devices.hasOtherSelectableDevices ? 36 : 0)
                    .accessibilityIdentifier("menu.title")
                    .overlay(alignment: .trailing) {
                        if devices.hasOtherSelectableDevices {
                            ConnectedHeadphonePicker(showsIconOnly: true)
                        }
                    }
                if showsHeadphoneControls || retained != nil {
                    Text(headphones.statusText)
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showsBatteries, retained?.isChargingInCase ?? headphones.isChargingInCase {
                VStack(spacing: 10) {
                    OpenChargingCaseArtwork(model: headphones.deviceModel, artwork: headphones.productArtwork,
                                            suffix: headphones.productArtworkSuffix)
                    HStack(spacing: 22) {
                        battery("Left", value: batteries.left)
                        battery("Right", value: batteries.right)
                        battery("Case", value: batteries.caseBattery)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if headphones.deviceModel.isEarbuds {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 10) {
                        earbudArtwork(leftConnected: leftConnected, rightConnected: rightConnected)
                        if showsBatteries {
                            HStack(spacing: 12) {
                                battery("Left", value: batteries.left, connected: leftConnected)
                                battery("Right", value: batteries.right, connected: rightConnected)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        Group {
                            if let name = headphones.productArtwork?.caseImage, let image = NSImage(named: name) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 104, height: 76)
                            } else {
                                Image(nsImage: DeviceIcon.caseImage(model: headphones.deviceModel))
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 88, height: 76)
                            }
                        }
                        .accessibilityLabel("\(headphones.deviceModel.name) charging case")
                        .accessibilityIdentifier("device.artwork.case")
                        if showsBatteries { battery("Case", value: batteries.caseBattery) }
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                if let image = headphones.productArtwork?.heroImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityLabel(headphones.deviceModel.name)
                        .accessibilityIdentifier("device.artwork.\(headphones.deviceModel.rawValue)")
                } else {
                    DeviceIcon(model: headphones.deviceModel, leftConnected: nil, rightConnected: nil)
                        .frame(width: 80, height: 80)
                        .accessibilityLabel(headphones.deviceModel.name)
                        .accessibilityIdentifier("device.artwork.\(headphones.deviceModel.rawValue)")
                }
                if showsBatteries { battery("Battery", value: batteries.single) }
            }
        }
    }

    private func earbudArtwork(leftConnected: Bool?, rightConnected: Bool?) -> some View {
        HStack(spacing: 12) {
            EarbudArtwork(model: headphones.deviceModel, side: .left, artwork: headphones.productArtwork)
                .frame(width: 68, height: 76)
                .opacity(leftConnected == false ? 0.35 : 1)
            EarbudArtwork(model: headphones.deviceModel, side: .right, artwork: headphones.productArtwork)
                .frame(width: 68, height: 76)
                .opacity(rightConnected == false ? 0.35 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("\(headphones.deviceModel.name) earbuds")
        .accessibilityValue(DeviceIcon.connectionValue(left: leftConnected, right: rightConnected))
        .accessibilityIdentifier("device.artwork.\(headphones.deviceModel.rawValue)")
    }

    private func battery(_ title: String, value: BatteryReading?, connected: Bool? = nil) -> some View {
        let reading = connected == false ? nil : value
        let color = DeviceIcon.batteryColor(for: reading).map { Color(nsColor: $0) } ?? .green
        let description = reading.map {
            title == "Case" ? String(localized: "\($0.level) percent, \($0.chargingState.title), last reported")
                : String(localized: "\($0.level) percent\($0.isCharging ? String(localized: ", charging") : "")")
        }
        return VStack(spacing: 6) {
            Gauge(value: Double(reading?.level ?? 0), in: 0...100) {}
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(reading == nil ? Color.secondary : color)
                .fixedSize()
                .scaleEffect(28.0 / 58.0)
                .frame(width: 28, height: 28)
                .overlay {
                    if reading?.isCharging == true {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(color)
                    }
                }
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                if title == "Left" || title == "Right" {
                    Image(systemName: title == "Right" ? "r.circle.fill" : "l.circle.fill")
                        .font(.caption)
                        .foregroundStyle(title == "Right" ? Color.red.opacity(reading == nil ? 0.5 : 1) : (reading == nil ? Color.secondary : Color.primary))
                } else if title == "Case", let symbol = headphones.deviceModel.caseSymbol {
                    Image(symbol)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 13)
                } else if title == "Battery" {
                    Image(systemName: "headphones")
                        .font(.caption)
                }
                Text(reading.map { String(localized: "\($0.level)%") } ?? "—")
                    .monospacedDigit()
            }
            .foregroundStyle(reading == nil ? Color.secondary : Color.primary)
            if title == "Case", reading != nil {
                Text("Last reported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Case percentage and charging show the last report received from the headphones.")
            }
        }
        .frame(width: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(batteryTitle(title)), \(description ?? (connected == false ? String(localized: "Disconnected") : String(localized: "Not reported")))"))
        .accessibilityIdentifier("battery.\(title.lowercased())")
    }

    private func batteryTitle(_ title: String) -> String {
        switch title {
        case "Left": String(localized: "Left battery")
        case "Right": String(localized: "Right battery")
        case "Case": String(localized: "Case battery")
        default: String(localized: "Battery")
        }
    }

    private func listeningModes(_ presentation: MenuBarHeadphoneControls) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noise Control")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) { listeningModeButtons(presentation) }
            } else {
                listeningModeButtons(presentation)
            }
        }
    }

    private func listeningModeButtons(_ presentation: MenuBarHeadphoneControls) -> some View {
        let selectedMode = presentedMode ?? presentation.noiseMode
        return HStack(spacing: 8) {
            ForEach(presentation.noiseModes) { mode in
                modeButton(mode, selected: selectedMode == mode)
                    .headphoneButtonStyle(prominent: selectedMode == mode)
                    .tint(selectedMode == mode ? .primary : nil)
                if mode == .anc, presentation.showsVoiceSpotlight {
                    voiceSpotlightButton(selected: presentation.voiceSpotlightSelected)
                }
            }
        }
    }

    private func voiceSpotlightButton(selected: Bool) -> some View {
        Button { headphones.setNoiseCancellingSS() } label: {
            VStack(spacing: 7) {
                Image(systemName: "person.wave.2").font(.title3)
                Text("Voice")
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : Color.primary)
        }
        .headphoneButtonStyle(prominent: selected)
        .tint(selected ? .primary : nil)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!headphones.canChangeNoiseControl)
        .accessibilityLabel("Voice-spotlight")
        .help("Voice-spotlight")
        .accessibilityIdentifier("noiseControl.voiceSpotlight")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modeButton(_ mode: NoiseControlMode, selected: Bool) -> some View {
        Button { headphones.setNoiseControl(mode) } label: {
            VStack(spacing: 7) {
                Image(systemName: mode.symbol).font(.title3)
                Text(mode.compactTitle)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : Color.primary)
        }
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!headphones.canChangeNoiseControl)
        .accessibilityLabel(mode.title)
        .accessibilityInputLabels([mode.compactTitle, mode.title])
        .accessibilityIdentifier("noiseControl.\(mode.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func modeDetails(_ presentation: MenuBarHeadphoneControls) -> some View {
        if (presentedMode ?? presentation.noiseMode) == .ambient {
            VStack(alignment: .leading, spacing: 10) {
                if let range = presentation.ambientLevelRange, range.lowerBound < range.upperBound {
                    HStack {
                        Text("Ambient Sound")
                        Spacer()
                        Text("\(presentation.ambientLevel)").monospacedDigit().foregroundStyle(Color.primary)
                    }
                    Slider(value: Binding(get: { Double(retainedHeadphoneControls?.ambientLevel ?? headphones.ambientLevel) },
                                          set: { headphones.setAmbientLevel(Int($0)) }),
                           in: Double(range.lowerBound)...Double(range.upperBound), step: Double(presentation.ambientLevelStep))
                        .accessibilityLabel("Ambient sound level")
                }
                if presentation.supportsVoiceFocus {
                    HStack {
                        Text("Focus on Voice")
                        Spacer()
                        Toggle("Focus on Voice", isOn: Binding(
                            get: { retainedHeadphoneControls?.focusOnVoice ?? headphones.focusOnVoice },
                            set: headphones.setFocusOnVoice
                        ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(settings.tintColor)
                    }
                }
            }
            .disabled(!headphones.canChangeNoiseControl)
        }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(ListeningPreset.allCases) { preset in
                Button {
                    headphones.applyPreset(mode: preset.mode, ambientLevel: preset.level, focusOnVoice: preset.focusOnVoice)
                } label: {
                    Label(preset.title, systemImage: preset.symbol)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!headphones.canApplyNoisePreset(mode: preset.mode, ambientLevel: preset.level, focusOnVoice: preset.focusOnVoice))
                .help(preset.mode == .anc ? String(localized: "Turn on noise cancellation.")
                      : String(localized: "Set Ambient Sound to \(preset.level), with Focus on Voice \(preset.focusOnVoice ? String(localized: "on") : String(localized: "off"))."))
            }
        }
        .buttonStyle(.bordered)
        .tint(.primary)
    }

    private func equalizer(_ equalizer: SonyEqualizer) -> some View {
        let presets = equalizer.capabilities?.presets ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Equalizer")
                Spacer()
                Picker("Equalizer", selection: Binding(
                    get: { retainedHeadphoneControls.map(\.equalizer.presetID) ?? headphones.equalizer.presetID },
                    set: { if let preset = $0 { headphones.setEqualizerPreset(preset) } }
                )) {
                    if !presets.contains(where: { $0.id == equalizer.presetID }) {
                        Text(equalizer.presetTitle ?? String(localized: "Loading…"))
                            .tag(equalizer.presetID).disabled(true)
                    }
                    ForEach(presets) { preset in
                        Text(preset.title).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .tint(.primary)
                .disabled(!headphones.equalizer.canSelectPreset || headphones.listeningModeExcludesEqualizer
                          || (equalizer.supportsULT && (headphones.isEqualizerUpdatePending
                              || headphones.pendingChanges[.equalizerReadback] != nil)))
                .accessibilityIdentifier("equalizer.preset")
            }
            if let mode = equalizer.ultMode {
                LabeledContent("ULT Mode", value: mode.title)
                    .font(.caption)
                    .accessibilityIdentifier("equalizer.ultSummary")
            }
            if let error = headphones.settingErrors[.equalizer] {
                Text(error).font(.caption).foregroundStyle(.primary)
            }
        }
    }

    private func footer(_ retained: MenuBarHeadphoneControls?, locksHeadphoneControls: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                dismissMenu()
                showSettings()
            } label: {
                Label("More Settings…", systemImage: "gear")
                    .frame(height: 24)
            }
                .keyboardShortcut(",")
                .accessibilityIdentifier("menu.settings")
            Spacer()
            Button {
                devices.refreshControls(for: headphones)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
                .help("Refresh headphone status")
                .accessibilityLabel("Refresh headphone status")
                .keyboardShortcut("r")
                .disabled(locksHeadphoneControls || headphones.powerOffState != nil || headphones.isRunningHeadphoneTest || (showsLDACSession && !headphones.isReady))
            Menu {
                Button("Custom Equalizer…", action: showEqualizer)
                    .disabled(locksHeadphoneControls)
                if !settings.equalizerProfiles.isEmpty {
                    Menu("Saved Equalizers") {
                        ForEach(settings.equalizerProfiles) { profile in
                            Button(profile.name) {
                                settings.customEqualizerDraft = profile.settings
                                headphones.setCustomEqualizer(profile.settings)
                            }
                            .disabled(headphones.equalizer.settingsPayload(profile.settings) == nil)
                        }
                    }
                    .disabled(locksHeadphoneControls || headphones.powerOffState != nil || headphones.isRunningHeadphoneTest)
                }
                Divider()
                if retained?.supportsPowerOff ?? headphones.supportsPowerOff {
                    Button("Turn Off Headphones…", systemImage: "power") {
                        if let session = headphones.powerOffSession {
                            powerOffTarget = .init(controller: headphones, session: session, name: headphones.deviceName)
                            showsPowerOffConfirmation = true
                        }
                    }
                    .disabled(locksHeadphoneControls || !headphones.canPowerOff)
                    .help(headphones.powerOffUnavailableReason ?? String(localized: "Turn off the headphones on all connected devices"))
                    .accessibilityIdentifier("headphones.powerOff")
                    Divider()
                }
                Button("About Acouplet", action: showAbout)
                .accessibilityIdentifier("menu.about")
                Divider()
                if settings.hasBackgroundService {
                    Button("Background Service…") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Button("Quit Acouplet") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            .help("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 360)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .tint(nil)
        .foregroundStyle(.primary)
    }

    private func showAbout() {
        dismissMenu()
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showEqualizer() {
        openWindow(id: "equalizer")
        dismissMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissMenu() {
        if let closeMenu { closeMenu() }
        else { dismiss() }
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
struct LDACDriverGuidance: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var ldac: LDACController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch ldac.driverState {
            case .missing, .outdated, .updateAvailable:
                switch ldac.driverState {
                case .missing: Text("LDAC needs an audio driver. Install it, then restart your Mac.")
                case .updateAvailable: Text("An LDAC audio driver update is available. Install it, then restart your Mac.")
                default: Text("An LDAC audio driver update is required. Install it, then restart your Mac.")
                }
                Button(ldac.driverState == .missing ? String(localized: "Install Audio Driver…") : String(localized: "Update Audio Driver…")) {
                    ldac.installDriver()
                }
                .disabled(ldac.isOpeningDriverInstaller || ldac.isSessionRunning)
                .buttonStyle(.bordered)
                .tint(.primary)
                .accessibilityIdentifier("audio.installDriver")
            case .restartRequired:
                Text("The LDAC audio driver is installed. Restart your Mac to activate it.")
            case .unavailable(let message):
                Text(message)
            case .current:
                if let reason = ldac.deviceUnavailableReason(forAddress: headphones.address) {
                    Text(reason)
                }
            }
            if let error = ldac.driverInstallationError { Text(error) }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("audio.driverGuidance")
        .onAppear { ldac.refreshDriverState() }
    }
}

struct LDACPermissionGuidance: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var ldac: LDACController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow Acouplet and Acouplet Audio in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then retry LDAC.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Privacy & Security…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
                .accessibilityIdentifier("audio.ldacPrivacySettings")
                Button("Retry LDAC") { ldac.setEnabled(true, forAddress: headphones.address, configuration: settings.ldacConfiguration) }
                    .disabled(!ldac.canEnable(forAddress: headphones.address))
                    .accessibilityIdentifier("audio.ldacRetry")
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .accessibilityIdentifier("audio.ldacPermissionGuidance")
    }
}
#endif

struct ConnectedHeadphonePicker: View {
    var showsIconOnly = false
    @EnvironmentObject private var devices: SonyDeviceCoordinator

    var body: some View {
        if showsIconOnly {
            Menu {
                selectionPicker.pickerStyle(.inline)
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuIndicator(.hidden)
            .headphoneButtonStyle()
            .buttonBorderShape(.circle)
            .fixedSize()
            .tint(.primary)
            .accessibilityLabel("Choose Headphones")
            .accessibilityValue(devices.selectedController.deviceName)
            .accessibilityIdentifier("headphones.devicePicker")
            .help("Choose headphones")
        } else {
            selectionPicker
                .pickerStyle(.menu)
                .menuIndicator(.visible)
                .tint(.primary)
                .accessibilityIdentifier("headphones.devicePicker")
        }
    }

    private var selectionPicker: some View {
        Picker("Device", selection: Binding(
            get: { devices.selectedAddress },
            set: { if let address = $0 { devices.select(address: address) } }
        )) {
            if let address = devices.selectedAddress, !devices.selectableDevices.contains(where: { $0.address == address }) {
                Text(devices.selectedController.deviceName).tag(Optional(address)).disabled(true)
            }
            ForEach(devices.connectedDevices) { device in
                Text(Self.title(for: device, among: devices.selectableDevices))
                    .tag(Optional(device.address))
            }
            let disconnected = devices.selectableDevices.filter { device in
                !devices.connectedDevices.contains(where: { $0.address == device.address })
            }
            if !disconnected.isEmpty {
                Section("Sound may still be playing") {
                    ForEach(disconnected) { device in
                        Text(Self.title(for: device, among: devices.selectableDevices))
                            .tag(Optional(device.address))
                    }
                }
            }
        }
    }

    static func title(for device: SonyConnectedDevice, among devices: [SonyConnectedDevice]) -> String {
        guard devices.contains(where: { $0.address != device.address && ($0.model == device.model || $0.name == device.name) }) else {
            return device.name
        }
        let address = devices.contains { $0.address != device.address && $0.name == device.name && $0.address.suffix(5) == device.address.suffix(5) }
            ? device.address : String(device.address.suffix(5))
        return "\(device.name) · \(address)"
    }
}

struct ConnectionStatusIndicator: View {
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.orange)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffectsRemoved(reduceMotion)
                    .transition(.symbolEffect(.appear))
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct HeadphoneConnectionView: View {
    var connectOnly = false
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator

    var body: some View {
        Group {
            if !headphones.isReady || headphones.powerOffState != nil || headphones.headphoneTestNeedsRecovery {
                if connectOnly {
                    Button("Connect", action: connect)
                        .headphoneButtonStyle(prominent: true)
                        .disabled(headphones.multipointTransition?.isFinished == false)
                        .accessibilityIdentifier("headphones.connect")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            HStack(spacing: 10) {
                                ConnectionStatusIndicator(isLoading: isLoading)
                                Text(connectionTitle).font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("headphones.connectionStatus")
                            Spacer(minLength: 0)
                            if !isLoading && !headphones.isBluetoothAccessDenied {
                                Button(hasConnectionFailure ? String(localized: "Retry") : String(localized: "Connect"), action: connect)
                                    .headphoneButtonStyle()
                                    .accessibilityIdentifier("headphones.connect")
                            }
                        }
                        if isSearching || headphones.powerOffState != nil || headphones.headphoneTestNeedsRecovery {
                            Text(connectionDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 26)
                        } else if headphones.isBluetoothAccessDenied {
                            Text("Allow Acouplet to use Bluetooth in [System Settings](x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth).")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 26)
                        } else if !isLoading {
                            if let message = connectionFailureMessage {
                                Text(message)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 26)
                                    .accessibilityIdentifier("headphones.connectionFailure")
                                Link("Bluetooth Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                                    .foregroundStyle(.tint)
                                    .padding(.leading, 26)
                                    .accessibilityIdentifier("headphones.bluetoothSettings")
                            } else {
                                Text("If this continues, disconnect and reconnect the headphones in [Bluetooth Settings](x-apple.systempreferences:com.apple.BluetoothSettings).")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 26)
                                    .accessibilityIdentifier("headphones.bluetoothSettings")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func connect() {
        if headphones.address.isEmpty { devices.refreshDiscovery() }
        else { headphones.connect() }
    }

    private var isLoading: Bool {
        isSearching || isConnecting || isRecoveringMultipoint || headphones.isPoweringOff
    }

    private var isSearching: Bool { headphones.linkState == .searching }

    private var isRecoveringMultipoint: Bool { headphones.multipointTransition?.phase == .recovering }

    private var isConnecting: Bool {
        headphones.linkState == .opening || headphones.linkState == .handshaking
    }

    private var hasConnectionFailure: Bool {
        if case .failed = headphones.linkState { return true }
        return headphones.linkState == .controlBusy || connectionFailureMessage != nil
    }

    private var connectionFailureMessage: String? {
        if let message = headphones.lastErrorMessage { return message }
        if case .failed(let message) = headphones.linkState { return message }
        return nil
    }

    private var connectionTitle: String {
        if headphones.isBluetoothAccessDenied { return String(localized: "Bluetooth access is not allowed.") }
        if headphones.headGesturePracticeTransition?.phase == .interrupted { return String(localized: "Head Gesture Practice Needs Attention") }
        if headphones.earTipFitTransition?.phase == .interrupted { return String(localized: "Fit Test Needs Attention") }
        if headphones.legacyOptimizerTransition?.phase == .interrupted { return String(localized: "Noise Cancelling Optimizer") }
        if isRecoveringMultipoint { return String(localized: "Reconnecting Controls…") }
        return switch headphones.powerOffState {
        case .sending: String(localized: "Sending Power Off…")
        case .acknowledged: String(localized: "Power Off Requested")
        case .disconnected: String(localized: "Headphones Disconnected")
        case .unconfirmed: String(localized: "Power Off Not Confirmed")
        case nil: isSearching ? String(localized: "Checking Bluetooth…") : isConnecting ? String(localized: "Connecting…") : hasConnectionFailure ? String(localized: "Couldn’t connect to controls") : String(localized: "Not Connected")
        }
    }

    private var connectionDescription: String {
        if headphones.headGesturePracticeTransition?.phase == .interrupted, let message = headphones.headGesturePracticeTransition?.message { return message }
        if headphones.earTipFitTransition?.phase == .interrupted, let message = headphones.earTipFitTransition?.message { return message }
        if headphones.legacyOptimizerTransition?.phase == .interrupted, let message = headphones.legacyOptimizerTransition?.message { return message }
        if let state = headphones.powerOffState {
            let outcome: String
            switch state {
            case .sending: return String(localized: "Waiting for the headphones to acknowledge the command…")
            case .acknowledged: outcome = String(localized: "The headphones received the command. Their power state cannot be checked.")
            case .disconnected: outcome = String(localized: "The control connection closed after the power-off request. Their power state cannot be checked.")
            case .unconfirmed: outcome = String(localized: "The headphones did not acknowledge the command. They may already be off.")
            }
            let turnOn = headphones.deviceModel.isEarbuds
                ? String(localized: "To turn them on again, put both earbuds in the case, then take them out.")
                : String(localized: "Turn the headphones on with their power button before reconnecting.")
            return String(localized: "\(outcome) Automatic reconnect is paused. \(turnOn)")
        }
        return headphones.statusText
    }
}

enum EarbudSide {
    case left, right
}

extension SonyProductArtwork {
    var heroImage: NSImage? {
        Self.image(named: hero, bounds: heroBounds)
    }

    func earbudImage(for side: EarbudSide) -> NSImage? {
        guard let name = side == .left ? left : right else { return nil }
        return Self.image(named: name, bounds: side == .left ? leftBounds : rightBounds)
    }

    private static func image(named name: String, bounds: Bounds?) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        guard let bounds,
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let rect = CGRect(x: (bounds.x * Double(bitmap.width)).rounded(),
                          y: (bounds.y * Double(bitmap.height)).rounded(),
                          width: (bounds.width * Double(bitmap.width)).rounded(),
                          height: (bounds.height * Double(bitmap.height)).rounded())
        guard let cropped = bitmap.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: .zero)
    }
}

private struct OpenChargingCaseArtwork: View {
    let model: SonyDeviceModel
    let artwork: SonyProductArtwork?
    let suffix: String

    private var placement: (height: CGFloat, offset: CGFloat) {
        if model == .wfXM5, suffix.isEmpty { return (128, 0) }
        let bounds: (height: CGFloat, center: CGFloat)
        switch (model, suffix) {
        case (.wfXM5, "SmokyPink"): bounds = (559, 638.5)
        case (.wfXM5, _): bounds = (557, 638.5)
        case (.wfXM6, "Silver"): bounds = (554, 605)
        default: bounds = (557, 526.5)
        }
        return (128 * 1000 / bounds.height, 128 * (500 - bounds.center) / bounds.height)
    }

    var body: some View {
        Group {
            #if ACOUPLET_NO_SONY_ARTWORK
            caseSymbol
            #else
            if let name = artwork?.openCase, let image = NSImage(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: placement.height)
                    .offset(y: placement.offset)
                    .frame(width: 220, height: 128)
                    .clipped()
            } else {
                caseSymbol
            }
            #endif
        }
        .accessibilityLabel("\(model.name) earbuds charging in their case")
        .accessibilityIdentifier("device.artwork.openCase")
    }

    private var caseSymbol: some View {
        Image(nsImage: DeviceIcon.caseImage(model: model))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 128)
    }
}

struct EarbudArtwork: View {
    let model: SonyDeviceModel
    let side: EarbudSide
    let artwork: SonyProductArtwork?

    private var image: NSImage? {
        artwork?.earbudImage(for: side)
    }

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else if let symbol = side == .left ? model.leftSymbol : model.rightSymbol,
                      let image = NSImage(named: symbol) {
                let size = NSSize(width: image.size.width / 2, height: image.size.height)
                let cropped = NSImage(size: size, flipped: false) { rect in
                    image.draw(in: rect, from: NSRect(origin: NSPoint(x: side == .left ? 0 : size.width, y: 0), size: size),
                               operation: .sourceOver, fraction: 1)
                    return true
                }
                Image(nsImage: cropped)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Image(nsImage: DeviceIcon.fallbackEarbudImage(side: side))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .aspectRatio(137.0 / 103.0, contentMode: .fit)
        .accessibilityLabel(String(localized: "\(side == .left ? String(localized: "Left") : String(localized: "Right")) \(model.name) earbud"))
    }
}

struct DeviceIcon: View {
    let model: SonyDeviceModel
    let leftConnected: Bool?
    let rightConnected: Bool?

    var body: some View {
        if let leftSymbol = model.leftSymbol, let rightSymbol = model.rightSymbol {
            ZStack {
                Image(leftSymbol)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .opacity(leftConnected == false ? 0.35 : 1)
                Image(rightSymbol)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .opacity(rightConnected == false ? 0.35 : 1)
            }
        } else if model.isEarbuds {
            HStack(spacing: 1) {
                Image(nsImage: Self.fallbackEarbudImage(side: .left))
                    .resizable()
                    .scaledToFit()
                    .opacity(leftConnected == false ? 0.35 : 1)
                Image(nsImage: Self.fallbackEarbudImage(side: .right))
                    .resizable()
                    .scaledToFit()
                    .opacity(rightConnected == false ? 0.35 : 1)
            }
        } else if let symbol = model.symbol {
            Image(symbol)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: model.systemSymbol)
                .resizable()
                .scaledToFit()
        }
    }

    static func fallbackEarbudImage(side: EarbudSide) -> NSImage {
        if let image = NSImage(systemSymbolName: "earbuds.stemless." + (side == .left ? "left" : "right"), accessibilityDescription: nil) {
            return image
        }
        let image = NSImage(systemSymbolName: "earbuds", accessibilityDescription: nil)!
        let size = NSSize(width: image.size.width / 2, height: image.size.height)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: NSRect(origin: NSPoint(x: side == .left ? 0 : size.width, y: 0), size: size),
                       operation: .sourceOver, fraction: 1)
            return true
        }
    }

    static func caseImage(model: SonyDeviceModel) -> NSImage {
        model.caseSymbol.flatMap(NSImage.init(named:)).map { $0.copy() as! NSImage }
            ?? NSImage(systemSymbolName: "earbuds.case", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "case", accessibilityDescription: nil)!
    }

    static func connectionValue(left: Bool?, right: Bool?) -> String {
        String(localized: "Left: \(left.map { $0 ? String(localized: "Connected") : String(localized: "Disconnected") } ?? String(localized: "Unknown")), Right: \(right.map { $0 ? String(localized: "Connected") : String(localized: "Disconnected") } ?? String(localized: "Unknown"))")
    }

    static func batteryColor(for reading: BatteryReading?) -> NSColor? {
        guard let reading else { return nil }
        return reading.level <= 20 ? .systemRed : nil
    }

    static func menuBarImage(model: SonyDeviceModel, leftConnected: Bool?, rightConnected: Bool?, batteries: SonyBatteries = .init(), chargingCase: Bool = false, foregroundColor: NSColor = .labelColor) -> NSImage {
        if chargingCase {
            let symbol = caseImage(model: model)
            let color = batteries.caseBattery?.isCharging == true ? nil : batteryColor(for: batteries.caseBattery)
            let image = color.map { tinted(symbol, color: $0) } ?? symbol
            image.isTemplate = color == nil
            return image
        }
        let size = model.leftSymbol.flatMap(NSImage.init(named:))?.size ?? NSSize(width: 22, height: 18)
        let leftColor = leftConnected == false ? nil : batteryColor(for: batteries.left)
        let rightColor = rightConnected == false ? nil : batteryColor(for: batteries.right)
        let singleColor = batteryColor(for: batteries.single)
        let hasWarning = model.isEarbuds ? leftColor != nil || rightColor != nil : singleColor != nil
        let image = NSImage(size: size, flipped: false) { rect in
            if let left = model.leftSymbol, let right = model.rightSymbol {
                for (name, connected, color) in [(left, leftConnected, leftColor), (right, rightConnected, rightColor)] {
                    let symbol = NSImage(named: name)!
                    let part = hasWarning ? tinted(symbol, color: color ?? foregroundColor) : symbol
                    part.draw(in: rect, from: .zero, operation: .sourceOver, fraction: connected == false ? 0.35 : 1)
                }
            } else if model.isEarbuds {
                for (side, connected, color) in [(EarbudSide.left, leftConnected, leftColor), (.right, rightConnected, rightColor)] {
                    let symbol = fallbackEarbudImage(side: side)
                    let part = hasWarning ? tinted(symbol, color: color ?? foregroundColor) : symbol
                    let partRect = NSRect(x: side == .left ? rect.minX : rect.midX + 0.5, y: rect.minY,
                                          width: rect.width / 2 - 0.5, height: rect.height)
                    let scale = min(partRect.width / symbol.size.width, partRect.height / symbol.size.height)
                    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                    let bounds = NSRect(x: partRect.midX - size.width / 2, y: partRect.midY - size.height / 2, width: size.width, height: size.height)
                    part.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: connected == false ? 0.35 : 1)
                }
            } else {
                let symbol = model.symbol.flatMap(NSImage.init(named:))
                    ?? NSImage(systemSymbolName: model.systemSymbol, accessibilityDescription: model.name)!
                (singleColor.map { tinted(symbol, color: $0) } ?? symbol).draw(in: rect)
            }
            return true
        }
        image.isTemplate = !hasWarning
        return image
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

private struct MultipointPopoverContent: View {
    @ObservedObject var headphones: SonyHeadphonesController
    @ObservedObject var settings: SettingsStore
    let maximumHeight: CGFloat
    let selectSource: @MainActor (SonyMultipointDevice) -> Void
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MultipointSettingControl(compact: true)
                if MultipointControls.isVisible(for: headphones.multipoint) {
                    Divider()
                    MultipointControls(compact: true, selectSource: selectSource)
                }
                Divider()
                Button("Bluetooth Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                .buttonStyle(.borderless)
                .tint(nil)
                .foregroundStyle(settings.tintColor)
                .accessibilityIdentifier("multipoint.bluetoothSettings")
            }
            .padding(14)
            .font(.body)
            .fontWeight(.regular)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .environmentObject(headphones)
        .controlSize(.regular)
        .foregroundStyle(Color.primary)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
        .accessibilityIdentifier("multipoint.popover")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
}

private struct MultipointPopover: NSViewRepresentable {
    @Binding var isPresented: Bool
    let headphones: SonyHeadphonesController
    let settings: SettingsStore
    let maximumHeight: CGFloat
    let selectSource: @MainActor (SonyMultipointDevice) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.schedulePresentation() }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.update(self, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.stop()
    }

    final class AnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var owner: MultipointPopover
        private weak var anchor: AnchorView?
        private let popover = NSPopover()
        private var controller: NSHostingController<MultipointPopoverContent>?
        private var measuredContentSize = NSSize.zero

        init(_ owner: MultipointPopover) {
            self.owner = owner
            super.init()
            popover.behavior = .transient
            popover.delegate = self
        }

        func update(_ owner: MultipointPopover, anchor: AnchorView) {
            self.owner = owner
            self.anchor = anchor
            if owner.isPresented {
                let content = MultipointPopoverContent(headphones: owner.headphones, settings: owner.settings, maximumHeight: owner.maximumHeight,
                                                      selectSource: owner.selectSource) { [weak self] size in
                    self?.measuredContentSize = size
                    self?.schedulePresentation()
                }
                if let controller {
                    controller.rootView = content
                } else {
                    let controller = NSHostingController(rootView: content)
                    controller.sizingOptions = []
                    self.controller = controller
                    popover.contentViewController = controller
                    measuredContentSize = controller.sizeThatFits(in: NSSize(width: 320, height: owner.maximumHeight))
                }
            }
            schedulePresentation()
        }

        func schedulePresentation() {
            DispatchQueue.main.async { [weak self] in self?.updatePresentation() }
        }

        private func updatePresentation() {
            guard owner.isPresented else {
                popover.close()
                popover.contentViewController = nil
                controller = nil
                return
            }
            guard let anchor, let window = anchor.window, window.isVisible,
                  measuredContentSize.width > 0, measuredContentSize.height > 0 else { return }
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.appearance = window.effectiveAppearance
            if measuredContentSize != popover.contentSize { popover.contentSize = measuredContentSize }
            if !popover.isShown {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
                popover.contentViewController?.view.window?.makeKey()
            }
        }

        func popoverDidClose(_ notification: Notification) {
            owner.isPresented = false
            popover.contentViewController = nil
            controller = nil
            measuredContentSize = .zero
        }

        func stop() {
            anchor = nil
            popover.delegate = nil
            popover.close()
            popover.contentViewController = nil
            controller = nil
            let binding = owner.$isPresented
            if binding.wrappedValue {
                DispatchQueue.main.async { binding.wrappedValue = false }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func headphoneButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    func windowResizeAnchorIfAvailable(_ anchor: UnitPoint) -> some View {
        if #available(macOS 26.0, *) { windowResizeAnchor(anchor) }
        else { self }
    }
}
