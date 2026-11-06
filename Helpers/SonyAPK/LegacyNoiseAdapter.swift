import Foundation

func legacyNoiseAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("legacy.noise.") else { return nil }
    let kind = UInt8(input["kind"] as! Int)
    if operation == "legacy.noise.query" {
        let controls = SonyLegacyControls(supportPayload: [7, 0, 1, 0x60 + kind])!
        return ["payload": apkHex(controls.noiseQueries[input["query"] as! Int])]
    }
    if operation == "legacy.noise.set" {
        var controls = SonyLegacyControls(supportPayload: [7, 0, 1, 0x60 + kind])!
        controls.update(try apkBytes(input["capability"]))
        controls.update([0x63, kind, 0])
        controls.update(try apkBytes(input["state"]))
        let payload: [UInt8]?
        if kind == 2 {
            payload = controls.noiseControlPayload(mode: NoiseControlMode(rawValue: input["mode"] as! String)!,
                                                  ambientLevel: input["level"] as! Int, focusOnVoice: input["voice"] as! Bool)
        } else {
            let model = kind == 1 ? controls.standaloneNoiseCancel : controls.standaloneAmbient
            payload = model?.setPayload(enabled: input["enabled"] as! Bool, focusOnVoice: input["voice"] as? Bool)
        }
        return ["payload": payload.map { apkHex($0) } as Any? ?? NSNull()]
    }
    let payload = try apkBytes(input["payload"])
    if operation == "legacy.noise.capability" {
        guard let value = SonyLegacyNoiseCapability(payload: payload) else { return ["accepted": false] }
        return ["accepted": true, "inquiry": value.inquiryType, "noiseType": value.noiseType,
                "noiseSteps": value.noiseSteps, "ambientType": value.ambientType,
                "ambientSteps": value.ambientSteps.sorted { $0.key < $1.key }.map { [Int($0.key), Int($0.value)] },
                "supported": value.supportsModes]
    }
    if operation == "legacy.noise.parameter" {
        guard let value = SonyLegacyNoiseState(payload: payload) else { return ["accepted": false] }
        return ["accepted": true, "payload": apkHex([payload[0]] + value.payload.dropFirst())]
    }
    if operation == "legacy.noise.status" {
        var controls = SonyLegacyControls(supportPayload: [7, 0, 1, 0x60 + kind])!
        guard controls.update(payload) else { return ["accepted": false] }
        let available = kind == 2 ? controls.noiseAvailable
            : (kind == 1 ? controls.standaloneNoiseCancel?.available : controls.standaloneAmbient?.available)
        return ["accepted": true, "available": available as Any? ?? NSNull()]
    }
    throw APKInputError.invalid("Unknown legacy noise operation")
}
