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
