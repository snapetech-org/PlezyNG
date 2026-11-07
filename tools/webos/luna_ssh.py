#!/usr/bin/env python3
"""Call a rooted TV's native Luna tools without closing their input early."""
import argparse
import codecs
import json
import os
import selectors
import shlex
import subprocess
import tempfile
import time


def exchange(command, *, timeout=60, until=None):
    messages, pending = [], ''
    decoder = json.JSONDecoder()
    text_decoder = codecs.getincrementaldecoder('utf-8')()
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if not selector.select(min(1, max(0, deadline - time.monotonic()))):
                        continue
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError('Luna connection ended before the requested reply; check TV state before retrying')
                    pending += text_decoder.decode(chunk)
                    while pending.strip():
                        pending = pending.lstrip()
                        try:
                            message, end = decoder.raw_decode(pending)
                        except json.JSONDecodeError:
                            break
                        pending = pending[end:]
                        if not isinstance(message, dict):
                            raise RuntimeError('Expected a Luna response object')
                        messages.append(message)
                        state = message.get('details', {}).get('state', '')
                        # The install service may report a subscription disconnect
                        # after its successful terminal state. Stop at success.
                        if until and state.casefold() == until.casefold():
                            return messages
                        if message.get('returnValue') is False:
                            raise RuntimeError(message.get('errorText', 'Luna request failed'))
                        if until is None:
                            return messages
                raise TimeoutError('Luna observation timed out; check TV state before retrying')
        finally:
            # Keep stdin open until the reply arrives: EOF makes luna-send exit
            # successfully without delivering its asynchronous response.
            process.stdin.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', help='Existing SSH target, for example root@TV_HOST')
    parser.add_argument('uri')
    parser.add_argument('payload', help='JSON object')
    parser.add_argument('--until', choices=('installed', 'removed'))
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--private', action='store_true', help='Use luna-send rather than luna-send-pub')
    args = parser.parse_args()
    payload = json.loads(args.payload)
    if not isinstance(payload, dict) or not args.uri.startswith('luna://') or args.timeout <= 0:
        parser.error('Provide a Luna URI, JSON object and positive timeout')
    binary = '/usr/bin/luna-send' if args.private else '/usr/bin/luna-send-pub'
    remote = shlex.join([binary, '-i', '-f', '-w', str(int(args.timeout * 1000)), args.uri, json.dumps(payload)])
    replies = exchange(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', args.target, remote],
                       timeout=args.timeout + 10, until=args.until)
    print(json.dumps(replies[-1], indent=2))


if __name__ == '__main__':
    main()
