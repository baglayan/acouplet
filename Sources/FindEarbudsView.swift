import AppKit
import SwiftUI

struct FindEarbudsControl: View {
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @State private var showsFinder = false

    var body: some View {
        Group {
            if headphones.supportsEarbudFinding || showsFinder || headphones.earbudFinder?.isBusy == true || headphones.earbudFinder?.mayBeRinging == true {
                Section("Find Earbuds") {
                    Button("Find Earbuds…") {
                        if headphones.beginEarbudFinder() { showsFinder = true }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("finder.open")
                }
            }
        }
        .sheet(isPresented: $showsFinder) {
            if let finder = headphones.earbudFinder {
                FindEarbudsView(finder: finder)
                    .id(ObjectIdentifier(finder))
                    .onChange(of: finder.needsNewControlSession && !finder.isBusy && !finder.mayBeRinging
                              && headphones.supportsEarbudFinding, initial: true) { _, needsReplacement in
                        guard needsReplacement, headphones.earbudFinder === finder else { return }
                        _ = headphones.beginEarbudFinder()
                    }
            }
        }
    }
}

struct FindEarbudsView: View {
    @ObservedObject var finder: EarbudFinderController
    @EnvironmentObject private var headphones: SonyHeadphonesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmationTarget = FastPairRingTarget.left
    @State private var showsConfirmation = false
    @State private var wearingConfirmation: EarbudFindingSession?
    @State private var showsWearingConfirmation = false
    @State private var finalWearingConfirmation: EarbudFindingSession?
    @State private var warningVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find Earbuds").font(.headline)
                Text(finder.deviceName).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("The sound is loud. Keep the earbuds away from your ears and anyone else’s while it plays.")
                    .fixedSize(horizontal: false, vertical: true)
                if finder.wearingDetectionIsUnavailable {
                    Text("Acouplet can’t detect whether these earbuds are in your ears.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("finder.wearingUnavailable")
                }
            }
            VStack(spacing: 12) {
                earbud(.left)
                earbud(.right)
            }
            if !finder.isBusy, !finder.mayBeRinging, !headphones.isReady {
                HeadphoneConnectionView()
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if finder.isAuthenticating || finder.isSavingAuthorization || finder.isCheckingWearing || finder.session?.phase == .connecting {
                        ProgressView().controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("finder.status")
                }
            }
            HStack {
                if finder.isBusy || finder.mayBeRinging {
                    Button("Stop Sound") {
                        if finder.session?.phase == .unconfirmed { finder.retryStop() }
                        else { finder.stop() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!finder.canStop)
                        .accessibilityIdentifier("finder.stop")
                } else if headphones.hasFailedTable2Discovery {
                    Button("Reconnect Controls") { headphones.retryDeviceDiscovery() }
                        .tint(.primary)
                        .disabled(!headphones.canRetryDeviceDiscovery)
                        .accessibilityIdentifier("finder.reconnectControls")
                }
                Spacer(minLength: 12)
                Button("Done") { close() }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)
                    .accessibilityIdentifier("finder.done")
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .presentationSizing(.fitted)
        .presentationPreventsAppTermination(false)
        .confirmationDialog(confirmationTarget == .left ? String(localized: "Play sound in the left earbud?") : String(localized: "Play sound in the right earbud?"),
                            isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("Play Sound") { finder.play(confirmationTarget) }
                .keyboardShortcut(nil)
                .disabled(!finder.canPlay(confirmationTarget))
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Take both earbuds out of your ears before continuing. The sound may become loud.")
        }
        .alert(wearingConfirmationTitle,
               isPresented: $showsWearingConfirmation, presenting: wearingConfirmation) { session in
            Button("Play Anyway") {
                guard let current = finder.session, current.id == session.id else { return }
                if current.wearingConfirmationStatus != false,
                   current.wearingConfirmationStatus != session.wearingConfirmationStatus {
                    wearingConfirmation = current
                    DispatchQueue.main.async { showsWearingConfirmation = true }
                } else {
                    finalWearingConfirmation = current
                }
            }
                .keyboardShortcut(nil)
            Button("Cancel", role: .cancel) {
                if finder.session?.id == session.id { finder.stop() }
            }
            .keyboardShortcut(.defaultAction)
        } message: { _ in
            if finder.session?.wearingConfirmationStatus == nil {
                Text("Acouplet can’t determine whether this earbud is being worn. Make sure this earbud is out of everyone’s ears before playing the loud sound.")
            } else if finder.session?.wearingConfirmationStatus == true {
                Text("A covered sensor can give a false reading. Make sure this earbud is out of everyone’s ears before playing the loud sound.")
            } else {
                Text("Take both earbuds out of your ears before continuing. The sound may become loud.")
            }
        }
        .background(FindEarbudWearingConfirmation(session: $finalWearingConfirmation, finder: finder))
        .onChange(of: finder.session, initial: true) { _, session in
            if session?.phase != .awaitingWearingConfirmation {
                wearingConfirmation = nil
                finalWearingConfirmation = nil
                showsWearingConfirmation = false
            } else if let session, let finalWearingConfirmation,
                      session.wearingConfirmationStatus != false,
                      finalWearingConfirmation.wearingConfirmationStatus != session.wearingConfirmationStatus {
                self.finalWearingConfirmation = nil
                wearingConfirmation = session
                showsWearingConfirmation = true
            } else if finalWearingConfirmation?.id != session?.id {
                wearingConfirmation = session
                showsWearingConfirmation = true
            }
        }
        .onDisappear { finder.dismiss() }
    }

