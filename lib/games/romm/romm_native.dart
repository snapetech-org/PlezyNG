import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'romm_capabilities.dart';
import 'romm_models.dart';

class _RetroBindings {
  _RetroBindings() : library = DynamicLibrary.open(Platform.isWindows ? '${p.dirname(Platform.resolvedExecutable)}/plezy_retro.dll' : Platform.isMacOS ? '${p.dirname(Platform.resolvedExecutable)}/../Frameworks/PlezyRetro.framework/PlezyRetro' : Platform.isIOS ? '${p.dirname(Platform.resolvedExecutable)}/Frameworks/PlezyRetro.framework/PlezyRetro' : Platform.isLinux ? '${p.dirname(Platform.resolvedExecutable)}/lib/libplezy_retro.so' : 'libplezy_retro.so');
  final DynamicLibrary library;
  late final alloc = library.lookupFunction<Pointer<Uint8> Function(Int32), Pointer<Uint8> Function(int)>('plezy_retro_alloc');
  late final free = library.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('plezy_retro_free');
  late final has = library.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>('plezy_retro_has_core');
  late final open = library.lookupFunction<Int32 Function(Pointer<Uint8>,Pointer<Uint8>,Pointer<Uint8>,Pointer<Uint8>), int Function(Pointer<Uint8>,Pointer<Uint8>,Pointer<Uint8>,Pointer<Uint8>)>('plezy_retro_open');
  late final close = library.lookupFunction<Void Function(), void Function()>('plezy_retro_close');
  late final run = library.lookupFunction<Void Function(), void Function()>('plezy_retro_run');
  late final fps = library.lookupFunction<Double Function(), double Function()>('plezy_retro_fps');
  late final identity = library.lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>('plezy_retro_identity');
  late final width = library.lookupFunction<Int32 Function(), int Function()>('plezy_retro_width');
  late final height = library.lookupFunction<Int32 Function(), int Function()>('plezy_retro_height');
  late final frame = library.lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>('plezy_retro_frame');
  late final buttons = library.lookupFunction<Void Function(Int32,Int32), void Function(int,int)>('plezy_retro_buttons');
  late final pauseAudio = library.lookupFunction<Void Function(Int32), void Function(int)>('plezy_retro_pause_audio');
  late final capture = library.lookupFunction<Int32 Function(Int32), int Function(int)>('plezy_retro_capture');
  late final snapshot = library.lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>('plezy_retro_snapshot');
  late final restore = library.lookupFunction<Int32 Function(Pointer<Uint8>,Int32,Int32), int Function(Pointer<Uint8>,int,int)>('plezy_retro_restore');
  Pointer<Uint8> string(String value) {
    final bytes = utf8.encode(value); final ptr = alloc(bytes.length + 1);
    if (ptr == nullptr) throw const RommFailure('romm.nativeError');
    ptr.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]); return ptr;
  }
  String get coreIdentity {
    final ptr = identity(); var size = 0;
    if (ptr == nullptr) return '';
    while (size < 512 && ptr[size] != 0) { size++; }
    return utf8.decode(ptr.asTypedList(size), allowMalformed: true);
  }
}
String _corePath(String core) {
  if (!rommNativeCorePlatforms.containsKey(core)) throw const RommFailure('romm.nativeUnavailable');
  if (Platform.operatingSystem == 'tizen') return '${core}_libretro.so';
  if (Platform.isAndroid) return 'lib${core}_libretro.so';
  final root = p.dirname(Platform.resolvedExecutable);
  if (Platform.isMacOS) return '$root/../Frameworks/${core}_libretro.framework/${core}_libretro';
  if (Platform.isIOS) return '$root/Frameworks/${core}_libretro.framework/${core}_libretro';
  return '$root/${Platform.isWindows ? '' : 'lib/'}${core}_libretro.${Platform.isWindows ? 'dll' : 'so'}';
}

