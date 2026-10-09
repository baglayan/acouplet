import AppKit
import SwiftUI

struct SonyPreferencePaneView: View {
    @ObservedObject var client: SonyPreferencePaneClient
    @State private var openingError: String?
    @State private var pages: [Page] = []
    @State private var touchChange: TouchChange?

    private struct TouchChange {
        let serverID: UUID
        let address: String
        let session: UInt64
        let key: UInt8
        let gesture: UInt8
        let option: String
        let title: String
        let keys: [String]
    }

    enum Page: String {
        case audio = "Audio & Routing"
        case controls = "Controls & Gestures"
        case battery = "Battery"
        case equalizer = "Equalizer"

        var symbol: String {
            switch self {
            case .audio: "speaker.wave.2.fill"
            case .controls: "hand.tap.fill"
            case .battery: "battery.100percent"
            case .equalizer: "slider.vertical.3"
            }
        }

        var color: Color {
            switch self {
            case .audio: .red
            case .controls: .primary
            case .battery: .green
            case .equalizer: .orange
            }
        }
    }

    init(client: SonyPreferencePaneClient) { self.client = client }

    #if DEBUG
    init(client: SonyPreferencePaneClient, page: Page) {
        self.client = client
        _pages = State(initialValue: [page])
    }

    static func previewListeningModeControl(options: [SonyPreferencePaneDevice.Noise.Option], current: String?,
                                           select: @escaping @MainActor (String) -> Void) -> NSView {
        let view = NSHostingView(rootView: SonyPaneListeningModeControl(options: options, current: current, select: select)
            .frame(maxWidth: .infinity))
        view.sizingOptions = []
        return view
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if let page = pages.last {
                HStack(spacing: 12) {
                    Button { pages.removeLast() } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("pane.back")
                    Text(page.rawValue).font(.headline)
                    Spacer()
                }
                .padding([.horizontal, .top], 20)
            } else if let device = client.selectedDevice, !device.batteries.isEmpty {
                HStack(spacing: 16) {
                    ForEach(device.batteries) { battery in
                        batterySummary(battery, device: device)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            Form {
                if let device = client.selectedDevice {
                    switch pages.last {
                    case nil: overview(device)
                    case .audio: audio(device)
                    case .controls: controls(device)
                    case .battery: battery(device)
                    case .equalizer:
                        if let equalizer = device.equalizer {
                            SonyPaneEqualizerEditor(client: client, equalizer: equalizer)
                                .id("\(device.address):\(device.session):\(equalizer.bands.map(\.id)):\(equalizer.levelSteps)")
                        }
                    }
                    if let error = client.connectionError {
                        Section { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    unavailable
                }
            }
            .formStyle(.grouped)
        }
        .tint(.accentColor)
        .onChange(of: client.selectedAddress) { _, _ in
            pages.removeAll()
            touchChange = nil
        }
        .onChange(of: client.snapshot?.serverID) { _, _ in touchChange = nil }
        .onChange(of: client.selectedDevice?.session) { _, _ in touchChange = nil }
        .confirmationDialog(touchChange.map { "Change \($0.title)?" } ?? "Change Touch Control?",
            isPresented: Binding(get: { touchChange != nil }, set: { if !$0 { touchChange = nil } }),
            titleVisibility: .visible, presenting: touchChange) { change in
                Button("Change") {
                    guard client.snapshot?.serverID == change.serverID,
                          client.selectedDevice?.address == change.address,
                          client.selectedDevice?.session == change.session else { return }
                    client.setTouchAction(key: change.key, gesture: change.gesture, option: change.option)
                }
                Button("Cancel", role: .cancel) {}
            } message: { change in
                Text("Applies to \(change.keys.formatted(.list(type: .and))).")
            }
        .accessibilityIdentifier("pane.headphones")
    }

    @ViewBuilder
    private func overview(_ device: SonyPreferencePaneDevice) -> some View {
        Section {
            identity(device)
            if !device.isReady {
                LabeledContent("Connection") {
                    HStack {
                        Text(device.isConnected ? "Connecting…" : "Disconnected")
                        if !device.isConnected { Button("Open Acouplet", action: openApp) }
                    }
                }
                openingFailure
            }
        }
        if let noise = device.noise {
            Section("Listening Mode") {
                SonyPaneListeningModeControl(options: noise.options, current: noise.current) {
                    client.setNoise(mode: $0)
                }
                .frame(maxWidth: .infinity)
                .disabled(!noise.canSet || client.isUpdating)
                .accessibilityIdentifier("pane.noiseControl")
                pendingStatus(noise.pending, error: noise.error)
            }
        }
        if let volume = device.volume {
            Section("Volume") {
                SonyPaneVolumeControl(client: client, volume: volume)
                    .id("\(device.address):\(device.session):\(volume.sourceAddress ?? "")")
            }
        }
        if hasAudio(device) || hasControls(device) {
            Section {
                if hasAudio(device) { navigation(.audio) }
                if hasControls(device) { navigation(.controls) }
            }
        }
        if !device.batteries.isEmpty || device.batteryCare != nil || device.autoPowerSave != nil || device.automaticPowerOff != nil {
            Section { navigation(.battery) }
        }
        Section {
            LabeledContent("Model Name", value: device.modelName)
            if let firmware = device.firmwareVersion { LabeledContent("Version", value: firmware) }
        }
    }

    @ViewBuilder
    private func audio(_ device: SonyPreferencePaneDevice) -> some View {
        if device.equalizer != nil || device.dsee != nil {
            Section {
                if let equalizer = device.equalizer { navigation(.equalizer, value: equalizer.preset.currentTitle) }
                if let dsee = device.dsee {
                    choice(device.dseeTitle ?? "DSEE", value: dsee) { client.setDSEE(option: $0) }
                }
            }
        }
        if device.speak != nil || device.systemFeatures.contains(where: { $0.id == "1" }) {
            Section {
                if let speak = device.speak {
                    HStack {
                        if let enabled = speak.enabled {
                            Toggle("Speak-to-Chat", isOn: Binding(get: { enabled }, set: { client.setSpeak(enabled: $0) }))
                                .disabled(!speak.canSet || client.isUpdating)
                        } else {
                            LabeledContent("Speak-to-Chat", value: "Unknown")
                        }
                        if speak.pending { ProgressView().controlSize(.small) }
                    }
                    .accessibilityIdentifier("pane.speakToChat")
                    errorText(speak.error)
                }
                ForEach(device.systemFeatures.filter { $0.id == "1" }) { feature in
                    featureToggle(feature) { client.setSystemFeature(id: feature.id, enabled: $0) }
                }
            }
        }
        if device.connectionQuality != nil || device.codec != nil || device.multipoint != nil || !device.sources.isEmpty {
            Section {
                if let quality = device.connectionQuality {
                    LabeledContent("Bluetooth Connection Quality", value: quality.currentTitle ?? "Unknown")
                }
                if let codec = device.codec { LabeledContent("Codec", value: codec) }
                if let multipoint = device.multipoint {
                    LabeledContent(multipoint.title, value: multipoint.enabled.map { $0 ? "On" : "Off" } ?? "Unknown")
                }
                ForEach(device.sources) { source in
                    LabeledContent(source.title, value: source.isSelected ? "Current Audio" : source.isConnected ? "Connected" : "Disconnected")
                }
            }
        }
        if let listeningLevel = device.listeningLevel {
            Section { LabeledContent("Listening Level", value: listeningLevel) }
        }
    }

    @ViewBuilder
    private func controls(_ device: SonyPreferencePaneDevice) -> some View {
        let features = device.systemFeatures.filter { $0.id != "1" }
        if !features.isEmpty {
            Section {
                ForEach(features) { feature in
                    featureToggle(feature) { client.setSystemFeature(id: feature.id, enabled: $0) }
                }
            }
        }
        ForEach(device.touchAssignments) { key in
            Section {
                choice(key.title, value: key.assignment) { client.setTouchAssignment(key: key.id, option: $0) }
                ForEach(key.gestures) { gesture in
                    if let customization = gesture.customization {
                        choice(gesture.title, value: customization) { option in
                            guard option != customization.current else { return }
                            if gesture.sharedKeyTitles.isEmpty {
                                client.setTouchAction(key: key.id, gesture: gesture.id, option: option)
                            } else if let serverID = client.snapshot?.serverID {
                                touchChange = TouchChange(serverID: serverID, address: device.address, session: device.session,
                                    key: key.id, gesture: gesture.id, option: option,
                                    title: gesture.title, keys: gesture.sharedKeyTitles)
                            }
                        }
                    } else {
                        LabeledContent(gesture.title, value: gesture.functionTitle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func battery(_ device: SonyPreferencePaneDevice) -> some View {
        if !device.batteries.isEmpty {
            Section {
                ForEach(device.batteries) { battery in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if battery.isCharging { Label("Charging", systemImage: "bolt.fill") }
                            Text("\(battery.level)%").monospacedDigit()
                                .foregroundStyle(battery.level <= 20 ? Color.red : Color.primary)
                            if battery.id == "case" {
                                Text("Last reported").foregroundStyle(.secondary)
                                    .help("Case percentage and charging show the last report received from the headphones.")
                            }
                        }
                    } label: {
                        Label(battery.title, systemImage: batterySymbol(battery, device: device))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(battery.title) battery")
                    .accessibilityValue(batteryValue(battery))
                }
            }
        }
        if device.batteryCare != nil || device.autoPowerSave != nil || device.automaticPowerOff != nil {
            Section {
                if let care = device.batteryCare { featureToggle(care) { client.setBatteryCare(enabled: $0) } }
                if let saving = device.autoPowerSave { featureToggle(saving) { client.setAutoPowerSave(enabled: $0) } }
                if let power = device.automaticPowerOff {
                    choice("Automatic Power Off", value: power) { client.setAutomaticPowerOff(option: $0) }
                }
            }
        }
    }

    private func hasAudio(_ device: SonyPreferencePaneDevice) -> Bool {
        device.equalizer != nil || device.dsee != nil || device.speak != nil || device.codec != nil
            || device.connectionQuality != nil || device.multipoint != nil || !device.sources.isEmpty
            || device.listeningLevel != nil || device.systemFeatures.contains { $0.id == "1" }
    }

    private func hasControls(_ device: SonyPreferencePaneDevice) -> Bool {
        !device.touchAssignments.isEmpty || device.systemFeatures.contains { $0.id != "1" }
    }

    private func navigation(_ page: Page, value: String? = nil) -> some View {
        Button { pages.append(page) } label: {
            LabeledContent {
                HStack {
                    if let value { Text(value).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                }
            } label: {
                Label {
                    Text(page.rawValue)
                } icon: {
                    Image(systemName: page.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14))
                        .foregroundStyle(page.color)
                        .frame(width: 22, height: 22)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pane.page.\(page)")
    }

    private func choice(_ title: String, value: SonyPreferencePaneDevice.Choice, set: @escaping @MainActor @Sendable (String) -> Void) -> some View {
        Group {
            HStack {
                Picker(title, selection: Binding(get: { value.current ?? "" }, set: set)) {
                    if value.current == nil { Text("Unknown").tag("").disabled(true) }
                    else if let current = value.current, !value.options.contains(where: { $0.id == current }) {
                        Text(value.currentTitle ?? "Unknown").tag(current).disabled(true)
                    }
                    ForEach(value.options) { option in
                        Text(option.title).tag(option.id).disabled(!option.isEnabled)
                    }
                }
                .pickerStyle(.menu)
                .menuIndicator(.visible)
                .disabled(!value.canSet || client.isUpdating)
                if value.pending { ProgressView().controlSize(.small) }
            }
            errorText(value.error)
        }
    }

    private func featureToggle(_ feature: SonyPreferencePaneDevice.Toggle, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Group {
            HStack {
                if let enabled = feature.enabled {
                    Toggle(feature.title, isOn: Binding(get: { enabled }, set: set))
                        .disabled(!feature.canSet || client.isUpdating)
                } else { LabeledContent(feature.title, value: "Unknown") }
                if feature.pending { ProgressView().controlSize(.small) }
            }
            errorText(feature.error)
        }
    }

    private func batterySummary(_ battery: SonyPreferencePaneDevice.Battery, device: SonyPreferencePaneDevice) -> some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol(battery, device: device))
            if battery.id == "left" { Image(systemName: "l.circle") }
            if battery.id == "right" { Image(systemName: "r.circle").foregroundStyle(.red) }
            Text("\(battery.level)%").monospacedDigit()
                .foregroundStyle(battery.level <= 20 ? Color.red : Color.secondary)
            if battery.isCharging { Image(systemName: "bolt.fill") }
            if battery.id == "case" {
                Text("Last reported").font(.caption2)
                    .help("Case percentage and charging show the last report received from the headphones.")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(battery.title) battery")
        .accessibilityValue(batteryValue(battery))
    }

    private func batterySymbol(_ battery: SonyPreferencePaneDevice.Battery, device: SonyPreferencePaneDevice) -> String {
        switch battery.id {
        case "left": "earbuds.stemless.left"
        case "right": "earbuds.stemless.right"
        case "case": "earbuds.case.fill"
        default: device.systemSymbol
        }
    }

    private func batteryValue(_ battery: SonyPreferencePaneDevice.Battery) -> String {
        String(localized: "\(battery.level) percent\(battery.isCharging ? String(localized: ", charging") : "")")
            + (battery.id == "case" ? String(localized: ", last reported") : "")
    }

    private func identity(_ device: SonyPreferencePaneDevice) -> some View {
        let connected = client.snapshot?.devices.filter(\.isConnected) ?? []
        return Group {
            if client.pinnedAddress == nil, connected.count > 1 {
                Picker("Device", selection: Binding(get: { device.address }, set: { client.select(address: $0) })) {
                    if !device.isConnected { Text(device.displayTitle).tag(device.address).disabled(true) }
                    ForEach(connected) { Text($0.displayTitle).tag($0.address) }
                }
                .pickerStyle(.menu)
                .menuIndicator(.visible)
                .disabled(client.isUpdating)
                .accessibilityIdentifier("pane.devicePicker")
            } else {
                LabeledContent("Name", value: device.name).accessibilityIdentifier("pane.deviceName")
            }
        }
    }

    @ViewBuilder private var unavailable: some View {
        Section {
            if client.snapshot != nil {
                Text(client.pinnedAddress == nil ? "No Sony headphones connected" : "These headphones are unavailable")
            } else if client.connectionError != nil {
                Text("Acouplet is unavailable")
            } else {
                ProgressView("Connecting…").controlSize(.small)
            }
            Button("Open Acouplet", action: openApp)
            openingFailure
        }
    }

    @ViewBuilder private var openingFailure: some View {
        if let openingError { Text(openingError).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func errorText(_ error: String?) -> some View {
        if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func pendingStatus(_ pending: Bool, error: String?) -> some View {
        if pending { ProgressView().controlSize(.small) }
        errorText(error)
    }

    private func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.baglayan.Acouplet") else {
            openingError = "Acouplet is not installed."
            return
        }
        openingError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in openingError = error?.localizedDescription }
        }
    }
}

private struct SonyPaneListeningModeControl: NSViewRepresentable {
    let options: [SonyPreferencePaneDevice.Noise.Option]
    let current: String?
    let select: @MainActor (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.role = .valueSelection
        control.borderShape = .capsule
        control.segmentDistribution = .fill
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSegment(_:))
        control.setAccessibilityLabel("Listening Mode")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.options = options
        context.coordinator.select = select
        if control.segmentCount != options.count { control.segmentCount = options.count }
        for (index, option) in options.enumerated() {
            let symbol = switch option.id {
            case "off": "circle"
            case "anc": "waveform.slash"
            case "ambient": "ear"
            case "wind": "wind"
            default: "earbuds.stemless"
            }
            control.setLabel(option.title, forSegment: index)
            control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: index)
            control.setToolTip(option.title, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectedSegment = options.firstIndex { $0.id == current } ?? -1
        control.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(options: options, select: select) }

    @MainActor final class Coordinator: NSObject {
        var options: [SonyPreferencePaneDevice.Noise.Option]
        var select: (String) -> Void

        init(options: [SonyPreferencePaneDevice.Noise.Option], select: @escaping (String) -> Void) {
            self.options = options
            self.select = select
        }

        @objc func selectSegment(_ control: NSSegmentedControl) {
            guard options.indices.contains(control.selectedSegment) else { return }
            select(options[control.selectedSegment].id)
        }
    }
}

private struct SonyPaneVolumeControl: View {
    @ObservedObject var client: SonyPreferencePaneClient
    let volume: SonyPreferencePaneDevice.Volume
    @State private var value: Double
    @State private var isEditing = false

    init(client: SonyPreferencePaneClient, volume: SonyPreferencePaneDevice.Volume) {
        self.client = client
        self.volume = volume
        _value = State(initialValue: Double(volume.value))
    }

    var body: some View {
        HStack {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: {
                value = $0
                if !isEditing { client.setVolume(Int($0), sourceAddress: volume.sourceAddress) }
            }), in: Double(volume.minimum)...Double(volume.maximum), step: 1, onEditingChanged: {
                isEditing = $0
                if !$0 { client.setVolume(Int(value), sourceAddress: volume.sourceAddress) }
            }) { Text("Volume") }
                .labelsHidden()
                .disabled(!volume.canSet || client.isUpdating)
                .accessibilityValue("\(Int(value)) of \(volume.maximum)")
            Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
            if volume.pending { ProgressView().controlSize(.small) }
        }
        .onChange(of: volume.value) { _, value in
            if !isEditing { self.value = Double(value) }
        }
        if let error = volume.error { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct SonyPaneEqualizerEditor: View {
    @ObservedObject var client: SonyPreferencePaneClient
    let equalizer: SonyPreferencePaneDevice.Equalizer
    @State private var draft: [Int]

    init(client: SonyPreferencePaneClient, equalizer: SonyPreferencePaneDevice.Equalizer) {
        self.client = client
        self.equalizer = equalizer
        _draft = State(initialValue: equalizer.values ?? [])
    }

    var body: some View {
        Group {
        Section {
            Picker("Preset", selection: Binding(
                get: { equalizer.preset.current ?? "" },
                set: { client.setEqualizerPreset(option: $0) }
            )) {
                if equalizer.preset.current == nil { Text("Unknown").tag("").disabled(true) }
                ForEach(equalizer.preset.options) { option in
                    Text(option.title).tag(option.id).disabled(!option.isEnabled)
                }
            }
            .pickerStyle(.menu)
            .menuIndicator(.visible)
            .disabled(!equalizer.preset.canSet || client.isUpdating)
            if equalizer.requiresManualSelection, let manual = equalizer.manualPresetID {
                Button("Use Manual") { client.setEqualizerPreset(option: manual) }
                    .disabled(!equalizer.preset.canSet || client.isUpdating)
            }
            if equalizer.preset.pending { ProgressView().controlSize(.small) }
            if let error = equalizer.preset.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        if draft.count == equalizer.bands.count, !draft.isEmpty {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(equalizer.bands.indices, id: \.self) { index in
                        VStack(spacing: 8) {
                            Text(draft[index].formatted(.number.sign(strategy: .always())))
                                .font(.caption).monospacedDigit()
                            SonyPaneEqualizerFader(value: Binding(
                                get: { Double(draft[index]) },
                                set: { draft[index] = Int($0) }
                            ), title: equalizer.bands[index].title, range: equalizer.minimum...equalizer.maximum)
                                .frame(width: 24, height: 156)
                            Text(equalizer.bands[index].title).font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
                .disabled(!equalizer.canEdit || client.isUpdating)
                HStack {
                    Button("Reset Flat") { draft = Array(repeating: 0, count: draft.count) }
                        .disabled(!equalizer.canEdit || client.isUpdating)
                    Spacer()
                    Button("Apply") { client.setEqualizer(values: draft) }
                        .disabled(!equalizer.canEdit || client.isUpdating || equalizer.values == draft)
                }
            }
        }
        }
            .onChange(of: equalizer.values) { old, new in
                if draft == old || draft.isEmpty { draft = new ?? [] }
            }
            .onChange(of: equalizer.preset.current) { _, _ in draft = equalizer.values ?? [] }
    }
}

private struct SonyPaneEqualizerFader: NSViewRepresentable {
    @Binding var value: Double
    let title: String
    let range: ClosedRange<Int>
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                              target: context.coordinator, action: #selector(Coordinator.changeValue(_:)))
        slider.isVertical = true
        slider.neutralValue = 0
        slider.allowsTickMarkValuesOnly = true
        slider.tintProminence = .primary
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.setAccessibilityLabel(title)
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.numberOfTickMarks = range.count
        slider.doubleValue = value
        slider.trackFillColor = .controlAccentColor
        slider.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changeValue(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
    }
}
