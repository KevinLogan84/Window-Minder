import Foundation

public enum LoginItemRegistration {
    /// `.notFound` is what `SMAppService` reports before the first `register()`.
    /// That is the moment to turn Launch at Login on. `.notRegistered` means the user
    /// turned it off later, and it stays off.
    public static func shouldRegisterOnLaunch(_ state: LoginItemState) -> Bool {
        state == .notFound
    }
}

public enum LoginItemState: Equatable, Sendable {
    case enabled
    case notRegistered
    /// `SMAppService` reports this before the first `register()`. It is not an error.
    case notFound
    case requiresApproval
    case unknown
}

public enum LoginItemPresentation {
    public static func title(for state: LoginItemState) -> String {
        switch state {
        case .enabled, .notRegistered, .notFound:
            return "Launch at Login"
        case .requiresApproval:
            return "Launch at Login (Approval Required)"
        case .unknown:
            return "Launch at Login (Unknown Status)"
        }
    }

    public static func isEnabled(_ state: LoginItemState) -> Bool {
        state == .enabled
    }

    /// `.notFound` is the normal unchecked state before the first registration.
    public static func showsToggle(_ state: LoginItemState) -> Bool {
        switch state {
        case .enabled, .notRegistered, .notFound:
            return true
        case .requiresApproval, .unknown:
            return false
        }
    }

    /// Status text for a successful status read. Registration failures use `registrationFailureMessage`.
    public static func message(for state: LoginItemState) -> String? {
        switch state {
        case .requiresApproval:
            return "Approve Window Minder in System Settings > General > Login Items & Extensions."
        case .enabled, .notRegistered, .notFound, .unknown:
            return nil
        }
    }

    public static func registrationFailureMessage(
        errorDescription: String,
        bundlePath: String,
        homeDirectory: String
    ) -> String {
        let base = "Launch at Login could not be updated. \(errorDescription)"
        if InstallLocation.isAcceptableApplicationsPath(bundlePath, homeDirectory: homeDirectory) {
            return base
        }
        return base + " Move Window Minder into /Applications or ~/Applications and try again."
    }
}

/// Locations `SMAppService` can register from. Both the system Applications folder
/// and the user's own Applications folder count.
public enum InstallLocation {
    public static func isAcceptableApplicationsPath(_ path: String, homeDirectory: String) -> Bool {
        let home = normalize(expandingTilde(homeDirectory, home: homeDirectory))
        let candidate = normalize(expandingTilde(path, home: home))
        guard candidate.hasPrefix("/") else { return false }
        if isInside(candidate, directory: "/Applications") { return true }
        guard home.hasPrefix("/") else { return false }
        return isInside(candidate, directory: join(home, "Applications"))
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        let rest = String(path.dropFirst(2))
        if home.isEmpty { return rest }
        if home.hasSuffix("/") { return home + rest }
        return home + "/" + rest
    }

    private static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = trimmed.hasPrefix("/")
        var parts: [String] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        guard absolute else { return parts.joined(separator: "/") }
        return "/" + parts.joined(separator: "/")
    }

    private static func join(_ directory: String, _ child: String) -> String {
        if directory == "/" { return "/" + child }
        return directory + "/" + child
    }

    private static func isInside(_ path: String, directory: String) -> Bool {
        let path = path.lowercased()
        let directory = directory.lowercased()
        if path == directory { return true }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix)
    }
}
