import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

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
            return .notFound
        @unknown default:
            return .unknown
        }
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
