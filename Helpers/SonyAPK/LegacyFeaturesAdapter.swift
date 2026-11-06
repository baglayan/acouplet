import Foundation

private func legacyFeatureValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

func legacyFeaturesAPK(_ input: [String: Any]) throws -> [String: Any]? {
    if let result = try legacyOptimizerAPK(input) { return result }
    guard let operation = input["op"] as? String, operation.hasPrefix("legacy.features."),
          let kind = input["kind"] as? Int else { return nil }
    if operation.hasPrefix("legacy.features.sound") {
        var effect = SonyLegacySoundEffect(kind: kind == 1 ? .surround : .soundPosition, supportedFunctions: [0x41, 0x42])
        if operation == "legacy.features.soundSet" {
            let presets = kind == 1 ? Array(UInt8(0)...15) : [0, 1, 2, 3, 0x11, 0x12]
            let capability: [UInt8] = kind == 1 ? [0x41, 1, UInt8(presets.count)] + presets.flatMap { [$0, 0] } : [0x41, 2, 1]
            effect.update(capability)
            effect.update([0x43, UInt8(kind), 0])
            effect.update([0x47, UInt8(kind), 0])
            let preset = UInt8(input["preset"] as! Int)
            return ["payload": legacyFeatureValue(effect.setPayload(preset).map { apkHex($0) })]
        }
        guard effect.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
        switch operation {
        case "legacy.features.soundCapability":
            if kind == 2 { return ["accepted": true, "positionType": legacyFeatureValue(effect.positionType)] }
            var result: [String: Any] = ["accepted": true, "presets": effect.presets!.map { Int($0.id) }]
            if input["names"] as? Bool == true { result["names"] = effect.presets!.map(\.name) }
            return result
        case "legacy.features.soundStatus": return ["accepted": true, "available": legacyFeatureValue(effect.available)]
        case "legacy.features.soundParameter": return ["accepted": true, "preset": legacyFeatureValue(effect.presetID)]
        default: throw APKInputError.invalid("Unknown legacy sound operation")
        }
    }
    var controls = SonyLegacyControls(supportPayload: [7, 0, 2, 0xE1, 0xE2])!
    if operation == "legacy.features.audioSet" {
        controls.update(kind == 1 ? [0xE1, 1, 0] : [0xE1, 2, 0, 0])
        controls.update([0xE3, UInt8(kind), 0])
        controls.update([0xE7, UInt8(kind), 0, 0])
        let value = UInt8(input["value"] as! Int)
        let payload = kind == 1 ? controls.connectionQuality.setPayload(SonyConnectionMode(rawValue: value))
            : controls.dsee.setPayload(SonyDSEEMode(rawValue: value))
        return ["payload": legacyFeatureValue(payload.map { apkHex($0) })]
    }
    guard controls.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
    switch operation {
    case "legacy.features.audioCapability":
        if kind == 1 { return ["accepted": true, "settingType": legacyFeatureValue(controls.connectionQuality.settingType)] }
        return ["accepted": true, "settingType": legacyFeatureValue(controls.dsee.settingType), "upscalingType": legacyFeatureValue(controls.dsee.rawType)]
    case "legacy.features.audioStatus":
        return ["accepted": true, "available": legacyFeatureValue(kind == 1 ? controls.connectionQuality.available : controls.dsee.available)]
    case "legacy.features.audioParameter":
        return ["accepted": true, "mode": legacyFeatureValue(kind == 1 ? controls.connectionQuality.mode?.sonyValue : controls.dsee.mode?.sonyValue)]
    default: throw APKInputError.invalid("Unknown legacy audio operation")
    }
}
