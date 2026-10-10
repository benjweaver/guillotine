# Guillotine

**Off with the head.** A small native menu bar app for headless remote access on external power. A blade suspended over a display turns the name into a visual pun: keep the computer awake while its physical screen sleeps. The icons are original vector artwork.

Guillotine prevents **idle system sleep**, while allowing real display sleep and normal keyboard backlight timeout. It starts disabled, turns off on external-power loss, and never re-enables on reconnect. macOS 13 Ventura or later; Apple Silicon first, universal Intel build supported.

**Closed-lid limitation:** the assertion does not prevent lid-close sleep. Use macOS closed-display mode with external power, display, keyboard and mouse/trackpad. A compatible EDID dummy plug may replace the monitor, but must be tested on your Mac. Software-only closed-lid operation without a display is **unsupported**. No privileged helper or persistent power override is installed. See [platform investigation](docs/PLATFORM.md).

## Build and run

Open `Guillotine.xcodeproj`, select the **Guillotine** scheme and **My Mac**, then Run. The complete project and shared scheme are checked in; XcodeGen is not required. Xcode 16+ with the macOS SDK is recommended. The verified build environment is recorded in [TESTING.md](docs/TESTING.md).

Command-line local build (no signing team required):

```sh
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
open build/Build/Products/Release/Guillotine.app
```

For distribution, select your Developer ID team, sign, archive and notarize with your own Apple credentials. The supplied local binary is signed with Ben Weaver’s Developer ID Application certificate and hardened runtime, but is not notarized. Do not weaken Gatekeeper or SIP. Run your local Xcode build if downloaded binaries are blocked.

## Use

1. Connect external power. Full battery or optimized charging still qualifies. Desktop AC qualifies; a UPS running on battery does not.
2. Click the outlined guillotine in the menu bar → **Enable Headless Mode**. The blade fills and a power dot appears when active. Let the display sleep normally.
3. Disable from the menu or press **Fn–Control–Option–Command–Space** while another app has focus. Settings lets you choose modifiers and a key; a conflicting shortcut leaves the old one registered. The Fn key is required by default; keyboards without Fn can choose another chord. Secure Input/lock screens may block hotkeys. macOS exclusive registration detects registered conflicts and blocks activation until an available shortcut is chosen. Other utilities or OS gestures may still intercept keys; test delivery with your physical keyboard.
4. Optionally enable **Launch Guillotine at login** in Settings. It launches disabled. Approve Login Items in System Settings if macOS requests it.
5. **Quit Guillotine** releases the assertion before exiting. If the app crashes, macOS releases its process-scoped assertion automatically.

The menu reports AC status and closed-lid requirements. “Display detected” includes virtual displays and does **not** certify clamshell operation. The bundled **Headless Setup & Limitations** guide is available from the menu, offline.

## Remote access and permissions

Guillotine needs no administrator, Accessibility, Input Monitoring, Screen Recording or network permission. It never unlocks the Mac or configures sharing. Enable Remote Login or Screen Sharing yourself under System Settings → General → Sharing. Streaming hosts need their own permissions.

- **SSH:** no graphical display required. Requires the Mac and network to remain awake.
- **macOS Screen Sharing:** native support; High Performance virtual displays require compatible Apple Silicon Macs with macOS 14+. Authentication and FileVault remain normal.
- **Sunshine + Moonlight:** Sunshine has experimental native arm64/x86_64 macOS support; Moonlight is the client. Capture requires an available display and host permissions. Sleeping/removed physical displays need testing with a virtual display or dummy plug.
- **Vibepollo:** fork/version dependent. Nonary’s upstream has macOS workflow code, but inherited Sunshine install docs do not prove a published, functioning macOS release. Its Windows/Linux virtual-display features are not a macOS guarantee. Verify your exact release; Guillotine makes no runtime compatibility claim.

During host testing, a running Vibepollo process was observed holding its **own display-sleep assertion** while streaming. Such a host can keep the physical display awake independently of Guillotine. Guillotine cannot guarantee display timeout while another app prevents it, and does not release or override another app’s assertions. This observation does not certify end-to-end streaming with the lid closed.

Source links, capture details and constraints are in [PLATFORM.md](docs/PLATFORM.md). Network and streaming operation are unchanged by Guillotine; no display surface is created or removed.

## Reliability and removal

Only a `PreventUserIdleSystemSleep` IOKit assertion is owned. No `pmset`, brightness, backlight, lock, display, network or authentication settings are changed. Releasing it resumes normal policy without forcing sleep or terminating remote sessions. User changes to system settings are therefore never overwritten. Disable, Quit, power loss, unknown power state and requested system sleep all release the assertion. Start-up failures block activation and show an actionable error.

Remove by turning off launch at login, quitting, then deleting `Guillotine.app`. There is no helper to install/remove and no power-setting recovery procedure. Preferences contain only the shortcut; delete the `dev.guillotine.Guillotine` defaults domain if desired.

## Tests and development

```sh
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- test
```

See [TESTING.md](docs/TESTING.md) for results actually obtained and the physical-hardware/second-device checklist. Unit tests cover fail-closed power handling, activation races, restoration, failure paths, repeated toggles and shortcut persistence, plus real IOKit acquisition/release.

Sources are in `Sources/Guillotine`. `SessionController` contains the serial state machine; `PowerMonitor` owns the main-run-loop notification source; `IdleSleepAssertion` owns the process-scoped override. AppKit provides the menu and Carbon hotkey registration; SwiftUI provides Settings. `project.yml` optionally regenerates the project with XcodeGen. `./scripts/make-icon.sh` regenerates all icon sizes.

Contributions should preserve AC-only activation, never persist the active state, and include transition tests and hardware results for any new power controls. Licensed under GPL-3.0-only. See LICENSE for the complete GNU General Public License version 3.

The repository is private during development. GPL-3.0-only applies to the code and original icon artwork; private hosting does not change the license.
