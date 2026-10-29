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
- **Auto-restore** is on by default. After login, after the Mac wakes, after the displays wake, when the screen unlocks, and when displays are connected or disconnected (including a dock), Window Minder waits about a second and a half so that burst becomes one restore, then applies the saved layout for that set of screens. Further display events restart the wait. A wake and the display change that follows it restore once. If the screens just after a wake, display wake, or unlock are only some of the screens from the previous setup, and that previous setup has a saved layout, Window Minder waits up to about 90 seconds for the missing screen instead of applying the smaller layout. It applies the smaller layout only if the missing screen does not come back. A screen that returns inside that window is restored even when the setup matches the one from before the wake. Nothing is moved while a mouse button is down. The same monitors match the same layout after a replug. Windows that are not open yet are retried for about 30 seconds. Window Minder does not launch apps. If nothing is saved for that setup, or auto-restore is off, the windows stay where they are.
- **Save before a display change** is on by default. The app keeps an in-memory snapshot while the setup is stable. The screen notification arrives after the change, so that earlier snapshot is what gets saved for the previous setup. A snapshot with no windows does not replace a saved layout that still has windows.
- **Periodic auto-save** is off by default. Turn it on to write the current layout every 2 minutes.
- **Launch at Login** uses `SMAppService.mainApp` and is registered on first launch. Before that call, status is `.notFound`, which is not an error. The menu toggle can turn it off; `.notRegistered` stays off. The app can live in `/Applications` or `~/Applications`. An error is shown only if `register()` fails.
- **Ignored apps** are left alone. Window Minder always ignores itself. You can ignore the frontmost app and remove apps later.
- **Shortcuts** default to Control-Option-Command-S (store) and Control-Option-Command-R (restore). They are registered with Carbon so they work when another app is focused. The key code and modifiers are saved. If registration fails, Preferences says so.

## Accessibility

Window Minder prompts for Accessibility access on launch with `AXIsProcessTrustedWithOptions` and `kAXTrustedCheckOptionPrompt`.

If access is not actually working, the menu shows **Accessibility access needed. Open Settings…**, which opens:

System Settings > Privacy & Security > Accessibility

Enable Window Minder there. Nothing is stored or restored until a live read succeeds. An ad-hoc rebuild changes the cdhash, so a previous Accessibility row can stay listed while `tccd` rejects the new binary.

`AXIsProcessTrusted` can stay cached `true` for the life of the process, and that cache is not treated as a grant. Window Minder copies the window list of running apps that already have on-screen windows. If that call fails, or it returns no windows, the menu warning stays up. If it returns windows, Store and Restore turn on without relaunching, even when the cached flag is still false. When no app has an on-screen window, a live attribute copy decides, and API disabled still means not granted. The menu rechecks about once a second until then, including while the menu is open, and also when the menu opens, when the app becomes active, when another app becomes frontmost, and when macOS posts `com.apple.accessibility.api` (immediately, then again after half a second and two seconds). Each check is logged to Console under subsystem `com.kevinlogan.WindowMinder` and category `accessibility`. Store and restore counts, and Accessibility errors, are logged under the same subsystem. Polling stops once a live read succeeds.

A Store that reads zero windows does not replace a saved layout that still has windows. The previous file is left untouched and the menu says so. A Store with fewer windows than the saved layout keeps the saved entries for windows that are not open, and the menu says how many were kept.

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
