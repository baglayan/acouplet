import Foundation
@preconcurrency import IOBluetooth
import XCTest
@testable import Acouplet

final class FastPairTransportTests: XCTestCase {
    @MainActor
    func testReplacementTransportWaitsForSharedRetirementAndKeepsMainActorResponsive() async {
        let started = expectation(description: "Channel close started")
        let finished = expectation(description: "Channel close returned")
        let release = DispatchSemaphore(value: 0)
        let channel = DelayedChannel(started: started, finished: finished, release: release)
        var failures = 0
        let closeCompletion = DispatchGroup()
        var owner: FastPairTransport? = FastPairTransport(closeCompletion: closeCompletion, onOpen: {},
                                                        onData: { _ in }, onFailure: { _ in XCTFail("Retired transport failed") })
        let replacementOwner = FastPairTransport(closeCompletion: closeCompletion, onOpen: { XCTFail("Invalid address opened") },
                                                onData: { _ in }, onFailure: { _ in failures += 1 })
        var delegate: FastPairTransport.ChannelDelegate? = .init(owner: owner!, session: UUID())
        delegate?.channel = channel
        delegate?.channelIO = RFCOMMChannelIO(channel: channel)
        weak var retainedDelegate = delegate
        weak var retiredOwner = owner
        delegate?.retire(completion: closeCompletion)
        delegate = nil
        owner = nil

        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(retainedDelegate)
        XCTAssertNil(retiredOwner)
        XCTAssertNil(retainedDelegate?.owner)
        XCTAssertNil(retainedDelegate?.channel)
        let replacement = FastPairTransport.ChannelDelegate(owner: replacementOwner, session: UUID())
        retainedDelegate?.didOpen(channel, status: kIOReturnSuccess)
        retainedDelegate?.didClose(channel)
        let callbacksDrained = expectation(description: "Stale callbacks drained")
        DispatchQueue.main.async { callbacksDrained.fulfill() }
        await fulfillment(of: [callbacksDrained], timeout: 2)
        XCTAssertTrue(replacement.owner === replacementOwner)
        XCTAssertEqual(failures, 0)
        replacementOwner.open(address: "invalid")
        let waiting = expectation(description: "Open waits while native close is blocked")
        DispatchQueue.main.async { waiting.fulfill() }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(failures, 0)
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        for _ in 0..<100 where retainedDelegate != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(retainedDelegate)
        let reopened = expectation(description: "Pending open resumed after native close")
        closeCompletion.notify(queue: .main) { reopened.fulfill() }
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testOpenWaitsForNativeCloseAndCancellationDropsThePendingOpen() async {
        let started = expectation(description: "Channel close started")
        let finished = expectation(description: "Channel close returned")
        let release = DispatchSemaphore(value: 0)
        let channel = DelayedChannel(started: started, finished: finished, release: release)
        var failures = 0
        let owner = FastPairTransport(onOpen: { XCTFail("Invalid address opened") }, onData: { _ in },
                                      onFailure: { _ in failures += 1 })
        let delegate = FastPairTransport.ChannelDelegate(owner: owner, session: UUID())
        delegate.channel = channel
        delegate.channelIO = RFCOMMChannelIO(channel: channel)
        delegate.retire(completion: owner.closeCompletion)
        await fulfillment(of: [started], timeout: 2)

        owner.open(address: "invalid")
        let waiting = expectation(description: "Main queue drained while native close is blocked")
        DispatchQueue.main.async { waiting.fulfill() }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(failures, 0)
        owner.close()
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        let closed = expectation(description: "Native cleanup completed")
        owner.closeCompletion.notify(queue: .main) { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(failures, 0)

        owner.open(address: "invalid")
        let reopened = expectation(description: "Open proceeds after cleanup")
        DispatchQueue.main.async { reopened.fulfill() }
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testOpenTimeoutFailsWithoutAdmittingReplacementWhileNativeCloseIsBlocked() async {
        let started = expectation(description: "Channel close started")
        let finished = expectation(description: "Channel close returned")
        let release = DispatchSemaphore(value: 0)
        let channel = DelayedChannel(started: started, finished: finished, release: release)
        var failures = 0
        let owner = FastPairTransport(onOpen: { XCTFail("Replacement opened while closing") }, onData: { _ in },
                                      onFailure: { _ in failures += 1 })
        let delegate = FastPairTransport.ChannelDelegate(owner: owner, session: UUID())
        delegate.channel = channel
        delegate.channelIO = RFCOMMChannelIO(channel: channel)
        delegate.retire(completion: owner.closeCompletion)
        await fulfillment(of: [started], timeout: 2)

        owner.open(address: "invalid")
        owner.simulateOpenTimeout()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(owner.closeCompletion.wait(timeout: .now()), .timedOut)
        let responsive = expectation(description: "Main queue responsive after timeout")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 2)
        XCTAssertEqual(failures, 1)
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        let closed = expectation(description: "Native cleanup completed")
        owner.closeCompletion.notify(queue: .main) { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testHealthyReuseDeliversOnlyTheLatestOpenNotification() async {
        var openings = 0
        let owner = FastPairTransport(onOpen: { openings += 1 }, onData: { _ in },
                                      onFailure: { _ in XCTFail("Healthy reuse failed") })
        let channel = RFCOMMChannelIOTests.TestChannel()
        owner.simulateConnection(address: "test", device: ConnectedDevice(), channel: channel)
        XCTAssertTrue(owner.canReuse(address: "test"))
        owner.open(address: "test")
        owner.open(address: "test")
        XCTAssertEqual(openings, 0)
        let drained = expectation(description: "Reused open notifications drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(openings, 1)
        XCTAssertEqual(channel.closeCount, 0)
        owner.open(address: "test")
        owner.close()
        let cancelled = expectation(description: "Cancelled reuse notification drained")
        DispatchQueue.main.async { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(openings, 1)
    }

    private final class ConnectedDevice: FastPairDevice, @unchecked Sendable {
        func isPaired() -> Bool { true }
        func isClassicConnected() -> Bool { true }
    }

    private final class DelayedChannel: FastPairChannel, @unchecked Sendable {
        let started: XCTestExpectation
        let finished: XCTestExpectation
        let release: DispatchSemaphore

        init(started: XCTestExpectation, finished: XCTestExpectation, release: DispatchSemaphore) {
            self.started = started
            self.finished = finished
            self.release = release
        }

        func isOpen() -> Bool { true }
        func isTransmissionPaused() -> Bool { false }
        func getMTU() -> BluetoothRFCOMMMTU { 127 }
        func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn { kIOReturnSuccess }

        func setDelegate(_ delegate: Any!) -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            return kIOReturnSuccess
        }

        func close() -> IOReturn {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            DispatchQueue.main.async { self.finished.fulfill() }
            return kIOReturnSuccess
        }
    }
}
