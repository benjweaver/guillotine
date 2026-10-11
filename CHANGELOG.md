# Changelog

All notable changes are documented here using Keep a Changelog.

## Unreleased

## [1.0.1] - 2026-10-11

### Fixed

- Request panel power-off once at activation, then power-on at restoration. Periodic guard ticks and lease renewals no longer send panel-power requests or compete with lid-open and wake transitions.
- Preserve recovery of recorded panel ownership, including keyboard-only journals from local test builds.

### Changed

- Mark closed-lid sleep prevention as experimental, WIP, and not yet reliable in Settings, menu status, and setup guidance. Recommend leaving the lid open; the WindowServer failure's trigger remains unresolved.
- Reset the legacy closed-lid sleep block to off once on upgrade; later explicit choices persist. Sleep prevention remains independent of panel control.

### Added

- Homebrew cask installation through `benjweaver/guillotine/guillotine`, with verified release checksums and tap updates from the release script.

## [1.0.0] - 2026-10-10

### Added

- Native macOS menu bar controls to turn off the built-in Apple Silicon panel and keyboard backlight while retaining the logical display for remote access.
- Configurable global restore shortcut, defaulting to Control–Option–Command–Space, and an explicit panel rescue when already disabled.
- Optional closed-lid operation through a signed, privileged helper with five-second leases, recovery journals, and restoration after disconnect or failure.
- Opt-in battery operation, restoration when disallowed power disconnects, and thermal-pressure sleep protection on battery.
- Optional sleep at a user-selected battery percentage, defaulting to 10%, with a complete opt-out.
- Optional Low Power Mode throughout battery operation or at a user-selected percentage (20% preset), with restoration of the prior battery setting.
- Optional built-in speaker mute while headless, preserving virtual and external audio outputs.
- Optional launch at login, disabled startup, and independent sleep/wake restoration preferences. Locking does not change headless status.
- Matching app, menu bar, and Settings artwork; GPL-3.0-only source and a complete universal Xcode project.
- A local release script with automated tests, Developer ID signing, Apple notarization, and private GitHub release assets.

### Known limitations

- Physical panel and keyboard controls use private macOS APIs and require revalidation after OS updates. Intel binaries are included, but physical panel control is unsupported there.
- Closed-lid support blocks ordinary and manual system sleep while active. Capturable displays and uninterrupted streams depend on the remote host and display setup; Guillotine does not hide lid state or create a virtual display.
- Lock-screen shortcut delivery, actual battery-percentage sleep, minimum macOS 13 runtime behavior, and Intel hardware remain unverified. See docs/TESTING.md for the full test record.
