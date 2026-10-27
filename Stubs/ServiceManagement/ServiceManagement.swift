public final class SMAppService: Sendable {
    public static let mainApp = SMAppService()

    public enum Status: Int, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    public var status: Status { .notFound }

    public func register() throws {}
    public func unregister() throws {}
}
