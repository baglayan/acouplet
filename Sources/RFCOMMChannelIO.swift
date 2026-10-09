import Foundation
@preconcurrency import IOBluetooth

protocol RFCOMMChannel: AnyObject {
    func isOpen() -> Bool
    func getMTU() -> BluetoothRFCOMMMTU
    func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn
    func setDelegate(_ delegate: Any!) -> IOReturn
    func close() -> IOReturn
}

extension IOBluetoothRFCOMMChannel: RFCOMMChannel {}

final class RFCOMMChannelIO: @unchecked Sendable {
    private var channel: (any RFCOMMChannel)?
    private let writeQueue = DispatchQueue(label: "dev.baglayan.Acouplet.rfcomm-write", qos: .utility)
    private let lock = NSLock()
    private var retired = false

    init(channel: any RFCOMMChannel) {
        self.channel = channel
    }

    @MainActor
    func write(_ data: Data, willSend: (@MainActor @Sendable () -> Bool)? = nil, completion: @escaping @MainActor @Sendable (IOReturn) -> Void) {
        writeQueue.async {
            let retired = self.lock.withLock { self.retired }
            guard !retired else {
                DispatchQueue.main.async { completion(kIOReturnAborted) }
                return
            }
            if let willSend, !DispatchQueue.main.sync(execute: { willSend() }) {
                DispatchQueue.main.async { completion(kIOReturnAborted) }
                return
            }
            var buffer = data
            let result = buffer.withUnsafeMutableBytes {
                self.channel!.writeSync($0.baseAddress, length: UInt16($0.count))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    @MainActor
    func close(completion: @escaping @MainActor @Sendable () -> Void) {
        let alreadyRetired = lock.withLock {
            let previous = retired
            retired = true
            return previous
        }
        guard !alreadyRetired else { return }
        DispatchQueue.global(qos: .utility).async {
            self.channel!.setDelegate(nil)
            self.channel!.close()
            self.writeQueue.async {
                self.channel = nil
                DispatchQueue.main.async { completion() }
            }
        }
    }
}
