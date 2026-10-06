import XCTest
@testable import Acouplet

final class SonyBLETransportTests: XCTestCase {
    @MainActor
    func testFrameworkFailureDiagnosticsRetainDomainAndCodeWithoutPrivateUserInfo() {
        let privateMessage = "Could not connect to private renamed earbuds"
        let error = NSError(domain: "CBErrorDomain", code: 6, userInfo: [NSLocalizedDescriptionKey: privateMessage])
        let transport = SonyBLETransport(waitForConnection: false)
        var message: String?
        transport.onDisconnect = { message = $0 }
        transport.simulateFailure(error)
        XCTAssertEqual(message, String(localized: "Could not connect to the headphone controls. Try again."))
        XCTAssertFalse(message!.contains(privateMessage))
        XCTAssertEqual(transport.diagnosticError, "CBErrorDomain (code 6)")
        XCTAssertFalse(transport.diagnosticError!.contains(privateMessage))
        let timeout = "The headphone connection timed out. Try again."
        transport.simulateFailure(timeout)
        XCTAssertEqual(message, timeout)
        XCTAssertEqual(transport.diagnosticError, timeout)
    }

    @MainActor
    func testDisablingAutomaticReconnectCancelsSetupBeforePeripheralSelection() {
        let automatic = SonyBLETransport(waitForConnection: true)
        XCTAssertFalse(automatic.isWaitingForConnection)
        XCTAssertTrue(automatic.shouldCancelAutomaticConnection)

        let manual = SonyBLETransport(waitForConnection: false)
        XCTAssertFalse(manual.isWaitingForConnection)
        XCTAssertFalse(manual.shouldCancelAutomaticConnection)
    }

    func testAutomaticReconnectWaitsForEarbudsButStillTimesOutSetup() {
        XCTAssertNil(SonyBLETransport.setupTimeoutDuration(waitForConnection: true, isWaitingForConnection: true))
        XCTAssertEqual(SonyBLETransport.setupTimeoutDuration(waitForConnection: true, isWaitingForConnection: false), .seconds(20))
        XCTAssertEqual(SonyBLETransport.setupTimeoutDuration(waitForConnection: false, isWaitingForConnection: true), .seconds(20))
        XCTAssertEqual(SonyBLETransport.setupTimeoutDuration(waitForConnection: false, isWaitingForConnection: false), .seconds(20))
    }

