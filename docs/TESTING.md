# Verification — 2026-10-10

Host: MacBookPro18,1, macOS 27.0.1. Build 9 uses release Xcode 27, macOS 13 app deployment, and compiler warnings as errors. XCTest targets 14 to match the installed XCTest libraries. Intel hardware and minimum-OS runtime testing remain outstanding.

## Actually run

- 19 XCTest cases pass: disabled launch, battery opt-in, power loss/reconnect, live policy revocation, rechecks around activation, repeated toggles, failure/retry, and shortcut registration/callback behavior.
- 36 fake hardware-guard integration cases pass: disconnect, expiry/renewal, signals, SIGKILL recovery, duplicate exclusion, explicit restore, battery policy, thermal ordering, and no thermal sleep on AC. Audio cases cover default-off, preexisting mute, live/repeated toggles, fragmented/coalesced policy messages, unplugging, thermal cutoff, lease expiry, external unmute, and killed-guard recovery.
- 21 fake privileged-helper cases cover original/absent settings, disconnection, expiry with blocked renewal, external changes, unplugging, battery thermal cleanup, SIGTERM, SIGKILL/startup recovery, and interrupted absence restoration. These use files instead of system settings and do not run as root.
- Universal signed build 9 compiles cleanly with release Xcode 27. Both executable architectures and nested signatures are checked before installation. App Intents extraction is omitted because this app defines none; no warning suppression is added to compiler flags.
- Real build-7 audio guard test on this Mac: built-in speaker mute readback changed 0 → 1, live opt-out restored 0, opt-in muted again, and parent EOF restored 0 with the journal removed. This verified CoreAudio state, not audible output or streaming-client audio.
- Status-menu outside-click dismissal needs user acceptance: AppKit global mouse monitoring cancels tracking on clicks in another app; a local monitor handles clicks in Settings. Both monitors are removed at menu close. No keyboard events are monitored.
- Earlier real panel pulse: user confirmed the screen physically turned off and back on, while CoreGraphics retained one active logical display. Registry CurrentPowerState did not change and is not treated as proof.
- Earlier real keyboard/guard test: zero readback, then restored original 0.001; auto-brightness remained enabled. Caffeine kept its own display assertion; the app and guard held no sleep assertion.
- **Build 5 failed closed-lid testing.** User confirmed ON and battery allowed. Power log: 20:23:57 Clamshell Sleep on battery 98%, lid-open wake at 20:24:01. Build 6 replaces that path with a root sleep-disable lease. API success in build 5 was insufficient evidence.
- Build 6 installed and helper approved. Real activation set both `pmset SleepDisabled=1` and the kernel `SleepDisabled=Yes`; restoration returned the originally absent system setting. A separate unsigned XPC client was rejected without changing the setting.
- **Build 6 passed the user’s closed-lid awake test on this Mac.** During the test the registry showed lid closed and SleepDisabled active; the power log showed no new sleep/wake event (last sleep remained the failed build-5 event at 20:23:57). User confirmed it stayed awake on battery and could reconnect through Vibepollo while the lid remained shut. The stream disconnected at closure; uninterrupted capture did not pass. User observed the Vibepollo display behaving as a second monitor while the physical panel stayed off.
- Actual root-helper SIGKILL recovery and independent expiry under a paused guard remain unverified on hardware; fake lifecycle tests cover them. No physical thermal stress was attempted.
- Build 9 adds fake guard coverage for configurable battery sleep, disabled cutoff, threshold boundaries, invalid/missing capacities, live policy changes, Low Power Mode requests, and explicit panel rescue while OFF. Helper cases cover battery-only Low Power Mode, exact value/absence restoration, separate host/global profiles, preservation of AC/unrelated values, expiry, crash recovery, and external user changes.
- Build 9 Settings initially crashed from recursive published-property assignment; conditional clamping fixed it. Regression XCTest and actual Settings opening/editing pass, including sleep 10 → 11 → 10 and Low Power Mode threshold 20 → 25 → 20. Low Power Mode was left Off after the UI checks.
- The first real Low Power Mode test exposed an incorrect global-profile read. The user restored Off through Battery settings. The corrected helper uses Apple’s host-UUID profile. A signed direct XPC test then verified battery Low Power Mode 0 → 1 → 0 through both CFPreferences and pmset, with exact original battery/AC/global settings restored and unrelated keys unchanged. On-disk plist flushing lagged behind effective CFPreferences values; disk-only immediate readback is insufficient. No panel-power or sleep request was made during this test.
- User confirmed remote audio works. After the user reported a stuck dark panel, an explicit panel-power-on request restored it and Vibepollo was restarted; the user confirmed the physical screen returned. The precise original cause remains unconfirmed. The OFF-state restore shortcut now also requests panel power-on; startup recovery remains limited to owned changes.
- Additional signed direct XPC tests verified Low Power Mode restoration after client SIGKILL and five-second lease expiry, comparing effective battery/AC/global settings exactly. These tests did not kill the root helper. Actual low-battery sleep, thermal sleep, root-helper SIGKILL recovery with Low Power Mode, and minimum-OS/Intel behavior still require hardware testing.

