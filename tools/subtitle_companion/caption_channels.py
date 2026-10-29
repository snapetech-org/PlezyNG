"""Expiring opaque caption transport; never accepts media URLs or executes content.

Channels are memory-only and disappear on restart. The channel token grants
shared read/write access, independently of the companion's administrative token.
AES-GCM encryption and room/copy identity checks remain client responsibilities.
"""
import hashlib
import hmac
import re
import secrets
import threading
import time

NAME = re.compile(r'plezyng-state-v1-([a-f0-9]{24})-[a-f0-9]{32}-[0-9]{16}\.json\Z')
CHANNEL = re.compile(r'[a-f0-9]{32}\Z')
NAMESPACE = re.compile(r'[a-f0-9]{24}\Z')
TOKEN = re.compile(r'[A-Za-z0-9_-]{43}\Z')
MAX_OBJECT = 2 * 1024**2
MAX_CHANNEL_BYTES = 64 * 1024**2
MAX_TOTAL_BYTES = 128 * 1024**2
MAX_FILES = 256
MAX_CHANNELS = 8
LIFETIME = 6 * 3600


class RelayError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class CaptionChannels:
    def __init__(self, closing):
        self.lock = threading.RLock()
        self.channels = {}
        self.closing = closing
        threading.Thread(target=self._expiry, name='caption-channel-expiry', daemon=True).start()

    def _expiry(self):
        while not self.closing.wait(30):
            self.purge()
        with self.lock:
            self.channels.clear()

    def purge(self):
        with self.lock:
            now = time.monotonic()
            for identifier in list(self.channels):
                if self.channels[identifier]['deadline'] <= now:
                    del self.channels[identifier]

    def create(self, scope):
        with self.lock:
            self.purge()
            if len(self.channels) >= MAX_CHANNELS:
                raise RelayError(429, 'caption_channel_limit')
            identifier, token = secrets.token_hex(16), secrets.token_urlsafe(32)
            expiry = int(time.time()) + LIFETIME
            self.channels[identifier] = {'token': hashlib.sha256(token.encode('ascii')).digest(),
                'scope': scope, 'deadline': time.monotonic() + LIFETIME, 'expires': expiry,
                'files': {}, 'bytes': 0}
            return {'version': 1, 'id': identifier, 'token': token, 'expires': expiry,
                    'maxObjectBytes': MAX_OBJECT, 'maxChannelBytes': MAX_CHANNEL_BYTES}

    def revoke(self, identifier, scope):
        with self.lock:
            self.purge()
            channel = self.channels.get(identifier)
            if channel is None or channel['scope'] != scope:
                raise RelayError(404, 'caption_channel_not_found')
            del self.channels[identifier]

    def _authorized(self, identifier, authorization):
        self.purge()
        token = authorization[7:] if authorization.startswith('Bearer ') else ''
        channel = self.channels.get(identifier)
        if not CHANNEL.fullmatch(identifier) or not TOKEN.fullmatch(token) or channel is None or \
                not hmac.compare_digest(channel['token'], hashlib.sha256(token.encode('ascii')).digest()):
            raise RelayError(401, 'caption_channel_expired_or_invalid')
        return channel

    def authorized(self, identifier, authorization):
        with self.lock:
            self._authorized(identifier, authorization)

    def request(self, identifier, authorization, method, namespace=None, name=None, text=None):
        with self.lock:
            channel = self._authorized(identifier, authorization)
            files = channel['files']
            if method == 'GET' and namespace is not None and NAMESPACE.fullmatch(namespace):
                return {'files': sorted(key for key in files if NAME.fullmatch(key).group(1) == namespace),
                        'expires': channel['expires']}
            if not isinstance(name, str) or not NAME.fullmatch(name):
                raise RelayError(400, 'invalid_caption_object_name')
            if method == 'GET':
                if name not in files:
                    raise RelayError(404, 'caption_object_not_found')
                return {'text': files[name].decode('utf-8')}
            if method == 'DELETE':
                previous = files.pop(name, b'')
                channel['bytes'] -= len(previous)
                return {'deleted': True}
            if method != 'PUT' or not isinstance(text, str) or not 0 < len(text) <= MAX_OBJECT:
                raise RelayError(400, 'invalid_caption_object')
            data = text.encode('utf-8')
            if len(data) > MAX_OBJECT:
                raise RelayError(413, 'caption_object_limit')
            # Immutable writes are idempotent only for identical opaque bytes.
            if name in files:
                if files[name] != data:
                    raise RelayError(409, 'caption_object_conflict')
                return {'created': False}
            if len(files) >= MAX_FILES or channel['bytes'] + len(data) > MAX_CHANNEL_BYTES or \
                    sum(c['bytes'] for c in self.channels.values()) + len(data) > MAX_TOTAL_BYTES:
                raise RelayError(507, 'caption_relay_storage_limit')
            files[name] = data
            channel['bytes'] += len(data)
            return {'created': True}
