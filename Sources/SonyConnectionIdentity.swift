struct SonyConnectionIdentity: Equatable, Sendable {
    let queryPayload: [UInt8]
    let addresses: Set<String>

    static func queryPayloads(frameType: UInt8, supportedFunctions: Set<UInt8>, supportedFunctions2: Set<UInt8>) -> [[UInt8]] {
        if frameType == 0x0E { return supportedFunctions2.contains(0x64) ? [[0x60, 0x04]] : [] }
        guard frameType == 0x0C else { return [] }
        return [(UInt8(0x19), [UInt8(0x10), 0x07]), (0x40, [0x40, 0x00]), (0x41, [0x40, 0x01])]
            .compactMap { function, query in supportedFunctions.contains(function) ? query : nil }
    }

    init?(payload: [UInt8], frameType: UInt8, supportedFunctions: Set<UInt8>, supportedFunctions2: Set<UInt8>) {
        guard payload.count >= 2 else { return nil }
        let query = [payload[0] &- 1, payload[1]]
        guard Self.queryPayloads(frameType: frameType, supportedFunctions: supportedFunctions,
                                supportedFunctions2: supportedFunctions2).contains(query) else { return nil }
        let fieldCount = query == [0x40, 0x00] ? 3 : 2
        guard payload.count == 2 + fieldCount * 17 else { return nil }
        var parsed: [String] = []
        for offset in stride(from: 2, to: payload.count, by: 17) {
            let bytes = payload[offset..<(offset + 17)]
            guard bytes.enumerated().allSatisfy({ index, byte in
                index % 3 == 2 ? byte == 0x3A
                    : (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
            }) else { return nil }
            parsed.append(String(decoding: bytes, as: UTF8.self).uppercased())
        }
        queryPayload = query
        addresses = Set(query == [0x10, 0x07] ? Array(parsed.dropFirst()) : parsed)
    }
}
