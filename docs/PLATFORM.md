# Physical controls and closed-lid sleep prevention

## Why the implementation changed

The physical build-5 test failed: the user confirmed ON with battery allowed, and the power log recorded **2026-10-10 20:23:57, Clamshell Sleep, battery 98%**, followed by lid-open wake. This is system sleep; no streaming-host change is needed to explain it.

An idle-sleep assertion does not prevent clamshell sleep. Apple’s [RootDomainUserClient](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp) selector 12 changes a shared powerd clamshell bit, not a process-owned token. Its successful return and `AppleClamshellCausesSleep` registry value did not establish reliable no-monitor operation. That path is retained only for cleanup of journals from old builds, never for new activation. Apple’s per-client AppliesOnLidClose assertion requires a private Apple entitlement that Guillotine does not claim.

[Adrafinil’s upstream experiments](https://github.com/kageroumado/adrafinil/blob/main/Docs/ARCHITECTURE.md) identify privileged `pmset disablesleep` as the broader working approach. [Apple’s pmset implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m) writes the global `SleepDisabled` control; [IOPMEnergyPrefs](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMEnergyPrefs.c) defines its preferences domain and change notification. **This blocks system sleep broadly, not just lid-close sleep.** The Settings text exposes that tradeoff. Hardware acceptance remains necessary; a successful setting write alone is not a passing lid test.

## Privileged lease

The optional helper uses [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), with an embedded LaunchDaemon, macOS background-service approval, and no legacy installer or SIP change. Only `GuillotineLidHelper` runs as root. The hardware guard remains a user process.

The listener enforces a code-signing requirement for the guard’s identifier and Developer ID team on incoming XPC messages; the guard verifies the helper’s requirement. The listener also checks the current console UID. One connection owns the lease. Renew and release run serially on the main queue, check connection identity, and take no arbitrary command/path/settings arguments.

The helper records `SleepDisabled`, including an originally absent key/container, in `/Library/Application Support/Guillotine/lid-session.plist` before modification. The folder is root-owned, not group/world-writable, and validated against symlinks. Atomic journal writes are fsynced with their directory. The only command is fixed `/usr/bin/pmset -a disablesleep 1/0`. Absence restoration uses the exact system preferences key and notification identified in Apple’s source, preserving the latest other dictionary entries. An already-disabled sleep policy is never acquired or cleared.

On release, disconnect, five awake seconds without renewal, disallowed battery operation, or console-user change, the helper restores its owned setting. Launchd KeepAlive restarts a killed helper; startup replays recovery before accepting a lease. Restoration is compare-and-restore: a changed value is preserved, and a changed policy ends the session rather than being repeatedly overwritten. Identical concurrent writes cannot be distinguished, and the preferences API has no atomic compare-and-swap across unrelated writers. Do not run competing global sleep-control utilities. No other pmset setting is changed.

Helper removal is available only after the UI has released the active session. macOS manages registration. A pending recovery journal must survive until recovery succeeds. If recovery fails, the helper refuses new leases and reports the failure; do not manually erase the journal.

## Panel and keyboard

[Clamless](https://github.com/TCXM/clamless/blob/main/src/helper/clamless-display.c) separates logical display configuration from IOMobileFramebuffer panel power. Guillotine uses only runtime-resolved `IOMobileFramebufferOpen` and `IOMobileFramebufferRequestPowerChange(0/1)` for `disp0,`, leaving external framebuffers and display layout alone. A real timed pulse returned success, the user confirmed darkness, and CoreGraphics retained one active display. Registry CurrentPowerState stayed 1, so it is not treated as physical proof. This is a private API, not a supported cross-model panel interface or a power-consumption measurement.

[Keyboard backlight upstream](https://github.com/noluyorAbi/macos-keyboard-backlight/blob/main/src/index.js) identifies private CoreBrightness `KeyboardBrightnessClient`. Runtime selector checks and zero readback guard activation. The host read 0 while controlled and its original 0.001 after release; auto-brightness stayed enabled. A user journal records the latest nonzero brightness before forcing zero. Restore preserves a currently nonzero user/OS value. Panel ownership has no public per-client token, so concurrent panel utilities cannot be perfectly distinguished.

The physical guard journals under `~/Library/Application Support/Guillotine`, holds an exclusive file lock, and independently observes power/thermal transitions. App EOF, five-second heartbeat expiry, SIGTERM, and explicit restore release controls. A killed guard cannot clean itself up; the app or next launch replays its journal. The privileged lease expires independently if the guard dies. Normal sleep/wake grants a bounded eight-second parent-heartbeat grace. Lock never ends the session. Optional restore-on-sleep/wake settings apply to the next activation.

## Battery and thermal behavior

Battery operation defaults off. AC power is determined from IOKit’s providing power source, independent of active charging. Unknown/UPS sources are treated as limited power. The app rechecks power around activation; both guard and root helper receive power notifications and enforce the opt-in independently. Replugging never reactivates.

On battery, [serious thermal pressure](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious) or critical pressure restores physical controls and the owned sleep override before requesting `IOPMSleepSystem`. No Celsius sensor API is claimed. The root helper also schedules a sleep request after a two-second physical-restoration grace if the guard is unresponsive. Cooling takes priority in that failure case; physical restoration cannot be guaranteed until the user guard runs/recovery occurs. Sleep-request acceptance is not proof of a transition, and a pre-existing sleep block owned by another tool remains untouched. No actual thermal-stress test has been run.

## Capture, keyboard routing, and security

Keeping the computer awake and maintaining a capturable framebuffer are separate. Guillotine preserves its logical display and never changes a virtual display, streaming process, or network interface. A virtual display/adapter may still be needed by the exact capture stack after lid closure. Verify progressing frames and input on another device.

The inspected local Vibepollo input source posts session keyboard events, maps Control/Option/Command, and lacks Fn forwarding. This supports the non-Fn default; it does not prove Carbon hotkey delivery while loginwindow or Secure Input owns input. Lock-screen shortcut delivery remains a physical acceptance item. Guillotine does not bypass authentication, weaken SIP, intercept credentials, or change lock policy. Streaming hosts retain their own permissions. Guillotine itself does not request Screen Recording or Accessibility for these controls.

## Optional built-in audio mute

The nonprivileged guard uses public CoreAudio device enumeration, built-in transport filtering, output-stream detection, and `kAudioDevicePropertyMute` on the output main element. No audio permission, privileged operation, routing change, or playback control is needed. Devices with virtual, aggregate, HDMI, USB, or Bluetooth transport are excluded. This mutes built-in audio playback, not an electrical shutdown of the codec or amplifier. Whether a particular streaming host captures before hardware mute is an acceptance test, not a guarantee.

Before setting mute, the durable hardware journal records the device UID and original value. Unchecking, ending the session, and recovery restore only a current mute value of 1 owned by the guard. Already-muted devices need no override. Missing devices or API errors retain pending recovery state and surface an actionable failure. A guard killed together with the app cannot restore until recovery runs on reopening. Identical-value external writes cannot be attributed. The audio preference persists independently of session activation and applies within one second while active.
