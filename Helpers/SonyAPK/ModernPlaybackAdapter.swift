import Foundation

func modernPlaybackAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("modernPlayback.") else { return nil }
    let function = UInt8(input["function"] as! Int)
    var state = SonyPlayback(supportedFunctions: [function])
    if operation == "modernPlayback.read" {
        let index = input["index"] as! Int
        return ["payload": apkHex(state.queryPayloads[index])]
    }
    if operation == "modernPlayback.set" {
        let inquiry = state.playbackInquiryType
        let isCall = input["call"] as? Bool ?? false
        state.update([0xA1, inquiry, 255] + (state.supportsCallVolume ? [255] : []))
        state.update([0xA3, inquiry, 0, 1] + (state.supportsCallVolume ? [isCall ? 1 : 0] : [])
            + (inquiry == 1 ? [] : [0]))
        let volumeInquiry = isCall ? state.callVolumeQueryPayload![1] : state.musicVolumeQueryPayload[1]
        state.update([0xA7, volumeInquiry, 0] + (state.supportsMute ? [1] : []))
        let payload: [UInt8]?
        if let command = input["command"] as? Int {
            payload = state.commandPayload(SonyPlaybackCommand(rawValue: UInt8(command))!)
        } else {
            let value = input["value"] as! Int
            payload = isCall ? state.callVolumePayload(value) : state.volumePayload(value)
        }
        return payload.map { ["payload": apkHex($0)] } ?? ["accepted": false]
    }
    let payload = try apkBytes(input["payload"])
    if operation == "modernPlayback.volume" {
        state.update([0xA1, state.playbackInquiryType, 255] + (state.supportsCallVolume ? [255] : []))
    }
    guard state.update(payload) else { return ["accepted": false] }
    switch operation {
    case "modernPlayback.capability":
        return ["musicSteps": state.musicVolumeRange!.upperBound + 1,
                "callSteps": state.callVolumeRange.map { $0.upperBound + 1 } as Any? ?? NSNull()]
    case "modernPlayback.status":
        return ["available": state.available as Any? ?? NSNull(), "state": state.state.map { Int($0.rawValue) } as Any? ?? NSNull(),
                "musicCall": state.musicCallStatus.map { Int($0) } as Any? ?? NSNull(),
                "controlAvailable": state.playbackControlAvailable as Any? ?? NSNull()]
    case "modernPlayback.volume":
        let isCall = payload[1] == state.callVolumeQueryPayload?[1]
        return ["volume": (isCall ? state.callVolume : state.volume) as Any? ?? NSNull(),
                "muted": (isCall ? state.callMuted : state.musicMuted) as Any? ?? NSNull()]
    case "modernPlayback.track":
        return ["names": [state.track!.title, state.track!.album, state.track!.artist, state.track!.genre].map { $0 as Any? ?? NSNull() }]
    default:
        throw APKInputError.invalid("Unknown modern playback operation")
    }
}
