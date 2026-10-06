#if !ACOUPLET_PUBLIC_APIS_ONLY
import Foundation

struct SonyNativeBatterySnapshot: Equatable, Sendable {
    struct Reading: Equatable, Sendable {
        let level: Int
        let isCharging: Bool
        let observedAt: Date

        init?(_ reading: BatteryReading, observedAt: Date) {
            guard reading.chargingState != .unknown else { return nil }
            level = reading.level
            isCharging = reading.isCharging
            self.observedAt = observedAt
        }

        func isFresh(at date: Date) -> Bool {
            (0...100).contains(level) && observedAt.timeIntervalSince1970.isFinite
                && (-5...45).contains(date.timeIntervalSince(observedAt))
        }
    }

    let identifier: UUID
    let name: String
    private(set) var left: Reading?
    private(set) var right: Reading?
    private(set) var caseBattery: Reading?

    mutating func update(_ batteries: SonyBatteries, type: UInt8, observedAt: Date) {
        switch type {
        case 0x09:
            left = batteries.left.flatMap { Reading($0, observedAt: observedAt) }
            right = batteries.right.flatMap { Reading($0, observedAt: observedAt) }
        case 0x0A:
            caseBattery = batteries.caseBattery.flatMap { Reading($0, observedAt: observedAt) }
        default:
            break
        }
    }

    mutating func invalidateUnavailableBuds(leftConnected: Bool?, rightConnected: Bool?) {
        if leftConnected != true { left = nil }
        if rightConnected != true { right = nil }
    }

    func freshReadings(at date: Date) -> [String: Reading] {
        ["Left": left, "Right": right, "Case": caseBattery].compactMapValues {
            guard let reading = $0, reading.isFresh(at: date) else { return nil }
            return reading
        }
    }

    func diagnosticDescription(at date: Date) -> String {
        let fresh = freshReadings(at: date)
        let parts = [("Left", left), ("Right", right), ("Case", caseBattery)].map { name, reading in
            guard let reading else { return "\(name): unknown" }
            return "\(name): \(reading.level)%, \(reading.isCharging ? "charging" : "not charging"), observed \(reading.observedAt.ISO8601Format()), \(fresh[name] != nil ? "fresh" : "expired")"
        }.joined(separator: "; ")
        return parts
    }
}
#endif
