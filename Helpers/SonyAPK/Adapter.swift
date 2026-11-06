import Foundation

enum APKInputError: Error {
    case invalid(String)
}

func apkBytes(_ input: Any?) throws -> [UInt8] {
    guard let text = input as? String, text.count.isMultiple(of: 2) else {
        throw APKInputError.invalid("Expected an even-length hex string")
    }
    var result: [UInt8] = []
    var offset = text.startIndex
    while offset < text.endIndex {
        let end = text.index(offset, offsetBy: 2)
        guard let byte = UInt8(text[offset..<end], radix: 16) else {
            throw APKInputError.invalid("Invalid hex byte")
        }
        result.append(byte)
        offset = end
    }
    return result
}

func apkHex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func framingAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard let op = input["op"] as? String, op.hasPrefix("frame.") else { return nil }
    let type = UInt8(input["type"] as! Int)
    if op == "frame.ackRequired" {
        return ["required": SonyFrame(type: type, sequence: 0, payload: []).requiresAcknowledgment]
    }
    let sequence = UInt8(input["sequence"] as! Int)
    let payload = try apkBytes(input["payload"])
    let encoded = SonyFrameCodec.encode(type: type, sequence: sequence, payload: payload)
    let expected = SonyFrame(type: type, sequence: sequence, payload: payload)
    guard SonyFrameCodec.decode(encoded) == expected else {
        throw APKInputError.invalid("Production frame round-trip failed")
    }
    for chunkSize in [1, 2, 7, encoded.count] {
        var stream = SonyFrameStream()
        var frames: [SonyFrame] = []
        for offset in stride(from: 0, to: encoded.count, by: chunkSize) {
            frames += stream.append(encoded.subdata(in: offset..<min(offset + chunkSize, encoded.count)))
        }
        guard frames == [expected] else { throw APKInputError.invalid("Fragmented frame failed") }
    }
    return ["encoded": apkHex(encoded)]
}

@main
struct SonyAPKAdapter {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let requests = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
        let results = try requests.map { request -> [String: Any] in
            let arguments = request["swift"] as! [String: Any]
            let legacy = try framingAPK(arguments) ?? legacyFeaturesAPK(arguments) ?? legacyNoiseAPK(arguments) ?? legacyAPK(arguments)
            let modern = try legacy ?? modernPlaybackAPK(arguments) ?? modernNoiseAPK(arguments) ?? commonConnectionAPK(arguments) ?? connectionIdentityAPK(arguments) ?? modernAPK(arguments) ?? queueAPK(arguments)
            guard let value = try modern ?? batteryAPK(arguments) ?? equalizerAPK(arguments) ?? powerAPK(arguments) ?? legacyIndicatorsAPK(arguments) else {
                throw APKInputError.invalid("Unknown adapter operation: \(arguments)")
            }
            return ["id": request["id"]!, "value": value]
        }
        let output = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
