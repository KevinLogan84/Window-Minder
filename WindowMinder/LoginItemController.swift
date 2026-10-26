import Foundation
import ServiceManagement

@MainActor
struct LoginItemController {
    func state() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            // Normal before the first register(), including when the app is in ~/Applications.
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    /// Registers only when the service has never been registered. `.notFound` is that state.
    func registerIfNeeded() throws -> LoginItemState {
        let service = SMAppService.mainApp
        if service.status == .notFound {
            try service.register()
        }
        return state()
    }

    func toggle() throws -> LoginItemState {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            try service.unregister()
        case .notRegistered, .notFound, .requiresApproval:
            try service.register()
        @unknown default:
            try service.register()
        }
        return state()
    }
}
