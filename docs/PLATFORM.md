# Physical controls and independent sleep policy

The revised app's scope is physical panel and keyboard backlight power. There are no IOKit sleep assertions, `pmset` commands, brightness changes for the panel, virtual displays, layout changes or persistent sleep settings in the app. An optional private lid-close override is described below.

## Panel

[Clamless upstream](https://github.com/TCXM/clamless/blob/main/src/helper/clamless-display.c) documents two separate layers: SkyLight layout disconnection and IOMobileFramebuffer panel power. Guillotine uses only the latter: runtime-resolved `IOMobileFramebufferOpen` and `IOMobileFramebufferRequestPowerChange(framebuffer, 0/1)` on the built-in `disp0,` service. It never invokes SkyLight or disconnects the logical display.

On the test Mac, power-off returned success and the user confirmed the physical panel went dark. CoreGraphics still reported one active logical display. The IOPowerManagement registry's CurrentPowerState remained 1, so that field is **not** used as proof the physical panel is lit or dark. This is not an electrical power-consumption measurement, nor a general guarantee for every Mac/OS. No public supported per-panel power API is established by this investigation. Private API availability is checked at runtime and hardware writes fail closed.

## Keyboard

[macos-keyboard-backlight upstream](https://github.com/noluyorAbi/macos-keyboard-backlight/blob/main/src/index.js) documents `KeyboardBrightnessClient`, `copyKeyboardBacklightIDs`, `brightnessForKeyboard:` and `setBrightness:forKeyboard:` in private CoreBrightness. Guillotine uses runtime class/selector checks and validates zero readback. No API is invented and auto-brightness is untouched. Original/latest nonzero values are fsynced before modification and restored conditionally. The test Mac read zero while controlled and its original 0.001 after release.

## Caffeine, capture and lock screen

Logical display availability differs from physical panel power. Because Guillotine retains the framebuffer, this approach does not need a dummy plug for lid-open use. It leaves Caffeine and other sleep assertions alone; Caffeine's display assertion remained active during the hardware test. Actual Sunshine/Moonlight, Vibepollo and Screen Sharing frame progression still needs a second-device acceptance test. System sleep still suspends capture and networking normally.

The user's local Vibepollo source was inspected at `src/platform/macos/input.cpp`: keyboard events are posted via `CGEventPost(kCGSessionEventTap, event)`, with Control/Option/Command/Shift mappings but no Fn flag mapping. `misc.mm` checks Accessibility permission for event injection. Its `display.mm` independently holds PreventUserIdleDisplaySleep while streaming. This supports a remote-friendly non-Fn default; it does not prove a Carbon hotkey is dispatched to Guillotine while loginwindow or Secure Input owns keyboard input. No lock-screen bypass or blanket lock-screen compatibility claim is made.

No lock notification changes active status. Sleep/wake restoration is optional, off by default. The helper observes workspace sleep/wake events solely to honor that preference and avoid treating normal sleep as a crashed parent. It reapplies hardware-off requests every second while leased, allowing sleep and streaming policies to remain external.

## Limits and safety

Apple Silicon built-in panels only. No Intel dimming substitute and no unverified external-monitor DDC support. These private APIs can fail after an OS update. No administrator privileges, SIP changes, input interception, Accessibility access or Screen Recording are requested by Guillotine. Streaming hosts have their own permissions.

Crash restoration relies on a separate user process and short lease. If both app and guard are forcibly killed, restoration occurs on next launch via the durable journal; macOS restart is the final recovery path if APIs fail. There is no per-client CAS ownership token for panel power, so simultaneous utilities requesting panel power cannot be perfectly distinguished. Guillotine never rewrites persistent display layouts or power-management settings.

## Experimental closed-lid control

Apple's [RootDomainUserClient source](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp) exposes selector `kPMSetClamshellSleepState` (12), which sets a shared powerd lid-sleep-disable bit. [IOPMrootDomain](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp) consults that bit separately from idle-sleep assertions. Guillotine's unprivileged guard invokes it only with the optional closed-lid preference. It does not add an idle/display assertion or change `pmset disablesleep`.

If `AppleClamshellCausesSleep` reports a sleep-causing policy, the guard fsyncs `lidOwned` before requesting disable. Cleanup clears the bit only for that recorded ownership, after restoring the panel and keyboard. If the current policy already allows lid close, the guard leaves it alone. Crash recovery replays the owned release. The API's success result is **not** proof of no-monitor closed-lid operation. Upstream [claude-keep-awake](https://github.com/AxGord/claude-keep-awake) reports success with this control, whereas [adrafinil's hardware experiments](https://github.com/kageroumado/adrafinil/blob/main/Docs/ARCHITECTURE.md) report needing privileged `pmset disablesleep`. Physical testing is mandatory; no privileged fallback is installed in this build.

This is a shared private kernel bit, not a process-owned assertion or per-client token. The registry property does not expose every contributor and can lag policy evaluation. Concurrent utilities changing the same bit cannot be perfectly distinguished. Do not run competing lid-override utilities during validation. The optional control remains experimental rather than promising safe universal ownership. A simultaneous kill of both app and guard requires next-launch journal recovery. A virtual display/adapter may still be needed for capturable frames after physical lid closure; Guillotine does not create or remove one.

## Battery and thermal safety

**Allow on battery** defaults off and takes effect immediately. The app rechecks power before and after activation. Independent guard IOKit notifications restore on unplug when battery use is disallowed, including if the parent is hung. Plug-in never re-enables. Unknown/UPS power is treated as limited power, not AC.

On limited power, `NSProcessInfo.thermalState >= serious` triggers restoration before `IOPMSleepSystem`, a public console-user/root sleep-request API. Thermal notifications plus the one-second guard check cover pressure changes and hot unplugging. On AC no thermal sleep request is made. [Apple's serious state documentation](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious) describes high thermal pressure; no supported cross-model Celsius sensor API is claimed. The app cannot promise a physical sleep transition merely from an accepted request, especially with another utility enforcing its own sleep override. The guard records the outcome in `last-stop.txt`; reactivation remains manual. No heat-generation test or actual thermal sleep has been performed.
