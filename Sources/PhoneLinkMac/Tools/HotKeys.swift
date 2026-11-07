import Carbon.HIToolbox

/// Global shortcuts. This Carbon API needs no permission and doesn't watch other keystrokes.
@MainActor
enum HotKeys {
    static let keyTab = UInt32(kVK_Tab)
    static let controlCommand = UInt32(controlKey | cmdKey)
    static let option = UInt32(optionKey)
    static let optionShift = UInt32(optionKey | shiftKey)
    static let switcherID: UInt32 = 3
    static let switcherBackID: UInt32 = 4
    private static var actions: [UInt32: () -> Void] = [:]
    private static var references: [UInt32: EventHotKeyRef] = [:]
    private static var isInstalled = false
    private static let signature: OSType = 0x44_59_53_4B // DYSK

    /// Returns false if another app already has the shortcut.
    @discardableResult
    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32 = controlCommand, action: @escaping () -> Void) -> Bool {
        installHandler()
        remove(id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { return false }
        references[id] = reference
        actions[id] = action
        return true
    }

    static func remove(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        actions[id] = nil
    }

    static func removeAll() {
        references.keys.forEach(remove)
    }

    private static func installHandler() {
        guard !isInstalled else { return }
        isInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &key
            )
            guard status == noErr else { return status }
            let id = key.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
