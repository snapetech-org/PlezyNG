#!/usr/bin/env python3
"""OverDrive QR token exchange for approved PlezyNG integrations.

Bind to loopback behind an HTTPS reverse proxy. Never embed client secrets in
PlezyNG. This service performs token exchange only; circulation requests use the
patron's scoped bearer token directly. See docs/LENDING_SETUP.md.
"""
import base64
import hashlib
import hmac
import json
import ipaddress
import os
import re
import secrets
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class InvalidRequest(Exception):
    def __init__(self, status=400):
        self.status = status


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def pkce(value):
    return base64.urlsafe_b64encode(hashlib.sha256(value.encode('ascii')).digest()).decode().rstrip('=')


class Gateway:
    def __init__(self, config, exchange=None, clock=time.monotonic):
        self.origin = config['origin'].rstrip('/')
        origin = urlsplit(self.origin)
        if origin.scheme != 'https' or not origin.hostname or origin.username or origin.path or origin.query or origin.fragment:
            raise ValueError('origin must be an HTTPS origin')
        self.client_id = config.get('client_id', '')
        self.secret = config.get('client_secret', '')
        self.code_parameter = config.get('code_parameter', 'code')
        signing_key = config.get('signing_key', '')
        if not isinstance(self.client_id, str) or not isinstance(self.secret, str) or not isinstance(signing_key, str):
            raise ValueError('invalid native OverDrive credentials')
        self.signing_key = signing_key.encode()
        libraries = config.get('libraries', [])
        if not isinstance(libraries, list):
            raise ValueError('libraries must be an array')
        self.libraries = {str(lib['id']): lib for lib in libraries if isinstance(lib, dict) and 'id' in lib}
        for lib in self.libraries.values():
            if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', str(lib['id'])) or not str(lib.get('websiteId', '')).isdigit():
                raise ValueError('invalid library identifiers')
        self.pending = {}
        self.rates = {}
        self.lock = threading.Lock()
        self.clock = clock
        self.exchange = exchange or self._exchange
        title_link = config.get('title_link') or {}
        if not isinstance(title_link, dict):
            raise ValueError('title_link must be an object')
        self.title_link_client_id = title_link.get('client_id', '')
        self.title_link_secret = title_link.get('client_secret', '')
        if not isinstance(self.title_link_client_id, str) or not isinstance(self.title_link_secret, str):
            raise ValueError('invalid Title Link credentials')
        self._title_link_token_value = None
        self._title_link_token_expiry = 0
        self._title_link_token_lock = threading.Lock()

    def _require_native(self):
        if not self.client_id or not self.secret or len(self.signing_key) < 32:
            raise InvalidRequest(503)

    def public_libraries(self):
        allowed = ('id', 'name', 'websiteId', 'libraryId', 'home', 'integration', 'circulation')
        return [{key: lib[key] for key in allowed if key in lib} for lib in self.libraries.values()]

    def rate_limit(self, address):
        with self.lock:
            now = self.clock()
            self.rates = {key: value for key, value in self.rates.items() if now - value[0] < 60}
            start, count = self.rates.get(address, (now, 0))
            if count >= 120 or len(self.rates) >= 10000:
                raise InvalidRequest(429)
            self.rates[address] = (start, count + 1)

    def initiate(self, data):
        self._require_native()
        library = str(data.get('library', ''))
        challenge = data.get('challenge', '')
        if library not in self.libraries or not isinstance(challenge, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', challenge):
            raise InvalidRequest()
        with self.lock:
            now = self.clock()
            self.pending = {key: value for key, value in self.pending.items() if value['expires'] > now}
            if len(self.pending) >= 1000:
                raise InvalidRequest(429)
            identifier, callback_secret = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            self.pending[identifier] = dict(challenge=challenge, callback=callback_secret, library=library, expires=now + 600, code=None)
        callback = f'{self.origin}/callback/{identifier}/{callback_secret}'
        query = dict(redirect_url=callback, abandon_url=callback + '?cancelled=1', error_url=callback + '?failed=1',
                     website_id=str(self.libraries[library]['websiteId']), client_id=self.client_id)
        return dict(id=identifier, authorizeUrl='https://oauth-patron.overdrive.com/device/initiate?' + urlencode(query), expiresIn=600)

    def callback(self, identifier, secret, query):
        with self.lock:
            pending = self.pending.get(identifier)
            if not pending or pending['expires'] <= self.clock() or not hmac.compare_digest(pending['callback'], secret):
                raise InvalidRequest(404)
            if pending.get('received'):
                raise InvalidRequest(409)
            pending['received'] = True
            if query.get('cancelled') or query.get('failed'):
                pending['cancelled'] = True
                return
            # OverDrive documents a 64-character code. Confirm the callback
            # parameter name with the assigned integration before production.
            code = query.get(self.code_parameter, [''])[0]
            if len(code) != 64 or any(ord(character) < 33 or ord(character) > 126 for character in code):
                pending['cancelled'] = True
                raise InvalidRequest()
            pending['code'] = code

    def poll(self, identifier, data):
        self._require_native()
        verifier = data.get('verifier', '')
        if not isinstance(verifier, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43,128}', verifier):
            raise InvalidRequest()
        with self.lock:
            pending = self.pending.get(identifier)
            if not pending or pending['expires'] <= self.clock():
                raise InvalidRequest(410)
            if not hmac.compare_digest(pending['challenge'], pkce(verifier)):
                raise InvalidRequest(403)
            if data.get('cancel') is True or pending.get('cancelled'):
                del self.pending[identifier]
                raise InvalidRequest(410)
            if not pending['code']:
                return 202, {'pending': True}
            # Consume before network exchange: one code can never be replayed.
            del self.pending[identifier]
        return 200, self._tokens(self.exchange('code', {'grant_type': 'authorization_code', 'code': pending['code']}), pending['library'])

    def proof(self, token, library):
        return hmac.new(self.signing_key, json.dumps([library, token], separators=(',', ':')).encode(), hashlib.sha256).hexdigest()

    def _tokens(self, result, library):
        if not isinstance(result.get('access_token'), str) or not result['access_token']:
            raise InvalidRequest(502)
        # Only issue sessions for the requested website and environment.
        scopes = result.get('scope', '').split()
        lib = self.libraries[library]
        required = 'PATRONINT' if lib.get('integration', False) else 'PATRON'
        if f"website:{lib['websiteId']}" not in scopes or required not in scopes:
            raise InvalidRequest(403)
        result = {key: result[key] for key in ('access_token', 'refresh_token', 'expires_in', 'scope', 'token_type') if key in result}
        if result.get('refresh_token'):
            result['refreshProof'] = self.proof(result['refresh_token'], library)
        return result

    def refresh(self, data):
        self._require_native()
        library, token, proof = data.get('library'), data.get('refresh_token'), data.get('refreshProof')
        if library not in self.libraries or not isinstance(token, str) or not isinstance(proof, str):
            raise InvalidRequest()
        if not hmac.compare_digest(proof, self.proof(token, library)):
            raise InvalidRequest(403)
        return self._tokens(self.exchange('refresh', {'grant_type': 'refresh_token', 'refresh_token': token}), library)

    def title_link_find(self, data):
        if not self.title_link_client_id or not self.title_link_secret:
            raise InvalidRequest(503)
        title = data.get('title', '')
        creator = data.get('creator', '')
        isbn = data.get('isbn', '')
        media_type = data.get('mediaType')
        if not isinstance(title, str) or not isinstance(creator, str) or not isinstance(isbn, str):
            raise InvalidRequest()
        title, creator, isbn = title.strip(), creator.strip(), isbn.strip()
        if len(title) > 300 or len(creator) > 200 or len(isbn) > 32:
            raise InvalidRequest()
        if isbn:
            isbn = re.sub(r'[\s-]', '', isbn)
            if not re.fullmatch(r'(?:[0-9]{9}[0-9Xx]|[0-9]{13})', isbn):
                raise InvalidRequest()
        elif not title:
            raise InvalidRequest()
        if media_type not in (None, '', 'ebook', 'audiobook'):
            raise InvalidRequest()
        token = self._title_link_token()
        query = {}
        if isbn:
            query['isbn'] = isbn
        else:
            query['title'] = title
        if creator:
            query['creator'] = creator
        if media_type:
            query['mediaType'] = media_type
        request = Request(
            'https://api.overdrive.com/v1/share/find?' + urlencode(query),
            headers={'Authorization': f'Bearer {token}', 'User-Agent': 'Pleazyng', 'Accept': 'application/json'},
        )
        try:
            with build_opener(NoRedirect()).open(request, timeout=20) as response:
                payload = response.read(65537)
                if len(payload) > 65536:
                    raise InvalidRequest(502)
                result = json.loads(payload)
        except HTTPError as error:
            if error.code == 404:
                return {'found': False}
            raise InvalidRequest(502) from None
        except (OSError, ValueError):
            raise InvalidRequest(502) from None
        if not isinstance(result, dict):
            raise InvalidRequest(502)
        result_title = result.get('title')
        result_type = result.get('mediaType')
        creators = result.get('creators', [])
        share = result.get('shareLink')
        href = share.get('href') if isinstance(share, dict) else None
        target = urlsplit(href) if isinstance(href, str) else None
        query_values = parse_qs(target.query).get('q', []) if target else []
        if (not isinstance(result_title, str) or not result_title.strip() or len(result_title) > 500 or
                result_type not in ('ebook', 'audiobook') or not target or target.scheme != 'https' or
                target.hostname != 'link.overdrive.com' or target.username or target.password or
                target.port not in (None, 443) or target.path != '/share' or
                not query_values or not query_values[0] or len(query_values[0]) > 256):
            raise InvalidRequest(502)
        if not isinstance(creators, list):
            creators = []
        safe_creators = [value.strip()[:200] for value in creators[:10]
                         if isinstance(value, str) and value.strip()]
        return {
            'found': True,
            'title': result_title.strip(),
            'creators': safe_creators,
            'mediaType': result_type,
            'shareLink': {'href': href, 'type': 'text/HTML'},
        }

    def _title_link_token(self):
        if not self.title_link_client_id or not self.title_link_secret:
            raise InvalidRequest(503)
        with self._title_link_token_lock:
            now = time.monotonic()
            if self._title_link_token_value and self._title_link_token_expiry > now + 5:
                return self._title_link_token_value
            basic = base64.b64encode(
                f'{self.title_link_client_id}:{self.title_link_secret}'.encode()
            ).decode()
            request = Request(
                'https://oauth.overdrive.com/token',
                data=urlencode({'grant_type': 'client_credentials'}).encode(),
                headers={
                    'Authorization': f'Basic {basic}',
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'User-Agent': 'Pleazyng',
                    'Accept': 'application/json',
                },
            )
            try:
                with build_opener(NoRedirect()).open(request, timeout=20) as response:
                    payload = response.read(65537)
                    if len(payload) > 65536:
                        raise InvalidRequest(502)
                    result = json.loads(payload)
            except (HTTPError, OSError, ValueError):
                raise InvalidRequest(502) from None
            token = result.get('access_token') if isinstance(result, dict) else None
            scope = result.get('scope', '') if isinstance(result, dict) else ''
            token_type = result.get('token_type', '') if isinstance(result, dict) else ''
            expires = result.get('expires_in', 3600) if isinstance(result, dict) else 0
            if (not isinstance(token, str) or not token or len(token) > 8192 or
                    not isinstance(token_type, str) or token_type.lower() != 'bearer' or
                    'SRCH' not in str(scope).split()):
                raise InvalidRequest(403)
            try:
                lifetime = max(30, min(int(expires), 86400))
            except (TypeError, ValueError):
                lifetime = 3600
            self._title_link_token_value = token
            self._title_link_token_expiry = time.monotonic() + max(5, lifetime - 60)
            return token

    def _exchange(self, endpoint, fields):
        basic = base64.b64encode(f'{self.client_id}:{self.secret}'.encode()).decode()
        request = Request(f'https://oauth-patron.overdrive.com/patrontoken/{endpoint}', data=urlencode(fields).encode(),
                          headers={'Authorization': f'Basic {basic}', 'Content-Type': 'application/x-www-form-urlencoded',
                                   'User-Agent': 'PlezyNG-Lending/1'})
        try:
            with build_opener(NoRedirect()).open(request, timeout=20) as response:
                payload = response.read(65537)
                if len(payload) > 65536:
                    raise InvalidRequest(502)
                return json.loads(payload)
        except (HTTPError, OSError, ValueError):
            raise InvalidRequest(502) from None


def handler(gateway):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(self.server.header_timeout)
            super().setup()

        def handle_one_request(self):
            # A socket idle timeout alone can be defeated by sending one byte at a
            # time. Bound the entire unauthenticated request line/header phase.
            self._header_expired = threading.Event()
            def expire():
                self._header_expired.set()
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            self._header_timer = threading.Timer(self.server.header_timeout, expire)
            self._header_timer.daemon = True
            self._header_timer.start()
            try:
                super().handle_one_request()
            finally:
                self._header_timer.cancel()

        def parse_request(self):
            try:
                return super().parse_request() and not self._header_expired.is_set()
            finally:
                self._header_timer.cancel()

        def log_message(self, *_args):
            pass  # Authorization codes and tokens must not enter access logs.

        def _reply(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'")
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _run(self, post=False):
            try:
                self.connection.settimeout(25)
                # The reverse proxy must preserve Host and limit connections.
                if self.headers.get('Host') != urlsplit(gateway.origin).netloc or self.headers.get('Origin'):
                    raise InvalidRequest(403)
                # Only the loopback proxy may supply the normalized peer IP.
                # The deployment must overwrite, never append, this header.
                peer = ipaddress.ip_address(self.client_address[0])
                address = self.headers.get('X-Real-IP', str(peer)) if peer.is_loopback else str(peer)
                try:
                    address = str(ipaddress.ip_address(address))
                except ValueError:
                    raise InvalidRequest(400) from None
                gateway.rate_limit(address)
                parsed = urlsplit(self.path)
                parts = parsed.path.strip('/').split('/')
                if not post:
                    if parsed.path == '/v1/libraries':
                        return self._reply(200, {'libraries': gateway.public_libraries()})
                    if len(parts) == 3 and parts[0] == 'callback':
                        gateway.callback(parts[1], parts[2], parse_qs(parsed.query))
                        return self._reply(200, {'message': 'Return to PlezyNG to finish signing in.'})
                    raise InvalidRequest(404)
                length = int(self.headers.get('Content-Length', '0'))
                if length <= 0 or length > 16384 or self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                    raise InvalidRequest(400)
                # The small JSON body has a total deadline as well: otherwise
                # a byte arriving before every socket timeout pins a worker.
                expired = threading.Event()
                def expire_body():
                    expired.set()
                    try:
                        self.connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                timer = threading.Timer(self.server.body_timeout, expire_body)
                timer.daemon = True
                timer.start()
                try:
                    payload = self.rfile.read(length)
                finally:
                    timer.cancel()
                if expired.is_set():
                    self.close_connection = True
                    return
                if len(payload) != length:
                    raise InvalidRequest(400)
                data = json.loads(payload)
                if not isinstance(data, dict):
                    raise InvalidRequest()
                if parts == ['v1', 'authorizations']:
                    return self._reply(201, gateway.initiate(data))
                if len(parts) == 4 and parts[:2] == ['v1', 'authorizations'] and parts[3] == 'token':
                    status, result = gateway.poll(parts[2], data)
                    return self._reply(status, result)
                if parts == ['v1', 'refresh']:
                    return self._reply(200, gateway.refresh(data))
                if parts == ['v1', 'title-links']:
                    return self._reply(200, gateway.title_link_find(data))
                raise InvalidRequest(404)
            except InvalidRequest as error:
                self._reply(error.status, {'error': 'Request could not be completed.'})
            except (ValueError, KeyError, TypeError):
                self._reply(400, {'error': 'Invalid request.'})
            except OSError:
                self.close_connection = True

        def do_GET(self):
            self._run()

        def do_POST(self):
            self._run(post=True)
    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16
    header_timeout = 10
    body_timeout = 25

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


if __name__ == '__main__':
    with open(os.environ['PLEZY_LENDING_CONFIG'], encoding='utf-8') as stream:
        config = json.load(stream)
    Server(('127.0.0.1', int(os.environ.get('PORT', '8788'))), handler(Gateway(config))).serve_forever()
