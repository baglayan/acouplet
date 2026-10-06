import Foundation

struct FastPairMessage: Equatable, Sendable {
    static let maximumPayloadLength = Int(UInt16.max)

    let group: UInt8
    let code: UInt8
    let payload: [UInt8]

    var encoded: Data? {
        guard payload.count <= Self.maximumPayloadLength else { return nil }
        return Data([group, code, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload)
    }
}

struct FastPairMessageStream: Sendable {
    private var buffer: [UInt8] = []
    private var frameLength = 4

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data, receive: (FastPairMessage) -> Void) {
        for byte in data {
            buffer.append(byte)
            if buffer.count == 4 {
                frameLength = 4 + (Int(buffer[2]) << 8) + Int(buffer[3])
            }
            if buffer.count == frameLength {
                let message = FastPairMessage(group: buffer[0], code: buffer[1], payload: Array(buffer.dropFirst(4)))
                reset()
                receive(message)
            }
        }
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        frameLength = 4
    }
}

enum FastPairRingTarget: UInt8, Sendable {
    case right = 0x01
    case left = 0x02
}

struct FastPairRingCommand: Equatable, Sendable {
    let message: FastPairMessage

    private init(payload: [UInt8]) {
        message = FastPairMessage(group: 0x04, code: 0x01, payload: payload)
    }

    static func ring(_ target: FastPairRingTarget, timeoutSeconds: UInt8) -> Self? {
        guard timeoutSeconds > 0 else { return nil }
        return Self(payload: [target.rawValue, timeoutSeconds])
    }

    static let stop = Self(payload: [0x00])
}

struct FastPairRingStatus: Equatable, Sendable {
    enum Components: UInt8, Sendable {
        case stopped = 0x00
        case right = 0x01
        case left = 0x02
        case both = 0x03
    }

    let components: Components
    let timeoutSeconds: UInt8?

    init?(payload: [UInt8]) {
        guard (1...2).contains(payload.count), let components = Components(rawValue: payload[0]) else { return nil }
        self.components = components
        timeoutSeconds = payload.count == 2 ? payload[1] : nil
    }

    var acknowledgement: FastPairMessage {
        var payload: [UInt8] = [0x04, 0x01, components.rawValue]
        if let timeoutSeconds { payload.append(timeoutSeconds) }
        return FastPairMessage(group: 0xFF, code: 0x01, payload: payload)
    }
}

enum FastPairRingRejection: UInt8, Sendable {
    case unsupported = 0x00
    case busy = 0x01
    case disallowed = 0x02
    case invalidAuthentication = 0x03
    case redundant = 0x04
}

enum FastPairRingResponse: Equatable, Sendable {
    case status(FastPairRingStatus)
    case acknowledgement(FastPairRingStatus?)
    case rejection(FastPairRingRejection, FastPairRingStatus?)

    init?(message: FastPairMessage) {
        let payload = message.payload
        switch (message.group, message.code) {
        case (0x04, 0x01):
            guard let status = FastPairRingStatus(payload: payload) else { return nil }
            self = .status(status)
        case (0xFF, 0x01):
            guard (2...4).contains(payload.count), payload[0] == 0x04, payload[1] == 0x01 else { return nil }
            if payload.count == 2 {
                self = .acknowledgement(nil)
            } else {
                guard let status = FastPairRingStatus(payload: Array(payload.dropFirst(2))) else { return nil }
                self = .acknowledgement(status)
            }
        case (0xFF, 0x02):
            guard (3...5).contains(payload.count), let reason = FastPairRingRejection(rawValue: payload[0]),
                  payload[1] == 0x04, payload[2] == 0x01 else { return nil }
            if payload.count == 3 {
                self = .rejection(reason, nil)
            } else {
                guard let status = FastPairRingStatus(payload: Array(payload.dropFirst(3))) else { return nil }
                self = .rejection(reason, status)
            }
        default:
            return nil
        }
    }
}
