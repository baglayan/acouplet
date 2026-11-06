import Foundation

func connectionIdentityAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let operation = input["op"] as? String, operation.hasPrefix("connectionIdentity.") else { return nil }
    let frameType = UInt8(input["frameType"] as! Int)
    let functions = Set((input["functions"] as! [Int]).map { UInt8($0) })
    let functions2 = Set((input["functions2"] as! [Int]).map { UInt8($0) })
    if operation == "connectionIdentity.queries" {
        return ["payloads": SonyConnectionIdentity.queryPayloads(frameType: frameType, supportedFunctions: functions,
                                                                supportedFunctions2: functions2).map(apkHex).sorted()]
    }
    guard operation == "connectionIdentity.parse" else { throw APKInputError.invalid("Unknown connection identity operation") }
    guard let identity = SonyConnectionIdentity(payload: try apkBytes(input["payload"]), frameType: frameType,
                                               supportedFunctions: functions, supportedFunctions2: functions2) else {
        return ["accepted": false]
    }
    return ["accepted": true, "queryPayload": apkHex(identity.queryPayload), "addresses": identity.addresses.sorted()]
}
