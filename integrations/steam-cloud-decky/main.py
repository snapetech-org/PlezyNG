import os
import secrets
import sys
from pathlib import Path
import decky
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bridge import Bridge


class Plugin:
    async def _main(self):
        self.session = None
        self.revision = 0
        if sys.platform == 'win32':
            from windows_pipe import WindowsBridge
            self.bridge = WindowsBridge(decky.emit)
            await self.bridge.start()
        else:
            uid = Path(decky.DECKY_USER_HOME).stat().st_uid
            self.bridge = Bridge(uid, decky.emit)
            runtime = f'/run/user/{uid}'
            if sys.platform == 'darwin':
                runtime = f'/tmp/plezyng-steam-cloud-{uid}'
                # Existing directories are validated by Bridge.start, never chmodded.
                Path(runtime).mkdir(mode=0o700, exist_ok=True)
            elif not sys.platform.startswith('linux'):
                raise RuntimeError('unsupported Steam host')
            await self.bridge.start(runtime)

    async def begin(self):
        self.bridge.allow(False)
        self.session = secrets.token_hex(16)
        self.revision = 0
        return self.session

    async def set_enabled(self, enabled, revision, session):
        if session != self.session or type(revision) is not int or revision <= self.revision:
            return False
        self.revision = revision
        self.bridge.allow(enabled)
        return self.bridge.enabled

    async def claim(self, request, session):
        return session == self.session and await self.bridge.claim(request)

    async def complete(self, request, result, session):
        if session == self.session:
            await self.bridge.complete(request, result)

    async def _unload(self):
        if hasattr(self, 'bridge'):
            await self.bridge.close()
