# Window Minder

Window Minder is a macOS menu bar app that remembers where you put your windows. It saves the position and size of every standard window and restores that layout for the display setup that is connected.

It is a menu-bar-only app (`LSUIElement`): no Dock icon, no ads, no accounts, and no network. Layouts stay in Application Support on this Mac.

## What it saves

A display setup is the set of connected screens. Each screen is identified by its stable display UUID (`CGDisplayCreateUUIDFromDisplayID`), its frame in points, and its pixel size. The localized name is stored for the menu, but it does not affect which layout is used. Screen order does not matter.

There is one layout per setup, written as JSON under:

`~/Library/Application Support/Window Minder/layouts/`

Each file includes a version, the configuration key, the time it was saved, the displays, and the windows (bundle identifier, title, per-app window index, and frame).

Window frames are stored in Cocoa coordinates (origin at the bottom-left of the primary display). Accessibility coordinates (origin at the top-left) are converted with the primary display's height.

## Behavior

- **Store Windows Now** and **Restore Windows Now** read and move standard windows. Panels, sheets, and menus are skipped. A window that cannot be moved does not stop the rest. A fullscreen window leaves fullscreen before its frame is set.
- **Auto-restore** is on by default. Window Minder restores the matching layout when displays are connected or disconnected, and shortly after the Mac wakes so windows exist again. If nothing is saved for that setup, the windows stay where they are.
- **Save before a display change** is on by default. The app keeps an in-memory snapshot while the setup is stable. The screen notification arrives after the change, so that earlier snapshot is what gets saved for the previous setup.
- **Periodic auto-save** is off by default. Turn it on to write the current layout every 2 minutes.
- **Launch at Login** uses `SMAppService.mainApp` and shows the real registration status.
- **Ignored apps** are left alone. Window Minder always ignores itself. You can ignore the frontmost app and remove apps later.
- **Shortcuts** default to Control-Option-Command-S (store) and Control-Option-Command-R (restore). They are registered with Carbon so they work when another app is focused. The key code and modifiers are saved. If registration fails, Preferences says so.

## Accessibility

Window Minder prompts for Accessibility access on launch with `AXIsProcessTrustedWithOptions` and `kAXTrustedCheckOptionPrompt`.

If access is not granted, the menu says so and includes **Open Accessibility Settings…**, which opens:

System Settings > Privacy & Security > Accessibility

Enable Window Minder there. Nothing is stored or restored until that permission is on.

## Build and test

Core logic (macOS or Linux, Swift 5.9 or later), from this directory:

```sh
swift test
```

The Mac app and the same tests:

```sh
xcodebuild test -scheme WindowMinder -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Open `WindowMinder.xcodeproj` and run the shared **WindowMinder** scheme to launch the menu bar app. The project does not require a development team. Code signing is disabled, the app is not sandboxed, and the hardened runtime is off. The minimum system is macOS 14.

`xcodebuild test` builds the app and runs the logic tests for display-setup keys, layout files, window matching, and coordinate conversion. Those tests do not need Accessibility permission.

## Privacy

Window Minder does not use the network. It does not collect analytics, show ads, or require an account.
