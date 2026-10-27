@_exported import CoreFoundation

public typealias CGDirectDisplayID = UInt32
public typealias CGWindowID = UInt32

public struct CGWindowListOption: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let optionOnScreenOnly = CGWindowListOption(rawValue: 1 << 0)
    public static let excludeDesktopElements = CGWindowListOption(rawValue: 1 << 4)
}

public let kCGNullWindowID: CGWindowID = 0
public let kCGWindowLayer = "kCGWindowLayer"
public let kCGWindowOwnerPID = "kCGWindowOwnerPID"
public let kCGWindowBounds = "kCGWindowBounds"

public func CGWindowListCopyWindowInfo(
    _ option: CGWindowListOption,
    _ relativeToWindow: CGWindowID
) -> CFArray? {
    nil
}

public func CGDisplayVendorNumber(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayModelNumber(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplaySerialNumber(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayPixelsWide(_ display: CGDirectDisplayID) -> Int { 0 }
public func CGDisplayPixelsHigh(_ display: CGDirectDisplayID) -> Int { 0 }
public func CGDisplayCreateUUIDFromDisplayID(_ display: CGDirectDisplayID) -> CFUUID? { nil }

public struct CGDisplayChangeSummaryFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public enum CGError: Int32 {
    case success = 0
}

public func CGDisplayRegisterReconfigurationCallback(
    _ callback: @escaping (CGDirectDisplayID, CGDisplayChangeSummaryFlags, UnsafeMutableRawPointer?) -> Void,
    _ userInfo: UnsafeMutableRawPointer?
) -> CGError {
    .success
}
