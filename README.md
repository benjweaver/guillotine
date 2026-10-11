# Guillotine

**Off with the head.** A native menu bar switch that cuts the MacBook's physical panel power and keyboard backlight while leaving its logical display connected for remote access.

Guillotine leaves ordinary idle-sleep settings, display timeouts and Caffeine independent. It can optionally override lid-close sleep and requests system sleep for the mandatory battery thermal cutout. It never dims the screen to zero. Earlier commits implemented ordinary idle-sleep prevention; the current app does not.

## Supported setup

Apple Silicon MacBooks, macOS 13 or later. Verified hardware: MacBookPro18,1 running macOS 27.0.1. The built-in panel uses the private `IOMobileFramebufferRequestPowerChange` API; the keyboard uses private CoreBrightness APIs. These are experimental and can stop working after macOS updates. Activation fails with an error if either control is unavailable. Intel and desktop/external panel control are not implemented; the universal executable reports that limitation.

No brightness-to-zero substitute is used for the screen. The keyboard's backlight brightness is set to zero and checked. The panel's logical framebuffer remains active; no display configuration, mirroring, virtual display, network interface, streaming process or authentication setting is changed. No fake monitor is created. Closed-lid use requires either native macOS clamshell hardware or successful validation of the optional experimental lid override.

## Use

1. Connect external power, or opt into **Allow on battery** in Settings (off by default).
2. Click the guillotine menu icon → **Cut Screen & Keyboard**, or use Settings. Both physical controls switch off immediately; the icon fills while the guard owns them.
3. Restore with **Control–Option–Command–Space**, the menu, or Quit. Fn is optional in Settings. The local Vibepollo input source forwards Control/Option/Command but has no Fn mapping, so the default omits Fn for remote use.
4. Lock does not change the mode. It also stays active through system sleep/wake by default. Optional restore-on-sleep and restore-on-wake settings apply on the next activation. Normal system sleep still suspends streaming; the optional lid override affects lid sleep only.
5. Unplugging restores unless **Allow on battery** is enabled. Turning that preference off on battery restores immediately. Reconnecting never reactivates. App exit/crash or a stopped heartbeat restores; launch and login always start restored.
6. Battery sessions have a mandatory thermal cutout at macOS **serious/critical thermal pressure**: restore panel/backlight and the owned lid override, then request system sleep through IOPMSleepSystem. This is an OS thermal-pressure threshold, not a Celsius sensor or a guarantee that another utility cannot inhibit sleep. Activation on a hot battery is rejected; a fresh activation is required after cooling.
7. **Allow closed-lid operation (experimental)** requests the private root-domain lid-sleep control. It does not change persistent `pmset` settings, idle-sleep settings, or Caffeine. It is not certified until the physical lid/streaming test passes on your Mac.

The shortcut is registered exclusively so macOS reports registered conflicts. **Lock-screen and Secure Input delivery are not certified**; remote input reaching loginwindow is not proof a user-session Carbon hotkey is delivered. A remote client must forward the selected keys. The UI remains authenticated and no lock-screen bypass is installed. See the manual acceptance tests before relying on lock-screen recovery. A same-user SSH recovery command works independently of keyboard routing and leaves the Mac locked:

```sh
/Applications/Guillotine.app/Contents/Helpers/GuillotineGuard --restore
```

System transitions can briefly wake the panel/backlight before the guard reapplies the request on its next one-second tick. Settings report ownership, not an electrical power measurement.

## Restoration and guard

`Guillotine.app/Contents/Helpers/GuillotineGuard` is a bundled, signed, **nonprivileged** user process. No root service, installer, SIP change or background daemon is required. The app renews a five-second lease over an anonymous pipe. Pipe EOF, lease expiry, or SIGTERM trigger restoration. Independent IOKit power notifications enforce the battery preference; thermal notifications and a one-second backstop enforce the battery thermal cutout. Sleep/wake notifications grant a bounded eight-second grace for the parent to renew; the lease is never made indefinite. The default never restores merely because the screen locks.

Before a hardware write, the guard atomically writes and fsyncs `~/Library/Application Support/Guillotine/hardware-session.plist`. An exclusive file lock prevents two guards owning the same hardware. An app restart recovers a killed guard's journal before activation. A killed guard itself cannot execute cleanup: app recovery or the next launch retries restoration. If APIs become unavailable, restart macOS and report the error.

The guard never changes keyboard auto-brightness. While active it keeps the backlight at zero; if the user/OS raises it, it records that new value before reapplying zero. Restoration leaves a nonzero current value alone, otherwise restores the most recently recorded value. Panel restoration sends power-on only for the session's owned power-off request; no public per-client ownership token exists for this private API. Normal macOS power behavior resumes when the guard ends.

Remove by restoring, disabling launch at login, quitting and deleting the app. There is no privileged helper to uninstall. Keep a pending recovery journal until restoration has succeeded.

## Build, signing and tests

Open `Guillotine.xcodeproj` and run the **Guillotine** scheme on My Mac. The complete shared project is included; XcodeGen is optional. Xcode 16+ is recommended; verified with Xcode 27 beta.

```sh
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
open build/Build/Products/Release/Guillotine.app
```

The supplied app and guard are Developer ID signed with hardened runtime and secure timestamps, but not notarized. For distribution, sign/notarize using your own Apple credentials. Do not weaken Gatekeeper or SIP.

```sh
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGN_IDENTITY=- test
python3 scripts/test-guard.py build/Build/Products/Debug/GuillotineGuard
```

The guard test flag uses fake hardware only. It is not a system-power override. Test results and remaining physical/remote checks are in [docs/TESTING.md](docs/TESTING.md). API references are in [docs/PLATFORM.md](docs/PLATFORM.md). `./scripts/make-icon.sh` regenerates app artwork from the same vector drawing as the menu and Settings icons.

GPL-3.0-only, including original artwork; see LICENSE. The repository remains private during development.
