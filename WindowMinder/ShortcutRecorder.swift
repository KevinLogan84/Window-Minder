import AppKit
import SwiftUI

/// Records a global shortcut. The key code comes from the key-down event so it can be registered with Carbon.
struct ShortcutRecorder: View {
    let title: String
    @Binding var hotkey: StoredHotkey
    @State private var recording = false
    @State private var hint: String?

    var body: some View {
        Button {
            recording.toggle()
            hint = nil
            if recording {
                NSApp.activate()
                NSApp.keyWindow?.makeKey()
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(capsuleText)
                    .font(.body.monospaced())
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(recording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: recording ? 2 : 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) shortcut")
        .accessibilityValue(recording ? "Recording" : HotkeyFormatting.displayString(for: hotkey))
        .accessibilityHint("Activate, then press a key combination that includes Control, Option, Shift, or Command.")
        .background {
            KeyDownCatcher(isRecording: recording) { event in
                handle(event)
            } onStopped: {
                recording = false
            }
        }
    }

    private var capsuleText: String {
        if recording {
            return hint ?? "Type shortcut…"
        }
        return HotkeyFormatting.displayString(for: hotkey)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            recording = false
            hint = nil
            return
        }
        let relevant = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !relevant.isEmpty else {
            hint = "Add a modifier key"
            return
        }
        hotkey = StoredHotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: CarbonModifiers.carbon(from: relevant)
        )
        recording = false
        hint = nil
    }
}

private struct KeyDownCatcher: NSViewRepresentable {
    var isRecording: Bool
    var onKey: (NSEvent) -> Void
    var onStopped: () -> Void

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.onKey = onKey
        view.onStopped = onStopped
        return view
    }

    func updateNSView(_ nsView: KeyMonitorView, context: Context) {
        nsView.onKey = onKey
        nsView.onStopped = onStopped
        nsView.isRecording = isRecording
    }
}

private final class KeyMonitorView: NSView {
    var onKey: ((NSEvent) -> Void)?
    var onStopped: (() -> Void)?
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
                start()
            } else {
                stop()
            }
        }
    }

    private var monitor: Any?
    private static weak var active: KeyMonitorView?

    override func isAccessibilityElement() -> Bool { false }

    private func start() {
        if let other = Self.active, other !== self {
            other.stop()
            other.onStopped?()
        }
        Self.active = self
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.onKey?(event)
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if Self.active === self {
            Self.active = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if Self.active === self {
            Self.active = nil
        }
    }
}
