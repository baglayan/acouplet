import Foundation

private func modernHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func modernMultipointState(connected: Bool = true, function: UInt8 = 0x32) -> SonyMultipoint {
    var state = SonyMultipoint(supportedFunctions: [0x31, function])
    let inquiry = state.inventoryInquiryType!
    state.update([0x31, inquiry, 8, 2, 0])
    state.update([0x33, inquiry, 0, 0])
    let deviceClass: [UInt8] = inquiry == 2 ? [0, 1, 0] : []
    state.update([0x37, inquiry, 1] + Array("12:34:56:78:9A:BC".utf8)
        + [connected ? 1 : 0] + deviceClass + [1, 65, connected ? 1 : 0])
    state.update([0x37, 1, 1])
    return state
}

func modernAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("modern.") else { return nil }
    let payload = (input["payload"] as? [Int] ?? []).map(UInt8.init)
    if operation.hasPrefix("modern.connection") {
        var state = SonyAudioFeatures(supportedFunctions: [UInt8(input["function"] as? Int ?? 0xE7)])
        if operation == "modern.connectionAlertSet" {
            var transition = SonyConnectionTransition(original: .stableConnection, target: .soundQuality,
                supportedModes: [.soundQuality, .stableConnection], session: 1,
                connectionModeInquiryType: state.connectionModeInquiryType!)!
            transition.commandTransmitted(transition.requestPayload, session: 1)
            guard let alert = SonyConnectionAlert(payload: payload), transition.receiveAlert(alert, session: 1),
                  let action = SonyConnectionAlertAction(rawValue: UInt8(input["action"] as! Int)),
                  let reply = transition.respond(to: alert, action: action) else { return ["accepted": false] }
            return ["payload": modernHex(reply)]
        }
        if operation == "modern.connectionSet" {
            let mode: SonyConnectionMode
            switch input["mode"] as! String {
            case "soundQuality": mode = .soundQuality
            case "stableConnection": mode = .stableConnection
            case "lowLatency": mode = .lowLatency
            default: preconditionFailure("Unknown modern connection mode")
            }
            let original: SonyConnectionMode = mode == .soundQuality ? .stableConnection : .soundQuality
            let transition = SonyConnectionTransition(original: original, target: mode,
                supportedModes: [.soundQuality, .stableConnection, .lowLatency], session: 1,
                connectionModeInquiryType: state.connectionModeInquiryType!)!
            return ["payload": modernHex(transition.requestPayload)]
        }
        guard state.update(payload) else { return ["accepted": false] }
        switch operation {
        case "modern.connectionCapability":
            return ["modes": state.supportedConnectionModes!.map { String(describing: $0) },
                    "exclusions": state.connectionModeLDACExclusions!.map { String(describing: $0) }]
        case "modern.connectionStatus":
            if state.connectionModeInquiryType == 0 { return ["available": state.connectionModeAvailable!] }
            return ["available": state.connectionModeAvailable!, "ldac": state.connectionModeLDACAvailable!]
        case "modern.connectionParameter":
            return ["mode": String(describing: state.connectionMode!)]
        case "modern.connectionNotification":
            if state.connectionModeInquiryType != 5 { return ["mode": String(describing: state.connectionMode!)] }
            return ["mode": String(describing: state.connectionMode!), "stream": String(describing: state.lastConnectionModeSwitchingStream!)]
        default:
            preconditionFailure("Unknown modern connection operation")
        }
    }
    if operation == "modern.general" || operation == "modern.generalSet" {
        let slot = UInt8(input["slot"] as! Int)
        let setting = input["setting"] as! String
        var state = SonySystemFeatures(supportedFunctions: [slot])
        if operation == "modern.generalSet" {
            state.update([0xD1, slot, 0, 1, UInt8(setting.utf8.count)] + Array(setting.utf8) + [0])
            state.update([0xD3, slot, 0])
            state.update([0xD7, slot, 0, 1])
            let enabled = input["enabled"] as! Bool
            let result = setting == "MULTIPOINT_SETTING" ? state.multipointSetPayload(enabled: enabled) : state.sidetoneSetPayload(enabled: enabled)
            return ["payload": modernHex(result!)]
        }
        for bytes in input["payloads"] as! [[Int]] {
            guard state.update(bytes.map(UInt8.init)) else { return ["accepted": false] }
        }
        let feature = setting == "MULTIPOINT_SETTING" ? state.multipoint! : state.sidetone!
        return ["available": feature.available!, "enabled": feature.enabled!]
    }
    switch operation {
    case "modern.sourceSet":
        let state = modernMultipointState()
        return ["payload": modernHex(state.sourceSwitchPayload(address: input["address"] as! String)!)]
    case "modern.keepingSet":
        let state = modernMultipointState()
        return ["payload": modernHex(state.keepingSetPayload(input["enabled"] as! Bool)!)]
    case "modern.actionSet":
        let action: SonyPeripheralAction
        switch input["action"] as! String {
        case "disconnect": action = .disconnect
        case "connect": action = .connect
        case "unpair": action = .unpair
        default: preconditionFailure("Unknown modern peripheral action")
        }
        let state = modernMultipointState(connected: action != .connect, function: UInt8(input["function"] as? Int ?? 0x32))
        return ["payload": modernHex(state.peripheralActionPayload(action, address: input["address"] as! String)!)]
    default:
        break
    }
    var state = SonyMultipoint(supportedFunctions: [0x31, UInt8(input["function"] as? Int ?? 0x32)])
    guard state.update(payload) else { return ["accepted": false] }
    switch operation {
    case "modern.multipointCapability":
        return ["paired": Int(state.maxPairedDevices!), "connected": Int(state.maxConnectedDevices!),
                "transfer": state.multipleConnectionFileTransfer!]
    case "modern.multipointStatus":
        return ["mode": Int(state.bluetoothMode!), "available": state.available!]
    case "modern.inventory":
        return ["playback": Int(state.inventory!.playbackRightID), "selectedSource": state.selectedSource?.address ?? "", "devices": state.devices.map {
            ["address": $0.address, "connection": Int($0.connectionID), "connected": $0.isConnected,
             "class": Int($0.classOfDevice), "name": $0.name] as [String: Any]
        }]
    case "modern.keeping":
        return ["keeping": state.keeping!]
    case "modern.keepingResult":
        return ["keeping": state.keeping!, "result": String(describing: state.lastKeepingResult!)]
    case "modern.sourceResult":
        return ["address": state.lastSourceResult!.address, "result": String(describing: state.lastSourceResult!.result)]
    case "modern.actionResult":
        return ["action": String(describing: SonyPeripheralAction(rawValue: state.lastPeripheralResult!.action)!), "address": state.lastPeripheralResult!.address,
                "result": String(describing: state.lastPeripheralResult!.result)]
    default:
        preconditionFailure("Unknown modern operation")
    }
}
