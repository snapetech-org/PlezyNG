/// Private OS IPC for the opt-in Steam UI extension. No TCP or account tokens.
/// Only desktop runtimes load native symbols; mobile/TV use Companion instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

const _limit = 2048;

abstract class _Memory {
  Pointer<Uint8> allocate(int size);
  void release(Pointer pointer);
}

class _Arena {
  _Arena(this.memory);
  final _Memory memory;
  final List<Pointer> _owned = [];
  Pointer<T> alloc<T extends NativeType>(int bytes) {
    final pointer = memory.allocate(bytes);
    if (pointer == nullptr) throw StateError('Native allocation failed');
    _owned.add(pointer);
    return pointer.cast<T>();
  }

  void close() {
    for (final pointer in _owned.reversed) {
      memory.release(pointer);
    }
  }
}

Future<void> _tick(Stopwatch deadline, bool Function() current) async {
  if (!current() || deadline.elapsedMilliseconds >= 8000) throw StateError('Cloud request retired');
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

/// Returns a single bounded JSON line, authenticated against the OS desktop user.
Future<String> desktopCloudRequest(String request, bool Function() current) async {
  final bytes = utf8.encode('$request\n');
  if (bytes.length > _limit || !current()) throw StateError('Invalid Cloud request');
  if (Platform.isWindows) return _Windows().exchange(bytes, current);
  if (Platform.isMacOS) return _Darwin().exchange(bytes, current);
  throw UnsupportedError('Desktop Cloud transport unavailable');
}

class _Windows implements _Memory {
  final k = DynamicLibrary.open('kernel32.dll');
  final a = DynamicLibrary.open('advapi32.dll');
  late final heap = k.lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
  late final heapAlloc = k
      .lookupFunction<Pointer<Uint8> Function(IntPtr, Uint32, IntPtr), Pointer<Uint8> Function(int, int, int)>(
        'HeapAlloc',
      );
  late final heapFree = k.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer), int Function(int, int, Pointer)>(
    'HeapFree',
  );
  late final closeHandle = k.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final error = k.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  late final result = k
      .lookupFunction<
        Int32 Function(IntPtr, Pointer, Pointer<Uint32>, Int32),
        int Function(int, Pointer, Pointer<Uint32>, int)
      >('GetOverlappedResult');
  late final cancel = k.lookupFunction<Int32 Function(IntPtr, Pointer), int Function(int, Pointer)>('CancelIoEx');
  @override
  Pointer<Uint8> allocate(int size) => heapAlloc(heap, 8, size);
  @override
  void release(Pointer pointer) => heapFree(heap, 0, pointer);

  String sid(int process) {
    final arena = _Arena(this);
    var token = 0;
    try {
      final output = arena.alloc<IntPtr>(sizeOf<IntPtr>());
      final open = a
          .lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<IntPtr>), int Function(int, int, Pointer<IntPtr>)>(
            'OpenProcessToken',
          );
      if (open(process, 8, output) == 0) throw StateError('Process identity unavailable');
      token = output.value;
      final get = a
          .lookupFunction<
            Int32 Function(IntPtr, Int32, Pointer, Uint32, Pointer<Uint32>),
            int Function(int, int, Pointer, int, Pointer<Uint32>)
          >('GetTokenInformation');
      final length = arena.alloc<Uint32>(4);
      get(token, 1, nullptr, 0, length);
      if (length.value <= 0 || length.value > 65536) throw StateError('Invalid token');
      final data = arena.alloc<Uint8>(length.value);
      if (get(token, 1, data, length.value, length) == 0) throw StateError('Identity unavailable');
      final convert = a
          .lookupFunction<
            Int32 Function(Pointer, Pointer<Pointer<Uint16>>),
            int Function(Pointer, Pointer<Pointer<Uint16>>)
          >('ConvertSidToStringSidW');
      final text = arena.alloc<Pointer<Uint16>>(sizeOf<IntPtr>());
      if (convert(data.cast<Pointer>().value, text) == 0) throw StateError('SID unavailable');
      try {
        final units = <int>[];
        for (var i = 0; i < 256; i++) {
          final unit = text.value[i];
          if (unit == 0) return String.fromCharCodes(units);
          units.add(unit);
        }
        throw StateError('Invalid SID');
      } finally {
        k.lookupFunction<Pointer Function(Pointer), Pointer Function(Pointer)>('LocalFree')(text.value);
      }
    } finally {
      if (token != 0) closeHandle(token);
      arena.close();
    }
  }

  Future<int> io(
    int handle,
    Pointer<Uint8> buffer,
    int size,
    bool writing,
    Stopwatch deadline,
    bool Function() current,
  ) async {
    final arena = _Arena(this);
    var event = 0;
    var pending = false;
    final ov = arena.alloc<Uint8>(sizeOf<IntPtr>() == 8 ? 32 : 20);
    final count = arena.alloc<Uint32>(4);
    try {
      event = k
          .lookupFunction<IntPtr Function(Pointer, Int32, Int32, Pointer), int Function(Pointer, int, int, Pointer)>(
            'CreateEventW',
          )(nullptr, 1, 0, nullptr);
      if (event == 0) throw StateError('Event unavailable');
      // OVERLAPPED: two ULONG_PTRs, two DWORD offsets, HANDLE hEvent.
      (ov + 2 * sizeOf<IntPtr>() + 8).cast<IntPtr>().value = event;
      final call = k
          .lookupFunction<
            Int32 Function(IntPtr, Pointer, Uint32, Pointer<Uint32>, Pointer),
            int Function(int, Pointer, int, Pointer<Uint32>, Pointer)
          >(writing ? 'WriteFile' : 'ReadFile');
      if (call(handle, buffer, size, count, ov) == 0) {
        if (error() != 997) throw StateError('Pipe IO unavailable');
        pending = true;
      }
      while (pending) {
        if (result(handle, ov, count, 0) != 0) {
          pending = false;
          break;
        }
        if (error() != 996) {
          pending = false;
          throw StateError('Pipe IO failed');
        }
        await _tick(deadline, current);
      }
      return count.value;
    } finally {
      if (pending) {
        cancel(handle, ov);
        // Native OVERLAPPED storage must outlive cancellation completion.
        while (result(handle, ov, count, 0) == 0 && error() == 996) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      if (event != 0) closeHandle(event);
      arena.close();
    }
  }

  Future<String> exchange(List<int> bytes, bool Function() current) async {
    final arena = _Arena(this);
    var handle = -1;
    try {
      final identity = sid(-1); // GetCurrentProcess pseudo-handle.
      final name = '\\\\.\\pipe\\PlezyNG.SteamCloud.$identity'.codeUnits;
      final path = arena.alloc<Uint16>((name.length + 1) * 2);
      path.asTypedList(name.length).setAll(0, name);
      final create = k
          .lookupFunction<
            IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Pointer, Uint32, Uint32, IntPtr),
            int Function(Pointer<Uint16>, int, int, Pointer, int, int, int)
          >('CreateFileW');
      // OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: no delegation.
      handle = create(path, 0xc0000000, 0, nullptr, 3, 0x40110000, 0);
      if (handle == -1) throw StateError('Cloud pipe unavailable');
      final pid = arena.alloc<Uint32>(4);
      final getPid = k.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetNamedPipeServerProcessId',
      );
      if (getPid(handle, pid) == 0) throw StateError('Server identity unavailable');
      final process = k.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
        'OpenProcess',
      )(0x1000, 0, pid.value);
      if (process == 0) throw StateError('Server unavailable');
      try {
        if (sid(process) != identity) throw StateError('Wrong Cloud server user');
      } finally {
        closeHandle(process);
      }
      final deadline = Stopwatch()..start();
      final data = arena.alloc<Uint8>(_limit + 1);
      data.asTypedList(bytes.length).setAll(0, bytes);
      var sent = 0;
      while (sent < bytes.length) {
        if (!current()) throw StateError('Retired Cloud request');
        final count = await io(handle, data + sent, bytes.length - sent, true, deadline, current);
        if (count == 0) throw StateError('Closed Cloud pipe');
        sent += count;
      }
      final response = <int>[];
      while (response.length <= _limit) {
        final count = await io(handle, data, _limit + 1 - response.length, false, deadline, current);
        if (count == 0) throw StateError('Closed Cloud pipe');
        response.addAll(data.asTypedList(count));
        if (response.contains(10)) {
          if (response.length > _limit ||
              response.last != 10 ||
              response.indexOf(10) != response.length - 1 ||
              !current()) {
            throw StateError('Invalid Cloud response');
          }
          return utf8.decode(response);
        }
      }
      throw StateError('Oversized Cloud response');
    } finally {
      if (handle != -1) closeHandle(handle);
      arena.close();
    }
  }
}

