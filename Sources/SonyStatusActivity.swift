#if !ACOUPLET_PUBLIC_APIS_ONLY
import AppKit
#if ACOUPLET_STATUS_ACTIVITY
import ActivityKit
import OSLog
#endif

@MainActor
final class SonyStatusActivity {
    typealias State = AcoupletStatusAttributes.ContentState

    struct Session {
        let isActive: @MainActor () -> Bool
        let update: @MainActor (State) async -> Void
        let end: @MainActor () async -> Void
    }

    enum Presentation {
        case accepted, busy, unavailable
    }

    private let canPresent: (NSView?) -> Bool
    private let request: (State) -> Session?
    private let lifetime: BannerLifetime
    private var session: Session?
    private var updateTask: Task<Void, Never>?
    private var isEnding = false
    var onAvailable: () -> Void = {}

    init(lifetime: BannerLifetime = BannerLifetime(), canPresent: @escaping (NSView?) -> Bool,
         request: @escaping (State) -> Session?) {
        self.lifetime = lifetime
        self.canPresent = canPresent
        self.request = request
        lifetime.onExpire = { [weak self] in self?.dismiss() }
    }

    static func system() -> SonyStatusActivity? {
        #if ACOUPLET_STATUS_ACTIVITY
        if #available(macOS 27.3, *) {
            return SonyStatusActivity(canPresent: { anchor in
                guard let destination = BannerPlacement.current(anchorView: anchor), destination.isActiveDisplay,
                      destination.screen.hasAcoupletDynamicIsland else { return false }
                return ActivityAuthorizationInfo().areActivitiesEnabled
            }, request: { state in
                do {
                    let id = try Activity.request(attributes: AcoupletStatusAttributes(), content: content(state),
                                                  pushType: nil, style: .transient).id
                    return Session(isActive: {
                        let state = activity(id)?.activityState
                        return state == .active || state == .stale
                    }, update: { await activity(id)?.update(content($0)) },
                       end: { await activity(id)?.end(nil, dismissalPolicy: .immediate) })
                } catch {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.baglayan.Acouplet", category: "NoiseModeHUD")
                        .info("Live Activity request declined: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            })
        }
        #endif
        return nil
    }

    static func endInterruptedActivities() {
        #if ACOUPLET_STATUS_ACTIVITY
        if #available(macOS 27.3, *) {
            for id in Activity<AcoupletStatusAttributes>.activities.map(\.id) {
                Task { await activity(id)?.end(nil, dismissalPolicy: .immediate) }
            }
        }
        #endif
    }

    #if ACOUPLET_STATUS_ACTIVITY
    @available(macOS 27.3, *)
    nonisolated private static func activity(_ id: String) -> Activity<AcoupletStatusAttributes>? {
        Activity<AcoupletStatusAttributes>.activities.first { $0.id == id }
    }

    @available(macOS 27.3, *)
    private static func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(BannerLifetime.duration))
    }
    #endif

    func present(_ state: State, anchorView: NSView?, replacing: Bool) -> Presentation {
        guard !isEnding else { return .busy }
        guard canPresent(anchorView) else {
            if session != nil {
                dismiss()
                return .busy
            }
            return .unavailable
        }
        if let session, session.isActive() {
            guard replacing else { return .busy }
            let previous = updateTask
            previous?.cancel()
            updateTask = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await session.update(state)
            }
        } else {
            updateTask?.cancel()
            updateTask = nil
            session = request(state)
            guard session != nil else {
                lifetime.dismissed()
                return .unavailable
            }
        }
        lifetime.presented()
        return .accepted
    }

    func dismiss() {
        guard let session else { return }
        self.session = nil
        isEnding = true
        lifetime.dismissed()
        let previous = updateTask
        previous?.cancel()
        updateTask = nil
        Task { [weak self] in
            await previous?.value
            await session.end()
            guard let self else { return }
            isEnding = false
            onAvailable()
        }
    }

    isolated deinit {
        dismiss()
    }
}
#endif
