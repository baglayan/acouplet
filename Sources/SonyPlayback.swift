import Foundation

enum SonyPlaybackState: UInt8, Sendable {
    case unsettled = 0, playing, paused, stopped
}

enum SonyPlaybackCommand: UInt8, Sendable {
    case pause = 1, next, previous
    case play = 7
}

struct SonyTrack: Equatable, Sendable {
    let title: String?
    let album: String?
    let artist: String?
    let genre: String?

    init?(payload: [UInt8]) {
        var offset = 2
        var names: [String?] = []
        for _ in 0..<4 {
            guard offset + 2 <= payload.count else { return nil }
            let status = payload[offset]
            let end = offset + 2 + Int(payload[offset + 1])
            guard payload[offset + 1] <= 128, end <= payload.count,
                  let name = String(bytes: payload[(offset + 2)..<end], encoding: .utf8) else { return nil }
            names.append(status == 2 && !name.isEmpty ? name : nil)
            offset = end
        }
        guard offset == payload.count else { return nil }
        title = names[0]
        album = names[1]
        artist = names[2]
        genre = names[3]
    }
}

struct SonyPlayback: Equatable, Sendable {
    let generation: SonyProtocolInfo.Generation
    let isSupported: Bool
    let playbackInquiryType: UInt8
    let supportsCallVolume: Bool
    let supportsMute: Bool
    private(set) var hasReceivedCapabilities = false
    private(set) var available: Bool?
    private(set) var state: SonyPlaybackState?
    private(set) var musicCallStatus: UInt8?
    private(set) var playbackControlAvailable: Bool?
    private(set) var musicMuted: Bool?
    private(set) var callMuted: Bool?
    private(set) var musicVolumeRange: ClosedRange<Int>?
    private(set) var callVolumeRange: ClosedRange<Int>?
    private var reportedMusicVolume: Int?
    private var reportedCallVolume: Int?
    private(set) var track: SonyTrack?

    init(supportedFunctions: Set<UInt8> = [], generation: SonyProtocolInfo.Generation = .v2) {
        self.generation = generation
        let function = (generation == .v1 ? [UInt8(0xA1)] : [0xA1, 0xA2, 0xA3, 0xA4]).first { supportedFunctions.contains($0) }
        isSupported = function != nil
        playbackInquiryType = function == 0xA3 ? 2 : function == 0xA4 ? 3 : 1
        supportsCallVolume = generation == .v2 && function != nil && function != 0xA4
        supportsMute = generation == .v2 && function == 0xA2
    }

    var capabilityQueryPayload: [UInt8] { [0xA0, playbackInquiryType] }
    var statusQueryPayload: [UInt8] { [0xA2, playbackInquiryType] }
    var musicVolumeQueryPayload: [UInt8] { generation == .v1 ? [0xA6, 0x01, 0x20] : [0xA6, supportsMute ? 0x30 : 0x20] }
    var callVolumeQueryPayload: [UInt8]? { supportsCallVolume ? [0xA6, supportsMute ? 0x31 : 0x21] : nil }

    var queryPayloads: [[UInt8]] {
        guard isSupported else { return [] }
        return generation == .v1 ? [capabilityQueryPayload, statusQueryPayload, musicVolumeQueryPayload]
            : [capabilityQueryPayload, statusQueryPayload, [0xA6, playbackInquiryType], musicVolumeQueryPayload]
                + (callVolumeQueryPayload.map { [$0] } ?? [])
    }

    func queryPayload(for payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 2 else { return nil }
        switch payload[0] {
        case 0xA1: return payload[1] == playbackInquiryType ? capabilityQueryPayload : nil
        case 0xA3, 0xA5: return payload[1] == playbackInquiryType ? statusQueryPayload : nil
        case 0xA6, 0xA7, 0xA8, 0xA9:
            if generation == .v1 {
                guard payload.count == (payload[0] == 0xA6 ? 3 : 4), payload[1...2] == [1, 0x20] else { return nil }
                return musicVolumeQueryPayload
            }
            return queryPayloads.contains([0xA6, payload[1]]) ? [0xA6, payload[1]] : nil
        default: return nil
        }
    }

    var volume: Int? {
        guard let reportedMusicVolume, musicVolumeRange?.contains(reportedMusicVolume) == true else { return nil }
        return reportedMusicVolume
    }

    var callVolume: Int? {
        guard let reportedCallVolume, callVolumeRange?.contains(reportedCallVolume) == true else { return nil }
        return reportedCallVolume
    }

    var hasKnownStatus: Bool {
        available != nil && state != nil && (!supportsCallVolume || musicCallStatus == 0 || musicCallStatus == 1)
            && (playbackInquiryType == 1 || playbackControlAvailable != nil)
    }