class _Darwin implements _Memory {
  final c = DynamicLibrary.process();
  late final calloc = c.lookupFunction<Pointer<Uint8> Function(IntPtr, IntPtr), Pointer<Uint8> Function(int, int)>(
    'calloc',
  );
  late final free = c.lookupFunction<Void Function(Pointer), void Function(Pointer)>('free');
  @override
  Pointer<Uint8> allocate(int size) => calloc(1, size);
  @override
  void release(Pointer pointer) => free(pointer);

  Future<String> exchange(List<int> bytes, bool Function() current) async {
    final arena = _Arena(this);
    var fd = -1;
    final close = c.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    final errno = c.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__error');
    try {
      final uid = c.lookupFunction<Uint32 Function(), int Function()>('geteuid')();
      final path = utf8.encode('/tmp/plezyng-steam-cloud-$uid/plezyng-steam-cloud.sock');
      if (path.length >= 104) throw StateError('Invalid socket path');
      final address = arena.alloc<Uint8>(106);
      address[0] = 106; // Darwin sockaddr_un.sun_len
      address[1] = 1; // AF_UNIX
      (address + 2).asTypedList(path.length).setAll(0, path);
      fd = c.lookupFunction<Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket')(1, 1, 0);
      if (fd < 0) throw StateError('Socket unavailable');
      // Nonblocking IO; no SIGPIPE if the plugin retires the connection.
      final fcntl = c.lookupFunction<Int32 Function(Int32, Int32, VarArgs<(Int32,)>), int Function(int, int, int)>(
        'fcntl',
      );
      if (fcntl(fd, 4, 4) < 0 || fcntl(fd, 2, 1) < 0) {
        throw StateError('Nonblocking private socket unavailable');
      }
      final flag = arena.alloc<Int32>(4)..value = 1;
      if (c.lookupFunction<
            Int32 Function(Int32, Int32, Int32, Pointer, Uint32),
            int Function(int, int, int, Pointer, int)
          >('setsockopt')(fd, 0xffff, 0x1022, flag, 4) <
          0) {
        throw StateError('Socket protection unavailable');
      }
      final deadline = Stopwatch()..start();
      final connect = c.lookupFunction<Int32 Function(Int32, Pointer, Uint32), int Function(int, Pointer, int)>(
        'connect',
      );
      final status = connect(fd, address, 106);
      if (status < 0) {
        if (errno().value != 36) throw StateError('Cloud socket unavailable'); // EINPROGRESS
        final pollfd = arena.alloc<Uint8>(8);
        pollfd.cast<Int32>().value = fd;
        (pollfd + 4).cast<Int16>().value = 4; // POLLOUT
        final poll = c.lookupFunction<Int32 Function(Pointer, Uint32, Int32), int Function(Pointer, int, int)>('poll');
        while (poll(pollfd, 1, 0) == 0) {
          await _tick(deadline, current);
        }
        final error = arena.alloc<Int32>(4);
        final length = arena.alloc<Uint32>(4)..value = 4;
        if (c.lookupFunction<
                  Int32 Function(Int32, Int32, Int32, Pointer, Pointer<Uint32>),
                  int Function(int, int, int, Pointer, Pointer<Uint32>)
                >('getsockopt')(fd, 0xffff, 0x1007, error, length) !=
                0 ||
            error.value != 0) {
          throw StateError('Cloud connection failed');
        }
      }
      final peer = arena.alloc<Uint32>(4);
      final group = arena.alloc<Uint32>(4);
      if (c.lookupFunction<
                Int32 Function(Int32, Pointer<Uint32>, Pointer<Uint32>),
                int Function(int, Pointer<Uint32>, Pointer<Uint32>)
              >('getpeereid')(fd, peer, group) !=
              0 ||
          peer.value != uid) {
        throw StateError('Wrong Cloud server user');
      }
      final data = arena.alloc<Uint8>(_limit + 1);
      data.asTypedList(bytes.length).setAll(0, bytes);
      final write = c.lookupFunction<IntPtr Function(Int32, Pointer, IntPtr), int Function(int, Pointer, int)>('write');
      var sent = 0;
      while (sent < bytes.length) {
        await _tick(deadline, current);
        final count = write(fd, data + sent, bytes.length - sent);
        if (count < 0 && errno().value == 35) continue; // EAGAIN
        if (count <= 0) throw StateError('Cloud socket write failed');
        sent += count;
      }
      final read = c.lookupFunction<IntPtr Function(Int32, Pointer, IntPtr), int Function(int, Pointer, int)>('read');
      final response = <int>[];
      while (response.length <= _limit) {
        await _tick(deadline, current);
        final count = read(fd, data, _limit + 1 - response.length);
        if (count < 0 && errno().value == 35) continue;
        if (count <= 0) throw StateError('Cloud socket closed');
        response.addAll(data.asTypedList(count));
        if (response.contains(10)) {
          if (response.length > _limit || response.last != 10 || response.indexOf(10) != response.length - 1) {
            throw StateError('Invalid Cloud response');
          }
          return utf8.decode(response);
        }
      }
      throw StateError('Oversized Cloud response');
    } finally {
      if (fd >= 0) close(fd);
      arena.close();
    }
  }
}
