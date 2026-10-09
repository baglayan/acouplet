import Foundation

struct SonyTouchActionSetting: Equatable, Sendable {
    let action: UInt8
    let function: UInt8

    func gestureTitle(keyType: UInt8, generation: SonyProtocolInfo.Generation = .v2) -> String {
        guard keyType <= (generation == .v1 ? 0x01 : 0x02),
              knownTouchAction(action, generation: generation) else { return String(localized: "Unknown gesture") }
        return switch action {
        case 0x00: keyType == 0x01 ? String(localized: "Press") : String(localized: "Tap")
        case 0x01: keyType == 0x01 ? String(localized: "Double press") : String(localized: "Double tap")
        case 0x02: keyType == 0x01 ? String(localized: "Triple press") : String(localized: "Triple tap")
        case 0x03: keyType == 0x01 ? String(localized: "Repeated presses") : String(localized: "Repeated taps")
        case 0x10: keyType == 0x01 ? String(localized: "Press and hold") : String(localized: "Tap and hold")
        case 0x11: keyType == 0x01 ? String(localized: "Double press and hold") : String(localized: "Double tap and hold")
        case 0x21: String(localized: "Long press to activate")
        case 0x22: String(localized: "Long press while active")
        default: String(localized: "Unknown gesture")
        }
    }

    var functionTitle: String { functionTitle(generation: .v2) }

    func functionTitle(generation: SonyProtocolInfo.Generation) -> String {
        guard knownTouchFunction(function, generation: generation) else { return String(localized: "Unknown function") }
        if generation == .v1 {
            switch function {
            case 0x02: return String(localized: "Noise Cancelling Optimizer")
            case 0x11: return String(localized: "Volume up")
            case 0x12: return String(localized: "Volume down")
            case 0x34: return String(localized: "Talk to / Cancel Amazon Alexa")
            default: break
            }
        }
        return switch function {
        case 0x00: String(localized: "No function")
        case 0x01: String(localized: "Noise Cancelling / Ambient Sound / Off")
        case 0x02: String(localized: "Noise Cancelling / Ambient Sound")
        case 0x03: String(localized: "Noise Cancelling / Off")
        case 0x04: String(localized: "Ambient Sound / Off")
        case 0x10: String(localized: "Quick Attention")
        case 0x11: String(localized: "Noise Cancelling Optimizer")
        case 0x20: String(localized: "Play / Pause")
        case 0x21: String(localized: "Next track")
        case 0x22: String(localized: "Previous track")
        case 0x23: String(localized: "Volume up")
        case 0x24: String(localized: "Volume down")
        case 0x30: String(localized: "Voice Assistant")
        case 0x31: String(localized: "Read notifications")
        case 0x32: String(localized: "Talk to Google Assistant")
        case 0x33: String(localized: "Stop Google Assistant")
        case 0x34, 0x36: String(localized: "Cancel voice input")
        case 0x35: String(localized: "Talk to Tencent Xiaowei")
        case 0x37: String(localized: "Talk to Amazon Alexa")
        case 0x38: String(localized: "Cancel Amazon Alexa")
        case 0x39: String(localized: "Cancel Tencent Xiaowei")
        case 0x3A: String(localized: "Next track / Stop Gemini Live")
        case 0x3B: String(localized: "Previous track / Stop Gemini Live")
        case 0x43: String(localized: "Quick Access 1")
        case 0x44: String(localized: "Quick Access 2")
        case 0x45: String(localized: "Talk to / Cancel Tencent Xiaowei")
        case 0x47: String(localized: "Microsoft Teams")
        case 0x48: String(localized: "Teams voice commands")
        case 0x57: String(localized: "Ambient Sound settings")
        case 0x59: String(localized: "Listening mode")
        case 0x70: String(localized: "Microphone mute")
        case 0x71: String(localized: "Increase game audio")
        case 0x72: String(localized: "Increase chat audio")
        default: String(localized: "Unknown function")
        }
    }

