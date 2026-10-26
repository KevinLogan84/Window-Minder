import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class AppStatusTests: XCTestCase {
    func testPollingRunsOnlyWhileUntrusted() {
        XCTAssertTrue(AccessibilityTrustPolling.shouldPoll(isTrusted: false))
        XCTAssertFalse(AccessibilityTrustPolling.shouldPoll(isTrusted: true))
        XCTAssertEqual(AccessibilityTrustPolling.interval, 1)
        XCTAssertEqual(AccessibilityTrustPolling.probeTimeout, 0.25)
        XCTAssertLessThanOrEqual(AccessibilityTrustPolling.probeTimeout, AccessibilityTrustPolling.interval)
    }

    func testPollingStartsOnceAndStopsOnlyAfterTrust() {
        XCTAssertTrue(AccessibilityTrustPolling.shouldStartPolling(isTrusted: false, timerAlreadyRunning: false))
        XCTAssertFalse(AccessibilityTrustPolling.shouldStartPolling(isTrusted: false, timerAlreadyRunning: true))
        XCTAssertFalse(AccessibilityTrustPolling.shouldStartPolling(isTrusted: true, timerAlreadyRunning: false))
        XCTAssertFalse(AccessibilityTrustPolling.shouldStopPolling(isTrusted: false))
        XCTAssertTrue(AccessibilityTrustPolling.shouldStopPolling(isTrusted: true))
        XCTAssertEqual(AccessibilityTrustPolling.notificationFollowUpDelays, [0.5, 2])
    }

    func testCachedProcessTrustDoesNotHideALiveProbe() {
        XCTAssertTrue(AccessibilityTrustDecision.isTrusted(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.success
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isTrusted(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.noValue
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isTrusted(
            processTrusted: false,
            probeError: -25204
        ))
        XCTAssertFalse(AccessibilityTrustDecision.isTrusted(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.apiDisabled
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isTrusted(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.apiDisabled
        ))
        XCTAssertEqual(
            AccessibilityTrustDecision.logLine(
                source: .poll,
                processTrusted: false,
                probeError: AccessibilityAPIErrorCode.success
            ),
            "Trust check source=poll AXIsProcessTrusted=false probe=success(0) trusted=true"
        )
        XCTAssertEqual(
            AccessibilityTrustDecision.logLine(
                source: .menuOpen,
                processTrusted: false,
                probeError: AccessibilityAPIErrorCode.apiDisabled
            ),
            "Trust check source=menu-open AXIsProcessTrusted=false probe=apiDisabled(-25211) trusted=false"
        )
        XCTAssertEqual(
            AccessibilityTrustDecision.probeDescription(AccessibilityAPIErrorCode.noValue),
            "noValue(-25212)"
        )
        XCTAssertEqual(AccessibilityTrustDecision.probeDescription(-25200), "other(-25200)")
    }

    func testProbePrefersAResultThatIsNotAPIDisabled() {
        XCTAssertEqual(
            AccessibilityTrustDecision.preferredProbeError([
                AccessibilityAPIErrorCode.apiDisabled,
                AccessibilityAPIErrorCode.success,
            ]),
            AccessibilityAPIErrorCode.success
        )
        XCTAssertEqual(
            AccessibilityTrustDecision.preferredProbeError([
                AccessibilityAPIErrorCode.apiDisabled,
                AccessibilityAPIErrorCode.noValue,
            ]),
            AccessibilityAPIErrorCode.noValue
        )
        XCTAssertEqual(
            AccessibilityTrustDecision.preferredProbeError([
                AccessibilityAPIErrorCode.apiDisabled,
                AccessibilityAPIErrorCode.apiDisabled,
            ]),
            AccessibilityAPIErrorCode.apiDisabled
        )
        XCTAssertEqual(AccessibilityTrustDecision.preferredProbeError([]), AccessibilityAPIErrorCode.apiDisabled)
        XCTAssertEqual(AccessibilityTrustCheckSource.notification.rawValue, "notification")
        XCTAssertEqual(AccessibilityTrustCheckSource.activation.rawValue, "activation")
        XCTAssertEqual(AccessibilityTrustCheckSource.frontmost.rawValue, "frontmost")
    }

    func testGrantClearsTheDeniedBannerAndEnablesWindowActions() {
        XCTAssertTrue(AccessibilityTrustPolling.showsAccessDenied(isTrusted: false))
        XCTAssertFalse(AccessibilityTrustPolling.menuAllowsWindowActions(isTrusted: false))

        XCTAssertFalse(AccessibilityTrustPolling.showsAccessDenied(isTrusted: true))
        XCTAssertTrue(AccessibilityTrustPolling.menuAllowsWindowActions(isTrusted: true))
    }

    func testFirstLaunchRegistersOnlyWhenTheServiceWasNeverRegistered() {
        XCTAssertTrue(LoginItemRegistration.shouldRegisterOnLaunch(.notFound))
        XCTAssertFalse(LoginItemRegistration.shouldRegisterOnLaunch(.notRegistered))
        XCTAssertFalse(LoginItemRegistration.shouldRegisterOnLaunch(.enabled))
        XCTAssertFalse(LoginItemRegistration.shouldRegisterOnLaunch(.requiresApproval))
        XCTAssertFalse(LoginItemRegistration.shouldRegisterOnLaunch(.unknown))
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
