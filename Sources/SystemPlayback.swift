#if !ACOUPLET_PUBLIC_APIS_ONLY
import Combine
import Darwin
import Foundation

@MainActor
final class SystemPlayback: ObservableObject {
    enum Command: UInt32 {
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    typealias Reply = @MainActor @Sendable ([UInt32]?) -> Void
    typealias Sender = (Command, @escaping Reply) -> Bool

    @Published private(set) var error: String?
    @Published private(set) var lastCommand: Command?
    var isAvailable: Bool { sender != nil }

    private let sender: Sender?
    private var pendingCommandID: UUID?

    convenience init(simulated: Bool = false) {
        self.init(sender: simulated ? { _, reply in
            reply([0])
            return true
        } : Self.makeSender())
    }

    init(sender: Sender?) {
        self.sender = sender
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let sender else {
            error = String(localized: "System playback controls are unavailable.")
            return false
        }
        let commandID = UUID()
        pendingCommandID = commandID
        error = nil
        let submitted = sender(command) { [weak self] statuses in
            guard let self, self.pendingCommandID == commandID else { return }
            self.pendingCommandID = nil
            if statuses?.contains(0) != true {
                self.error = String(localized: "The current Mac player did not confirm the command.")
            }
        }
        if submitted {
            lastCommand = command
        } else {
            pendingCommandID = nil
            error = String(localized: "The playback command could not be sent.")
        }
        return submitted
    }

    private static let library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW | RTLD_LOCAL)

    private static func makeSender() -> Sender? {
        typealias NativeSender = @convention(c) (UInt32, CFDictionary?, DispatchQueue, @convention(block) (CFArray?) -> Void) -> Bool
        guard let library, let symbol = dlsym(library, "MRMediaRemoteSendCommandWithReply") else { return nil }
        let send = unsafeBitCast(symbol, to: NativeSender.self)
        return { command, reply in
            send(command.rawValue, nil, .main) { rawStatuses in
                let statuses = (rawStatuses as? [Any])?.compactMap { ($0 as? NSNumber)?.uint32Value }
                Task { @MainActor in reply(statuses) }
            }
        }
    }
}
#endif