    func testModelMatchingUsesAdvertisedNameWithoutAcceptingAnotherModel() {
        XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: nil, advertisedName: "LE_WF-1000XM5", model: .wfXM5), "LE_WF-1000XM5")
        XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: "WF-1000XM5", advertisedName: nil, model: .unknown), "WF-1000XM5")
        XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: "WH-1000XM5", advertisedName: nil, model: .whXM5), "WH-1000XM5")
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "WH-1000XM5", advertisedName: nil, model: .wfXM5))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "WH-1000XM5", advertisedName: "WF-1000XM5", model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "Sony", advertisedName: nil, model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: nil, advertisedName: nil, model: .wfXM5))
    }

    func testExpandedModelMatchingPreservesExactGamingSpeakerAndNeckbandIdentity() {
        let models: [(String, SonyDeviceModel)] = [
            ("WF-G700N", .wfG700N), ("WH-G910N", .whG910N), ("WI-C100", .wiC100),
            ("HT-AN7", .htAN7), ("SRS-LS1", .srsLS1), ("SRS-NS7", .srsNS7),
            ("SRS-ULT900", .srsULT900), ("SRS-ULT900AC", .srsULT900AC),
        ]
        for (name, model) in models {
            XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: nil, advertisedName: "LE_" + name, model: model), "LE_" + name)
            XCTAssertEqual(SonyBLETransport.matchingName(peripheralName: name, advertisedName: nil, model: .unknown), name)
            XCTAssertNil(SonyBLETransport.matchingName(peripheralName: name, advertisedName: nil, model: .wfXM5))
        }
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "SRS-ULT900AC", advertisedName: "SRS-ULT900", model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "WH-G910N", advertisedName: "WF-G700N", model: .unknown))
        XCTAssertNil(SonyBLETransport.matchingName(peripheralName: "SRS-ULT9000", advertisedName: nil, model: .unknown))
    }

    func testWritableLengthIsBigEndianAndLimitedByHost() {
        XCTAssertEqual(SonyBLEWriteBuffer.maximumLength(from: Data([0x01, 0x02]), hostMaximum: 512), 258)
        XCTAssertEqual(SonyBLEWriteBuffer.maximumLength(from: Data([0x01, 0x02]), hostMaximum: 180), 180)
        XCTAssertEqual(SonyBLEWriteBuffer.maximumLength(from: Data([0xFF, 0xFF]), hostMaximum: 512), 512)
        for data in [Data(), Data([0x14]), Data([0, 0]), Data([0, 0x14, 0])] {
            XCTAssertNil(SonyBLEWriteBuffer.maximumLength(from: data, hostMaximum: 512))
        }
        XCTAssertNil(SonyBLEWriteBuffer.maximumLength(from: Data([0, 0x14]), hostMaximum: 0))
    }

    func testBlockedDrainPreservesFrameAndResumesWithoutInterleaving() throws {
        var buffer = SonyBLEWriteBuffer()
        let frame = Data([0x3E, 0x0C, 0, 0, 0, 0, 1, 0x3D, 0x1E, 0x3C])
        let acknowledgment = Data([0x3E, 1, 1, 0, 0, 0, 0, 2, 0x3C])
        buffer.append(frame)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: false))
        let first = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertEqual(first.data, frame.prefix(4))
        XCTAssertFalse(first.completesWrite)
        buffer.append(acknowledgment)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: false))
        let second = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertFalse(second.completesWrite)
        let third = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertTrue(third.completesWrite)
        XCTAssertEqual(first.data + second.data + third.data, frame)
        var receivedACK = Data()
        var completedWrites = 0
        while let chunk = buffer.next(maximumLength: 4, canSend: true) {
            XCTAssertLessThanOrEqual(chunk.data.count, 4)
            receivedACK.append(chunk.data)
            if chunk.completesWrite { completedWrites += 1 }
        }
        XCTAssertEqual(receivedACK, acknowledgment)
        XCTAssertEqual(completedWrites, 1)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testExactBoundaryCompletesOnceAndResetDiscardsQueuedBytes() throws {
        var buffer = SonyBLEWriteBuffer()
        buffer.append(Data([1, 2, 3, 4]))
        let chunk = try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true))
        XCTAssertEqual(chunk.data, Data([1, 2, 3, 4]))
        XCTAssertTrue(chunk.completesWrite)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: true))
        buffer.append(Data([5, 6, 7, 8, 9]))
        XCTAssertFalse(try XCTUnwrap(buffer.next(maximumLength: 4, canSend: true)).completesWrite)
        buffer = SonyBLEWriteBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.next(maximumLength: 4, canSend: true))
    }

    func testUnsentWriteCanBeDiscardedButPartialFrameMustFinish() throws {
        var buffer = SonyBLEWriteBuffer()
        buffer.append(Data([1, 2, 3, 4, 5]))
        buffer.append(Data([6, 7]))
        XCTAssertNil(buffer.next(maximumLength: 3, canSend: false))
        XCTAssertTrue(buffer.discardUnsentPending())
        XCTAssertEqual(try XCTUnwrap(buffer.next(maximumLength: 3, canSend: true)).data, Data([6, 7]))
        buffer.append(Data([1, 2, 3, 4, 5]))
        buffer.append(Data([6, 7]))
        XCTAssertEqual(try XCTUnwrap(buffer.next(maximumLength: 3, canSend: true)).data, Data([1, 2, 3]))
        XCTAssertFalse(buffer.discardUnsentPending())
        XCTAssertNil(buffer.next(maximumLength: 3, canSend: false))
        XCTAssertFalse(buffer.discardUnsentPending())
        let final = try XCTUnwrap(buffer.next(maximumLength: 3, canSend: true))
        XCTAssertEqual(final.data, Data([4, 5]))
        XCTAssertTrue(final.completesWrite)
        XCTAssertTrue(buffer.discardUnsentPending())
        XCTAssertTrue(buffer.isEmpty)
    }
}
