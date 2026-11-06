import Foundation

private enum LegacyAPKError: Error {
    case invalidInput
}

private func legacyHex(_ bytes: [UInt8]?) -> Any {
    bytes.map { apkHex($0) } ?? NSNull() as Any
}

private func legacyValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

func legacyAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("legacy.") else { return nil }
    if ["legacy.metadata", "legacy.boolean", "legacy.available", "legacy.set"].contains(operation) {
        let identity = try apkBytes(input[operation == "legacy.metadata" ? "payload" : "identity"])
        var system = SonySystemFeatures(legacyGeneralSettings: [0xD1, 0xD2, 0xD3])
        let identified = system.update(identity)
        if operation == "legacy.metadata" {
            guard identified else { return ["accepted": false] }
            return ["accepted": true, "multipoint": system.multipointSlot != nil, "sidetone": system.sidetoneSlot != nil]
        }
        if operation == "legacy.set" {
            guard let enabled = input["enabled"] as? Bool, identity.count > 1 else { throw LegacyAPKError.invalidInput }
            system.update([0xD3, identity[1], 0])
            system.update([0xD7, identity[1], 1, 0])
            return ["payload": legacyHex(system.multipointSetPayload(enabled: enabled) ?? system.sidetoneSetPayload(enabled: enabled))]
        }
        let accepted = system.update(try apkBytes(input["payload"]))
        guard accepted else { return ["accepted": false] }
        let state = system.multipoint ?? system.sidetone
        return operation == "legacy.boolean" ? ["accepted": true, "enabled": legacyValue(state?.enabled)]
            : ["accepted": true, "available": legacyValue(state?.available)]
    }
    if operation == "legacy.inventory" {
        var multipoint = SonyMultipoint(legacySupportedFunctions: [0x38])
        guard multipoint.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
        return ["accepted": true, "devices": multipoint.devices.map {
            ["address": $0.address, "name": $0.name, "connectionID": Int($0.connectionID)] as [String: Any]
        }]
    }
    if operation == "legacy.functions" {
        guard let controls = SonyLegacyControls(supportPayload: try apkBytes(input["payload"])) else { return ["accepted": false] }
        return ["accepted": true, "functions": controls.supportedFunctions.sorted().map(Int.init)]
    }
    if operation.hasPrefix("legacy.playback") {
        var playback = SonyPlayback(supportedFunctions: [0xA1], generation: .v1)
        playback.update([0xA1, 1, 255, 1, 1])
        playback.update([0xA3, 1, 0, 1])
        playback.update([0xA7, 1, 0x20, 0])
        if operation == "legacy.playbackSet" {
            guard let value = input["value"] as? Int else { throw LegacyAPKError.invalidInput }
            return ["payload": legacyHex(playback.volumePayload(value))]
        }
        guard playback.update(try apkBytes(input["payload"])) else { return ["accepted": false] }
        switch operation {
        case "legacy.playbackCapability":
            return ["accepted": true, "minimum": legacyValue(playback.musicVolumeRange?.lowerBound),
                    "maximum": legacyValue(playback.musicVolumeRange?.upperBound)]
        case "legacy.playbackVolume":
            return ["accepted": true, "volume": legacyValue(playback.volume)]
        case "legacy.playbackStatus":
            return ["accepted": true, "available": legacyValue(playback.available), "state": legacyValue(playback.state?.rawValue)]
        default: throw LegacyAPKError.invalidInput
        }
    }
    return nil
}
