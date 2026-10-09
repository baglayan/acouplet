import Foundation
import XCTest
@testable import Acouplet

final class SonyLowBatteryPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func reading(_ part: SonyLowBatteryPolicy.Part, _ level: Int, charging: Bool = false,
                         at date: Date? = nil) -> SonyLowBatteryPolicy.Reading {
        .init(part: part, level: level, isCharging: charging, observedAt: date ?? start)
    }

    func testHeadphonesUseCurrentMacThresholdsAndActualSkippedLevels() throws {
        var policy = SonyLowBatteryPolicy()
        var presented: [Int] = []
        for level in [100, 21, 20, 20, 19, 11, 10, 9, 6, 5, 4, 4, 2, 1, 0, 0] {
            if let warning = policy.warnings(for: "WH", readings: [reading(.headphones, level)],
                                             at: start).first {
                presented.append(warning.reading.level)
                policy.didPresent(warning, at: start)
            }
        }
        XCTAssertEqual(presented, [20, 10, 5, 4, 2, 1, 0])
        policy = SonyLowBatteryPolicy()
        let low = try XCTUnwrap(policy.warnings(for: "WH", readings: [reading(.headphones, 3)],
                                               at: start).first)
        policy.didPresent(low, at: start)
        XCTAssertTrue(policy.warnings(for: "WH", readings: [reading(.headphones, 3)], at: start).isEmpty)
        XCTAssertEqual(policy.warnings(for: "WH", readings: [reading(.headphones, 2)], at: start).count, 1)
    }

    func testEarbudsShareHistoryAndReportOnlyTheLowestDischargingSide() throws {
        var policy = SonyLowBatteryPolicy()
        let first = try XCTUnwrap(policy.warnings(for: "WF", readings: [reading(.left, 20), reading(.right, 80)],
                                                 at: start).first)
        XCTAssertEqual(first.group, .earbuds)
        XCTAssertEqual(first.reading.part, .left)
        policy.didPresent(first, at: start)
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.left, 19), reading(.right, 20)],
                                      at: start).isEmpty)
        let both = policy.warnings(for: "WF", readings: [reading(.left, 10), reading(.right, 8)],
                                   at: start)
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(both.first?.reading.part, .right)
        XCTAssertEqual(both.first?.reading.level, 8)
        XCTAssertEqual(policy.warnings(for: "other WF", readings: [reading(.right, 19)],
                                       at: start).count, 1)
    }

    func testCaseHasItsOwnTwentyFivePercentThresholdAndHistory() throws {
        var policy = SonyLowBatteryPolicy()
        let warnings = policy.warnings(for: "WF", readings: [reading(.left, 20), reading(.right, 70), reading(.caseBattery, 25)],
                                       at: start)
        XCTAssertEqual(warnings.map(\.group), [.earbuds, .caseBattery])
        policy.didPresent(try XCTUnwrap(warnings.first), at: start)
        let caseWarning = try XCTUnwrap(policy.warnings(for: "WF", readings: [reading(.caseBattery, 25)],
                                                       at: start).first)
        policy.didPresent(caseWarning, at: start)
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.caseBattery, 24)], at: start).isEmpty)
        XCTAssertEqual(policy.warnings(for: "WF", readings: [reading(.caseBattery, 10)], at: start).count, 1)
    }

    func testChargingSuppressesOnlyItsOwnReadingAndRearmsTheGroup() throws {
        var policy = SonyLowBatteryPolicy()
        let low = try XCTUnwrap(policy.warnings(for: "WF", readings: [reading(.left, 2, charging: true), reading(.right, 15)],
                                               at: start).first)
        XCTAssertEqual(low.reading.part, .right)
        policy.didPresent(low, at: start)
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.left, 2, charging: true), reading(.right, 15, charging: true)],
                                      at: start).isEmpty)
        XCTAssertEqual(policy.warnings(for: "WF", readings: [reading(.right, 15)], at: start).count, 1)
    }

    func testUnknownOrStaleDataCannotWarnOrRearm() throws {
        var policy = SonyLowBatteryPolicy()
        let low = try XCTUnwrap(policy.warnings(for: "WF", readings: [reading(.left, 20)], at: start).first)
        policy.didPresent(low, at: start)
        let stale = start.addingTimeInterval(-46)
        for readings in [[], [reading(.left, 80, at: stale)], [reading(.left, 5, charging: true, at: stale)],
                         [reading(.left, -1)], [reading(.left, 101)], [reading(.left, 80, at: start.addingTimeInterval(6))]] {
            XCTAssertTrue(policy.warnings(for: "WF", readings: readings, at: start).isEmpty)
        }
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.left, 20)], at: start).isEmpty)
        XCTAssertEqual(policy.warnings(for: "unseen", readings: [reading(.right, 5)], at: start).count, 1)
    }

    func testRearmingRequiresFiftyPercentForEveryDischargingSide() throws {
        var policy = SonyLowBatteryPolicy()
        let low = try XCTUnwrap(policy.warnings(for: "WF", readings: [reading(.left, 20)], at: start).first)
        policy.didPresent(low, at: start)
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.left, 50), reading(.right, 49)], at: start).isEmpty)
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.left, 20)], at: start).isEmpty)
        XCTAssertTrue(policy.warnings(for: "WF", readings: [reading(.left, 50), reading(.right, 50)], at: start).isEmpty)
        XCTAssertEqual(policy.warnings(for: "WF", readings: [reading(.left, 20)], at: start).count, 1)
    }

    func testPersistenceSuppressesReconnectAndExpiresAfterSixteenHours() throws {
        var policy = SonyLowBatteryPolicy()
        let low = try XCTUnwrap(policy.warnings(for: "WH", readings: [reading(.headphones, 20)], at: start).first)
        policy.didPresent(low, at: start.addingTimeInterval(2))
        let data = try JSONEncoder().encode(policy)
        var restored = try JSONDecoder().decode(SonyLowBatteryPolicy.self, from: data)
        XCTAssertEqual(restored, policy)
        let beforeExpiry = start.addingTimeInterval(57_601)
        XCTAssertTrue(restored.warnings(for: "WH", readings: [reading(.headphones, 20, at: beforeExpiry)],
                                        at: beforeExpiry).isEmpty)
        let expired = start.addingTimeInterval(57_602)
        XCTAssertEqual(restored.warnings(for: "WH", readings: [reading(.headphones, 20, at: expired)],
                                         at: expired).count, 1)
    }

    func testUndeliveredWarningsRemainEligibleAndExpiredDeliveryCannotConsumeThem() throws {
        var policy = SonyLowBatteryPolicy()
        let low = try XCTUnwrap(policy.warnings(for: "WH", readings: [reading(.headphones, 20)], at: start).first)
        XCTAssertEqual(policy.warnings(for: "WH", readings: [reading(.headphones, 20)], at: start).count, 1)
        let later = start.addingTimeInterval(46)
        policy.didPresent(low, at: later)
        XCTAssertEqual(policy.warnings(for: "WH", readings: [reading(.headphones, 20, at: later)],
                                       at: later).count, 1)
    }

    func testMainBatteryDoesNotCreateAnEarbudOrCaseWarning() {
        var policy = SonyLowBatteryPolicy()
        XCTAssertTrue(policy.warnings(for: "WH", readings: [reading(.headphones, 80), reading(.left, 5), reading(.caseBattery, 1)],
                                      at: start).isEmpty)
        XCTAssertTrue(policy.warnings(for: "", readings: [reading(.headphones, 10)], at: start).isEmpty)
    }
}
