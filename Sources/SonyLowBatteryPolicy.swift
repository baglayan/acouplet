import Foundation

struct SonyLowBatteryPolicy: Codable, Equatable {
    enum Group: String, Codable, CaseIterable {
        case headphones, earbuds, caseBattery

        var initialThreshold: Int { self == .caseBattery ? 25 : 20 }
    }

    enum Part: String, Codable {
        case headphones, left, right, caseBattery

        var group: Group {
            switch self {
            case .headphones: .headphones
            case .left, .right: .earbuds
            case .caseBattery: .caseBattery
            }
        }
    }

    struct Reading: Equatable {
        let part: Part
        let level: Int
        let isCharging: Bool
        let observedAt: Date

        func isFresh(at date: Date) -> Bool {
            (0...100).contains(level) && observedAt.timeIntervalSince1970.isFinite
                && (-5...45).contains(date.timeIntervalSince(observedAt))
        }
    }

    struct Warning: Equatable {
        let deviceID: String
        let group: Group
        let reading: Reading
        let evaluatedAt: Date
    }

    private struct Record: Codable, Equatable {
        let level: Int
        let lastSeenAt: Date
        let reportedAt: Date

        func threshold(for group: Group) -> Int {
            if level > group.initialThreshold { return group.initialThreshold }
            if level > 10 { return 10 }
            if level > 5 { return 5 }
            return level - 1
        }

        func isExpired(at date: Date) -> Bool {
            abs(date.timeIntervalSince(lastSeenAt)) >= 57_600
                && abs(date.timeIntervalSince(reportedAt)) >= 57_600
        }
    }

    private var records: [String: [Group: Record]] = [:]

    mutating func warnings(for deviceID: String, readings: [Reading], at date: Date) -> [Warning] {
        guard !deviceID.isEmpty else { return [] }
        var deviceRecords = records[deviceID, default: [:]].filter { !$0.value.isExpired(at: date) }
        let fresh = readings.filter { $0.isFresh(at: date) }
        let groups: [Group] = fresh.contains { $0.part == .headphones } ? [.headphones] : [.earbuds, .caseBattery]
        var warnings: [Warning] = []
        for group in groups {
            let available = fresh.filter { $0.part.group == group }
            guard !available.isEmpty else { continue }
            let discharging = available.filter { !$0.isCharging }
            if discharging.allSatisfy({ $0.level >= 50 }) {
                deviceRecords[group] = nil
                continue
            }
            guard let lowest = discharging.min(by: { $0.level < $1.level }),
                  lowest.level <= (deviceRecords[group]?.threshold(for: group) ?? group.initialThreshold) else { continue }
            warnings.append(Warning(deviceID: deviceID, group: group, reading: lowest, evaluatedAt: date))
        }
        records[deviceID] = deviceRecords.isEmpty ? nil : deviceRecords
        return warnings.sorted { $0.reading.level < $1.reading.level }
    }

    mutating func didPresent(_ warning: Warning, at date: Date) {
        guard warning.reading.isFresh(at: date) else { return }
        records[warning.deviceID, default: [:]][warning.group] = Record(
            level: warning.reading.level, lastSeenAt: warning.evaluatedAt, reportedAt: date)
    }
}
