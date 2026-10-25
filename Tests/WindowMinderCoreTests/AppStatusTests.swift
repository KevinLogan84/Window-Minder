import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class AppStatusTests: XCTestCase {
    func testPollingRunsOnlyWhileUntrusted() {
        XCTAssertTrue(AccessibilityTrustPolling.shouldPoll(isTrusted: false))
        XCTAssertFalse(AccessibilityTrustPolling.shouldPoll(isTrusted: true))
        XCTAssertEqual(AccessibilityTrustPolling.interval, 1)
    }

    func testGrantClearsTheDeniedBannerAndEnablesWindowActions() {
        XCTAssertTrue(AccessibilityTrustPolling.showsAccessDenied(isTrusted: false))
        XCTAssertFalse(AccessibilityTrustPolling.menuAllowsWindowActions(isTrusted: false))

        XCTAssertFalse(AccessibilityTrustPolling.showsAccessDenied(isTrusted: true))
        XCTAssertTrue(AccessibilityTrustPolling.menuAllowsWindowActions(isTrusted: true))
    }

    func testNotFoundIsUncheckedLaunchAtLogin() {
        XCTAssertEqual(LoginItemPresentation.title(for: .notFound), "Launch at Login")
        XCTAssertFalse(LoginItemPresentation.isEnabled(.notFound))
        XCTAssertTrue(LoginItemPresentation.showsToggle(.notFound))
        XCTAssertNil(LoginItemPresentation.message(for: .notFound))
    }

    func testNotRegisteredMatchesTheNotFoundLabel() {
        XCTAssertEqual(
            LoginItemPresentation.title(for: .notRegistered),
            LoginItemPresentation.title(for: .notFound)
        )
        XCTAssertFalse(LoginItemPresentation.isEnabled(.notRegistered))
        XCTAssertTrue(LoginItemPresentation.showsToggle(.notRegistered))
        XCTAssertNil(LoginItemPresentation.message(for: .notRegistered))
    }

    func testEnabledLaunchAtLoginIsChecked() {
        XCTAssertEqual(LoginItemPresentation.title(for: .enabled), "Launch at Login")
        XCTAssertTrue(LoginItemPresentation.isEnabled(.enabled))
        XCTAssertTrue(LoginItemPresentation.showsToggle(.enabled))
        XCTAssertNil(LoginItemPresentation.message(for: .enabled))
    }

    func testApprovalAndUnknownStayDistinct() {
        XCTAssertEqual(LoginItemPresentation.title(for: .requiresApproval), "Launch at Login (Approval Required)")
        XCTAssertFalse(LoginItemPresentation.showsToggle(.requiresApproval))
        XCTAssertEqual(
            LoginItemPresentation.message(for: .requiresApproval),
            "Approve Window Minder in System Settings > General > Login Items & Extensions."
        )

        XCTAssertEqual(LoginItemPresentation.title(for: .unknown), "Launch at Login (Unknown Status)")
        XCTAssertFalse(LoginItemPresentation.showsToggle(.unknown))
        XCTAssertNil(LoginItemPresentation.message(for: .unknown))
    }

    func testSystemAndHomeApplicationsAreAccepted() {
        let home = "/Users/kevin"
        XCTAssertTrue(InstallLocation.isAcceptableApplicationsPath(
            "/Applications/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertTrue(InstallLocation.isAcceptableApplicationsPath(
            "/Users/kevin/Applications/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertTrue(InstallLocation.isAcceptableApplicationsPath(
            "~/Applications/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertTrue(InstallLocation.isAcceptableApplicationsPath(
            "/Users/kevin/Applications/Utilities/Window Minder.app/",
            homeDirectory: "/Users/kevin/"
        ))
        XCTAssertTrue(InstallLocation.isAcceptableApplicationsPath(
            "/applications/Window Minder.app",
            homeDirectory: home
        ))
    }

    func testPathsOutsideApplicationsAreRejected() {
        let home = "/Users/kevin"
        XCTAssertFalse(InstallLocation.isAcceptableApplicationsPath(
            "/tmp/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertFalse(InstallLocation.isAcceptableApplicationsPath(
            "/ApplicationsBackup/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertFalse(InstallLocation.isAcceptableApplicationsPath(
            "/Users/kevin/ApplicationsBackup/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertFalse(InstallLocation.isAcceptableApplicationsPath(
            "/Users/kevin/Library/Application Support/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertFalse(InstallLocation.isAcceptableApplicationsPath(
            "/Applications/../tmp/Window Minder.app",
            homeDirectory: home
        ))
        XCTAssertFalse(InstallLocation.isAcceptableApplicationsPath("", homeDirectory: home))
    }

    func testRegistrationFailureInHomeApplicationsDoesNotAskToMove() {
        let message = LoginItemPresentation.registrationFailureMessage(
            errorDescription: "Operation not permitted.",
            bundlePath: "/Users/kevin/Applications/Window Minder.app",
            homeDirectory: "/Users/kevin"
        )
        XCTAssertEqual(message, "Launch at Login could not be updated. Operation not permitted.")
    }

    func testRegistrationFailureOutsideApplicationsMentionsBothFolders() {
        let message = LoginItemPresentation.registrationFailureMessage(
            errorDescription: "The app could not be found.",
            bundlePath: "/tmp/Window Minder.app",
            homeDirectory: "/Users/kevin"
        )
        XCTAssertTrue(message.contains("The app could not be found."))
        XCTAssertTrue(message.contains("/Applications"))
        XCTAssertTrue(message.contains("~/Applications"))
    }
}
