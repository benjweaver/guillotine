# Physical controls and independent sleep policy

The revised app's scope is physical panel and keyboard backlight power. There are no IOKit sleep assertions, `pmset` commands, brightness changes for the panel, virtual displays, layout changes or lid-close overrides in the app.

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
