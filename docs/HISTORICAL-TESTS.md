# Verification

## Actually run — 2026-10-10

Host: Apple Silicon, macOS 27.0.1 (26A434), Xcode 27.0 beta (27A5252f), Swift 6.4 compiler in Swift 5 language mode. The deployment target is macOS 13.0; minimum-OS and Intel runtime testing remain outstanding.

- `xcodebuild ... test`: **15 tests passed, zero failures**. Battery/UPS/unknown power rejection; AC activation; loss of power between activation checks; stale cached AC; notification/shortcut startup failure; release on battery/UPS/unknown; reconnect stays disabled; 100 balanced toggle cycles; acquire/release errors; relaunch starts disabled; shortcut validation/persistence; real IOKit acquire/release; real Carbon registration, conflict and replacement; Carbon hotkey event delivered to registered handler disables the controller.
- Universal Release build: **succeeded**. `lipo -archs` reports `x86_64 arm64`. `codesign --verify --deep --strict` passed for the ad-hoc signed local binary. The AppIntents metadata extraction warning is expected (no AppIntents dependency); Xcode 27's test framework also warns about its own newer minimum OS, not the app deployment target.
- Native host UI: Settings opens, starts OFF on AC, enables successfully, displays ON and allows disable; explanatory text wraps fully after visual inspection.
- `pmset -g assertions` while enabled showed a Guillotine-owned **PreventUserIdleSystemSleep** assertion. Guillotine held no PreventUserIdleDisplaySleep assertion.
- Sent SIGKILL to the specific enabled Guillotine test PID: its assertion disappeared from `pmset -g assertions`. Relaunch visually showed OFF. Enabled again, then used the native app **Quit** command: process and owned assertion disappeared. Other applications' assertions remained.
- Physical global-shortcut delivery is **not certified**. Computer Use's synthesized modifier-key chords did not disable the app. In the VM, Command-Space arrived as Space (Quick Look), indicating modifiers were not reliably delivered by this test path. Carbon registration/conflict and callback-to-disable tests passed; a real keyboard test is still required.
- During the session, an installed Vibepollo process was observed holding its own display-sleep assertion while streaming. No second-device video or input acceptance test was run, and no streaming process was changed.

## Guillotine rename, signing and local installation — 2026-10-10

- Re-ran the renamed target's XCTest suite: **15 passed, zero failures**.
- Universal Release build succeeded using **Developer ID Application: Ben Weaver (AR25V66TVY)**, secure timestamp and hardened runtime. `codesign --verify --deep --strict` passed, including after installation to `/Applications/Guillotine.app`. Both arm64 and x86_64 slices are present.
- Launched the installed signed app. Visually checked Settings, shared guillotine artwork, OFF → ON → OFF, and the filled-blade/indicator-dot active state. Left running OFF with launch at login OFF for user testing.
- Full GPL v3 license is bundled with the app and source; code and original artwork are GPL-3.0-or-later. This local build is signed but has not been notarized.
- Earlier host and guest checks below were performed under the original Nightjar branding; historical process names and screenshots should be interpreted accordingly. The behavior is unchanged.

## UTM macOS VM

VM UUID `C528BB02-1C9E-43EC-A0A7-2C792D1B03B2` was initially stopped and started for testing. Its desktop eventually became usable after an initially black console. The backend reports `utmctl exec` unsupported. Guest UI was used instead. The existing `macos27` SSH/SFTP alias was found, but its configured private address returned “No route to host” from this host session. After a graceful guest restart, the temporary `vm-transfer` shared folder mounted and supplied the universal Release archive.

- Launched the Release app in the guest: moon icon, **Enable Headless Mode**, **External power connected**, and desktop/no-lid status were visible. It started OFF.
- Enabled from the guest menu: icon changed to the lightning circle. Guest `pmset -g assertions` showed PID 878 (Guillotine) holding **PreventUserIdleSystemSleep**; **PreventUserIdleDisplaySleep** was zero system-wide.
- Issued SIGKILL to that exact test PID. The console subsequently had display/rendering problems, so a complete guest crash-cleanup/relaunch result is **not certified**. The equivalent host crash-cleanup and relaunch checks above passed.
- The test app was extracted under `/tmp/nightjar-test`. A temporary UTM share points only to this workspace's `work/vm-transfer` directory. It contains only the app archive; remove that share through UTM → Virtual Machine → Shared Folder → vm-transfer → Remove when no longer needed. No guest security or network setting was changed.

A VM cannot certify physical lid closure, keyboard lighting, AC disconnect or real display sleep.

## Physical hardware / second-device acceptance checklist — not yet run

Record Mac model/chip, macOS version, power adapter, capture host/client versions, display/adapter/virtual display setup, power/lock settings and results. Repeat on Apple Silicon first, then Intel where available. Disable other sleep-prevention utilities when measuring Guillotine; do not change a streaming host's policies without understanding their effect.

