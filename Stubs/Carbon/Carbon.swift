import Foundation

public typealias OSStatus = Int32
public typealias OSType = UInt32
public typealias OptionBits = UInt32

public let noErr: OSStatus = 0
public let eventNotHandledErr: OSStatus = -9874

public let controlKey = 0x1000
public let optionKey = 0x0800
public let shiftKey = 0x0200
public let cmdKey = 0x0100
public let kVK_ANSI_S = 0x01
public let kVK_ANSI_R = 0x0F

public let kEventClassKeyboard: UInt32 = 0x6B657962
public let kEventHotKeyPressed: UInt32 = 5
public let kEventParamDirectObject: UInt32 = 0x2D2D2D2D
public let typeEventHotKeyID: UInt32 = 0x686B6964

public typealias EventHotKeyRef = OpaquePointer
public typealias EventHandlerRef = OpaquePointer
public typealias EventTargetRef = OpaquePointer
public typealias EventRef = OpaquePointer
public typealias EventHandlerCallRef = OpaquePointer
public typealias EventHandlerUPP = (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus

public struct EventHotKeyID {
    public var signature: OSType
    public var id: UInt32
    public init() {
        signature = 0
        id = 0
    }
    public init(signature: OSType, id: UInt32) {
        self.signature = signature
        self.id = id
    }
}

public struct EventTypeSpec {
    public var eventClass: OSType
    public var eventKind: OSType
    public init(eventClass: OSType, eventKind: OSType) {
        self.eventClass = eventClass
        self.eventKind = eventKind
    }
}

public struct EventParamName: RawRepresentable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public struct EventParamType: RawRepresentable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public func GetApplicationEventTarget() -> EventTargetRef {
    EventTargetRef(bitPattern: 1)!
}

public func InstallEventHandler(
    _ target: EventTargetRef,
    _ handler: EventHandlerUPP,
    _ numTypes: UInt32,
    _ list: UnsafePointer<EventTypeSpec>,
    _ userData: UnsafeMutableRawPointer?,
    _ handlerRef: UnsafeMutablePointer<EventHandlerRef?>
) -> OSStatus {
    noErr
}

public func RegisterEventHotKey(
    _ keyCode: UInt32,
    _ modifiers: UInt32,
    _ hotKeyID: EventHotKeyID,
    _ target: EventTargetRef,
    _ options: OptionBits,
    _ outRef: UnsafeMutablePointer<EventHotKeyRef?>
) -> OSStatus {
    noErr
}

public func UnregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
    noErr
}

public func GetEventParameter(
    _ event: EventRef,
    _ paramName: EventParamName,
    _ paramType: EventParamType,
    _ outActualType: UnsafeMutablePointer<EventParamType>?,
    _ bufferSize: Int,
    _ outActualSize: UnsafeMutablePointer<Int>?,
    _ outData: UnsafeMutableRawPointer
) -> OSStatus {
    noErr
}