    var canControl: Bool {
        generation == .v2 && isSupported && available == true && (!supportsCallVolume || musicCallStatus == 0)
            && (playbackInquiryType == 1 || playbackControlAvailable == true) && state != nil && state != .unsettled
    }

    var canControlMusicVolume: Bool {
        isSupported && available == true && (!supportsCallVolume || musicCallStatus == 0) && volume != nil
    }

    var canControlCallVolume: Bool {
        supportsCallVolume && available == true && musicCallStatus == 1 && callVolume != nil
    }

    func commandPayload(_ command: SonyPlaybackCommand) -> [UInt8]? {
        canControl ? [0xA4, playbackInquiryType == 3 ? 3 : 1, 0x00, command.rawValue] : nil
    }

    func volumePayload(_ value: Int) -> [UInt8]? {
        guard canControlMusicVolume, musicVolumeRange?.contains(value) == true else { return nil }
        return [0xA8] + musicVolumeQueryPayload.dropFirst() + [UInt8(value)]
    }

    func callVolumePayload(_ value: Int) -> [UInt8]? {
        guard canControlCallVolume, callVolumeRange?.contains(value) == true, let callVolumeQueryPayload else { return nil }
        return [0xA8] + callVolumeQueryPayload.dropFirst() + [UInt8(value)]
    }

    @discardableResult
    mutating func update(_ payload: [UInt8]) -> Bool {
        guard isSupported, payload.count >= 2 else { return false }
        if generation == .v1 {
            switch (payload[0], payload[1]) {
            case (0xA1, 0x01):
                guard payload.count == 5 else { return false }
                hasReceivedCapabilities = true
                musicVolumeRange = payload[2] > 0 ? 0...(Int(payload[2]) - 1) : nil
            case (0xA3, 0x01), (0xA5, 0x01):
                guard payload.count == 4 else { return false }
                available = payload[2] <= 1 ? payload[2] == 0 : nil
                state = SonyPlaybackState(rawValue: payload[3])
            case (0xA7, 0x01), (0xA9, 0x01):
                guard payload.count == 4, payload[2] == 0x20 else { return false }
                reportedMusicVolume = Int(payload[3])
            default: return false
            }
            return true
        }
        switch payload[0] {
        case 0xA1:
            guard payload[1] == playbackInquiryType, payload.count == (supportsCallVolume ? 4 : 3), payload[2] > 0,
                  !supportsCallVolume || payload[3] > 0 else { return false }
            hasReceivedCapabilities = true
            musicVolumeRange = 0...(Int(payload[2]) - 1)
            callVolumeRange = supportsCallVolume ? 0...(Int(payload[3]) - 1) : nil
        case 0xA3, 0xA5:
            guard payload[1] == playbackInquiryType, payload.count == (playbackInquiryType == 2 ? 6 : 5) else { return false }
            available = payload[2] <= 1 ? payload[2] == 0 : nil
            state = SonyPlaybackState(rawValue: payload[3])
            musicCallStatus = supportsCallVolume ? payload[4] : nil
            if playbackInquiryType != 1 {
                let value = payload[playbackInquiryType == 2 ? 5 : 4]
                playbackControlAvailable = value <= 1 ? value == 0 : nil
            }
        case 0xA7, 0xA9:
            if payload[1] == playbackInquiryType {
                guard let track = SonyTrack(payload: payload) else { return false }
                self.track = track
            } else if payload[1] == musicVolumeQueryPayload[1] || payload[1] == callVolumeQueryPayload?[1] {
                guard payload.count == (supportsMute ? 4 : 3) else { return false }
                if payload[1] == musicVolumeQueryPayload[1] {
                    reportedMusicVolume = Int(payload[2])
                    musicMuted = supportsMute && payload[3] <= 1 ? payload[3] == 0 : nil
                } else {
                    reportedCallVolume = Int(payload[2])
                    callMuted = supportsMute && payload[3] <= 1 ? payload[3] == 0 : nil
                }
            } else {
                return false
            }
        default:
            return false
        }
        return true
    }
}

struct SonyPlaybackReadSequence: Equatable, Sendable {
    private(set) var queries: [[UInt8]]
    private var acknowledged = false
    private var received = false

    var currentQuery: [UInt8]? { queries.first }

    init(queries: [[UInt8]]) {
        self.queries = queries
    }

    mutating func transmitted(_ query: [UInt8]) {
        guard currentQuery == query else { return }
        acknowledged = false
        received = false
    }

    mutating func acknowledge(_ query: [UInt8]) -> Bool {
        guard currentQuery == query else { return false }
        acknowledged = true
        return advance()
    }

    mutating func receive(_ query: [UInt8]) -> Bool {
        guard currentQuery == query else { return false }
        received = true
        return advance()
    }

    private mutating func advance() -> Bool {
        guard acknowledged, received else { return false }
        queries.removeFirst()
        acknowledged = false
        received = false
        return true
    }
}
