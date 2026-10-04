import AppKit
import Combine
import SwiftUI

struct PanelScreenHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScreenHeightView {
        let view = ScreenHeightView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenHeightView, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleReport()
    }

    final class ScreenHeightView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observation: AnyCancellable?
        private var lastHeight: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            lastHeight = nil
            guard let window else { return }
            let names = [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSApplication.didChangeScreenParametersNotification]
            observation = Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
                .filter { [weak window] notification in
                    notification.name == NSApplication.didChangeScreenParametersNotification
                        || notification.object as? NSWindow === window
                }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reportHeight() }
            scheduleReport()
        }

        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in self?.reportHeight() }
        }

        private func reportHeight() {
            guard let height = window?.screen?.visibleFrame.height else { return }
            let availableHeight = height - 16
            guard availableHeight != lastHeight else { return }
            lastHeight = availableHeight
            onChange?(availableHeight)
        }
    }
}
