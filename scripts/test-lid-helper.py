#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fake pmset only: lifecycle and compare-and-restore tests, never root writes."""
import pathlib, plistlib, subprocess, sys, tempfile, time, unittest
HELPER=str(pathlib.Path(sys.argv.pop(1)).resolve())
class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.folder=pathlib.Path(self.temp.name); self.children=[]
    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.stdin.close(); child.wait(timeout=10)
            for stream in (child.stdin,child.stdout):
                if not stream.closed: stream.close()
        self.temp.cleanup()
    def start(self):
        child=subprocess.Popen([HELPER,'--test-helper',str(self.folder)],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        self.children.append(child); self.assertEqual(child.stdout.readline().strip(),b'READY'); return child
    def send(self,child,text):
        child.stdin.write((text+'\n').encode()); child.stdin.flush(); return child.stdout.readline().decode()
    def value(self): return int((self.folder/'value').read_text()) if (self.folder/'value').exists() else 0
    def test_lease_records_original_and_disconnect_restores(self):
        child=self.start(); self.assertTrue(self.send(child,'renew').startswith('OK'))
        self.assertEqual(self.value(),1)
        self.assertEqual(plistlib.loads((self.folder/'lid-session.plist').read_bytes())['original'],0)
        child.stdin.close(); child.wait(timeout=3); self.assertEqual(self.value(),0)
        self.assertFalse((self.folder/'lid-session.plist').exists())
    def test_expiry_restores_without_new_lease(self):
        child=self.start(); self.send(child,'renew'); time.sleep(6.2)
        self.assertEqual(self.value(),0)
        self.assertTrue(self.send(child,'renew').startswith('NO'))
    def test_original_disabled_sleep_setting_is_preserved(self):
        (self.folder/'value').write_text('1'); child=self.start(); self.send(child,'renew'); self.send(child,'end')
        self.assertEqual(self.value(),1); self.assertFalse((self.folder/'lid-session.plist').exists())
    def test_external_setting_change_is_preserved(self):
        child=self.start(); self.send(child,'renew'); (self.folder/'value').write_text('0')
        self.assertTrue(self.send(child,'renew').startswith('NO')); self.assertEqual(self.value(),0)
        self.assertFalse((self.folder/'lid-session.plist').exists())
    def test_unplug_restores_when_battery_disallowed(self):
        child=self.start(); self.send(child,'renew'); (self.folder/'power').write_text('battery')
        time.sleep(1.2); self.assertEqual(self.value(),0)
    def test_battery_opt_in_and_thermal_emergency_restore(self):
        (self.folder/'power').write_text('battery'); child=self.start(); self.send(child,'renew battery=1')
        time.sleep(1.2); self.assertEqual(self.value(),1)
        (self.folder/'hot').touch(); time.sleep(1.2); self.assertEqual(self.value(),0)
        deadline=time.monotonic()+6
        while not (self.folder/'sleep-request').exists() and time.monotonic()<deadline: time.sleep(0.1)
        self.assertTrue((self.folder/'sleep-request').exists())
    def test_daemon_crash_recovery(self):
        child=self.start(); self.send(child,'renew'); child.kill(); child.wait(timeout=2)
        self.assertEqual(self.value(),1)
        recovered=self.start(); self.assertEqual(self.value(),0)
        self.assertFalse((self.folder/'lid-session.plist').exists())
    def test_absent_key_recovery_during_restoration(self):
        (self.folder/'value').write_text('0')
        (self.folder/'lid-session.plist').write_bytes(plistlib.dumps({'original':0, 'written':1, 'originalPresent':False, 'containerPresent':False, 'restoring':True}))
        self.start()
        self.assertFalse((self.folder/'value').exists())
        self.assertFalse((self.folder/'lid-session.plist').exists())
    def test_signal_cleanup(self):
        child=self.start(); self.send(child,'renew'); child.terminate(); child.wait(timeout=3)
        self.assertEqual(self.value(),0)
if __name__=='__main__': unittest.main()