    private var wearingConfirmationTitle: String {
        if finder.session?.wearingConfirmationStatus == nil {
            return wearingConfirmation?.target == .left
                ? String(localized: "Left earbud wear status unknown")
                : String(localized: "Right earbud wear status unknown")
        }
        if finder.session?.wearingConfirmationStatus == true {
            return wearingConfirmation?.target == .left
                ? String(localized: "Left earbud detected in ear")
                : String(localized: "Right earbud detected in ear")
        }
        return wearingConfirmation?.target == .left
            ? String(localized: "Play sound in the left earbud?")
            : String(localized: "Play sound in the right earbud?")
    }

    private func earbud(_ target: FastPairRingTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: target == .left ? "l.circle.fill" : "r.circle.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.title2)
                    .foregroundStyle(target == .right ? Color.red : Color.secondary)
                    .accessibilityHidden(true)
                Text(target == .left ? String(localized: "Left") : String(localized: "Right"))
                Spacer(minLength: 12)
                Button("Play Sound") {
                    confirmationTarget = target
                    showsConfirmation = true
                }
                .keyboardShortcut(nil)
                .tint(.primary)
                .disabled(!finder.canPlay(target))
                .accessibilityLabel(target == .left ? String(localized: "Play sound in the left earbud") : String(localized: "Play sound in the right earbud"))
                .accessibilityIdentifier(target == .left ? "finder.left" : "finder.right")
            }
            if finder.session?.target == target, finder.session?.startedWithWearingOverride == true, finder.mayBeRinging {
                Label {
                    Text("If you’re wearing this earbud, take it out NOW!")
                        .opacity(reduceMotion || warningVisible ? 1 : 0)
                        .animation(nil, value: warningVisible)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("If you’re wearing this earbud, take it out NOW!")
                    .accessibilityIdentifier(target == .left ? "finder.leftWarning" : "finder.rightWarning")
                    .task(id: reduceMotion) {
                        warningVisible = true
                        guard !reduceMotion else { return }
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .milliseconds(800)) }
                            catch { return }
                            warningVisible.toggle()
                        }
                    }
            }
        }
    }

    private var status: String {
        if finder.session?.phase == .unconfirmed {
            return String(localized: "The earbuds haven’t confirmed that the sound stopped. Keep them out of your ears.")
        }
        if let message = finder.message { return message }
        if finder.isAuthenticating { return String(localized: "Authorizing…") }
        if finder.isSavingAuthorization { return String(localized: "Saving authorization…") }
        if finder.isCheckingWearing { return String(localized: "Checking whether the earbuds are being worn…") }
        switch finder.session?.phase {
        case .connecting: return String(localized: "Connecting…")
        case .awaitingWearingConfirmation: return String(localized: "Waiting for confirmation…")
        case .starting: return String(localized: "Starting sound…")
        case .ringing:
            return finder.session?.target == .left
                ? String(localized: "Playing a sound in the left earbud.")
                : String(localized: "Playing a sound in the right earbud.")
        case .stopping: return String(localized: "Stopping sound…")
        case .finished: return String(localized: "Sound stopped.")
        case .failed: return String(localized: "Couldn’t start the locating sound.")
        default: return finder.availabilityMessage ?? String(localized: "The sound gets louder and stops after 30 seconds.")
        }
    }

    private func close() {
        finder.dismiss()
        dismiss()
    }
}

private struct FindEarbudWearingConfirmation: NSViewRepresentable {
    @Binding var session: EarbudFindingSession?
    @ObservedObject var finder: EarbudFinderController

    func makeNSView(context: Context) -> ConfirmationView { ConfirmationView() }

