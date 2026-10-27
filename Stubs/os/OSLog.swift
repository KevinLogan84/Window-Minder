public struct OSLogPrivacy: Hashable, Sendable {
    public static let auto = OSLogPrivacy()
    public static let `public` = OSLogPrivacy()
    public static let `private` = OSLogPrivacy()
}

public struct OSLogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        public typealias StringLiteralType = String
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy) {}
    }

    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}

public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func info(_ message: OSLogMessage) {}
    public func error(_ message: OSLogMessage) {}
    public func debug(_ message: OSLogMessage) {}
}

public struct OSSignpostIntervalState: Sendable {}

public struct OSSignposter: Sendable {
    public init(subsystem: String, category: String) {}
    public func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
        OSSignpostIntervalState()
    }
    public func endInterval(_ name: StaticString, _ interval: OSSignpostIntervalState) {}
}
