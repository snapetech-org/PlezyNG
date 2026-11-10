#!/usr/bin/env python3
"""Disposable native aerynOS guest, booted from a checksum-pinned official ISO."""
from __future__ import annotations
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import time
import uuid

ISO_URL = 'https://cdn.aerynos.dev/isos/aerynOS-2026.11-GNOME-live-x86_64.iso'
ISO_SHA256 = 'e348b88da07e5876d1e0fc50e156f0a062c58251ab6deb2a897155980fa6c419'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Guest:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=False)
        self.ssh_port = port()
        self.process = None
        self.logs = []

    def prepare(self, iso: Path):
        import hashlib
        with iso.open('rb') as f:
            if hashlib.file_digest(f, 'sha256').hexdigest() != ISO_SHA256:
                raise RuntimeError('Official ISO checksum mismatch')
        run(['bsdtar', '-xf', iso, '-C', self.root, 'LiveOS/squashfs.img'])
        rootfs = self.root / 'rootfs'
        run(['sudo', '-n', 'unsquashfs', '-processors', '2', '-no-progress', '-d', rootfs, self.root / 'LiveOS/squashfs.img'])
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', self.root / 'key'])
        # Root-only edits run in a bounded task tree; no host configuration changes.
        payload = {
            'root/.ssh/authorized_keys': (self.root / 'key.pub').read_text(),
            'etc/ssh/sshd_config.d/90-qa.conf': 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n',
            'etc/hostname': 'aerynos-ci\n',
            'etc/gdm/custom.conf': '[daemon]\nAutomaticLoginEnable=False\n',
            'var/lib/AccountsService/users/live': '[User]\nSystemAccount=false\n',
            'etc/systemd/system/qa-bootstrap.service': '''[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -ec 'for i in {1..10}; do moss -y pkg add boulder openssh-server bsdtar && break; sleep 10; done; command -v boulder; systemctl start sshd'
TimeoutStartSec=900
[Install]
WantedBy=multi-user.target
''',
        }
        edit = '''import json,os,pathlib,sys
root=pathlib.Path(sys.argv[1]); payload=json.load(sys.stdin)
for name,text in payload.items():
 p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
os.chmod(root/'root/.ssh',0o700);os.chmod(root/'root/.ssh/authorized_keys',0o600)
p=root/'etc/systemd/system/multi-user.target.wants/qa-bootstrap.service';p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to('/etc/systemd/system/qa-bootstrap.service')
'''
        run(['sudo', '-n', 'python3', '-c', edit, rootfs], input=json.dumps(payload), text=True)
        password = run(['openssl', 'passwd', '-6', '-stdin'], input='maestro\n', text=True, capture_output=True).stdout.strip()
        run(['sudo', '-n', 'chpasswd', '--encrypted', '--root', rootfs], input='live:' + password + '\n', text=True)
        disk_uuid = str(uuid.uuid4())
        run(['truncate', '-s', '40G', self.root / 'system.raw'])
        run(['sudo', '-n', 'mkfs.ext4', '-q', '-F', '-U', disk_uuid, '-d', rootfs, self.root / 'system.raw'])
        kernels = list((rootfs / 'usr/lib/modules').glob('*/vmlinux'))
        if len(kernels) != 1:
            raise RuntimeError(f'Expected one ISO kernel, got {kernels}')
        kernel = kernels[0]
        initrd = rootfs / 'usr/lib/kernel' / kernel.parent.name / '50-default.initrd'
        (self.root / 'cmdline').write_text(f'root=UUID={disk_uuid} rw console=ttyS0,115200\0')
        run(['objcopy', '--add-section', f'.osrel={rootfs}/usr/lib/os-release', '--change-section-vma', '.osrel=0x14dfc0000',
             '--add-section', f'.cmdline={self.root}/cmdline', '--change-section-vma', '.cmdline=0x14dfd0000',
             '--add-section', f'.linux={kernel}', '--change-section-vma', '.linux=0x14e190000',
             '--add-section', f'.initrd={initrd}', '--change-section-vma', '.initrd=0x150f90000',
             '/usr/lib/systemd/boot/efi/linuxx64.efi.stub', self.root / 'guest.efi'])
        run(['truncate', '-s', '512M', self.root / 'esp.raw'])
        run(['sfdisk', self.root / 'esp.raw'], input='label: gpt\nstart=2048, type=U\n', text=True)
        run(['truncate', '-s', '510M', self.root / 'esp.fat'])
        run(['mkfs.vfat', '-F', '32', self.root / 'esp.fat'])
        run(['mmd', '-i', self.root / 'esp.fat', '::/EFI', '::/EFI/BOOT', '::/EFI/Linux'])
        run(['mcopy', '-i', self.root / 'esp.fat', '/usr/lib/systemd/boot/efi/systemd-bootx64.efi', '::/EFI/BOOT/BOOTX64.EFI'])
        run(['mcopy', '-i', self.root / 'esp.fat', self.root / 'guest.efi', '::/EFI/Linux/guest.efi'])
        run(['dd', f'if={self.root}/esp.fat', f'of={self.root}/esp.raw', 'bs=512', 'seek=2048', 'conv=notrunc', 'status=none'])
        shutil.copyfile('/usr/share/OVMF/OVMF_VARS_4M.fd', self.root / 'OVMF_VARS.fd')
        # Only extracted intermediates, after their consumers have exited. ISO stays cached.
        run(['sudo', '-n', 'rm', '-rf', '--', rootfs, self.root / 'LiveOS'])
        for name in ('esp.fat', 'guest.efi'):
            (self.root / name).unlink()
        (self.root / 'os.json').write_text(json.dumps({'iso_url': ISO_URL, 'iso_sha256': ISO_SHA256, 'kernel': kernel.parent.name}))

    def start(self):
        log = (self.root / 'qemu.log').open('w')
        self.logs.append(log)
        self.process = subprocess.Popen([
            'sudo', '-n', 'qemu-system-x86_64', '-name', 'pleazyng-aerynos-ci',
            '-machine', 'q35,accel=kvm', '-cpu', 'host', '-smp', '2', '-m', '6G',
            '-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd',
            '-drive', f'if=pflash,format=raw,file={self.root}/OVMF_VARS.fd',
            '-drive', f'file={self.root}/system.raw,if=virtio,format=raw,cache=none',
            '-drive', f'file={self.root}/esp.raw,if=virtio,format=raw,cache=none',
            '-netdev', f'user,id=qa,hostfwd=tcp:127.0.0.1:{self.ssh_port}-:22',
            '-device', 'virtio-net-pci,netdev=qa', '-vga', 'virtio',
            '-device', 'virtio-keyboard-pci', '-device', 'virtio-tablet-pci',
            '-audiodev', f'wav,id=qa,path={self.root}/audio.wav', '-device', 'ich9-intel-hda',
            '-device', 'hda-duplex,audiodev=qa', '-display', 'none',
            '-qmp', f'unix:{self.root}/qmp.sock,server=on,wait=off',
            '-serial', f'file:{self.root}/serial.log', '-monitor', 'none', '-no-reboot'], stdout=log, stderr=subprocess.STDOUT)
        for _ in range(30):
            if (self.root / 'qmp.sock').exists():
                run(['sudo', '-n', 'chown', f'{os.getuid()}:{os.getgid()}', self.root / 'qmp.sock'])
                break
            time.sleep(1)
        deadline = time.monotonic() + 1000
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('QEMU exited; inspect qemu.log and serial.log')
            try:
                self.ssh('command -v boulder', timeout=10)
                return
            except (subprocess.SubprocessError, OSError):
                time.sleep(5)
        raise TimeoutError('Guest bootstrap/SSH did not become ready')

    def ssh(self, command, *, data=None, timeout=1200):
        return run(['ssh', '-i', self.root / 'key', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                    '-o', f'UserKnownHostsFile={self.root}/known_hosts', '-o', 'ConnectTimeout=5',
                    '-p', str(self.ssh_port), 'root@127.0.0.1', command],
                   input=data, capture_output=True, timeout=timeout)

    def user(self, command):
        return self.ssh('runuser -u live -- env XDG_RUNTIME_DIR=/run/user/1000 '
                        'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus bash -c ' + shlex.quote(command))

    def put(self, source: Path, destination: str):
        self.ssh('cat > ' + shlex.quote(destination), data=source.read_bytes())

    def qmp(self, name, arguments=None):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(15)
            conn.connect(str(self.root / 'qmp.sock'))
            f = conn.makefile('rwb', buffering=0)
            f.readline()
            def command(cmd, args):
                f.write((json.dumps({'execute': cmd, 'arguments': args}) + '\n').encode())
                while True:
                    result = json.loads(f.readline())
                    if 'error' in result:
                        raise RuntimeError(result)
                    if 'return' in result:
                        return result['return']
            command('qmp_capabilities', {})
            return command(name, arguments or {})

    def screenshot(self, path: Path):
        ppm = path.with_suffix('.ppm')
        self.qmp('screendump', {'filename': str(ppm.resolve())})
        from PIL import Image
        Image.open(ppm).save(path)
        ppm.unlink()

    def close(self):
        if self.process and self.process.poll() is None:
            try:
                self.ssh('poweroff', timeout=20)
                self.process.wait(timeout=90)
            except (subprocess.SubprocessError, OSError):
                try:
                    self.qmp('quit')
                finally:
                    self.process.wait(timeout=30)
        for log in self.logs:
            log.close()
