enum SonyCommonConnection: Equatable, Sendable {
    enum RequestType: UInt8, Sendable {
        case underConfirmation = 0x00, execute = 0x01
    }

    case reconnectionRequest(requestType: RequestType, address: String)
    case releaseGATT

    static func parse(_ payload: [UInt8], supportedFunctions: Set<UInt8>) -> Self? {
        guard payload.count >= 2, payload[0] == 0x19 else { return nil }
        switch payload[1] {
        case 0x08:
            guard supportedFunctions.contains(0x1A), payload.count == 20,
                  let requestType = RequestType(rawValue: payload[2]),
                  payload[3...].enumerated().allSatisfy({ index, byte in
                      index % 3 == 2 ? byte == 0x3A
                          : (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
                  }) else { return nil }
            return .reconnectionRequest(requestType: requestType, address: String(decoding: payload[3...], as: UTF8.self).uppercased())
        case 0x0A:
            guard supportedFunctions.contains(0x1C), payload.count == 2 else { return nil }
            return .releaseGATT
        default:
            return nil
        }
    }
}
