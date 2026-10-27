@_exported import CoreFoundation
import CoreGraphics
import Foundation

open class AXUIElement: CFType {}
open class AXValue: CFType {}

public enum AXError: Int32 {
    case success = 0
    case cannotComplete = -25204
}

public struct AXCopyMultipleAttributeOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public enum AXValueType: UInt32 {
    case cgPoint = 1
    case cgSize = 2
    case axError = 3
}

public let kAXWindowsAttribute = "AXWindows"
public let kAXFocusedApplicationAttribute = "AXFocusedApplication"
public let kAXPositionAttribute = "AXPosition"
public let kAXSizeAttribute = "AXSize"
public let kAXTrustedCheckOptionPrompt: CFString = "AXTrustedCheckOptionPrompt" as CFString

public func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { AXUIElement() }
public func AXUIElementCreateSystemWide() -> AXUIElement { AXUIElement() }

@discardableResult
public func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeoutInSeconds: Float) -> AXError {
    .success
}

public func AXUIElementCopyAttributeValue(
    _ element: AXUIElement,
    _ attribute: CFString,
    _ value: UnsafeMutablePointer<CFTypeRef?>
) -> AXError {
    .success
}

public func AXUIElementCopyMultipleAttributeValues(
    _ element: AXUIElement,
    _ attributes: CFArray,
    _ options: AXCopyMultipleAttributeOptions,
    _ values: UnsafeMutablePointer<CFArray?>
) -> AXError {
    .success
}

public func AXUIElementSetAttributeValue(
    _ element: AXUIElement,
    _ attribute: CFString,
    _ value: CFTypeRef
) -> AXError {
    .success
}

public func AXIsProcessTrusted() -> Bool { false }
public func AXIsProcessTrustedWithOptions(_ options: CFDictionary) -> Bool { false }

public func AXValueGetTypeID() -> CFTypeID { 5 }
public func AXValueGetType(_ value: AXValue) -> AXValueType { .cgPoint }
public func AXValueGetValue(_ value: AXValue, _ type: AXValueType, _ valuePtr: UnsafeMutableRawPointer) -> Bool {
    false
}
public func AXValueCreate(_ type: AXValueType, _ valuePtr: UnsafeRawPointer) -> AXValue? { nil }
