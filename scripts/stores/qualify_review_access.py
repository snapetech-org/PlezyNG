#!/usr/bin/env python3
"""Exercise the actual signed Play APK's reviewer grant on a fresh emulator.

Never targets a physical phone, changes a clock, resets existing app data,
prints the grant, or captures a screenshot while its input dialog is visible.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

PACKAGE = 'org.snapetech.pleazyng'
EXPIRED = 'Your 7-day trial has ended'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-[0-9]+', args.serial):
        parser.error('This expired-trial test only accepts an isolated emulator')
    token = os.environ['STORE_REVIEW_ACCESS_CODE']
    if not re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', token):
        raise RuntimeError('Review grant is missing or has invalid encoding')

    def adb(*command, binary=False, timeout=45):
        try:
            result = subprocess.run(['adb', '-s', args.serial, *command], capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError('ADB operation timed out') from None
        if result.returncode:
            # A failed input command's argv/stderr could include the grant.
            raise RuntimeError('ADB operation failed')
        return result.stdout if binary else result.stdout.decode('utf-8', errors='replace').strip()

    for _ in range(120):
        try:
            if adb('shell', 'getprop', 'sys.boot_completed') == '1':
                break
        except RuntimeError:
            pass
        time.sleep(2)
    else:
        raise RuntimeError('Emulator did not finish booting')
    if adb('shell', 'getprop', 'ro.kernel.qemu') != '1':
        raise RuntimeError('Refusing expired-trial state injection outside an emulator')
    if adb('shell', 'pm', 'list', 'packages', PACKAGE):
        raise RuntimeError('Fresh emulator required; existing app data will not be replaced')
    root = args.artifacts
    receipt = json.loads((root / 'play-qualification.json').read_text())
    apk = receipt['apks'][0]
    if not apk.get('signing_certificate_verified'):
        raise RuntimeError('Verify the Google signing certificate before executing the APK')
    adb('install', str((root / apk['file']).resolve()), timeout=180)
    adb('root')
    adb('wait-for-device')
    info = adb('shell', 'cmd', 'package', 'list', 'packages', '-U', PACKAGE)
    uid = re.search(r'uid:([0-9]+)', info)
    if not uid:
        raise RuntimeError('Installed app UID not found')
    uid = uid[1]
    started = int((time.time() - 8 * 86400) * 1000)
    # Populate only the fresh emulator's legacy preference before first launch;
    # the production migration moves it into the ordinary settings backend.
    prefs = f'/data/user/0/{PACKAGE}/shared_prefs'
    with tempfile.TemporaryDirectory(prefix='pleazyng-review-fixture-') as directory:
        fixture = Path(directory) / 'expired-trial.xml'
        fixture.write_text('<?xml version="1.0" encoding="utf-8"?>\n<map>\n'
                           f'<long name="flutter.app_access_trial_started_at_ms" value="{started}" />\n'
                           '</map>\n')
        adb('shell', 'mkdir', '-p', prefs)
        adb('push', str(fixture), prefs + '/FlutterSharedPreferences.xml')
        adb('shell', 'chown', '-R', f'{uid}:{uid}', prefs)
        adb('shell', 'chmod', '700', prefs)
        adb('shell', 'chmod', '600', prefs + '/FlutterSharedPreferences.xml')
        adb('shell', 'restorecon', '-R', prefs)

    def launch():
        component = adb('shell', 'cmd', 'package', 'resolve-activity', '--brief', PACKAGE).splitlines()[-1]
        if not component.startswith(PACKAGE + '/'):
            raise RuntimeError('Expected app launcher activity not found')
        adb('shell', 'am', 'start', '-n', component)

    def ui():
        path = '/data/local/tmp/pleazyng-review-ui.xml'
        adb('shell', 'uiautomator', 'dump', path)
        data = adb('shell', 'cat', path)
        adb('shell', 'rm', path)
        try:
            return ET.fromstring(data[data.index('<?xml'):])
        except (ValueError, ET.ParseError):
            raise RuntimeError('Could not parse native accessibility tree') from None

    def labels(tree):
        return [node.get(key, '') for node in tree.iter('node') for key in ('text', 'content-desc')]

    def wait_for(predicate):
        for _ in range(20):
            tree = ui()
            if predicate(labels(tree)):
                return tree
            time.sleep(1)
        raise RuntimeError('Expected application state did not appear')

    def click(tree, label):
        matches = []
        for node in tree.iter('node'):
            if not any(label in node.get(key, '') for key in ('text', 'content-desc')):
                continue
            values = re.fullmatch(r'\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]', node.get('bounds', ''))
            if values:
                x1, y1, x2, y2 = map(int, values.groups())
                if x2 > x1 and y2 > y1:
                    matches.append(((x2-x1)*(y2-y1), (x1+x2)//2, (y1+y2)//2))
        if not matches:
            raise RuntimeError('Expected native UI control not found')
        _, x, y = min(matches)
        adb('shell', 'input', 'tap', str(x), str(y))

    launch()
    tree = wait_for(lambda values: any(EXPIRED in value for value in values))
    if not any('Restore lifetime purchase' in value for value in labels(tree)):
        raise RuntimeError('Expired gate is missing purchase restore control')
    (root / 'expired-trial.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
    click(tree, 'Store review access')
    tree = wait_for(lambda values: any('Review code' in value for value in values))
    # No screenshots, XML files, command echo or raw logs are retained from here
    # until the dialog has closed. The existing grant stays in the CI secret.
    adb('shell', 'input', 'text', token)
    tree = ui()
    click(tree, 'Activate')
    unlocked = lambda values: (not any(EXPIRED in value or 'Review code' in value for value in values)
                              and any('Sign in with Plex' in value or 'Connect to Jellyfin' in value for value in values))
    wait_for(unlocked)
    (root / 'review-grant-unlocked.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
    adb('shell', 'am', 'force-stop', PACKAGE)
    launch()
    wait_for(unlocked)
    (root / 'review-grant-after-restart.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
    receipt.update(reviewer_grant_device_qualified=True, reviewer_test={
        'target': 'fresh native x86_64 Android emulator; actual Google-signed APK',
        'trial_fixture': 'started eight days before test, injected before first launch',
        'expired_gate_observed': True, 'restore_control_present_on_expired_gate': True,
        'grant_redeemed_through_disclosed_ui': True,
        'full_app_authentication_screen_after_redemption': True,
        'full_app_authentication_screen_after_restart': True,
        'clock_modified': False, 'physical_phone_modified': False,
        'purchase_restore_qualified': False,
    })
    (root / 'play-qualification.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Actual Google-signed APK accepted reviewer grant after trial expiry and remained unlocked after restart')


if __name__ == '__main__':
    main()
