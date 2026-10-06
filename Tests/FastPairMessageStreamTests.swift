import Foundation
import XCTest
@testable import Acouplet

final class FastPairMessageStreamTests: XCTestCase {
    func testRingRequiresAnExplicitSideAndFiniteNonzeroTimeout() throws {
        XCTAssertNil(FastPairRingCommand.ring(.left, timeoutSeconds: 0))
        XCTAssertNil(FastPairRingCommand.ring(.right, timeoutSeconds: 0))
        let right = try XCTUnwrap(FastPairRingCommand.ring(.right, timeoutSeconds: 60))
        let left = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 255))
        XCTAssertEqual(right.message.encoded, Data([0x04, 0x01, 0x00, 0x02, 0x01, 0x3C]))
        XCTAssertEqual(left.message.encoded, Data([0x04, 0x01, 0x00, 0x02, 0x02, 0xFF]))
        XCTAssertEqual(FastPairRingCommand.stop.message.encoded, Data([0x04, 0x01, 0x00, 0x01, 0x00]))
    }

    func testStreamHandlesEverySplitAndCoalescedFrames() throws {
        let messages = [
            FastPairMessage(group: 0x04, code: 0x01, payload: [0x01, 0x3C]),
            FastPairMessage(group: 0xFF, code: 0x01, payload: [0x04, 0x01, 0x01, 0x3C]),
            FastPairMessage(group: 0xA0, code: 0xFF, payload: [])
        ]
        let data = try messages.reduce(into: Data()) { $0.append(try XCTUnwrap($1.encoded)) }
        for split in 0...data.count {
            var stream = FastPairMessageStream()
            var received: [FastPairMessage] = []
            stream.append(data.prefix(split)) { received.append($0) }
            stream.append(data.dropFirst(split)) { received.append($0) }
            XCTAssertEqual(received, messages, "Split at \(split)")
            XCTAssertEqual(stream.bufferedByteCount, 0)
        }
        var stream = FastPairMessageStream()
        var received: [FastPairMessage] = []
        for byte in data { stream.append(Data([byte])) { received.append($0) } }
        XCTAssertEqual(received, messages)
    }

    func testWireLengthBoundsIncompleteFramesAndRejectsOversizedEncoding() throws {
        let message = FastPairMessage(group: 0x12, code: 0x34,
                                      payload: [UInt8](repeating: 0xFF, count: FastPairMessage.maximumPayloadLength))
        let data = try XCTUnwrap(message.encoded)
        XCTAssertEqual(data.prefix(4), Data([0x12, 0x34, 0xFF, 0xFF]))
        XCTAssertNil(FastPairMessage(group: 0, code: 0, payload: message.payload + [0]).encoded)
        var stream = FastPairMessageStream()
        stream.append(data.dropLast()) { _ in XCTFail("Incomplete frame was delivered") }
        XCTAssertEqual(stream.bufferedByteCount, FastPairMessage.maximumPayloadLength + 3)
        var received: FastPairMessage?
        stream.append(data.suffix(1)) { received = $0 }
        XCTAssertEqual(received, message)
        XCTAssertEqual(stream.bufferedByteCount, 0)
    }

    func testLargeCoalescedInputDoesNotRemainBufferedAndResetDiscardsPartialSession() {
        var stream = FastPairMessageStream()
        var receivedCount = 0
        stream.append(Data(repeating: 0, count: 80_000)) { message in
            XCTAssertEqual(message, FastPairMessage(group: 0, code: 0, payload: []))
            receivedCount += 1
        }
        XCTAssertEqual(receivedCount, 20_000)
        XCTAssertEqual(stream.bufferedByteCount, 0)
        stream.append(Data([0xFF, 0x01, 0, 4, 0x04])) { _ in XCTFail("Incomplete frame was delivered") }
        XCTAssertEqual(stream.bufferedByteCount, 5)
        stream.reset()
        var received: [FastPairMessage] = []
        stream.append(Data([0x04, 0x01, 0, 1, 0])) { received.append($0) }
        XCTAssertEqual(received, [FastPairRingCommand.stop.message])
    }

    func testAcknowledgementsPreserveReportedStateWithoutInventingIt() throws {
        let status = try XCTUnwrap(FastPairRingStatus(payload: [0x01, 0x3C]))
        XCTAssertEqual(status.components, .right)
        XCTAssertEqual(status.timeoutSeconds, 60)
        XCTAssertEqual(status.acknowledgement.encoded, Data([0xFF, 0x01, 0, 4, 0x04, 0x01, 0x01, 0x3C]))
        XCTAssertEqual(FastPairRingResponse(message: status.acknowledgement), .acknowledgement(status))
        XCTAssertEqual(FastPairRingResponse(message: FastPairMessage(group: 0xFF, code: 0x01,
                                                                   payload: [0x04, 0x01])), .acknowledgement(nil))
        let stopped = try XCTUnwrap(FastPairRingStatus(payload: [0]))
        XCTAssertNil(stopped.timeoutSeconds)
        let rejection = FastPairMessage(group: 0xFF, code: 0x02, payload: [0x01, 0x04, 0x01, 0x00])
        XCTAssertEqual(FastPairRingResponse(message: rejection), .rejection(.busy, stopped))
        for reason in UInt8(0)...4 {
            XCTAssertEqual(FastPairRingResponse(message: FastPairMessage(group: 0xFF, code: 0x02,
                payload: [reason, 0x04, 0x01])), .rejection(try XCTUnwrap(FastPairRingRejection(rawValue: reason)), nil))
        }
    }

    func testStatusPreservesUnknownTimeoutAndBothSidesEvenThoughWeOnlyRequestOneSide() throws {
        for components in UInt8(0)...3 {
            for payload in [[components], [components, 0], [components, 30]] {
                let status = try XCTUnwrap(FastPairRingStatus(payload: payload))
                XCTAssertEqual(status.components.rawValue, components)
                XCTAssertEqual(status.timeoutSeconds, payload.count == 2 ? payload[1] : nil)
                XCTAssertEqual(FastPairRingResponse(message: FastPairMessage(group: 0x04, code: 0x01,
                                                                           payload: payload)), .status(status))
            }
        }
    }

    func testMalformedOrUnrelatedResponsesAreNotAcceptedAsRingState() {
        for payload: [UInt8] in [[], [4], [255], [1, 1, 1]] {
            XCTAssertNil(FastPairRingStatus(payload: payload))
            XCTAssertNil(FastPairRingResponse(message: FastPairMessage(group: 0x04, code: 0x01, payload: payload)))
        }
        for payload: [UInt8] in [[], [4], [3, 1], [4, 2], [4, 1, 4], [4, 1, 0, 1, 2]] {
            XCTAssertNil(FastPairRingResponse(message: FastPairMessage(group: 0xFF, code: 0x01, payload: payload)))
        }
        for payload: [UInt8] in [[], [0], [0, 4], [5, 4, 1], [0, 3, 1], [0, 4, 2], [0, 4, 1, 4], [0, 4, 1, 0, 1, 2]] {
            XCTAssertNil(FastPairRingResponse(message: FastPairMessage(group: 0xFF, code: 0x02, payload: payload)))
        }
        for (group, code): (UInt8, UInt8) in [(0x03, 0x01), (0x04, 0x02), (0xFF, 0x03)] {
            XCTAssertNil(FastPairRingResponse(message: FastPairMessage(group: group, code: code, payload: [0])))
        }
    }
}
