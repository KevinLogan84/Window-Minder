# Window Minder

Window Minder is a macOS menu bar app that remembers where you put your windows. It saves the position and size of every standard window and restores that layout for the display setup that is connected.

It is a menu-bar-only app (`LSUIElement`): no Dock icon, no ads, no accounts, and no network. Layouts stay in Application Support on this Mac.

## What it saves

A display setup is the set of connected screens. Each screen is identified by its EDID vendor, product, and serial when the display reports them. The UUID from `CGDisplayCreateUUIDFromDisplayID` is only a fallback, because it can change across a reboot. Pixel size and scaled point size are part of the key, so a resolution change is a different setup. The frame origin is not: it moves when the primary display or menu bar changes, and a dock replug often shifts it by a point. `CGDirectDisplayID` is never used. The localized name is stored for the menu and does not affect the key. Screen order does not matter.

There is one layout per setup, written as JSON under:

`~/Library/Application Support/Window Minder/layouts/`

Each file includes a version, the configuration key, the time it was saved, the displays, and the windows (bundle identifier, title, per-app window index, and frame).

Window frames are stored in Cocoa coordinates (origin at the bottom-left of the primary display). Accessibility coordinates (origin at the top-left) are converted with the primary display's height. On restore, a frame is shifted onto the same physical display when that display's origin has moved.

## Behavior

- **Store Windows Now** and **Restore Windows Now** read and move standard windows. Panels, sheets, and menus are skipped. Restore matches bundle id and title, then window index. It does not use the process id or the Accessibility window id, because those change after a restart. A window that cannot be moved does not stop the rest, and an app that is not running yet does not fail the restore. A fullscreen window leaves fullscreen before its frame is set.
- **Auto-restore** is on by default. After login, after wake, and when displays are connected or disconnected (including a dock), Window Minder waits about a second and a half so a burst of display events becomes one restore, then applies the saved layout for that set of screens. The same monitors match the same layout after a replug. Apps that are not running yet are retried for about 15 seconds. Window Minder does not launch them. If nothing is saved for that setup, the windows stay where they are.
- **Save before a display change** is on by default. The app keeps an in-memory snapshot while the setup is stable. The screen notification arrives after the change, so that earlier snapshot is what gets saved for the previous setup. A snapshot with no windows does not replace a saved layout that still has windows.
- **Periodic auto-save** is off by default. Turn it on to write the current layout every 2 minutes.
- **Launch at Login** uses `SMAppService.mainApp` and is registered on first launch. Before that call, status is `.notFound`, which is not an error. The menu toggle can turn it off; `.notRegistered` stays off. The app can live in `/Applications` or `~/Applications`. An error is shown only if `register()` fails.
- **Ignored apps** are left alone. Window Minder always ignores itself. You can ignore the frontmost app and remove apps later.
- **Shortcuts** default to Control-Option-Command-S (store) and Control-Option-Command-R (restore). They are registered with Carbon so they work when another app is focused. The key code and modifiers are saved. If registration fails, Preferences says so.

## Accessibility

Window Minder prompts for Accessibility access on launch with `AXIsProcessTrustedWithOptions` and `kAXTrustedCheckOptionPrompt`.

If access is not granted, the menu says so and includes **Open Accessibility Settings…**, which opens:

System Settings > Privacy & Security > Accessibility

Enable Window Minder there. Nothing is stored or restored until that permission is on.

`AXIsProcessTrusted` can stay cached for the life of the process, so a grant is also checked with a live Accessibility call (`AXUIElementCopyAttributeValue` on the system-wide element). API disabled means not granted. Any other result, or a cached `true` from `AXIsProcessTrusted`, counts as granted. The menu rechecks about once a second until then, including while the menu is open, and also when the menu opens, when the app becomes active, when another app becomes frontmost, and when macOS posts `com.apple.accessibility.api` (immediately, then again after half a second and two seconds). Each check is logged to Console under subsystem `com.kevinlogan.WindowMinder` and category `accessibility`. Store and Restore turn on as soon as a check succeeds, without relaunching. Polling stops once access is granted.

## Build and test

Core logic (macOS or Linux, Swift 5.9 or later), from this directory:

```sh
swift test
```

The Mac app and the same tests:

```sh
xcodebuild test -scheme WindowMinder -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Open `WindowMinder.xcodeproj` and run the shared **WindowMinder** scheme to launch the menu bar app. The project does not require a development team. The default identity is ad-hoc (`CODE_SIGN_IDENTITY` = `-`). The app is not sandboxed, and the hardened runtime is off. The minimum system is macOS 14.

`xcodebuild test` builds the app and runs the logic tests for display-setup keys, layout files, window matching, and coordinate conversion. Those tests do not need Accessibility permission. CI passes `CODE_SIGNING_ALLOWED=NO`, which still overrides the project and leaves the build unsigned.

## Stable code signing

Ad-hoc signing gives the app a new cdhash on every rebuild. macOS then treats it as a different binary, and an Accessibility grant stops applying. A local self-signed identity named **Window Minder Dev** keeps the same designated requirement across rebuilds. The project does not require that identity. Passing `CODE_SIGN_IDENTITY` overrides the ad-hoc default. `CODE_SIGNING_ALLOWED=NO` still skips signing.

Create the identity once in Keychain Access:

1. Open Keychain Access.
2. Choose Certificate Assistant > Create a Certificate.
3. Name it `Window Minder Dev`.
4. Set Identity Type to Self-Signed Root.
5. Set Certificate Type to Code Signing.
6. Create it in the login keychain.

Build with that identity:

```sh
xcodebuild -scheme WindowMinder -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Window Minder Dev" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  build
```

`scripts/build-dev-signed.sh` runs the same build. It does not read the Keychain. The app does not read the Keychain either.

If Accessibility was granted to an older ad-hoc build and the menu still says access is not granted, reset the grant and enable Window Minder again:

```sh
tccutil reset Accessibility com.kevinlogan.WindowMinder
```

## Privacy

Window Minder does not use the network. It does not collect analytics, show ads, or require an account.

## Feedback

Questions or feedback: kevinlogan@mail.grokbot.com
