import Carbon
import Foundation

/// Global shortcuts via Carbon's RegisterEventHotKey, which fires when this app is not focused.
@MainActor
final class HotkeyCenter {
    var onStore: @MainActor () -> Void = {}
    var onRestore: @MainActor () -> Void = {}
    private(set) var registrationError: String?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false
    private static weak var shared: HotkeyCenter?
    private let signature = OSType(0x576D6E64) // 'Wmnd'

    func register(store: StoredHotkey, restore: StoredHotkey) {
        Self.shared = self
        unregisterKeys()
        var problems: [String] = []
        let handlerStatus = installHandlerIfNeeded()
        if handlerStatus != noErr {
            problems.append("Could not install the shortcut handler (OSStatus \(handlerStatus)).")
        }
        if let status = registerOne(store, id: 1) {
            problems.append("Could not register the Store Windows shortcut (OSStatus \(status)).")
        }
        if let status = registerOne(restore, id: 2) {
            problems.append("Could not register the Restore Windows shortcut (OSStatus \(status)).")
        }
        registrationError = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    static func dispatch(id: UInt32) {
        guard let center = shared else { return }
        if id == 1 {
            center.onStore()
        } else if id == 2 {
            center.onRestore()
        }
    }

    private func installHandlerIfNeeded() -> OSStatus {
        if handlerInstalled { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &spec,
            nil,
            &handlerRef
        )
        if status == noErr {
            handlerInstalled = true
        }
        return status
    }

    private func registerOne(_ hotkey: StoredHotkey, id: UInt32) -> OSStatus? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            return status
        }
        if let ref {
            hotKeyRefs.append(ref)
        }
        return nil
    }

    private func unregisterKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let identifier = hotKeyID.id
    // Carbon delivers this on the main thread. Hop explicitly so the call stays
    // legal if the queue closure is treated as nonisolated.
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotkeyCenter.dispatch(id: identifier)
        }
    }
    return noErr
}
