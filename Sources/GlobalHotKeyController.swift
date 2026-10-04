import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyController {
    // Carbon owns these opaque handles. Marking their storage unsafe-nonisolated
    // lets deinit release them under Swift 6's nonisolated deinit rules.
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let action: @MainActor () -> Void
    private var eventHandlerStatus: OSStatus = noErr
    private var registrationStatus: OSStatus = noErr

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        installEventHandler()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        eventHandlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in controller.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func setEnabled(_ enabled: Bool) -> String? {
        if enabled {
            registerIfNeeded()
            if eventHandlerStatus != noErr {
                return String(localized: "The shortcut could not start. Turn it off and on to try again.")
            }
            if registrationStatus == eventHotKeyExistsErr {
                return String(localized: "Another app is using ⌥⌘A. Free that shortcut, then turn this option off and on to try again.")
            }
            if registrationStatus != noErr {
                return String(localized: "The shortcut could not be registered. Turn it off and on to try again.")
            }
        } else if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        return nil
    }

    private func registerIfNeeded() {
        guard hotKey == nil else { return }
        if eventHandler == nil { installEventHandler() }
        guard eventHandlerStatus == noErr else { return }
        let identifier = EventHotKeyID(
            signature: OSType(0x4143504C), // ACPL
            id: 1
        )
        registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKey
        )
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