    fileprivate func isRecognized(generation: SonyProtocolInfo.Generation) -> Bool {
        knownTouchAction(action, generation: generation) && knownTouchFunction(function, generation: generation)
    }
}

struct SonyTouchCustomizableAction: Equatable, Sendable {
    let action: UInt8
    let defaultFunction: UInt8
    let functions: [UInt8]

    fileprivate var isRecognized: Bool {
        knownTouchAction(action) && knownTouchFunction(defaultFunction) && functions.allSatisfy { knownTouchFunction($0) }
    }
}

struct SonyTouchPresetCapability: Equatable, Sendable {
    let preset: UInt8
    let fixedActions: [SonyTouchActionSetting]
    let customizableActions: [SonyTouchCustomizableAction]

    var title: String { title(generation: .v2) }

    func title(generation: SonyProtocolInfo.Generation) -> String { touchPresetTitle(preset, generation: generation) ?? String(localized: "Unknown") }

    fileprivate func isRecognized(generation: SonyProtocolInfo.Generation) -> Bool {
        touchPresetTitle(preset, generation: generation) != nil
            && fixedActions.allSatisfy({ $0.isRecognized(generation: generation) })
            && customizableActions.allSatisfy(\.isRecognized)
            && Set(fixedActions.map(\.action) + customizableActions.map(\.action)).count
                == fixedActions.count + customizableActions.count
    }
}

struct SonyTouchKeyCapability: Equatable, Sendable {
    let key: UInt8
    let keyType: UInt8
    let defaultPreset: UInt8
    let presets: [SonyTouchPresetCapability]

    var title: String { title(generation: .v2) }

    func title(generation: SonyProtocolInfo.Generation) -> String {
        guard key <= (generation == .v1 ? 0x03 : 0x05) else { return String(localized: "Unknown") }
        return switch key {
        case 0x00: String(localized: "Left")
        case 0x01: String(localized: "Right")
        case 0x02: String(localized: "Custom button")
        case 0x03: String(localized: "C button")
        case 0x04: String(localized: "NC/AMB button")
        case 0x05: String(localized: "NC/AMBIENT button")
        default: String(localized: "Unknown")
        }
    }

    fileprivate func isRecognized(generation: SonyProtocolInfo.Generation) -> Bool {
        key <= (generation == .v1 ? 0x03 : 0x05) && keyType <= (generation == .v1 ? 0x01 : 0x02)
            && touchPresetTitle(defaultPreset, generation: generation) != nil
            && presets.allSatisfy({ $0.isRecognized(generation: generation) })
            && Set(presets.map(\.preset)).count == presets.count
    }
}

struct SonyTouchPresetActions: Equatable, Sendable {
    let preset: UInt8
    let actions: [SonyTouchActionSetting]
}

