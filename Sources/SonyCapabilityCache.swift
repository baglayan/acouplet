import Foundation

struct SonyCapabilityIdentity: Codable, Equatable, Sendable {
    static let queryPayload: [UInt8] = [0x02, 0x00]

    let identifier: String
    let counter: UInt8

    init?(payload: [UInt8]) {
        guard payload.count >= 4, payload[0] == 0x03, payload[1] == 0x00,
              payload[3] > 0, payload.count == 4 + Int(payload[3]),
              let identifier = String(bytes: payload.dropFirst(4), encoding: .utf8) else { return nil }
        self.identifier = identifier
        counter = payload[2]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter && lhs.identifier.utf8.elementsEqual(rhs.identifier.utf8)
    }
}

struct SonyCapabilityCache {
    static let savedEntriesKey = "headphones.capabilityCache.v1"
    static let maximumEntries = 32
    static let maximumReplyBytes = 4_096
    static let queryPayloads: [[UInt8]] = [[0xA0, 1], [0xE0, 1], [0xE0, 2], [0xF0, 4]]

    struct Key: Codable, Equatable, Sendable {
        let protocolVersion: UInt32
        let identity: SonyCapabilityIdentity
        let displayLanguage: UInt8
    }

    private struct Entry: Codable {
        let key: Key
        var replies: [String: Data]
    }

    private let defaults: UserDefaults?
    private var entries: [Entry] = []

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        reload()
    }

    private mutating func reload() {
        guard let defaults else { return }
        entries = []
        guard let data = defaults.data(forKey: Self.savedEntriesKey), data.count <= 1_048_576,
              let saved = try? JSONDecoder().decode([Entry].self, from: data), saved.count <= Self.maximumEntries,
              saved.allSatisfy({ entry in
                  (1...255).contains(entry.key.identity.identifier.utf8.count)
                      && !entry.replies.isEmpty && entry.replies.count <= Self.queryPayloads.count
                      && entry.replies.allSatisfy { name, reply in
                          Self.queryPayloads.contains { Self.queryName($0) == name && Self.accepts(reply, for: $0) }
                      }
              }) else { return }
        for entry in saved {
            guard !entries.contains(where: { $0.key == entry.key }) else {
                entries = []
                return
            }
            entries.append(entry)
        }
    }

    mutating func bind(to key: Key) {
        reload()
        let count = entries.count
        entries.removeAll { $0.key != key && $0.key.identity.identifier.utf8.elementsEqual(key.identity.identifier.utf8) }
        if entries.count != count { save() }
    }

    mutating func reply(for query: [UInt8], key: Key) -> [UInt8]? {
        guard Self.queryPayloads.contains(query) else { return nil }
        bind(to: key)
        guard let index = entries.firstIndex(where: { $0.key == key }),
              let reply = entries[index].replies[Self.queryName(query)] else { return nil }
        entries.append(entries.remove(at: index))
        save()
        return Array(reply)
    }

    mutating func store(_ reply: [UInt8], for query: [UInt8], key: Key) {
        guard Self.queryPayloads.contains(query), Self.accepts(Data(reply), for: query) else { return }
        bind(to: key)
        var entry = Entry(key: key, replies: [:])
        if let index = entries.firstIndex(where: { $0.key == key }) { entry = entries.remove(at: index) }
        entry.replies[Self.queryName(query)] = Data(reply)
        entries.append(entry)
        if entries.count > Self.maximumEntries { entries.removeFirst() }
        save()
    }

    mutating func remove(for query: [UInt8], key: Key) {
        reload()
        guard Self.queryPayloads.contains(query), let index = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[index].replies[Self.queryName(query)] = nil
        if entries[index].replies.isEmpty { entries.remove(at: index) }
        save()
    }

    private static func queryName(_ query: [UInt8]) -> String {
        "\(query[0]):\(query[1])"
    }

    private static func accepts(_ reply: Data, for query: [UInt8]) -> Bool {
        (3...maximumReplyBytes).contains(reply.count) && reply.prefix(2) == Data([query[0] + 1, query[1]])
    }

    private func save() {
        if let defaults, let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.savedEntriesKey) }
    }
}
