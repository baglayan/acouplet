import Foundation

private func legacyOptimizerValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

func legacyOptimizerAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("legacy.optimizer") else { return nil }
    if operation == "legacy.optimizerSet" {
        return ["payload": apkHex(input["control"] as! String == "START" ? SonyLegacyOptimizer.startPayload : SonyLegacyOptimizer.cancelPayload)]
    }
    if operation == "legacy.optimizerQuery" {
        return ["payload": apkHex(input["query"] as! String == "status" ? SonyLegacyOptimizer.statusQuery : SonyLegacyOptimizer.measurementsQuery)]
    }
    var optimizer = SonyLegacyOptimizer(supportedFunctions: input["supported"] as? Bool == false ? [] : [0x81])
    if operation == "legacy.optimizerStatus" {
        optimizer.update([0x81, 1, 5, 1, 3, 1, 4])
    }
    if operation == "legacy.optimizerMeasurements" {
        optimizer.update(try apkBytes(input["capability"]))
    }
    guard optimizer.update(try apkBytes(input["payload"]), frameType: UInt8(input["frameType"] as? Int ?? 0x0C)) else {
        return ["accepted": false]
    }
    switch operation {
    case "legacy.optimizerCapability":
        let capability = optimizer.capability!
        return ["accepted": true, "optimizationSeconds": Int(capability.optimizationSeconds),
                "personalType": Int(capability.personalType), "personalSeconds": Int(capability.personalSeconds),
                "pressureType": Int(capability.pressureType), "pressureSeconds": Int(capability.pressureSeconds),
                "recognized": capability.isRecognized]
    case "legacy.optimizerStatus":
        let status = optimizer.status!
        return ["accepted": true, "availability": Int(status.availability), "available": legacyOptimizerValue(status.available),
                "phaseValue": Int(status.phaseValue), "phase": legacyOptimizerValue(status.phase?.rawValue),
                "active": legacyOptimizerValue(status.phase?.isActive), "canStart": optimizer.canStart]
    case "legacy.optimizerMeasurements":
        let measurements = optimizer.measurements!
        return ["accepted": true, "personalType": Int(measurements.personalType), "personalValue": Int(measurements.personalValue),
                "pressureType": Int(measurements.pressureType), "pressureValue": Int(measurements.pressureValue),
                "personalMeasured": legacyOptimizerValue(measurements.personalMeasured),
                "pressureAtmospheres": legacyOptimizerValue(measurements.pressureAtmospheres)]
    default:
        throw APKInputError.invalid("Unknown legacy optimizer operation")
    }
}
