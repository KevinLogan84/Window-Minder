import Foundation

/// Linux stand-in for CoreFoundation. Names and labels match the macOS overlay.
/// `CFString` is `NSString` so `as CFString` / `as String` typecheck the way the SDK bridging does.
public typealias CFString = NSString
public typealias CFArray = NSArray
public typealias CFDictionary = NSDictionary
public typealias CFTypeID = UInt
public typealias CFIndex = Int
public typealias CFAllocatorRef = UnsafeMutableRawPointer

open class CFType: NSObject {}
public typealias CFTypeRef = CFType

open class CFBoolean: CFType {}
open class CFUUID: CFType {}

public let kCFBooleanTrue = CFBoolean()
public let kCFBooleanFalse = CFBoolean()

public func CFBooleanGetValue(_ boolean: CFBoolean) -> Bool { false }

public func CFGetTypeID(_ cf: CFTypeRef) -> CFTypeID { 0 }
public func CFArrayGetTypeID() -> CFTypeID { 1 }
public func CFStringGetTypeID() -> CFTypeID { 2 }
public func CFBooleanGetTypeID() -> CFTypeID { 3 }
public func CFNullGetTypeID() -> CFTypeID { 4 }

public func CFArrayGetCount(_ theArray: CFArray) -> CFIndex { 0 }
public func CFArrayGetValueAtIndex(_ theArray: CFArray, _ idx: CFIndex) -> UnsafeRawPointer? { nil }

public func CFUUIDCreateString(_ allocator: CFAllocatorRef?, _ uuid: CFUUID) -> CFString? { nil }
