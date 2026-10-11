# Guillotine

**Off with the head.** A native menu bar switch that cuts the MacBook's physical panel power and keyboard backlight while leaving its logical display connected for remote access.

Guillotine does **not** prevent sleep, sleep the computer, alter display timeouts, dim the screen to zero, or configure Caffeine. macOS sleep settings and other apps remain independent. If you want an awake remote host, configure those separately. This is the revised physical-control implementation; earlier commits implemented idle-sleep prevention.

## Supported setup

Apple Silicon MacBooks, macOS 13 or later. Verified hardware: MacBookPro18,1 running macOS 27.0.1. The built-in panel uses the private `IOMobileFramebufferRequestPowerChange` API; the keyboard uses private CoreBrightness APIs. These are experimental and can stop working after macOS updates. Activation fails with an error if either control is unavailable. Intel and desktop/external panel control are not implemented; the universal executable reports that limitation.

No brightness-to-zero substitute is used for the screen. The keyboard's backlight brightness is set to zero and checked. The panel's logical framebuffer remains active; no display configuration, mirroring, virtual display, network interface, streaming process or authentication setting is changed. No fake monitor is created. This does not override lid-close behavior: leave the lid open or establish a supported macOS clamshell setup separately.

## Use

1. Use external power or battery; the reported power source is informational.
2. Click the guillotine menu icon → **Cut Screen & Keyboard**, or use Settings. Both physical controls switch off immediately; the icon fills while the guard owns them.
3. Restore with **Control–Option–Command–Space**, the menu, or Quit. Fn is optional in Settings. The local Vibepollo input source forwards Control/Option/Command but has no Fn mapping, so the default omits Fn for remote use.
4. Lock does not change the mode. It also stays active through system sleep/wake by default. Optional restore-on-sleep and restore-on-wake settings apply on the next activation. Normal sleep still suspends streaming; Guillotine does not keep the Mac awake.
5. App exit/crash or a stopped heartbeat restores physical controls. Plugging/unplugging power preserves the current mode. Launch and login always start restored.

The shortcut is registered exclusively so macOS reports registered conflicts. **Lock-screen and Secure Input delivery are not certified**; remote input reaching loginwindow is not proof a user-session Carbon hotkey is delivered. A remote client must forward the selected keys. The UI remains authenticated and no lock-screen bypass is installed. See the manual acceptance tests before relying on lock-screen recovery. A same-user SSH recovery command works independently of keyboard routing and leaves the Mac locked:

```sh
/Applications/Guillotine.app/Contents/Helpers/GuillotineGuard --restore
```

System transitions can briefly wake the panel/backlight before the guard reapplies the request on its next one-second tick. Settings report ownership, not an electrical power measurement.

## Restoration and guard

`Guillotine.app/Contents/Helpers/GuillotineGuard` is a bundled, signed, **nonprivileged** user process. No root service, installer, SIP change or background daemon is required. The app renews a five-second lease over an anonymous pipe. Pipe EOF, lease expiry, or SIGTERM trigger restoration. Sleep/wake notifications grant a bounded eight-second grace for the parent to renew; the lease is never made indefinite. The default never restores merely because the screen locks.

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
