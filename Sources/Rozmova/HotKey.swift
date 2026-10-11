import Carbon.HIToolbox

/// A system-wide shortcut. Carbon's hot keys work without the Accessibility permission that
/// watching every key press would need.
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `modifiers` are Carbon flags such as `controlKey | optionKey`.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x524F_5A4D), id: id) // "ROZM"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.info("Hot key not registered: \(status)")
            return nil
        }
        self.ref = ref
        Self.actions[id] = action
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
        }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension HotKey {
    static let recordShortcut = "⌃⌥R"

    /// ⌃⌥R: start or stop a recording.
    static func record(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey, action: action)
    }
}

extension Notification.Name {
    /// Posted by the settings window when the shortcut is switched on or off.
    static let rozmovaHotKeyChanged = Notification.Name("RozmovaHotKeyChanged")
}
