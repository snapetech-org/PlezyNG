"""Local-only, same-SID overlapped named pipe. Imported only on Windows."""
import asyncio
import ctypes as c
from ctypes import wintypes as w
from bridge import Bridge

k = c.WinDLL('kernel32', use_last_error=True)
a = c.WinDLL('advapi32', use_last_error=True)


def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, list(args)
    return fn


class Overlapped(c.Structure):
    _fields_ = [('Internal', c.c_size_t), ('InternalHigh', c.c_size_t),
                ('Offset', w.DWORD), ('OffsetHigh', w.DWORD), ('hEvent', w.HANDLE)]


class SecurityAttributes(c.Structure):
    _fields_ = [('length', w.DWORD), ('descriptor', w.LPVOID), ('inherit', w.BOOL)]


close_handle = bind(k, 'CloseHandle', w.BOOL, w.HANDLE)
local_free = bind(k, 'LocalFree', w.HANDLE, w.HANDLE)
current_process = bind(k, 'GetCurrentProcess', w.HANDLE)
current_thread = bind(k, 'GetCurrentThread', w.HANDLE)
open_token = bind(a, 'OpenProcessToken', w.BOOL, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE))
open_thread_token = bind(a, 'OpenThreadToken', w.BOOL, w.HANDLE, w.DWORD, w.BOOL, c.POINTER(w.HANDLE))
get_token = bind(a, 'GetTokenInformation', w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD, c.POINTER(w.DWORD))
sid_string = bind(a, 'ConvertSidToStringSidW', w.BOOL, w.LPVOID, c.POINTER(w.LPWSTR))
sddl = bind(a, 'ConvertStringSecurityDescriptorToSecurityDescriptorW', w.BOOL, w.LPCWSTR, w.DWORD, c.POINTER(w.LPVOID), c.POINTER(w.DWORD))
create_pipe = bind(k, 'CreateNamedPipeW', w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD, c.POINTER(SecurityAttributes))
connect_pipe = bind(k, 'ConnectNamedPipe', w.BOOL, w.HANDLE, c.POINTER(Overlapped))
create_event = bind(k, 'CreateEventW', w.HANDLE, w.LPVOID, w.BOOL, w.BOOL, w.LPCWSTR)
read_file = bind(k, 'ReadFile', w.BOOL, w.HANDLE, w.LPVOID, w.DWORD, c.POINTER(w.DWORD), c.POINTER(Overlapped))
write_file = bind(k, 'WriteFile', w.BOOL, w.HANDLE, w.LPVOID, w.DWORD, c.POINTER(w.DWORD), c.POINTER(Overlapped))
get_result = bind(k, 'GetOverlappedResult', w.BOOL, w.HANDLE, c.POINTER(Overlapped), c.POINTER(w.DWORD), w.BOOL)
cancel_io = bind(k, 'CancelIoEx', w.BOOL, w.HANDLE, c.POINTER(Overlapped))
impersonate = bind(a, 'ImpersonateNamedPipeClient', w.BOOL, w.HANDLE)
revert = bind(a, 'RevertToSelf', w.BOOL)
INVALID = c.c_void_p(-1).value


def token_sid(thread=False):
    token = w.HANDLE()
    ok = (open_thread_token(current_thread(), 8, True, c.byref(token)) if thread
          else open_token(current_process(), 8, c.byref(token)))
    if not ok:
        raise PermissionError('token unavailable')
    try:
        needed = w.DWORD()
        get_token(token, 1, None, 0, c.byref(needed))
        if not 0 < needed.value <= 65536:
            raise PermissionError('invalid token size')
        data = c.create_string_buffer(needed.value)
        if not get_token(token, 1, data, len(data), c.byref(needed)):
            raise PermissionError('token unavailable')
        sid = w.LPWSTR()
        if not sid_string(c.cast(data, c.POINTER(w.LPVOID))[0], c.byref(sid)):
            raise PermissionError('SID unavailable')
        try:
            return sid.value
        finally:
            local_free(c.cast(sid, w.LPVOID))
    finally:
        close_handle(token)


async def operation(handle, begin, *, connecting=False):
    """Keep OVERLAPPED/buffer alive until completion, including cancellation."""
    event = create_event(None, True, False, None)
    if not event:
        raise OSError('event unavailable')
    ov = Overlapped(hEvent=event)
    count = w.DWORD()
    pending = False
    try:
        if not begin(c.byref(count), c.byref(ov)):
            error = c.get_last_error()
            if connecting and error == 535:  # ERROR_PIPE_CONNECTED
                return 0
            if error != 997:  # ERROR_IO_PENDING
                raise OSError(error, 'pipe operation failed')
            pending = True
        while pending:
            if get_result(handle, c.byref(ov), c.byref(count), False):
                pending = False
                break
            error = c.get_last_error()
            if error != 996:  # ERROR_IO_INCOMPLETE
                pending = False
                raise OSError(error, 'pipe completion failed')
            await asyncio.sleep(.01)
        return count.value
    finally:
        if pending:
            cancel_io(handle, c.byref(ov))
            # Do not free OVERLAPPED or its caller's buffer until the kernel has
            # finished. Repeated task cancellation must not interrupt cleanup.
            while not get_result(handle, c.byref(ov), c.byref(count), False):
                if c.get_last_error() != 996:
                    break
                try:
                    await asyncio.sleep(.01)
                except asyncio.CancelledError:
                    pass
        close_handle(event)


