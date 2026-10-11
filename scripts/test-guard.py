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
        self.assertTrue(state['lidOwned'])
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
