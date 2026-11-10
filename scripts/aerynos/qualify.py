#!/usr/bin/env python3
"""Build/install a Stone in fresh aerynOS and gate publication on release-app QA."""
from __future__ import annotations
import argparse
import contextlib
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request

from vm import Guest, ISO_SHA256, ISO_URL, port, run

HERE = Path(__file__).resolve().parent


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def command(guest, text, log):
    try:
        result = guest.ssh("set -euo pipefail; " + text)
    except subprocess.CalledProcessError as error:
        log.write_bytes(error.stdout + error.stderr)
        raise
    log.write_bytes(result.stdout + result.stderr)
    return result.stdout


@contextlib.contextmanager
def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server.server_port
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


class AppQA:
    def __init__(self, guest, evidence):
        self.guest, self.evidence = guest, evidence
        guest.put(HERE / 'guest_ui.py', '/tmp/qa-ui.py')

    def ui(self, action='dump', name='', value=None):
        args = ['python3', '/tmp/qa-ui.py', action]
        if action != 'dump':
            args.append(name)
        if value is not None:
            args.append(value)
        return json.loads(self.guest.user(shlex.join(args)).stdout)

    def wait(self, name, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if any((n['name'] or '').split('\n', 1)[0] == name for n in self.ui()):
                    return
            except (subprocess.SubprocessError, json.JSONDecodeError):
                pass
            time.sleep(1)
        self.guest.screenshot(self.evidence / 'ui-timeout.png')
        raise TimeoutError(f'App control did not appear: {name}')

    def key(self, key):
        self.guest.qmp('human-monitor-command', {'command-line': 'sendkey ' + key})

    def click(self, x, y):
        self.guest.qmp('input-send-event', {'events': [
            {'type': 'abs', 'data': {'axis': 'x', 'value': int(x / 1280 * 32767)}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': int(y / 800 * 32767)}},
        ]})
        time.sleep(0.05)
        for down in (True, False):
            self.guest.qmp('input-send-event', {'events': [{'type': 'btn', 'data': {'button': 'left', 'down': down}}]})
            time.sleep(0.05)

    def text(self, text):
        if not re.fullmatch('[a-z0-9]+', text):
            raise ValueError('Only authored lowercase QA credentials are typed')
        for letter in text:
            for down in (True, False):
                self.guest.qmp('input-send-event', {'events': [
                    {'type': 'key', 'data': {'down': down, 'key': {'type': 'qcode', 'data': letter}}}
                ]})
                time.sleep(0.03)

    def login_desktop(self):
        # A normal password login lets PAM initialize/unlock GNOME's login keyring.
        self.key('shift')
        time.sleep(2)
        image = self.evidence / 'desktop-login.png'
        self.guest.screenshot(image)
        self.key('ret')
        time.sleep(2)
        self.guest.screenshot(image)
        text = run(['tesseract', image, 'stdout'], capture_output=True, text=True).stdout.lower()
        if 'password' not in text:
            raise RuntimeError('GDM did not show the authored fixture user password field: ' + text)
        self.text('maestro')
        self.key('ret')
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                result = self.guest.user('gdbus call --session --dest org.freedesktop.DBus '
                                         '--object-path /org/freedesktop/DBus '
                                         '--method org.freedesktop.DBus.NameHasOwner org.gnome.Shell')
                if b'true' in result.stdout:
                    # GNOME publishes Shell before its first-login input services settle.
                    time.sleep(15)
                    return
            except subprocess.SubprocessError:
                pass
            time.sleep(2)
        raise TimeoutError('GNOME did not start after normal fixture login')

    def launch(self, preload=None):
        self.guest.user('gsettings set org.gnome.desktop.session idle-delay 0')
        self.guest.user('gsettings set org.gnome.desktop.interface toolkit-accessibility true')
        env = ['--setenv=LD_PRELOAD=' + preload] if preload else []
        self.guest.user(shlex.join(['systemd-run', '--user', '--unit=pleazyng-qa', *env, '/usr/bin/pleazyng']))
        time.sleep(3)
        self.key('esc')
        self.key('alt-f10')

    def stop(self):
        self.guest.user('systemctl --user stop pleazyng-qa')
        time.sleep(1)

    def sign_in(self, server_port):
        self.wait('Connect to Jellyfin')
        self.ui('click', 'Connect to Jellyfin')
        self.wait('Server URLs')
        self.ui('fill', 'Server URLs', f'http://10.0.2.2:{server_port}')
        self.ui('click', 'Find server')
        self.wait('Username')
        self.ui('fill', 'Username', 'maestro')
        self.wait('Password')
        # Use the exposed tap action; protected text has no usable geometry.
        self.ui('click', 'Password')
        time.sleep(0.3)
        self.text('maestro')
        time.sleep(0.3)
        if self.ui('length', 'Password') != len('maestro'):
            self.guest.screenshot(self.evidence / 'password-input-failed.png')
            raise RuntimeError('Ordinary protected-field keyboard input failed')
        self.ui('click', 'Sign in')
        self.finish_sign_in()

    def finish_sign_in(self):
        time.sleep(1)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            names = {(n['name'] or '').split('\n', 1)[0] for n in self.ui()}
            if 'Allow HTTP' in names:
                self.ui('click', 'Allow HTTP')
            if 'Recently Added in Maestro Movies' in names:
                return
            if 'Invalid username or password' in names or 'Sign-in failed: an unexpected error occurred' in names:
                raise RuntimeError('Fixture sign-in failed; inspect native app journal')
            time.sleep(1)
        raise TimeoutError('Fixture libraries did not load after sign-in')

    def settings(self):
        self.ui('click', 'Settings')
        time.sleep(1)
        if not any((n['name'] or '').split('\n', 1)[0] == 'Video Playback' for n in self.ui()):
            self.ui('click', 'Settings')
        self.wait('Video Playback')
        self.ui('click', 'Video Playback')
        self.wait('Experimental Dolby Vision')

    def verify_default(self):
        self.settings()
        assert self.ui('state', 'Experimental Dolby Vision') is True
        assert self.ui('state', 'Compatibility fallback') is True
        self.guest.screenshot(self.evidence / 'default-on.png')
        self.ui('click', 'Video experiment logging')
        self.key('esc')
        self.key('esc')

    def open_movie(self, name):
        # Search through the normal app UI; no release-only automation endpoint.
        self.click(38, 190)
        time.sleep(1)
        try:
            self.wait('Search movies, shows, music...', timeout=3)
        except TimeoutError:
            self.click(80, 374)
            self.wait('Search movies, shows, music...')
        self.ui('fill', 'Search movies, shows, music...', name)
        self.wait(name)
        self.ui('click', name)
        self.wait('Play')
        self.ui('click', 'Play')
        self.wait('Show playback controls')

    def visible_h264(self):
        from PIL import Image, ImageChops
        self.open_movie('Maestro Movie')
        deadline = time.monotonic() + 90
        path = self.evidence / 'h264-playing.png'
        while time.monotonic() < deadline:
            self.guest.screenshot(path)
            image = Image.open(path).convert('RGB').crop((100, 150, 1180, 700))
            vivid = sum(max(p) - min(p) > 100 and max(p) > 160 for p in image.getdata()) / (image.width * image.height)
            if vivid > 0.4:
                break
            time.sleep(1)
        else:
            raise RuntimeError('Native video aperture never displayed the authored colour pattern')
        self.ui('click', 'Show playback controls')
        self.wait('Pause')
        self.ui('click', 'Pause')
        time.sleep(1)
        self.guest.screenshot(self.evidence / 'before-seek.png')
        self.ui('click', 'Seek forward 10 seconds')
        time.sleep(2)
        self.guest.screenshot(self.evidence / 'paused-1.png')
        time.sleep(2)
        self.guest.screenshot(self.evidence / 'paused-2.png')
        a = Image.open(self.evidence / 'paused-1.png').crop((100, 150, 1180, 550))
        before_seek = Image.open(self.evidence / 'before-seek.png').crop((100, 150, 1180, 550))
        delta = ImageChops.difference(before_seek.convert('RGB'), a.convert('RGB'))
        changed = sum(max(pixel) > 20 for pixel in delta.getdata()) / (delta.width * delta.height)
        (self.evidence / 'seek-result.json').write_text(json.dumps({'changed_frame_fraction': changed}) + '\n')
        if changed < 0.02:
            raise RuntimeError('Seek did not visibly advance the authored moving pattern')
        b = Image.open(self.evidence / 'paused-2.png').crop((100, 150, 1180, 550))
        if ImageChops.difference(a, b).getbbox() is not None:
            raise RuntimeError('Paused video pixels changed')
        # Reveal controls if their timeout hid them, then verify paused state.
        if any(n['name'] == 'Show playback controls' for n in self.ui()):
            self.ui('click', 'Show playback controls')
        self.wait('Play')
        self.ui('click', 'Enter fullscreen')
        self.wait('Exit fullscreen')
        self.guest.screenshot(self.evidence / 'fullscreen.png')
        self.key('esc')
        self.ui('click', 'Back')
        self.wait('Back')
        self.ui('click', 'Back')


def fixture(source, root):
    data = root / 'jellyfin'
    for name in ('media', 'config', 'cache'):
        (data / name).mkdir(parents=True)
    run([sys.executable, source / 'scripts/maestro/maestro_real_jellyfin.py', 'prepare', '--output-dir', data / 'media'])
    movie = data / 'media/movies/maestro-movie/Maestro Movie.mp4'
    run(['ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24',
         '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '60',
         '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '24', '-c:a', 'aac', '-movflags', '+faststart', movie])
    server_port = port()
    name = 'pleazyng-aerynos-ci-' + root.name.lower().replace('_', '-')
    image = 'jellyfin/jellyfin@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db'
    result = run(['docker', 'run', '-d', '--name', name, '--cpus', '2', '--memory', '1g',
                  '--user', f'{os.getuid()}:{os.getgid()}', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                  '-p', f'127.0.0.1:{server_port}:8096', '-v', f'{data}/config:/config',
                  '-v', f'{data}/cache:/cache', '-v', f'{data}/media:/media:ro', image], capture_output=True)
    try:
        run([sys.executable, source / 'scripts/maestro/maestro_real_jellyfin.py', 'bootstrap', '--url', f'http://127.0.0.1:{server_port}', '--timeout', '180'])
    except BaseException:
        run(['docker', 'rm', '-f', name])
        raise
    return name, server_port


def qualify(args):
    source, candidate, output = args.source.resolve(), args.candidate.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    evidence = output / 'evidence'
    evidence.mkdir()
    build = json.loads((candidate / 'build.json').read_text())
    for name, expected in build['assets'].items():
        if digest(candidate / name) != expected:
            raise RuntimeError('Candidate checksum mismatch: ' + name)
    version = build['version'].split('+')[0]
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', build['source_sha']):
        raise ValueError('Invalid source version or SHA')
    tag = f'main-{build["source_sha"][:12]}-r{args.release}'
    run([sys.executable, HERE.parents[1] / 'scripts/prepare_linux_channel_recipes.py', '--channel', 'aerynos', '--tag', 'v' + version,
         '--checksums', candidate / 'SHA256SUMS.txt', '--output', output / 'prepared'])
    recipe = output / 'prepared/aerynos'
    text = (recipe / 'stone.yaml').read_text()
    text = re.sub(r'^release\s*:\s*\d+', f'release     : {args.release}', text, flags=re.M)
    public_url = f'https://github.com/snapetech-org/pleazyng-aerynos/releases/download/{tag}/pleazyng-linux-x64.tar.gz'
    original_url = f'https://github.com/snapetech-org/pleazyng/releases/download/v{version}/pleazyng-linux-x64.tar.gz'
    public_recipe = text.replace(original_url, public_url)
    guest = Guest(args.scratch / 'vm')
    container = None
    try:
        container, server_port = fixture(source, args.scratch)
        print('Preparing official aerynOS guest', flush=True)
        guest.prepare(args.iso)
        guest.start()
        baseline_url = 'https://raw.githubusercontent.com/snapetech-org/pleazyng-aerynos/main/sync-state/last-good.json'
        with urllib.request.urlopen(baseline_url, timeout=30) as response:
            baseline = json.load(response)
        baseline_feed = baseline['release_feed_url']
        if not re.fullmatch(r'https://github.com/snapetech-org/pleazyng-aerynos/releases/download/[A-Za-z0-9.+_-]+/stone.index', baseline_feed):
            raise ValueError('Unexpected last-good package feed')
        command(guest, f'moss repo add pleazyng-baseline {shlex.quote(baseline_feed)}; moss -y pkg add pleazyng; moss repo remove pleazyng-baseline', evidence / 'baseline-install.log')
        with serve(candidate) as http_port:
            (recipe / 'stone.yaml').write_text(text.replace(original_url, f'http://10.0.2.2:{http_port}/pleazyng-linux-x64.tar.gz'))
            archive = output / 'recipe-tested.tar'
            with tarfile.open(archive, 'w') as t:
                t.add(recipe, arcname='recipe')
            guest.ssh('mkdir -p /root/recipe; tar -C /root -xf -', data=archive.read_bytes())
            print('Building native Stone', flush=True)
            command(guest, 'cd /root/recipe && boulder build stone.yaml', evidence / 'boulder.log')
        # Index relative immutable release paths. The public index is atomically committed at
        # github.com/ORG/REPO/raw/refs/heads/main/feed/stone.index; Moss resolves against that original URI.
        layout = '/root/publish-layout'
        packages = f'{layout}/releases/download/{tag}'
        index = f'{layout}/raw/refs/heads/main/feed'
        command(guest, f'mkdir -p {packages} {index}; cp /root/recipe/*.stone {packages}/; '
                f'moss index --input-dir {packages} --output-dir {index}; '
                f'moss repo add pleazyng-ci file://{index}/stone.index; moss sync --dry-run; moss -y sync', evidence / 'install.log')
        installed = command(guest, "moss pkg list --installed | sed -n '/^pleazyng /p'", evidence / 'installed-version.txt').decode().split()
        if len(installed) < 2 or installed[1] != f'{version}-{args.release}':
            raise RuntimeError('Moss did not activate the new package release')
        names = guest.ssh(f'find {packages} -name "*.stone" -printf "%f\\n"').stdout.decode().splitlines()
        if len(names) != 1:
            raise RuntimeError(f'Unexpected subpackages: {names}')
        for name in names:
            (output / name).write_bytes(guest.ssh(f'cat {packages}/{name}').stdout)
        (output / 'feed.index').write_bytes(guest.ssh(f'cat {index}/stone.index').stdout)
        guest.ssh(f'moss index --input-dir {packages}')
        (output / 'stone.index').write_bytes(guest.ssh(f'cat {packages}/stone.index').stdout)
        guest.put(HERE / 'check_installed.py', '/root/check-installed.py')
        command(guest, 'python3 /root/check-installed.py /usr/lib/pleazyng /root/recipe/pkg/normalize-bundle-rpaths.py', evidence / 'installed-elf.json')
        command(guest, 'test -s /usr/lib/pleazyng/lib/gtk-3.0/3.0.0/immodules.cache', evidence / 'im-cache.log')
        app = AppQA(guest, evidence)
        print('Testing ordinary installed release application', flush=True)
        app.login_desktop()
        app.launch()
        app.sign_in(server_port)
        app.verify_default()
        app.visible_h264()
        app.stop()
        guest.screenshot(evidence / 'after-playback.png')
        command(guest, 'journalctl _COMM=pleazyng --no-pager', evidence / 'runtime.log')
        # All publication claims must correspond to checks actually executed above.
        qualification = {'source_sha': build['source_sha'], 'version': build['version'], 'release': args.release, 'tag': tag,
                         'iso_sha256': ISO_SHA256, 'status': 'qualified',
                         'recipe_tooling_sha': run(['git', '-C', HERE.parents[1], 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip(),
                         'checks': ['native_boulder_build', 'native_moss_install', 'native_moss_upgrade', 'installed_elf', 'bundled_im_cache', 'ordinary_release_launch',
                                    'jellyfin_sign_in', 'dv_default_on', 'fallback_default_on', 'visible_h264', 'pause', 'seek', 'fullscreen'],
                         'not_qualified': ['physical HDR/Dolby Vision output', 'FEL reference picture accuracy', 'physical GPU/NPU execution'],
                         'stone': names[0], 'stone_sha256': digest(output / names[0]), 'build': build, 'baseline': baseline,
                         'same_app_version_upgrade': baseline.get('version', '').split('+')[0] == version,
                         'source_sha_changed': (baseline.get('source_sha') or baseline.get('legacy_source_sha')) != build['source_sha']}
        (output / 'qualification.json').write_text(json.dumps(qualification, indent=2) + '\n')
        (recipe / 'stone.yaml').write_text(public_recipe)
        with tarfile.open(output / 'recipe.tar.gz', 'w:gz') as t:
            t.add(recipe, arcname='recipe')
        for name in ('pleazyng-linux-x64.tar.gz', 'pleazyng-source.tar.gz'):
            shutil.copyfile(candidate / name, output / name)
        public_assets = [names[0], 'stone.index', 'feed.index', 'qualification.json', 'recipe.tar.gz', 'pleazyng-linux-x64.tar.gz', 'pleazyng-source.tar.gz']
        (output / 'SHA256SUMS.txt').write_text(''.join(f'{digest(output / name)}  {name}\n' for name in public_assets))
        print('Native qualification passed', flush=True)
    finally:
        try:
            if guest.process and guest.process.poll() is None:
                for name, query in [('runtime.log', 'journalctl --user -b -u pleazyng-qa --no-pager')]:
                    try:
                        (evidence / name).write_bytes(guest.user(query).stdout)
                    except subprocess.SubprocessError:
                        pass
                guest.screenshot(evidence / 'final.png')
        finally:
            guest.close()
            if container:
                run(['docker', 'rm', '-f', container])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--scratch', required=True, type=Path)
    parser.add_argument('--iso', required=True, type=Path)
    parser.add_argument('--release', required=True, type=int)
    args = parser.parse_args()
    if args.release < 2:
        parser.error('Automated package release must be greater than the seed release 1')
    args.scratch.mkdir(parents=True, exist_ok=True)
    qualify(args)


if __name__ == '__main__':
    main()
