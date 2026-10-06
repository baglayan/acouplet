import Foundation
@preconcurrency import IOBluetooth

@MainActor
final class FastPairTransport: NSObject {
    private static let serviceBytes: [UInt8] = [
        0xDF, 0x21, 0xFE, 0x2C, 0x25, 0x15, 0x4F, 0xDB,
        0x88, 0x86, 0xF1, 0x2C, 0x4D, 0x67, 0x92, 0x7C
    ]

    private let onOpen: () -> Void
    private let onData: (Data) -> Void
    private let onFailure: (String) -> Void
    private var session: UUID?
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var channelDelegate: ChannelDelegate?
    private var discovery: ServiceDiscovery?
    private var openTimeout: DispatchWorkItem?
    private var writes: [UInt: NSMutableData] = [:]
    private var nextWriteID: UInt = 0
    private var isOpen = false

    init(onOpen: @escaping () -> Void, onData: @escaping (Data) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.onOpen = onOpen
        self.onData = onData
        self.onFailure = onFailure
        super.init()
    }

    isolated deinit {
        openTimeout?.cancel()
        channelDelegate?.retire()
        channel?.close()
    }

    func open(address: String) {
        close()
        guard let target = IOBluetoothDevice(addressString: address),
              target.isPaired(), target.isConnected() else {
            onFailure(String(localized: "Connect your paired earbuds before finding them."))
            return
        }
        let identifier = UUID()
        session = identifier
        device = target
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == identifier else { return }
            self.fail(String(localized: "The earbud finding connection timed out."))
        }
        openTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        resolveChannel(on: target, session: identifier, discoverIfMissing: true)
    }

    func send(_ data: Data, isStopping: Bool = false) -> Bool {
        guard isOpen, let channel, channel.isOpen(),
              device?.isPaired() == true, device?.isConnected() == true,
              !channel.isTransmissionPaused(), writes.count < (isStopping ? 9 : 8), !data.isEmpty,
              data.count <= Int(channel.getMTU()), data.count <= Int(UInt16.max) else { return false }
        nextWriteID += 1
        let identifier = nextWriteID
        let buffer = NSMutableData(data: data)
        writes[identifier] = buffer
        let result = channel.writeAsync(buffer.mutableBytes, length: UInt16(data.count),
                                        refcon: UnsafeMutableRawPointer(bitPattern: identifier))
        guard result == kIOReturnSuccess else {
            writes[identifier] = nil
            return false
        }
        return true
    }

    func close() {
        session = nil
        isOpen = false
        openTimeout?.cancel()
        openTimeout = nil
        let oldChannel = channel
        channel = nil
        channelDelegate?.retire()
        oldChannel?.close()
        channelDelegate = nil
        writes.removeAll()
        discovery = nil
        device = nil
    }

    private func resolveChannel(on target: IOBluetoothDevice, session identifier: UUID,
                                discoverIfMissing: Bool) {
        guard session == identifier else { return }
        guard target.isPaired(), target.isConnected() else {
            fail(String(localized: "The earbuds disconnected."))
            return
        }
        let uuid = Self.serviceBytes.withUnsafeBytes {
            IOBluetoothSDPUUID(bytes: $0.baseAddress!, length: Self.serviceBytes.count)
        }
        guard let record = target.getServiceRecord(for: uuid) else {
            guard discoverIfMissing else {
                fail(String(localized: "These earbuds do not offer the finding service."))
                return
            }
            let query = ServiceDiscovery { [weak self] foundDevice, status in
                guard let self, self.session == identifier, self.device === foundDevice else { return }
                self.discovery = nil
                guard status == kIOReturnSuccess else {
                    self.fail(String(localized: "Could not discover the earbud finding service."))
                    return
                }
                self.resolveChannel(on: foundDevice, session: identifier, discoverIfMissing: false)
            }
            discovery = query
            let result = target.performSDPQuery(query)
            if result != kIOReturnSuccess { query.finish(target, status: result) }
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess,
              (1...30).contains(channelID) else {
            fail(String(localized: "The earbud finding service has no valid connection channel."))
            return
        }
        let delegate = ChannelDelegate(owner: self, session: identifier)
        channelDelegate = delegate
        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = target.openRFCOMMChannelAsync(&openedChannel, withChannelID: channelID, delegate: delegate)
        channel = openedChannel
        delegate.channel = openedChannel
        guard result == kIOReturnSuccess, openedChannel != nil else {
            fail(String(localized: "Could not open the earbud finding connection."))
            return
        }
    }

    private func fail(_ message: String) {
        close()
        onFailure(message)
    }

    private func didOpen(_ openedChannel: IOBluetoothRFCOMMChannel, status: IOReturn, session identifier: UUID) {
        guard channel === openedChannel, session == identifier else { return }
        guard status == kIOReturnSuccess, device?.isConnected() == true else {
            fail(String(localized: "Could not open the earbud finding connection."))
            return
        }
        openTimeout?.cancel()
        openTimeout = nil
        isOpen = true
        onOpen()
    }

    private func didReceive(_ data: Data, from source: IOBluetoothRFCOMMChannel, session identifier: UUID) {
        guard channel === source, session == identifier, isOpen else { return }
        onData(data)
    }

    private func didWrite(on source: IOBluetoothRFCOMMChannel, identifier: UInt, status: IOReturn,
                          session sessionID: UUID) {
        guard channel === source, session == sessionID, writes.removeValue(forKey: identifier) != nil else { return }
        if status != kIOReturnSuccess {
            fail(String(localized: "Could not send the earbud finding command."))
        }
    }

    private func didClose(_ source: IOBluetoothRFCOMMChannel, session identifier: UUID) {
        guard channel === source, session == identifier else { return }
        fail(String(localized: "The earbud finding connection closed."))
    }

    @MainActor
    private final class ChannelDelegate: NSObject {
        weak var owner: FastPairTransport?
        let session: UUID
        var channel: IOBluetoothRFCOMMChannel?
        private var retainedSelf: ChannelDelegate?

        init(owner: FastPairTransport, session: UUID) {
            self.owner = owner
            self.session = session
        }

        func retire() {
            owner = nil
            if retainedSelf == nil { channel?.setDelegate(nil) }
            DispatchQueue.main.async { withExtendedLifetime(self) {} }
        }

        @objc nonisolated
        func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel, status: IOReturn) {
            DispatchQueue.main.async {
                if status == kIOReturnSuccess, self.owner != nil { self.retainedSelf = self }
                self.owner?.didOpen(channel, status: status, session: self.session)
            }
        }

        @objc nonisolated
        func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel, data pointer: UnsafeMutableRawPointer,
                               length: Int) {
            guard length > 0 else { return }
            let data = Data(bytes: pointer, count: length)
            DispatchQueue.main.async { self.owner?.didReceive(data, from: channel, session: self.session) }
        }

        @objc nonisolated
        func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel,
                                        refcon: UnsafeMutableRawPointer?, status: IOReturn) {
            let identifier = UInt(bitPattern: refcon)
            DispatchQueue.main.async {
                self.owner?.didWrite(on: channel, identifier: identifier, status: status, session: self.session)
            }
        }

        @objc nonisolated
        func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel) {
            DispatchQueue.main.async {
                channel.setDelegate(nil)
                self.owner?.didClose(channel, session: self.session)
                self.channel = nil
                self.retainedSelf = nil
            }
        }
    }

    @MainActor
    private final class ServiceDiscovery: NSObject {
        let complete: (IOBluetoothDevice, IOReturn) -> Void
        private var retainedSelf: ServiceDiscovery?

        init(complete: @escaping (IOBluetoothDevice, IOReturn) -> Void) {
            self.complete = complete
            super.init()
            retainedSelf = self
        }

        func finish(_ device: IOBluetoothDevice, status: IOReturn) {
            defer { retainedSelf = nil }
            complete(device, status)
        }

        @objc nonisolated
        func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            DispatchQueue.main.async { self.finish(device, status: status) }
        }
    }
}