/// Emulation and serialization run on one worker isolate; no core callbacks
/// enter Flutter. Frame delivery is acknowledged to bound the render queue.
class RommNative extends ChangeNotifier {
  SendPort? _commands;
  Isolate? _worker;
  final _events = ReceivePort();
  final _pending = <int, Completer<Object?>>{};
  int _sequence = 0;
  Uint8List? pixels;
  int width = 0, height = 0;
  String identity = '';
  String failure = '';
  bool _closed = false, _retired = false, _ownsLease = false;
  bool _closeRequested = false;
  Future<void>? _shutdown;
  final _closedSignal = Completer<void>();
  Future<void> get whenClosed => _closedSignal.future;
  static bool _leased = false;
  static Future<Set<String>> available() async {
    try {
      final api = _RetroBindings(), result = <String>{};
      for (final core in rommNativeCorePlatforms.keys) {
        final path = api.string(_corePath(core));
        try { if (api.has(path) == 1) result.add(core); } finally { api.free(path); }
      }
      return result;
    } catch (_) { return {}; }
  }
  Future<void> start(String core, String rom, String system, String saves) async {
    if (_closed || _retired || _ownsLease) throw const RommFailure('romm.cancelled');
    if (_leased) throw const RommFailure('romm.busy');
    _leased = true; _ownsLease = true;
    final ready = Completer<void>();
    _events.listen((event) {
      final row = rommMap(event);
      if (row['port'] is SendPort) { _commands = row['port'] as SendPort; if (_retired) _requestClose(); }
      if (row['ready'] == true) { identity = rommString(row['identity'], 512); if (!ready.isCompleted) ready.complete(); }
      if (row['error'] == true && row['id'] == null) {
        if (!ready.isCompleted) ready.completeError(const RommFailure('romm.nativeError'));
        else if (!_closed && !_retired) { failure = 'romm.nativeError'; notifyListeners(); }
      }
      if (row['pixels'] is TransferableTypedData) {
        if (!_closed && !_retired) {
          pixels = (row['pixels'] as TransferableTypedData).materialize().asUint8List();
          width = rommInt(row['width']); height = rommInt(row['height']); notifyListeners();
        }
        _commands?.send({'action': 'frameAck'});
      }
      final id = row['id']; if (id is int) {
        final pending = _pending.remove(id);
        if (row['error'] == true) pending?.completeError(const RommFailure('romm.nativeError'));
        else pending?.complete(row['data']);
      }
      if (row['closed'] == true) {
        if (!ready.isCompleted) ready.completeError(const RommFailure('romm.cancelled'));
        _finishShutdown();
      }
    });
    try {
      _worker = await Isolate.spawn(_retroWorker, {'port': _events.sendPort, 'core': _corePath(core), 'rom': rom, 'system': system, 'saves': saves});
      await ready.future.timeout(const Duration(seconds: 30));
    } catch (_) {
      if (_worker == null) { if (!ready.isCompleted) ready.complete(); _finishShutdown(); }
      unawaited(shutdown()); rethrow;
    }
  }
  Future<Object?> _request(String action, [Map<String, Object?> args = const {}]) {
    if (_closed || _retired || _commands == null) throw const RommFailure('romm.nativeError');
    final id = ++_sequence, result = Completer<Object?>(); _pending[id] = result;
    _commands!.send({'id': id, 'action': action, ...args});
    return result.future.timeout(const Duration(seconds: 15)).whenComplete(() => _pending.remove(id));
  }
  void input(int port, int buttons) { if (!_closed && !_retired) _commands?.send({'action': 'input', 'port': port, 'buttons': buttons}); }
  void pause(bool paused) { if (!_closed && !_retired) _commands?.send({'action': 'pause', 'paused': paused}); }
  Future<Uint8List?> capture({bool state = false}) async {
    final data = await _request('capture', {'state': state});
    return data is TransferableTypedData ? data.materialize().asUint8List() : null;
  }
  Future<({Uint8List? sram, Uint8List? state})> captureProgress() async {
    final data = rommMap(await _request('captureProgress'));
    Uint8List? bytes(Object? value) => value is TransferableTypedData ? value.materialize().asUint8List() : null;
    return (sram: bytes(data['sram']), state: bytes(data['state']));
  }
  Future<void> restore(Uint8List bytes, {bool state = false}) async {
    await _request('restore', {'bytes': TransferableTypedData.fromList([bytes]), 'state': state});
  }
  Future<void> shutdown() => _shutdown ??= _stop();
  Future<void> _stop() async {
    if (_closed) return;
    _retired = true;
    if (!_ownsLease) { _finishShutdown(); return; }
    _requestClose();
    // Caller-owned UI deadlines never authorize deleting a live core's files.
    // A late worker port also receives close, and the lease survives until ack.
    await whenClosed;
  }
  void _requestClose() {
    if (_closed || _closeRequested || _commands == null) return;
    _closeRequested = true; _commands!.send({'action': 'close'});
  }
  void _finishShutdown() {
    if (_closed) return;
    _closed = true; _retired = true;
    if (_ownsLease) { _leased = false; _ownsLease = false; }
    _events.close();
    for (final result in _pending.values) { if (!result.isCompleted) result.completeError(const RommFailure('romm.cancelled')); }
    _pending.clear(); _worker = null;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
  }
  @override void dispose() { unawaited(shutdown()); super.dispose(); }
}
void _retroWorker(Map<String, Object?> args) {
  final out = args['port'] as SendPort, input = ReceivePort();
  out.send({'port': input.sendPort});
  _RetroBindings? api;
  bool opened = false;
  Timer? clock;
  bool framePending = false, paused = true;
  try {
    final binding = api = _RetroBindings();
    final strings = <Pointer<Uint8>>[];
    int result;
    try {
      for (final key in ['core', 'rom', 'system', 'saves']) { strings.add(binding.string(args[key] as String)); }
      result = binding.open(strings[0], strings[1], strings[2], strings[3]);
    } finally { for (final ptr in strings) { binding.free(ptr); } }
    if (result != 1) throw const RommFailure('romm.nativeError');
    opened = true;
    out.send({'port': input.sendPort, 'ready': true, 'identity': binding.coreIdentity});
    final interval = Duration(microseconds: (1000000 / binding.fps().clamp(15, 120)).round());
    clock = Timer.periodic(interval, (_) {
      if (paused) return;
      try {
      binding.run();
      final w = binding.width(), h = binding.height(), ptr = binding.frame();
      if (!framePending && ptr != nullptr && w > 0 && h > 0) {
        framePending = true;
        out.send({'width': w, 'height': h, 'pixels': TransferableTypedData.fromList([ptr.asTypedList(w * h * 4)])});
      }
      } catch (_) {
        clock?.cancel(); binding.close(); opened = false;
        out.send({'error': true, 'closed': true}); input.close();
      }
    });
    input.listen((event) {
      final row = rommMap(event), id = row['id'];
      try {
        Object? result;
        switch (row['action']) {
          case 'frameAck': framePending = false;
          case 'pause': paused = row['paused'] == true; binding.pauseAudio(paused ? 1 : 0); for (var port = 0; port < 4; port++) { binding.buttons(port, 0); }
          case 'input': binding.buttons(rommInt(row['port']), rommInt(row['buttons']));
          case 'capture':
            final size = binding.capture(row['state'] == true ? 1 : 0);
            if (size > 0) result = TransferableTypedData.fromList([binding.snapshot().asTypedList(size)]);
          case 'captureProgress':
            final progress = <String, Object?>{};
            for (final state in [false, true]) {
              final size = binding.capture(state ? 1 : 0);
              if (size > 0) progress[state ? 'state' : 'sram'] = TransferableTypedData.fromList([binding.snapshot().asTypedList(size)]);
            }
            result = progress;
          case 'restore':
            final bytes = (row['bytes'] as TransferableTypedData).materialize().asUint8List();
            final data = binding.alloc(bytes.length);
            if (data == nullptr) throw const RommFailure('romm.nativeError');
            try { data.asTypedList(bytes.length).setAll(0, bytes); if (binding.restore(data, bytes.length, row['state'] == true ? 1 : 0) != 1) throw const RommFailure('romm.nativeError'); }
            finally { binding.free(data); }
          case 'close': clock?.cancel(); binding.close(); out.send({'id': id, 'closed': true}); input.close(); Isolate.exit();
        }
        if (id != null) out.send({'id': id, 'data': result});
      } catch (_) { if (id != null) out.send({'id': id, 'error': true}); }
    });
  } catch (_) { clock?.cancel(); if (opened) api?.close(); out.send({'error': true, 'closed': true}); input.close(); }
}
