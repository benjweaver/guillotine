# Changelog

All notable changes will be documented here using Keep a Changelog.

## Unreleased

### Changed

- Make the restore shortcut and explicit restore command request panel power-on even when no hardware session journal remains. Startup recovery still touches only owned changes.

- Dismiss the status menu explicitly on clicks in another app or the Settings window; remove event monitors when the menu closes.

- Replace the failed experimental clamshell bit with an optional approved root helper that leases the global sleep-disable control.
- Explain that closed-lid support also blocks ordinary/manual sleep while active.
- Show helper actions only when appropriate to installation/approval state.
- Preserve battery opt-in, physical screen/backlight controls, restore shortcut, and normal lock behavior.

### Added

- Optional automatic battery sleep at an editable percentage (10% by default), with restoration before sleep and a complete opt-out.
- Optional battery Low Power Mode whenever on battery or below an editable percentage (20% preset), leased through the power helper with exact prior-setting recovery.
- A note that Low Power Mode may reduce heat and help avoid thermal limits.

- Optional menu checkbox to mute built-in speakers while headless, with live toggling, durable restoration, and no changes to streaming audio outputs.

- Root-owned recovery journal, signed XPC peer checks, five-second helper lease, and independent power/thermal cleanup.
- Helper installation/removal controls and lifecycle tests, including daemon crash recovery.
- Compiler warnings as errors and release-Xcode verification.
