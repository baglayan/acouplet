import Foundation

func powerAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("power.") else { return nil }
    let payload = try apkBytes(input["payload"] ?? "")
    let setting = input["enabled"] as? Bool
    let frameType = UInt8(input["frameType"] as? Int ?? 0x0C)
    switch operation {
    case "power.chargeInUse":
        let functions = Set((input["functions"] as! [Int]).map(UInt8.init))
        let functions2 = Set((input["functions2"] as! [Int]).map(UInt8.init))
        return ["supported": SonyPowerFeatures(supportedFunctions: functions,
                                              supportedFunctions2: functions2).supportsChargeInUse]
    case "power.care":
        var state = SonyBatteryCare(includesThreshold: frameType == 0x0E)
        if let setting {
            if state.includesThreshold { state.update([0x21, 1, 80], frameType: frameType) }
            state.update([0x23, state.inquiryType, 0] + (state.includesThreshold ? [1] : []), frameType: frameType)
            state.update([0x27, state.inquiryType, 1], frameType: frameType)
            return ["payload": state.setPayload(enabled: setting).map(apkHex) as Any? ?? NSNull()]
        }
        guard state.update(payload, frameType: frameType) else { return ["accepted": false] }
        switch payload[0] {
        case 0x21:
            return ["accepted": true, "threshold": state.threshold as Any? ?? NSNull()]
        case 0x23, 0x25:
            var result: [String: Any] = ["accepted": true, "available": state.available as Any? ?? NSNull()]
            if state.includesThreshold { result["noticeNecessary"] = state.noticeNecessary as Any? ?? NSNull() }
            return result
        default:
            return ["accepted": true, "enabled": state.enabled as Any? ?? NSNull()]
        }
    case "power.switch":
        let inquiry = UInt8(input["inquiry"] as! Int)
        var state = SonyPowerSwitch(inquiryType: inquiry)
        if let query = input["query"] as? Int {
            return ["payload": apkHex(state.queryPayloads.first { $0[0] == UInt8(query) }!)]
        }
        if let setting {
            state.update([0x23, inquiry, 0], frameType: frameType)
            state.update([0x27, inquiry, 1], frameType: frameType)
            return ["payload": state.setPayload(enabled: setting).map(apkHex) as Any? ?? NSNull()]
        }
        guard state.update(payload, frameType: frameType) else { return ["accepted": false] }
        if payload[0] == 0x23 || payload[0] == 0x25 {
            return ["accepted": true, "available": state.available as Any? ?? NSNull()]
        }
        return ["accepted": true, "enabled": state.enabled as Any? ?? NSNull()]
    case "power.standby":
        var state = SonyAutoStandby()
        if let query = input["query"] as? Int {
            return ["payload": apkHex(state.queryPayloads.first { $0[0] == UInt8(query) }!)]
        }
        if let setting {
            state.update([0x21, 0, 0], frameType: frameType)
            state.update([0x23, 0, 0], frameType: frameType)
            state.update([0x27, 0, 1], frameType: frameType)
            return ["payload": state.setPayload(enabled: setting).map(apkHex) as Any? ?? NSNull()]
        }
        guard state.update(payload, frameType: frameType) else { return ["accepted": false] }
        switch payload[0] {
        case 0x21:
            return ["accepted": true, "candidate": state.candidate as Any? ?? NSNull()]
        case 0x23, 0x25:
            return ["accepted": true, "available": state.available as Any? ?? NSNull()]
        default:
            return ["accepted": true, "enabled": state.enabled as Any? ?? NSNull()]
        }
    case "power.save":
        var state = SonyAutoPowerSave()
        if setting != nil || input["cancel"] as? Bool == true {
            state.update([0x21, 0x0B, 20, 0, 0], frameType: frameType)
            state.update([0x27, 0x0B, 0, 0], frameType: frameType)
            let result = setting.map { state.setPayload(enabled: $0) } ?? state.cancelEffectPayload
            return ["payload": result.map(apkHex) as Any? ?? NSNull()]
        }
        guard state.update(payload, frameType: frameType) else { return ["accepted": false] }
        if payload[0] == 0x21 {
            return ["accepted": true, "threshold": state.threshold as Any? ?? NSNull(),
                    "affectedFunctions": state.affectedFunctions, "affectedFunctions2": state.affectedFunctions2]
        }
        return ["accepted": true, "enabled": state.enabled as Any? ?? NSNull(),
                "effectActive": state.effectActive as Any? ?? NSNull()]
    case "power.autoOff":
        let generation: SonyProtocolInfo.Generation = input["generation"] as! Int == 1 ? .v1 : .v2
        let inquiry = UInt8(input["inquiry"] as! Int)
        var state = SonyAutomaticPowerOffState(inquiryType: inquiry, generation: generation)
        if let selected = input["selected"] as? Int {
            let options = (input["options"] as! [Int]).map(UInt8.init)
            let last = UInt8(input["last"] as! Int)
            state.update([generation == .v1 ? 0xF1 : 0x21, inquiry, UInt8(options.count)] + options)
            state.update([generation == .v1 ? 0xF3 : 0x23, inquiry, 0])
            state.update((generation == .v1 ? [0xF7, inquiry, 1] : [0x27, inquiry]) + [0x11, last])
            return ["payload": state.setPayload(SonyAutomaticPowerOffOption(rawValue: UInt8(selected))).map(apkHex) as Any? ?? NSNull()]
        }
        guard state.update(payload) else { return ["accepted": false] }
        switch payload[0] {
        case 0xF1, 0x21:
            return ["accepted": true, "options": state.options?.map(\.rawValue) as Any? ?? NSNull()]
        case 0xF3, 0xF5, 0x23, 0x25:
            return ["accepted": true, "available": state.available as Any? ?? NSNull()]
        default:
            return ["accepted": true, "current": state.current?.rawValue as Any? ?? NSNull(),
                    "last": state.last?.rawValue as Any? ?? NSNull()]
        }
    default:
        throw APKInputError.invalid("Unknown power operation")
    }
}
