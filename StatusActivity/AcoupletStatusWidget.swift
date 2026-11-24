import SwiftUI
import WidgetKit

@main
struct AcoupletStatusWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AcoupletStatusAttributes.self) { context in
            let state = context.state
            HStack {
                Image(systemName: state.systemImage)
                    .accessibilityHidden(true)
                StatusText(state: state)
                if let percentage = state.batteryPercentage {
                    Text(verbatim: percentage)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.systemImage)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let percentage = state.batteryPercentage {
                        Text(verbatim: percentage)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatusText(state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: state.systemImage)
                    .accessibilityHidden(true)
            } compactTrailing: {
                if let percentage = state.batteryPercentage {
                    Text(verbatim: percentage)
                        .monospacedDigit()
                        .accessibilityLabel(Text(verbatim: state.title))
                        .accessibilityValue(Text(verbatim: percentage))
                } else {
                    Text(verbatim: state.title)
                        .lineLimit(1)
                }
            } minimal: {
                Image(systemName: state.systemImage)
                    .accessibilityLabel(Text(verbatim: state.title))
                    .accessibilityValue(Text(verbatim: state.batteryPercentage ?? ""))
            }
        }
    }
}

private struct StatusText: View {
    let state: AcoupletStatusAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: state.title)
                .font(.headline)
            if let subtitle = state.subtitle {
                Text(verbatim: subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension AcoupletStatusAttributes.ContentState {
    var batteryPercentage: String? {
        percent.map { (Double($0) / 100).formatted(.percent) }
    }
}
