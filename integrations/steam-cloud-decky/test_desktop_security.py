"""Platform-independent lifecycle and macOS peer-credential failure tests."""
import asyncio
import ctypes
import time
import unittest
from unittest.mock import patch, Mock
import bridge


class PeerIdentityTests(unittest.TestCase):
    def test_darwin_uses_kernel_peer_uid(self):
        def identify(fd, uid, gid):
            self.assertEqual(fd, 42)
            ctypes.cast(uid, ctypes.POINTER(ctypes.c_uint))[0] = 501
            ctypes.cast(gid, ctypes.POINTER(ctypes.c_uint))[0] = 20
            return 0
        lib = Mock()
        lib.getpeereid.side_effect = identify
        with patch.object(bridge.sys, 'platform', 'darwin'), patch.object(bridge.ctypes, 'CDLL', return_value=lib):
            self.assertEqual(bridge.peer_uid(Mock(fileno=lambda: 42)), 501)

    def test_darwin_identity_failure_is_closed(self):
        lib = Mock()
        lib.getpeereid.return_value = -1
        with patch.object(bridge.sys, 'platform', 'darwin'), patch.object(bridge.ctypes, 'CDLL', return_value=lib):
            with self.assertRaises(PermissionError):
                bridge.peer_uid(Mock(fileno=lambda: 42))


class RetirementTests(unittest.IsolatedAsyncioTestCase):
    async def test_disconnect_blocks_claim_even_while_emitter_is_waiting(self):
        host = bridge.Bridge(501, None)
        host.allow(True)
        loop = asyncio.get_running_loop()
        reply, disconnected = loop.create_future(), loop.create_future()
        host.pending = {'id': 'one', 'claimed': False, 'deadline': time.monotonic() + 5,
                        'future': reply, 'disconnected': disconnected, 'account': '76561198000000001'}
        disconnected.set_result(b'')
        self.assertFalse(await host.claim('one'))
        host.pending['claimed'] = True
        await host.complete('one', {'status': 'observed', 'steamId': '76561198000000001', 'enabled': True})
        self.assertFalse(reply.done())
        reply.cancel()


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def exchange(self, payload, *, eof=False, permission=True):
        reader = asyncio.StreamReader(limit=2048)
        reader.feed_data(payload)
        if eof:
            reader.feed_eof()
        output = bytearray()
        class Writer:
            def get_extra_info(self, _):
                return object()
            def write(self, value):
                output.extend(value)
            async def drain(self):
                pass
            def close(self):
                pass
            async def wait_closed(self):
                pass
        claims = []
        async def emit(_, request, data):
            if await host.claim(request):
                claims.append(data)
                await host.complete(request, {'status': 'observed', 'steamId': data['steamId'], 'enabled': False})
        host = bridge.Bridge(501, emit)
        host.allow(permission)
        with patch.object(bridge, 'peer_uid', return_value=501):
            await host.handle(reader, Writer())
        import json
        return json.loads(output), claims

    async def test_valid_frame_has_one_observed_reply(self):
        result, claims = await self.exchange(b'{"version":1,"op":"read","steamId":"76561198000000001"}\n')
        self.assertEqual(result['status'], 'observed')
        self.assertFalse(result['enabled'])
        self.assertEqual(len(claims), 1)

    async def test_already_disconnected_and_extra_frames_never_claim(self):
        request = b'{"version":1,"op":"read","steamId":"76561198000000001"}\n'
        for payload, eof in ((request, True), (request + b'{}\n', False)):
            result, claims = await self.exchange(payload, eof=eof)
            self.assertEqual(result['status'], 'unknown')
            self.assertEqual(claims, [])

    async def test_boolean_version_and_unterminated_frame_never_claim(self):
        for payload in (b'{"version":true,"op":"read","steamId":"76561198000000001"}\n',
                        b'{"version":1,"op":"read","steamId":"76561198000000001"}'):
            result, claims = await self.exchange(payload, eof=True)
            self.assertEqual(result['status'], 'unknown')
            self.assertEqual(claims, [])

    async def test_disabled_permission_never_claims(self):
        result, claims = await self.exchange(b'{"version":1,"op":"read","steamId":"76561198000000001"}\n', permission=False)
        self.assertEqual(result['status'], 'unknown')
        self.assertEqual(claims, [])


if __name__ == '__main__':
    unittest.main()
