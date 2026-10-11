# Revised hardware-control verification — 2026-10-10

Host: MacBookPro18,1 (Apple Silicon), macOS 27.0.1 (26A434), Xcode 27 beta. Minimum macOS and Intel runtime checks are outstanding; Intel panel control intentionally reports unsupported.

## Actually run

- 15 XCTest tests passed after replacing the sleep assertion with an injected physical-control interface. Covers start restored, activation on battery/UPS/unknown power, power transitions preserving the active mode, informational power refresh, repeated ownership cycles, release failure/retry, shortcut validation/exclusivity/replacement and Carbon callback-to-restore.
- Seven fake-hardware guard integration tests passed, covering: anonymous-pipe disconnect, five-second lease expiry, heartbeat renewal, SIGTERM cleanup, SIGKILL journal recovery on next launch, duplicate-guard exclusion and the remote restore command. No physical power controls were invoked by these tests.
- Read-only hardware probe found the built-in `disp0,t600x` framebuffer, keyboard ID and API symbols/selectors.
- A timed one-second panel-off pulse with a separate three-second power-on fallback returned success. **The user confirmed the physical screen turned off and came back.** CoreGraphics continued reporting one active logical display.
- Keyboard pulse: original 0.001, zero write succeeded, zero readback verified, original value restored. Auto-brightness remained enabled.
- Real guard end-to-end: READY, keyboard zero readback, then closing its lease yielded exit 0 and removed the recovery journal. Keyboard original 0.001 and unchanged auto-brightness were verified after release. Caffeine continued holding its own display assertion. Neither Guillotine nor its guard held any sleep assertion.
- Universal Release app and guard built and Developer ID signatures verified. Installed build 4 starts OFF, shows battery power, the non-Fn default shortcut, optional Fn and sleep/wake restore settings. Existing launch-at-login choice was preserved. Battery activation was exercised through the installed app: Settings changed to ON on battery, then the independent restore command returned it to OFF with “Physical controls restored by hardware guard.” This verifies application/guard integration; physical darkness was not separately confirmed by the user in this cycle.
- Earlier sleep-prevention tests and UTM results are archived in [HISTORICAL-TESTS.md](HISTORICAL-TESTS.md); they do not certify the revised physical-control implementation. A VM has no physical MacBook panel/backlight and cannot certify them.

## Manual acceptance still needed

| Test | Expected result |
| --- | --- |
| Cut/restore on AC and battery | Actual physical panel and keyboard backlight go off immediately; menu/Settings owns the session; restore shortcut brings both back. Repeat 20 times. |
| Independent Caffeine | Leave Caffeine active, cut the lights, verify physical darkness and continuing remote frames. Caffeine state/assertions must remain unchanged. |
| Keyboard activity/ambient light | With mode active, type locally/remotely and vary lighting. Guard reapplies zero within one second, leaving auto-brightness preference unchanged. Restore latest user/OS value when disabled. |
| Lock screen | Establish Vibepollo/Moonlight, cut the lights, lock normally. Physical controls and active status remain off/active. Verify progressing remote lock-screen frames and authentication. Try Control–Option–Command–Space both locally and remotely. **Delivery is not yet certified**; do not assume Fn is forwarded. |
| Sleep/wake default | Sleep normally while headless, wake through ordinary means. Active mode persists; remote sessions resume per their own behavior. Panel/backlight may briefly wake before the guard reapplies off. Neither app nor guard prevents system sleep. |
| Optional restore behavior | Enable each restore preference separately, start a new session, then sleep/wake. Guard restores and app becomes inactive only for the selected transition. Lock remains independent. |
| Power loss | Unplug while active, including locked/closed lid. Mode remains active across unplug/replug; power status updates. Normal macOS sleep behavior applies. |
| App crash/hang | With guard active, SIGKILL only the exact app PID: pipe EOF restores. Suspend the app: lease expiry restores within approximately five awake seconds. No sleep settings change. |
| Guard crash | Kill only the exact guard PID. App detects exit and recovers the journal. Also kill both, then relaunch: recovery should restore. Never remove a pending journal first. |
| User keyboard changes | Change backlight brightness during a session. Guard journals that new nonzero value before reapplying zero. On restore, preserve a current nonzero user value. |
| Lid close | Test separately with native clamshell requirements. Guillotine does not prevent lid-close sleep or create a monitor. |
| Streaming | Exact Vibepollo and Sunshine/Moonlight builds, Screen Sharing: changing clock/video, input, lock/unlock, display-off, sleep/wake, reconnect and restoration. Check progressing frames, not a stale connected image. |
| Quit/reboot/login | Quit restores; login/reboot starts restored even when launch at login is enabled. Existing stream/network processes are untouched. |

No end-to-end remote capture, lock-screen shortcut, real sleep/wake or physical power-transition result is implied by the automated tests. Private APIs require revalidation after macOS updates.
