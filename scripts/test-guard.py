#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Guard lifecycle tests use fake hardware only. Pass the built Guard executable."""
import plistlib
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

GUARD = str(pathlib.Path(sys.argv.pop(1)).resolve())

class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = pathlib.Path(self.temp.name)
        self.children = []
    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.stdin.close()
                child.wait(timeout=10)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream and not stream.closed:
                    stream.close()
        self.temp.cleanup()
    def start(self, *arguments):
        child = subprocess.Popen([GUARD, '--test-guard', *arguments, str(self.folder)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.children.append(child)
        return child
    def ready(self, child):
        self.assertEqual(child.stdout.readline().strip(), b'READY')
        self.assertTrue((self.folder / 'hardware-session.plist').exists())
    def restored(self, child):
        self.assertEqual(child.wait(timeout=10), 0)
        self.assertFalse((self.folder / 'hardware-session.plist').exists())
    def mute(self):
        return (self.folder / 'test-mute').read_text()
    def set_mute(self, value):
        (self.folder / 'test-mute').write_text(str(value))
    def policy(self, child, enabled):
        child.stdin.write(f'renew mute={int(enabled)}\n'.encode()); child.stdin.flush()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if self.mute() == str(int(enabled)):
                return
            time.sleep(.02)
        self.fail('Audio policy did not apply')
    def test_default_session_owns_and_restores_panel(self):
        child = self.start(); self.ready(child)
        state = plistlib.loads((self.folder / 'hardware-session.plist').read_bytes())
        self.assertTrue(state['panelOwned'])
        child.stdin.close(); self.restored(child)
        self.assertEqual((self.folder / 'test-panel-requests').read_text(), '0\n1\n')
        self.assertFalse((self.folder / 'test-helper-policy.plist').exists())
    def test_keyboard_only_trial_journal_does_not_restore_unowned_panel(self):
        (self.folder / 'hardware-session.plist').write_bytes(
            plistlib.dumps({'panelOwned': False, 'keyboards': {'1': 0.5}}))
        recovered = self.start('--recover')
        self.assertEqual(recovered.stdout.readline().strip(), b'RECOVERED')
        self.restored(recovered)
        self.assertFalse((self.folder / 'test-panel-requests').exists())
    def test_panel_requests_only_at_activation_and_restoration(self):
        for ending in ('disconnect', 'signal', 'expiry'):
            with self.subTest(ending=ending):
                requests = self.folder / 'test-panel-requests'
                requests.unlink(missing_ok=True)
                child = self.start(); self.ready(child)
                for _ in range(3):
                    child.stdin.write(b'renew\n'); child.stdin.flush()
                    time.sleep(1.1)
                self.assertEqual(requests.read_text(), '0\n')
                if ending == 'disconnect':
                    child.stdin.close()
                elif ending == 'signal':
                    child.terminate()
                self.restored(child)
                self.assertEqual(requests.read_text(), '0\n1\n')
    def test_panel_is_restored_after_crash(self):
        child = self.start(); self.ready(child)
        self.assertEqual((self.folder / 'test-panel-requests').read_text(), '0\n')
        child.kill(); child.wait(timeout=2)
        # Recovery uses journal ownership to restore panel power.
        recovered = self.start('--recover')
        self.assertEqual(recovered.stdout.readline().strip(), b'RECOVERED')
        self.restored(recovered)
        self.assertEqual((self.folder / 'test-panel-requests').read_text(), '0\n1\n')
    def hold_lease(self, child, seconds):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            child.stdin.write(b'renew\n'); child.stdin.flush()
            time.sleep(.1)
    def panel_requests(self):
        return (self.folder / 'test-panel-requests').read_text()
    def wait_panel_requests(self, child, expected):
        until = time.monotonic() + 5
        while time.monotonic() < until:
            if self.panel_requests() == expected:
                return
            self.hold_lease(child, .1)
        self.assertEqual(self.panel_requests(), expected)
    def test_remote_display_removal_reapplies_once_then_stays_idle(self):
        configuration = self.folder / 'test-display-configuration'
        configuration.write_text('built-in + virtual')
        child = self.start(); self.ready(child)
        configuration.write_text('built-in only')
        self.wait_panel_requests(child, '0\n0\n')
        # Duplicate callbacks for the same logical layout must not retrigger.
        configuration.write_text('built-in only')
        self.hold_lease(child, 3.2)
        self.assertEqual(self.panel_requests(), '0\n0\n')
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.panel_requests(), '0\n0\n1\n')
    def test_activation_creates_an_anchor_display_when_the_builtin_is_the_only_display(self):
        (self.folder / 'test-no-other-display').touch()
        child = self.start(); self.ready(child)
        self.assertTrue((self.folder / 'test-anchor-created').exists())
        self.assertEqual(self.panel_requests(), '0\n')
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.panel_requests(), '0\n1\n')
    def test_activation_refuses_without_changing_the_panel_when_the_anchor_cannot_be_created(self):
        (self.folder / 'test-no-other-display').touch()
        (self.folder / 'test-anchor-fails').touch()
        child = self.start()
        self.assertTrue(child.stdout.readline().startswith(b'ERROR Could not create the display'))
        child.wait(timeout=10)
        # Only the restoring power-on; the panel is never powered off.
        self.assertEqual(self.panel_requests(), '1\n')
    def test_disconnect_creates_anchor_and_keeps_panel_off(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-no-other-display').touch()
        (self.folder / 'test-display-configuration').write_text('stream disconnected')
        self.wait_panel_requests(child, '0\n0\n')
        self.assertTrue((self.folder / 'test-anchor-created').exists())
        # A later loss must refresh an existing anchor too.
        (self.folder / 'test-no-other-display').touch()
        self.enable_panel_event(child, 'anchor lost')
        self.wait_panel_requests(child, '0\n0\n0\n')
        child.stdin.close(); self.restored(child)
    def test_panel_is_left_on_when_anchor_fails_then_off_when_display_returns(self):
        configuration = self.folder / 'test-display-configuration'
        configuration.write_text('built-in + virtual')
        child = self.start(); self.ready(child)
        (self.folder / 'test-anchor-fails').touch()
        (self.folder / 'test-no-other-display').touch()
        configuration.write_text('built-in only')
        self.wait_panel_requests(child, '0\n1\n')
        # A built-in enable edge with no other display must not power it off either.
        self.enable_panel_event(child, 'built-in enabled, only display')
        self.wait_panel_requests(child, '0\n1\n1\n')
        (self.folder / 'test-no-other-display').unlink()
        configuration.write_text('built-in + virtual again')
        self.wait_panel_requests(child, '0\n1\n1\n0\n')
        child.stdin.close(); self.restored(child)
    def enable_panel_event(self, child, configuration):
        (self.folder / 'test-display-configuration').write_text(configuration)
        child.stdin.write(b'test-panel-enabled\n'); child.stdin.flush()
    def test_builtin_enable_bypasses_settling_and_cooldown_without_repeats(self):
        child = self.start(); self.ready(child)
        started = time.monotonic()
        self.enable_panel_event(child, 'built-in enabled')
        self.wait_panel_requests(child, '0\n0\n')
        self.assertLess(time.monotonic() - started, .75)
        # A duplicate enable callback is not a new transition.
        self.enable_panel_event(child, 'built-in enabled')
        self.hold_lease(child, 3.2)
        self.assertEqual(self.panel_requests(), '0\n0\n')
    def test_builtin_enable_cancels_pending_settled_write(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-display-wake').touch()
        self.hold_lease(child, 1.2)
        self.enable_panel_event(child, 'built-in enabled after wake')
        self.wait_panel_requests(child, '0\n0\n')
        self.hold_lease(child, 3.2)
        self.assertEqual(self.panel_requests(), '0\n0\n')
    def test_virtual_callback_first_does_not_delay_builtin_enable(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-display-configuration').write_text('built-in enabled, virtual removed')
        started = time.monotonic()
        child.stdin.write(b'test-display-changed\ntest-panel-enabled\n'); child.stdin.flush()
        self.wait_panel_requests(child, '0\n0\n')
        self.assertLess(time.monotonic() - started, .75)
        self.hold_lease(child, 3.2)
        self.assertEqual(self.panel_requests(), '0\n0\n')
    def test_builtin_enable_respects_lid_and_sleep_suppression(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-lid').write_text('closed')
        self.enable_panel_event(child, 'built-in enabled with lid shut')
        self.hold_lease(child, 1.2)
        self.assertEqual(self.panel_requests(), '0\n')
        (self.folder / 'test-system-notification').write_text('sleep')
        self.hold_lease(child, 1.2)
        (self.folder / 'test-lid').write_text('open')
        self.enable_panel_event(child, 'built-in enabled during sleep')
        self.hold_lease(child, 1.2)
        self.assertEqual(self.panel_requests(), '0\n')
    def test_display_change_burst_coalesces_into_one_request(self):
        child = self.start(); self.ready(child)
        configuration = self.folder / 'test-display-configuration'
        configuration.write_text('virtual removed')
        self.hold_lease(child, 1.2)
        configuration.write_text('built-in made main')
        self.wait_panel_requests(child, '0\n0\n')
        self.hold_lease(child, 2.2)
        self.assertEqual(self.panel_requests(), '0\n0\n')
    def test_display_wake_reapplies_without_a_layout_change(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-display-wake').touch()
        self.wait_panel_requests(child, '0\n0\n')
        self.hold_lease(child, 3.2)
        self.assertEqual(self.panel_requests(), '0\n0\n')
    def test_lid_closed_or_unknown_suppresses_pending_panel_write(self):
        for lid in ('closed', 'unknown'):
            with self.subTest(lid=lid):
                (self.folder / 'test-panel-requests').unlink(missing_ok=True)
                child = self.start(); self.ready(child)
                (self.folder / 'test-display-wake').touch()
                self.hold_lease(child, 1.2)
                (self.folder / 'test-lid').write_text(lid)
                self.hold_lease(child, 2.2)
                self.assertEqual(self.panel_requests(), '0\n')
                child.stdin.close(); self.restored(child)
    def test_disconnect_cancels_pending_display_reapply(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-display-wake').touch()
        self.hold_lease(child, 1.2)
        child.stdin.close(); self.restored(child)
        time.sleep(2)
        self.assertEqual(self.panel_requests(), '0\n1\n')
    def test_system_sleep_cancels_reapply_and_wake_schedules_one(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-display-wake').touch()
        (self.folder / 'test-system-notification').write_text('sleep')
        self.hold_lease(child, 3.2)
        self.assertEqual(self.panel_requests(), '0\n')
        (self.folder / 'test-system-notification').write_text('wake')
        self.wait_panel_requests(child, '0\n0\n')
    def test_restore_on_system_wake_takes_precedence_over_panel_reapply(self):
        child = self.start('--restore-on-wake'); self.ready(child)
        (self.folder / 'test-system-notification').write_text('wake')
        self.restored(child)
        self.assertEqual(self.panel_requests(), '0\n1\n')
    def test_speakers_unchanged_when_option_off(self):
        self.set_mute(0)
        child = self.start(); self.ready(child)
        self.assertEqual(self.mute(), '0')
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.mute(), '0')
    def test_speaker_mute_restores_on_disconnect(self):
        self.set_mute(0)
        child = self.start('--mute-speakers'); self.ready(child)
        self.assertEqual(self.mute(), '1')
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.mute(), '0')
    def test_preexisting_mute_is_preserved(self):
        self.set_mute(1)
        child = self.start('--mute-speakers'); self.ready(child)
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.mute(), '1')
    def test_live_audio_policy_and_repeated_toggles(self):
        self.set_mute(0)
        child = self.start(); self.ready(child)
        for _ in range(5):
            self.policy(child, True)
            self.policy(child, False)
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.mute(), '0')
    def test_crashed_audio_guard_recovers_by_uid(self):
        self.set_mute(0)
        child = self.start('--mute-speakers'); self.ready(child)
        child.kill(); child.wait(timeout=2)
        self.assertEqual(self.mute(), '1')
        recovered = self.start('--recover')
        self.assertEqual(recovered.stdout.readline().strip(), b'RECOVERED')
        self.restored(recovered)
        self.assertEqual(self.mute(), '0')
    def test_unplug_restores_speakers(self):
        self.set_mute(0)
        child = self.start('--mute-speakers'); self.ready(child)
        (self.folder / 'test-power').write_text('battery')
        self.restored(child)
        self.assertEqual(self.mute(), '0')
    def test_thermal_cutout_restores_speakers(self):
        self.set_mute(0)
        child = self.start('--mute-speakers', '--allow-battery'); self.ready(child)
        (self.folder / 'test-power').write_text('battery')
        (self.folder / 'test-hot').touch()
        self.restored(child)
        self.assertEqual(self.mute(), '0')
        self.assertTrue((self.folder / 'test-sleep-request').exists())
    def test_external_unmute_is_preserved_on_exit(self):
        self.set_mute(0)
        child = self.start('--mute-speakers'); self.ready(child)
        self.set_mute(0)
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.mute(), '0')
    def test_audio_lease_expiry_restores(self):
        self.set_mute(0)
        child = self.start('--mute-speakers'); self.ready(child)
        self.restored(child)
        self.assertEqual(self.mute(), '0')
    def test_fragmented_and_coalesced_audio_policy(self):
        self.set_mute(0)
        child = self.start(); self.ready(child)
        child.stdin.write(b'renew mu'); child.stdin.flush()
        time.sleep(.05)
        child.stdin.write(b'te=1\nrenew mute=0\nrenew mute=1\n'); child.stdin.flush()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and self.mute() != '1':
            time.sleep(.02)
        self.assertEqual(self.mute(), '1')
        child.stdin.close(); self.restored(child)
        self.assertEqual(self.mute(), '0')
    def percentage(self, value):
        (self.folder / 'test-percentage').write_text(str(value))
    def test_default_battery_cutoff_is_inclusive(self):
        self.percentage(11)
        (self.folder / 'test-power').write_text('battery')
        self.set_mute(0)
        child = self.start('--allow-battery', '--closed-lid', '--mute-speakers'); self.ready(child)
        self.percentage(10)
        self.restored(child)
        self.assertEqual(self.mute(), '0')
        self.assertTrue((self.folder / 'test-sleep-request').exists())
        policy = plistlib.loads((self.folder / 'test-helper-policy.plist').read_bytes())
        self.assertTrue(policy['released'])
    def test_custom_sleep_percentage(self):
        self.percentage(38)
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery', '--sleep-below', '37'); self.ready(child)
        self.percentage(37)
        self.restored(child)
        self.assertTrue((self.folder / 'test-sleep-request').exists())
    def test_sleep_cutoff_can_be_disabled(self):
        self.percentage(1)
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery', '--sleep-below', '0'); self.ready(child)
        time.sleep(1.2); self.assertIsNone(child.poll())
        child.stdin.close(); self.restored(child)
        self.assertFalse((self.folder / 'test-sleep-request').exists())
    def test_cutoff_does_not_apply_on_external_power(self):
        self.percentage(1)
        child = self.start(); self.ready(child)
        time.sleep(1.2); self.assertIsNone(child.poll())
        child.stdin.close(); self.restored(child)
        self.assertFalse((self.folder / 'test-sleep-request').exists())
    def test_unknown_and_invalid_percentages_do_not_request_sleep(self):
        for value in ('missing', '-1', '101', 'nan', 'bad'):
            with self.subTest(value=value):
                self.percentage(value)
                (self.folder / 'test-power').write_text('battery')
                child = self.start('--allow-battery'); self.ready(child)
                time.sleep(.05); self.assertIsNone(child.poll())
                child.stdin.close(); self.restored(child)
                self.assertFalse((self.folder / 'test-sleep-request').exists())
    def test_fractional_percentage_does_not_sleep_early(self):
        self.percentage('10.5')
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery'); self.ready(child)
        time.sleep(1.2); self.assertIsNone(child.poll())
        child.stdin.close(); self.restored(child)
    def test_live_sleep_policy_requests_cutoff(self):
        self.percentage(40)
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery'); self.ready(child)
        child.stdin.write(b'renew sleep=40\n'); child.stdin.flush()
        self.restored(child)
        self.assertTrue((self.folder / 'test-sleep-request').exists())
    def test_live_sleep_disable_prevents_cutoff(self):
        self.percentage(11)
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery'); self.ready(child)
        child.stdin.write(b'renew sleep=0\n'); child.stdin.flush()
        time.sleep(.05); self.percentage(1)
        time.sleep(1.2); self.assertIsNone(child.poll())
        child.stdin.close(); self.restored(child)
        self.assertFalse((self.folder / 'test-sleep-request').exists())
    def test_invalid_policy_percentages_are_rejected(self):
        for option in ('--sleep-below', '--low-power-below'):
            child = self.start(option, '101')
            self.assertTrue(child.stdout.readline().startswith(b'ERROR Battery percentages'))
            self.assertEqual(child.wait(timeout=2), 2)
    def helper_policy(self):
        return plistlib.loads((self.folder / 'test-helper-policy.plist').read_bytes())
    def wait_low_power(self, expected):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if self.helper_policy()['lowPowerMode'] == expected:
                return
            time.sleep(.02)
        self.fail('Low Power Mode threshold did not apply')
    def test_low_power_threshold_and_external_power_restore(self):
        self.percentage(21)
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery', '--low-power-below', '20'); self.ready(child)
        self.assertFalse(self.helper_policy()['lowPowerMode'])
        self.assertFalse(self.helper_policy()['closedLid'])
        self.percentage(20); self.wait_low_power(True)
        (self.folder / 'test-power').write_text('ac'); self.wait_low_power(False)
        child.stdin.close(); self.restored(child)
    def test_low_power_whenever_battery_and_live_opt_out(self):
        self.percentage(99)
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery', '--low-power-below', '100'); self.ready(child)
        self.assertTrue(self.helper_policy()['lowPowerMode'])
        child.stdin.write(b'renew lowpower=0\n'); child.stdin.flush()
        self.wait_low_power(False)
        child.stdin.close(); self.restored(child)
    def test_battery_requires_opt_in(self):
        (self.folder / 'test-power').write_text('battery')
        child = self.start()
        self.assertTrue(child.stdout.readline().startswith(b'ERROR Battery'))
        self.assertEqual(child.wait(timeout=2), 2)
        self.assertFalse((self.folder / 'hardware-session.plist').exists())
    def test_unplug_restores_without_battery_opt_in(self):
        child = self.start(); self.ready(child)
        (self.folder / 'test-power').write_text('battery')
        self.restored(child)
    def test_allowed_battery_stays_active_until_thermal_cutout(self):
        child = self.start('--allow-battery', '--closed-lid'); self.ready(child)
        (self.folder / 'test-power').write_text('battery')
        child.stdin.write(b'renew battery=1\n'); child.stdin.flush()
        time.sleep(1.2); self.assertIsNone(child.poll())
        (self.folder / 'test-hot').touch()
        self.restored(child)
        self.assertTrue((self.folder / 'test-sleep-request').exists())
    def test_thermal_on_ac_does_not_request_sleep(self):
        child = self.start('--closed-lid'); self.ready(child)
        (self.folder / 'test-hot').touch()
        time.sleep(1.2); self.assertIsNone(child.poll())
        child.stdin.close(); self.restored(child)
        self.assertFalse((self.folder / 'test-sleep-request').exists())
    def test_disabling_battery_policy_restores_active_guard(self):
        (self.folder / 'test-power').write_text('battery')
        child = self.start('--allow-battery'); self.ready(child)
        child.stdin.write(b'renew battery=0\n'); child.stdin.flush()
        self.restored(child)
    def test_closed_lid_ownership_is_journaled_and_recovered(self):
        import plistlib
        child = self.start('--closed-lid'); self.ready(child)
        state = plistlib.loads((self.folder / 'hardware-session.plist').read_bytes())
        self.assertTrue(state['lidService'])
        child.kill(); child.wait(timeout=2)
        recovered = self.start('--recover')
        self.assertEqual(recovered.stdout.readline().strip(), b'RECOVERED')
        self.restored(recovered)
    def test_app_disconnect_restores(self):
        child = self.start(); self.ready(child)
        child.stdin.close(); self.restored(child)
    def test_expired_lease_restores(self):
        child = self.start(); self.ready(child)
        self.restored(child)
    def test_renewal_keeps_lease_then_disconnect_restores(self):
        child = self.start(); self.ready(child)
        for _ in range(6):
            child.stdin.write(b'renew\n'); child.stdin.flush()
            time.sleep(1)
        self.assertIsNone(child.poll())
        child.stdin.close(); self.restored(child)
    def test_guard_signal_restores(self):
        child = self.start(); self.ready(child)
        child.terminate(); self.restored(child)
    def test_guard_crash_is_recovered_next_launch(self):
        child = self.start(); self.ready(child)
        child.kill(); child.wait(timeout=2)
        self.assertTrue((self.folder / 'hardware-session.plist').exists())
        recovered = self.start('--recover')
        self.assertEqual(recovered.stdout.readline().strip(), b'RECOVERED')
        self.restored(recovered)
    def test_explicit_restore_powers_panel_on_without_a_journal(self):
        child = self.start('--restore')
        self.assertEqual(child.stdout.readline().strip(), b'RECOVERED')
        self.restored(child)
        self.assertTrue((self.folder / 'test-panel-on').exists())
    def test_startup_recovery_does_not_power_an_unowned_panel(self):
        child = self.start('--recover')
        self.assertEqual(child.stdout.readline().strip(), b'RECOVERED')
        self.restored(child)
        self.assertFalse((self.folder / 'test-panel-on').exists())
    def test_remote_restore_command(self):
        first = self.start(); self.ready(first)
        request = self.start('--restore')
        self.assertEqual(request.stdout.readline().strip(), b'RESTORE REQUESTED')
        self.assertEqual(request.wait(timeout=2), 0)
        self.restored(first)
    def test_second_guard_cannot_take_ownership(self):
        first = self.start(); self.ready(first)
        second = self.start()
        self.assertTrue(second.stdout.readline().startswith(b'ERROR Another'))
        self.assertEqual(second.wait(timeout=2), 2)
        self.assertTrue((self.folder / 'hardware-session.plist').exists())
        first.stdin.close(); self.restored(first)

unittest.main()
