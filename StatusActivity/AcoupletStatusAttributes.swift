#if ACOUPLET_STATUS_ACTIVITY
import ActivityKit
#endif

struct AcoupletStatusAttributes: Codable, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let title: String
        let subtitle: String?
        let systemImage: String
        let percent: Int?
    }
}

#if ACOUPLET_STATUS_ACTIVITY
@available(macOS 27.3, *)
extension AcoupletStatusAttributes: ActivityAttributes {}
#endif
