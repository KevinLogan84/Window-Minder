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
        XCTAssertFalse(AccessibilityTrustDecision.isTrusted(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.apiDisabled
        ))
        XCTAssertEqual(AccessibilityAPIErrorCode.cannotComplete, -25204)
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
        XCTAssertEqual(
            AccessibilityTrustDecision.logLine(
                source: .action,
                processTrusted: true,
                probeError: AccessibilityAPIErrorCode.apiDisabled
            ),
            "Trust check source=action AXIsProcessTrusted=true probe=apiDisabled(-25211) trusted=false"
        )
    }

    func testWindowProbeDecidesTrustWhenAppsHaveWindows() {
        XCTAssertFalse(AccessibilityTrustDecision.isEffective(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.success,
            onscreenAppsWithWindows: 2,
            axWindowCount: 0,
            axReadFailed: false
        ))
        XCTAssertFalse(AccessibilityTrustDecision.isEffective(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.success,
            onscreenAppsWithWindows: 1,
            axWindowCount: 0,
            axReadFailed: true
        ))
        XCTAssertFalse(AccessibilityTrustDecision.isEffective(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.apiDisabled,
            onscreenAppsWithWindows: 3,
            axWindowCount: 0,
            axReadFailed: true
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isEffective(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.apiDisabled,
            onscreenAppsWithWindows: 1,
            axWindowCount: 4,
            axReadFailed: false
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isEffective(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.success,
            onscreenAppsWithWindows: 2,
            axWindowCount: 1,
            axReadFailed: true
        ))
        XCTAssertFalse(AccessibilityTrustDecision.isEffective(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.apiDisabled,
            onscreenAppsWithWindows: 0,
            axWindowCount: 0,
            axReadFailed: false
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isEffective(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.success,
            onscreenAppsWithWindows: 0,
            axWindowCount: 0,
            axReadFailed: false
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isEffective(
            processTrusted: false,
            probeError: AccessibilityAPIErrorCode.noValue,
            onscreenAppsWithWindows: 0,
            axWindowCount: 0,
            axReadFailed: false
        ))
        XCTAssertTrue(AccessibilityTrustDecision.isEffective(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.cannotComplete,
            onscreenAppsWithWindows: 2,
            axWindowCount: 0,
            axReadFailed: false
        ))
        XCTAssertFalse(AccessibilityTrustDecision.isEffective(
            processTrusted: true,
            probeError: AccessibilityAPIErrorCode.cannotComplete,
            onscreenAppsWithWindows: 2,
            axWindowCount: 0,
            axReadFailed: true
        ))
        XCTAssertEqual(
            AccessibilityMenuCopy.accessNeeded,
            "Accessibility access needed. Open Settings…"
        )
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

    func testTransientActionResultsExpireAfterFourSeconds() {
        XCTAssertEqual(MenuStatusLine.displayInterval, 4)
        let posted = Date(timeIntervalSince1970: 1_000)
        let results = [
            "Deleted the saved layout.",
            "Stored 2 windows from 1 app",
            "Restored 1 window",
            "There is no frontmost app to ignore.",
            "Window Minder cannot ignore itself.",
            "Ignoring Safari.",
            "Window Minder is still starting.",
            "No saved layout for this display setup.",
            "Could not store windows. 1 app did not respond",
        ]
        for result in results {
            let fresh = MenuStatusLine.resolve(
                message: result,
                postedAt: posted,
                now: posted.addingTimeInterval(3.999),
                accessibilityTrusted: true,
                inProgressMessage: nil
            )
            XCTAssertTrue(fresh.isTransient, result)
            XCTAssertEqual(fresh.message, result, result)
            XCTAssertNil(fresh.replacement, result)

            let expired = MenuStatusLine.resolve(
                message: result,
                postedAt: posted,
                now: posted.addingTimeInterval(MenuStatusLine.displayInterval),
                accessibilityTrusted: true,
                inProgressMessage: nil
            )
            XCTAssertFalse(expired.isTransient, result)
            XCTAssertNil(expired.message, result)
            XCTAssertNil(expired.replacement, result)
        }
    }

    func testMenuOpenReplacesAnExpiredActionResultWithTheCurrentState() {
        let now = Date(timeIntervalSince1970: 5_000)
        let expiredAt = now.addingTimeInterval(-MenuStatusLine.displayInterval)

        let ready = MenuStatusLine.resolve(
            message: "Deleted the saved layout.",
            postedAt: expiredAt,
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: nil
        )
        XCTAssertFalse(ready.isTransient)
        XCTAssertNil(ready.message)

        let missingTimestamp = MenuStatusLine.resolve(
            message: "Deleted the saved layout.",
            postedAt: nil,
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: nil
        )
        XCTAssertFalse(missingTimestamp.isTransient)
        XCTAssertNil(missingTimestamp.message)

        let needsAccess = MenuStatusLine.resolve(
            message: "Deleted the saved layout.",
            postedAt: expiredAt,
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: nil
        )
        XCTAssertFalse(needsAccess.isTransient)
        XCTAssertEqual(needsAccess.message, MenuStatusLine.accessibilityNeeded)
        XCTAssertEqual(needsAccess.replacement, MenuStatusLine.accessibilityNeeded)

        let stillShowing = MenuStatusLine.resolve(
            message: "Deleted the saved layout.",
            postedAt: now.addingTimeInterval(-1),
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: nil
        )
        XCTAssertTrue(stillShowing.isTransient)
        XCTAssertEqual(stillShowing.message, "Deleted the saved layout.")
        XCTAssertEqual(stillShowing.replacement, MenuStatusLine.accessibilityNeeded)

        let storing = MenuStatusLine.resolve(
            message: "Deleted the saved layout.",
            postedAt: now.addingTimeInterval(-1),
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: MenuStatusLine.storing
        )
        XCTAssertFalse(storing.isTransient)
        XCTAssertEqual(storing.message, MenuStatusLine.storing)

        let restoring = MenuStatusLine.resolve(
            message: "Stored 1 window from 1 app",
            postedAt: nil,
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: MenuStatusLine.restoring
        )
        XCTAssertFalse(restoring.isTransient)
        XCTAssertEqual(restoring.message, MenuStatusLine.restoring)
    }

    func testAccessibilityWarningStaysUntilAccessIsGranted() {
        XCTAssertEqual(MenuStatusLine.accessibilityNeeded, "Accessibility access is not granted.")
        let now = Date(timeIntervalSince1970: 8_000)

        let denied = MenuStatusLine.resolve(
            message: MenuStatusLine.accessibilityNeeded,
            postedAt: now.addingTimeInterval(-3600),
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: nil
        )
        XCTAssertFalse(denied.isTransient)
        XCTAssertEqual(denied.message, MenuStatusLine.accessibilityNeeded)
        XCTAssertEqual(denied.replacement, MenuStatusLine.accessibilityNeeded)

        let deniedWithoutTimestamp = MenuStatusLine.resolve(
            message: "  Accessibility access is not granted. \n",
            postedAt: nil,
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: nil
        )
        XCTAssertFalse(deniedWithoutTimestamp.isTransient)
        XCTAssertEqual(deniedWithoutTimestamp.message, MenuStatusLine.accessibilityNeeded)

        let deniedDuringStore = MenuStatusLine.resolve(
            message: MenuStatusLine.accessibilityNeeded,
            postedAt: now.addingTimeInterval(-30),
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: MenuStatusLine.storing
        )
        XCTAssertFalse(deniedDuringStore.isTransient)
        XCTAssertEqual(deniedDuringStore.message, MenuStatusLine.accessibilityNeeded)

        let granted = MenuStatusLine.resolve(
            message: MenuStatusLine.accessibilityNeeded,
            postedAt: now,
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: nil
        )
        XCTAssertFalse(granted.isTransient)
        XCTAssertNil(granted.message)

        let idleAndUntrusted = MenuStatusLine.resolve(
            message: nil,
            postedAt: nil,
            now: now,
            accessibilityTrusted: false,
            inProgressMessage: nil
        )
        XCTAssertFalse(idleAndUntrusted.isTransient)
        XCTAssertNil(idleAndUntrusted.message)
        XCTAssertEqual(idleAndUntrusted.replacement, MenuStatusLine.accessibilityNeeded)

        let blank = MenuStatusLine.resolve(
            message: " \n\t",
            postedAt: now.addingTimeInterval(-30),
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: nil
        )
        XCTAssertFalse(blank.isTransient)
        XCTAssertNil(blank.message)
    }

    func testInProgressStoreAndRestoreStayUntilTheWorkFinishes() {
        XCTAssertEqual(MenuStatusLine.storing, "Storing windows…")
        XCTAssertEqual(MenuStatusLine.restoring, "Restoring windows…")
        let now = Date(timeIntervalSince1970: 9_000)

        let storing = MenuStatusLine.resolve(
            message: MenuStatusLine.storing,
            postedAt: now.addingTimeInterval(-30),
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: MenuStatusLine.storing
        )
        XCTAssertFalse(storing.isTransient)
        XCTAssertEqual(storing.message, MenuStatusLine.storing)
        XCTAssertEqual(storing.replacement, MenuStatusLine.storing)

        let restoring = MenuStatusLine.resolve(
            message: MenuStatusLine.restoring,
            postedAt: now,
            now: now.addingTimeInterval(10),
            accessibilityTrusted: true,
            inProgressMessage: MenuStatusLine.restoring
        )
        XCTAssertFalse(restoring.isTransient)
        XCTAssertEqual(restoring.message, MenuStatusLine.restoring)

        let finished = MenuStatusLine.resolve(
            message: "Restored 3 windows. Skipped 1",
            postedAt: now,
            now: now.addingTimeInterval(1),
            accessibilityTrusted: true,
            inProgressMessage: nil
        )
        XCTAssertTrue(finished.isTransient)
        XCTAssertEqual(finished.message, "Restored 3 windows. Skipped 1")
        XCTAssertNil(finished.replacement)

        let stuckAfterFinish = MenuStatusLine.resolve(
            message: MenuStatusLine.storing,
            postedAt: now.addingTimeInterval(-30),
            now: now,
            accessibilityTrusted: true,
            inProgressMessage: nil
        )
        XCTAssertFalse(stuckAfterFinish.isTransient)
        XCTAssertNil(stuckAfterFinish.message)
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
