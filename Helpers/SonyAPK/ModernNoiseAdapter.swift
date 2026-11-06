import Foundation

func modernNoiseAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("modernNoise.") else { return nil }
    let function = UInt8(input["function"] as! Int)
    if operation.hasPrefix("modernNoise.test") {
        var state = SonyNoiseTest()
        if operation == "modernNoise.testRead" { return ["payload": apkHex(state.queryPayload)] }
        if operation == "modernNoise.testSet" {
            state.update([0x63, 0x40, 1])
            return ["payload": apkHex(state.setPayload(start: input["start"] as! Bool)!)]
        }
        guard state.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
        return ["active": state.active as Any? ?? NSNull()]
    }
    if function == 0x69 {
        var state = SonyNoiseToggle()
        if operation == "modernNoise.read" { return ["payload": apkHex(state.queryPayloads[input["index"] as! Int])] }
        if operation == "modernNoise.toggleSet" {
            state.update([0x61, 0x30, 0])
            state.update([0x63, 0x30, 0])
            state.update([0x67, 0x30, 1])
            return state.setPayload(UInt8(input["value"] as! Int)).map { ["payload": apkHex($0)] } ?? ["accepted": false]
        }
        guard state.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
        switch operation {
        case "modernNoise.toggleCapability":
            guard let key = state.key, let options = state.options else { return ["accepted": false] }
            return ["key": Int(key), "options": options.map(Int.init)]
        case "modernNoise.toggleState":
            guard let selected = state.selected else { return ["accepted": false] }
            return ["selected": Int(selected)]
        case "modernNoise.available":
            return ["available": state.available as Any? ?? NSNull()]
        default:
            throw APKInputError.invalid("Unknown modern noise toggle operation")
        }
    }
    var state = SonyNoiseControl(inquiryType: SonyNoiseControl.inquiryType(forFunction: function)!)
    let inquiry = state.inquiryType
    if operation == "modernNoise.read" { return ["payload": apkHex(state.queryPayloads[input["index"] as! Int])] }
    let payload = try apkBytes(input["payload"])
    if operation == "modernNoise.set" {
        state.update([0x61, inquiry] + (inquiry == 1 ? [] : [0x11, 0x12].contains(inquiry) ? [2, 0, 1] : [2, 0, 0, 255, 1, 1, 0, 255, 1]))
        state.update([0x63, inquiry, 0])
        state.update(payload)
        return state.setPayload(mode: (input["mode"] as? String).flatMap(NoiseControlMode.init(rawValue:)),
                                ambientLevel: input["ambientLevel"] as? Int,
                                focusOnVoice: input["focusOnVoice"] as? Bool,
                                noiseCancellingSS: input["noiseCancellingSS"] as? Bool)
            .map { ["payload": apkHex($0)] } ?? ["accepted": false]
    }
    guard state.update(payload) else { return ["accepted": false] }
    switch operation {
    case "modernNoise.capability":
        guard let capabilities = state.capabilities else { return ["accepted": false] }
        return ["records": capabilities.values.sorted { $0.ambientMode < $1.ambientMode }.map {
            ["mode": Int($0.ambientMode), "minimum": $0.minimum, "maximum": $0.maximum, "step": $0.step]
        }]
    case "modernNoise.available":
        return ["available": state.available as Any? ?? NSNull()]
    case "modernNoise.autoMode":
        guard let value = state.state else { return ["accepted": false] }
        return ["mode": value.mode?.rawValue as Any? ?? NSNull()]
    case "modernNoise.state":
        guard let value = state.state else { return ["accepted": false] }
        return ["payload": apkHex(value.payload), "effectEnabled": value.effectEnabled,
                "ambientMode": Int(value.ambientMode), "ambientLevel": value.ambientLevel,
                "noiseValue": value.noiseValue.map { Int($0) } as Any? ?? NSNull(),
                "ncAsmMode": Int(value.ncAsmMode), "noiseCancellingSS": value.isNoiseCancellingSS]
    default:
        throw APKInputError.invalid("Unknown modern noise operation")
    }
}
