import AppKit
import Carbon

struct StoredHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static var storeWindows: StoredHotkey {
        StoredHotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: CarbonModifiers.controlOptionCommand)
    }

    static var restoreWindows: StoredHotkey {
        StoredHotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: CarbonModifiers.controlOptionCommand)
    }
}

enum CarbonModifiers {
    static var controlOptionCommand: UInt32 {
        UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
    }

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    static func cocoa(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
}

enum HotkeyFormatting {
    static func displayString(for hotkey: StoredHotkey) -> String {
        let flags = CarbonModifiers.cocoa(from: hotkey.modifiers)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyName(hotkey.keyCode))
        return parts.joined()
    }

    static func keyName(_ keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    private static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x24: "Return",
        0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "Tab",
        0x31: "Space", 0x32: "`", 0x33: "Delete", 0x35: "Escape",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3", 0x64: "F8", 0x65: "F9",
        0x67: "F11", 0x69: "F13", 0x6A: "F16", 0x6B: "F14", 0x6D: "F10", 0x6F: "F12",
        0x71: "F15", 0x76: "F4", 0x78: "F2", 0x7A: "F1",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up",
        0x40: "F17", 0x4F: "F18", 0x50: "F19",
    ]
}
