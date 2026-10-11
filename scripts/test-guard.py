#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Guard lifecycle tests use fake hardware only. Pass the built Guard executable."""
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
