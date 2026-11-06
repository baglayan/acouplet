import Foundation

func commonConnectionAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard input["op"] as? String == "commonConnection.parse" else { return nil }
    let payload = try apkBytes(input["payload"])
    let functions = Set((input["functions"] as! [Int]).map { UInt8($0) })
    guard let event = SonyCommonConnection.parse(payload, supportedFunctions: functions) else {
        return ["accepted": false]
    }
    switch event {
    case let .reconnectionRequest(requestType, address):
        return ["requestType": Int(requestType.rawValue), "address": address]
    case .releaseGATT:
        return ["event": "CommonNotifyParamDisconnectGattRequest"]
    }
}