struct SonyTouchAssignments: Equatable, Sendable {
    let generation: SonyProtocolInfo.Generation
    let inquiryType: UInt8?
    private(set) var keys: [SonyTouchKeyCapability]?
    private(set) var limitation: UInt8?
    private(set) var statuses: [UInt8]?
    private(set) var selectedPresets: [UInt8]?
    private(set) var customizedActions: [SonyTouchPresetActions]?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.generation = generation
        inquiryType = generation == .v1 ? (supportedFunctions.contains(0xF6) ? 0x06 : nil)
            : supportedFunctions.contains(0xFE) ? 0x0E : supportedFunctions.contains(0xF3) ? 0x03 : nil
    }

    var hasKnownCapability: Bool {
        guard let keys else { return false }
        return keys.allSatisfy({ $0.isRecognized(generation: generation) })
            && Set(keys.map(\.key)).count == keys.count
            && (inquiryType != 0x0E || limitation.map { $0 <= 0x02 } == true)
    }

    var hasKnownStatus: Bool { statuses?.allSatisfy { $0 <= 1 } == true }

    var hasKnownSelection: Bool {
        selectedPresets?.allSatisfy { touchPresetTitle($0, generation: generation) != nil } == true
    }

    var queryPayloads: [[UInt8]] {
        guard let inquiryType else { return [] }
        var queries: [[UInt8]] = (keys == nil ? [[0xF0, inquiryType]] : [])
            + [[0xF2, inquiryType], [0xF6, inquiryType]]
        if keys?.contains(where: { $0.presets.contains(where: { !$0.customizableActions.isEmpty }) }) == true {
            queries.append([0xFA, inquiryType])
        }
        return queries
    }

    func selectedPreset(key: UInt8) -> UInt8? {
        guard let keys, let selectedPresets, selectedPresets.count == keys.count,
              let index = keys.firstIndex(where: { $0.key == key }) else { return nil }
        return selectedPresets[index]
    }

    mutating func invalidateRead(_ query: [UInt8]) {
        guard query.count == 2, query[1] == inquiryType else { return }
        switch query[0] {
        case 0xF0:
            keys = nil
            limitation = nil
        case 0xF2: statuses = nil
        case 0xF6: selectedPresets = nil
        case 0xFA: customizedActions = nil
        default: break
        }
    }

    func keysUsingPreset(_ preset: UInt8) -> [SonyTouchKeyCapability] {
        guard let keys, let selectedPresets, keys.count == selectedPresets.count else { return [] }
        return zip(keys, selectedPresets).compactMap { $0.1 == preset ? $0.0 : nil }
    }

    func customizableActions(key: UInt8) -> [SonyTouchCustomizableAction] {
        guard let selected = selectedPreset(key: key),
              let matches = keys?.filter({ $0.key == key }), matches.count == 1 else { return [] }
        let presets = matches[0].presets.filter { $0.preset == selected }
        guard presets.count == 1, touchPresetTitle(selected, generation: generation) != nil else { return [] }
        let preset = presets[0]
        let actions = preset.fixedActions.map(\.action) + preset.customizableActions.map(\.action)
        return preset.customizableActions.compactMap { customizable in
            guard knownTouchAction(customizable.action, generation: generation),
                  actions.filter({ $0 == customizable.action }).count == 1,
                  Set(customizable.functions).count == customizable.functions.count else { return nil }
            return SonyTouchCustomizableAction(action: customizable.action, defaultFunction: customizable.defaultFunction,
                                               functions: customizable.functions.filter { knownTouchFunction($0, generation: generation) })
        }
    }

    func reportedFunction(preset: UInt8, action: UInt8) -> UInt8? {
        guard let records = customizedActions?.filter({ $0.preset == preset }), records.count == 1 else { return nil }
        let actions = records[0].actions.filter { $0.action == action }
        return actions.count == 1 && knownTouchFunction(actions[0].function, generation: generation) ? actions[0].function : nil
    }

    func reportedActions(key: UInt8) -> [SonyTouchActionSetting]? {
        guard let selected = selectedPreset(key: key),
              let capabilities = keys?.filter({ $0.key == key }), capabilities.count == 1 else { return nil }
        let presets = capabilities[0].presets.filter { $0.preset == selected }
        guard presets.count == 1 else { return nil }
        let preset = presets[0]
        var actions = preset.fixedActions
        if !preset.customizableActions.isEmpty {
            for customizable in preset.customizableActions {
                guard let function = reportedFunction(preset: selected, action: customizable.action),
                      customizable.functions.contains(function) else { return nil }
                actions.append(SonyTouchActionSetting(action: customizable.action, function: function))
            }
        }
        guard Set(actions.map(\.action)).count == actions.count else { return nil }
        return actions.sorted { $0.action < $1.action }
    }

    func isAvailable(key: UInt8) -> Bool {
        guard hasKnownCapability, hasKnownStatus, let keys,
              let statuses, statuses.count == keys.count,
              let selectedPresets, selectedPresets.count == keys.count,
              zip(keys, selectedPresets).allSatisfy({ key, preset in key.presets.contains(where: { $0.preset == preset }) }),
              let index = keys.firstIndex(where: { $0.key == key }) else { return false }
        return statuses[index] == 0
    }

    func setPayload(key: UInt8, preset: UInt8) -> [UInt8]? {
        guard isAvailable(key: key), let inquiryType, let keys, var selectedPresets,
              let index = keys.firstIndex(where: { $0.key == key }),
              keys[index].presets.contains(where: { $0.preset == preset }) else { return nil }
        selectedPresets[index] = preset
        return [0xF8, inquiryType, UInt8(selectedPresets.count)] + selectedPresets
    }

    func setActionPayload(key: UInt8, action: UInt8, function: UInt8) -> [UInt8]? {
        guard inquiryType == 0x03, let keys, Set(keys.map(\.key)).count == keys.count,
              let statuses, statuses.count == keys.count,
              let preset = selectedPreset(key: key),
              let current = reportedFunction(preset: preset, action: action) else { return nil }
        let sharedKeys = keysUsingPreset(preset)
        guard !sharedKeys.isEmpty, sharedKeys.allSatisfy({ key in
            guard key.key <= 0x05, key.keyType <= 0x02,
                  let index = keys.firstIndex(where: { $0.key == key.key }), statuses[index] == 0 else { return false }
            let actions = customizableActions(key: key.key).filter { $0.action == action }
            return actions.count == 1 && actions[0].functions.contains(current) && actions[0].functions.contains(function)
        }) else { return nil }
        return [0xFC, 0x03, 1, preset, 1, action, function]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard let inquiryType, payload.count >= 3, payload[1] == inquiryType else { return false }
        switch payload[0] {
        case 0xF1:
            var reader = SonyTouchPacketReader(bytes: payload, offset: 2)
            let receivedLimitation = inquiryType == 0x0E ? reader.read() : nil
            guard let receivedKeys = reader.readKeys(generation: generation), reader.isAtEnd else { return false }
            keys = receivedKeys
            limitation = receivedLimitation
        case 0xF3, 0xF5:
            guard payload[2] > 0, payload.count == 3 + Int(payload[2]) else { return false }
            statuses = Array(payload.dropFirst(3))
        case 0xF7, 0xF9:
            guard payload[2] > 0, payload.count == 3 + Int(payload[2]) else { return false }
            selectedPresets = Array(payload.dropFirst(3))
        case 0xFB, 0xFD:
            guard generation == .v2 else { return false }
            var reader = SonyTouchPacketReader(bytes: payload, offset: 2)
            guard let actions = reader.readPresetActions(), reader.isAtEnd else { return false }
            customizedActions = actions
        default:
            return false
        }
        return true
    }
}

