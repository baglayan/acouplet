#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import XCTest
@testable import Acouplet

@MainActor
final class SonyNativeBatteryPublisherTests: XCTestCase {
    @MainActor
    private final class Harness {
        final class Child {
            var isRunning = true
            var exitedWithoutPublishing = false
            var exitedSuccessfully = false
            var withdrewAfterNativeDisconnect = false
            var withdrewAfterLeaseExpiry = false
        }

        var date = Date(timeIntervalSince1970: 1_000)
        var timers: [(Date, @MainActor () -> Void)] = []
        var cancelled: Set<Int> = []
        var sent: [String: [Data]] = [:]
        var closes: [String: Int] = [:]
        var launches: [String: Int] = [:]
        var children: [SonyNativeBatteryPublication.Identity: Child] = [:]
        var receivers: [SonyNativeBatteryPublication.Identity: @MainActor @Sendable (Data) -> Void] = [:]
        var caseSent: [Data] = []
        var caseCloses = 0
        var caseLaunches = 0
        var caseChild: Child?
        var caseReceive: (@MainActor @Sendable (Data) -> Void)?
        var launchDelay: TimeInterval = 0
        var failsWrite = false
        var failsLaunch = false

        func publisher() -> SonyNativeBatteryPublisher {
            SonyNativeBatteryPublisher(now: { self.date }, schedule: { date, action in
                let index = self.timers.count
                self.timers.append((date, action))
                return AnyCancellable { self.cancelled.insert(index) }
            }, launchCase: { publication, receive in
                self.caseLaunches += 1
                self.date.addTimeInterval(self.launchDelay)
                let child = Child()
                self.caseChild = child
                self.caseReceive = receive
                return SonyNativeBatteryPublisher.Connection(send: { data in
                    if self.failsWrite { throw POSIXError(.EPIPE) }
                    self.caseSent.append(data)
                }, close: { self.caseCloses += 1 }, isRunning: { child.isRunning },
                    didExitWithoutPublishing: { !child.isRunning && child.exitedWithoutPublishing },
                    didExitSuccessfully: { !child.isRunning && child.exitedSuccessfully },
                    didWithdrawAfterNativeDisconnect: { !child.isRunning && child.withdrewAfterNativeDisconnect })
            }, launch: { publication, receive in
                let address = publication.address
                self.launches[address, default: 0] += 1
                self.date.addTimeInterval(self.launchDelay)
                if self.failsLaunch { throw POSIXError(.EACCES) }
                let child = Child()
                self.children[publication.identity] = child
                self.receivers[publication.identity] = receive
                return SonyNativeBatteryPublisher.Connection(send: { data in
                    if self.failsWrite { throw POSIXError(.EPIPE) }
                    self.sent[address, default: []].append(data)
                }, close: { self.closes[address, default: 0] += 1 }, isRunning: { child.isRunning },
                    didExitWithoutPublishing: { !child.isRunning && child.exitedWithoutPublishing },
                    didExitSuccessfully: { !child.isRunning && child.exitedSuccessfully },
                    didWithdrawAfterNativeDisconnect: { !child.isRunning && child.withdrewAfterNativeDisconnect },
                    didWithdrawAfterLeaseExpiry: { !child.isRunning && child.withdrewAfterLeaseExpiry })
            })
        }

        func exit(_ identity: SonyNativeBatteryPublication.Identity, withoutPublishing: Bool = false, successfully: Bool = false, nativeDisconnected: Bool = false, outputComplete: Bool = true) {
            children[identity]?.isRunning = false
            children[identity]?.exitedWithoutPublishing = withoutPublishing
            children[identity]?.exitedSuccessfully = successfully || nativeDisconnected
            children[identity]?.withdrewAfterNativeDisconnect = nativeDisconnected
            if outputComplete { receivers[identity]?(Data()) }
        }

        func acknowledgment(_ publication: SonyNativeBatteryPublication, update: UInt64 = 1) throws -> Data {
            let sample = try JSONSerialization.jsonObject(with: JSONEncoder().encode(publication))
            var data = try JSONSerialization.data(withJSONObject: ["event": "refresh-completed", "sample": sample, "update": update])
            data.append(0x0A)
            return data
        }

        func acknowledge(_ publication: SonyNativeBatteryPublication, update: UInt64 = 1) throws {
            receivers[publication.identity]?(try acknowledgment(publication, update: update))
        }

        func fireDueTimers() {
            for index in timers.indices where !cancelled.contains(index) && timers[index].0 <= date {
                cancelled.insert(index)
                timers[index].1()
            }
        }

        var deadlines: [Date] { timers.indices.filter { !cancelled.contains($0) }.map { timers[$0].0 } }
    }

    private let address = "02:00:00:00:00:19"
    private let identifier = UUID(uuidString: "00000000-0000-4000-8000-000000000019")!

