import asyncio
import json
import os
from pathlib import Path
import tempfile
import unittest
from bridge import Bridge

ACCOUNT = '76561198000000001'

class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.events = asyncio.Queue()
        async def emit(_, request, data):
            await self.events.put((request, data))
        self.bridge = Bridge(os.getuid(), emit)
        try:
            await self.bridge.start(self.temp.name)
        except PermissionError:
            self.skipTest('Unix sockets are denied by this execution environment')
        self.addAsyncCleanup(self.bridge.close)

    async def request(self, **data):
        reader, writer = await asyncio.open_unix_connection(str(self.bridge.path))
        writer.write((json.dumps({'version':1,'op':'read','steamId':ACCOUNT,**data})+'\n').encode())
        await writer.drain()
        self.addAsyncCleanup(self.close_writer, writer)
        return reader, writer

    async def close_writer(self, writer):
        writer.close()
        await writer.wait_closed()

    async def test_disabled_by_default_and_private_socket(self):
        self.assertEqual(self.bridge.path.stat().st_mode & 0o777, 0o600)
        reader, _ = await self.request()
        self.assertEqual(json.loads(await reader.readline())['status'], 'unknown')
        self.assertTrue(self.events.empty())

    async def test_claim_once_and_readback(self):
        self.bridge.allow(True)
        reader, _ = await self.request(op='set', expected=True, enabled=False)
        request, data = await self.events.get()
        self.assertFalse(await self.bridge.claim('other'))
        self.assertTrue(await self.bridge.claim(request))
        self.assertFalse(await self.bridge.claim(request))
        await self.bridge.complete(request, {'status':'observed','steamId':ACCOUNT,'enabled':False})
        self.assertFalse(json.loads(await reader.readline())['enabled'])

    async def test_revoke_cancels_pending_claim(self):
        self.bridge.allow(True)
        reader, _ = await self.request()
        request, _ = await self.events.get()
        self.bridge.allow(False)
        self.assertFalse(await self.bridge.claim(request))
        self.assertEqual(json.loads(await reader.readline())['status'], 'unknown')

    async def test_invalid_commands_never_reach_ui(self):
        self.bridge.allow(True)
        for data in ({'op':'eval','script':'x'}, {'op':'set','expected':True,'enabled':1}, {'steamId':'bad'}):
            reader, _ = await self.request(**data)
            self.assertEqual(json.loads(await reader.readline())['status'],'unknown')
        self.assertTrue(self.events.empty())

    async def test_account_mismatch_never_reports_success(self):
        self.bridge.allow(True)
        reader, _ = await self.request()
        request, _ = await self.events.get()
        await self.bridge.claim(request)
        await self.bridge.complete(request, {'status':'observed','steamId':'76561198000000002','enabled':True})
        self.assertEqual(json.loads(await reader.readline())['status'],'unknown')

    async def test_disconnect_retires_request(self):
        self.bridge.allow(True)
        _, writer = await self.request()
        request, _ = await self.events.get()
        writer.close()
        await writer.wait_closed()
        for _ in range(20):
            if self.bridge.pending is None:
                break
            await asyncio.sleep(.01)
        self.assertFalse(await self.bridge.claim(request))


class ClaimTests(unittest.IsolatedAsyncioTestCase):
    async def test_claim_is_one_use_expiring_and_permission_gated(self):
        import time
        bridge = Bridge(os.getuid(), None)
        future = asyncio.get_running_loop().create_future()
        bridge.pending = {'id':'one', 'claimed':False, 'deadline':time.monotonic()+2, 'future':future}
        self.assertFalse(await bridge.claim('one'))
        bridge.allow(True)
        self.assertFalse(await bridge.claim('other'))
        self.assertTrue(await bridge.claim('one'))
        self.assertFalse(await bridge.claim('one'))
        bridge.allow(False)
        self.assertTrue(future.cancelled())

    async def test_completion_requires_claim_and_account_match(self):
        bridge = Bridge(os.getuid(), None)
        future = asyncio.get_running_loop().create_future()
        import time
        bridge.pending = {'id':'one','claimed':False,'future':future,'account':ACCOUNT,'deadline':time.monotonic()+2}
        await bridge.complete('one', {'status':'observed','steamId':ACCOUNT,'enabled':True})
        self.assertFalse(future.done())
        bridge.pending['claimed'] = True
        await bridge.complete('one', {'status':'observed','steamId':'other','enabled':True})
        self.assertEqual(future.result(), {'status':'unknown'})

    async def test_expired_claim_and_late_completion_are_rejected(self):
        import time
        bridge = Bridge(os.getuid(), None)
        bridge.allow(True)
        future = asyncio.get_running_loop().create_future()
        bridge.pending = {'id':'one','claimed':False,'future':future,'account':ACCOUNT,'deadline':time.monotonic()-1}
        self.assertFalse(await bridge.claim('one'))
        bridge.pending['claimed'] = True
        await bridge.complete('one', {'status':'observed','steamId':ACCOUNT,'enabled':True})
        self.assertFalse(future.done())
        future.cancel()

if __name__ == '__main__':
    unittest.main()
