import Foundation

func queueAPK(_ input: [String: Any]) throws -> [String: Any]? {
    guard input["op"] as? String == "queue.ack" else { return nil }
    guard let commands = input["commands"] as? [[String: Any]],
          let acknowledgments = input["acknowledgments"] as? [Int],
          acknowledgments.allSatisfy({ UInt8(exactly: $0) != nil }) else {
        throw APKInputError.invalid("Expected commands and byte-valued acknowledgments")
    }
    var queue = SonyCommandQueue()
    var transmitted: [SonyFrame] = []
    var accepted: [Bool] = []
    for command in commands {
        guard let value = command["type"] as? Int, let type = UInt8(exactly: value),
              let payload = command["payload"] as? [Int],
              payload.allSatisfy({ UInt8(exactly: $0) != nil }) else {
            throw APKInputError.invalid("Expected a byte-valued command type and payload")
        }
        if let frame = queue.enqueue(payload: payload.map(UInt8.init), type: type) {
            transmitted.append(frame)
        }
    }
    for sequence in acknowledgments {
        let result = queue.handleAcknowledgment(sequence: UInt8(sequence))
        accepted.append(result.accepted)
        if let frame = result.nextFrame { transmitted.append(frame) }
    }
    let frameValue: (SonyFrame) -> [String: Any] = {
        ["type": Int($0.type), "sequence": Int($0.sequence), "payload": $0.payload.map(Int.init)]
    }
    return ["transmitted": transmitted.map(frameValue), "accepted": accepted,
            "pending": queue.pending.map { frameValue($0) as Any } ?? NSNull()]
}