    func updateNSView(_ nsView: ConfirmationView, context: Context) {
        nsView.session = $session
        nsView.finder = finder
        if session == nil { nsView.cancel() }
        else { nsView.updateAuthorization(); nsView.schedulePresentation() }
    }

    static func dismantleNSView(_ nsView: ConfirmationView, coordinator: ()) {
        nsView.cancel()
        nsView.session = nil
        nsView.finder = nil
    }

    final class ConfirmationView: NSView {
        var session: Binding<EarbudFindingSession?>?
        weak var finder: EarbudFinderController?
        private var alert: NSAlert?
        private var checkbox: NSButton?
        private var requestID: UUID?
        private var authenticationRequested = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancel() }
            else { schedulePresentation() }
        }

        func schedulePresentation() {
            DispatchQueue.main.async { [weak self] in self?.present() }
        }

        private func present() {
            guard let request = session?.wrappedValue, let finder,
                  finder.session?.id == request.id, finder.session?.phase == .awaitingWearingConfirmation else {
                cancel()
                return
            }
            guard alert == nil, let window, window.isVisible else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = request.target == .left
                ? String(localized: "Play sound in the left earbud?")
                : String(localized: "Play sound in the right earbud?")
            alert.informativeText = String(format: String(localized: "Are you ABSOLUTELY CERTAIN BEYOND ANY DOUBT that nobody is wearing the earbud right now? This action will be logged as authorized by %@."), finder.accountName)
            let play = alert.addButton(withTitle: String(localized: "Play Sound"))
            play.keyEquivalent = ""
            play.isEnabled = false
            play.setAccessibilityIdentifier("finder.authorizedPlay")
            let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
            cancel.keyEquivalent = "\u{1B}"
            let title = request.target == .left
                ? String(localized: "I verify that nobody is wearing the left earbud right now.")
                : String(localized: "I verify that nobody is wearing the right earbud right now.")
            let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(verificationChanged))
            checkbox.state = .off
            checkbox.setAccessibilityIdentifier("finder.verifyNotWorn")
            checkbox.setAccessibilityLabel(title)
            checkbox.cell?.wraps = true
            checkbox.cell?.isScrollable = false
            checkbox.cell?.lineBreakMode = .byWordWrapping
            let bounds = NSRect(x: 0, y: 0, width: 320, height: CGFloat.greatestFiniteMagnitude)
            checkbox.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                    height: checkbox.cell?.cellSize(forBounds: bounds).height ?? checkbox.intrinsicContentSize.height)
            alert.accessoryView = checkbox
            alert.layout()
            alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            self.alert = alert
            self.checkbox = checkbox
            requestID = request.id
            authenticationRequested = false
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, let alert, self.alert === alert else { return }
                let verified = self.checkbox?.state == .on
                self.alert = nil
                self.checkbox = nil
                self.requestID = nil
                guard self.session?.wrappedValue?.id == request.id else { return }
                self.session?.wrappedValue = nil
                if response == .alertFirstButtonReturn, verified,
                   self.finder?.wearingAuthorization?.id == request.id {
                    self.finder?.confirmWearingOverride(sessionID: request.id)
                } else if self.finder?.session?.id == request.id {
                    self.finder?.stop()
                }
            }
        }

        @objc private func verificationChanged() {
            guard let requestID, let finder, finder.session?.id == requestID else { return }
            authenticationRequested = checkbox?.state == .on
            if authenticationRequested { finder.authenticateWearingOverride(sessionID: requestID) }
            else { finder.cancelWearingAuthorization() }
            updateAuthorization()
        }

        func updateAuthorization() {
            guard let requestID, let finder, let checkbox else { return }
            if authenticationRequested, !finder.isAuthenticating, finder.wearingAuthorization == nil {
                checkbox.state = .off
                authenticationRequested = false
            }
            alert?.buttons.first?.isEnabled = checkbox.state == .on && !finder.isAuthenticating
                && finder.wearingAuthorization?.id == requestID
        }

        func cancel() {
            let presented = alert
            let cancelledID = requestID
            alert = nil
            checkbox = nil
            requestID = nil
            authenticationRequested = false
            if let presented, let parent = presented.window.sheetParent {
                parent.endSheet(presented.window, returnCode: .cancel)
            }
            if let cancelledID, finder?.session?.id == cancelledID { finder?.cancelWearingAuthorization() }
            let binding = session
            guard let requestID = binding?.wrappedValue?.id else { return }
            DispatchQueue.main.async {
                if binding?.wrappedValue?.id == requestID { binding?.wrappedValue = nil }
            }
        }
    }
}
