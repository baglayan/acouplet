import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

extension SettingsStore {
    var controlAccentColor: NSColor {
        if useSystemAccentColor { return .controlAccentColor }
        return NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 170.0 / 255, green: 137.0 / 255, blue: 64.0 / 255, alpha: 1)
            }
            return NSColor(srgbRed: 140.0 / 255, green: 107.0 / 255, blue: 10.0 / 255, alpha: 1)
        }
    }
    var tintColor: Color { Color(nsColor: controlAccentColor) }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var devices: SonyDeviceCoordinator
    @EnvironmentObject private var audioRoute: MacAudioRouteObserver
    private var selectMultipointSource = MultipointSourceSelection()
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    @State private var showsDriverRemovalConfirmation = false
    @State private var isOpeningDriverRemoval = false
    @State private var driverRemovalError: String?
    #endif
    #if ACOUPLET_SPARKLE
    @EnvironmentObject private var updater: AppUpdater
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if DEBUG
        let _ = SettingsLifecycleProbe.recordBody()
        #endif
        TabView(selection: $settings.selectedSettingsPane) {
            Tab("General", systemImage: "gear", value: "general") {
                general
            }
            Tab(headphones.deviceModel.isSpeaker ? String(localized: "Speakers") : String(localized: "Headphones"),
                systemImage: headphones.deviceModel.systemSymbol, value: "headphones") {
                headphoneControls
            }
            Tab("Advanced", systemImage: "gearshape.2", value: "advanced") {
                advanced
            }
        }
        .formStyle(.grouped)
        .accentColor(settings.tintColor)
        .tint(settings.tintColor)
        .accessibilityIdentifier("settings.form")
        .onAppear {
            settings.refreshLaunchStatus()
            settings.refreshAppLanguage()
            #if DEBUG
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.appearances += 1 }
            #endif
        }
        .task(id: soundPressureRefreshInterval) {
            guard let interval = soundPressureRefreshInterval else { return }
            while !Task.isCancelled {
                headphones.refreshSoundPressure(automatically: true)
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
        .onChange(of: soundPressureRefreshInterval) { _, interval in
            if interval == nil { headphones.invalidateSoundPressureReading() }
        }
        .onDisappear {
            headphones.invalidateSoundPressureReading()
            #if DEBUG
            if SettingsLifecycleProbe.isEnabled { SettingsLifecycleProbe.disappearances += 1 }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                settings.refreshLaunchStatus()
                settings.refreshAppLanguage()
            }
            else { headphones.invalidateSoundPressureReading() }
        }
        .onChange(of: settings.selectedSettingsPane) { _, pane in
            if pane != "headphones" { headphones.invalidateSoundPressureReading() }
        }
        .onChange(of: headphones.connectionTransition?.alert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
        .onChange(of: headphones.bluetoothStandbyAlert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
        .onChange(of: headphones.lightingModeAlert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
        .onChange(of: headphones.multipointTransition?.alert, initial: true) { _, alert in
            if alert != nil { settings.selectedSettingsPane = "headphones" }
        }
    }

    private var soundPressureRefreshInterval: Int? {
        guard scenePhase == .active, settings.selectedSettingsPane == "headphones", headphones.isReady, headphones.powerOffState == nil, !headphones.isRunningHeadphoneTest,
              headphones.soundPressure.available == true, !headphones.soundPressure.isStopped,
              !headphones.soundPressureAutomaticRefreshSuspended,
              headphones.connectionTransition?.isFinished != false, headphones.sourceTransition?.isFinished != false,
              headphones.multipointTransition?.isFinished != false, headphones.deviceActionTransition?.isFinished != false else { return nil }
        return headphones.soundPressure.intervalSeconds
    }

    private var general: some View {
        Form {
            Section {
                Picker("App language", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.setAppLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.appLanguage")
                if settings.appLanguageNeedsRestart {
                    Text("Quit and reopen Acouplet to apply the language change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.appLanguageRestart")
                }
                Toggle("Use system accent color", isOn: $settings.useSystemAccentColor)
                    .accessibilityIdentifier("settings.systemAccent")
            }
            Section("Menu Bar") {
                Toggle("Keep icon visible when disconnected", isOn: $settings.keepMenuBarIconWhenDisconnected)
                    .accessibilityIdentifier("menuBar.keepIcon")
                Toggle("Show battery percentage", isOn: $settings.showBatteryInMenuBar)
            }
            Section("Connection") {
                Toggle("Reconnect automatically", isOn: $settings.reconnectAutomatically)
                if settings.hasBackgroundService {
                    LabeledContent("Background access") {
                        Text(settings.backgroundServiceStatus == .enabled ? String(localized: "Allowed") : String(localized: "Not enabled")).foregroundStyle(.primary)
                    }
                    Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                } else {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                }
                if let error = settings.backgroundServiceMigrationError ?? settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if settings.backgroundServiceMigrationError != nil {
                        Button("Retry") { settings.retryBackgroundServiceMigration?() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Keyboard") {
                Toggle("Global ANC / Ambient shortcut", isOn: $settings.globalShortcutEnabled)
                    .help("Available while Acouplet is running.")
                LabeledContent("Shortcut") {
                    Text("⌥⌘A").foregroundStyle(.primary)
                }
                if let error = settings.globalShortcutError {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
            #if !ACOUPLET_PUBLIC_APIS_ONLY
            Section("Alerts") {
                Toggle("Low battery", isOn: $settings.lowBatteryNotificationsEnabled)
                .accessibilityIdentifier("notifications.lowBattery")
                Toggle("Firmware updates", isOn: $settings.firmwareNotificationsEnabled)
                .accessibilityIdentifier("notifications.firmware")
            }
            Section("Experimental Features") {
                Toggle("Show LDAC controls", isOn: $settings.experimentalLDACEnabled)
                    .accessibilityIdentifier("experimental.ldac")
                if settings.experimentalLDACEnabled {
                    Picker("Sample Rate", selection: $settings.ldacConfiguration.sampleRate) {
                        ForEach(LDACSampleRate.allCases, id: \.self) { rate in
                            Text(rate.displayName).tag(rate)
                        }
                    }
                    .disabled(!ldac.canChangeConfiguration)
                    .accessibilityIdentifier("ldac.sampleRate")
                    if case let .active(format) = ldac.state, let activeRate = LDACSampleRate(rawValue: format.sampleRateHz) {
                        LabeledContent("Active LDAC Rate", value: activeRate.displayName)
                        if let sourceRate = format.sourceSampleRateHz.flatMap(LDACSampleRate.init(rawValue:)),
                           sourceRate.rawValue != format.sampleRateHz {
                            LabeledContent("Mac Audio Capture Rate", value: sourceRate.displayName)
                        }
                    }
                    if let error = ldac.sampleRateChangeError {
                        Text(error).font(.caption)
                    }
                    Picker("Playback Quality", selection: $settings.ldacConfiguration.quality) {
                        ForEach(LDACQuality.allCases, id: \.self) { quality in
                            let configuration = LDACConfiguration(sampleRate: settings.ldacConfiguration.sampleRate, quality: quality)
                            Text(configuration.qualityDisplayName).tag(quality)
                        }
                    }
                    .disabled(!ldac.canChangeConfiguration)
                    .accessibilityIdentifier("ldac.quality")
                    if !ldac.isSessionRunning { LDACDriverGuidance() }
                }
                if settings.experimentalLDACEnabled, ldac.targetAddress == headphones.address,
                   ldac.audioCaptureAccess == .permissionRequired {
                    LDACPermissionGuidance()
                }
                if hasInstalledLDACDriver {
                    Button("Remove LDAC Audio Driver…") { showsDriverRemovalConfirmation = true }
                        .disabled(ldac.needsStopBeforeTermination || ldac.isOpeningDriverInstaller || isOpeningDriverRemoval
                                  || settings.backgroundServiceMigrationError != nil)
                        .alert("Remove LDAC Audio Driver?", isPresented: $showsDriverRemovalConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Continue") {
                                isOpeningDriverRemoval = true
                                driverRemovalError = nil
                                Task {
                                    do {
                                        try await LDACDriverInstaller.openUninstaller()
                                        NSApp.terminate(nil)
                                    } catch {
                                        driverRemovalError = error.localizedDescription
                                    }
                                    isOpeningDriverRemoval = false
                                }
                            }
                        } message: {
                            Text("Acouplet will quit and open the removal installer. Restart your Mac after removing the driver.")
                        }
                    if let driverRemovalError {
                        Text(driverRemovalError).font(.caption).foregroundStyle(.primary)
                    }
                }
            }
            #endif
            #if ACOUPLET_SPARKLE
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updater.allowsAutomaticUpdates)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("settings.version")
            }
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    private var hasInstalledLDACDriver: Bool {
        switch ldac.driverState {
        case .current, .outdated, .updateAvailable, .restartRequired: true
        case .missing, .unavailable: false
        }
    }
    #endif

    private var headphoneControls: some View {
        Form {
            Section("Headphones") {
                if devices.hasOtherSelectableDevices {
                    ConnectedHeadphonePicker()
                } else {
                    LabeledContent("Device") {
                        Text(headphones.deviceName)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("headphones.deviceName")
                    }
                }
                if let color = headphones.deviceInformation.color {
                    LabeledContent("Color") {
                        Text(color.title).foregroundStyle(.primary)
                    }
                }
                if let firmware = headphones.firmwareVersionLabel {
                    #if !ACOUPLET_PUBLIC_APIS_ONLY
                    FirmwareUpdateControl(firmware: firmware)
                    #else
                    LabeledContent("Firmware") {
                        Text(firmware).foregroundStyle(.primary)
                    }
                    #endif
                }
                HeadphoneConnectionView()
            }
            Section("Sound") {
                LabeledContent("Mac audio output", value: audioOutputName)
                    .accessibilityIdentifier("audio.macOutput")
                Link("Sound Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                    .foregroundStyle(.tint)
                if headphones.supportsConnectionMode || headphones.connectionTransition != nil {
                    ConnectionModeControl()
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
                }
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                if ldac.hasPendingConnectionPreferenceRestoration(forAddress: headphones.address) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restore the previous Stable Connection preference?")
                            .font(.caption)
                        HStack {
                            Button("Restore Stable Connection") {
                                ldac.restorePendingConnectionPreference(forAddress: headphones.address)
                            }
                            .disabled(!ldac.canRestoreConnectionPreference(forAddress: headphones.address))
                            Button("Keep Current Preference") {
                                ldac.keepConnectionPreference(forAddress: headphones.address)
                            }
                            .disabled(ldac.needsStopBeforeTermination)
                        }
                    }
                }
                #endif
                if headphones.supportsCodecStatus {
                    LabeledContent("Headphone codec") {
                        Text(headphones.audioCodec?.title ?? String(localized: "Unknown")).foregroundStyle(.primary)
                    }
                        .accessibilityIdentifier("audio.codec")
                        .help("Reported by the headphones. With two devices connected, this may describe audio from the other device.")
                }
                if headphones.soundPressure.isSupported { SoundPressureControl() }
                if headphones.volumeProtection.supportsSafeVolume || headphones.volumeProtection.supportsMaxVolume {
                    VolumeProtectionControl()
                }
                if headphones.adaptiveVolumeWithLimitation.isSupported {
                    AdaptiveVolumeWithLimitationControl()
                } else if headphones.systemFeatureState(.adaptiveVolume) != nil {
                    SystemFeatureControl(feature: .adaptiveVolume)
                    Text("Adjusts headphone volume as the surrounding noise changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if headphones.equalizer.bassBoost.inquiryType != nil { BassBoostControl(effect: headphones.equalizer.bassBoost) }
                if headphones.equalizer.turnKey.supportsImport || headphones.equalizer.turnKey.supportsManagement {
                    TurnKeyEqualizerControl()
                }
                if headphones.equalizer.ultSoundEffectAssignment.isSupported {
                    ULTSoundEffectAssignmentControl()
                }
                if headphones.equalizer.soundEffect.isSupported {
                    SpeakerSoundEffectControl()
                }
                if headphones.equalizer.customEQ.isSupported {
                    SpeakerCustomEQControl()
                }
                if headphones.equalizer.customSoundEffect.isSupported {
                    CustomSoundEffectControl()
                }
                if headphones.equalizer.lrBalanceCorrection.isSupported {
                    switch headphones.equalizer.lrBalanceCorrection.mode {
                    case .on, .off:
                        Toggle("Left/right balance correction", isOn: Binding(
                            get: { headphones.equalizer.lrBalanceCorrection.mode == .on },
                            set: headphones.setLRBalanceCorrection
                        ))
                        .disabled(!headphones.canSetLRBalanceCorrection)
                        .accessibilityIdentifier("audio.lrBalanceCorrection")
                    case .offNotInitialized:
                        LabeledContent("Left/right balance correction", value: String(localized: "Setup required"))
                    case .outOfRange, nil:
                        LabeledContent("Left/right balance correction", value: String(localized: "Unknown"))
                    }
                    if headphones.pendingChanges[.lrBalanceCorrection] != nil { ProgressView().controlSize(.small) }
                    if let error = headphones.settingErrors[.lrBalanceCorrection] { Text(error).font(.caption) }
                }
                if headphones.legacySurround.isSupported { LegacySoundEffectControl(kind: .surround) }
                if headphones.legacySoundPosition.isSupported { LegacySoundEffectControl(kind: .soundPosition) }
                if headphones.supportsDSEE {
                    DSEEControl().disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
                }
                if headphones.supportsUpscalingStatus {
                    LabeledContent("Upscaling type", value: headphones.upscalingIndicatorType?.title ?? String(localized: "Unknown"))
                        .accessibilityIdentifier("audio.upscalingType")
                    LabeledContent("Upscaling status", value: headphones.upscalingIndicatorStatus?.title ?? String(localized: "Unknown"))
                        .accessibilityIdentifier("audio.upscalingStatus")
                }
            }
            if headphones.playback.isSupported {
                Section("Playback") { HeadphonePlaybackControl() }
            }
            if headphones.audioFeatures.supportsListeningMode {
                Section("Listening Mode") { ListeningModeControls() }
            } else if let leakage = headphones.audioFeatures.soundLeakageReduction {
                Section("Listening Mode") {
                    if leakage.enabled != nil {
                        Toggle("Sound leakage reduction", isOn: Binding(
                            get: { headphones.audioFeatures.soundLeakageReduction?.enabled == true },
                            set: headphones.setSoundLeakageReduction
                        ))
                        .disabled(!headphones.canSetSoundLeakageReduction)
                        .accessibilityIdentifier("audio.soundLeakageReduction")
                    } else {
                        LabeledContent("Sound leakage reduction", value: String(localized: "Unknown"))
                    }
                    Text("Reduces sound leakage by lowering high-pitched sounds.")
                        .font(.caption).foregroundStyle(.secondary)
                    if headphones.pendingChanges[.soundLeakageReduction] != nil {
                        ProgressView().controlSize(.small)
                    }
                    if let error = headphones.settingErrors[.soundLeakageReduction] { Text(error).font(.caption) }
                    if leakage.enabled == true {
                        if headphones.soundLeakageReductionExcludes(.equalizer) {
                            Text("Equalizer is unavailable in the current headphone mode.").font(.caption)
                        }
                        if headphones.soundLeakageReductionExcludes(.dsee) {
                            Text("DSEE is unavailable in the current headphone mode.").font(.caption)
                        }
                    }
                }
            }
            if !headphones.audioFeatures.supportsListeningMode, let voice = headphones.audioFeatures.voiceContents {
                Section("Listening Mode") {
                    if voice.enabled != nil {
                        Toggle("Voice boost", isOn: Binding(
                            get: { headphones.audioFeatures.voiceContents?.enabled == true },
                            set: headphones.setVoiceContents
                        ))
                        .disabled(!headphones.canSetVoiceContents)
                        .accessibilityIdentifier("audio.voiceContents")
                    } else {
                        LabeledContent("Voice boost", value: String(localized: "Unknown"))
                    }
                    if let reason = headphones.voiceContentsConnectionRestriction { Text(reason).font(.caption) }
                    if headphones.pendingChanges[.voiceContents] != nil { ProgressView().controlSize(.small) }
                    if let error = headphones.settingErrors[.voiceContents] { Text(error).font(.caption) }
                }
            }
            if let assignments = headphones.audioFeatures.listeningModeAssignments, assignments.enabled != false {
                Section("Listening mode button") {
                    ListeningModeAssignmentControls(assignments: assignments)
                }
            }
            if headphones.legacyControls?.standaloneNoiseCancel != nil || headphones.legacyControls?.standaloneAmbient != nil {
                Section("Listening Mode") {
                    LegacyStandaloneNoiseControl(inquiry: 1)
                    LegacyStandaloneNoiseControl(inquiry: 3)
                    if let error = headphones.settingErrors[.noiseControl] { Text(error).font(.caption) }
                }
            }
            if headphones.legacyOptimizer.isSupported || headphones.legacyOptimizerTransition != nil {
                Section("Noise Cancelling") { LegacyOptimizerControl() }
            }
            if headphones.noiseControl?.inquiryType == 0x19 {
                Section("Noise Adaptation") {
                    NoiseAdaptationControl()
                }
            }
            if headphones.noiseToggle != nil || headphones.noiseTest?.active == true {
                Section("Noise Control") {
                    NoiseToggleControl()
                    if headphones.noiseTest?.active == true {
                        HStack {
                            Text("A noise-control test is running.")
                            Spacer()
                            if headphones.pendingChanges[.noiseTest] != nil {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("End Test") { headphones.finishNoiseTest() }
                                    .disabled(!headphones.canFinishNoiseTest)
                                    .accessibilityIdentifier("noise.endTest")
                            }
                        }
                        if let error = headphones.settingErrors[.noiseTest] {
                            Text(error).font(.caption)
                        }
                    }
                }
            }
            if headphones.systemFeatures[.headGestures] != nil || headphones.headGesturePractice.isSupported || headphones.headGesturePracticeTransition != nil {
                Section("Head Gestures") {
                    SystemFeatureControl(feature: .headGestures)
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
                    if headphones.headGesturePractice.isSupported || headphones.headGesturePracticeTransition != nil {
                        HeadGesturePracticeControl()
                    }
                }
            }
            if headphones.earTipFit.isSupported || headphones.earTipFit.supportsEarpieceSelection || headphones.earTipFitTransition != nil
                || headphones.wearingPosition.isSupported {
                Section("Earbud Fit") {
                    if headphones.earTipFit.supportsEarpieceSelection {
                        LabeledContent("Ear-tip type", value: headphones.earTipFit.selectionTitle)
                            .accessibilityIdentifier("earpiece.selection")
                        if headphones.earTipFit.selectionAvailable == false {
                            Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if headphones.earTipFit.isSupported || headphones.earTipFitTransition != nil {
                        EarTipFitControl()
                    }
                    if headphones.wearingPosition.isSupported { WearingPositionControl() }
                }
            }
            FindEarbudsControl()
            if MultipointControls.isVisible(for: headphones.multipoint) || MultipointSettingControl.enabled(for: headphones) != nil
                || headphones.multipoint.supportsMusicHandover {
                Section("Devices") {
                    MultipointSettingControl()
                    if MultipointControls.isVisible(for: headphones.multipoint) {
                        MultipointControls { selectMultipointSource($0, on: headphones) }
                    }
                    if headphones.multipoint.supportsMusicHandover {
                        if let enabled = headphones.multipoint.musicHandoverEnabled {
                            Toggle(isOn: Binding(get: { enabled }, set: headphones.setMusicHandover)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Switch playback devices automatically")
                                    Text("Switch to the most recently started playback on a connected device.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!headphones.canSetMusicHandover)
                            .accessibilityIdentifier("multipoint.musicHandover")
                        } else {
                            LabeledContent("Switch playback devices automatically", value: "Unknown")
                        }
                        if let error = headphones.settingErrors[.musicHandover] {
                            Text(error).font(.caption)
                        }
                    }
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil)
            }
            let autoSwitch = headphones.linkAutoSwitch
            if autoSwitch.supportsSpeaker || autoSwitch.supportsHeadset {
                Section("Speaker Auto Switch") {
                    if autoSwitch.supportsSpeaker {
                        LinkAutoSwitchAvailability("Speaker", available: autoSwitch.speakerAvailable)
                        if let count = autoSwitch.registeredPhoneCount {
                            LabeledContent("Registered phones", value: count.formatted())
                                .accessibilityIdentifier("linkAutoSwitch.speaker")
                        }
                        if let paired = autoSwitch.speakerStereoPair {
                            LabeledContent("Stereo pair", value: paired ? String(localized: "On") : String(localized: "Off"))
                        }
                    }
                    if autoSwitch.supportsHeadset {
                        let reason = headphones.leAudioUnavailableReason(.linkAutoSwitch)
                        LinkAutoSwitchAvailability("Headphones", available: reason == nil ? autoSwitch.headsetAvailable : false)
                        if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        if let enabled = autoSwitch.headsetLinkEnabled {
                            LabeledContent("Speaker link", value: enabled ? String(localized: "On") : String(localized: "Off"))
                                .accessibilityIdentifier("linkAutoSwitch.headset")
                        }
                    }
                    Text("Use Sony | Sound Connect on your phone to set up or remove a speaker link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if SonySystemFeature.allCases.contains(where: { $0 != .headGestures && $0 != .legacyPowerSavingMode && $0 != .adaptiveVolume && headphones.systemFeatureState($0) != nil && headphones.systemFeatureState($0)?.isVisible != false })
                || headphones.automaticPowerOff != nil || headphones.systemFeatures.sidetone != nil
                || headphones.systemFeatures.voiceAssistant != nil || headphones.voiceAssistantSetupOptions?.isEmpty == false
                || headphones.voiceGuidance.supportsGuidance {
                Section("Headphone Controls") {
                    ForEach(SonySystemFeature.allCases.filter { $0 != .headGestures && $0 != .voiceAssistantWakeWord && $0 != .legacyPowerSavingMode && $0 != .adaptiveVolume }, id: \.self) { feature in
                        SystemFeatureControl(feature: feature)
                    }
                    VoiceAssistantControl()
                    if let options = headphones.voiceAssistantSetupOptions, !options.isEmpty {
                        LabeledContent("Voice assistant setup options") {
                            Text(options.map(\.title).formatted(.list(type: .and)))
                                .accessibilityIdentifier("system.voiceAssistantSetupOptions")
                        }
                        Text("Assistant setup is managed in Sony Sound Connect on your phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SystemFeatureControl(feature: .voiceAssistantWakeWord)
                    AutomaticPowerOffControl()
                    SidetoneControl()
                    VoiceGuidanceControls()
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
            }
            if headphones.microphoneOperation.isSupported {
                Section("Microphone Controls") {
                    MicrophoneOperationControls()
                }
            }
            if headphones.powerFeatures.batteryCare != nil || headphones.powerFeatures.autoPowerSave != nil
                || headphones.powerFeatures.touchPanelBacklight != nil || headphones.powerFeatures.stamina != nil
                || headphones.powerFeatures.powerSavingMode != nil || headphones.powerFeatures.bluetoothStandby != nil
                || headphones.powerFeatures.autoStandby != nil || headphones.powerFeatures.supportsChargeInUse
                || headphones.systemFeatureState(.legacyPowerSavingMode) != nil {
                Section("Power and Battery") {
                    BatteryCareControl()
                    AutoPowerSaveControl()
                    SystemFeatureControl(feature: .legacyPowerSavingMode)
                    SpeakerPowerControls()
                    StaminaControl()
                    TouchPanelBacklightControl()
                    if headphones.powerFeatures.supportsChargeInUse {
                        Text("While the headphones are in use, charging stops at about 80% to reduce battery wear. Turn them off to charge to 100%.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("power.chargeInUse")
                    }
                }
                .disabled(!headphones.isReady || headphones.isRunningHeadphoneTest || headphones.powerOffState != nil
                          || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false
                          || headphones.deviceActionTransition?.isFinished == false)
            }
            if !headphones.usbProtection.ports.isEmpty {
                Section("USB port protection") {
                    USBProtectionNotice(headphones: headphones, showsStatus: true)
                }
            }
            if let optimization = headphones.audioFeatures.soundFieldOptimization {
                Section("Sound Field Optimization") {
                    SoundFieldOptimizationControls(optimization: optimization)
                }
            }
            if let booster = headphones.audioFeatures.tvSoundBooster {
                Section("TV Sound Booster") {
                    TVSoundBoosterControls(booster: booster)
                }
            }
            if !headphones.audioFeatures.supportsListeningMode, !headphones.audioFeatures.upmix.isEmpty {
                Section("360 Upmix") {
                    ForEach(SonyUpmix.Variant.allCases, id: \.self) { variant in
                        if let upmix = headphones.audioFeatures.upmix[variant] {
                            SpeakerUpmixControls(upmix: upmix, showsSelection: true)
                        }
                    }
                }
            }
            if let music = headphones.audioFeatures.backgroundMusic {
                Section("Background Music") {
                    BackgroundMusicControls(music: music, showsPower: !headphones.audioFeatures.supportsListeningMode)
                }
            }
            if headphones.speakerLighting.isSupported {
                Section("Lighting") {
                    SpeakerLightingControls()
                        .id(headphones.preferencePaneSession)
                }
            }
            if headphones.djControl.inquiry != nil {
                Section("DJ Control") {
                    SpeakerDJControls()
                        .id(headphones.preferencePaneSession)
                }
            }
            if headphones.karaoke.inquiry != nil {
                Section("Karaoke") {
                    SpeakerKaraokeControls()
                        .id(headphones.preferencePaneSession)
                }
            }
            if headphones.auracast.variant != nil {
                Section("Auracast") {
                    AuracastControls()
                        .id(headphones.preferencePaneSession)
                }
            }
            if headphones.touchAssignments.inquiryType != nil {
                Section(headphones.touchAssignments.keys?.allSatisfy { $0.keyType == 1 } == true ? String(localized: "Button Controls") : String(localized: "Touch Controls")) {
                    if let keys = headphones.touchAssignments.keys {
                        if headphones.deviceModel.isEarbuds, keys.contains(where: { $0.key <= 0x01 }) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(keys.filter { $0.key <= 0x01 }.sorted { $0.key < $1.key }, id: \.key) { key in
                                    TouchAssignmentControl(key: key)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                        }
                        ForEach(keys.filter { !headphones.deviceModel.isEarbuds || $0.key > 0x01 }, id: \.key) { key in
                            TouchAssignmentControl(key: key)
                        }
                    } else if headphones.settingErrors[.touchCustomActions] == nil && headphones.settingErrors[.touchAssignments] == nil {
                        Text("Reading touch controls…").foregroundStyle(.primary)
                    }
                    if headphones.pendingChanges[.touchAssignments] != nil || headphones.pendingChanges[.touchCustomActions] != nil {
                        ProgressView("Updating touch controls…").controlSize(.small)
                    }
                    if let error = headphones.settingErrors[.touchCustomActions] ?? headphones.settingErrors[.touchAssignments] {
                        Text(error).font(.caption).foregroundStyle(.primary)
                    }
                }
                .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.multipointTransition?.isFinished == false || headphones.deviceActionTransition?.isFinished == false)
            }
        }
        .task(id: headphones.canReadVoiceAssistantSetup) { headphones.requestVoiceAssistantSetup() }
    }

    private var advanced: some View {
        Form {
            Section("Mac Audio Output") {
                LabeledContent("Device", value: audioOutputName)
                if let route = audioRoute.route {
                    LabeledContent("Transport", value: route.transport?.title ?? String(localized: "Unknown"))
                    LabeledContent("Audio format", value: route.pcmFormatDescription)
                        .help(route.transport?.rawValue == kAudioDeviceTransportTypeUSB
                              ? String(localized: "A USB Bluetooth transmitter controls its wireless connection and codec.")
                              : String(localized: "The Mac’s output format does not identify the Bluetooth wireless codec."))
                }
                if audioRoute.error != nil {
                    Text("Some audio output details are unavailable. Copy diagnostics for details.")
                        .font(.caption)
                }
            }
            Section("Connection") {
                if !headphones.usesBluetoothLE {
                    LabeledContent("Bluetooth address") {
                        Text(headphones.address.isEmpty ? String(localized: "Not found") : headphones.address).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Headphone controls") {
                    Text(headphones.isReady && headphones.powerOffState == nil ? String(localized: "Ready") : headphones.statusText).foregroundStyle(.primary)
                }
            }
            if headphones.supportsLEAudioStandby || headphones.leAudioCapabilities.supportsSwitchCompatibility
                || headphones.leAudioCapabilities.supportsConnectionMode {
                Section("Device LE Audio") {
                    LEAudioPreferenceControls()
                }
            }
            Section("Diagnostics") {
                LabeledContent("Bluetooth device") {
                    Text(headphones.isDeviceConnected ? String(localized: "Connected") : String(localized: "Disconnected")).foregroundStyle(.primary)
                }
                LabeledContent("Protocol") {
                    Text(headphones.controlProtocol).foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if let identifier = headphones.controlPeripheralID {
                    LabeledContent("LE peripheral") {
                        Text(identifier.uuidString).foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Last sync") {
                    Text(lastSyncText).foregroundStyle(.primary)
                }
                if let error = headphones.lastErrorMessage {
                    LabeledContent("Last issue") {
                        Text(error)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Sync Now") {
                        devices.refreshControls(for: headphones)
                    }
                        .disabled(headphones.isRunningHeadphoneTest || headphones.powerOffState != nil || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                    Spacer()
                    Button("Copy Diagnostics") { copyDiagnostics() }
                }
                #if DEBUG
                if headphones.protocolInformation?.generation != .v1 {
                    HStack {
                        Button("Connect Controls with Bluetooth LE") { headphones.connectBluetoothLE() }
                            .disabled(headphones.usesBluetoothLE || headphones.isPreparingBluetoothLE || headphones.linkState == .opening || headphones.linkState == .handshaking
                                      || headphones.isPoweringOff
                                      || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                        if headphones.isPreparingBluetoothLE {
                            Button("Cancel") { headphones.cancelBluetoothLEPreparation() }
                        }
                        if headphones.usesBluetoothLE {
                            Button("Reconnect Controls") { headphones.connect() }
                                .disabled(headphones.isPoweringOff || headphones.connectionTransition?.isFinished == false || headphones.multipointTransition?.isFinished == false)
                        }
                    }
                }
                if let error = headphones.bluetoothLEError {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
                #endif
            }
        }
        .tint(.primary)
    }

    private var audioOutputName: String {
        audioRoute.route?.name ?? (audioRoute.route != nil || audioRoute.error != nil ? String(localized: "Unavailable") : String(localized: "No output selected"))
    }

    private var lastSyncText: String {
        headphones.lastSyncDate?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Never")
    }

    private func copyDiagnostics() {
        var reports = [DiagnosticHistory.environmentReport, headphones.diagnosticReport, audioRoute.diagnosticReport]
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        reports.append(ldac.diagnosticReport)
        #else
        reports.append("LDAC: unavailable in this build")
        #endif
        let report = reports.joined(separator: "\n\n").components(separatedBy: "\n")
            .map { DiagnosticHistory.line($0, redacting: headphones.diagnosticPrivateNames + [audioRoute.route?.name ?? ""]) }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

private struct LinkAutoSwitchAvailability: View {
    let title: LocalizedStringKey
    let available: Bool?

    init(_ title: LocalizedStringKey, available: Bool?) {
        self.title = title
        self.available = available
    }

    var body: some View {
        LabeledContent(title) {
            switch available {
            case true?: Text("Available")
            case false?: Text("Unavailable")
            case nil: Text("Unknown")
            }
        }
    }
}

#if !ACOUPLET_PUBLIC_APIS_ONLY
private struct FirmwareUpdateControl: View {
    let firmware: String
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var notifications: SonyNotificationService
    @State private var request: UUID?
    @State private var isChecking = false
    @State private var availability: SonyFirmwareAvailability?

    var body: some View {
        LabeledContent("Firmware") {
            HStack(spacing: 12) {
                Text(firmware).foregroundStyle(.primary)
                    .accessibilityIdentifier("headphones.firmwareVersion")
                Button(isChecking ? String(localized: "Checking…") : String(localized: "Check for Updates")) {
                    isChecking = true
                    availability = nil
                    request = UUID()
                }
                .disabled(isChecking || headphones.firmwareUpdateSession == nil || headphones.firmwareUpdateIdentity == nil || headphones.firmwareVersion == nil)
                .accessibilityIdentifier("headphones.checkFirmware")
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .task(id: headphones.firmwareUpdateSession) {
            headphones.requestFirmwareUpdateIdentity()
            availability = nil
        }
        .task(id: request) {
            guard request != nil else { return }
            defer { isChecking = false }
            guard let session = headphones.firmwareUpdateSession, let identity = headphones.firmwareUpdateIdentity,
                  let currentVersion = headphones.firmwareVersion else { return }
            let result = await notifications.checkFirmware(identity: identity, currentVersion: currentVersion)
            guard !Task.isCancelled, headphones.firmwareUpdateSession == session,
                  headphones.firmwareUpdateIdentity == identity, headphones.firmwareVersion == currentVersion else { return }
            availability = result
        }
        .onChange(of: headphones.firmwareVersion) { _, _ in availability = nil }
        if let availability {
            Text(statusText(availability))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusText(availability))
                .accessibilityIdentifier("headphones.firmwareUpdateStatus")
        }
    }

    private func statusText(_ availability: SonyFirmwareAvailability) -> String {
        switch availability {
        case .available(let version): String(localized: "Firmware \(version) is available. Install it with Sony | Sound Connect.")
        case .noUpdate: String(localized: "Firmware is up to date.")
        case .unavailable: String(localized: "Couldn’t check for updates. Try again.")
        }
    }
}
#endif

private struct HeadGesturePracticeControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsPractice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.headGesturePracticeTransition == nil ? String(localized: "Practice Head Gestures…") : String(localized: "Practice Details…")) {
                if headphones.beginHeadGesturePractice() { showsPractice = true }
            }
            .tint(.primary)
            .disabled(headphones.headGesturePracticeTransition == nil && headphones.headGesturePracticeUnavailableReason != nil)
            .help(headphones.headGesturePracticeUnavailableReason ?? "")
            .accessibilityIdentifier("gesture.open")
            .sheet(isPresented: $showsPractice) {
                if let transition = headphones.headGesturePracticeTransition {
                    HeadGesturePracticeSheet(transitionID: transition.id)
                }
            }
            if headphones.headGesturePracticeTransition?.phase == .interrupted,
               let message = headphones.headGesturePracticeTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HeadGesturePracticeSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var target = SonyHeadGesturePractice.Gesture.nod
    @State private var feedbackAfterRevision: UInt64 = 0
    @State private var countAtSelection = 0

    private var detectedGesture: SonyHeadGesturePractice.Gesture? {
        headphones.headGesturePractice.gestureRevision > feedbackAfterRevision ? headphones.headGesturePractice.receivedGesture : nil
    }

    private var matchingGestureCount: Int {
        min(3, max(0, headphones.headGesturePractice.count(for: target) - countAtSelection))
    }

    var body: some View {
        if let transition = headphones.headGesturePracticeTransition, transition.id == transitionID {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text("Practice Head Gestures").font(.headline)
                        .accessibilityIdentifier("gesture.title")
                    Spacer(minLength: 0)
                    Picker("Gesture", selection: $target) {
                        Text("Nod").tag(SonyHeadGesturePractice.Gesture.nod)
                        Text("Shake").tag(SonyHeadGesturePractice.Gesture.shake)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 136)
                    .disabled(transition.phase != .ready && transition.phase != .practicing)
                    .accessibilityIdentifier("gesture.target")
                }
                GroupBox {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            let head = Image(systemName: "face.smiling.inverse")
                                .font(.system(size: 28))
                                .foregroundStyle(.tint)
                            if !reduceMotion && scenePhase == .active && matchingGestureCount < 3
                                && transition.phase == .practicing {
                                head.phaseAnimator([0, -1, 0, 1]) { content, phase in
                                    content.offset(x: target == .shake ? CGFloat(phase) * 6 : 0,
                                                   y: target == .nod ? CGFloat(phase) * 6 : 0)
                                } animation: { _ in .easeInOut(duration: 0.35) }
                            } else {
                                head
                            }
                            Image(systemName: target == .nod ? "arrow.up.and.down" : "arrow.left.and.right")
                                .font(.callout.weight(.medium))
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 64)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            if let message = transition.message {
                                Text(message).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("gesture.message")
                            } else if transition.phase == .practicing {
                                HStack(spacing: 6) {
                                    Image(systemName: matchingGestureCount == 3 || detectedGesture == target ? "checkmark.circle.fill" : detectedGesture == nil ? "circle.dotted" : "arrow.trianglehead.clockwise")
                                        .foregroundStyle(matchingGestureCount == 3 || detectedGesture == target ? Color.green : Color.secondary)
                                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                        .symbolEffectsRemoved(reduceMotion || detectedGesture != target)
                                        .symbolEffect(.bounce, value: matchingGestureCount)
                                        .accessibilityHidden(true)
                                    if matchingGestureCount == 3 {
                                        Text("All set")
                                    } else if let detectedGesture {
                                        Text("\(detectedGesture.title) detected")
                                    } else {
                                        Text("Waiting for a gesture…")
                                    }
                                }
                                .font(.headline)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(matchingGestureCount == 3 ? "gesture.success" : detectedGesture == nil ? "gesture.waiting" : "gesture.detected")
                            } else if transition.phase == .finished {
                                Text("Practice has ended.").font(.headline)
                            } else {
                                Text("Wear both earbuds and face forward.")
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if transition.message == nil && transition.phase != .finished {
                                Text(target == .nod ? String(localized: "Face forward, then nod your head up and down.") : String(localized: "Face forward, then shake your head from side to side."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if transition.waitingForReport {
                                HeadphoneTestProgress(title: transition.phase == .checking ? String(localized: "Preparing practice…") : transition.phase == .entering ? String(localized: "Starting practice…") : String(localized: "Ending practice…"))
                                    .accessibilityIdentifier("gesture.progress")
                            } else if transition.phase == .practicing {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(matchingGestureCount) of 3 gestures detected")
                                        .font(.caption).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("gesture.count")
                                    HStack(spacing: 5) {
                                        ForEach(0..<3) { index in
                                            ProgressView(value: index < matchingGestureCount ? 1 : 0, total: 1)
                                                .progressViewStyle(.linear)
                                                .tint(index < matchingGestureCount ? .green : .clear)
                                                .frame(width: 18)
                                        }
                                    }
                                    .accessibilityHidden(true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                    .padding(6)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                Text("If a gesture is not detected, face forward and remain still for a moment before trying again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(transition.message == nil && transition.phase != .finished ? 1 : 0)
                    .accessibilityHidden(transition.message != nil || transition.phase == .finished)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(transition.canDismiss || transition.phase == .practicing ? String(localized: "Done") : String(localized: "Cancel")) {
                        if transition.canDismiss {
                            headphones.dismissHeadGesturePractice(id: transitionID)
                            dismiss()
                        } else { headphones.cancelHeadGesturePractice(id: transitionID) }
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .disabled(transition.phase == .leaving)
                    .accessibilityIdentifier("gesture.cancel")
                    if transition.phase == .ready {
                        Button("Start Practice") { headphones.startHeadGesturePractice(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartHeadGesturePractice)
                            .accessibilityIdentifier("gesture.start")
                    }
                }
            }
            .padding(20)
            .frame(width: 440, height: 296)
            .presentationSizing(.fitted)
            .accessibilityElement(children: .contain)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .onChange(of: transition.phase) { _, phase in
                if phase == .finished, transition.shouldDismiss {
                    headphones.dismissHeadGesturePractice(id: transitionID)
                    dismiss()
                }
            }
            .onChange(of: target) { _, _ in
                feedbackAfterRevision = headphones.headGesturePractice.gestureRevision
                countAtSelection = headphones.headGesturePractice.count(for: target)
            }
            .onChange(of: headphones.headGesturePractice.gestureRevision) { _, _ in
                if NSWorkspace.shared.isVoiceOverEnabled, let gesture = headphones.headGesturePractice.receivedGesture {
                    NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
                                         userInfo: [.announcement: matchingGestureCount == 3 ? String(localized: "All set") : String(localized: "\(gesture.title) detected"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
            .onDisappear { headphones.cancelHeadGesturePractice(id: transitionID, dismissWhenFinished: true) }
        }
    }
}

private struct LegacyOptimizerControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsOptimizer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.legacyOptimizerTransition == nil ? String(localized: "Optimize Noise Cancelling…") : String(localized: "Optimizer Details…")) {
                if headphones.beginLegacyOptimizer() { showsOptimizer = true }
            }
            .tint(.primary)
            .disabled(headphones.legacyOptimizerTransition == nil && headphones.legacyOptimizerUnavailableReason != nil)
            .help(headphones.legacyOptimizerUnavailableReason ?? "")
            .accessibilityIdentifier("optimizer.open")
            .sheet(isPresented: $showsOptimizer) {
                if let transition = headphones.legacyOptimizerTransition {
                    LegacyOptimizerSheet(transitionID: transition.id)
                }
            }
            if headphones.legacyOptimizerTransition?.phase == .interrupted,
               let message = headphones.legacyOptimizerTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LegacyOptimizerSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let transition = headphones.legacyOptimizerTransition, transition.id == transitionID {
            VStack(alignment: .leading, spacing: 20) {
                Text("Noise Cancelling Optimizer").font(.title2).fontWeight(.semibold)
                    .accessibilityIdentifier("optimizer.title")
                VStack(alignment: .leading, spacing: 20) {
                    if let message = transition.message {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("optimizer.message")
                    } else if transition.phase == .checking || transition.phase == .ready {
                        Text("Wear the headphones as you normally do. This test plays sounds. Avoid touching the headphones until it finishes.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if transition.phase == .completed {
                        Label {
                            Text("Optimization Complete")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                            .accessibilityIdentifier("optimizer.result")
                        if let result = transition.result {
                            if result.personalType == 1 {
                                LabeledContent("Personal optimization", value: result.personalMeasured.map { $0 ? String(localized: "Measured") : String(localized: "Not measured") } ?? String(localized: "Unknown"))
                            }
                            if result.pressureType == 1 {
                                LabeledContent("Atmospheric pressure", value: result.pressureAtmospheres.map {
                                    String(localized: "\($0.formatted(.number.precision(.fractionLength(1)))) atm")
                                } ?? (result.pressureValue == 0 ? String(localized: "Not measured") : String(localized: "Unknown")))
                            }
                        }
                    } else if transition.waitingForReport || transition.phase == .checking {
                        HeadphoneTestProgress(title: progressText(transition.phase))
                            .accessibilityIdentifier("optimizer.progress")
                    }
                    Spacer(minLength: 0)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                HStack {
                    Spacer()
                    Button((transition.canDismiss && transition.phase != .ready) || transition.phase == .completed ? String(localized: "Done") : String(localized: "Cancel")) {
                        if transition.canDismiss {
                            headphones.dismissLegacyOptimizer(id: transitionID)
                            dismiss()
                        } else { headphones.cancelLegacyOptimizer(id: transitionID) }
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .disabled(transition.phase == .cancelling || transition.phase == .readingResult
                              || (transition.phase == .completed && !transition.canDismiss))
                    .accessibilityIdentifier("optimizer.cancel")
                    if transition.phase == .ready {
                        Button("Start Optimization") { headphones.startLegacyOptimizer(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartLegacyOptimizer)
                            .accessibilityIdentifier("optimizer.start")
                    }
                }
            }
            .padding(24)
            .frame(width: 460, height: 260)
            .presentationSizing(.fitted)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .onChange(of: transition.shouldDismiss) { _, shouldDismiss in
                if shouldDismiss {
                    headphones.dismissLegacyOptimizer(id: transitionID)
                    dismiss()
                }
            }
            .onDisappear {
                if headphones.legacyOptimizerTransition?.canDismiss != true {
                    headphones.cancelLegacyOptimizer(id: transitionID)
                }
                headphones.dismissLegacyOptimizer(id: transitionID)
            }
        }
    }

    private func progressText(_ phase: SonyLegacyOptimizerTransition.Phase) -> String {
        switch phase {
        case .checking: String(localized: "Checking headphones…")
        case .starting, .running: String(localized: "Optimizing noise cancellation…")
        case .readingResult: String(localized: "Reading results…")
        case .cancelling: String(localized: "Stopping optimization…")
        default: String(localized: "Waiting for headphones…")
        }
    }
}

private struct WearingPositionControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wear both earbuds and face forward.").font(.caption).foregroundStyle(.secondary)
            if headphones.checkingWearingPosition {
                ProgressView("Checking…").controlSize(.small)
            } else if headphones.wearingPositionTimedOut {
                Text("The position check timed out. Reconnect the earbuds to try again.").font(.caption)
            } else if let result = headphones.wearingPositionResult {
                Text(result.message).font(.caption).accessibilityIdentifier("wearingPosition.result")
            } else if headphones.wearingPosition.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Check Earbud Position") { headphones.startWearingPositionCheck() }
                .disabled(!headphones.canStartWearingPositionCheck)
                .accessibilityIdentifier("wearingPosition.start")
        }
    }
}

private struct EarTipFitControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsTest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(headphones.earTipFitTransition == nil ? String(localized: "Check Earbud Fit…") : String(localized: "Fit Test Details…")) {
                if headphones.beginEarTipFit() { showsTest = true }
            }
            .tint(.primary)
            .disabled(headphones.earTipFitTransition == nil && headphones.earTipFitUnavailableReason != nil)
            .help(headphones.earTipFitUnavailableReason ?? "")
            .accessibilityIdentifier("fit.open")
            .sheet(isPresented: $showsTest) {
                if let transition = headphones.earTipFitTransition {
                    EarTipFitSheet(transitionID: transition.id)
                }
            }
            if headphones.earTipFitTransition?.phase == .interrupted,
               let message = headphones.earTipFitTransition?.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EarTipFitSheet: View {
    let transitionID: UUID
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var resultHasFocus: Bool

    var body: some View {
        if let transition = headphones.earTipFitTransition, transition.id == transitionID {
            let passed = transition.phase == .result && transition.result?.left == .good && transition.result?.right == .good
            VStack(alignment: .leading, spacing: 20) {
                Text("Earbud Fit Test").font(.title2).fontWeight(.semibold)
                    .accessibilityIdentifier("fit.title")
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 32) {
                        earbud(.left, seal: transition.result?.left)
                        earbud(.right, seal: transition.result?.right)
                    }
                    .frame(maxWidth: .infinity)
                    if let selectedSeries = headphones.earTipFit.selectedSeries {
                        LabeledContent("Ear-tip type", value: selectedSeries.title)
                    }
                    if let message = transition.message {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fit.message")
                    } else if !passed {
                        Text(instructions(transition.phase)).fixedSize(horizontal: false, vertical: true)
                    }
                    if transition.waitingForReport {
                        HeadphoneTestProgress(title: progressText(transition.phase))
                            .accessibilityIdentifier("fit.progress")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: transition.phase == .result ? .center : .top)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: transition.phase)
                HStack {
                    if transition.phase == .result {
                        Button("Test Again") { headphones.prepareEarTipFitAgain(id: transitionID) }
                            .keyboardShortcut(passed ? nil : .defaultAction)
                            .tint(passed ? .primary : settings.tintColor)
                            .accessibilityIdentifier("fit.again")
                    }
                    Spacer()
                    Button(transition.canDismiss || transition.phase == .result ? String(localized: "Done") : String(localized: "Cancel")) {
                        close(transition)
                    }
                    .keyboardShortcut(passed ? .defaultAction : .cancelAction)
                    .tint(passed ? settings.tintColor : .primary)
                    .disabled(transition.phase == .cancelling || transition.phase == .leaving)
                    .accessibilityIdentifier("fit.cancel")
                    if transition.phase == .ready {
                        Button("Start Test") { headphones.startEarTipFit(id: transitionID) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!headphones.canStartEarTipFit)
                            .accessibilityIdentifier("fit.start")
                    }
                }
            }
            .padding(24)
            .frame(width: 460, height: 380)
            .presentationSizing(.fitted)
            .interactiveDismissDisabled(!transition.canDismiss)
            .presentationPreventsAppTermination(false)
            .focusable(passed, interactions: .edit)
            .focused($resultHasFocus)
            .focusEffectDisabled()
            .onExitCommand(perform: passed ? { close(transition) } : nil)
            .onChange(of: passed, initial: true) { _, passed in resultHasFocus = passed }
            .onChange(of: transition.phase) { _, phase in
                if phase == .finished, transition.shouldDismiss {
                    headphones.dismissEarTipFit(id: transitionID)
                    dismiss()
                }
            }
            .onDisappear { headphones.cancelEarTipFit(id: transitionID, dismissWhenFinished: true) }
        }
    }

    private func close(_ transition: SonyEarTipFitTransition) {
        if transition.canDismiss {
            headphones.dismissEarTipFit(id: transitionID)
            dismiss()
        } else { headphones.cancelEarTipFit(id: transitionID) }
    }

    private func earbud(_ side: EarbudSide, seal: SonyEarTipFit.Seal?) -> some View {
        VStack(spacing: 8) {
            EarbudArtwork(model: headphones.deviceModel, side: side, artwork: headphones.productArtwork)
                .frame(width: 100, height: 100 * 103.0 / 137.0).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(side == .left ? String(localized: "Left") : String(localized: "Right")).font(.headline)
                if let seal {
                    Label {
                        Text(seal == .good ? String(localized: "Good seal") : String(localized: "Adjust fit"))
                    } icon: {
                        Image(systemName: seal == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(seal == .good ? Color.green : Color.yellow)
                    }
                        .accessibilityIdentifier(side == .left ? "fit.leftResult" : "fit.rightResult")
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    private func instructions(_ phase: SonyEarTipFitTransition.Phase) -> String {
        switch phase {
        case .checking, .ready:
            String(localized: "Wear both earbuds in a quiet place. The test plays a short sound.")
        case .entering, .starting, .measuring:
            String(localized: "Keep still and leave both earbuds in your ears.")
        case .result:
            String(localized: "Reposition the earbud or try another tip size, then test again.")
        case .cancelling, .leaving:
            String(localized: "Waiting for the earbuds to finish.")
        case .finished:
            String(localized: "The fit test has ended.")
        case .unavailable, .interrupted:
            String(localized: "The fit test is unavailable.")
        }
    }

    private func progressText(_ phase: SonyEarTipFitTransition.Phase) -> String {
        switch phase {
        case .checking: String(localized: "Reading earbud information…")
        case .entering, .starting: String(localized: "Starting test…")
        case .measuring: String(localized: "Measuring fit…")
        case .cancelling: String(localized: "Cancelling test…")
        default: String(localized: "Finishing test…")
        }
    }
}

private struct HeadphoneTestProgress: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.regular)
            Text(title).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct VoiceGuidanceControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.locale) private var locale

    var body: some View {
        let state = headphones.voiceGuidance
        if state.guidanceInquiry != nil, state.supportsOnOffSwitch != false {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setVoiceGuidance($0) }
                        )) {
                            HStack {
                                Text("Voice guidance")
                                if headphones.pendingChanges[.voiceGuidance] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating voice guidance")
                                }
                            }
                        }
                        .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                                  || headphones.pendingChanges[.voiceGuidance] != nil
                                  || headphones.pendingChanges[.voiceGuidanceLanguage] != nil
                                  || state.setEnabledPayload(!enabled) == nil)
                        .accessibilityIdentifier("guidance.enabled")
                    } else {
                        LabeledContent("Voice guidance") { Text("Unknown").foregroundStyle(.primary) }
                    }
                }
                if let error = headphones.settingErrors[.voiceGuidance] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if state.guidanceInquiry == 2 {
            let languages = state.supportedLanguageChoices
            let current = state.currentLanguage.flatMap { languages.contains($0) ? $0 : nil }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Voice guidance language", selection: Binding(
                    get: { current },
                    set: { if let language = $0 { headphones.setVoiceGuidanceLanguage(language) } }
                )) {
                    if current == nil { Text("Unknown").tag(UInt8?.none).disabled(true) }
                    ForEach(languages, id: \.self) { language in
                        if let identifier = SonyVoiceGuidance.languageLocales[language] {
                            Text(locale.localizedString(forIdentifier: identifier) ?? identifier).tag(Optional(language))
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                          || headphones.pendingChanges[.voiceGuidance] != nil
                          || headphones.pendingChanges[.voiceGuidanceLanguage] != nil
                          || !languages.contains(where: { state.setLanguagePayload($0) != nil }))
                .accessibilityIdentifier("guidance.language")
                if let error = headphones.settingErrors[.voiceGuidanceLanguage] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.languageAvailable == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        ForEach(state.tones, id: \.self) { tone in
            let setting = SonyHeadphonesController.Setting.voiceGuidanceTone(tone)
            let title = switch tone {
            case .batteryLevel: String(localized: "Battery level notification")
            case .powerButton: String(localized: "Power button tone")
            case .ultButton: String(localized: "ULT button tone")
            }
            VStack(alignment: .leading, spacing: 6) {
                if let enabled = state.toneEnabled[tone] {
                    Toggle(isOn: Binding(
                        get: { enabled },
                        set: { headphones.setVoiceGuidanceTone(tone, enabled: $0) }
                    )) {
                        HStack {
                            Text(title)
                            if headphones.pendingChanges[setting] != nil {
                                ProgressView().controlSize(.mini).accessibilityLabel("Updating")
                            }
                        }
                    }
                    .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                              || headphones.pendingChanges[setting] != nil || state.setTonePayload(tone, enabled: !enabled) == nil)
                } else {
                    LabeledContent(title) { Text("Unknown").foregroundStyle(.primary) }
                }
                if let error = headphones.settingErrors[setting] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.toneAvailability[tone] == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if state.supportsVolume {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.volume },
                        set: { if let volume = $0 { headphones.setVoiceGuidanceVolume(volume) } }
                    )) {
                        if state.volume == nil { Text("Unknown").tag(Int?.none).disabled(true) }
                        ForEach(SonyVoiceGuidance.volumeRange, id: \.self) { volume in
                            Text([String(localized: "Very low"), String(localized: "Low"), String(localized: "Medium"), String(localized: "High"), String(localized: "Very high")][volume + 2])
                                .tag(Optional(volume))
                                .disabled(state.setVolumePayload(volume) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Guidance volume")
                            if headphones.pendingChanges[.voiceGuidanceVolume] != nil {
                                ProgressView().controlSize(.mini).accessibilityLabel("Updating guidance volume")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                              || headphones.pendingChanges[.voiceGuidanceVolume] != nil
                              || !SonyVoiceGuidance.volumeRange.contains(where: { state.setVolumePayload($0) != nil }))
                    .accessibilityIdentifier("guidance.volume")
                }
                Button("Play Test Audio") {
                    if let volume = state.volume { headphones.setVoiceGuidanceVolume(volume, playTestAudio: true) }
                }
                .disabled(!headphones.isReady || headphones.connectionTransition?.isFinished == false
                          || headphones.pendingChanges[.voiceGuidanceVolume] != nil
                          || state.volume.flatMap { state.setVolumePayload($0, playTestAudio: true) } == nil)
                if let error = headphones.settingErrors[.voiceGuidanceVolume] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.volumeAvailable == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct HeadphonePlaybackControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let track = headphones.playback.track {
            if let title = track.title { LabeledContent("Title", value: title) }
            if let artist = track.artist { LabeledContent("Artist", value: artist) }
            if let album = track.album { LabeledContent("Album", value: album) }
            if let genre = track.genre { LabeledContent("Genre", value: genre) }
        }
        if headphones.playback.supportsPlaybackCommands {
            HStack {
                Button { headphones.controlPlayback(.previous) } label: {
                    Label("Previous", systemImage: "backward.end.fill")
                }
                Button { headphones.controlPlayback(headphones.playback.state == .playing ? .pause : .play) } label: {
                    if headphones.playback.state == .playing { Label("Pause", systemImage: "pause.fill") }
                    else { Label("Play", systemImage: "play.fill") }
                }
                Button { headphones.controlPlayback(.next) } label: {
                    Label("Next", systemImage: "forward.end.fill")
                }
            }
            .disabled(!headphones.canControlPlayback)
            .accessibilityIdentifier("playback.commands")
        }
        HeadphonePlaybackVolumeControl(isCall: false)
            .id("music:\(headphones.preferencePaneSession):\(headphones.multipoint.selectedSource?.address ?? "")")
        if headphones.playback.supportsCallVolume {
            HeadphonePlaybackVolumeControl(isCall: true)
                .id("call:\(headphones.preferencePaneSession):\(headphones.multipoint.selectedSource?.address ?? "")")
        }
        if let error = headphones.playbackReadError { Text(error).font(.caption) }
    }
}

private struct HeadphonePlaybackVolumeControl: View {
    let isCall: Bool
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var draft: Double?
    @State private var isEditing = false

    private var title: LocalizedStringKey { isCall ? "Call Volume" : "Music Volume" }
    private var setting: SonyHeadphonesController.Setting { isCall ? .callVolume : .playbackVolume }
    private var value: Int? { isCall ? headphones.playback.callVolume : headphones.playback.volume }
    private var range: ClosedRange<Int>? { isCall ? headphones.playback.callVolumeRange : headphones.playback.musicVolumeRange }
    private var muted: Bool? { isCall ? headphones.playback.callMuted : headphones.playback.musicMuted }

    var body: some View {
        if let value, let range {
            if range.lowerBound < range.upperBound {
                Slider(value: Binding(get: { isEditing ? draft ?? Double(value) : Double(value) }, set: {
                    draft = $0
                    if !isEditing { setVolume(Int($0)) }
                }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1, onEditingChanged: {
                    isEditing = $0
                    if !$0, let draft {
                        setVolume(Int(draft))
                        self.draft = nil
                    }
                }) { Text(title) }
                .disabled(isCall ? !headphones.canControlCallVolume : !headphones.canControlMusicVolume)
                .accessibilityIdentifier(isCall ? "playback.callVolume" : "playback.musicVolume")
            } else {
                LabeledContent(title, value: String(value))
            }
            if muted == true { Text("Muted").font(.caption).foregroundStyle(.secondary) }
        } else {
            LabeledContent(title, value: String(localized: "Unknown"))
        }
        if let error = headphones.settingErrors[setting] { Text(error).font(.caption) }
    }

    private func setVolume(_ value: Int) {
        if isCall { headphones.setCallVolume(value) }
        else { headphones.setPlaybackVolume(value) }
    }
}

private struct LegacyStandaloneNoiseControl: View {
    let inquiry: UInt8
    @EnvironmentObject private var headphones: SonyHeadphonesController

    private var title: LocalizedStringKey { inquiry == 1 ? "Noise Cancelling" : "Ambient Sound" }

    var body: some View {
        if let state = headphones.standaloneNoiseControl(inquiry) {
            if let enabled = state.enabled {
                Toggle(title, isOn: Binding(get: { enabled }, set: {
                    headphones.setStandaloneNoiseControl(inquiry, enabled: $0)
                }))
                .disabled(!headphones.canSetStandaloneNoiseControl(inquiry))
                .accessibilityIdentifier("noise.standalone.\(inquiry)")
                if inquiry == 3, enabled, state.capability?.ambientSteps[1] != nil, let focus = state.state?.focusOnVoice {
                    Toggle("Focus on Voice", isOn: Binding(get: { focus }, set: {
                        headphones.setStandaloneNoiseControl(inquiry, enabled: true, focusOnVoice: $0)
                    }))
                    .disabled(!headphones.canSetStandaloneNoiseControl(inquiry))
                }
            } else {
                LabeledContent(title, value: String(localized: "Unknown"))
            }
            if state.available == false { Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct SoundPressureControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Listening level") {
                HStack {
                    Text(reading).monospacedDigit().foregroundStyle(.primary)
                    if headphones.soundPressure.intervalSeconds == nil || headphones.soundPressureReadError != nil
                        || headphones.soundPressureAutomaticRefreshSuspended {
                        Button("Refresh") { headphones.refreshSoundPressure() }
                            .disabled(!headphones.canRefreshSoundPressure)
                            .tint(.primary)
                    }
                }
            }
            .accessibilityIdentifier("audio.listeningLevel")
            .help("Reported by the headphones for the current audio source.")
            if let error = headphones.soundPressureReadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Listening measurement") {
                Menu(headphones.soundPressure.mode.map(modeTitle) ?? String(localized: "Unknown")) {
                    ForEach(SonySoundPressureMode.allCases, id: \.self) { mode in
                        Button(modeTitle(mode)) { headphones.setSoundPressureMode(mode) }
                    }
                }
                .disabled(!headphones.canChangeSoundPressureMode)
            }
            .help("Preview shows the current level. Recording also stores listening exposure on the headphones.")
            if let error = headphones.settingErrors[.soundPressureMode] {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Listening exposure") {
                HStack {
                    Button("Read current") { headphones.readExposure(current: true) }
                    Button("Read history") { headphones.readExposure(current: false) }
                }
                .disabled(!headphones.canReadExposure)
            }
            if headphones.isReadingExposure {
                ProgressView("Reading listening exposure…").controlSize(.small)
            }
            if let current = headphones.currentExposure { exposureSummary("Current record", current) }
            if let history = headphones.exposureHistory { exposureSummary("Stored history", history) }
            if let error = headphones.exposureReadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modeTitle(_ mode: SonySoundPressureMode) -> String {
        switch mode {
        case .off: String(localized: "Off")
        case .preview: String(localized: "Preview")
        case .recording: String(localized: "Recording")
        }
    }

    private func exposureSummary(_ title: LocalizedStringKey, _ exposure: SonyExposureHistory) -> some View {
        LabeledContent(title) {
            if exposure.isEmpty {
                Text("No records")
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Listening time: \(exposure.listeningMinutes) min")
                    if let decibels = exposure.averageDecibels { Text("\(decibels) dB average") }
                    if let ambient = exposure.ambientMinutes { Text("Ambient sound time: \(ambient) min") }
                    if exposure.incomplete { Text("One earbud was unavailable") }
                }
                .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var reading: String {
        if headphones.soundPressure.isStopped { return String(localized: "Measurement is off") }
        if headphones.soundPressure.available == false { return String(localized: "Unavailable") }
        guard headphones.soundPressure.available == true else { return "—" }
        return switch headphones.soundPressure.reading {
        case .decibels(let value): String(localized: "\(value) dB")
        case .notPlaying: String(localized: "Not playing")
        case .inCall: String(localized: "In a call")
        case .notWorn: String(localized: "Not worn")
        case .unknown, nil: "—"
        }
    }
}

struct USBProtectionNotice: View {
    @ObservedObject var headphones: SonyHeadphonesController
    var showsStatus = false

    var body: some View {
        let session = headphones.notificationSession
        ForEach(SonyUSBProtection.Kind.allCases, id: \.self) { kind in
            if let state = headphones.usbProtection.ports[kind] {
                let hasCaution = headphones.usbProtection.cautions.contains(kind)
                if hasCaution || state.detected == true {
                    VStack(alignment: .leading, spacing: 5) {
                        if kind == .moisture {
                            Label(state.detected == false ? String(localized: "USB moisture warning")
                                  : String(localized: "Moisture detected in the USB port"),
                                  systemImage: "exclamationmark.triangle")
                            Text("Wait until the USB port is completely dry before charging the headphones.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(state.detected == false ? String(localized: "USB overheat warning")
                                  : String(localized: "USB port overheating"),
                                  systemImage: "exclamationmark.triangle")
                        }
                        if hasCaution {
                            Button("OK") { headphones.acknowledgeUSBCaution(kind, expectedSession: session) }
                                .disabled(!headphones.canAcknowledgeUSBCaution(kind))
                        }
                    }
                } else if showsStatus {
                    LabeledContent(kind == .moisture ? String(localized: "USB moisture") : String(localized: "USB overheat"),
                                   value: state.detected == nil ? String(localized: "Unknown")
                                   : kind == .moisture ? String(localized: "No moisture detected") : String(localized: "No overheating detected"))
                }
            }
        }
    }
}

private struct VolumeProtectionControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let protection = headphones.volumeProtection
        if protection.supportsSafeVolume {
            LabeledContent("Safe Volume Control", value: safeVolumeStatus)
            if let profile = protection.hearingProfile {
                LabeledContent("Safe Volume profile", value: profile == .standard
                               ? String(localized: "Standard") : String(localized: "Sensitive"))
            }
        }
        if protection.supportsMaxVolume {
            LabeledContent("Max Volume Control") {
                if protection.maxVolumeEnabled == false, protection.enablePayload != nil {
                    Button("Turn On") { headphones.enableMaxVolume() }
                        .disabled(!headphones.canConfigureMaxVolume)
                } else if let enabled = protection.maxVolumeEnabled {
                    Text(enabled ? String(localized: "On") : String(localized: "Off"))
                } else {
                    Text("Unknown")
                }
            }
            if let preset = protection.limitPreset {
                LabeledContent("Maximum volume limit") {
                    Menu(presetTitle(preset)) {
                        ForEach(SonyVolumeProtection.LimitPreset.allCases, id: \.self) { preset in
                            Button(presetTitle(preset)) { headphones.setMaxVolumePreset(preset) }
                        }
                    }
                    .disabled(!headphones.canConfigureMaxVolume || protection.maxVolumeEnabled != true
                              || protection.limitPattern == nil)
                }
            }
            if let error = headphones.settingErrors[.maxVolumeEnabled] ?? headphones.settingErrors[.maxVolumePreset] {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var safeVolumeStatus: String {
        let protection = headphones.volumeProtection
        if protection.automaticallyLimiting == true { return String(localized: "Limiting volume") }
        if let enabled = protection.safeVolumeEnabled { return enabled ? String(localized: "On · standby") : String(localized: "Off") }
        return String(localized: "Unknown")
    }

    private func presetTitle(_ preset: SonyVolumeProtection.LimitPreset) -> String {
        (Double(preset.percent) / 100).formatted(.percent)
    }
}

private struct TouchAssignmentControl: View {
    let key: SonyTouchKeyCapability
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if headphones.deviceModel.isEarbuds, key.key <= 0x01 {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 8) {
                    EarbudArtwork(model: headphones.deviceModel, side: key.key == 0x00 ? .left : .right,
                                  artwork: headphones.productArtwork)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    Text(key.title(generation: headphones.touchAssignments.generation)).font(.headline)
                }
                .frame(maxWidth: .infinity)
                assignmentPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(key.title(generation: headphones.touchAssignments.generation)) assignment")
                    .accessibilityIdentifier("touch.assignment.\(key.key)")
                gestures
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(key.title(generation: headphones.touchAssignments.generation)).font(.headline)
                assignmentPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("touch.assignment.\(key.key)")
                gestures
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var gestures: some View {
        if let actions = headphones.touchAssignments.reportedActions(key: key.key) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.action) { action in
                    let title = String(localized: "\(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation)): \(action.functionTitle(generation: headphones.touchAssignments.generation))")
                    let isTouch = key.keyType == 0x00 || key.keyType == 0x02
                    let usesMark = isTouch && [0x00, 0x01, 0x02, 0x10, 0x11].contains(action.action)
                    HStack(alignment: .top, spacing: 8) {
                        if isTouch {
                            HStack(spacing: 3) {
                                if usesMark, action.action <= 0x02 {
                                    ForEach(0...Int(action.action), id: \.self) { _ in
                                        Circle().frame(width: 6, height: 6)
                                    }
                                } else if usesMark {
                                    if action.action == 0x11 {
                                        Circle().frame(width: 6, height: 6)
                                    }
                                    Capsule().frame(width: 18, height: 6)
                                }
                            }
                            .frame(width: 28, height: 20)
                            .accessibilityHidden(true)
                        }
                        if headphones.touchAssignments.inquiryType == 0x03,
                           let customizable = headphones.touchAssignments.customizableActions(key: key.key)
                            .first(where: { $0.action == action.action }),
                           customizable.functions.contains(where: { (0x01...0x04).contains($0) }) {
                            gesturePicker(action, capability: customizable)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.functionTitle(generation: headphones.touchAssignments.generation))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(title)
                                    .accessibilityIdentifier("touch.gesture.\(key.key).\(action.action)")
                                if !usesMark {
                                    Text(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .help(title)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
        } else if headphones.touchAssignments.selectedPreset(key: key.key) != nil {
            Text("Gesture details not reported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func gesturePicker(_ action: SonyTouchActionSetting, capability: SonyTouchCustomizableAction) -> some View {
        let state = headphones.touchAssignments
        let functions = capability.functions.filter { (0x01...0x04).contains($0) }
        let sharedKeys = state.selectedPreset(key: key.key).map { state.keysUsingPreset($0) } ?? []
        let scope = sharedKeys.count > 1 ? sharedKeys.map(\.title).joined(separator: ", ") : key.title(generation: headphones.touchAssignments.generation)
        return VStack(alignment: .leading, spacing: 4) {
            Picker(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation), selection: Binding(
                get: { action.function },
                set: { headphones.setTouchAction(key: key.key, action: action.action, function: $0) }
            )) {
                if !functions.contains(action.function) {
                    Text(action.functionTitle(generation: headphones.touchAssignments.generation)).tag(action.function).disabled(true)
                }
                ForEach(functions, id: \.self) { function in
                    Text(SonyTouchActionSetting(action: action.action, function: function).functionTitle)
                        .tag(function)
                        .disabled(state.setActionPayload(key: key.key, action: action.action, function: function) == nil)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("\(scope) \(action.gestureTitle(keyType: key.keyType, generation: headphones.touchAssignments.generation)) action")
            .accessibilityIdentifier("touch.action.\(key.key).\(action.action)")
            .disabled(!headphones.canSetTouchAction(key: key.key, action: action.action))
            if sharedKeys.count > 1 {
                Text("Shared: \(scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("touch.shared.\(key.key).\(action.action)")
            }
        }
    }

    private var assignmentPicker: some View {
        let state = headphones.touchAssignments
        let selected = state.selectedPreset(key: key.key)
        return Picker(key.title(generation: headphones.touchAssignments.generation), selection: Binding(
            get: { selected },
            set: { if let preset = $0 { headphones.setTouchAssignment(key: key.key, preset: preset) } }
        )) {
            if !key.presets.contains(where: { $0.preset == selected }) {
                Text(selected == nil ? String(localized: "Not reported") : String(localized: "Unsupported assignment"))
                    .tag(selected).disabled(true)
            }
            ForEach(key.presets, id: \.preset) { preset in
                Text(preset.title(generation: state.generation)).tag(Optional(preset.preset))
                    .disabled(state.setPayload(key: key.key, preset: preset.preset) == nil)
            }
        }
        .disabled(!headphones.canSetTouchAssignment(key: key.key))
    }
}

private struct ConnectionModeControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var showsAlert = false
    @State private var requestedMode: SonyConnectionMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connection preference")
                if headphones.connectionTransition?.isFinished == false && headphones.connectionTransition?.awaitingUser == false
                    && headphones.connectionTransition?.phase != .pairingRequired {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Changing connection preference")
                }
                Spacer()
                Picker("Connection preference", selection: Binding(
                    get: { headphones.connectionMode },
                    set: { mode in
                        guard let mode else { return }
                        if headphones.protocolInformation?.generation == .v1 {
                            requestedMode = mode
                            showsAlert = true
                        } else {
                            headphones.setConnectionMode(mode)
                        }
                    }
                )) {
                    if headphones.connectionMode?.sonyValue == nil {
                        Text(headphones.connectionMode == nil ? String(localized: "Loading…") : String(localized: "Unknown"))
                            .tag(headphones.connectionMode)
                    }
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.title).tag(Optional(mode))
                            .disabled(headphones.connectionModeUnavailableReason(mode) != nil)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                .disabled(!modes.contains { $0 != headphones.connectionMode && headphones.connectionModeUnavailableReason($0) == nil })
                .accessibilityIdentifier("audio.connectionMode")
            }
            if let error = headphones.connectionModeError {
                Text(error).font(.caption).foregroundStyle(.primary)
                if headphones.connectionTransition?.phase == .failed,
                   !headphones.isReady || headphones.connectionTransition?.generation == .v1 {
                    Button(headphones.isReady ? String(localized: "Check Preference") : String(localized: "Retry Connection")) { headphones.connect() }
                        .accessibilityIdentifier("audio.retryConnection")
                }
            } else if let status = transitionStatus {
                Text(status).font(.caption).foregroundStyle(.primary)
            } else if let reason = headphones.leAudioUnavailableReason(.connectionPreference) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if headphones.connectionTransition?.awaitingUser == true {
                Button("Review Change…") { showsAlert = true }
                    .accessibilityIdentifier("audio.reviewConnectionChange")
            }
            if let transition = headphones.connectionTransition, transition.phase == .pairingRequired {
                Text("Pair the headphones with this Mac in Bluetooth settings, then check the connection.")
                    .font(.caption).foregroundStyle(.primary)
                Text("Last reported preference: \((headphones.connectionMode ?? transition.originalMode).title)")
                    .font(.caption).foregroundStyle(.primary)
                HStack {
                    Button("Bluetooth Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                    }
                    .foregroundStyle(.tint)
                    Button("Check Connection") { headphones.connect() }
                        .accessibilityIdentifier("audio.checkPairedConnection")
                }
            }
        }
        .onChange(of: headphones.connectionTransition?.alert, initial: true) { _, alert in
            presentedAlert = alert
            showsAlert = alert != nil
        }
        .alert(alertTitle, isPresented: $showsAlert) {
            if let mode = requestedMode {
                Button("Cancel", role: .cancel) { requestedMode = nil }
                Button("Change Preference") {
                    requestedMode = nil
                    headphones.setConnectionMode(mode)
                }
            } else if let alert = presentedAlert {
                if alert.availableActions.contains(.negative) {
                    Button("Cancel", role: .cancel) { headphones.respondToConnectionAlert(alert, action: .negative) }
                }
                if alert.availableActions.contains(.positive) {
                    Button("Continue") { headphones.respondToConnectionAlert(alert, action: .positive) }
                } else if alert.actionType == .confirmationOnly {
                    Button("OK") { headphones.respondToConnectionAlert(alert, action: nil) }
                }
            }
        } message: {
            if requestedMode != nil {
                Text("The audio connection may briefly disconnect while the headphones apply this preference.")
            } else if let alert = presentedAlert {
                Text(alertMessage(alert))
            }
        }
    }

    private var alertTitle: String {
        if let requestedMode { return String(localized: "Use \(requestedMode.title)?") }
        guard let alert = presentedAlert else { return String(localized: "Connection Change") }
        if alert.isLegacyConnectionChange { return String(localized: "Use Stable Connection?") }
        if alert.actionType == .confirmationOnly { return String(localized: "Connection Change") }
        return String(localized: "Use \((alert.requestedMode ?? headphones.connectionTransition?.targetMode)?.title ?? String(localized: "this connection"))?")
    }

    private var modes: [SonyConnectionMode] {
        var modes = (headphones.supportedConnectionModes ?? []).filter { $0.sonyValue != nil && $0 != .lowLatency }
        if let current = headphones.connectionMode, current.sonyValue != nil, !modes.contains(current) {
            modes.insert(current, at: 0)
        }
        return modes
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        let message = switch (alert.format, alert.messageID) {
        case (.legacyFixed, 0x01):
            String(localized: "The headphones require Stable Connection to change these settings. The audio connection will reconnect and music will stop.")
        case (.fixed, 0x71):
            String(localized: "Sound may cut out when Sound Quality and connections to two devices are enabled together. Continue?")
        case (.flexible, 0x10):
            String(localized: "This change requires LE Audio pairing. Pair the headphones with this Mac before using LE Audio.")
        case (.flexible, 0x11):
            String(localized: "This connection uses LE Audio. This Mac also needs an LE Audio connection for playback.")
        default:
            String(localized: "This connection uses Classic Bluetooth. Reconnect the headphones to this Mac to resume audio.")
        }
        let features = alert.affectedFeatures.map(\.title)
        return features.isEmpty ? message : message + String(localized: "\n\nUnavailable with this connection: ") + features.joined(separator: ", ") + "."
    }

    private var transitionStatus: String? {
        guard let transition = headphones.connectionTransition else { return nil }
        switch transition.phase {
        case .queued: return String(localized: "Waiting to send…")
        case .awaitingResponse: return String(localized: "Changing connection preference…")
        case .awaitingUser: return String(localized: "The headphones need your confirmation.")
        case .replyQueued: return String(localized: "Sending your response…")
        case .pairingRequired: return String(localized: "Pairing required.")
        case .reconnecting, .recovering: return String(localized: "Reconnecting controls…")
        case .verifying: return String(localized: "Checking connection preference…")
        case .cancelled: return String(localized: "Change cancelled.")
        case .confirmed, .failed: return nil
        }
    }
}

private struct NoiseToggleControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.noiseToggle {
            Picker("Mode cycle", selection: Binding(
                get: { headphones.noiseToggle?.selected },
                set: { if let option = $0 { headphones.setNoiseToggle(option) } }
            )) {
                if state.selected == nil {
                    Text("Not reported").tag(Optional<UInt8>.none)
                }
                ForEach(state.options ?? [], id: \.self) { option in
                    Text(title(option)).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetNoiseToggle)
            .accessibilityIdentifier("noise.modeCycle")
            .help("Modes switched by the headphones’ noise-control button or touch sensor.")
            if let error = headphones.settingErrors[.noiseToggle] {
                Text(error).font(.caption).foregroundStyle(.primary)
            }
        }
    }

    private func title(_ option: UInt8) -> String {
        switch option {
        case 1: String(localized: "Noise Cancelling / Ambient Sound / Off")
        case 2: String(localized: "Noise Cancelling / Ambient Sound")
        case 3: String(localized: "Noise Cancelling / Off")
        case 4: String(localized: "Ambient Sound / Off")
        default: String(localized: "Unknown")
        }
    }
}

private struct NoiseAdaptationControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.noiseControlDisplayState, let adaptationEnabled = state.adaptationEnabled,
           let sensitivity = state.sensitivity {
            HStack {
                Toggle(isOn: Binding(
                    get: { headphones.noiseControlDisplayState?.adaptationEnabled ?? adaptationEnabled },
                    set: { headphones.setNoiseAdaptation(enabled: $0) }
                )) {
                    HStack {
                        Text("Noise adaptation")
                        if headphones.pendingChanges[.noiseControl] != nil {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("Updating noise control")
                        }
                    }
                }
                .disabled(!headphones.canChangeNoiseControl || headphones.pendingChanges[.noiseControl] != nil)
                .accessibilityIdentifier("noise.adaptation")
            }
            Picker("Sensitivity", selection: Binding(
                get: { headphones.noiseControlDisplayState?.sensitivity ?? sensitivity },
                set: headphones.setNoiseAdaptationSensitivity
            )) {
                ForEach(SonyNoiseControl.Sensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canChangeNoiseControl || !adaptationEnabled || headphones.pendingChanges[.noiseControl] != nil)
            .accessibilityIdentifier("noise.sensitivity")
            if let error = headphones.settingErrors[.noiseControl] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if headphones.noiseControl?.canSet != true {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Noise adaptation", value: String(localized: "Unavailable"))
        }
    }
}

private struct SpeakerSoundEffectControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let sound = headphones.equalizer.soundEffect
        LabeledContent("Sound effect") {
            if let modes = sound.modes, !modes.isEmpty, let selected = sound.selectedCode {
                Menu(SonySoundEffect.Effect(rawValue: selected).map(title) ?? String(localized: "Unavailable")) {
                    ForEach(modes) { effect in
                        Button {
                            headphones.setSoundEffect(effect)
                        } label: {
                            if selected == effect.rawValue {
                                Label(title(effect), systemImage: "checkmark")
                            } else {
                                Text(title(effect))
                            }
                        }
                        .disabled(!sound.canSelect(effect))
                    }
                }
                .disabled(!headphones.canChangeSoundEffect || sound.available != true)
            } else {
                Text("Unknown")
            }
        }
        .accessibilityIdentifier("equalizer.soundEffect")
        if headphones.pendingChanges[.soundEffect] != nil { ProgressView().controlSize(.small) }
        if let error = headphones.settingErrors[.soundEffect] { Text(error).font(.caption) }
    }

    private func title(_ effect: SonySoundEffect.Effect) -> String {
        effect == .ult ? "ULT POWER SOUND" : effect.title
    }
}

private struct SpeakerCustomEQControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let custom = headphones.equalizer.customEQ
        if let values = custom.editableValues, let bands = custom.bands, let steps = custom.levelSteps {
            Text("Custom EQ")
            let titles = bands.count == 3
                ? [String(localized: "Bass"), String(localized: "Middle"), String(localized: "Treble")]
                : bands.map(\.title)
            SpeakerEqualizerLevels(values: values, titles: titles, levelSteps: steps,
                                   applyIdentifier: "equalizer.customEQ.apply", allowsDraftReset: true) {
                headphones.setCustomEQLevels($0, basedOn: custom)
            }
            .id(SpeakerEqualizerLevels.Identity(session: headphones.notificationSession, effect: nil,
                                               values: values, bands: bands, levelSteps: steps))
            .disabled(!headphones.canChangeCustomEQ)
        } else {
            LabeledContent("Custom EQ", value: String(localized: "Unknown"))
        }
        if headphones.pendingChanges[.customEQ] != nil { ProgressView().controlSize(.small) }
        if let error = headphones.settingErrors[.customEQ] { Text(error).font(.caption) }
    }
}

private struct CustomSoundEffectControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var resetTarget: (effect: SonyCustomSoundEffect.Effect, session: UInt64)?

    var body: some View {
        let sound = headphones.equalizer.customSoundEffect
        let title = headphones.equalizer.soundEffect.isSupported
            ? String(localized: "Customizable sound effect") : String(localized: "Sound effect")
        if let effects = sound.effects, !effects.isEmpty, let selected = sound.selectedCode {
            Picker(title, selection: Binding(
                get: { headphones.equalizer.customSoundEffect.selectedCode ?? selected },
                set: { code in
                    if let effect = SonyCustomSoundEffect.Effect(rawValue: code) {
                        headphones.selectCustomSoundEffect(effect)
                    }
                }
            )) {
                if !effects.contains(where: { $0.rawValue == selected }) { Text("Unavailable").tag(selected) }
                ForEach(effects) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!headphones.canChangeCustomSoundEffect)
            .accessibilityIdentifier("equalizer.customSoundEffect")
            if let effect = sound.selectedEffect, let values = sound.editableValues,
               let bands = sound.bands, let steps = sound.levelSteps {
                SpeakerEqualizerLevels(values: values, titles: bands.map(\.title), levelSteps: steps,
                                       applyIdentifier: "equalizer.customSoundEffect.apply") {
                    headphones.editCustomSoundEffect(effect, values: $0, basedOn: values)
                }
                .id(SpeakerEqualizerLevels.Identity(session: headphones.notificationSession, effect: effect,
                                                   values: values, bands: bands, levelSteps: steps))
                .disabled(!headphones.canChangeCustomSoundEffect)
            }
            if let effect = sound.selectedEffect, sound.resetPayload(effect) != nil {
                Button("Reset Sound Effect…") { resetTarget = (effect, headphones.notificationSession) }
                    .disabled(!headphones.canChangeCustomSoundEffect)
                    .confirmationDialog("Reset Sound Effect?", isPresented: Binding(
                        get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }
                    ), titleVisibility: .visible, presenting: resetTarget) { target in
                        Button("Reset", role: .destructive) {
                            if target.session == headphones.notificationSession { headphones.resetCustomSoundEffect(target.effect) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        } else {
            LabeledContent(title, value: String(localized: "Unknown"))
        }
        if headphones.pendingChanges[.customSoundEffect] != nil { ProgressView().controlSize(.small) }
        if let error = headphones.settingErrors[.customSoundEffect] { Text(error).font(.caption) }
    }
}

private struct SpeakerEqualizerLevels: View {
    struct Identity: Hashable {
        let session: UInt64
        let effect: SonyCustomSoundEffect.Effect?
        let values: [UInt8]
        let bands: [SonyEqualizerBand]
        let levelSteps: Int
    }

    let values: [UInt8]
    let titles: [String]
    let levelSteps: Int
    let applyIdentifier: String
    let allowsDraftReset: Bool
    let apply: ([UInt8]) -> Void
    @State private var draft: [UInt8]

    init(values: [UInt8], titles: [String], levelSteps: Int, applyIdentifier: String, allowsDraftReset: Bool = false,
         apply: @escaping ([UInt8]) -> Void) {
        self.values = values
        self.titles = titles
        self.levelSteps = levelSteps
        self.applyIdentifier = applyIdentifier
        self.allowsDraftReset = allowsDraftReset
        self.apply = apply
        _draft = State(initialValue: values)
    }

    var body: some View {
        Group {
            ForEach(titles.indices, id: \.self) { index in
                let center = (levelSteps - 1) / 2
                HStack {
                    Text(titles[index])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { Double(draft[index]) },
                        set: { draft[index] = UInt8($0) }
                    ), in: 0...Double(levelSteps - 1), step: 1) {
                        Text(titles[index])
                    }
                    .labelsHidden()
                    .accessibilityValue("\(Int(draft[index]) - center)")
                    .frame(maxWidth: .infinity)
                    Text((Int(draft[index]) - center).formatted(.number.sign(strategy: .always(includingZero: false))))
                        .monospacedDigit()
                }
            }
            HStack {
                if allowsDraftReset { Button("Reset") { draft = values } }
                Button("Apply") { apply(draft) }
                    .accessibilityIdentifier(applyIdentifier)
            }
            .disabled(draft == values)
        }
    }
}

private struct ULTSoundEffectAssignmentControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let assignment = headphones.equalizer.ultSoundEffectAssignment
        LabeledContent("ULT button settings") {
            if let entries = assignment.entries, let count = assignment.selectionCount {
                VStack(alignment: .leading) {
                    Text("The speaker’s ULT button cycles through the selected sound modes.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        Toggle(entry.id.title, isOn: Binding(
                            get: { headphones.equalizer.ultSoundEffectAssignment.entries?.first { $0.id == entry.id }?.enabled == true },
                            set: { headphones.setULTSoundEffectAssignment(entry.id, enabled: $0) }
                        ))
                        .disabled(!headphones.canChangeULTSoundEffectAssignment
                                  || assignment.setPayload(entry.id, enabled: !entry.enabled) == nil)
                    }
                    if count.lowerBound == count.upperBound {
                        Text("Select \(count.lowerBound) sound modes.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Select \(count.lowerBound) to \(count.upperBound) sound modes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Unknown")
            }
        }
        .accessibilityIdentifier("equalizer.ultSoundEffectAssignment")
        if headphones.pendingChanges[.ultSoundEffectAssignment] != nil { ProgressView().controlSize(.small) }
        if let error = headphones.settingErrors[.ultSoundEffectAssignment] { Text(error).font(.caption) }
    }
}

private struct TurnKeyEqualizerControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var code = ""
    @State private var deletion: (preset: SonyEqualizerPreset, address: String, session: UInt64)?

    var body: some View {
        let equalizer = headphones.equalizer
        let feature = equalizer.turnKey
        if feature.supportsImport {
            LabeledContent("Import Equalizer Preset") {
                HStack {
                    TextField("Preset code", text: $code)
                        .accessibilityIdentifier("equalizer.importCode")
                    Button("Import") {
                        headphones.importTurnKeyEqualizer(code)
                        if headphones.pendingChanges[.turnKeyEQ] != nil { code = "" }
                    }
                    .disabled(!headphones.canChangeTurnKeyEqualizer || feature.importPayload(code) == nil)
                }
            }
            if !headphones.turnKeyImportActions.isEmpty {
                LabeledContent("Add the preset to the headphones?") {
                    HStack {
                        if headphones.turnKeyImportActions.contains(.negative) {
                            Button("Cancel") { headphones.respondToTurnKeyEqualizerImport(.negative) }
                        }
                        Button("Add and Reconnect") { headphones.respondToTurnKeyEqualizerImport(.positive) }
                            .accessibilityIdentifier("equalizer.confirmImport")
                    }
                }
            }
        }
        if feature.supportsManagement {
            let ids = Set(feature.deletablePresets ?? []).subtracting([0xFF]).sorted()
            let presets = ids.map { id in
                equalizer.capabilities?.presets.first(where: { $0.id == id }) ?? SonyEqualizerPreset(id: id, name: nil)
            }
            LabeledContent("Headphone Presets") {
                if presets.isEmpty {
                    Text(feature.deletablePresets == nil ? String(localized: "Unknown") : String(localized: "No removable presets"))
                } else {
                    Menu("Remove Preset") {
                        ForEach(presets) { preset in
                            Button(preset.title) { deletion = (preset, headphones.address, headphones.notificationSession) }
                        }
                    }
                    .disabled(!headphones.canChangeTurnKeyEqualizer)
                    .accessibilityIdentifier("equalizer.removablePresets")
                    .confirmationDialog("Delete Headphone Preset?", isPresented: Binding(
                        get: { deletion != nil }, set: { if !$0 { deletion = nil } }
                    ), titleVisibility: .visible, presenting: deletion) { target in
                        Button("Delete", role: .destructive) {
                            if headphones.address == target.address, headphones.notificationSession == target.session {
                                headphones.deleteTurnKeyEqualizerPreset(target.preset.id)
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { target in
                        Text("Remove “\(target.preset.title)” from the headphones?")
                    }
                }
            }
            if feature.limit == .maximum { Text("Headphone preset storage is full.").font(.caption) }
        }
        if headphones.pendingChanges[.turnKeyEQ] != nil { ProgressView().controlSize(.small) }
        if let error = headphones.settingErrors[.turnKeyEQ] { Text(error).font(.caption) }
        else if let operation = feature.lastCompletedOperation {
            Text(operation == 0x32 ? String(localized: "Preset addition approved.")
                 : String(localized: "Headphone preset deleted.")).font(.caption)
        }
    }
}

struct BassBoostControl: View {
    let effect: SonyBassBoost
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var draft: Double?
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let level = effect.level, let range = effect.range, range.lowerBound < range.upperBound {
                HStack {
                    Slider(value: Binding(get: { isEditing ? draft ?? Double(level) : Double(level) }, set: {
                        draft = $0
                        if !isEditing { headphones.setBassBoost(Int($0)) }
                    }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1, onEditingChanged: {
                        isEditing = $0
                        if !$0, let draft {
                            headphones.setBassBoost(Int(draft))
                            self.draft = nil
                        }
                    }) { Text("Clear Bass") }
                    .disabled(!headphones.canSetBassBoost)
                    .accessibilityLabel("Clear Bass")
                    .accessibilityIdentifier("audio.clearBass")
                    Text((isEditing ? draft.map(Int.init) ?? level : level).formatted())
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
            } else {
                LabeledContent("Clear Bass", value: effect.level?.formatted() ?? String(localized: "Unknown"))
            }
            if let error = headphones.settingErrors[.bassBoost] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if effect.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LegacySoundEffectControl: View {
    let kind: SonyLegacySoundEffect.Kind
    var displayedEffect: SonyLegacySoundEffect? = nil
    @EnvironmentObject private var headphones: SonyHeadphonesController

    private var effect: SonyLegacySoundEffect { displayedEffect ?? headphones.legacySoundEffect(kind) }
    private var setting: SonyHeadphonesController.Setting { .legacySoundEffect(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(kind.title)
                if headphones.pendingChanges[setting] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating \(kind.title)")
                }
                Spacer()
                Picker(kind.title, selection: Binding(
                    get: { effect.presetID },
                    set: { if let preset = $0 { headphones.setLegacySoundEffect(kind, preset: preset) } }
                )) {
                    if !effect.selectablePresets.contains(where: { $0.id == effect.presetID }) {
                        Text(effect.selectedTitle ?? (headphones.settingErrors[setting] == nil ? String(localized: "Loading…") : String(localized: "Unknown")))
                            .tag(effect.presetID).disabled(true)
                    }
                    ForEach(effect.selectablePresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(maxWidth: 180, alignment: .trailing)
                .disabled(!headphones.canSetLegacySoundEffect(kind))
                .accessibilityIdentifier(kind == .surround ? "audio.surround" : "audio.soundPosition")
            }
            if let error = headphones.settingErrors[setting] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if effect.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DSEEControl: View {
    struct Presentation {
        let type: SonyDSEEType?
        let mode: SonyDSEEMode?
        let unavailableMessage: String?

        @MainActor
        init(_ headphones: SonyHeadphonesController) {
            type = headphones.dseeType
            mode = headphones.dseeMode
            let reasons = headphones.audioFeatures.dseeDisableReasons
            if reasons.contains(.calling) {
                unavailableMessage = String(localized: "Unavailable during a call.")
            } else if reasons.contains(.listeningModeIsNotStandard) {
                unavailableMessage = String(localized: "Unavailable outside Standard listening mode.")
            } else if headphones.dseeAvailable == false || !reasons.isEmpty {
                unavailableMessage = String(localized: "Currently unavailable.")
            } else {
                unavailableMessage = nil
            }
        }
    }

    var presentation: Presentation? = nil
    @EnvironmentObject private var headphones: SonyHeadphonesController

    private var state: Presentation { presentation ?? Presentation(headphones) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.type?.title ?? "DSEE")
                if headphones.pendingChanges[.dsee] != nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating \(state.type?.title ?? "DSEE")")
                }
                Spacer()
                Picker(state.type?.title ?? "DSEE", selection: Binding(
                    get: { state.mode },
                    set: { if let mode = $0 { headphones.setDSEE(mode) } }
                )) {
                    if state.mode?.sonyValue == nil {
                        Text(state.mode == nil && headphones.settingErrors[.dsee] == nil ? String(localized: "Loading…") : String(localized: "Unknown"))
                            .tag(state.mode)
                    }
                    ForEach(SonyDSEEMode.allCases) { mode in
                        Text(mode.title).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                .disabled(!headphones.canSetDSEE)
                .accessibilityIdentifier("audio.dsee")
            }
            if let error = headphones.settingErrors[.dsee] {
                Text(error).font(.caption).foregroundStyle(.primary)
            } else if let unavailableMessage = state.unavailableMessage {
                Text(unavailableMessage).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio.dseeRestriction")
            }
        }
    }
}

private struct AdaptiveVolumeWithLimitationControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedCaution: SonyConnectionAlert?
    @State private var presentedRequestID: UUID?
    @State private var showsCaution = false

    var body: some View {
        let state = headphones.adaptiveVolumeWithLimitation
        VStack(alignment: .leading, spacing: 6) {
            if let enabled = state.enabled {
                Toggle("Adaptive Volume Control", isOn: Binding(
                    get: { enabled }, set: headphones.setAdaptiveVolumeWithLimitation
                ))
                .disabled(!headphones.canSetAdaptiveVolumeWithLimitation)
                .accessibilityIdentifier("audio.adaptiveVolume")
            } else {
                LabeledContent("Adaptive Volume Control") { Text("Unknown") }
            }
            Text("Adjusts headphone volume as the surrounding noise changes.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = headphones.settingErrors[.adaptiveVolumeWithLimitation] {
                Text(error).font(.caption)
            } else if state.limitationActive == true {
                Text("Adaptive Volume Control is paused while Safe Volume Control limits the volume.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: headphones.adaptiveVolumeCaution, initial: true) { _, caution in
            presentedCaution = caution
            presentedRequestID = headphones.adaptiveVolumeCautionRequestID
            showsCaution = caution != nil
        }
        .alert("Adaptive Volume Control", isPresented: $showsCaution, presenting: presentedCaution) { caution in
            Button("OK") { headphones.acknowledgeAdaptiveVolumeCaution(caution, requestID: presentedRequestID) }
        } message: { caution in
            if caution.messageID == 0x5B {
                Text("Safe Volume Control is limiting the volume. Adaptive Volume Control will resume automatically when the limit is lifted.")
            } else {
                Text("Adaptive Volume Control pauses whenever Safe Volume Control limits the volume.")
            }
        }
    }
}

private struct MicrophoneOperationControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.microphoneOperation
        if let gesture = state.gestureEnabled, let tone = state.toneEnabled {
            Toggle("Headphone microphone control", isOn: Binding(
                get: { gesture }, set: { headphones.setMicrophoneOperation(gesture: $0) }
            ))
            .disabled(!headphones.canSetMicrophoneOperation)
            .accessibilityIdentifier("microphoneOperation.gesture")
            Toggle("Microphone-off tone", isOn: Binding(
                get: { tone }, set: { headphones.setMicrophoneOperation(tone: $0) }
            ))
            .disabled(!headphones.canSetMicrophoneOperation || !gesture)
            .accessibilityIdentifier("microphoneOperation.tone")
        } else {
            LabeledContent("Headphone microphone control") { Text("Unknown") }
        }
        if let key = state.key {
            switch key {
            case .touchSensor:
                Text("Double-tap the touch sensor during a call to switch the microphone on or off.")
            case .button:
                Text("Press the NC/AMB button twice during a call to switch the microphone on or off.")
            case .faceTap:
                Text("Use the earbuds’ tap gesture during a call to switch the microphone on or off.")
            }
        }
        if headphones.deviceModel.isEarbuds {
            Text("Double-tap must have an assigned action. With microphone control enabled, double-tap no longer ends a call.")
        }
        Text("Calling apps may show a different microphone status. The optional tone repeats while the headphone microphone is off.")
        if let error = headphones.settingErrors[.microphoneOperation] {
            Text(error)
        } else if state.available == false {
            Text("Currently unavailable.")
        }
        if headphones.pendingChanges[.microphoneOperation] != nil { ProgressView().controlSize(.mini) }
    }
}

private struct SystemFeatureControl: View {
    let feature: SonySystemFeature
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatureState(feature), state.isVisible != false {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setSystemFeature(feature, enabled: $0) }
                        )) {
                            HStack {
                                Text(feature.title)
                                if headphones.pendingChanges[.system(feature)] != nil {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Updating \(feature.title)")
                                }
                            }
                        }
                        .disabled(!headphones.canSetSystemFeature(feature))
                        .accessibilityIdentifier("system.\(feature.rawValue)")
                    } else {
                        LabeledContent(feature.title) {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.system(feature)] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if feature == .voiceAssistantWakeWord,
                          let reason = headphones.leAudioUnavailableReason(.voiceAssistantWakeWord) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if feature == .speakToChat {
                SpeakToChatOptionsControl()
            }
        }
    }
}

private struct SpeakToChatOptionsControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let options = headphones.systemFeatures.speakToChatOptions {
            Group {
                Picker(selection: Binding(
                    get: { options.sensitivity },
                    set: { if let sensitivity = $0, let delay = options.delay {
                        headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay)
                    } }
                )) {
                    if options.sensitivity?.sonyValue == nil {
                        Text("Unknown").tag(options.sensitivity).disabled(true)
                    }
                    ForEach(SonySpeechSensitivity.options, id: \.self) { sensitivity in
                        Text(sensitivity.title).tag(Optional(sensitivity))
                    }
                } label: {
                    HStack {
                        Text("Voice detection sensitivity")
                        if headphones.pendingChanges[.speakToChatOptions] != nil {
                            ProgressView().controlSize(.mini).accessibilityLabel("Updating Speak-to-Chat")
                        }
                    }
                }
                .help("Choose High if speech is missed, or Low if Speak-to-Chat starts unintentionally.")
                .accessibilityIdentifier("system.speechSensitivity")
                Picker("End Speak-to-Chat", selection: Binding(
                    get: { options.delay },
                    set: { if let delay = $0, let sensitivity = options.sensitivity {
                        headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay)
                    } }
                )) {
                    if options.delay?.sonyValue == nil {
                        Text("Unknown").tag(options.delay).disabled(true)
                    }
                    ForEach(SonySpeakToChatDelay.options, id: \.self) { delay in
                        if delay.rawValue < 3, let seconds = options.delaySeconds?[Int(delay.rawValue)], seconds > 0 {
                            Text("\(delay.title) (\(Int(seconds)) s)").tag(Optional(delay))
                        } else {
                            Text(delay.title).tag(Optional(delay))
                        }
                    }
                }
                .help("The delay begins when you stop speaking.")
                .accessibilityIdentifier("system.speakToChatDelay")
                if options.variant.hasVoiceFocus {
                    if let voiceFocus = options.voiceFocus {
                        Toggle("Voice passthrough", isOn: Binding(
                            get: { voiceFocus },
                            set: { if let sensitivity = options.sensitivity, let delay = options.delay {
                                headphones.setSpeakToChatOptions(sensitivity: sensitivity, delay: delay, voiceFocus: $0)
                            } }
                        ))
                        .accessibilityIdentifier("system.speakToChatVoiceFocus")
                    } else {
                        LabeledContent("Voice passthrough") {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.speakToChatOptions] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetSpeakToChatOptions)
        }
    }
}

private struct VoiceAssistantControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatures.voiceAssistant {
            let options = state.knownOptions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.knownCurrent },
                        set: { if let option = $0 { headphones.setVoiceAssistant(option) } }
                    )) {
                        if !options.contains(where: { $0 == state.knownCurrent }) {
                            Text(state.knownCurrent?.title ?? String(localized: "Unknown")).tag(state.knownCurrent)
                                .disabled(true)
                        }
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                                .disabled(state.setPayload(option) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Voice assistant")
                            if headphones.pendingChanges[.voiceAssistant] != nil {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Updating voice assistant")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.canSetVoiceAssistant)
                    .help(headphones.leAudioUnavailableReason(.voiceAssistant)
                          ?? String(localized: "Assistant setup is managed in Sony Sound Connect on your phone."))
                    .accessibilityIdentifier("system.voiceAssistant")
                }
                if let alert = headphones.voiceAssistantSideAlert, let requestID = headphones.voiceAssistantSideAlertRequestID {
                    VoiceAssistantSideControl(alert: alert, requestID: requestID)
                        .id(requestID)
                }
                if let error = headphones.settingErrors[.voiceAssistant] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if let reason = headphones.leAudioUnavailableReason(.voiceAssistant) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct VoiceAssistantSideControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var side: SonyVoiceAssistantSideAlert.Action
    let alert: SonyVoiceAssistantSideAlert
    let requestID: UUID

    init(alert: SonyVoiceAssistantSideAlert, requestID: UUID) {
        self.alert = alert
        self.requestID = requestID
        _side = State(initialValue: alert.defaultSide)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $side) {
                Text("Left").tag(SonyVoiceAssistantSideAlert.Action.left)
                Text("Right").tag(SonyVoiceAssistantSideAlert.Action.right)
            } label: {
                if alert.usesTouchSensor { Text("Voice assistant touch sensor") }
                else { Text("Voice assistant button") }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("system.voiceAssistantSide")
            if alert.restartsHeadphones {
                Text("The headphones will restart after changing the voice assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { headphones.respondToVoiceAssistantSideAlert(alert, action: .cancel, requestID: requestID) }
                Button("Continue") { headphones.respondToVoiceAssistantSideAlert(alert, action: side, requestID: requestID) }
            }
        }
    }
}

private struct AutomaticPowerOffControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.automaticPowerOff {
            let options = state.knownOptions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(selection: Binding(
                        get: { state.knownCurrent },
                        set: { if let option = $0 { headphones.setAutomaticPowerOff(option) } }
                    )) {
                        if !options.contains(where: { $0 == state.knownCurrent }) {
                            Text(state.knownCurrent?.title ?? String(localized: "Unknown")).tag(state.knownCurrent)
                                .disabled(true)
                        }
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                                .disabled(state.setPayload(option) == nil)
                        }
                    } label: {
                        HStack {
                            Text("Automatic power off")
                            if headphones.pendingChanges[.automaticPowerOff] != nil {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Updating automatic power off")
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .disabled(!headphones.canSetAutomaticPowerOff)
                    .accessibilityIdentifier("system.automaticPowerOff")
                }
                if let error = headphones.settingErrors[.automaticPowerOff] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BatteryCareControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.batteryCare {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled }, set: { headphones.setBatteryCare($0) }
                        )) {
                            HStack {
                                Text("Battery Care")
                                if headphones.pendingChanges[.batteryCare] != nil {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating Battery Care")
                                }
                            }
                        }
                        .disabled(!headphones.canSetBatteryCare)
                        .accessibilityIdentifier("power.batteryCare")
                    } else {
                        LabeledContent("Battery Care", value: String(localized: "Unknown"))
                    }
                }
                if let threshold = state.threshold {
                    LabeledContent("Charging limit", value: String(localized: "\(Int(threshold))%")).font(.caption)
                }
                if let error = headphones.settingErrors[.batteryCare] {
                    Text(error).font(.caption)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ListeningModeControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let current = headphones.audioFeatures.listeningMode {
            let options = headphones.audioFeatures.listeningModeOptions
            Picker("Listening mode", selection: Binding(get: { current }, set: headphones.setListeningMode)) {
                ForEach(options, id: \.self) { mode in
                    Text(listeningModeTitle(mode)).tag(mode)
                        .disabled(mode != current && !headphones.canSetListeningMode(mode))
                }
                if !options.contains(current) {
                    Text(listeningModeTitle(current)).tag(current)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!options.contains(where: headphones.canSetListeningMode))
            .accessibilityIdentifier("listeningMode.selection")
        } else {
            LabeledContent("Listening mode", value: String(localized: "Unknown"))
                .accessibilityIdentifier("listeningMode.selection")
        }
        if headphones.audioFeatures.listeningMode == .soundLeakageReduction {
            Text("Reduces sound leakage by lowering high-pitched sounds.").font(.caption).foregroundStyle(.secondary)
            if headphones.soundLeakageReductionExcludes(.equalizer) {
                Text("Equalizer is unavailable in the current headphone mode.").font(.caption)
            }
            if headphones.soundLeakageReductionExcludes(.dsee) {
                Text("DSEE is unavailable in the current headphone mode.").font(.caption)
            }
        }
        if let reason = headphones.voiceContentsConnectionRestriction {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(SonyUpmix.Variant.allCases, id: \.self) { variant in
            if let upmix = headphones.audioFeatures.upmix[variant] {
                SpeakerUpmixControls(upmix: upmix, showsSelection: false)
            }
        }
        if headphones.isChangingListeningMode {
            ProgressView().controlSize(.small)
        }
        ForEach(Array(Set(headphones.listeningModeErrors)).sorted(), id: \.self) { error in
            Text(error).font(.caption)
        }
    }
}

private struct ListeningModeAssignmentControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    let assignments: SonyListeningModeAssignments

    var body: some View {
        if let options = assignments.options, let selection = assignments.selection {
            Text("Choose which modes the Listening mode button cycles through.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(options) { option in
                Toggle(isOn: Binding(get: { selection.contains(option.item) },
                                     set: { _ in headphones.toggleListeningModeAssignment(option.item) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listeningModeTitle(option.item.mode))
                        if option.requirement == .mandatory {
                            Text("This mode is required.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!headphones.canToggleListeningModeAssignment(option.item))
                .accessibilityIdentifier("listeningMode.assignment.\(option.item.rawValue)")
            }
        } else {
            LabeledContent("Assigned modes", value: String(localized: "Unknown"))
        }
        if assignments.available == false {
            Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
        }
        if headphones.pendingChanges[.listeningModeAssignments] != nil {
            ProgressView().controlSize(.small)
        }
        if let error = headphones.settingErrors[.listeningModeAssignments] {
            Text(error).font(.caption)
        }
    }
}

private func listeningModeTitle(_ mode: SonyListeningMode) -> LocalizedStringKey {
    switch mode {
    case .standard: "Standard"
    case .backgroundMusic: "Background Music"
    case .cinema: "Cinema"
    case .game: "Game"
    case .music: "Music"
    case .voiceContents: "Voice boost"
    case .soundLeakageReduction: "Sound leakage reduction"
    }
}

private struct BackgroundMusicControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    let music: SonyBackgroundMusic
    let showsPower: Bool

    var body: some View {
        if showsPower {
            if let enabled = music.enabled {
                Toggle("Background Music Effect", isOn: Binding(get: { enabled }, set: headphones.setBackgroundMusic))
                    .disabled(!headphones.canSetBackgroundMusic)
                    .accessibilityIdentifier("backgroundMusic.enabled")
            } else {
                LabeledContent("Background Music Effect", value: String(localized: "Unknown"))
            }
        }
        if let room = music.room {
            Picker("Room size", selection: Binding(get: { room }, set: headphones.setBackgroundMusicRoom)) {
                ForEach(SonyBackgroundMusic.Room.allCases, id: \.self) { option in
                    Text(roomTitle(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetBackgroundMusic)
            .accessibilityIdentifier("backgroundMusic.roomSize")
        } else {
            LabeledContent("Room size", value: String(localized: "Unknown"))
        }
        if let reason = headphones.backgroundMusicConnectionRestriction {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        } else if music.available == false {
            if music.reasons.isEmpty {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(Set(music.reasons)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { reason in
                Text(reasonTitle(reason)).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let exclusions = music.exclusions {
            if exclusions.contains(0) {
                Text("Equalizer is unavailable while this listening mode is active.").font(.caption).foregroundStyle(.secondary)
            }
            if exclusions.contains(1) {
                Text("DSEE is unavailable while this listening mode is active.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if showsPower {
            if let error = headphones.settingErrors[.backgroundMusic] {
                Text(error).font(.caption)
            } else if headphones.pendingChanges[.backgroundMusic] != nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func roomTitle(_ room: SonyBackgroundMusic.Room) -> LocalizedStringKey {
        switch room {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    private func reasonTitle(_ reason: SonyBackgroundMusic.UnavailableReason) -> LocalizedStringKey {
        switch reason {
        case .calling: "Unavailable during a call."
        case .demoMode: "Demo Mode is active."
        case .leAudioConnected, .leAudioPlaying: "Unavailable with LE Audio."
        case .tandemOverGATT: "Unavailable over Bluetooth LE controls."
        case .googleAssistant: "Google Assistant is active."
        case .sonyAssistant: "Sony Voice Control is active."
        case .tencentAssistant: "Tencent Xiaowei is active."
        case .upmixCinema: "Cinema upmix is active."
        case .upmixGame: "Game upmix is active."
        case .upmixMusic: "Music upmix is active."
        case .nonstandardListeningMode: "Choose Standard as the listening mode first."
        case .other: "Currently unavailable."
        }
    }
}

private struct SpeakerUpmixControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    let upmix: SonyUpmix
    let showsSelection: Bool

    var body: some View {
        if showsSelection { selectionControl }
        if upmix.preferredEffect == .bravia3DSurround, let selection = upmix.selection, selection != .standard {
            Text("BRAVIA 3D Surround takes priority. Turn it off on your TV to hear the Upmix effect.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if upmix.available == false {
            Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
        }
        if let exclusions = upmix.exclusions, !exclusions.isEmpty {
            if exclusions.contains(0) {
                Text("Equalizer is unavailable while this listening mode is active.").font(.caption).foregroundStyle(.secondary)
            }
            if exclusions.contains(1) {
                Text("DSEE is unavailable while this listening mode is active.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if showsSelection {
            if let error = headphones.settingErrors[.upmix(upmix.variant)] {
                Text(error).font(.caption)
            } else if headphones.pendingChanges[.upmix(upmix.variant)] != nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private var selectionControl: some View {
        if upmix.variant == .cinema {
            if let selection = upmix.selection {
                let next: SonyUpmix.Mode = selection == .cinema ? .standard : .cinema
                Toggle("Cinema upmix", isOn: Binding(get: { selection == .cinema },
                                                     set: { headphones.setUpmix(.cinema, mode: $0 ? .cinema : .standard) }))
                    .disabled(!headphones.canSetUpmix(.cinema, mode: next))
                    .accessibilityIdentifier("upmix.cinema")
            } else {
                LabeledContent("Cinema upmix", value: String(localized: "Unknown"))
            }
        } else {
            if let selection = upmix.selection, upmix.selectableModes.contains(selection) {
                Picker("Listening mode", selection: Binding(get: { selection }, set: { headphones.setUpmix(.series, mode: $0) })) {
                    ForEach(upmix.selectableModes, id: \.self) { mode in
                        Text(title(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .disabled(!upmix.selectableModes.contains(where: { headphones.canSetUpmix(.series, mode: $0) }))
                .accessibilityIdentifier("upmix.series")
            } else {
                LabeledContent("Listening mode") {
                    Text(upmix.selection.map(title) ?? "Unknown")
                }
            }
        }
    }

    private func title(_ mode: SonyUpmix.Mode) -> LocalizedStringKey {
        switch mode {
        case .standard: "Standard"
        case .cinema: "Cinema"
        case .game: "Game"
        case .music: "Music"
        }
    }
}

private struct SoundFieldOptimizationControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    let optimization: SonySoundFieldOptimization

    var body: some View {
        if let enabled = optimization.enabled {
            Toggle("Adjust sound automatically", isOn: Binding(get: { enabled }, set: headphones.setSoundFieldOptimization))
                .disabled(!headphones.canSetSoundFieldOptimization)
                .accessibilityIdentifier("soundFieldOptimization.enabled")
        } else {
            LabeledContent("Adjust sound automatically", value: String(localized: "Unknown"))
        }
        Text("The speaker adapts its sound to surrounding noise.")
            .font(.caption).foregroundStyle(.secondary)
        if let reason = unavailableReason {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
        if let error = headphones.settingErrors[.soundFieldOptimization] {
            Text(error).font(.caption)
        } else if headphones.pendingChanges[.soundFieldOptimization] != nil {
            ProgressView().controlSize(.small)
        }
    }

    private var unavailableReason: LocalizedStringKey? {
        switch optimization.exclusion {
        case .stereoPair: "Unavailable while Stereo Pair is active."
        case .partyConnect: "Unavailable while Party Connect is active."
        case .partyChainTransmitter, .partyChainReceiver: "Unavailable while Party Chain is active."
        case .tvSoundBooster: "Sound Field Optimization is unavailable while TV Sound Booster is on."
        default: optimization.available == false ? "Currently unavailable." : nil
        }
    }
}

private struct TVSoundBoosterControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    let booster: SonyTVSoundBooster

    var body: some View {
        if let enabled = booster.enabled {
            Toggle("Boost TV sound", isOn: Binding(get: { enabled }, set: headphones.setTVSoundBooster))
                .disabled(!headphones.canSetTVSoundBooster)
                .accessibilityIdentifier("tvSoundBooster.enabled")
        } else {
            LabeledContent("Boost TV sound", value: String(localized: "Unknown"))
        }
        if let delay = booster.delay {
            Picker("TV audio synchronization", selection: Binding(get: { delay }, set: headphones.setTVSoundBoosterDelay)) {
                ForEach(SonyTVSoundBooster.delays, id: \.self) { step in
                    Text("\(step * 10) ms").tag(step)
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetTVSoundBoosterDelay)
            .accessibilityIdentifier("tvSoundBooster.delay")
        } else {
            LabeledContent("TV audio synchronization", value: String(localized: "Unknown"))
        }
        if booster.available == false {
            Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
        } else if booster.enabled == true, booster.syncAvailable == false {
            Text("TV audio synchronization is currently unavailable.").font(.caption).foregroundStyle(.secondary)
        }
        Text("Connect the TV to the speaker with an optical cable. Adjust their volumes separately.")
            .font(.caption).foregroundStyle(.secondary)
        if let exclusions = booster.exclusions {
            if exclusions.contains(.soundFieldOptimization) {
                Text("Sound Field Optimization is unavailable while TV Sound Booster is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if exclusions.contains(.stamina), exclusions.contains(.soundEffect) {
                Text("Changing TV Sound Booster can change STAMINA and sound effects.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if exclusions.contains(.stamina) {
                Text("Changing TV Sound Booster can change STAMINA.").font(.caption).foregroundStyle(.secondary)
            } else if exclusions.contains(.soundEffect) {
                Text("Changing TV Sound Booster can change sound effects.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = headphones.settingErrors[.tvSoundBooster] {
            Text(error).font(.caption)
        } else if headphones.pendingChanges[.tvSoundBooster] != nil {
            ProgressView().controlSize(.small)
        }
    }
}

private struct LEAudioPreferenceControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if headphones.supportsLEAudioStandby {
            if let enabled = headphones.leAudioStandby.enabled {
                Toggle("Allow LE Audio", isOn: Binding(get: { enabled }, set: headphones.setLEAudioStandby))
                    .disabled(!headphones.canSetLEAudioStandby)
                    .accessibilityIdentifier("leAudio.devicePreference")
            } else {
                LabeledContent("Allow LE Audio", value: String(localized: "Unknown"))
            }
            LEAudioPreferenceFeedback()
        }
        let capabilities = headphones.leAudioCapabilities
        if capabilities.supportsConnectionMode {
            LabeledContent("LE Audio connection mode", value: capabilities.mode?.title ?? String(localized: "Unknown"))
                .accessibilityIdentifier("leAudio.deviceConnectionMode")
            if let modes = capabilities.supportedModes, !modes.isEmpty {
                LabeledContent("Supported LE Audio modes", value: modes.map(\.title).formatted(.list(type: .and)))
            }
        }
        if capabilities.supportsSwitchCompatibility {
            LabeledContent("LE Audio switch compatibility",
                           value: capabilities.compatibilityVersion?.formatted() ?? String(localized: "Unknown"))
                .accessibilityIdentifier("leAudio.switchCompatibility")
        }
    }
}

private struct LEAudioPreferenceFeedback: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if headphones.pendingChanges[.leAudioStandby] != nil {
            ProgressView().controlSize(.mini).accessibilityLabel("Updating LE Audio preference")
        } else if let error = headphones.settingErrors[.leAudioStandby] {
            Text(error).foregroundStyle(.secondary)
        } else if headphones.leAudioStandby.available == false {
            Text("The device cannot change its LE Audio preference right now.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AuracastControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var passwordBroadcast: SonyAuracast.Broadcast?
    @State private var password = ""

    private var auracast: SonyAuracast { headphones.auracast }
    private var scanning: Bool { auracast.scan == .scanning }

    var body: some View {
        if auracast.variant == .requiresLEAudio && headphones.leAudioStandby.enabled != true {
            if headphones.supportsLEAudioStandby, headphones.leAudioStandby.enabled == false {
                Button("Enable LE Audio on Device") { headphones.setLEAudioStandby(true) }
                    .disabled(!headphones.canSetLEAudioStandby)
                    .accessibilityIdentifier("auracast.enableLEAudio")
                LEAudioPreferenceFeedback()
            } else {
                Text("Enable LE Audio on the device to use Auracast.")
                    .foregroundStyle(.secondary)
            }
        } else if auracast.available != true {
            Text(availabilityMessage)
                .foregroundStyle(.secondary)
        }
        if let broadcast = auracast.current {
            LabeledContent("Receiving broadcast") { broadcastLabel(broadcast) }
            Button("Leave Broadcast") { headphones.setAuracastReception(.stop, broadcastID: broadcast.id) }
                .disabled(!headphones.canSetAuracast)
                .accessibilityIdentifier("auracast.leave")
        }
        Button(scanning ? String(localized: "Stop Scanning") : String(localized: "Scan for Broadcasts")) {
            headphones.setAuracastScan(start: !scanning)
        }
        .disabled(!headphones.canSetAuracast)
        .accessibilityIdentifier("auracast.scan")
        .sheet(item: $passwordBroadcast, onDismiss: { password = "" }) { broadcast in
            VStack(alignment: .leading, spacing: 12) {
                broadcastLabel(broadcast)
                SecureField("Broadcast password", text: $password)
                    .accessibilityIdentifier("auracast.password")
                HStack {
                    Spacer()
                    Button("Cancel") { passwordBroadcast = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Join") {
                        headphones.setAuracastReception(.start, broadcastID: broadcast.id, password: password)
                        passwordBroadcast = nil
                    }
                    .disabled(!headphones.canSetAuracast || !SonyAuracast.validPassword(password))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 320)
        }
        if auracast.scan == .timedOut && auracast.broadcasts.isEmpty {
            Text("No broadcasts found.")
                .foregroundStyle(.secondary)
        }
        ForEach(auracast.broadcasts) { broadcast in
            if broadcast.id != auracast.current?.id {
                LabeledContent {
                    Button("Join") {
                        if broadcast.protection == .password {
                            password = ""
                            passwordBroadcast = broadcast
                        } else {
                            headphones.setAuracastReception(.start, broadcastID: broadcast.id)
                        }
                    }
                    .disabled(!headphones.canSetAuracast)
                    .accessibilityIdentifier("auracast.join")
                } label: {
                    broadcastLabel(broadcast)
                }
            }
        }
        if let error = headphones.settingErrors[.auracastScan] ?? headphones.settingErrors[.auracastReception] {
            Text(error)
                .foregroundStyle(.secondary)
        } else if headphones.pendingChanges[.auracastScan] != nil || headphones.pendingChanges[.auracastReception] != nil {
            ProgressView().controlSize(.mini).accessibilityLabel("Updating Auracast")
        }

    }

    private var availabilityMessage: LocalizedStringKey {
        if auracast.available == nil { return "Reading Auracast status…" }
        switch auracast.restriction {
        case .call: return "Unavailable during a call."
        case .partyChain: return "Unavailable while Party Chain is active."
        case .stereoPair: return "Unavailable while Stereo Pair is active."
        default: return "Auracast is unavailable."
        }
    }

    private func broadcastLabel(_ broadcast: SonyAuracast.Broadcast) -> some View {
        VStack(alignment: .leading) {
            Text(broadcast.name.isEmpty ? String(localized: "Unnamed broadcast") : broadcast.name)
            if !broadcast.program.isEmpty {
                Text(broadcast.program)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpeakerKaraokeControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var changes: [SonyKaraoke.Item: Int] = [:]

    private var karaoke: SonyKaraoke { headphones.karaoke }

    var body: some View {
        Group {
            if karaoke.micPlugged == false {
                Text("Connect a microphone to the speaker.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(Set(karaoke.disableReasons)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { reason in
                Text(reasonTitle(reason)).font(.caption).foregroundStyle(.secondary)
            }
            if karaoke.availability == .exceptVocal {
                Text("Vocal controls are currently unavailable.").font(.caption).foregroundStyle(.secondary)
            } else if karaoke.availability == .disabled, karaoke.disableReasons.isEmpty {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            if let items = karaoke.items {
                ForEach(items.filter { $0.range != nil }, id: \.self) { item in
                    if let value = karaoke.value(item), let range = item.range {
                        Picker(itemTitle(item), selection: Binding(
                            get: { changes[item] ?? value },
                            set: { changes[item] = $0 == value ? nil : $0 }
                        )) {
                            ForEach(range, id: \.self) { option in
                                optionTitle(item, value: option).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .disabled(!headphones.canSetKaraoke(.controls) || !karaoke.canAdjust(item))
                        .accessibilityIdentifier("karaoke.control.\(item.rawValue)")
                    } else {
                        LabeledContent(itemTitle(item), value: String(localized: "Unknown"))
                    }
                }
                if items.contains(where: { $0.range != nil }) {
                    Button("Apply Karaoke Settings") { headphones.setKaraokeControls(changes) }
                        .disabled(!headphones.canSetKaraoke(.controls) || karaoke.controlsPayload(changes) == nil)
                        .accessibilityIdentifier("karaoke.apply")
                    settingFeedback(.controls)
                }
                if items.contains(.sampler), !karaoke.samples.isEmpty {
                    ForEach(karaoke.samples, id: \.self) { sample in
                        Button(sampleTitle(sample)) { headphones.playKaraokeSample(sample) }
                            .disabled(!headphones.canPlayKaraokeSample(sample))
                            .accessibilityIdentifier("karaoke.sample.\(sample.rawValue)")
                    }
                }
                if items.contains(.scoring), let scoring = karaoke.scoring {
                    if let next = scoring.next {
                        Button {
                            headphones.setKaraokeScoring(next)
                        } label: {
                            if next == .started {
                                Text("Start Scoring")
                            } else {
                                Text("Finish Scoring")
                            }
                        }
                        .disabled(!headphones.canSetKaraoke(.scoring) || karaoke.scoringPayload(next) == nil)
                        .accessibilityIdentifier("karaoke.scoring")
                    } else if karaoke.score == nil {
                        LabeledContent("Scoring", value: "Waiting for the score")
                    }
                    if let score = karaoke.score {
                        LabeledContent("Last score", value: score.formatted())
                    }
                    settingFeedback(.scoring)
                }
            } else {
                LabeledContent("Karaoke controls", value: String(localized: "Unknown"))
            }
            if karaoke.supportsLive {
                if let enabled = karaoke.liveEnabled {
                    Toggle("Live Karaoke", isOn: Binding(get: { enabled }, set: headphones.setLiveKaraoke))
                        .disabled(!headphones.canSetKaraoke(.live) || karaoke.livePayload(!enabled) == nil)
                        .accessibilityIdentifier("karaoke.live")
                } else {
                    LabeledContent("Live Karaoke", value: String(localized: "Unknown"))
                }
                settingFeedback(.live)
            }
        }
        .onChange(of: karaoke.current(.controls)) { _, _ in changes = [:] }
    }

    @ViewBuilder
    private func settingFeedback(_ setting: SonyKaraoke.Setting) -> some View {
        if let error = headphones.settingErrors[.speakerKaraoke(setting)] {
            Text(error).font(.caption)
        } else if headphones.pendingChanges[.speakerKaraoke(setting)] != nil {
            ProgressView().controlSize(.mini).accessibilityLabel("Updating karaoke")
        }
    }

    private func itemTitle(_ item: SonyKaraoke.Item) -> LocalizedStringKey {
        switch item {
        case .echo: "Microphone echo"
        case .key: "Key shift"
        case .vocal: "Vocal setting"
        case .voiceChanger: "Voice changer"
        case .bass: "Bass"
        case .treble: "Treble"
        case .sampler: "Sampler"
        case .scoring: "Scoring"
        }
    }

    private func optionTitle(_ item: SonyKaraoke.Item, value: Int) -> Text {
        switch (item, value) {
        case (.vocal, 0), (.voiceChanger, 0), (.echo, 0): Text("Off")
        case (.vocal, 1): Text("Guide vocals")
        case (.vocal, 2): Text("Vocal fader")
        case (.voiceChanger, 1): Text("Double tracking")
        case (.voiceChanger, 2): Text("Munchkin")
        case (.voiceChanger, 3): Text("Mouse")
        case (.voiceChanger, 4): Text("Radio")
        case (.key, let key) where key > 0: Text(verbatim: "+" + key.formatted())
        default: Text(value.formatted())
        }
    }

    private func sampleTitle(_ sample: SonyKaraoke.Sample) -> LocalizedStringKey {
        switch sample {
        case .clap: "Play handclap"
        case .letsGo: "Play Let’s Go"
        case .reggaeHorn: "Play reggae horn"
        case .comeOn: "Play Come On"
        }
    }

    private func reasonTitle(_ reason: SonyKaraoke.DisableReason) -> LocalizedStringKey {
        switch reason {
        case .tvSoundBooster: "TV Sound Booster is active."
        case .demoMode: "Demo Mode is active."
        case .speaking: "Voice activity is active."
        }
    }
}

private struct SpeakerDJControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var bands: [UInt8]?
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var effectHeld = false
    @GestureState private var pointerDown = false

    private var dj: SonyDJControl { headphones.djControl }
    private var effectsAvailable: Bool { headphones.canSetDJControl && dj.available == true }

    var body: some View {
        Group {
            if let advertised = dj.options, let current = dj.effect {
                let options = advertised.reduce(into: [SonyDJControl.Effect.off]) { options, item in
                    if !options.contains(item) { options.append(item) }
                }
                Picker("DJ Effect", selection: Binding(
                    get: { current },
                    set: { headphones.setDJEffect($0) }
                )) {
                    if !options.contains(current) { Text(effectTitle(current)).tag(current).disabled(true) }
                    ForEach(options, id: \.self) { item in
                        Text(effectTitle(item)).tag(item).disabled(dj.setPayload(effect: item) == nil)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .disabled(!headphones.canSetDJControl || !options.contains(where: { dj.setPayload(effect: $0) != nil }))
                .accessibilityIdentifier("dj.effect")
                if current.usesTouchPad {
                    effectPad
                    Slider(value: $x, in: -100...100, step: 1) { Text("Horizontal Effect Position") }
                        .onChange(of: x) { _, _ in if effectHeld { sendEffectPosition() } }
                    Slider(value: $y, in: -100...100, step: 1) { Text("Vertical Effect Position") }
                        .onChange(of: y) { _, _ in if effectHeld { sendEffectPosition() } }
                    Button {
                        effectHeld.toggle()
                        if effectHeld { sendEffectPosition() }
                        else { headphones.finishDJControlDrag() }
                    } label: {
                        if effectHeld { Text("End Effect") }
                        else { Text("Start Effect") }
                    }
                    .disabled(!effectsAvailable)
                } else if !current.samplePositions.isEmpty {
                    ForEach(current.samplePositions.indices, id: \.self) { index in
                        Button("Play Sample \(index + 1)") { headphones.playDJControlSample(index) }
                            .disabled(!effectsAvailable)
                            .accessibilityIdentifier("dj.sample.\(index)")
                    }
                } else if current == .customEQ, let reported = dj.bands,
                          reported.count == dj.bandCount.map(Int.init), let limit = dj.bandStep, limit > 0,
                          reported.allSatisfy({ $0 <= limit }) {
                    ForEach(reported.indices, id: \.self) { index in
                        Slider(value: Binding(
                            get: { Double((bands ?? reported)[index]) },
                            set: { level in
                                var draft = bands ?? reported
                                draft[index] = UInt8(level)
                                bands = draft
                            }
                        ), in: 0...Double(limit), step: 1) {
                            Text("Band \(index + 1)")
                        }
                        .disabled(!headphones.canSetDJControl || dj.equalizerAvailable != true)
                    }
                    Button("Apply DJ Equalizer") {
                        if let bands { headphones.setDJEffect(.customEQ, bands: bands) }
                    }
                    .disabled(!headphones.canSetDJControl || dj.equalizerAvailable != true || bands == nil || bands == reported)
                    .accessibilityIdentifier("dj.applyEqualizer")
                }
            } else {
                LabeledContent("DJ Effect", value: String(localized: "Unknown"))
            }
            if let error = headphones.settingErrors[.speakerDJ] {
                Text(error).font(.caption)
            } else if headphones.pendingChanges[.speakerDJ] != nil {
                ProgressView().controlSize(.mini).accessibilityLabel("Updating DJ Control")
            } else if dj.available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(dj.disableReasons, id: \.self) { reason in
                Text(reasonTitle(reason)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: dj.effect) { _, _ in
            effectHeld = false
            bands = nil
        }
        .onChange(of: dj.bands) { _, _ in bands = nil }
        .onChange(of: dj.available) { _, available in
            if available != true { effectHeld = false }
        }
        .onDisappear { headphones.finishDJControlDrag() }
    }

    private var effectPad: some View {
        GeometryReader { geometry in
            let size = geometry.size
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay(alignment: .topLeading) {
                    Circle().fill(.primary)
                        .frame(width: 10, height: 10)
                        .position(x: (1 - x / 100) * size.width / 2, y: (1 - y / 100) * size.height / 2)
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($pointerDown) { _, down, _ in down = true }
                    .onChanged { moveEffect($0.location, size: size) }
                    .onEnded {
                        moveEffect($0.location, size: size)
                        headphones.finishDJControlDrag()
                    })
        }
        .frame(height: 72)
        .disabled(!effectsAvailable || effectHeld)
        .accessibilityHidden(true)
        .onChange(of: pointerDown) { _, down in
            if !down {
                Task { @MainActor in
                    await Task.yield()
                    if !pointerDown { headphones.finishDJControlDrag() }
                }
            }
        }
    }

    private func moveEffect(_ point: CGPoint, size: CGSize) {
        x = min(max(((1 - 2 * point.x / size.width) * 100).rounded(), -100), 100)
        y = min(max(((1 - 2 * point.y / size.height) * 100).rounded(), -100), 100)
        sendEffectPosition()
    }

    private func sendEffectPosition() {
        headphones.updateDJControlDrag(x: Int(x), y: Int(y))
    }

    private func effectTitle(_ item: SonyDJControl.Effect) -> LocalizedStringKey {
        switch item {
        case .off: "Off"
        case .isolator: "Isolator"
        case .flanger: "Flanger"
        case .drums: "Drums"
        case .audience: "Audience"
        case .phaser: "Phaser"
        case .rhythm: "Rhythm"
        case .scratch: "Scratch"
        case .voice: "Voice"
        case .reggaeHorn: "Reggae Horn"
        case .robot: "Robot"
        case .customEQ: "Custom EQ"
        case .drumRoll: "Drum Roll"
        case .explosion: "Explosion"
        case .clap: "Clap"
        case .sevenDrums: "Seven Drum Sounds"
        }
    }

    private func reasonTitle(_ reason: SonyDJControl.DisableReason) -> LocalizedStringKey {
        switch reason {
        case .tvSoundBooster: "TV Sound Booster is active."
        case .demoMode: "Demo Mode is active."
        case .speaking: "Voice activity is active."
        }
    }
}

private struct SpeakerLightingControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var defaultColorDraft: Color?
    @State private var partyColorDraft = Color.white
    @State private var partyPosition = 0.0
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var presentedRequestID: UUID?
    @State private var showsAlert = false

    private var lighting: SonySpeakerLighting { headphones.speakerLighting }

    var body: some View {
        Group {
            if lighting.supportsMode {
                lightingPicker("Lighting Mode", parameter: .mode, current: lighting.mode,
                               options: lighting.modeOptions ?? [], title: modeTitle)
                    .accessibilityIdentifier("lighting.mode")
                if lighting.modeAvailable == false { unavailable }
            }
            if lighting.supportsDefaultColor {
                lightingPicker("Default Color", parameter: .colorType, current: lighting.colorType,
                               options: lighting.colorOptions ?? [], title: colorTitle)
                    .accessibilityIdentifier("lighting.defaultColor")
                if lighting.colorType == .customColor {
                    if let color = lighting.customColor {
                        SpeakerLightingColorPad(adjustsEffect: false, move: { point in
                            let color = lightingColor(at: point, adjustsEffect: false)
                            defaultColorDraft = color
                            if let rgb = rgb(color) { headphones.previewSpeakerLightingColor(rgb) }
                        }, finish: { point in
                            let color = lightingColor(at: point, adjustsEffect: false)
                            defaultColorDraft = color
                            if let rgb = rgb(color) { headphones.setSpeakerLighting(.customColor, value: rgb.bytes) }
                        }, cancel: headphones.cancelSpeakerLightingColorPreview)
                        .disabled(!headphones.canSetSpeakerLighting(.customColor))
                        ColorPicker("Custom Color", selection: Binding(
                            get: { defaultColorDraft ?? Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255) },
                            set: {
                                defaultColorDraft = $0
                                if let color = rgb($0) { headphones.previewSpeakerLightingColor(color) }
                            }
                        ), supportsOpacity: false)
                        Button("Apply Custom Color") {
                            if let draft = defaultColorDraft.flatMap(rgb) {
                                headphones.setSpeakerLighting(.customColor, value: draft.bytes)
                            }
                        }
                        .disabled(!headphones.canSetSpeakerLighting(.customColor) || defaultColorDraft.flatMap(rgb) == nil)
                        .accessibilityIdentifier("lighting.applyDefaultColor")
                    } else {
                        LabeledContent("Custom Color", value: String(localized: "Unknown"))
                    }
                    settingStatus(.customColor)
                }
            }
            if lighting.supportsParty {
                lightingPicker("Party Illumination", parameter: .party, current: lighting.partyItem,
                               options: lighting.partyOptions?.map(\.item) ?? [], title: partyTitle)
                    .accessibilityIdentifier("lighting.partyItem")
                if lighting.partyAvailable == false { unavailable }
                if let palette = lighting.currentPartyPalette {
                    SpeakerLightingColorPad(adjustsEffect: palette == 1, move: {
                        updatePartyColorPad($0, adjustsEffect: palette == 1)
                    }, finish: {
                        updatePartyColorPad($0, adjustsEffect: palette == 1)
                        headphones.finishPartyLightingDrag()
                    }, cancel: headphones.finishPartyLightingDrag)
                    .id(lighting.partyItem)
                    .disabled(!headphones.canSetSpeakerLighting(.party))
                    ColorPicker("Party Color", selection: $partyColorDraft, supportsOpacity: false)
                    if palette == 1 {
                        Slider(value: $partyPosition, in: -100...100, step: 1) { Text("Effect Position") }
                    }
                    Button("Apply Party Color") {
                        if let color = rgb(partyColorDraft) {
                            headphones.setPartyLightingColor(color, x: 0, y: Int(partyPosition))
                        }
                    }
                    .disabled(!headphones.canSetSpeakerLighting(.party) || rgb(partyColorDraft) == nil)
                    .accessibilityIdentifier("lighting.applyPartyColor")
                    Button("Reset Party Illumination") {
                        headphones.setSpeakerLighting(.party, value: [SonySpeakerLighting.PartyItem.reset.rawValue])
                    }
                    .disabled(!headphones.canSetSpeakerLighting(.party))
                    .accessibilityIdentifier("lighting.resetParty")
                }
            }
        }
        .onChange(of: lighting.customColor) { _, _ in defaultColorDraft = nil }
        .onChange(of: lighting.partyItem) { _, _ in
            headphones.finishPartyLightingDrag()
            partyPosition = 0
        }
        .onChange(of: lighting.colorType) { _, _ in
            defaultColorDraft = nil
            headphones.cancelSpeakerLightingColorPreview()
        }
        .onDisappear {
            headphones.finishPartyLightingDrag()
            headphones.cancelSpeakerLightingColorPreview()
        }
        .onChange(of: headphones.lightingModeAlert, initial: true) { _, alert in
            presentedAlert = alert
            presentedRequestID = headphones.lightingModeAlertRequestID
            showsAlert = alert != nil
        }
        .alert("Turn On Lighting?", isPresented: $showsAlert, presenting: presentedAlert) { alert in
            if alert.availableActions.contains(.negative) {
                Button("Cancel", role: .cancel) {
                    headphones.respondToLightingModeAlert(alert, action: .negative, requestID: presentedRequestID)
                }
            }
            Button("Turn On") {
                headphones.respondToLightingModeAlert(alert, action: .positive, requestID: presentedRequestID)
            }
        } message: { _ in
            Text("Turning on lighting disables STAMINA.")
        }
    }

    private var unavailable: some View {
        Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
    }

    private func lightingColor(at point: CGPoint, adjustsEffect: Bool) -> Color {
        Color(hue: point.x, saturation: adjustsEffect ? 1 : 1 - point.y, brightness: 1)
    }

    private func updatePartyColorPad(_ point: CGPoint, adjustsEffect: Bool) {
        let color = lightingColor(at: point, adjustsEffect: adjustsEffect)
        partyColorDraft = color
        let x = Int(((1 - 2 * point.x) * 100).rounded())
        let y = Int(((1 - 2 * point.y) * 100).rounded())
        if adjustsEffect { partyPosition = Double(y) }
        if let rgb = rgb(color) {
            headphones.updatePartyLightingDrag(rgb, x: x, y: y)
        }
    }

    private func lightingPicker<Option: RawRepresentable & Hashable>(_ label: LocalizedStringKey,
                 parameter: SonySpeakerLighting.Parameter, current: Option?, options: [Option],
                 title: @escaping (Option) -> LocalizedStringKey) -> some View where Option.RawValue == UInt8 {
        var seen: Set<Option> = []
        let distinctOptions = options.filter { seen.insert($0).inserted }
        return VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: Binding(
                get: { current },
                set: { if let option = $0 { headphones.setSpeakerLighting(parameter, value: [option.rawValue]) } }
            )) {
                if !options.contains(where: { $0 == current }) {
                    Text(current.map(title) ?? "Unknown").tag(current).disabled(true)
                }
                ForEach(distinctOptions, id: \.self) { option in
                    Text(title(option)).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .tint(.primary)
            .disabled(!headphones.canSetSpeakerLighting(parameter)
                      || !options.contains(where: { lighting.setPayload(parameter, value: [$0.rawValue]) != nil }))
            settingStatus(parameter)
        }
    }

    @ViewBuilder
    private func settingStatus(_ parameter: SonySpeakerLighting.Parameter) -> some View {
        if let error = headphones.settingErrors[.speakerLighting(parameter)] {
            Text(error).font(.caption)
        } else if headphones.pendingChanges[.speakerLighting(parameter)] != nil {
            ProgressView().controlSize(.mini).accessibilityLabel("Updating lighting")
        }
    }

    private func rgb(_ color: Color) -> SonySpeakerLighting.RGB? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let bytes = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            UInt8((255 * min(max($0, 0), 1)).rounded())
        }
        return SonySpeakerLighting.RGB(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    private func partyTitle(_ item: SonySpeakerLighting.PartyItem) -> LocalizedStringKey {
        switch item {
        case .reset: "Reset"
        case .flash: "Party Flash"
        case .customColor: "Custom Color"
        }
    }

    private func modeTitle(_ mode: SonySpeakerLighting.Mode) -> LocalizedStringKey {
        switch mode {
        case .off: "Off"
        case .delightful: "Delightful"
        case .rave: "Rave"
        case .chill: "Chill"
        case .strobe: "Strobe"
        case .gradation: "Gradation"
        case .allFlashing: "Party All Flashing"
        case .random: "Party Random"
        case .circle: "Party Circle"
        case .beat: "Beat"
        case .wave: "Wave"
        case .mellow: "Mellow"
        case .hot: "Hot"
        case .cool: "Cool"
        case .cute: "Cute"
        case .fresh: "Fresh"
        case .calmDaylight: "Calm Daylight"
        }
    }

    private func colorTitle(_ color: SonySpeakerLighting.ColorType) -> LocalizedStringKey {
        switch color {
        case .multicolor: "Multicolor"
        case .white: "White"
        case .customColor: "Custom Color"
        }
    }
}

private struct SpeakerLightingColorPad: View {
    let adjustsEffect: Bool
    let move: (CGPoint) -> Void
    let finish: (CGPoint) -> Void
    let cancel: () -> Void
    @State private var selectedPoint: CGPoint?
    @GestureState private var pointerDown = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let hues = (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: hues, startPoint: .leading, endPoint: .trailing))
                .overlay {
                    if !adjustsEffect {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let point = selectedPoint {
                        Circle().strokeBorder(.white, lineWidth: 2)
                            .background { Circle().strokeBorder(.black.opacity(0.65), lineWidth: 4).padding(-1) }
                            .frame(width: 14, height: 14)
                            .position(x: point.x * size.width, y: point.y * size.height)
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($pointerDown) { _, down, _ in down = true }
                    .onChanged {
                        let point = normalizedPoint($0.location, size: size)
                        selectedPoint = point
                        move(point)
                    }
                    .onEnded {
                        let point = normalizedPoint($0.location, size: size)
                        selectedPoint = point
                        finish(point)
                    })
        }
        .frame(height: 80)
        .accessibilityHidden(true)
        .onChange(of: pointerDown) { _, down in
            if !down {
                Task { @MainActor in
                    await Task.yield()
                    if !pointerDown { cancel() }
                }
            }
        }
    }

    private func normalizedPoint(_ location: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(location.x / size.width, 0), 1), y: min(max(location.y / size.height, 0), 1))
    }
}

private struct SpeakerPowerControls: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var presentedRequestID: UUID?
    @State private var showsAlert = false

    var body: some View {
        Group {
            if let state = headphones.powerFeatures.powerSavingMode {
                powerSwitch("Power Saving", enabled: state.enabled, available: state.available,
                            setting: .powerSavingMode, canSet: headphones.canSetPowerSavingMode,
                            identifier: "power.powerSavingMode", set: headphones.setPowerSavingMode)
            }
            if let state = headphones.powerFeatures.bluetoothStandby {
                powerSwitch("Bluetooth Standby", enabled: state.enabled, available: state.available,
                            setting: .bluetoothStandby, canSet: headphones.canSetBluetoothStandby,
                            identifier: "power.bluetoothStandby", set: headphones.setBluetoothStandby)
            }
            if let state = headphones.powerFeatures.autoStandby {
                VStack(alignment: .leading, spacing: 6) {
                    powerSwitch("Automatic Standby", enabled: state.enabled, available: state.available,
                                setting: .autoStandby, canSet: headphones.canSetAutoStandby,
                                identifier: "power.autoStandby", set: headphones.setAutoStandby)
                    if state.candidate == 0 {
                        LabeledContent("Standby delay", value: String(localized: "15 minutes")).font(.caption)
                    }
                }
            }
        }
        .onChange(of: headphones.bluetoothStandbyAlert, initial: true) { _, alert in
            presentedAlert = alert
            presentedRequestID = headphones.bluetoothStandbyAlertRequestID
            showsAlert = alert != nil
        }
        .alert("Bluetooth Standby", isPresented: $showsAlert, presenting: presentedAlert) { alert in
            if alert.availableActions.contains(.negative) {
                Button("Cancel", role: .cancel) { headphones.respondToBluetoothStandbyAlert(alert, action: .negative, requestID: presentedRequestID) }
            }
            if alert.availableActions.contains(.positive) {
                Button("Continue") { headphones.respondToBluetoothStandbyAlert(alert, action: .positive, requestID: presentedRequestID) }
            } else if alert.actionType == .confirmationOnly {
                Button("OK") { headphones.respondToBluetoothStandbyAlert(alert, action: nil, requestID: presentedRequestID) }
            }
        } message: { alert in
            Text(alertMessage(alert))
        }
    }

    private func powerSwitch(_ title: LocalizedStringKey, enabled: Bool?, available: Bool?,
                             setting: SonyHeadphonesController.Setting, canSet: Bool,
                             identifier: String, set: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let enabled {
                Toggle(isOn: Binding(get: { enabled }, set: set)) {
                    HStack {
                        Text(title)
                        if headphones.pendingChanges[setting] != nil {
                            ProgressView().controlSize(.mini).accessibilityLabel("Updating power setting")
                        }
                    }
                }
                .disabled(!canSet)
                .accessibilityIdentifier(identifier)
            } else {
                LabeledContent(title, value: String(localized: "Unknown"))
            }
            if let error = headphones.settingErrors[setting] {
                Text(error).font(.caption)
            } else if available == false {
                Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        var message = String(localized: "Turning off Bluetooth Standby disables some features.")
        let known = alert.affectedFeatures.filter { $0.title != String(localized: "Unknown feature") }.map(\.title)
        if !known.isEmpty {
            message += String(localized: "\n\nUnavailable with this change: ") + known.joined(separator: ", ") + "."
        }
        if known.count != alert.affectedFeatures.count {
            message += String(localized: "\n\nThe headphones also report an affected feature this app cannot identify.")
        }
        return message
    }
}

private struct StaminaControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var requestedEnabled: Bool?
    @State private var requestedSession: UInt64 = 0

    var body: some View {
        if let state = headphones.powerFeatures.stamina {
            VStack(alignment: .leading, spacing: 6) {
                if let enabled = state.enabled {
                    Toggle(isOn: Binding(get: { enabled }, set: {
                        requestedSession = headphones.preferencePaneSession
                        requestedEnabled = $0
                    })) {
                        HStack {
                            Text("STAMINA")
                            if headphones.pendingChanges[.stamina] != nil {
                                ProgressView().controlSize(.mini).accessibilityLabel("Updating STAMINA")
                            }
                        }
                    }
                    .disabled(!headphones.canSetStamina)
                    .accessibilityIdentifier("power.stamina")
                } else {
                    LabeledContent("STAMINA", value: String(localized: "Unknown"))
                }
                Text("Reduces power use by changing sound effects and, on supported speakers, lighting.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = headphones.settingErrors[.stamina] {
                    Text(error).font(.caption)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .alert("Change STAMINA?", isPresented: Binding(
                get: { requestedEnabled != nil }, set: { if !$0 { requestedEnabled = nil } }
            ), presenting: requestedEnabled) { enabled in
                Button("Cancel", role: .cancel) {}
                Button("Continue") { headphones.setStamina(enabled, session: requestedSession) }
            } message: { _ in
                Text("Turning STAMINA on or off changes sound effects and may change lighting. Continue?")
            }
            .onChange(of: headphones.preferencePaneSession) { _, _ in requestedEnabled = nil }
        }
    }
}

private struct TouchPanelBacklightControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.touchPanelBacklight {
            VStack(alignment: .leading, spacing: 6) {
                if let enabled = state.enabled {
                    Toggle(isOn: Binding(
                        get: { enabled }, set: { headphones.setTouchPanelBacklight($0) }
                    )) {
                        HStack {
                            Text("Turn off touch-panel backlight when idle")
                            if headphones.pendingChanges[.touchPanelBacklight] != nil {
                                ProgressView().controlSize(.mini).accessibilityLabel("Updating touch-panel backlight")
                            }
                        }
                    }
                    .disabled(!headphones.canSetTouchPanelBacklight)
                    .accessibilityIdentifier("power.touchPanelBacklight")
                } else {
                    LabeledContent("Turn off touch-panel backlight when idle", value: String(localized: "Unknown"))
                }
                Text("Reduces power use by turning off the top touch-panel backlight after inactivity.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = headphones.settingErrors[.touchPanelBacklight] {
                    Text(error).font(.caption)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AutoPowerSaveControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.powerFeatures.autoPowerSave {
            let pending = headphones.pendingChanges[.autoPowerSave] != nil || headphones.pendingChanges[.powerSaveEffect] != nil
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled }, set: { headphones.setAutoPowerSave($0) }
                        )) {
                            HStack {
                                Text("Auto Power Save")
                                if pending {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Updating power saving")
                                }
                            }
                        }
                        .disabled(!headphones.canSetAutoPowerSave)
                        .accessibilityIdentifier("power.autoPowerSave")
                    } else {
                        LabeledContent("Auto Power Save", value: String(localized: "Unknown"))
                    }
                }
                if let threshold = state.threshold {
                    Text("Activates at \(threshold)% battery.").font(.caption)
                }
                if state.effectActive == true {
                    Text("Power saving is active.").font(.caption)
                    Button("Turn Off Power Saving for Now") { headphones.cancelPowerSaveEffect() }
                        .disabled(!headphones.canCancelPowerSaveEffect)
                        .accessibilityIdentifier("power.cancelEffect")
                        .help("Auto Power Save remains on.")
                }
                if let error = headphones.settingErrors[.autoPowerSave] ?? headphones.settingErrors[.powerSaveEffect] {
                    Text(error).font(.caption)
                }
            }
        }
    }
}

private struct SidetoneControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        if let state = headphones.systemFeatures.sidetone {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let enabled = state.enabled {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { headphones.setSidetone($0) }
                        )) {
                            HStack {
                                Text("Hear your voice during calls")
                                if headphones.pendingChanges[.sidetone] != nil {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Updating own voice during calls")
                                }
                            }
                        }
                        .disabled(!headphones.canSetSidetone)
                        .accessibilityIdentifier("system.sidetone")
                    } else {
                        LabeledContent("Hear your voice during calls") {
                            Text("Unknown").foregroundStyle(.primary)
                        }
                    }
                }
                if let error = headphones.settingErrors[.sidetone] {
                    Text(error).font(.caption).foregroundStyle(.primary)
                } else if state.available == false {
                    Text("Currently unavailable.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
struct MultipointSourceSelection: DynamicProperty {
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    #endif

    func callAsFunction(_ device: SonyMultipointDevice, on headphones: SonyHeadphonesController) {
        #if !ACOUPLET_PUBLIC_APIS_ONLY
        ldac.selectAudioSource(device, on: headphones)
        #else
        headphones.selectAudioSource(device)
        #endif
    }
}

struct MultipointControls: View {
    var compact = false
    let selectSource: @MainActor (SonyMultipointDevice) -> Void
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = headphones.multipoint
        VStack(alignment: .leading, spacing: 10) {
            if !state.devices.isEmpty {
                deviceGroup("Connected", devices: state.devices.filter(\.isConnected))
                if state.devices.contains(where: \.isConnected), state.devices.contains(where: { !$0.isConnected }) {
                    Divider()
                }
                deviceGroup("Saved", devices: state.devices.filter { !$0.isConnected })
            }
            if state.supportsSourceControl, let keeping = state.keeping {
                if !state.devices.isEmpty { Divider() }
                Toggle(isOn: Binding(get: { keeping }, set: headphones.setSourceKeeping)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep current audio source")
                        Text("Don’t switch when another device starts playing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .disabled(headphones.sourceControlUnavailableReason != nil || (!keeping && state.selectedSource == nil))
                .accessibilityIdentifier("multipoint.keeping")
                .help("Prevents automatic switching to another connected device. Choosing another device turns this off.")
            }
            if let message = headphones.sourceTransition?.failureMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("multipoint.error")
            }
            if let message = headphones.deviceActionTransition?.failureMessage {
                Text(message).font(.caption)
                    .accessibilityIdentifier("multipoint.deviceError")
            } else if state.supportsInventory, let reason = headphones.leAudioUnavailableReason(.pairedDevices) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if state.supportsLegacyInventory, let pairingMode = state.pairingMode {
                HStack {
                    Button(pairingMode ? String(localized: "Stop Pairing") : String(localized: "Pair New Device")) {
                        headphones.setLegacyPairingMode(!pairingMode)
                    }
                    .headphoneButtonStyle()
                    .tint(nil)
                    .controlSize(.small)
                    .disabled(!headphones.canSetLegacyPairingMode)
                    .accessibilityIdentifier("multipoint.pairingMode")
                    if headphones.legacyPairingModeRequest != nil {
                        ProgressView().controlSize(.mini)
                    }
                }
                if pairingMode {
                    Text("Select the headphones in the new device’s Bluetooth settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = headphones.legacyPairingModeError {
                    Text(error).font(.caption)
                }
            }
            if state.inventoryIsStale {
                Label("The device list could not be read. Refresh to try again.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if !compact {
                Divider()
                Button("Refresh Devices") { headphones.refreshDevices() }
                    .headphoneButtonStyle()
                    .tint(nil)
                    .controlSize(.small)
                    .disabled(!headphones.canRefreshDevices)
                    .accessibilityIdentifier("multipoint.refresh")
            }
        }
    }

    static func isVisible(for state: SonyMultipoint) -> Bool {
        state.supportsLegacyInventory || !state.devices.isEmpty || (state.supportsSourceControl && state.keeping != nil)
    }

    @ViewBuilder
    private func deviceGroup(_ title: LocalizedStringKey, devices: [SonyMultipointDevice]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                ForEach(devices) { device in
                    MultipointDeviceRow(device: device, selectSource: selectSource)
                }
            }
        }
    }

    static func title(for device: SonyMultipointDevice, among devices: [SonyMultipointDevice]) -> String {
        devices.filter { $0.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame }.count > 1
            ? "\(device.name) · \(device.address)" : device.name
    }
}

private struct MultipointDeviceRow: View {
    let device: SonyMultipointDevice
    let selectSource: @MainActor (SonyMultipointDevice) -> Void
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var hovered = false
    @State private var confirmsForget = false
    @FocusState private var sourceFocused: Bool
    @FocusState private var actionFocused: Bool
    @FocusState private var forgetFocused: Bool

    private var title: String { MultipointControls.title(for: device, among: headphones.multipoint.devices) }
    private var selected: Bool {
        !headphones.multipoint.inventoryIsStale && headphones.multipoint.selectedSource?.id == device.id
    }
    private var status: String {
        selected ? String(localized: "Selected for audio") : device.isConnected ? String(localized: "Connected") : String(localized: "Saved")
    }
    private var pendingAction: SonyPeripheralAction? {
        guard let transition = headphones.deviceActionTransition, !transition.isFinished,
              transition.targetAddress == device.id else { return nil }
        return transition.action
    }
    private var showsAction: Bool { hovered || sourceFocused || actionFocused || forgetFocused || voiceOverEnabled || pendingAction != nil }
    private var progressLabel: String? {
        if let pendingAction {
            return switch pendingAction {
            case .connect: String(localized: "Connecting device…")
            case .disconnect: String(localized: "Disconnecting device…")
            case .unpair: String(localized: "Forgetting device…")
            }
        }
        if let transition = headphones.sourceTransition, !transition.isFinished,
           (transition.targetAddress ?? headphones.multipoint.selectedSource?.id) == device.id {
            return String(localized: "Changing audio source…")
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if device.isConnected, headphones.multipoint.supportsSourceControl {
                Button { selectSource(device) } label: { deviceLabel }
                    .buttonStyle(.plain)
                    .focused($sourceFocused)
                    .focusEffectDisabled()
                    .disabled(headphones.sourceControlUnavailableReason != nil)
                    .help(headphones.sourceControlUnavailableReason ?? title)
                    .accessibilityLabel("Use \(title) for Audio")
                    .accessibilityValue(progressLabel ?? status)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("multipoint.select.\(device.id)")
            } else {
                deviceLabel
                    .focusable(headphones.multipoint.deviceInventoryInquiryType != nil)
                    .focused($sourceFocused)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(progressLabel ?? status)
            }
            if headphones.multipoint.deviceInventoryInquiryType != nil {
                let action: SonyPeripheralAction = device.isConnected ? .disconnect : .connect
                let reason = headphones.deviceActionUnavailableReason(action, device: device)
                Button {
                    headphones.changeDeviceConnection(action, device: device)
                } label: {
                    Text(action == .disconnect ? String(localized: "Disconnect") : String(localized: "Connect"))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 6))
                .tint(nil)
                .controlSize(.small)
                .focused($actionFocused)
                .disabled(reason != nil)
                .help(reason ?? (device.isConnected ? String(localized: "Disconnect this device from the headphones") : String(localized: "Connect this device to the headphones")))
                .accessibilityLabel("\(action == .disconnect ? String(localized: "Disconnect") : String(localized: "Connect")) \(title)")
                .accessibilityIdentifier("multipoint.\(action == .disconnect ? "disconnect" : "connect").\(device.id)")
                .accessibilityHidden(pendingAction != nil)
                .opacity(showsAction && pendingAction == nil ? 1 : 0)
                .fixedSize()
                .overlay {
                    if pendingAction != nil, let progressLabel {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(progressLabel)
                            .accessibilityIdentifier("multipoint.progress.\(device.id)")
                    }
                }
            }
            if headphones.multipoint.supportsLegacyInventory, !device.isConnected {
                let reason = headphones.deviceActionUnavailableReason(.unpair, device: device)
                Button("Forget…") { confirmsForget = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 6))
                    .tint(nil)
                    .controlSize(.small)
                    .focused($forgetFocused)
                    .disabled(reason != nil)
                    .help(reason ?? String(localized: "Forget this device from the headphones"))
                    .accessibilityIdentifier("multipoint.forget.\(device.id)")
                    .accessibilityHidden(pendingAction != nil)
                    .opacity(showsAction && pendingAction == nil ? 1 : 0)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(showsAction ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, -8)
        .onHover { hovered = $0 }
        .alert("Forget Device?", isPresented: $confirmsForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { headphones.changeDeviceConnection(.unpair, device: device) }
        } message: {
            Text("You’ll need to pair \(title) again to connect it to the headphones.")
        }
        .onChange(of: headphones.preferencePaneSession) { _, _ in confirmsForget = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multipoint.row.\(device.id)")
    }

    private var deviceLabel: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.1))
                if pendingAction == nil, progressLabel != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: device.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(device.isConnected ? .primary : .secondary)
            if selected {
                Image(systemName: "checkmark").accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(title)
    }
}

struct MultipointSourcePicker: View {
    var displayedMultipoint: SonyMultipoint? = nil
    let selectSource: @MainActor (SonyMultipointDevice) -> Void
    @EnvironmentObject private var headphones: SonyHeadphonesController

    var body: some View {
        let state = displayedMultipoint ?? headphones.multipoint
        let connected = state.devices.filter(\.isConnected)
        let selectedID = state.inventoryIsStale ? nil : state.selectedSource?.id
        if state.supportsSourceControl, connected.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(connected) { device in
                        let selected = selectedID == device.id
                        Button { selectSource(device) } label: {
                            Text(Self.title(for: device, among: connected))
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : Color.primary)
                        }
                        .headphoneButtonStyle(prominent: selected)
                        .tint(selected ? .primary : nil)
                        .help(headphones.sourceControlUnavailableReason ?? MultipointControls.title(for: device, among: state.devices))
                        .accessibilityLabel(MultipointControls.title(for: device, among: state.devices))
                        .accessibilityValue(selected ? String(localized: "Selected for audio") : String(localized: "Not selected"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("multipoint.sourcePicker.\(device.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Multipoint")
                .accessibilityIdentifier("multipoint.sourcePicker")
                if selectedID == nil {
                    Text("Not reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.regular)
            .tint(nil)
            .disabled(headphones.sourceControlUnavailableReason != nil)
            .help(headphones.sourceControlUnavailableReason ?? String(localized: "Multipoint"))
        }
    }

    static func title(for device: SonyMultipointDevice, among devices: [SonyMultipointDevice]) -> String {
        let matching = devices.filter { $0.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame }
        guard matching.count > 1 else { return device.name }
        let suffix = String(device.address.suffix(5))
        let identifier = matching.filter { $0.address.hasSuffix(suffix) }.count > 1 ? device.address : suffix
        return "\(device.name) · \(identifier)"
    }
}

struct MultipointSettingControl: View {
    var compact = false
    @EnvironmentObject private var headphones: SonyHeadphonesController
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @EnvironmentObject private var ldac: LDACController
    #endif
    @State private var presentedAlert: SonyConnectionAlert?
    @State private var showsAlert = false
    @State private var presentedSoundQualityWarning = false

    var body: some View {
        let enabled = Self.enabled(for: headphones)
        if compact || enabled != nil {
            VStack(alignment: .leading, spacing: 6) {
                if compact {
                    HStack(spacing: 12) {
                        Text("Multipoint").font(.headline).fontWeight(.semibold)
                        Spacer()
                        Button { headphones.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .tint(nil)
                            .foregroundStyle(.secondary)
                            .disabled(!headphones.canRefreshDevices)
                            .accessibilityLabel("Refresh Devices")
                            .accessibilityIdentifier("multipoint.refresh")
                            .help("Refresh Devices")
                            .frame(width: 16, height: 16)
                        if let enabled {
                            Toggle("Multipoint", isOn: Binding(get: { enabled }, set: headphones.setMultipointEnabled))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(headphones.multipointUnavailableReason != nil)
                                .help(headphones.multipointUnavailableReason ?? "")
                                .accessibilityIdentifier("multipoint.enabled")
                        }
                    }
                } else if let enabled {
                    Toggle("Multipoint", isOn: Binding(get: { enabled }, set: headphones.setMultipointEnabled))
                        .disabled(headphones.multipointUnavailableReason != nil)
                        .help(headphones.multipointUnavailableReason ?? "")
                        .accessibilityIdentifier("multipoint.enabled")
                }
                if let transition = headphones.multipointTransition {
                    if let failure = transition.failureMessage {
                        HStack(spacing: 10) {
                            ConnectionStatusIndicator()
                            Text(failure).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("multipoint.settingError")
                            Spacer(minLength: 0)
                            if transition.canRetryRecovery {
                                Button("Retry") { headphones.checkMultipointChange() }
                                    .controlSize(.small)
                                    .disabled(!headphones.canCheckMultipointChange)
                                    .accessibilityIdentifier("multipoint.checkSetting")
                            }
                        }
                    } else if !transition.isFinished && !transition.awaitingUser {
                        HStack(spacing: 10) {
                            ConnectionStatusIndicator(isLoading: true)
                            Text(transition.phase == .recovering ? String(localized: "Reconnecting controls…") : String(localized: "Checking device connections…"))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("multipoint.settingProgress")
                    }
                }
            }
            .onChange(of: headphones.multipointTransition?.alert, initial: true) { _, alert in
                guard !compact else { return }
                #if !ACOUPLET_PUBLIC_APIS_ONLY
                if ldac.handlesMultipointConfirmation(headphones.multipointTransition) {
                    presentedAlert = nil
                    showsAlert = false
                    return
                }
                #endif
                presentedAlert = alert
                presentedSoundQualityWarning = alert?.format == .fixed && alert?.messageID == 0x07
                    && alert?.actionType == .positiveNegative && headphones.multipointTransition?.targetEnabled == true
                    && headphones.connectionMode == .soundQuality
                showsAlert = alert != nil
            }
            .alert(alertTitle, isPresented: $showsAlert, presenting: presentedAlert) { alert in
                if alert.availableActions.contains(.negative) {
                    Button("Cancel", role: .cancel) { headphones.respondToMultipointAlert(alert, action: .negative) }
                }
                if alert.availableActions.contains(.positive) {
                    Button("Continue") {
                        headphones.respondToMultipointAlert(alert, action: .positive, confirmsSoundQualityWarning: presentedSoundQualityWarning)
                    }
                } else if alert.actionType == .confirmationOnly {
                    Button("OK") { headphones.respondToMultipointAlert(alert, action: nil) }
                }
            } message: { alert in
                Text(alertMessage(alert))
            }
        }
    }

    static func showsMenuEntry(for headphones: SonyHeadphonesController) -> Bool {
        if headphones.multipoint.supportsSourceControl {
            return headphones.multipoint.devices.filter(\.isConnected).count > 1
        }
        return headphones.systemFeatures.generation == .v1 && enabled(for: headphones) != nil
    }

    static func enabled(for headphones: SonyHeadphonesController) -> Bool? {
        headphones.systemFeatures.multipoint?.enabled
            ?? headphones.multipointTransition.flatMap { $0.isFinished ? nil : $0.originalEnabled }
    }

    private var alertTitle: String {
        if presentedAlert?.format == .fixed, presentedAlert?.messageID == 0x70 { return String(localized: "Audio may cut out") }
        guard presentedAlert?.actionType == .positiveNegative else { return String(localized: "Device Connection Change") }
        return headphones.multipointTransition?.targetEnabled == true ? String(localized: "Enable multipoint?") : String(localized: "Use one device at a time?")
    }

    private func alertMessage(_ alert: SonyConnectionAlert) -> String {
        if alert.format == .fixed, alert.messageID == 0x70 {
            return String(localized: "Audio may cut out when Sound Quality and multipoint are both enabled.")
        }
        var message = String(localized: "Changing this setting may briefly disconnect the headphones. Reconnect them if needed.")
        if presentedSoundQualityWarning {
            message += "\n\n" + String(localized: "Audio may cut out when Sound Quality and multipoint are both enabled.")
        }
        if alert.format == .fixed || alert.format == .legacyFixed, alert.messageID == 0x06 {
            message += String(localized: "\n\nThe headphones report that LDAC will be unavailable with this change.")
        }
        if alert.format == .flexible {
            let known = alert.affectedFeatures.filter { $0.title != String(localized: "Unknown feature") }.map(\.title)
            if !known.isEmpty { message += String(localized: "\n\nUnavailable with this change: ") + known.joined(separator: ", ") + "." }
            if known.count != alert.affectedFeatures.count {
                message += String(localized: "\n\nThe headphones also report an affected feature this app cannot identify.")
            }
        }
        return message
    }
}
