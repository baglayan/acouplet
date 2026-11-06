import Foundation

func equalizerAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("equalizer.") else { return nil }
    let generation: SonyProtocolInfo.Generation = input["generation"] as! Int == 1 ? .v1 : .v2
    let function = UInt8(input["function"] as! Int)
    var state = SonyEqualizer(supportedFunctions: [function], generation: generation)
    for payload in input["setup"] as? [[Int]] ?? [] {
        precondition(state.update(payload.map(UInt8.init)))
    }
    if operation == "equalizer.presetSet" {
        return ["payload": apkHex(state.presetPayload(UInt8(input["preset"] as! Int))!)]
    }
    if operation == "equalizer.settingsSet" {
        let flat = state.flatSettings!
        let settings = EqualizerSettings(layout: flat.layout, levelSteps: flat.levelSteps, values: input["values"] as! [Int])
        return ["payload": apkHex(state.settingsPayload(settings)!)]
    }
    if operation == "equalizer.layout" {
        let settings = state.settings!
        let range = settings.levelRange!
        let bands = settings.layout.map { band -> [String: Any] in
            let type = band == .clearBass ? "CLEAR_BASS" : band.informationType == 1 ? "HZ" : band.informationType == 2 ? "KHZ" : "NO_INFORMATION"
            return ["type": type, "value": Int(band.value)]
        }
        return ["payload": apkHex(state.settingsPayload(settings)!), "bandCount": settings.layout.count,
                "bands": bands,
                "rawValues": state.rawValues!.map(Int.init), "values": settings.values,
                "clearBassIndex": settings.layout.firstIndex(of: .clearBass) ?? -1,
                "range": [range.lowerBound, range.upperBound]]
    }
    guard state.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
    switch operation {
    case "equalizer.capability":
        let capability = state.capabilities!
        return ["accepted": true, "bandCount": Int(capability.bandCount), "levelSteps": Int(capability.levelSteps),
                "ultAdditionalSteps": capability.ultAdditionalSteps.map { Int($0) } as Any? ?? NSNull(),
                "presets": capability.presets.map { ["id": Int($0.id), "name": $0.name as Any? ?? NSNull()] }]
    case "equalizer.bands":
        return ["accepted": true, "bands": state.bandInformation!.map { ["type": Int($0.informationType), "value": Int($0.value)] }]
    case "equalizer.status":
        return ["accepted": true, "available": state.available as Any? ?? NSNull(),
                "errors": state.errorCodes.map { $0.map(Int.init) } as Any? ?? NSNull()]
    case "equalizer.parameter":
        return ["accepted": true, "preset": state.presetID.map { Int($0) } as Any? ?? NSNull(),
                "values": state.rawValues.map { $0.map(Int.init) } as Any? ?? NSNull()]
    default:
        throw APKInputError.invalid("Unknown equalizer operation")
    }
}
