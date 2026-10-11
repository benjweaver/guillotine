# Physical controls and closed-lid sleep prevention

## Panel power transitions (build 17)

Activation requests panel-off; restoration requests panel-on. The guard runs a
hidden AppKit application event loop: a plain NSRunLoop did not deliver display
callbacks in the physical disconnect test. CoreGraphics
reconfiguration callbacks compare the online display layout, active and main
states, mirroring, rotation, and mode. A changed configuration or workspace
screen/system wake schedules one off request after a one-second settling delay,
with at least three seconds between off writes. Additional events replace the
pending timer. Unchanged layout notifications cannot create a feedback loop from
our own panel request. No recurring panel-write timer or automatic retry exists.

Event reapplication checks the lid immediately before writing; closed or unknown
lid state suppresses it. System sleep cancels pending work, and restore-on-wake
takes precedence. Lease expiry, restore requests, and battery/thermal policy also
take precedence over a pending write. Physical acceptance after a Vibepollo
disconnect remains required; fake events establish scheduling, not panel darkness.

There is no separate panel-control preference. Startup recovery honors recorded
panel ownership, including keyboard-only journals from builds 11–12. The restore
shortcut while disabled still provides explicit panel-on rescue. Leave the lid
open for the current workflow; closed-lid streaming remains unreliable.

## Why the implementation changed

The physical build-5 test failed: the user confirmed ON with battery allowed, and the power log recorded **2026-10-10 20:23:57, Clamshell Sleep, battery 98%**, followed by lid-open wake. This is system sleep; no streaming-host change is needed to explain it.

An idle-sleep assertion does not prevent clamshell sleep. Apple’s [RootDomainUserClient](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp) selector 12 changes a shared powerd clamshell bit, not a process-owned token. Its successful return and `AppleClamshellCausesSleep` registry value did not establish reliable no-monitor operation. That path is retained only for cleanup of journals from old builds, never for new activation. Apple’s per-client AppliesOnLidClose assertion requires a private Apple entitlement that Guillotine does not claim.

[Adrafinil’s upstream experiments](https://github.com/kageroumado/adrafinil/blob/main/Docs/ARCHITECTURE.md) identify privileged `pmset disablesleep` as the broader working approach. [Apple’s pmset implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m) writes the global `SleepDisabled` control; [IOPMEnergyPrefs](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMEnergyPrefs.c) defines its preferences domain and change notification. **This blocks system sleep broadly, not just lid-close sleep.** The Settings text exposes that tradeoff. Hardware acceptance remains necessary; a successful setting write alone is not a passing lid test.

## Privileged lease

The optional helper uses [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), with an embedded LaunchDaemon, macOS background-service approval, and no legacy installer or SIP change. Only `GuillotineLidHelper` runs as root. The hardware guard remains a user process.

The listener enforces a code-signing requirement for the guard’s identifier and Developer ID team on incoming XPC messages; the guard verifies the helper’s requirement. The listener also checks the current console UID. One connection owns the lease. Renew and release run serially on the main queue, check connection identity, and take no arbitrary command/path/settings arguments.

The helper records `SleepDisabled`, including an originally absent key/container, in `/Library/Application Support/Guillotine/lid-session.plist` before modification. The folder is root-owned, not group/world-writable, and validated against symlinks. Atomic journal writes are fsynced with their directory. The sleep-control command is fixed `/usr/bin/pmset -a disablesleep 1/0`. Absence restoration uses the exact system preferences key and notification identified in Apple’s source, preserving the latest other dictionary entries. An already-disabled sleep policy is never acquired or cleared.

On release, disconnect, five awake seconds without renewal, disallowed battery operation, or console-user change, the helper restores its owned setting. Launchd KeepAlive restarts a killed helper; startup replays recovery before accepting a lease. Restoration is compare-and-restore: a changed value is preserved, and a changed policy ends the session rather than being repeatedly overwritten. Identical concurrent writes cannot be distinguished, and the preferences API has no atomic compare-and-swap across unrelated writers. Do not run competing global sleep-control utilities. The sleep-control path changes no other pmset setting. Optional battery Low Power Mode has its own journal and restoration, described below.

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

## Battery sleep and Low Power Mode

The guard reads internal battery capacity and maximum capacity through IOKit power-source descriptions, excluding UPS/accessory batteries. The percentage is compared without early integer rounding. IOKit notifications evaluate the sleep cutoff immediately, with the existing guard tick as a backstop. Invalid/missing capacities do not imply zero battery. A configured 1–100% sleep cutoff (10% default) restores controls and both owned helper settings before `IOPMSleepSystem`; disabling it sends a zero/off policy. macOS's own critical-battery and thermal behavior remains independent. Requests rejected by another sleep blocker are reported; the app never silently reactivates.

Low Power Mode is off by default, with an independent 20% threshold preset and a whole-battery-session option. The guard sends only booleans to the signed root helper: allow battery, block sleep for closed lid, and enable Low Power Mode. No caller supplies a setting name, command, or arbitrary percentage to the helper. The helper independently rejects enabling Low Power Mode on AC. Low Power Mode-only leases do not set SleepDisabled.

Following [Apple’s IOPMEnergyPrefs implementation](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMEnergyPrefs.c), the helper derives the `com.apple.PowerManagement.<gethostuuid>` CFPreferences domain and uses AnyUser/CurrentHost. Low Power Mode lives there, while SleepDisabled lives in the global domain. Effective readback uses CFPreferences; plist disk flushing can lag. Failure to determine the host domain prevents activation.

The helper changes only the battery profile's fixed `LowPowerMode` key using `pmset -b lowpowermode`. Its separate durable journal records the prior numeric value and key presence; restoration preserves unrelated profile keys, changed external values, and originally absent keys. Existing value 2 (High Power Mode) restores through fixed `pmset -b powermode 2`, on supporting hardware. A preexisting Low Power Mode setting is left unowned and preserved; an observed external opt-out ends the lease. Identical-value writes are indistinguishable. SIGTERM, EOF/XPC disconnect, five-second expiry, thermal cleanup, AC reconnection, and startup crash recovery restore owned settings. Low Power Mode may reduce heat and help avoid thermal constraints, but is not a replacement for macOS thermal protections.

Sources: [Apple power modes](https://support.apple.com/en-us/101613), [Apple pmset implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m), and SDK `IOPSKeys.h`.
