import Foundation

@main
struct BannerLifetimeCheck {
    @MainActor
    static func main() {
        let lifetime = BannerLifetime()
        var expirations = 0
        lifetime.onExpire = { expirations += 1 }
        lifetime.presented()
        let original = lifetime.timer!
        precondition((3.9...4).contains(original.fireDate.timeIntervalSinceNow))
        lifetime.keepAliveChanged(0)
        precondition(lifetime.timer === original)
        lifetime.keepAliveChanged(1)
        precondition(lifetime.timer == nil && !original.isValid)
        lifetime.keepAliveChanged(2)
        precondition(lifetime.timer == nil)
        lifetime.presented()
        precondition(lifetime.timer == nil)
        lifetime.keepAliveChanged(0)
        let resumed = lifetime.timer!
        precondition((3.9...4).contains(resumed.fireDate.timeIntervalSinceNow))
        lifetime.keepAliveChanged(0)
        precondition(lifetime.timer === resumed)
        lifetime.presented()
        precondition(!resumed.isValid && lifetime.timer !== resumed)
        lifetime.dismissed()
        precondition(lifetime.timer == nil)
        lifetime.keepAliveChanged(0)
        precondition(lifetime.timer == nil)
        lifetime.presented()
        let start = Date()
        RunLoop.main.run(until: start.addingTimeInterval(4.2))
        precondition(expirations == 1 && lifetime.timer == nil)
        print("PASS native-evidenced4s deadline, no-op repeated reasons, hold, full renewal, replacement, dismissal, one expiry")
    }
}
