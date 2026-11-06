import Foundation

private func batteryReading(_ reading: BatteryReading?) -> Any {
    guard let reading else { return NSNull() }
    return ["level": reading.level, "charging": Int(reading.chargingState.rawValue),
            "threshold": reading.lowBatteryThreshold as Any? ?? NSNull()]
}

func batteryAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("battery.") else { return nil }
    if operation == "battery.caseThresholdDecision" {
        let reading = BatteryReading(level: UInt8(input["level"] as! Int), charging: UInt8(input["charging"] as! Int),
                                     lowBatteryThreshold: (input["threshold"] as? Int).map(UInt8.init))!
        return ["belowThreshold": reading.isBelowLowBatteryThreshold as Any? ?? NSNull()]
    }
    let payload = try apkBytes(input["payload"])
    let batteries: SonyBatteries
    if operation == "battery.legacy" {
        var controls = SonyLegacyControls(supportPayload: [7, 0, 3, 0x11, 0x15, 0x18])!
        guard controls.update(payload) else { return ["accepted": false] }
        batteries = controls.batteries
    } else if operation == "battery.modern" {
        var state = SonyBatteries()
        guard state.update(payload) else { return ["accepted": false] }
        batteries = state
    } else {
        throw APKInputError.invalid("Unknown battery operation")
    }
    switch payload[1] {
    case 0, 8:
        return ["accepted": true, "single": batteryReading(batteries.single)]
    case 1, 9:
        return ["accepted": true, "left": batteryReading(batteries.left), "right": batteryReading(batteries.right)]
    case 2, 10:
        return ["accepted": true, "case": batteryReading(batteries.caseBattery)]
    default:
        throw APKInputError.invalid("Unknown battery inquiry")
    }
}