| Check | Procedure and expected result |
| --- | --- |
| Fresh launch/reboot | Launch on AC and battery, and reboot with launch at login both off/on. Mode always starts OFF; no Guillotine assertion until explicitly enabled. |
| AC, not charging | Full battery and optimized charging paused: enable succeeds. Desktop AC: enable succeeds. UPS supplying battery power: activation is rejected. |
| Lid open / desktop | Enable on AC. Wait longer than normal system idle threshold. SSH command continues responding. `pmset -g assertions` identifies only Guillotine's idle-system-sleep assertion. |
| Genuine display sleep | Let the configured display timeout expire, or deliberately use `pmset displaysleepnow` on the test Mac. Verify the panel truly sleeps and SSH still runs. Guillotine must not hold a display assertion. Rewake normally. Other apps can independently prevent display sleep. |
| Keyboard backlight | With macOS inactivity timeout configured, stop input and confirm the backlight times out. Remote/local input may reset OS inactivity. Guillotine must not generate activity. |
| Lid closed, supported setup | On AC with approved external keyboard/mouse and an external display, establish native clamshell operation, then enable Guillotine and close lid. Confirm SSH liveness and video progress beyond the idle timeout. |
| Lid closed, dummy plug | Repeat without a physical monitor using the exact tested EDID emulator. Record detection and actual capture success; do not infer success from the menu. |
| Lid closed, no display | Confirm the UI says clamshell setup is unavailable. Sleep on close is expected. This software-only configuration is unsupported, not a passing headless test. |
| Virtual display | Verify provider compatibility and capture selection separately. Confirm whether it actually supports clamshell mode; graphical surface availability alone is insufficient. |
| Unplug while lid closed | In a supported clamshell session, unplug the AC adapter. Guillotine releases its assertion on notification; macOS may sleep and remote access may end normally. Reconnect and reopen/reconnect as needed: mode must remain OFF. Inspect assertions after wake. |
| Rapid power transitions | Unplug/replug repeatedly, including while toggling and with menu open. No automatic re-enable, duplicate assertion or stuck active state. |
| Global disable shortcut | With Finder/another app focused, press the configured physical chord. Mode turns OFF and assertion disappears. Change shortcut, relaunch, and repeat. Old chord must be unregistered. Test conflicts with another utility; failed change must preserve old working chord. Secure Input/lock screens may block it. |
| Quit | Enable, Quit from status menu: assertion disappears and existing remote sessions are left running until normal macOS sleep policy acts. |
| Crash | Enable, record the exact app PID, terminate only that PID with SIGKILL. Its assertion must disappear. Relaunch is OFF. Already checked on host; repeat on hardware configurations under test. |
| Lock/authentication | Lock while enabled, verify password/Touch ID policy is unchanged. Remote access must still obey permissions and credentials. No auto-unlock/autologin. Test explicit Sleep, logout and shutdown; Guillotine does not override them. |
| Remote streaming | For Sunshine/Moonlight, the exact Vibepollo build if available, and Screen Sharing, stream a changing clock/animation. Test local display sleep, close/reopen, lock/unlock, input, reconnect, and disable. Check actual progressing frames and controllable input, not just a connected client or stale image. Record any host-held display assertion. |
| Launch at login / removal | Move a signed build to Applications, register and approve Login Items if needed, log out/in: app launches OFF. Turn setting off, log out/in: no launch. Quit/delete app; no helpers, sudoers entries or power settings should remain. |
| Other settings ownership | Change display/sleep settings during a session, disable/quit/crash: Guillotine must not restore over those user changes. It does not modify any of them. |

## Limits of the tests

Injected power values validate the state machine, not IOKit's physical notification delivery. Real IOKit tests validate assertion calls, not a full idle interval. The universal build verifies both architectures compile/link, not Intel execution. Helper lease/recovery tests are not applicable because this app has no privileged helper and no persistent power changes. No thermal, closed-lid, minimum-OS, backlight or end-to-end streaming result is implied by the host/VM tests.

## Fn + Space default and resource packaging follow-up

- Default changed to **Fn–Control–Option–Command–Space**. A standalone Carbon probe registered that exact chord exclusively with `noErr` and no registered conflict, then released it. A second probe successfully reserved the Fn and non-Fn variants simultaneously, showing the registrations are distinct.
- Hotkey registrations now request `kEventHotKeyExclusive`, so conflicts reported by macOS cannot silently share the registered shortcut. Configured shortcuts remain supported; Fn is optional for keyboards without it.
- Final XCTest run: **16 tests passed, zero failures**, including Fn+Space exclusive conflict and release checks. A first version of the new test collided with the test host's own default registration; the test now uses an independent chord with Shift added. This was a test-fixture conflict, not a production fallback.
- Corrected XcodeGen resource declarations. Verified the installed signed bundle contains `AppIcon.icns`, `Assets.car`, `HeadlessGuide.txt`, and `LICENSE`. The earlier icon artwork was generated correctly but had been omitted from the app bundle by the build configuration.
- Verified the installed app UI displays Fn, Control, Option and Command selected, Space as the key, and OFF. Preserved the user's enabled launch-at-login setting. The global shortcut's physical key delivery still needs a real keyboard test.
