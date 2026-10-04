import AppKit
import SwiftUI
import XCTest
@testable import Acouplet

final class EqualizerPresetConfirmationTests: XCTestCase {
    @MainActor
    func testNativeConfirmationHasNoReturnDefaultAndPreservesActionRoles() {
        let profile = SavedEqualizerProfile(id: UUID(), name: "Night", settings: .flat)
        for replacement: EqualizerSettings? in [nil, .flat] {
            let change = EqualizerEditorView.PresetChange(profile: profile, replacement: replacement)
            let alert = change.makeAlert()
            XCTAssertEqual(alert.messageText, replacement == nil ? "Delete Preset?" : "Replace Preset?")
            XCTAssertTrue(alert.informativeText.contains("“Night”"))
            XCTAssertTrue(alert.informativeText.contains("cannot be undone"))
            XCTAssertEqual(alert.buttons.map(\.title), [replacement == nil ? "Delete" : "Replace", "Cancel"])
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
            XCTAssertFalse(alert.buttons[1].hasDestructiveAction)
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1B}")
            XCTAssertTrue(alert.buttons[1].keyEquivalentModifierMask.isEmpty)
            XCTAssertNil(alert.window.defaultButtonCell)
            XCTAssertNil(alert.window.sheetParent)
            XCTAssertFalse(alert.window.isVisible)
        }
    }

    @MainActor
    func testCancellationAndStaleCompletionsCannotConfirmAPresetChange() {
        let profile = SavedEqualizerProfile(id: UUID(), name: "Night", settings: .flat)
        let first = EqualizerEditorView.PresetChange(profile: profile, replacement: nil)
        let second = EqualizerEditorView.PresetChange(profile: profile, replacement: .flat)
        var pending: EqualizerEditorView.PresetChange? = first
        var confirmed: [UUID] = []
        let view = EqualizerPresetConfirmation.ConfirmationView()
        view.change = Binding(get: { pending }, set: { pending = $0 })
        view.onConfirm = { confirmed.append($0.id) }
        view.finish(.alertSecondButtonReturn, for: first)
        XCTAssertNil(pending)
        XCTAssertTrue(confirmed.isEmpty)

        pending = second
        view.finish(.alertFirstButtonReturn, for: first)
        XCTAssertEqual(pending?.id, second.id)
        XCTAssertTrue(confirmed.isEmpty)
        view.finish(.cancel, for: second)
        XCTAssertNil(pending)
        XCTAssertTrue(confirmed.isEmpty)

        pending = second
        view.finish(.alertFirstButtonReturn, for: second)
        view.finish(.alertFirstButtonReturn, for: second)
        XCTAssertNil(pending)
        XCTAssertEqual(confirmed, [second.id])
    }

    @MainActor
    func testDeferredCancellationPreservesANewerRequestAndDismantleClearsState() async {
        let profile = SavedEqualizerProfile(id: UUID(), name: "Night", settings: .flat)
        let first = EqualizerEditorView.PresetChange(profile: profile, replacement: nil)
        let second = EqualizerEditorView.PresetChange(profile: profile, replacement: .flat)
        var pending: EqualizerEditorView.PresetChange? = first
        var confirmed = false
        let view = EqualizerPresetConfirmation.ConfirmationView()
        view.change = Binding(get: { pending }, set: { pending = $0 })
        view.onConfirm = { _ in confirmed = true }
        view.cancel()
        pending = second
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(pending?.id, second.id)
        XCTAssertFalse(confirmed)

        EqualizerPresetConfirmation.dismantleNSView(view, coordinator: ())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(pending)
        XCTAssertNil(view.change)
        XCTAssertNil(view.onConfirm)
        XCTAssertFalse(confirmed)
    }
}
