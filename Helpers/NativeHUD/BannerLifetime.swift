import Foundation

@MainActor
final class BannerLifetime {
    var onExpire: () -> Void = {}
    private(set) var timer: Timer?
    private var isPresented = false
    private var isKeptAlive = false

    func presented() {
        isPresented = true
        updateDeadline()
    }

    func keepAliveChanged(_ count: Int) {
        let value = count > 0
        guard value != isKeptAlive else { return }
        isKeptAlive = value
        if isPresented { updateDeadline() }
    }

    func dismissed() {
        isPresented = false
        isKeptAlive = false
        timer?.invalidate()
        timer = nil
    }

    private func updateDeadline() {
        timer?.invalidate()
        timer = nil
        guard !isKeptAlive else { return }
        let scheduled = Timer(fire: Date().addingTimeInterval(4), interval: 0, repeats: false) { [weak self] fired in
            let identifier = ObjectIdentifier(fired)
            MainActor.assumeIsolated {
                guard let self, self.timer.map(ObjectIdentifier.init) == identifier else { return }
                self.dismissed()
                self.onExpire()
            }
        }
        timer = scheduled
        RunLoop.main.add(scheduled, forMode: .common)
    }
}
