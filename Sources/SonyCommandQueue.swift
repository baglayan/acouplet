struct SonyCommandQueue: Equatable, Sendable {
    private(set) var pending: SonyFrame?
    private var queued: [SonyFrame] = []
    private var nextSequence: UInt8 = 0

    mutating func enqueue(payload: [UInt8], type: UInt8 = 0x0C, prioritizing: Bool = false) -> SonyFrame? {
        let frame = SonyFrame(type: type, sequence: nextSequence, payload: payload)
        nextSequence = 1 - nextSequence
        if pending == nil {
            pending = frame
            return frame
        }
        if prioritizing {
            var sequence = 1 - pending!.sequence
            queued = ([frame] + queued).map {
                let reordered = SonyFrame(type: $0.type, sequence: sequence, payload: $0.payload)
                sequence = 1 - sequence
                return reordered
            }
            nextSequence = sequence
        } else {
            queued.append(frame)
        }
        return nil
    }

    mutating func handleAcknowledgment(sequence: UInt8) -> (accepted: Bool, nextFrame: SonyFrame?) {
        guard let pending, sequence == 1 - pending.sequence else { return (false, nil) }
        self.pending = queued.isEmpty ? nil : queued.removeFirst()
        return (true, self.pending)
    }

    mutating func discardUnsentPending() -> SonyFrame? {
        precondition(pending != nil)
        queued = queued.map { SonyFrame(type: $0.type, sequence: 1 - $0.sequence, payload: $0.payload) }
        nextSequence = 1 - nextSequence
        pending = queued.isEmpty ? nil : queued.removeFirst()
        return pending
    }
}