    private func snapshot(at date: Date, left: UInt8 = 40, right: UInt8 = 36, caseLevel: UInt8? = nil, identifier: UUID? = nil) -> SonyNativeBatterySnapshot {
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: identifier ?? self.identifier, name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x25, 0x09, left, 0, right, 1]))
        snapshot.update(batteries, type: 0x09, observedAt: date)
        if let caseLevel {
            XCTAssertTrue(batteries.update([0x25, 0x0A, caseLevel, 0]))
            snapshot.update(batteries, type: 0x0A, observedAt: date.addingTimeInterval(30))
        }
        return snapshot
    }

    private func publication(_ harness: Harness, address: String? = nil, session: UInt64 = 1, identifier: UUID? = nil) -> SonyNativeBatteryPublication {
        SonyNativeBatteryPublication(address: address ?? self.address, controlSession: session,
            snapshot: snapshot(at: harness.date, identifier: identifier), at: harness.date)!
    }

    func testOnlyFreshPositiveFullPairsAreExportedAndCaseCannotRefreshThem() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for (left, right): (UInt8, UInt8) in [(0, 40), (40, 0), (255, 40), (40, 255)] {
            XCTAssertNil(SonyNativeBatteryPublication(address: address, controlSession: 1,
                snapshot: snapshot(at: now, left: left, right: right), at: now))
        }
        let snapshot = snapshot(at: now, caseLevel: 100)
        XCTAssertNil(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: now.addingTimeInterval(46)))
        XCTAssertNil(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: now.addingTimeInterval(-6)))
        let value = try XCTUnwrap(SonyNativeBatteryPublication(address: address.lowercased(), controlSession: 1, snapshot: snapshot, at: now))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "identifier", "controlSession", "name", "left", "right"])
        XCTAssertEqual(value.expiresAt, now.addingTimeInterval(45))
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, simulatedReady: true)
        XCTAssertNil(controller.nativeBatteryPublication(at: now))
    }

    private func casePublication(_ harness: Harness, level: UInt8 = 43, observedAt: Date? = nil, session: UInt64 = 1) throws -> SonyNativeCaseBatteryPublication {
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: identifier, name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x25, 0x0A, level, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: observedAt ?? harness.date)
        return try XCTUnwrap(SonyNativeCaseBatteryPublication(address: address, controlSession: session, snapshot: snapshot, at: harness.date))
    }

    private func acknowledgeCase(_ value: SonyNativeCaseBatteryPublication, harness: Harness, update: UInt64 = 1) throws {
        let sample = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        var data = try JSONSerialization.data(withJSONObject: ["event": "refresh-completed", "sample": sample, "update": update])
        data.append(0x0A)
        harness.caseReceive?(data)
    }

    func testCaseIsIndependentOfMissingOrExpiredBuds() throws {
        let harness = Harness(), publisher = harness.publisher()
        let value = try casePublication(harness)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "identifier", "controlSession", "name", "caseBattery"])
        XCTAssertEqual(value.caseBattery.level, 43)
        XCTAssertEqual(value.expiresAt, harness.date.addingTimeInterval(45))
        publisher.reconcile([], cases: [value])
        try acknowledgeCase(value, harness: harness)
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(publisher.ownedCaseAddresses, [address])
        XCTAssertTrue(harness.sent.isEmpty)
        harness.date.addTimeInterval(45)
        harness.fireDueTimers()
        XCTAssertEqual(harness.caseCloses, 1)
        XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty)
        publisher.stop()
    }

    func testCapturedCaseZeroWithdrawsCasePublicationWhileKeepingThePair() throws {
        let harness = Harness(), publisher = harness.publisher()
        defer { publisher.stop() }
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: identifier, name: "WF-1000XM5")
        XCTAssertTrue(batteries.update([0x23, 0x09, 0x46, 0, 0x40, 0, 0x64, 0x64]))
        snapshot.update(batteries, type: 0x09, observedAt: harness.date)
        XCTAssertTrue(batteries.update([0x23, 0x0A, 43, 0, 0x1E]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let pair = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        let caseValue = try XCTUnwrap(SonyNativeCaseBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([pair], cases: [caseValue])
        try harness.acknowledge(pair)
        try acknowledgeCase(caseValue, harness: harness)
        harness.date.addTimeInterval(1)
        XCTAssertTrue(batteries.update([0x23, 0x0A, 0, 0, 0x1E]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        XCTAssertNil(snapshot.caseBattery)
        XCTAssertNil(snapshot.freshReadings(at: harness.date)["Case"])
        let nextCase = SonyNativeCaseBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date)
        XCTAssertNil(nextCase)
        let nextPair = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        XCTAssertEqual(nextPair.left, pair.left)
        XCTAssertEqual(nextPair.right, pair.right)
        XCTAssertNil(nextPair.caseBattery)
        XCTAssertEqual(pair.left.level, 70)
        XCTAssertEqual(pair.right.level, 64)
        publisher.reconcile([nextPair], cases: [nextCase].compactMap { $0 })
        XCTAssertEqual(harness.caseCloses, 1)
        XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertNil(harness.closes[address])
    }

    func testCaseRefreshCannotExtendBudsAndBudsCannotExtendCase() throws {
        for refreshingCase in [true, false] {
            let harness = Harness(), publisher = harness.publisher()
            let pair = publication(harness), caseValue = try casePublication(harness, level: 63)
            publisher.reconcile([pair], cases: [caseValue])
            try harness.acknowledge(pair)
            try acknowledgeCase(caseValue, harness: harness)
            harness.date.addTimeInterval(30)
            let nextPair = refreshingCase ? pair : publication(harness)
            let nextCase = refreshingCase ? try casePublication(harness, level: 63) : caseValue
            publisher.reconcile([nextPair], cases: [nextCase])
            if refreshingCase { try acknowledgeCase(nextCase, harness: harness, update: 2) }
            else { try harness.acknowledge(nextPair, update: 2) }
            harness.date.addTimeInterval(15)
            harness.fireDueTimers()
            XCTAssertEqual(publisher.ownedAddresses.isEmpty, refreshingCase)
            XCTAssertEqual(publisher.ownedCaseAddresses.isEmpty, !refreshingCase)
            publisher.stop()
        }
    }

    func testCaseRequiresAcknowledgmentAndConfirmedCleanupBeforeFreshResume() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = try casePublication(harness)
        publisher.reconcile([], cases: [first])
        try acknowledgeCase(first, harness: harness)
        harness.date.addTimeInterval(30)
        let second = try casePublication(harness, level: 1)
        publisher.reconcile([], cases: [second])
        harness.date.addTimeInterval(10)
        harness.fireDueTimers()
        XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty)
        XCTAssertEqual(harness.caseCloses, 1)
        harness.caseChild?.isRunning = false
        harness.caseChild?.exitedSuccessfully = true
        harness.caseReceive?(Data())
        harness.date.addTimeInterval(20)
        publisher.reconcile([], cases: [try casePublication(harness, level: 2)])
        XCTAssertEqual(harness.caseLaunches, 1)
        publisher.stop()
    }

    func testCaseCleanExpiryResumesOnlyAfterEOFAndNewObservationAndCooldown() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = try casePublication(harness)
        publisher.reconcile([], cases: [first])
        try acknowledgeCase(first, harness: harness)
        harness.date.addTimeInterval(45)
        harness.fireDueTimers()
        let newer = try casePublication(harness, level: 63)
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 1)
        harness.caseChild?.isRunning = false
        harness.caseChild?.exitedSuccessfully = true
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 1)
        harness.caseReceive?(Data())
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 1)
        harness.date.addTimeInterval(15)
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 2)
        XCTAssertEqual(publisher.ownedCaseAddresses, [address])
        publisher.stop()
    }

    func testCaseMalformedAndFailedCleanupCannotRepublish() throws {
        for failure in ["malformed", "partial", "death", "revoke"] {
            let harness = Harness(), publisher = harness.publisher()
            let value = try casePublication(harness)
            publisher.reconcile([], cases: [value])
            try acknowledgeCase(value, harness: harness)
            if failure == "malformed" { harness.caseReceive?(Data("invalid\n".utf8)) }
            if failure == "partial" { harness.caseReceive?(Data("{".utf8)) }
            if failure == "revoke" { publisher.revoke() }
            harness.caseChild?.isRunning = false
            harness.caseChild?.exitedSuccessfully = failure != "death"
            harness.caseReceive?(Data())
            harness.date.addTimeInterval(20)
            publisher.reconcile([], cases: [try casePublication(harness, level: 100)])
            XCTAssertEqual(harness.caseLaunches, 1, failure)
            XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty, failure)
            publisher.stop()
        }
    }

    func testSubmissionMarginRejectsOldSamplesWithoutLatchingAnAttempt() throws {
        for age in [18.0, 18.001, 20.0] {
            let harness = Harness(), publisher = harness.publisher()
            let pair = publication(harness), caseValue = try casePublication(harness)
            harness.date.addTimeInterval(age)
            publisher.reconcile([pair], cases: [caseValue])
            XCTAssertEqual(harness.launches[address, default: 0], age <= 18 ? 1 : 0)
            XCTAssertEqual(harness.caseLaunches, age <= 18 ? 1 : 0)
            if age > 18 {
                publisher.reconcile([publication(harness)], cases: [try casePublication(harness)])
                XCTAssertEqual(harness.launches[address], 1)
                XCTAssertEqual(harness.caseLaunches, 1)
            }
            publisher.stop()
        }
    }

    func testStartupLatencyBeforeFirstWriteCanRetryOnlyConfirmedUnpublishedExit() throws {
        let harness = Harness(), publisher = harness.publisher()
        let pair = publication(harness), caseValue = try casePublication(harness)
        harness.date.addTimeInterval(17)
        harness.launchDelay = 3
        publisher.reconcile([pair], cases: [caseValue])
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertTrue(harness.caseSent.isEmpty)
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty)
        harness.exit(pair.identity, withoutPublishing: true)
        harness.caseChild?.isRunning = false
        harness.caseChild?.exitedWithoutPublishing = true
        harness.caseReceive?(Data())
        harness.date.addTimeInterval(15)
        harness.launchDelay = 0
        publisher.reconcile([publication(harness)], cases: [try casePublication(harness, level: 1)])
        XCTAssertEqual(harness.launches[address], 2)
        XCTAssertEqual(harness.caseLaunches, 2)
        publisher.stop()
    }

    func testCasePrerequisiteRefusalWaitsForEOFNewTelemetryAndCooldown() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = try casePublication(harness)
        publisher.reconcile([], cases: [first])
        harness.caseChild?.isRunning = false
        harness.caseChild?.exitedWithoutPublishing = true
        harness.date.addTimeInterval(15)
        let newer = try casePublication(harness, level: 1)
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 1)
        harness.caseReceive?(Data())
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 1)
        harness.date.addTimeInterval(15)
        publisher.reconcile([], cases: [newer])
        XCTAssertEqual(harness.caseLaunches, 2)
        for level in 2...5 {
            harness.caseChild?.isRunning = false
            harness.caseChild?.exitedWithoutPublishing = true
            harness.caseReceive?(Data())
            harness.date.addTimeInterval(15)
            publisher.reconcile([], cases: [try casePublication(harness, level: UInt8(level))])
            XCTAssertEqual(harness.caseLaunches, level + 1)
        }
        publisher.stop()
    }

    func testCasePrerequisiteRefusalCannotOverrideRevokeOrMalformedOutput() throws {
        for failure in ["revoke", "malformed", "partial"] {
            let harness = Harness(), publisher = harness.publisher()
            let first = try casePublication(harness)
            publisher.reconcile([], cases: [first])
            if failure == "revoke" { publisher.revoke() }
            if failure == "malformed" { harness.caseReceive?(Data("invalid\n".utf8)) }
            if failure == "partial" { harness.caseReceive?(Data("{".utf8)) }
            harness.caseChild?.isRunning = false
            harness.caseChild?.exitedWithoutPublishing = true
            harness.caseReceive?(Data())
            harness.date.addTimeInterval(20)
            publisher.reconcile([], cases: [try casePublication(harness, level: 1)])
            XCTAssertEqual(harness.caseLaunches, 1, failure)
            publisher.stop()
        }
    }

    func testCaseAcknowledgmentQueuedAfterCleanDisconnectUsesExitClassification() throws {
        for reconcileFirst in [false, true] {
            for fragmented in [false, true] {
                let harness = Harness(), publisher = harness.publisher()
                let first = try casePublication(harness)
                publisher.reconcile([], cases: [first])
                let sample = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
                var acknowledgment = try JSONSerialization.data(withJSONObject: ["event": "refresh-completed", "sample": sample, "update": 1])
                acknowledgment.append(0x0A)
                if fragmented { harness.caseReceive?(Data(acknowledgment.prefix(20))) }
                harness.caseChild?.isRunning = false
                harness.caseChild?.exitedSuccessfully = true
                harness.caseChild?.withdrewAfterNativeDisconnect = true
                if reconcileFirst { publisher.reconcile([], cases: [first]) }
                harness.caseReceive?(fragmented ? Data(acknowledgment.dropFirst(20)) : acknowledgment)
                XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty)
                XCTAssertTrue(harness.deadlines.isEmpty)
                harness.caseReceive?(Data())
                harness.date.addTimeInterval(15)
                publisher.reconcile([], cases: [try casePublication(harness, level: 1)])
                XCTAssertEqual(harness.caseLaunches, 2, "\(reconcileFirst) \(fragmented)")
                publisher.stop()
            }
        }
    }

    func testSnapshotDisplayNamesTravelWithPairAndCaseSamples() throws {
        let harness = Harness()
        var batteries = SonyBatteries()
        var snapshot = SonyNativeBatterySnapshot(identifier: identifier, name: "Renamed Sony earbuds")
        XCTAssertTrue(batteries.update([0x25, 0x09, 40, 0, 36, 0]))
        snapshot.update(batteries, type: 0x09, observedAt: harness.date)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 43, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let pair = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        let caseValue = try XCTUnwrap(SonyNativeCaseBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        XCTAssertEqual(pair.name, snapshot.name)
        XCTAssertEqual(caseValue.name, snapshot.name)
        XCTAssertEqual(pair.identity, caseValue.identity)
    }

    func testDisplayNameChangeWaitsForEachPartsNewTelemetryWithoutWithdrawing() throws {
        let harness = Harness(), publisher = harness.publisher()
        let pair = publication(harness), caseValue = try casePublication(harness)
        publisher.reconcile([pair], cases: [caseValue])
        try harness.acknowledge(pair)
        try acknowledgeCase(caseValue, harness: harness)
        var pairObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pair)) as? [String: Any])
        var caseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(caseValue)) as? [String: Any])
        pairObject["name"] = "Renamed Sony earbuds"
        caseObject["name"] = "Renamed Sony earbuds"
        let renamedPair = try JSONDecoder().decode(SonyNativeBatteryPublication.self, from: JSONSerialization.data(withJSONObject: pairObject))
        let renamedCase = try JSONDecoder().decode(SonyNativeCaseBatteryPublication.self, from: JSONSerialization.data(withJSONObject: caseObject))
        publisher.reconcile([renamedPair], cases: [renamedCase])
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertEqual(publisher.ownedCaseAddresses, [address])
        XCTAssertEqual(harness.sent[address]?.count, 1)
        XCTAssertEqual(harness.caseSent.count, 1)
        XCTAssertEqual(harness.deadlines.sorted(), [pair.expiresAt, caseValue.expiresAt].sorted())
        publisher.stop()
    }

    func testIntegratedCaseAppearanceUsesThePairPipeWithoutRefreshingBuds() throws {
        let harness = Harness(), publisher = harness.publisher()
        var snapshot = snapshot(at: harness.date)
        let first = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(25)
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 1]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let next = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([next])
        XCTAssertEqual(harness.sent[address]?.count, 2)
        XCTAssertEqual(harness.caseLaunches, 0)
        XCTAssertEqual(next.left, first.left)
        XCTAssertEqual(next.right, first.right)
        XCTAssertEqual(next.expiresAt, first.expiresAt)
        let data = try XCTUnwrap(harness.sent[address]?.last)
        XCTAssertEqual(try JSONDecoder().decode(SonyNativeBatteryPublication.self, from: data), next)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "identifier", "controlSession", "name", "left", "right", "caseBattery"])
        try harness.acknowledge(next, update: 2)
        harness.date = first.expiresAt
        harness.fireDueTimers()
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
    }

    func testOldCaseAtStartupCannotPreventFreshLRPublication() throws {
        let harness = Harness(), publisher = harness.publisher()
        var snapshot = snapshot(at: harness.date)
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date.addingTimeInterval(-25))
        var value = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        XCTAssertNotNil(value.caseBattery)
        publisher.reconcile([value])
        value.caseBattery = nil
        let data = try XCTUnwrap(harness.sent[address]?.last)
        XCTAssertEqual(try JSONDecoder().decode(SonyNativeBatteryPublication.self, from: data), value)
        try harness.acknowledge(value)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertEqual(harness.caseLaunches, 0)
        publisher.stop()
    }

    func testIntegratedCaseUnknownWithdrawsOnlyCaseAndRejectsDelayedResurrection() throws {
        let harness = Harness(), publisher = harness.publisher()
        var snapshot = snapshot(at: harness.date)
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let first = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(1)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 0, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let withdrawn = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([withdrawn])
        try harness.acknowledge(withdrawn, update: 2)
        publisher.reconcile([first])
        XCTAssertEqual(harness.sent[address]?.count, 2)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertNil(harness.closes[address])
        harness.date.addTimeInterval(1)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 62, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let returned = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([returned])
        try harness.acknowledge(returned, update: 3)
        XCTAssertEqual(harness.sent[address]?.count, 3)
        XCTAssertEqual(returned.left, first.left)
        XCTAssertEqual(returned.right, first.right)
        publisher.stop()
    }

    func testIntegratedCaseExpiryWithdrawsWithoutAnotherReconcileOrLRChange() throws {
        let harness = Harness(), publisher = harness.publisher()
        var snapshot = snapshot(at: harness.date)
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let first = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(30)
        XCTAssertTrue(batteries.update([0x25, 0x09, 39, 0, 35, 1]))
        snapshot.update(batteries, type: 0x09, observedAt: harness.date)
        let next = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([next])
        try harness.acknowledge(next, update: 2)
        harness.date = Date(timeIntervalSince1970: first.caseBattery!.observedAt + 45)
        harness.fireDueTimers()
        let data = try XCTUnwrap(harness.sent[address]?.last)
        let withdrawn = try JSONDecoder().decode(SonyNativeBatteryPublication.self, from: data)
        XCTAssertNil(withdrawn.caseBattery)
        XCTAssertEqual(withdrawn.left, next.left)
        XCTAssertEqual(withdrawn.right, next.right)
        XCTAssertEqual(withdrawn.expiresAt, next.expiresAt)
        XCTAssertEqual(harness.sent[address]?.count, 3)
        try harness.acknowledge(withdrawn, update: 3)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertNil(harness.closes[address])
        publisher.stop()
    }

    func testAgedNewCaseCannotRestoreExpiredCaseOrWithdrawFreshBuds() throws {
        let harness = Harness(), publisher = harness.publisher()
        var snapshot = snapshot(at: harness.date)
        var batteries = SonyBatteries()
        XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let first = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(30)
        XCTAssertTrue(batteries.update([0x25, 0x09, 39, 0, 35, 1]))
        snapshot.update(batteries, type: 0x09, observedAt: harness.date)
        let next = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([next])
        try harness.acknowledge(next, update: 2)
        harness.date.addTimeInterval(16)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 62, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date.addingTimeInterval(-19))
        XCTAssertTrue(batteries.update([0x25, 0x09, 38, 0, 34, 1]))
        snapshot.update(batteries, type: 0x09, observedAt: harness.date)
        var expected = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([expected])
        expected.caseBattery = nil
        let data = try XCTUnwrap(harness.sent[address]?.last)
        XCTAssertEqual(try JSONDecoder().decode(SonyNativeBatteryPublication.self, from: data), expected)
        try harness.acknowledge(expected, update: 3)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertNil(harness.closes[address])
        publisher.stop()
    }

    func testIntegratedCaseUpdatesQueueAndOnlyMatchingAcknowledgmentsAdvanceThem() throws {
        let harness = Harness(), publisher = harness.publisher()
        var snapshot = snapshot(at: harness.date)
        let first = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([first])
        try harness.acknowledge(first)
        var batteries = SonyBatteries()
        harness.date.addTimeInterval(1)
        XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 0]))
        snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
        let pending = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([pending])
        harness.date.addTimeInterval(1)
        XCTAssertTrue(batteries.update([0x25, 0x09, 39, 0, 35, 1]))
        snapshot.update(batteries, type: 0x09, observedAt: harness.date)
        let queued = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
        publisher.reconcile([queued])
        XCTAssertEqual(harness.sent[address]?.count, 2)
        try harness.acknowledge(pending, update: 2)
        XCTAssertEqual(harness.sent[address]?.count, 3)
        try harness.acknowledge(queued, update: 3)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        try harness.acknowledge(pending, update: 3)
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
    }

    func testIntegratedCaseCannotSurvivePeerWithdrawalStopOrHelperFailure() throws {
        for failure in ["peer", "stop", "helper", "timeout", "write"] {
            let harness = Harness(), publisher = harness.publisher()
            var snapshot = snapshot(at: harness.date)
            var batteries = SonyBatteries()
            XCTAssertTrue(batteries.update([0x25, 0x0A, 63, 0]))
            snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
            let value = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
            publisher.reconcile([value])
            try harness.acknowledge(value)
            switch failure {
            case "peer": publisher.reconcile([])
            case "stop": publisher.stop()
            case "helper": harness.exit(value.identity)
            case "timeout", "write":
                harness.date.addTimeInterval(1)
                XCTAssertTrue(batteries.update([0x25, 0x0A, 62, 0]))
                snapshot.update(batteries, type: 0x0A, observedAt: harness.date)
                let next = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot, at: harness.date))
                harness.failsWrite = failure == "write"
                publisher.reconcile([next])
                if failure == "timeout" { harness.date.addTimeInterval(10); harness.fireDueTimers() }
            default: XCTFail(failure)
            }
            XCTAssertTrue(publisher.ownedAddresses.isEmpty, failure)
            XCTAssertTrue(publisher.ownedCaseAddresses.isEmpty, failure)
            XCTAssertEqual(harness.closes[address], 1, failure)
            XCTAssertEqual(harness.caseLaunches, 0, failure)
        }
    }

    func testOnlyAcknowledgedUpdateReplacesExpiryWhileReplayCannotExtendIt() throws {
        let harness = Harness(), publisher: SonyNativeBatteryPublisher
        publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        XCTAssertEqual(harness.sent[address]?.count, 1)
        try harness.acknowledge(first)
        let firstExpiry = harness.timers.last!
        harness.date.addTimeInterval(20)
        let second = publication(harness)
        publisher.reconcile([second])
        XCTAssertEqual(harness.sent[address]?.count, 2)
        XCTAssertTrue(harness.deadlines.contains(first.expiresAt))
        XCTAssertFalse(harness.deadlines.contains(second.expiresAt))
        try harness.acknowledge(second, update: 2)
        firstExpiry.1()
        XCTAssertEqual(publisher.ownedAddresses, [address])
        publisher.reconcile([second])
        XCTAssertEqual(harness.sent[address]?.count, 2)
        XCTAssertEqual(harness.timers.last?.0, harness.date.addingTimeInterval(45))
        harness.date.addTimeInterval(46)
        harness.fireDueTimers()
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
        publisher.reconcile([publication(harness)])
        XCTAssertEqual(harness.launches[address], 1)
        publisher.stop()
    }

    func testPairCleanLeaseExpiryResumesAfterConfirmedAbsenceWithNewReadings() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(45)
        harness.fireDueTimers()
        let newer = publication(harness)
        harness.children[first.identity]?.withdrewAfterLeaseExpiry = true
        harness.exit(first.identity, successfully: true, outputComplete: false)
        publisher.reconcile([newer])
        XCTAssertEqual(harness.launches[address], 1)
        harness.receivers[first.identity]?(Data())
        publisher.reconcile([newer])
        XCTAssertEqual(harness.launches[address], 1)
        harness.date.addTimeInterval(15)
        publisher.reconcile([newer])
        XCTAssertEqual(harness.launches[address], 2)
        publisher.stop()
    }

    func testPairLeaseExpiryCannotOverrideRevokeDuringRetirement() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(45)
        harness.fireDueTimers()
        publisher.revoke()
        harness.children[first.identity]?.withdrewAfterLeaseExpiry = true
        harness.exit(first.identity, successfully: true)
        harness.date.addTimeInterval(20)
        publisher.reconcile([publication(harness)])
        XCTAssertEqual(harness.launches[address], 1)
        publisher.stop()
    }

    func testWithdrawalAndSessionReplacementPreserveOtherDevices() throws {
        let harness = Harness(), other = "02:00:00:00:00:20"
        let publisher = harness.publisher()
        let first = publication(harness)
        let otherPublication = publication(harness, address: other)
        publisher.reconcile([first, otherPublication])
        try harness.acknowledge(first)
        try harness.acknowledge(otherPublication)
        XCTAssertEqual(publisher.ownedAddresses, [address, other])
        publisher.reconcile([publication(harness, address: other)])
        XCTAssertEqual(harness.closes[address], 1)
        XCTAssertNil(harness.closes[other])
        publisher.reconcile([publication(harness, session: 2), publication(harness, address: other)])
        XCTAssertEqual(harness.launches[address], 1)
        harness.exit(first.identity, successfully: true)
        harness.date.addTimeInterval(15)
        publisher.reconcile([publication(harness, session: 2), publication(harness, address: other)])
        XCTAssertEqual(harness.launches[address], 2)
        XCTAssertEqual(harness.launches[other], 1)
        publisher.stop()
        XCTAssertEqual(harness.closes[address], 2)
        XCTAssertEqual(harness.closes[other], 1)
        publisher.reconcile([publication(harness, session: 3)])
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
    }

    func testFreshPairReturnsAfterCleanWithdrawalInTheSameControlSession() throws {
        let harness = Harness(), publisher = harness.publisher()
        var current = publication(harness)
        publisher.reconcile([current])
        try harness.acknowledge(current)
        for cycle in 1...4 {
            let oldReceiver = try XCTUnwrap(harness.receivers[current.identity])
            publisher.reconcile([])
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness)])
            XCTAssertEqual(harness.launches[address], cycle)
            harness.exit(current.identity, successfully: true)
            publisher.reconcile([current])
            XCTAssertEqual(harness.launches[address], cycle)
            current = publication(harness)
            publisher.reconcile([current])
            XCTAssertEqual(harness.launches[address], cycle + 1)
            oldReceiver(Data())
            try harness.acknowledge(current)
            XCTAssertEqual(publisher.ownedAddresses, [address])
        }
        publisher.stop()
    }

    func testWithdrawalFailureOrSleepCannotRearmSameSession() throws {
        for revoke in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            publisher.reconcile([])
            if revoke { publisher.revoke() }
            harness.exit(first.identity, successfully: revoke)
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness)])
            XCTAssertEqual(harness.launches[address], 1)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            publisher.stop()
        }
    }

    func testVerifiedNativeDisconnectRearmsOnlyAfterExitBackoffAndBothNewObservations() throws {
        for changesSession in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            harness.date.addTimeInterval(20)
            let latest = publication(harness)
            publisher.reconcile([latest])
            try harness.acknowledge(latest, update: 2)
            let oldReceiver = try XCTUnwrap(harness.receivers[first.identity])
            oldReceiver(Data())
            harness.date.addTimeInterval(14)
            publisher.reconcile([publication(harness, session: changesSession ? 2 : 1)])
            XCTAssertEqual(harness.launches[address], 1)
            harness.exit(first.identity, nativeDisconnected: true)
            publisher.reconcile([publication(harness, session: changesSession ? 2 : 1)])
            XCTAssertEqual(harness.launches[address], 1)
            harness.date.addTimeInterval(1)
            let next = publication(harness, session: changesSession ? 2 : 1)
            var partial = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any])
            partial["right"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest.right))
            publisher.reconcile([try JSONDecoder().decode(SonyNativeBatteryPublication.self,
                from: JSONSerialization.data(withJSONObject: partial))])
            XCTAssertEqual(harness.launches[address], 1)
            publisher.reconcile([next])
            XCTAssertEqual(harness.launches[address], 2)
            oldReceiver(Data())
            try harness.acknowledge(next)
            XCTAssertEqual(publisher.ownedAddresses, [address])
            publisher.stop()
        }
    }

    func testIdentityReplacementWithoutMissingPairRearmsOnlyAfterVerifiedWithdrawalAndFreshReadings() throws {
        for changedIdentifier in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            let nextIdentifier = changedIdentifier ? UUID() : identifier
            publisher.reconcile([publication(harness, session: 2, identifier: nextIdentifier)])
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            XCTAssertEqual(harness.closes[address], 1)
            harness.receivers[first.identity]?(Data("{\"event\":\"native-unavailable\",\"phase\":\"child\"}\n".utf8))
            harness.exit(first.identity, nativeDisconnected: true)
            harness.date.addTimeInterval(14)
            publisher.reconcile([publication(harness, session: 2, identifier: nextIdentifier)])
            XCTAssertEqual(harness.launches[address], 1)
            harness.date.addTimeInterval(1)
            publisher.reconcile([publication(harness, session: 2, identifier: nextIdentifier)])
            XCTAssertEqual(harness.launches[address], 2)
            harness.receivers[first.identity]?(Data())
            XCTAssertEqual(publisher.ownedAddresses, [address])
            publisher.stop()
        }
    }

    func testIdentityReplacementCannotResumeAfterUnconfirmedWithdrawalExit() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        try harness.acknowledge(first)
        publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
        harness.receivers[first.identity]?(Data("{\"event\":\"native-unavailable\",\"phase\":\"child\"}\n{\"event\":\"supervisor-exit\",\"result\":1}\n".utf8))
        harness.exit(first.identity)
        harness.date.addTimeInterval(15)
        publisher.reconcile([publication(harness, session: 3, identifier: UUID())])
        XCTAssertEqual(harness.launches[address], 1)
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        publisher.stop()
    }

    func testLateNativeDisconnectExitCannotUndoProtocolTimeoutWriteOrRevocationFailures() throws {
        for failure in ["protocol", "timeout", "write", "revoke", "retiring-revoke", "backoff-revoke"] {
            let harness = Harness(), publisher = harness.publisher()
            harness.failsWrite = failure == "write"
            let first = publication(harness)
            publisher.reconcile([first])
            switch failure {
            case "protocol":
                harness.receivers[first.identity]?(Data("invalid\n".utf8))
            case "timeout":
                harness.date.addTimeInterval(10)
                harness.fireDueTimers()
            case "revoke":
                publisher.revoke()
            case "retiring-revoke":
                harness.receivers[first.identity]?(Data())
                publisher.revoke()
            case "backoff-revoke":
                harness.exit(first.identity, nativeDisconnected: true)
                publisher.reconcile([first])
                publisher.revoke()
            default:
                break
            }
            harness.exit(first.identity, nativeDisconnected: true)
            harness.failsWrite = false
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness)])
            publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
            XCTAssertEqual(harness.launches[address], 1, failure)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty, failure)
            publisher.stop()
        }
    }

    func testNativeDisconnectExitCannotRearmAfterDeadlineBeforeTimeoutCallback() throws {
        for leaseExpired in [false, true] {
            for arrivesViaEOF in [false, true] {
                let harness = Harness(), publisher = harness.publisher()
                let first = publication(harness)
                publisher.reconcile([first])
                if leaseExpired { try harness.acknowledge(first) }
                harness.date.addTimeInterval(leaseExpired ? 45 : 10)
                harness.exit(first.identity, nativeDisconnected: true, outputComplete: false)
                if arrivesViaEOF { harness.receivers[first.identity]?(Data()) }
                publisher.reconcile([publication(harness)])
                if !arrivesViaEOF { harness.receivers[first.identity]?(Data()) }
                harness.fireDueTimers()
                harness.date.addTimeInterval(15)
                publisher.reconcile([publication(harness)])
                publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
                XCTAssertEqual(harness.launches[address], 1)
                XCTAssertTrue(publisher.ownedAddresses.isEmpty)
                publisher.stop()
            }
        }
    }

    func testIncompleteHelperOutputCannotRearmOnEOFOrNativeDisconnectExit() throws {
        for arrivesViaEOF in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            harness.receivers[first.identity]?(Data("invalid".utf8))
            harness.exit(first.identity, nativeDisconnected: true, outputComplete: false)
            if arrivesViaEOF { harness.receivers[first.identity]?(Data()) }
            publisher.reconcile([first])
            if !arrivesViaEOF { harness.receivers[first.identity]?(Data()) }
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness)])
            publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
            XCTAssertEqual(harness.launches[address], 1)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            publisher.stop()
        }
    }

    func testCleanWithdrawalRequiresBackoffAndBothNewObservationsAcrossPeerIdentities() throws {
        for (changesSession, changesIdentifier) in [(true, false), (false, true), (true, true)] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            publisher.reconcile([])
            harness.exit(first.identity, successfully: true)
            harness.date.addTimeInterval(14)
            let next = publication(harness, session: changesSession ? 2 : 1,
                identifier: changesIdentifier ? UUID() : nil)
            publisher.reconcile([next])
            XCTAssertEqual(harness.launches[address], 1)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            harness.date.addTimeInterval(1)
            for part in ["left", "right"] {
                var partial = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any])
                partial[part] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(part == "left" ? first.left : first.right))
                let oneNewObservation = try JSONDecoder().decode(SonyNativeBatteryPublication.self,
                    from: JSONSerialization.data(withJSONObject: partial))
                publisher.reconcile([oneNewObservation])
                XCTAssertEqual(harness.launches[address], 1)
                XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            }
            publisher.reconcile([next])
            XCTAssertEqual(harness.launches[address], 2)
            try harness.acknowledge(next)
            XCTAssertEqual(publisher.ownedAddresses, [address])
            publisher.stop()
        }
    }

    func testSleepRevocationCannotReuseCapturedSessionAndStopIsPermanent() {
        let harness = Harness(), publisher: SonyNativeBatteryPublisher
        publisher = harness.publisher()
        let old = publication(harness)
        publisher.reconcile([old])
        publisher.revoke()
        harness.date.addTimeInterval(1)
        publisher.reconcile([old, publication(harness, address: "02:00:00:00:00:21")])
        XCTAssertEqual(harness.launches[address], 1)
        publisher.reconcile([publication(harness, session: 2)])
        XCTAssertEqual(harness.launches[address], 1)
        harness.exit(old.identity, successfully: true)
        publisher.reconcile([publication(harness, session: 2)])
        XCTAssertEqual(harness.launches[address], 2)
        publisher.stop()
        publisher.stop()
        XCTAssertEqual(harness.closes[address], 2)
    }

    func testHelperFailureCannotTriggerRepeatedPublicationAttempts() {
        for failure in ["launch", "write", "death"] {
            let harness = Harness(), publisher: SonyNativeBatteryPublisher
            harness.failsLaunch = failure == "launch"
            harness.failsWrite = failure == "write"
            publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            harness.exit(first.identity)
            harness.date.addTimeInterval(1)
            publisher.reconcile([publication(harness)])
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            XCTAssertEqual(harness.launches[address], 1)
            XCTAssertEqual(harness.closes[address, default: 0], failure == "launch" ? 0 : 1)
            publisher.stop()
        }
    }

    func testPublishedHelperFailureCannotRearmForNewControlSession() throws {
        let harness = Harness(), other = "02:00:00:00:00:20"
        let publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.exit(first.identity)
        harness.date.addTimeInterval(15)
        publisher.reconcile([publication(harness)])
        XCTAssertEqual(harness.launches[address], 1)
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        publisher.reconcile([publication(harness, session: 2), publication(harness, address: other)])
        XCTAssertEqual(harness.launches[address], 1)
        XCTAssertFalse(publisher.ownedAddresses.contains(address))
        XCTAssertEqual(harness.launches[other], 1)
        XCTAssertTrue(publisher.ownedAddresses.contains(other))
        publisher.reconcile([publication(harness, session: 3, identifier: UUID())])
        XCTAssertEqual(harness.launches[address], 1)
        XCTAssertFalse(publisher.ownedAddresses.contains(address))
        publisher.stop()
    }

    func testFailedWithdrawalOrSleepCannotRearmForNewPeerIdentity() throws {
        for sleep in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            if sleep { publisher.revoke() } else { publisher.reconcile([]) }
            harness.exit(first.identity)
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness, session: 2)])
            publisher.reconcile([publication(harness, session: 3, identifier: UUID())])
            XCTAssertEqual(harness.launches[address], 1)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            publisher.stop()
        }
    }

    func testInitialOldSampleCannotStartAHelper() {
        let harness = Harness(), publisher: SonyNativeBatteryPublisher
        publisher = harness.publisher()
        let old = publication(harness)
        harness.date.addTimeInterval(21)
        publisher.reconcile([old])
        XCTAssertTrue(harness.launches.isEmpty)
        publisher.reconcile([publication(harness)])
        XCTAssertEqual(harness.launches[address], 1)
        publisher.stop()
    }

    func testBaselineUnavailableRetryRequiresExitFifteenSecondsAndBothNewObservations() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        let oldReceiver = try XCTUnwrap(harness.receivers[first.identity])
        oldReceiver(Data())
        harness.date.addTimeInterval(15)
        publisher.reconcile([publication(harness)])
        XCTAssertEqual(harness.launches[address], 1)
        harness.exit(first.identity, withoutPublishing: true)
        publisher.reconcile([first])
        XCTAssertEqual(harness.launches[address], 1)
        let next = publication(harness, session: 2, identifier: UUID())
        var partial = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any])
        partial["right"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first.right))
        let oneNewObservation = try JSONDecoder().decode(SonyNativeBatteryPublication.self,
            from: JSONSerialization.data(withJSONObject: partial))
        publisher.reconcile([oneNewObservation])
        XCTAssertEqual(harness.launches[address], 1)
        publisher.reconcile([next])
        XCTAssertEqual(harness.launches[address], 2)
        oldReceiver(Data())
        oldReceiver(try harness.acknowledgment(first))
        try harness.acknowledge(next)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        publisher.stop()
    }

    func testBaselineUnavailableRetriesAtMostThreeTimesAndNeverTooEarly() {
        for (changesSession, changesIdentifier) in [(false, false), (true, false), (false, true), (true, true)] {
            let harness = Harness(), publisher = harness.publisher()
            var current = publication(harness)
            publisher.reconcile([current])
            for attempt in 1...3 {
                harness.exit(current.identity, withoutPublishing: true)
                harness.date.addTimeInterval(14)
                let next = publication(harness, session: changesSession ? UInt64(attempt + 1) : 1,
                    identifier: changesIdentifier ? UUID() : nil)
                publisher.reconcile([next])
                XCTAssertEqual(harness.launches[address], attempt)
                harness.date.addTimeInterval(1)
                publisher.reconcile([next])
                XCTAssertEqual(harness.launches[address], min(attempt + 1, 3))
                current = next
            }
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            XCTAssertEqual(harness.closes[address], 3)
        }
    }

    func testCleanSessionsDoNotConsumeLaterBaselineUnavailableRetryBudget() throws {
        for changesSession in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            var current = publication(harness)
            publisher.reconcile([current])
            for cycle in 1...3 {
                try harness.acknowledge(current)
                publisher.reconcile([])
                harness.exit(current.identity, successfully: true)
                harness.date.addTimeInterval(15)
                current = publication(harness, session: changesSession ? UInt64(cycle + 1) : 1)
                publisher.reconcile([current])
                XCTAssertEqual(harness.launches[address], cycle + 1)
            }
            for attempt in 1...3 {
                harness.exit(current.identity, withoutPublishing: true)
                harness.date.addTimeInterval(15)
                current = publication(harness, session: current.controlSession)
                publisher.reconcile([current])
                XCTAssertEqual(harness.launches[address], 3 + min(attempt + 1, 3))
            }
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            publisher.stop()
        }
    }

    func testOtherFailuresCannotBecomeRetryableFromALateExitStatus() throws {
        for failure in ["launch", "write", "protocol", "timeout", "revoke", "retiring-revoke", "backoff-revoke", "non75", "published"] {
            let harness = Harness(), publisher = harness.publisher()
            harness.failsLaunch = failure == "launch"
            harness.failsWrite = failure == "write"
            let first = publication(harness)
            publisher.reconcile([first])
            switch failure {
            case "protocol":
                harness.receivers[first.identity]?(Data("invalid\n".utf8))
            case "timeout":
                harness.date.addTimeInterval(10)
                harness.fireDueTimers()
            case "revoke":
                publisher.revoke()
            case "retiring-revoke":
                harness.receivers[first.identity]?(Data())
                publisher.revoke()
            case "backoff-revoke":
                harness.exit(first.identity, withoutPublishing: true)
                publisher.reconcile([first])
                publisher.revoke()
            case "published":
                try harness.acknowledge(first)
            default:
                break
            }
            harness.exit(first.identity, withoutPublishing: failure != "non75" && failure != "published")
            harness.failsLaunch = false
            harness.failsWrite = false
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness)])
            XCTAssertEqual(harness.launches[address], 1, failure)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty, failure)
            publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
            XCTAssertEqual(harness.launches[address], 1, failure)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty, failure)
        }
    }

    func testAcknowledgedFreshReportsContinueBeyondTwoMinutes() throws {
        let harness = Harness(), publisher = harness.publisher()
        for update in 1...9 {
            let value = publication(harness)
            publisher.reconcile([value])
            try harness.acknowledge(value, update: UInt64(update))
            harness.date.addTimeInterval(20)
            harness.fireDueTimers()
        }
        XCTAssertEqual(harness.sent[address]?.count, 9)
        XCTAssertEqual(harness.launches[address], 1)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertNil(harness.closes[address])
        publisher.stop()
    }

    func testUnacknowledgedReportExpiresWithoutAnotherReconcile() {
        let harness = Harness(), publisher = harness.publisher()
        publisher.reconcile([publication(harness)])
        harness.date.addTimeInterval(10)
        harness.fireDueTimers()
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
    }

    func testWrongLateAndStaleAcknowledgmentsCloseTheAttempt() throws {
        for failure in ["late", "stale", "wrong-index", "wrong-sample", "wrong-session", "wrong-identifier", "extra-key", "wrong-type"] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            var data = try harness.acknowledgment(first)
            switch failure {
            case "late":
                harness.date.addTimeInterval(10)
            case "stale":
                try harness.acknowledge(first)
                harness.date.addTimeInterval(1)
                publisher.reconcile([publication(harness)])
            case "wrong-index":
                data = try harness.acknowledgment(first, update: 2)
            case "wrong-sample":
                harness.date.addTimeInterval(1)
                data = try harness.acknowledgment(publication(harness))
            case "wrong-session":
                data = try harness.acknowledgment(publication(harness, session: 2))
            case "wrong-identifier":
                data = try harness.acknowledgment(publication(harness, identifier: UUID()))
            default:
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var sample = try XCTUnwrap(object["sample"] as? [String: Any])
                if failure == "extra-key" { sample["case"] = sample["left"] }
                else { sample["controlSession"] = true }
                object["sample"] = sample
                data = try JSONSerialization.data(withJSONObject: object)
                data.append(0x0A)
            }
            harness.receivers[first.identity]?(data)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty, failure)
            XCTAssertEqual(harness.closes[address], 1, failure)
            harness.exit(first.identity)
            publisher.reconcile([publication(harness)])
            XCTAssertEqual(harness.launches[address], 1, failure)
        }
    }

    func testOldLeaseExpiresDuringRefreshEvenIfItsTimerHasNotRun() throws {
        for fireTimer in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            harness.date.addTimeInterval(44)
            let second = publication(harness)
            publisher.reconcile([second])
            XCTAssertTrue(harness.deadlines.allSatisfy { $0 == first.expiresAt })
            harness.date.addTimeInterval(2)
            if fireTimer { harness.fireDueTimers() }
            try harness.acknowledge(second, update: 2)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            XCTAssertEqual(harness.closes[address], 1)
        }
    }

    func testPendingReportsCoalesceToOnlyTheNewestSample() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        harness.date.addTimeInterval(1)
        publisher.reconcile([publication(harness)])
        harness.date.addTimeInterval(1)
        let newest = publication(harness)
        publisher.reconcile([newest])
        publisher.reconcile([newest])
        XCTAssertEqual(harness.sent[address]?.count, 1)
        try harness.acknowledge(first)
        XCTAssertEqual(harness.sent[address]?.count, 2)
        let sent = try XCTUnwrap(harness.sent[address]?.last)
        XCTAssertEqual(try JSONDecoder().decode(SonyNativeBatteryPublication.self, from: sent), newest)
        try harness.acknowledge(newest, update: 2)
        XCTAssertEqual(harness.deadlines, [newest.expiresAt])
        publisher.stop()
    }

    func testCoalescedSampleMustStillMeetHelperInputFreshness() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        try harness.acknowledge(first)
        harness.date.addTimeInterval(1)
        let second = publication(harness)
        harness.date.addTimeInterval(1)
        let queued = publication(harness)
        harness.date.addTimeInterval(17)
        publisher.reconcile([second])
        harness.date.addTimeInterval(1)
        publisher.reconcile([queued])
        harness.date.addTimeInterval(8)
        try harness.acknowledge(second, update: 2)
        XCTAssertEqual(harness.sent[address]?.count, 2)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertEqual(harness.closes[address, default: 0], 0)
        harness.date.addTimeInterval(18)
        harness.fireDueTimers()
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
    }

    func testExitedHelperDrainsAcknowledgmentAndFinalOutputBeforeRecovery() throws {
        for reconcileFirst in [false, true] {
            for output in ["batch", "fragmented", "truncated"] {
                let harness = Harness(), publisher = harness.publisher()
                let first = publication(harness)
                publisher.reconcile([first])
                try harness.acknowledge(first)
                harness.date.addTimeInterval(1)
                let pending = publication(harness)
                publisher.reconcile([pending])
                harness.date.addTimeInterval(1)
                let queued = publication(harness)
                publisher.reconcile([queued])
                let timerCount = harness.timers.count
                let acknowledgment = try harness.acknowledgment(pending, update: 2)
                if output != "batch" { harness.receivers[first.identity]?(Data(acknowledgment.prefix(20))) }
                harness.exit(first.identity, nativeDisconnected: true, outputComplete: false)
                if reconcileFirst { publisher.reconcile([queued]) }
                var data = output == "batch" ? acknowledgment : Data(acknowledgment.dropFirst(20))
                data.append(Data("{\"event\":\"final-inventory\"}\n{\"event\":\"supervisor-exit\",\"result\":".utf8))
                if output == "batch" { data.append(Data("76}\n".utf8)) }
                harness.receivers[first.identity]?(data)
                XCTAssertTrue(publisher.ownedAddresses.isEmpty, "\(reconcileFirst) \(output)")
                XCTAssertTrue(harness.deadlines.isEmpty)
                XCTAssertEqual(harness.timers.count, timerCount)
                XCTAssertEqual(harness.sent[address]?.count, 2)
                XCTAssertEqual(harness.closes[address], 1)
                if output == "fragmented" { harness.receivers[first.identity]?(Data("76}\n".utf8)) }
                harness.date.addTimeInterval(15)
                publisher.reconcile([publication(harness)])
                XCTAssertEqual(harness.launches[address], 1)
                harness.receivers[first.identity]?(Data())
                publisher.reconcile([publication(harness)])
                XCTAssertEqual(harness.launches[address], output == "truncated" ? 1 : 2, "\(reconcileFirst) \(output)")
                if output == "truncated" {
                    publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
                    XCTAssertEqual(harness.launches[address], 1)
                }
                publisher.stop()
            }
        }
    }

    func testExitedHelperCannotRecoverFromInvalidActiveAcknowledgment() throws {
        for failure in ["malformed", "wrong-index", "wrong-sample", "extra-key", "wrong-type"] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            var data = try harness.acknowledgment(first)
            switch failure {
            case "malformed":
                data = Data("invalid\n".utf8)
            case "wrong-index":
                data = try harness.acknowledgment(first, update: 2)
            case "wrong-sample":
                data = try harness.acknowledgment(publication(harness, session: 2))
            default:
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var sample = try XCTUnwrap(object["sample"] as? [String: Any])
                if failure == "extra-key" { sample["case"] = sample["left"] }
                else { sample["controlSession"] = true }
                object["sample"] = sample
                data = try JSONSerialization.data(withJSONObject: object)
                data.append(0x0A)
            }
            harness.exit(first.identity, nativeDisconnected: true, outputComplete: false)
            harness.receivers[first.identity]?(data)
            harness.receivers[first.identity]?(Data())
            publisher.reconcile([first])
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness)])
            publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
            XCTAssertEqual(harness.launches[address], 1, failure)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty, failure)
            publisher.stop()
        }
    }

    func testRetiringHelperMustExitAndItsLateOutputCannotAffectReplacement() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        var next = publication(harness, session: 2, identifier: UUID())
        publisher.reconcile([first])
        publisher.reconcile([next])
        publisher.reconcile([next])
        XCTAssertEqual(harness.launches[address], 1)
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        harness.exit(first.identity, successfully: true)
        harness.date.addTimeInterval(15)
        next = publication(harness, session: 2, identifier: next.identifier)
        publisher.reconcile([next])
        XCTAssertEqual(harness.launches[address], 2)
        harness.receivers[first.identity]?(Data())
        try harness.acknowledge(first)
        try harness.acknowledge(next)
        XCTAssertEqual(publisher.ownedAddresses, [address])
        XCTAssertEqual(harness.closes[address], 1)
        publisher.stop()
    }

    func testRetiringOutputProtocolFailureCannotRearmAfterCleanOrDisconnectedExit() throws {
        for nativeDisconnected in [false, true] {
            for exitedBeforeOutput in [false, true] {
                for output in ["invalid\n", String(repeating: "x", count: 8193), String(repeating: "x", count: 8193) + "\n", "{\"event\":"] {
                    let harness = Harness(), publisher = harness.publisher()
                    let first = publication(harness)
                    publisher.reconcile([first])
                    try harness.acknowledge(first)
                    publisher.reconcile([])
                    if exitedBeforeOutput {
                        harness.exit(first.identity, successfully: true, nativeDisconnected: nativeDisconnected, outputComplete: false)
                    }
                    harness.date.addTimeInterval(15)
                    publisher.reconcile([publication(harness, session: 2, identifier: UUID())])
                    XCTAssertEqual(harness.launches[address], 1)
                    harness.receivers[first.identity]?(Data(output.utf8))
                    if !exitedBeforeOutput {
                        harness.exit(first.identity, successfully: true, nativeDisconnected: nativeDisconnected, outputComplete: false)
                    }
                    harness.receivers[first.identity]?(Data())
                    publisher.reconcile([publication(harness, session: 3, identifier: UUID())])
                    XCTAssertEqual(harness.launches[address], 1)
                    XCTAssertTrue(publisher.ownedAddresses.isEmpty)
                    publisher.stop()
                }
            }
        }
    }

    func testRetiringCleanExitWaitsForFragmentedFinalOutputAndEOF() throws {
        for nativeDisconnected in [false, true] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            try harness.acknowledge(first)
            publisher.reconcile([])
            harness.exit(first.identity, successfully: true, nativeDisconnected: nativeDisconnected, outputComplete: false)
            harness.date.addTimeInterval(15)
            publisher.reconcile([publication(harness, session: 2)])
            XCTAssertEqual(harness.launches[address], 1)
            harness.receivers[first.identity]?(Data("{\"event\":\"supervisor-exit\",\"result\":".utf8))
            publisher.reconcile([publication(harness, session: 2)])
            XCTAssertEqual(harness.launches[address], 1)
            harness.receivers[first.identity]?(Data("0}\n".utf8))
            publisher.reconcile([publication(harness, session: 2)])
            XCTAssertEqual(harness.launches[address], 1)
            harness.receivers[first.identity]?(Data())
            publisher.reconcile([publication(harness, session: 2)])
            XCTAssertEqual(harness.launches[address], 2)
            publisher.stop()
        }
    }

    func testAcknowledgmentStreamHandlesFragmentsAndOtherEventsThenClosesOnEOF() throws {
        let harness = Harness(), publisher = harness.publisher()
        let first = publication(harness)
        publisher.reconcile([first])
        let acknowledgment = try harness.acknowledgment(first)
        var prefix = Data("{\"event\":\"started\"}\n".utf8)
        prefix.append(acknowledgment.prefix(20))
        harness.receivers[first.identity]?(prefix)
        XCTAssertEqual(harness.deadlines.count, 2)
        var suffix = Data(acknowledgment.dropFirst(20))
        suffix.append(Data("{\"event\":\"inventory\"}\n".utf8))
        harness.receivers[first.identity]?(suffix)
        XCTAssertEqual(harness.deadlines, [first.expiresAt])
        harness.receivers[first.identity]?(Data())
        XCTAssertTrue(publisher.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
    }

    func testMalformedOrOversizedOutputClosesTheAttempt() {
        for data in [Data("invalid\n".utf8), Data(repeating: 0x61, count: 8193)] {
            let harness = Harness(), publisher = harness.publisher()
            let first = publication(harness)
            publisher.reconcile([first])
            harness.receivers[first.identity]?(data)
            XCTAssertTrue(publisher.ownedAddresses.isEmpty)
            XCTAssertEqual(harness.closes[address], 1)
        }
    }

    func testCoordinatorSleepAndQuitClosePublisherSynchronously() {
        let harness = Harness()
        let live = harness.publisher()
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true, simulatedReady: true)
        let coordinator = SonyDeviceCoordinator(controller: controller)
        coordinator.nativeBatteryPublisher = live
        let first = publication(harness)
        live.reconcile([first])
        coordinator.systemWillSleep()
        XCTAssertTrue(live.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 1)
        harness.exit(first.identity, successfully: true)
        live.reconcile([publication(harness, session: 2)])
        coordinator.stop()
        XCTAssertTrue(live.ownedAddresses.isEmpty)
        XCTAssertEqual(harness.closes[address], 2)
        XCTAssertNil(controller.nativeBatteryPublication(at: harness.date))
    }

    func testEmbeddedChildReleasesItsPipeOnNormalAppDisposalWithoutPublishing() async throws {
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/Acouplet Battery Publisher")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        for submits in [false, true] {
            var output = Data()
            let pipe = try SonyNativeBatteryPipe(executableURL: executable,
                arguments: ["--model", identifier.uuidString, UUID().uuidString], receive: { output.append($0) })
            defer { if pipe.process.isRunning { pipe.process.terminate() } }
            if submits {
                let now = Date()
                let value = try XCTUnwrap(SonyNativeBatteryPublication(address: address, controlSession: 1, snapshot: snapshot(at: now), at: now))
                var data = try JSONEncoder().encode(value)
                data.append(0x0A)
                try pipe.send(data)
                for _ in 0..<200 where !output.contains(0x0A) && pipe.process.isRunning {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let newline = try XCTUnwrap(output.firstIndex(of: 0x0A))
                let acknowledgment = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.prefix(upTo: newline))) as? [String: Any])
                XCTAssertEqual(acknowledgment["event"] as? String, "refresh-completed")
                XCTAssertEqual(acknowledgment["update"] as? Int, 1)
                let sample = try XCTUnwrap(acknowledgment["sample"] as? [String: Any])
                XCTAssertEqual(Set(sample.keys), ["address", "identifier", "controlSession", "name", "left", "right"])
                XCTAssertEqual(try JSONDecoder().decode(SonyNativeBatteryPublication.self,
                    from: JSONSerialization.data(withJSONObject: sample)), value)
            }
            pipe.close()
            for _ in 0..<200 where pipe.process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(pipe.process.isRunning)
            if !pipe.process.isRunning {
                XCTAssertEqual(pipe.process.terminationReason, .exit)
                XCTAssertEqual(pipe.process.terminationStatus, 0)
            }
        }
    }
}
#endif
