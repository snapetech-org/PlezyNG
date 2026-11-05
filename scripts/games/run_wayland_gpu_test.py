#!/usr/bin/env python3
"""Run the native GPU integration test in a private, single-client Weston session."""
import argparse
import os
import socket
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('test')
    parser.add_argument('--weston', default='weston')
    parser.add_argument('--backend-module')
    parser.add_argument('--shell', default='kiosk-shell.so')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='steam-wayland-') as runtime:
        server, client = socket.socketpair()
        env = os.environ | {'XDG_RUNTIME_DIR': runtime, 'GDK_BACKEND': 'wayland'}
        if args.backend_module:
            env['WESTON_MODULE_MAP'] = 'headless-backend.so=' + args.backend_module
        weston = subprocess.Popen(
            [args.weston, '--backend=headless', '--renderer=pixman', '--shell=' + args.shell,
             '--width=640', '--height=480', '--idle-time=0', '--no-config'],
            env=env | {'WAYLAND_SERVER_SOCKET': str(server.fileno())}, pass_fds=(server.fileno(),))
        server.close()
        try:
            result = subprocess.run([args.test], env=env | {'WAYLAND_SOCKET': str(client.fileno())},
                                    pass_fds=(client.fileno(),), timeout=40)
            if result.returncode:
                raise SystemExit(result.returncode)
        finally:
            client.close()
            weston.terminate()
            try:
                weston.wait(timeout=5)
            except subprocess.TimeoutExpired:
                weston.kill()
                weston.wait()


if __name__ == '__main__':
    main()
