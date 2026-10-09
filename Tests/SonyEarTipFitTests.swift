import XCTest
@testable import Acouplet

final class SonyEarTipFitTests: XCTestCase {
    func testOnlyAdvertisedFitFunctionAcceptsItsT1Subtype() {
        for functions: Set<UInt8> in [[], [0xF0], [0xF1, 0xF5, 0xF7]] {
            var fit = SonyEarTipFit(supportedFunctions: functions)
            XCTAssertFalse(fit.isSupported)
            XCTAssertTrue(fit.queryPayloads.isEmpty)
            for payload in validPayloads { XCTAssertFalse(fit.update(payload)) }
        }
        var fit = SonyEarTipFit(supportedFunctions: [0xF6])
        XCTAssertTrue(fit.isSupported)
        XCTAssertEqual(fit.queryPayloads, [[0xF0, 6], [0xF2, 6], [0xF6, 6]])
        for payload in validPayloads {
            for type: UInt8 in [0, 0x0E, 0x10, 0xFF] {
                XCTAssertFalse(fit.update(payload, frameType: type))
            }
            for inquiry: UInt8 in [0, 1, 5, 7, 0xFF] {
                var wrongInquiry = payload
                wrongInquiry[1] = inquiry
                XCTAssertFalse(fit.update(wrongInquiry))
            }
        }
        XCTAssertEqual(fit, SonyEarTipFit(supportedFunctions: [0xF6]))
    }

    func testCapabilityPreservesReportedOrderAndSeparatesUncertainDuration() throws {
        var fit = SonyEarTipFit(supportedFunctions: [0xF6])
        XCTAssertTrue(fit.update([0xF1, 6, 12, 2, 2, 3, 4, 0, 2, 1, 2, 3, 1]))
        let capability = try XCTUnwrap(fit.capability)
        XCTAssertEqual(capability.duration, 12)
        XCTAssertEqual(capability.durationSeconds, 12)
        XCTAssertEqual(capability.earpieces.map(\.series), [.hybrid, .polyurethane])
        XCTAssertEqual(capability.earpieces.map(\.sizes), [[.ll, .ss, .m], [.l, .s]])
        XCTAssertEqual(fit.queryPayloads, [[0xF2, 6], [0xF6, 6]])
        for duration: UInt8 in [0, 1, 127, 128, 255] {
            XCTAssertTrue(fit.update([0xF1, 6, duration, 0]))
            XCTAssertEqual(fit.capability?.duration, duration)
            XCTAssertEqual(fit.capability?.durationSeconds, (1...127).contains(duration) ? Int(duration) : nil)
            XCTAssertEqual(fit.capability?.earpieces, [])
        }
        XCTAssertTrue(fit.update([0xF1, 6, 10, 1, 0, 0]))
        XCTAssertEqual(fit.capability?.earpieces, [.init(series: .other, sizes: [])])
    }

