# Guillotine

**Off with the head.** A native menu bar switch that powers off an Apple Silicon MacBook’s physical panel and keyboard backlight while retaining its logical display for remote access.

Lid-open controls leave sleep settings and Caffeine independent. **Optional closed-lid support requires an approved privileged helper and temporarily disables system sleep globally, including ordinary and manual sleep.** That broader control replaces the experimental lid-only override, which failed the physical test on this Mac. No brightness-zero substitute is used for the panel.

## Supported setup

macOS 13+, Apple Silicon MacBooks. Hardware checked: MacBookPro18,1, macOS 27.0.1. Panel power uses private IOMobileFramebuffer APIs; keyboard brightness uses private CoreBrightness APIs, with zero readback verified. Both can change after OS updates. Intel, desktop, and external-panel power control are not implemented; the universal executable reports unsupported hardware clearly.

Guillotine leaves display layout, virtual displays, network interfaces, streaming processes, and authentication alone. Retaining a logical framebuffer is different from guaranteeing capturable frames after lid closure. Physical lid-close sleep prevention and a progressing remote stream must both be tested on the exact hardware and host version. No dummy display is created.

## Use

1. Connect external power or opt into **Allow on battery** (off by default). Plugged in but not charging counts as external power.
2. For closed-lid use, enable **Allow closed-lid operation**, choose **Install Helper…**, and approve Guillotine under macOS **Login Items & Extensions → Allow in the Background**. Keep the app in Applications. Administrator approval is required by macOS.
3. Choose **Cut Screen & Keyboard**. Activation requires working power notifications, a registered restore shortcut, both physical controls, and, when selected, a working privileged lease. Failed activation restores owned changes and reports an error.
4. Restore with **Control–Option–Command–Space**, the menu, or Quit. Fn is optional locally; the inspected Vibepollo source does not forward it. Lock-screen/Secure Input shortcut delivery is not yet certified. Normal lock and authentication remain in force.
5. Lock never changes the active mode. Sleep/wake restoration is optional and off by default. With closed-lid support off, sleep follows the user’s policy. With it on, the global sleep block lasts until restoration.
6. Unplugging restores unless battery use is allowed. Turning battery use off on battery restores immediately. Reconnecting never reactivates. Launch/login starts restored.
7. Serious/critical macOS thermal pressure on battery restores physical controls and the owned sleep override, then requests system sleep. This uses OS thermal pressure, not a fabricated Celsius sensor. No deliberate heat test is appropriate. Another utility’s pre-existing sleep block can still reject sleep.

Transitions or keyboard activity may briefly light the hardware before the guard reapplies off on its next one-second tick. Status indicates ownership, not an electrical power measurement.

Same-user recovery without changing lock state:

```sh
/Applications/Guillotine.app/Contents/Helpers/GuillotineGuard --restore
```

## Restoration and privilege

The signed, nonprivileged `GuillotineGuard` owns panel/backlight changes, uses independent IOKit power notifications, and holds a five-second anonymous-pipe lease from the app. EOF, expiry, and termination restore. A durable user journal supports recovery after a killed guard. The keyboard’s auto-brightness setting is unchanged; restoration preserves a current nonzero value and otherwise restores the latest recorded nonzero brightness.

The optional root `GuillotineLidHelper` accepts only the signed guard from the current console user. Its XPC interface can renew or release one lease; callers cannot supply commands, paths, or power-setting names. It journals the original `SleepDisabled` value and whether it was absent before invoking fixed `pmset -a disablesleep 1`. A separate five-second lease, connection invalidation, power notifications, and a thermal backstop restore the setting. Launchd restarts a crashed helper to recover its root-owned journal before accepting another session. No SIP change or private Apple entitlement is required.

Restoration touches only the app-owned key if it still equals the value written. Other power settings remain intact. A pre-existing sleep block is left unchanged. Concurrent writes of the identical value cannot be attributed perfectly; avoid competing tools that change `disablesleep`. Keep recovery journals until restoration succeeds. See [platform details](docs/PLATFORM.md).

To remove: Restore, choose **Remove Helper**, disable launch at login, quit, and delete the app. Do not delete an app with pending root recovery before its helper has restored the setting. The helper is embedded in the app; macOS ServiceManagement manages registration/removal.

## Build and verify

The complete shared Xcode project is included. `project.yml` is the source for optional XcodeGen regeneration. Verified with release Xcode 27. Compiler warnings are errors. Tests target macOS 14 because Xcode 27’s XCTest requires it; the app targets 13.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

Ad hoc builds can exercise lid-open controls and fake tests. **Real privileged XPC requires matching trusted signatures**: change the two requirements in `Sources/Shared/LidService.h` to your signing identity and sign the app and both helpers consistently. This local build uses Ben Weaver’s Developer ID (AR25V66TVY), hardened runtime, and secure timestamps. It is a private test build, not a notarized release.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGN_IDENTITY=- test
python3 scripts/test-guard.py build/Build/Products/Debug/GuillotineGuard
python3 scripts/test-lid-helper.py build/Build/Products/Debug/GuillotineLidHelper
```

Fake tests never invoke hardware controls or write system power settings. See [tests and physical checklist](docs/TESTING.md). Artwork comes from one vector drawing via `scripts/make-icon.sh`, matching the menu and Settings icons. GPL-3.0-only; see LICENSE. Repository remains private during development.