private struct SonyTouchPacketReader {
    let bytes: [UInt8]
    var offset: Int

    var isAtEnd: Bool { offset == bytes.count }

    mutating func read() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readKeys(generation: SonyProtocolInfo.Generation) -> [SonyTouchKeyCapability]? {
        guard let count = read(), count > 0 else { return nil }
        var keys: [SonyTouchKeyCapability] = []
        for _ in 0..<count {
            guard let key = read(), let keyType = read(), let defaultPreset = read(),
                  let presetCount = read(), presetCount > 0 else { return nil }
            var presets: [SonyTouchPresetCapability] = []
            for _ in 0..<presetCount {
                guard let preset = read(), let fixedCount = read() else { return nil }
                let customizableCount: UInt8? = generation == .v1 ? 0 : read()
                guard let customizableCount, fixedCount > 0 || customizableCount > 0,
                      let fixedActions = readActions(count: fixedCount) else { return nil }
                var customizableActions: [SonyTouchCustomizableAction] = []
                for _ in 0..<customizableCount {
                    guard let action = read(), let defaultFunction = read(), let functionCount = read(),
                          functionCount > 0, offset + Int(functionCount) <= bytes.count else { return nil }
                    let functions = Array(bytes[offset..<(offset + Int(functionCount))])
                    offset += Int(functionCount)
                    customizableActions.append(SonyTouchCustomizableAction(action: action, defaultFunction: defaultFunction, functions: functions))
                }
                presets.append(SonyTouchPresetCapability(preset: preset, fixedActions: fixedActions, customizableActions: customizableActions))
            }
            keys.append(SonyTouchKeyCapability(key: key, keyType: keyType, defaultPreset: defaultPreset, presets: presets))
        }
        return keys
    }