class PipeWriter:
    def __init__(self, handle, identity):
        self.handle, self.peer_identity = handle, identity
        self.output = bytearray()
        self.closed = False

    def get_extra_info(self, key):
        return self if key == 'socket' else None

    def write(self, data):
        if self.closed or len(self.output) + len(data) > 2048:
            raise ValueError('closed or oversized response')
        self.output.extend(data)

    async def drain(self):
        while self.output:
            data = c.create_string_buffer(bytes(self.output))
            count = await operation(self.handle, lambda n, ov: write_file(self.handle, data, len(self.output), n, ov))
            if count <= 0:
                raise OSError('closed pipe')
            del self.output[:count]

    def close(self):
        self.closed = True

    async def wait_closed(self):
        pass  # The owner retires pending reads before closing the native handle.


class WindowsBridge(Bridge):
    def __init__(self, emit):
        super().__init__(token_sid(), emit)
        self.accept_task = None
        self.stopping = False
        self.workers = set()

    def new_pipe(self, first=False):
        descriptor = w.LPVOID()
        # Protected DACL: only this desktop SID, no inherited Everyone/Network ACEs.
        if not sddl(f'D:P(A;;GA;;;{self.uid})', 1, c.byref(descriptor), None):
            raise PermissionError('pipe ACL unavailable')
        try:
            attrs = SecurityAttributes(c.sizeof(SecurityAttributes), descriptor, False)
            handle = create_pipe('\\\\.\\pipe\\PlezyNG.SteamCloud.' + self.uid,
                                 3 | 0x40000000 | (0x80000 if first else 0),
                                 8, 4, 2048, 2048, 0, c.byref(attrs))
            if handle == INVALID:
                raise OSError('private pipe unavailable')
            return handle
        finally:
            local_free(descriptor)

    async def start(self):
        # FIRST_PIPE_INSTANCE fails closed if a preexisting server owns the name.
        handle = self.new_pipe(first=True)
        self.accept_task = asyncio.create_task(self.accept(handle))

    async def accept(self, handle):
        try:
            while not self.stopping:
                while len(self.workers) >= 3:
                    await asyncio.sleep(.01)
                await operation(handle, lambda _, ov: connect_pipe(handle, ov), connecting=True)
                # Keep an instance alive throughout replacement; no name takeover gap.
                replacement = self.new_pipe()
                task = asyncio.create_task(self.serve_pipe(handle))
                self.workers.add(task)
                task.add_done_callback(self.workers.discard)
                handle = replacement
        finally:
            self.allow(False)
            close_handle(handle)

    async def serve_pipe(self, handle):
        reader = asyncio.StreamReader(limit=2048)
        pump = None
        try:
            # Impersonation identity is available only after the client's first write.
            data = c.create_string_buffer(2048)
            count = await asyncio.wait_for(operation(handle, lambda n, ov: read_file(handle, data, 2048, n, ov)), 2)
            if not count or not impersonate(handle):
                raise PermissionError('pipe client unavailable')
            try:
                identity = token_sid(thread=True)
            finally:
                if not revert():
                    # Never continue under an untrusted impersonation context.
                    import os
                    os._exit(1)
            if identity != self.uid:
                raise PermissionError('wrong user')
            reader.feed_data(data.raw[:count])
            async def read_more():
                received = count
                try:
                    while True:
                        count = await operation(handle, lambda n, ov: read_file(handle, data, 2048, n, ov))
                        if not count:
                            break
                        received += count
                        reader.feed_data(data.raw[:count])
                        # Protocol has one <=2KiB request. Bound buffered extra data.
                        if received > 2048:
                            break
                except OSError:
                    pass
                finally:
                    reader.feed_eof()
            pump = asyncio.create_task(read_more())
            await self.handle(reader, PipeWriter(handle, identity))
            # Let the client consume the buffered reply and close; never flush
            # synchronously (a non-reading peer could block the entire plugin).
            await asyncio.wait_for(asyncio.shield(pump), 1)
        except (Exception, asyncio.CancelledError):
            pass
        finally:
            if pump:
                pump.cancel()
                await asyncio.gather(pump, return_exceptions=True)
            close_handle(handle)

    async def close(self):
        self.stopping = True
        if self.accept_task:
            self.accept_task.cancel()
            await asyncio.gather(self.accept_task, return_exceptions=True)
        self.allow(False)
        for task in list(self.workers):
            task.cancel()
        await asyncio.gather(*self.workers, return_exceptions=True)
        await super().close()
