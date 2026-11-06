import Foundation

private func legacyIndicatorValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

func legacyIndicatorsAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("legacy.indicators") else { return nil }
    let functions = Set((input["functions"] as? [Int] ?? [0x12, 0x13, 0x17]).map { UInt8($0) })
    var indicators = SonyLegacyIndicators(supportedFunctions: functions)
    if operation == "legacy.indicatorsQueries" {
        return ["codec": indicators.supportsCodecStatus, "upscaling": indicators.supportsUpscalingStatus,
                "connection": indicators.supportsConnectionStatus, "payloads": indicators.queryPayloads.map(apkHex)]
    }
    guard indicators.update(try apkBytes(input["payload"]), frameType: UInt8(input["frameType"] as? Int ?? 0x0C)) else {
        return ["accepted": false]
    }
    switch operation {
    case "legacy.indicatorsCodec":
        let name: String
        switch indicators.codec! {
        case .unsettled: name = "UNSETTLED"
        case .sbc: name = "SBC"
        case .aac: name = "AAC"
        case .ldac: name = "LDAC"
        case .aptX: name = "APT_X"
        case .aptXHD: name = "APT_X_HD"
        case .other: name = "OTHER"
        case .unknown: name = "UNKNOWN"
        case .lc3: name = "LC3"
        }
        return ["accepted": true, "codecValue": Int(indicators.codecValue!), "codec": name]
    case "legacy.indicatorsUpscaling":
        return ["accepted": true, "typeValue": Int(indicators.upscalingTypeValue!),
                "statusValue": Int(indicators.upscalingStatusValue!),
                "type": legacyIndicatorValue(indicators.upscalingType?.rawValue),
                "status": legacyIndicatorValue(indicators.upscalingStatus?.rawValue)]
    case "legacy.indicatorsConnection":
        return ["accepted": true, "leftValue": Int(indicators.leftConnectionValue!),
                "rightValue": Int(indicators.rightConnectionValue!),
                "leftConnected": legacyIndicatorValue(indicators.leftConnected),
                "rightConnected": legacyIndicatorValue(indicators.rightConnected)]
    default:
        throw APKInputError.invalid("Unknown legacy indicator operation")
    }
}