    mutating func readActions(count: UInt8) -> [SonyTouchActionSetting]? {
        var actions: [SonyTouchActionSetting] = []
        for _ in 0..<count {
            guard let action = read(), let function = read() else { return nil }
            actions.append(SonyTouchActionSetting(action: action, function: function))
        }
        return actions
    }

    mutating func readPresetActions() -> [SonyTouchPresetActions]? {
        guard let count = read(), count > 0 else { return nil }
        var presets: [SonyTouchPresetActions] = []
        for _ in 0..<count {
            guard let preset = read(), let actionCount = read(), actionCount > 0,
                  let actions = readActions(count: actionCount) else { return nil }
            presets.append(SonyTouchPresetActions(preset: preset, actions: actions))
        }
        return presets
    }
}

private func knownTouchAction(_ value: UInt8, generation: SonyProtocolInfo.Generation = .v2) -> Bool {
    if generation == .v1, value == 0x03 { return false }
    return switch value {
    case 0x00...0x03, 0x10, 0x11, 0x21, 0x22: true
    default: false
    }
}

private func knownTouchFunction(_ value: UInt8, generation: SonyProtocolInfo.Generation = .v2) -> Bool {
    if generation == .v1 {
        return switch value {
        case 0x00...0x02, 0x10...0x12, 0x20...0x22, 0x30...0x36: true
        default: false
        }
    }
    return switch value {
    case 0x00...0x04, 0x10, 0x11, 0x20...0x24, 0x30...0x3B, 0x40...0x48, 0x50...0x59, 0x70...0x72: true
    default: false
    }
}

private func touchPresetTitle(_ value: UInt8, generation: SonyProtocolInfo.Generation = .v2) -> String? {
    if generation == .v1, ![0x00, 0x10, 0x20, 0x30, 0x31, 0x32, 0x33, 0xFF].contains(value) { return nil }
    return switch value {
    case 0x00: String(localized: "Ambient Sound Control")
    case 0x10: String(localized: "Volume Control")
    case 0x20: String(localized: "Playback Control")
    case 0x21: String(localized: "Track Control")
    case 0x22: String(localized: "Playback Control (limited voice assistant)")
    case 0x30: String(localized: "Voice Assistant")
    case 0x31: String(localized: "Google Assistant")
    case 0x32: String(localized: "Amazon Alexa")
    case 0x33: String(localized: "Tencent Xiaowei")
    case 0x34: String(localized: "MS")
    case 0x35: String(localized: "Ambient Sound and Quick Access")
    case 0x36: String(localized: "Quick Access")
    case 0x37: String(localized: "Tencent Xiaowei and Q Music")
    case 0x38: String(localized: "Teams")
    case 0x39: String(localized: "Google Assistant (Classic only)")
    case 0x40: String(localized: "Amazon Alexa (Classic only)")
    case 0x41: String(localized: "Tencent Xiaowei (Classic only)")
    case 0x42: String(localized: "Quick Access (Classic only)")
    case 0x43: String(localized: "Ambient Sound & Quick Access (Classic only)")
    case 0x44: String(localized: "Tencent Xiaowei & Q Music (Classic only)")
    case 0x45: String(localized: "Ambient Sound and Microphone")
    case 0x46: String(localized: "Listening Mode and Quick Access")
    case 0x47: String(localized: "Ambient Sound and Listening Mode")
    case 0x70: String(localized: "Chat Mix")
    case 0x71: String(localized: "Custom 1")
    case 0x72: String(localized: "Custom 2")
    case 0xFF: String(localized: "No Function")
    default: nil
    }
}