Prior UTM tests concern the earlier sleep-assertion implementation; see [historical results](HISTORICAL-TESTS.md). A VM cannot certify a MacBook lid, panel, or backlight.

## Manual acceptance checklist

| Test | Expected result |
| --- | --- |
| Menu dismissal | Open from a different foreground app, then click that app, the desktop, Settings, and another menu bar item. The menu closes on each outside click. Repeat with left/right clicks, Escape, and the icon. Menu actions still work and no click monitors remain after closure. |
| Helper approval | Approve the signed service in Login Items. Settings reports Approved. An unsigned or wrong-team XPC client cannot acquire a lease. |
| Actual sleep setting | Record `pmset -g custom` and `pmset -g`. Activate with closed-lid support: SleepDisabled becomes 1. Restore: prior value/absence returns; other keys unchanged. Repeat and inspect root recovery journal cleanup. |
| Lid close on AC | Enable closed-lid support, activate, monitor changing clock/video remotely, close 20 seconds, reopen. No Clamshell Sleep event; frames/input continue on the exact display/capture setup. |
| Lid close on battery | Opt into battery operation, repeat. No Clamshell Sleep event while the lease is active. Keep normal thermal protections in force. |
| Unplug closed lid | Battery use off: restore physical controls and owned sleep setting; normal clamshell policy may then sleep. Replug must not activate. Battery use on: continue without sleep; live opt-out restores. |
| Panel/keyboard | Both physically dark on activation. Display changes and wake may briefly relight the panel; with the lid open, panel-off reapplies after events settle without recurring writes. Type and vary ambient light; keyboard zero reapplies within one second. Restore latest recorded keyboard brightness without changing auto-brightness. Repeat toggles. |
| Built-in audio | With music/video playing, check Mute built-in speakers while headless while active: local speakers silent within one second, remote stream audio continues on the chosen host. Uncheck: previous mute returns, volume/routing unchanged. Repeat with already-muted speakers, quit, app crash, and power cutoff. Test virtual/external outputs remain unchanged. Audible and streaming results require hardware/client testing. |
| Caffeine | With closed-lid option off, user sleep policy and Caffeine remain independent. With it on, global sleep is blocked; Caffeine’s own state remains unchanged. |
| Lock/hotkey | Lock normally while headless; mode stays active. Test local and remote Control–Option–Command–Space at loginwindow. Authenticate normally. Hotkey delivery is not yet certified. |
| Sleep/wake options | With closed-lid option off, test default persistence and each optional restore setting in fresh sessions. With it on, expect ordinary/manual sleep to be blocked. |
| Quit/app crash/hang | Restore on quit/EOF or five-second parent lease expiry. Physical controls and owned global sleep setting return. No forced sleep or remote-process termination. |
| Guard crash | Kill exact guard PID: app recovers physical journal; root lease independently releases. Kill app and guard, then reopen to recover physical controls. |
| Root helper crash | While active, kill exact helper PID: launchd restart restores journal before accepting another session. The guard fails closed; activation is not silently retried. |
| User power changes | Change SleepDisabled to 0 during a session: preserve that change and end session. Identical-value writes are not distinguishable. Keep other pmset keys unchanged. |
| Battery sleep | With battery operation allowed, set a cutoff just above the current charge on a test machine: controls and owned helper settings restore before sleep is requested. Disable the cutoff and verify no percentage-triggered request; restore default 10 afterward. Reconnecting must not reactivate. Do not drain the primary Mac deliberately. |
| Low Power Mode | Test Off, Whenever on battery, and a user percentage (preset 20). At/below threshold it enables only on battery. Opt-out, AC connection, quit, expiry, and crash recovery restore the exact original value/absence. Preexisting Low/High Power Mode and user changes are preserved. Low Power Mode-only operation must not block sleep. |
| OFF-state rescue | With the panel off and mode already OFF, press the restore shortcut; built-in panel power-on is requested. Launch/startup alone must not wake an unowned panel. |
| Thermal safety | Fake tests verify ordering. Do not deliberately heat hardware. Real OS serious/critical battery pressure should restore controls/owned sleep block, request sleep, and require manual reactivation. Another utility’s sleep block may prevent the transition. |
| Remote streams | Exact Vibepollo, Sunshine/Moonlight, Screen Sharing versions: progressing frames/input, lock/unlock, lid closure, reconnect, and restoration. A connected stale frame is not a pass. |
| Remove/reboot | Restore, Remove Helper, disable login, quit/delete. No owned override remains. Reboot/login starts disabled; startup helper recovery precedes new leases. |

