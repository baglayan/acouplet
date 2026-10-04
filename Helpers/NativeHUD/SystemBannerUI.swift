import SwiftUI

public class SystemBannerPresenter {}

public enum SystemBannerVariant {
    case banner
    case expanded
    case compact
    case minimal
}

public protocol SystemBannerContent: CustomStringConvertible, Equatable {
    associatedtype Banner: View
    associatedtype Expanded: View
    associatedtype CompactLeading: View
    associatedtype CompactTrailing: View
    associatedtype Minimal: View
    var banner: Banner { get }
    var expanded: Expanded { get }
    var compactLeading: CompactLeading { get }
    var compactTrailing: CompactTrailing { get }
    var minimal: Minimal { get }
    var accessibilityLabel: Text { get }
    var duration: Double? { get }
    var kind: Int { get }
    var preferredPresentationVariant: SystemBannerVariant { get }
    var presentationVariants: [SystemBannerVariant] { get }
    var priority: Int { get }
    var targetDisplayID: UInt32? { get }
    var wantsDismissButton: Bool { get }
    var accessibilityIdentifier: String? { get }
}

public protocol SystemBannerPresenterDelegate: AnyObject {
    func willPresentSystemBanner(for content: any SystemBannerContent)
    func willDismissSystemBanner(for content: any SystemBannerContent)
    func didDismissSystemBanner(for content: any SystemBannerContent)
    func canSystemBannerStayVisible(for content: any SystemBannerContent) -> Bool
}

public enum SystemBannerKeepAliveReason {
    case hovering
    case interacting
    case marqueeing
}

public protocol SystemBannerPresentationHost: AnyObject {
    func presenter(_ presenter: SystemBannerPresenter, stayVisibleFor reasons: [SystemBannerKeepAliveReason])
    func presenterDidDismissSystemBanner(_ presenter: SystemBannerPresenter, transitioning: Bool)
}