    func testStatusOperationAndResultRemainIndependentReportedFacts() throws {
        var fit = SonyEarTipFit(supportedFunctions: [0xF6])
        XCTAssertTrue(fit.update([0xF3, 6, 0, 0, 1, 0]))
        XCTAssertEqual(fit.status, .init(available: true, mode: .out, count: 1, result: .noError))
        XCTAssertNil(fit.operation)
        XCTAssertNil(fit.result)
        XCTAssertTrue(fit.update([0xF5, 6, 1, 1, 255, 1]))
        XCTAssertEqual(fit.status, .init(available: false, mode: .in, count: 255, result: .forcedOut))
        for state: UInt8 in 0...3 {
            for error: UInt8 in 0...7 {
                XCTAssertTrue(fit.update([0xF7, 6, state, error, 255, 254, 1, 2]))
                XCTAssertEqual(fit.operation?.state.rawValue, state)
                XCTAssertEqual(fit.operation?.error.rawValue, error)
                XCTAssertEqual(fit.operation?.count, 255)
                XCTAssertEqual(fit.operation?.index, 254)
                XCTAssertEqual(fit.operation?.series, .polyurethane)
                XCTAssertEqual(fit.operation?.size, .m)
            }
        }
        XCTAssertTrue(fit.update([0xF9, 6, 2, 0, 1, 0, 0xFF, 0xFF]))
        XCTAssertEqual(fit.operation?.state, .completed)
        XCTAssertEqual(fit.operation?.series, .notDetermined)
        XCTAssertEqual(fit.operation?.size, .notDetermined)
        XCTAssertNil(fit.result)
        XCTAssertTrue(fit.update([0xFB, 6, 0, 1, 1, 2, 0, 4]))
        XCTAssertEqual(fit.result, .init(left: .good, right: .poor, bestSeriesLeft: .polyurethane,
                                       bestSeriesRight: .hybrid, bestSizeLeft: .ss, bestSizeRight: .ll))
        XCTAssertTrue(fit.update([0xFD, 6, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(fit.result, .init(left: .poor, right: .good, bestSeriesLeft: .notDetermined,
                                       bestSeriesRight: .notDetermined, bestSizeLeft: .notDetermined,
                                       bestSizeRight: .notDetermined))
        XCTAssertEqual(try XCTUnwrap(fit.status).mode, .in)
        XCTAssertEqual(fit.operation?.state, .completed)
    }

    func testMalformedAndUnknownPacketsNeverMutatePriorObservations() {
        var fit = SonyEarTipFit(supportedFunctions: [0xF6])
        for payload in validPayloads { XCTAssertTrue(fit.update(payload)) }
        let prior = fit
        for payload in validPayloads {
            for count in 0..<payload.count {
                XCTAssertFalse(fit.update(Array(payload.prefix(count))))
                XCTAssertEqual(fit, prior)
            }
            XCTAssertFalse(fit.update(payload + [0]))
            XCTAssertEqual(fit, prior)
        }
        let malformed: [[UInt8]] = [
            [0xF1, 6, 10, 2, 1, 1, 0], [0xF1, 6, 10, 1, 1, 2, 0],
            [0xF1, 6, 10, 0, 1, 0], [0xF1, 6, 10, 1, 1, 255, 0],
            [0xF1, 6, 10, 1, 4, 0], [0xF1, 6, 10, 1, 0xFE, 0],
            [0xF1, 6, 10, 1, 0xFF, 0], [0xF1, 6, 10, 1, 1, 1, 5],
            [0xF1, 6, 10, 1, 1, 1, 0xFE], [0xF1, 6, 10, 1, 1, 1, 0xFF],
            [0xF0, 6], [0xF2, 6], [0xF4, 6, 1, 1], [0xF6, 6],
            [0xF8, 6, 0, 0, 1, 0xFF], [0xFA, 6], [0xFC, 6, 0, 0, 1, 1, 2, 2]
        ]
        for payload in malformed {
            XCTAssertFalse(fit.update(payload), "\(payload)")
            XCTAssertEqual(fit, prior)
        }
        let enumBoundaries: [(payload: [UInt8], fields: [(Int, [UInt8])])] = [
            ([0xF3, 6, 0, 1, 1, 0], [(2, [2, 255]), (3, [2, 255]), (5, [2, 255])]),
            ([0xF7, 6, 1, 0, 1, 0, 1, 2], [(2, [4, 255]), (3, [8, 255]), (6, [4, 254]), (7, [5, 254])]),
            ([0xFB, 6, 0, 1, 1, 2, 0, 4], [(2, [2, 255]), (3, [2, 255]), (4, [4, 254]),
                                           (5, [4, 254]), (6, [5, 254]), (7, [5, 254])])
        ]
        for (payload, fields) in enumBoundaries {
            for (index, values) in fields {
                for value in values {
                    var invalid = payload
                    invalid[index] = value
                    XCTAssertFalse(fit.update(invalid), "\(invalid)")
                    XCTAssertEqual(fit, prior)
                    invalid[0] += 2
                    XCTAssertFalse(fit.update(invalid), "\(invalid)")
                    XCTAssertEqual(fit, prior)
                }
            }
        }
    }

    func testSingleMeasurementPayloadsDoNotForceStartOrRequestHistoricalResults() {
        XCTAssertEqual(SonyEarTipFit.capabilityQueryPayload, [0xF0, 6])
        XCTAssertEqual(SonyEarTipFit.statusQueryPayload, [0xF2, 6])
        XCTAssertEqual(SonyEarTipFit.operationQueryPayload, [0xF6, 6])
        XCTAssertEqual(SonyEarTipFit.enterModePayload, [0xF4, 6, 1, 1])
        XCTAssertEqual(SonyEarTipFit.exitModePayload, [0xF4, 6, 0, 1])
        for series: SonyEarTipFit.Series in [.other, .polyurethane, .hybrid, .softFitting] {
            XCTAssertEqual(SonyEarTipFit.startPayload(series: series), [0xF8, 6, 0, 0, series.rawValue, 0xFF])
            XCTAssertEqual(SonyEarTipFit.cancelPayload(series: series), [0xF8, 6, 1, 0, series.rawValue, 0xFF])
        }
    }

    func testSelectedSeriesReadRequiresAdvertisedSupportAndPreservesNotDetermined() {
        var fit = SonyEarTipFit(supportedFunctions: [0xF6, 0xF7])
        XCTAssertTrue(fit.supportsEarpieceSelection)
        XCTAssertEqual(fit.queryPayloads, [[0xF0, 6], [0xF2, 6], [0xF6, 6], [0xF6, 7]])
        XCTAssertTrue(fit.update([0xF1, 6, 5, 1, 1, 1, 2]))
        XCTAssertNil(fit.measurementSeries)
        for value: UInt8 in [0, 1, 2, 3, 255] {
            for opcode: UInt8 in [0xF7, 0xF9] {
                XCTAssertTrue(fit.update([opcode, 7, value]))
                XCTAssertEqual(fit.selectedSeries?.rawValue, value)
                XCTAssertEqual(fit.measurementSeries?.rawValue, value)
            }
        }
        XCTAssertEqual(fit.selectedSeries?.title, "Not determined")
        let prior = fit
        for payload: [UInt8] in [[0xF7, 7], [0xF7, 7, 1, 0], [0xF7, 7, 4], [0xF9, 7, 254],
                                 [0xF1, 7, 1], [0xF3, 7, 0], [0xF5, 7, 1], [0xF8, 7, 2]] {
            XCTAssertFalse(fit.update(payload))
            XCTAssertEqual(fit, prior)
        }
        XCTAssertFalse(fit.update([0xF7, 7, 1], frameType: 0x0E))
        XCTAssertEqual(fit, prior)
    }

    func testFallbackSeriesIsUsedOnlyWithoutSelectionSupport() {
        for functions: Set<UInt8> in [[0xF6], [0xF6, 0xF7]] {
            var fit = SonyEarTipFit(supportedFunctions: functions)
            XCTAssertNil(fit.measurementSeries)
            XCTAssertTrue(fit.update([0xF1, 6, 5, 2, 2, 1, 2, 1, 1, 3]))
            XCTAssertEqual(fit.measurementSeries, functions.contains(0xF7) ? nil : .hybrid)
            XCTAssertTrue(fit.update([0xF1, 6, 5, 0]))
            XCTAssertEqual(fit.measurementSeries, functions.contains(0xF7) ? nil : .other)
        }
    }

    private var validPayloads: [[UInt8]] {
        [[0xF1, 6, 10, 2, 1, 2, 0, 3, 2, 1, 2], [0xF3, 6, 0, 0, 1, 0],
         [0xF5, 6, 0, 1, 1, 0], [0xF7, 6, 0, 0, 1, 0, 1, 0xFF],
         [0xF9, 6, 1, 0, 1, 0, 1, 0xFF], [0xFB, 6, 1, 0, 1, 2, 2, 3],
         [0xFD, 6, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF]]
    }
}
