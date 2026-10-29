import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:universal_gamepad/universal_gamepad.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_capabilities.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_native.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';
import '../../services/gamepad_service.dart';
import '../../services/playback_coordinator.dart';
import '../../utils/platform_detector.dart';

import 'romm_session_page.dart';

class RommNativePlayerScreen extends StatefulWidget {
  const RommNativePlayerScreen({super.key, required this.controller, required this.game, required this.core, this.resume = true, this.stateId, this.saveId});
  final RommController controller;
  final RommGame game;
  final String core;
  final bool resume;
  final int? stateId, saveId;
  @override State<RommNativePlayerScreen> createState() => _RommNativePlayerScreenState();
}
class _RommNativePlayerScreenState extends State<RommNativePlayerScreen> with WidgetsBindingObserver {
  final _runtime = RommNative();
  ui.Image? _frame;
  bool _decoding = false, _ready = false, _paused = false, _closing = false, _canPop = false, _touch = false, _capturing = false;
  String _error = '', _lastHash = '', _copyIdentity = '';
  bool _exitPrompt = false, _retiring = false, _starting = true;
  bool _restoring = false, _recorded = false;
  final _playtime = Stopwatch();
  DateTime? _playStarted;
  final _pads = <int, int>{};
  final _buttons = [0, 0, 0, 0];
  final _axes = [0, 0, 0, 0];
  final _keys = <LogicalKeyboardKey, int>{};
  final _touches = <int, int>{};
  StreamSubscription<GamepadConnectionEvent>? _connections;
  Timer? _autosave;
  Directory? _sessionDirectory;
  bool get live => mounted && widget.controller.current && widget.controller.hasConnection(widget.game.connectionId);
  String get _fileHash => _copyIdentity.substring(5);
  String get _emulator => rommNativeEmulator(widget.core, _fileHash);
  @override void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this); _runtime.addListener(_newFrame);
    widget.controller.retainPlayer(this, widget.game.connectionId);
    widget.controller.addListener(_profile);
    GamepadService.instance.registerWorkspaceInputHandler(this, _input, onNativeKeyEvent: _key,
      onReset: _resetInput, rawTvosControllerInput: true);
    // Keep slots current even while a pause dialog owns navigation input.
    _connections = Gamepad.instance.connectionEvents.listen((event) {
      if (event.connected) return;
      final port = _pads.remove(event.gamepadId);
      if (port != null) { _buttons[port] = 0; _axes[port] = 0; _emitInput(port); }
    }, onError: (Object _) => _release());
    GamepadService.instance.setWorkspaceInputOwner(this); unawaited(_start());
  }
  void _profile() {
    if (live || _retiring) return;
    _retiring = true; _autosave?.cancel(); _release(); _playtime.stop(); _runtime.pause(true);
    GamepadService.instance.releaseWorkspaceInputOwner(this);
    unawaited(_runtime.shutdown());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context); if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _release(); _paused = true; _applyPause();
      GamepadService.instance.releaseWorkspaceInputOwner(this);
      if (_ready) unawaited(_save().catchError((_) {})); if (mounted) setState(() {});
    }
  }
  Future<void> _start() async {
    try {
      await PlaybackCoordinator.instance.claimVideo();
      if (!live) return;
      final storage = widget.controller.storage;
      if (!storage.available(widget.game)) await storage.download(widget.game);
      if (!live) return;
      final name = rommString(storage.downloads[widget.game.key]?['name'], 1024);
      final extension = name.split('.').last.toLowerCase();
      if (!rommNativeCartridge(widget.core, name)) {
        throw const RommFailure('romm.unsupportedArchive');
      }
      final directory = await storage.nativeDirectory(widget.game);
      final rom = await storage.file(widget.game);
      _copyIdentity = 'sha1:${storage.downloads[widget.game.key]!['sha1']}';
      final session = _sessionDirectory = await Directory('${directory.path}/session-${const Uuid().v4()}').create();
      final copy = File('${session.path}/game.$extension');
      // Core APIs receive only a profile-owned immutable copy of verified bytes.
      await rom.copy(copy.path);
      if ((await sha1.bind(copy.openRead()).first).toString() != _fileHash) {
        throw const RommFailure('romm.downloadChanged');
      }
      final firmware = await Directory('${directory.path}/system').create(recursive: true);
      if (!live) return;
      await _runtime.start(widget.core, copy.path, firmware.path, directory.path);
      if (!live || _closing) { await _runtime.shutdown(); return; }
      if (widget.resume && (widget.stateId != null || widget.saveId != null)) {
        await _cloudResume();
      } else if (widget.resume) {
        final snapshot = await storage.nativeSnapshot(widget.game, _runtime.identity, fileHash: _fileHash);
        final sram = snapshot.sram, state = snapshot.state;
        if (sram != null) await _runtime.restore(sram);
        if (state != null) await _runtime.restore(state, state: true);
        if (sram == null && state == null) await _cloudResume();
      }
      if (!live) return;
      setState(() => _ready = true);
      _applyPause();
      try { await widget.controller.played(widget.game); } catch (_) { /* Playback does not depend on history persistence. */ }
      if (!live) return;
      _autosave = Timer.periodic(const Duration(seconds: 45), (_) => unawaited(_save().catchError((error) {
        if (live) setState(() => _error = error is RommFailure ? error.code : 'romm.saveFailed');
      })));
    } catch (error) {
      _playtime.stop(); _runtime.pause(true);
      if (live) setState(() { _ready = false; _paused = true; _error = error is RommFailure ? error.code : 'romm.nativeError'; });
    } finally {
      if (mounted) setState(() => _starting = false);
      if (!live || !_ready) {
        _autosave?.cancel();
        GamepadService.instance.releaseWorkspaceInputOwner(this);
        unawaited(_runtime.shutdown().then((_) => _removeSession()));
      }
    }
  }
  Future<void> _cloudResume() async {
    RommGame remote;
    try { remote = await widget.controller.detail(widget.game); } catch (_) {
      if (widget.stateId != null || widget.saveId != null) rethrow;
      return; // Local-first automatic resume remains available offline.
    }
    if (!live || remote.identity != widget.game.identity) throw const RommFailure('romm.copyMismatch');
    final engine = _emulator;
    final source = widget.controller.connection(widget.game.connectionId);
    final states = remote.states.where((s) => s.userId == source.userId && s.romId == widget.game.id && widget.saveId == null && (widget.stateId == null || s.id == widget.stateId) && s.emulator == engine && !s.missing).toList()
      ..sort((a,b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
    final saves = remote.saves.where((s) => s.userId == source.userId && s.romId == widget.game.id && (widget.saveId == null || s.id == widget.saveId) && s.emulator == engine && !s.missing).toList()
      ..sort((a,b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
    if (widget.stateId != null && states.isEmpty || widget.saveId != null && saves.isEmpty) throw const RommFailure('romm.notFound');
    final api = await widget.controller.client(widget.game.connectionId);
    // A newer SRAM upload must not be hidden by an older cloud save state.
    final useState = states.isNotEmpty && (widget.stateId != null || saves.isEmpty ||
      !(saves.first.updatedAt ?? DateTime(1970)).isAfter(states.first.updatedAt ?? DateTime(1970)));
    if (useState) {
      final bytes = await api.saveBytes(states.first);
      const marker = 'PLZYRETRO1\n';
      if (bytes.length <= marker.length || String.fromCharCodes(bytes.take(marker.length)) != marker) throw const RommFailure('romm.coreVersionDifferent');
      final newline = bytes.indexOf(10, marker.length);
      if (newline < 0 || newline > marker.length + 10) throw const RommFailure('romm.invalidFile');
      final length = int.tryParse(String.fromCharCodes(bytes.sublist(marker.length, newline))) ?? 0;
      final offset = newline + 1;
      if (length < 1 || length > 4096 || offset + length >= bytes.length) throw const RommFailure('romm.invalidFile');
      final metadata = rommMap(jsonDecode(utf8.decode(bytes.sublist(offset, offset + length))));
      if (metadata['format'] != 'plezy-libretro-state-v2' || metadata['core'] != _runtime.identity ||
          metadata['rom'] != widget.game.identity || metadata['file'] != _copyIdentity) {
        throw const RommFailure('romm.coreVersionDifferent');
      }
      if (!live) return;
      final snapshot = Uint8List.sublistView(bytes, offset + length);
      await _runtime.restore(snapshot, state: true);
      await widget.controller.storage.keepNativeProgress(widget.game, _runtime.identity, snapshot, state: true, fileHash: _fileHash);
    } else if (saves.isNotEmpty) {
      final save = saves.first;
      final bytes = await api.saveBytes(save, deviceId: source.deviceId);
      final hash = md5.convert(bytes).toString();
      if (save.hash.isNotEmpty && hash != save.hash) throw const RommFailure('romm.checksumFailed');
      if (!live) return;
      await _runtime.restore(bytes);
      await widget.controller.storage.keepNativeProgress(widget.game, _runtime.identity, bytes, fileHash: _fileHash);
      await widget.controller.storage.rememberSaveBaseline(widget.game, save);
      try { await api.acknowledgeSave(save, source.deviceId, hash); } catch (_) { /* Local progress is already durable; a later upload can surface a conflict. */ }
    }
  }
  void _newFrame() {
    if (live && _runtime.failure.isNotEmpty) {
      _release(); _playtime.stop(); GamepadService.instance.releaseWorkspaceInputOwner(this);
      setState(() { _error = _runtime.failure; _ready = false; _paused = true; });
      return;
    }
    final bytes = _runtime.pixels; if (!live || bytes == null || _decoding) return;
    _decoding = true;
    ui.decodeImageFromPixels(bytes, _runtime.width, _runtime.height, ui.PixelFormat.rgba8888, (image) {
      _decoding = false;
      if (!live) { image.dispose(); return; }
      final old = _frame; setState(() => _frame = image);
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    });
  }
  static const _mapping = <GamepadButton, int>{GamepadButton.b: 0, GamepadButton.y: 1, GamepadButton.back: 2,
    GamepadButton.start: 3, GamepadButton.dpadUp: 4, GamepadButton.dpadDown: 5, GamepadButton.dpadLeft: 6,
    GamepadButton.dpadRight: 7, GamepadButton.a: 8, GamepadButton.x: 9, GamepadButton.leftShoulder: 10, GamepadButton.rightShoulder: 11};
  void _input(GamepadEvent event) {
    if (!_ready || _paused || _closing || !live) return;
    if (event is GamepadButtonEvent && event.button == GamepadButton.guide) {
      if (event.pressed) _pause();
      return;
    }
    if (event is! GamepadButtonEvent && event is! GamepadAxisEvent) return;
    final port = _port(event.gamepadId);
    if (port == null) return;
    if (event is GamepadButtonEvent) {
      final button = _mapping[event.button]; if (button != null) _button(port, button, event.pressed);
    } else if (event is GamepadAxisEvent) {
      if (event.axis == GamepadAxis.leftStickX) {
        _axes[port] = (_axes[port] & ~((1 << 6) | (1 << 7))) |
          (event.value < -0.35 ? 1 << 6 : 0) | (event.value > 0.35 ? 1 << 7 : 0);
      }
      if (event.axis == GamepadAxis.leftStickY) {
        _axes[port] = (_axes[port] & ~((1 << 4) | (1 << 5))) |
          (event.value < -0.35 ? 1 << 4 : 0) | (event.value > 0.35 ? 1 << 5 : 0);
      }
      _emitInput(port);
    }
  }
  int? _port(int id) {
    final assigned = _pads[id]; if (assigned != null) return assigned;
    for (var port = 0; port < 4; port++) {
      if (!_pads.containsValue(port)) { _pads[id] = port; return port; }
    }
    return null;
  }
  void _key(KeyEvent event) {
    if (!_ready || _closing || !live) return;
    final key = event.logicalKey, down = event is! KeyUpEvent;
    if ({LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack}.contains(key) && event is KeyDownEvent) { _pause(); return; }
    final button = {LogicalKeyboardKey.arrowUp: 4, LogicalKeyboardKey.arrowDown: 5, LogicalKeyboardKey.arrowLeft: 6,
      LogicalKeyboardKey.arrowRight: 7, LogicalKeyboardKey.keyZ: 0, LogicalKeyboardKey.keyA: 1, LogicalKeyboardKey.shiftRight: 2,
      LogicalKeyboardKey.enter: 3, LogicalKeyboardKey.keyX: 8, LogicalKeyboardKey.keyS: 9, LogicalKeyboardKey.keyQ: 10, LogicalKeyboardKey.keyW: 11,
      LogicalKeyboardKey.gameButtonA: 8, LogicalKeyboardKey.select: 8, LogicalKeyboardKey.gameButtonB: 0,
      LogicalKeyboardKey.gameButtonX: 9, LogicalKeyboardKey.gameButtonY: 1}[key];
    if (button != null && !_paused) {
      if (down) _keys[key] = button; else _keys.remove(key);
      _emitInput(0);
    }
  }
  void _button(int port, int button, bool down) {
    if (down) _buttons[port] |= 1 << button; else _buttons[port] &= ~(1 << button);
    _emitInput(port);
  }
  void _emitInput(int port) {
    var held = _buttons[port] | _axes[port];
    if (port == 0) { for (final button in [..._keys.values, ..._touches.values]) { held |= 1 << button; } }
    _runtime.input(port, held);
  }
  void _touchInput(int pointer, int button, bool down) {
    if (down && live && _ready && !_paused && !_closing) _touches[pointer] = button;
    else _touches.remove(pointer);
    _emitInput(0);
  }
  void _release() {
    _keys.clear(); _touches.clear();
    for (var port = 0; port < 4; port++) { _buttons[port] = 0; _axes[port] = 0; _runtime.input(port, 0); }
  }
  void _resetInput(WorkspaceGameInputResetReason reason) {
    _release();
    if (live && {WorkspaceGameInputResetReason.windowFocusLost, WorkspaceGameInputResetReason.applicationInactive}.contains(reason)) {
      setState(() => _paused = true); _applyPause();
      GamepadService.instance.releaseWorkspaceInputOwner(this);
    }
  }
  void _applyPause() {
    final paused = !_ready || _paused || _exitPrompt || _closing || _restoring;
    _runtime.pause(paused);
    if (paused) _playtime.stop();
    else { _playStarted ??= DateTime.now(); _playtime.start(); }
  }
  void _pause() {
    if (!_ready || _closing || _exitPrompt || _restoring || !live) return;
    _release(); setState(() => _paused = !_paused); _applyPause();
    if (_paused) GamepadService.instance.releaseWorkspaceInputOwner(this); else GamepadService.instance.setWorkspaceInputOwner(this);
  }
  Future<void> _save({bool state = false, bool allowSramFallback = false}) async {
    if (!_ready || _capturing) { if (_closing || state) throw const RommFailure('romm.saveInProgress'); return; }
    _capturing = true;
    try {
      final storage = widget.controller.storage;
      final progress = await _runtime.captureProgress();
      final sram = progress.sram, snapshot = progress.state;
      if (!live) return;
      if (sram == null && snapshot == null) throw const RommFailure('romm.saveFailed');
      await storage.keepNativeSnapshot(widget.game, _runtime.identity, sram: sram, state: snapshot, fileHash: _fileHash);
      final bytes = state || sram == null ? snapshot ?? (allowSramFallback ? sram : null) : sram;
      if (bytes == null) throw const RommFailure('romm.saveFailed');
      final hash = sha256.convert(bytes).toString(); if (hash == _lastHash && !state) return;
      final nativeState = snapshot != null && (state || sram == null);
      // State files carry their own exact core/version/ROM envelope. Browser
      // and streamed cores cannot accidentally interpret these as their states.
      final header = utf8.encode(jsonEncode({'format': 'plezy-libretro-state-v2', 'core': _runtime.identity, 'rom': widget.game.identity, 'file': _copyIdentity}));
      final envelope = BytesBuilder()..add(utf8.encode('PLZYRETRO1\n'))..add(utf8.encode('${header.length}\n'))..add(header)..add(bytes);
      final id = await storage.enqueue(game: widget.game, bytes: nativeState ? envelope.takeBytes() : bytes,
        emulator: _emulator, core: _runtime.identity, state: nativeState, slot: '$_emulator-autosave', nativeFileHash: _fileHash);
      _lastHash = hash;
      // Exiting waits for durable local bytes, not for network availability.
      unawaited(storage.sync(id).catchError((_) { if (live) setState(() => _error = 'romm.savedLocally'); }));
    } finally { _capturing = false; }
  }
  Future<void> _loadState() async {
    if (!_ready || _capturing || _closing) return;
    _capturing = true; _restoring = true; _release(); _applyPause();
    try {
      final bytes = await widget.controller.storage.nativeProgress(widget.game, _runtime.identity, state: true, fileHash: _fileHash);
      if (bytes == null) throw const RommFailure('romm.noLocalSave');
      if (live) { await _runtime.restore(bytes, state: true); _lastHash = ''; }
    } catch (error) { if (live) setState(() => _error = error is RommFailure ? error.code : 'romm.nativeError'); }
    finally { _capturing = false; _restoring = false; if (live) _applyPause(); }
  }
  Future<void> _exit(bool save) async {
    if (_closing) return; setState(() => _closing = true);
    _applyPause(); _release();
    try {
      if (save && _ready) await _save(state: true, allowSramFallback: true);
      await _runtime.shutdown().timeout(const Duration(seconds: 20));
      await _removeSession();
      unawaited(_recordPlay());
      if (live) { setState(() => _canPop = true); Navigator.pop(context); }
    } catch (error) { if (live) setState(() { _error = error is RommFailure ? error.code : 'romm.saveFailed'; _paused = true; }); }
    finally { if (mounted) setState(() => _closing = false); }
  }
  Future<void> _askExit() async {
    if (_closing || _exitPrompt || !live) return;
    _exitPrompt = true;
    _applyPause(); _release(); GamepadService.instance.releaseWorkspaceInputOwner(this);
    try {
    final save = await rommDialog<bool>(context: context, controller: widget.controller, connectionId: widget.game.connectionId, builder: (dialog) => AlertDialog(title: Text(rommText(dialog, 'exitConfirm')),
      content: Text(rommText(dialog, 'saveExitHelp')), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(rommText(dialog, 'continue'))),
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(rommText(dialog, 'exitWithoutSaving'))),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(rommText(dialog, 'saveAndExit')))]));
    if (!live) return;
    if (save != null) await _exit(save);
    } finally {
      _exitPrompt = false;
      if (live && !_canPop) { _applyPause(); if (!_paused && _ready) GamepadService.instance.setWorkspaceInputOwner(this); }
    }
  }
  Widget _touchButton(String label, int id) => Semantics(label: label, button: true, child: Listener(
    onPointerDown: (event) => _touchInput(event.pointer, id, true), onPointerUp: (event) => _touchInput(event.pointer, id, false), onPointerCancel: (event) => _touchInput(event.pointer, id, false),
    child: Container(constraints: const BoxConstraints(minWidth: 52, minHeight: 52), alignment: Alignment.center,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(26)), child: Text(label))));
  Future<void> _removeSession() async {
    final directory = _sessionDirectory; _sessionDirectory = null;
    if (directory != null) { try { await directory.delete(recursive: true); } on FileSystemException { /* A later cleanup may remove an interrupted copy. */ } }
  }
  Future<void> _recordPlay() async {
    _playtime.stop();
    final start = _playStarted;
    if (_recorded || start == null || !widget.controller.current) return;
    _recorded = true;
    final end = DateTime.now(), duration = _playtime.elapsedMilliseconds;
    try {
      final api = await widget.controller.client(widget.game.connectionId);
      await api.recordPlay(widget.game, widget.controller.connection(widget.game.connectionId).deviceId, start, end, durationMs: duration);
    } catch (_) { /* Metadata cannot hold a saved game open. */ }
  }
  @override void dispose() {
    unawaited(_recordPlay());
    widget.controller.releasePlayer(this);
    unawaited(_connections?.cancel());
    unawaited(_runtime.shutdown().then((_) => _removeSession()));
    _autosave?.cancel(); _runtime.removeListener(_newFrame); _runtime.dispose(); _frame?.dispose();
    widget.controller.removeListener(_profile); WidgetsBinding.instance.removeObserver(this);
    GamepadService.instance.unregisterWorkspaceInputHandler(this); super.dispose();
  }
  @override Widget build(BuildContext context) => PopScope(canPop: _canPop, onPopInvokedWithResult: (popped, _) { if (!popped) unawaited(_askExit()); }, child: Focus(
    autofocus: true,
    descendantsAreFocusable: !_ready || _paused || _closing,
    onKeyEvent: (_, event) {
      // Android bypasses GamepadService's global keyboard handler; Tizen uses
      // its engine's key input. Handle those keys only while gameplay owns focus.
      if (!(Platform.isAndroid || PlatformDetector.isTizenBuild()) || !_ready || _paused || _closing) return KeyEventResult.ignored;
      if (!(Platform.isAndroid && event.deviceType == ui.KeyEventDeviceType.gamepad)) _key(event);
      return KeyEventResult.handled;
    },
    child: Scaffold(
    appBar: AppBar(title: Text(isolateDisplayText(widget.game.name)), leading: IconButton(onPressed: _askExit, icon: const Icon(Icons.arrow_back)), actions: [
      IconButton(onPressed: _ready ? _pause : null, tooltip: rommText(context, _paused ? 'continue' : 'pause'), icon: Icon(_paused ? Icons.play_arrow : Icons.pause)),
      IconButton(onPressed: () { setState(() => _touch = !_touch); if (!_touch) { _touches.clear(); _emitInput(0); } }, tooltip: rommText(context, 'touchControls'), icon: const Icon(Icons.gamepad)),
      IconButton(onPressed: !_ready || _closing ? null : _loadState, tooltip: rommText(context, 'loadState'), icon: const Icon(Icons.restore)),
      IconButton(onPressed: !_ready || _closing ? null : () => _save(state: true).catchError((_) { if (live) setState(() => _error = 'romm.saveFailed'); }), tooltip: rommText(context, 'saveState'), icon: const Icon(Icons.save)),
    ]), body: Column(children: [
      if (_starting || _closing) const LinearProgressIndicator(), if (_error.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(rommText(context, _error))),
      Expanded(child: Center(child: _frame == null ? Text(rommText(context, 'starting')) : AspectRatio(
        aspectRatio: _runtime.aspectRatio > 0 ? _runtime.aspectRatio : _frame!.width / _frame!.height,
        child: RawImage(image: _frame, fit: BoxFit.fill, filterQuality: FilterQuality.none)))),
      if (_touch && _ready && !_paused) SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 10, runSpacing: 10, children: [
        for (final entry in {'up': 4, 'down': 5, 'left': 6, 'right': 7, 'select': 2, 'start': 3}.entries) _touchButton(rommText(context, entry.key), entry.value),
        for (final entry in {'B': 0, 'Y': 1, 'A': 8, 'X': 9, 'L': 10, 'R': 11}.entries) _touchButton(entry.key, entry.value),
      ]))),
    ]),
  )));
}