Keep results separate: fake tests, actual settings, physical darkness, no-sleep power logs, and remote frame progression establish different properties. Private APIs need revalidation after updates.

## Build 11 panel-isolation trial

Panel-power control defaults off, and the persisted closed-lid sleep-block option
resets off once. Leave both off and use Caffeine independently. Confirm the panel
goes dark on lid closure, streaming connects and reconnects after a delay, and lid
opening plus the restore shortcut leaves WindowServer healthy. Check fresh power
and Vibepollo logs afterward; Caffeine alone does not guarantee clamshell sleep
prevention. Hardware acceptance is pending.

Local validation on 2026-10-11: 20 app tests, 38 fake guard tests, and 21 fake
helper tests passed. Developer ID Release build completed without compiler
warnings; strict recursive signature verification passed. Installed build 11
and confirmed both panel control and closed-lid sleep prevention are off.
No new physical closed-lid streaming test has been performed.

## Build 12 panel request regression

With panel control selected, observe exactly one off request across multiple guard
ticks and app lease renewals, followed by one on request on disconnect, SIGTERM,
or lease expiry. Recovery after a killed guard must still restore journaled panel
ownership without needing the panel option on the recovery command. Confirm on
hardware that lid-open and wake transitions no longer fight recurring off requests;
macOS is allowed to relight the panel until another explicit activation.

2026-10-11 validation: all 20 app tests and 39 fake guard tests passed. The
Developer ID Release build succeeded without compiler warnings, and recursive
strict signature verification passed outside the sandbox. Build 12 was installed
and relaunched disabled. Closed-lid streaming and lid-open crash acceptance remain
pending; no streaming or panel activation was performed during installation.

## Build 13 standard panel control

The panel checkbox and app preference are removed. Every activation requests
panel-off once and restoration requests panel-on; periodic ticks and renewals
remain free of panel-power writes. Recovery of keyboard-only trial journals
leaves their unowned panel alone. The explicit restore shortcut still provides
panel-on rescue while disabled. Leave the lid open for the current interim setup;
closed-lid reliability remains unresolved.

2026-10-11 validation: 20 app tests and 40 fake guard tests passed. The signed
Release build had no compiler warnings, strict recursive signature verification
passed outside the sandbox, and build 13 was installed and relaunched disabled.
Panel activation and closed-lid streaming remain for physical acceptance.

## Build 16 display-event reapplication

The user reported that build 14 (same panel behavior as release 1.0.1) leaves the
physical panel on after a Vibepollo disconnect with the lid open. The guard was
still running with panel ownership journaled. WindowServer logged built-in power
state 0 → 1 as the remote virtual display changed; no guard event handler existed
to reapply off. This is a regression of the activation-only policy, separate from
the unresolved closed-lid watchdog failure.

Build 16 passed all 47 fake guard tests and 20 XCTest cases. The universal
Developer ID build and nested signatures verified, and it was installed locally
with controls restored. No new release has been published.

Fake guard coverage now includes remote display removal, duplicate layout
notifications, coalesced event bursts, wake without layout changes, closed/unknown
lid suppression, cancellation at disconnect/system sleep, and restore-on-wake
precedence. Hardware acceptance: enable Guillotine with the lid open, disconnect
Vibepollo, confirm the physical panel returns dark within a few seconds, reconnect,
and repeat. Confirm Restore still lights the panel. **Build 16 failed:** the
user confirmed the panel stayed lit after disconnect. Its guard logged no
event-driven reapplication despite WindowServer recording built-in power-on.
The logical-layout/workspace observers are insufficient in this configuration;
notification delivery and a panel-specific signal need further investigation.

## Build 17 display callback delivery

During the repeat disconnect/reconnect, two read-only probes watched the same
Mac. The plain NSRunLoop probe received zero CoreGraphics callbacks. The hidden
NSApplication probe received 16 callbacks and seven screen-parameter
notifications. Neither received a workspace screen-wake notification. The
panel's displayOnTimestamp changed once; registry CurrentPowerState remained
unsuitable as a physical measurement. The guard now uses the proven AppKit event
pump for real sessions; recovery remains short-lived, and fake tests stay out of
the GUI session. The universal Developer ID build, nested signatures, and seven
display-event regression cases passed; build 17 was installed locally with
controls restored. Hardware retest pending.
