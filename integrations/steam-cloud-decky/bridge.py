"""Same-user Unix socket; no TCP, account tokens, paths or script execution API."""
import asyncio
import json
import os
import secrets
import socket
import stat
import struct
import time
from pathlib import Path


class Bridge:
    def __init__(self, uid, emit):
        self.uid, self.emit = uid, emit
        self.enabled = False
        self.pending = None
        self.server = None
        self.path = None
        self.inode = None
        self.clients = set()

    async def start(self, runtime):
        if os.geteuid() != self.uid:
            raise ValueError('bridge must run as the Steam desktop user, never root on behalf of another user')
        directory = Path(runtime)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != self.uid or info.st_mode & 0o077:
            raise ValueError('private user runtime directory required')
        path = directory / 'plezyng-steam-cloud.sock'
        if path.exists() or path.is_symlink():
            raise ValueError('bridge socket already exists')
        self.server = await asyncio.start_unix_server(self.handle, path=str(path), limit=2048)
        os.chmod(path, 0o600)
        self.path, self.inode = path, path.lstat().st_ino

    def allow(self, enabled):
        self.enabled = enabled is True
        if not self.enabled and self.pending:
            self.pending['future'].cancel()

    async def claim(self, request):
        p = self.pending
        if not self.enabled or not p or p['id'] != request or p['claimed'] or p['future'].done() or time.monotonic() >= p['deadline']:
            return False
        p['claimed'] = True
        return True

    async def complete(self, request, result):
        p = self.pending
        if not p or p['id'] != request or not p['claimed'] or p['future'].done() or time.monotonic() >= p['deadline']:
            return
        if not isinstance(result, dict) or result.get('status') not in ('observed', 'stale', 'denied', 'unknown', 'unavailable'):
            result = {'status': 'unknown'}
        if result['status'] == 'observed':
            if result.get('steamId') != p['account'] or type(result.get('enabled')) is not bool:
                result = {'status': 'unknown'}
            else:
                result = {k: result[k] for k in ('status', 'steamId', 'enabled')}
        else:
            result = {'status': result['status']}
        p['future'].set_result(result)

    async def handle(self, reader, writer):
        if len(self.clients) >= 4:
            writer.close()
            await writer.wait_closed()
            return
        current = asyncio.current_task()
        self.clients.add(current)
        pending = None
        disconnected = None
        try:
            credentials = writer.get_extra_info('socket').getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
            _, uid, _ = struct.unpack('3i', credentials)
            if uid != self.uid or not self.enabled or self.pending:
                raise ValueError('unavailable')
            line = await asyncio.wait_for(reader.readline(), 2)
            request = json.loads(line)
            if not isinstance(request, dict) or set(request) - {'version', 'op', 'steamId', 'expected', 'enabled'}:
                raise ValueError('invalid request')
            account = request.get('steamId')
            if request.get('version') != 1 or not isinstance(account, str) or len(account) != 17 or not account.isascii() or not account.isdigit() or not account.startswith('7656119'):
                raise ValueError('invalid identity')
            if request.get('op') == 'set':
                if type(request.get('enabled')) is not bool or type(request.get('expected')) is not bool:
                    raise ValueError('invalid setting')
            elif request.get('op') != 'read' or 'enabled' in request or 'expected' in request:
                raise ValueError('invalid operation')
            if not self.enabled or self.pending:
                raise ValueError('unavailable')
            pending = {'id': secrets.token_hex(16), 'account': account, 'deadline': time.monotonic() + 7,
                       'claimed': False, 'future': asyncio.get_running_loop().create_future()}
            self.pending = pending
            # A peer disconnect/extra data retires the claim before UI work starts.
            disconnected = asyncio.create_task(reader.read(1))
            await self.emit('cloud_request', pending['id'], request)
            done, _ = await asyncio.wait([pending['future'], disconnected], timeout=7, return_when=asyncio.FIRST_COMPLETED)
            if disconnected in done or pending['future'] not in done or not self.enabled:
                raise ValueError('unavailable')
            result = pending['future'].result()
            writer.write((json.dumps(result, separators=(',', ':')) + '\n').encode())
            await asyncio.wait_for(writer.drain(), 1)
        except (Exception, asyncio.CancelledError):
            # Fixed bounded response; no request, token, identity or exception logs.
            try:
                writer.write(b'{"status":"unknown"}\n')
                await asyncio.wait_for(writer.drain(), 1)
            except (Exception, asyncio.CancelledError):
                pass
        finally:
            if pending:
                pending['future'].cancel()
                if self.pending is pending:
                    self.pending = None
            if disconnected:
                disconnected.cancel()
                await asyncio.gather(disconnected, return_exceptions=True)
            writer.close()
            try:
                await writer.wait_closed()
            except (Exception, asyncio.CancelledError):
                pass
            self.clients.discard(current)

    async def close(self):
        self.allow(False)
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        for task in list(self.clients):
            task.cancel()
        await asyncio.gather(*self.clients, return_exceptions=True)
        if self.path and self.path.exists() and self.path.lstat().st_ino == self.inode:
            self.path.unlink()
