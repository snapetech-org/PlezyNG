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
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_native.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';
import '../../services/gamepad_service.dart';
import '../../services/playback_coordinator.dart';

class RommNativePlayerScreen extends StatefulWidget {
  const RommNativePlayerScreen({super.key, required this.controller, required this.game, required this.core, this.resume = true});
  final RommController controller;
  final RommGame game;
  final String core;
  final bool resume;
  @override State<RommNativePlayerScreen> createState() => _RommNativePlayerScreenState();
}
class _RommNativePlayerScreenState extends State<RommNativePlayerScreen> with WidgetsBindingObserver {
  final _runtime = RommNative();
  ui.Image? _frame;
  bool _decoding = false, _ready = false, _paused = false, _closing = false, _canPop = false, _touch = false, _capturing = false;
  String _error = '', _lastHash = '';
  final _pads = <String, int>{};
  final _buttons = [0, 0, 0, 0];
  Timer? _autosave;
  Directory? _sessionDirectory;
  bool get live => mounted && widget.controller.current;
  @override void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this); _runtime.addListener(_newFrame);
    widget.controller.addListener(_profile);
    GamepadService.instance.registerWorkspaceInputHandler(this, _input, onNativeKeyEvent: _key, onReset: (_) => _release());
    GamepadService.instance.setWorkspaceInputOwner(this); unawaited(_start());
  }
  void _profile() { if (!widget.controller.current) { _release(); _runtime.pause(true); unawaited(_runtime.shutdown()); } }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _ready) {
      _release(); _runtime.pause(true); _paused = true;
      unawaited(_save().catchError((_) {})); if (mounted) setState(() {});
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
      if (!{'sfc', 'smc', 'gb', 'gbc', 'gba', 'nes', 'bin', 'md', 'gen', 'sms', 'gg'}.contains(extension)) {
        throw const RommFailure('romm.unsupportedArchive');
      }
      final directory = await storage.nativeDirectory(widget.game);
      final rom = await storage.file(widget.game);
      final session = _sessionDirectory = await Directory('${directory.path}/session-${const Uuid().v4()}').create();
      final copy = File('${session.path}/game.$extension');
      // Core APIs receive only a profile-owned immutable copy of verified bytes.
      await rom.copy(copy.path);
      final firmware = await Directory('${directory.path}/system').create(recursive: true);
      if (!live) return;
      await _runtime.start(widget.core, copy.path, firmware.path, directory.path);
      if (!live) { await _runtime.shutdown(); return; }
      if (widget.resume) {
        final sram = await storage.nativeProgress(widget.game, _runtime.identity);
        final state = await storage.nativeProgress(widget.game, _runtime.identity, state: true);
        if (sram != null) await _runtime.restore(sram);
        if (state != null) await _runtime.restore(state, state: true);
        if (sram == null && state == null) await _cloudResume();
      }
      if (!live) return;
      setState(() => _ready = true);
      await widget.controller.played(widget.game);
      _autosave = Timer.periodic(const Duration(seconds: 45), (_) => unawaited(_save().catchError((error) {
        if (live) setState(() => _error = error is RommFailure ? error.code : 'romm.saveFailed');
      })));
    } catch (error) { _runtime.pause(true); if (live) setState(() => _error = error is RommFailure ? error.code : 'romm.nativeError'); }
  }
  Future<void> _cloudResume() async {
    RommGame remote;
    try { remote = await widget.controller.detail(widget.game); } catch (_) { return; } // Offline starts stay available.
    if (!live || remote.identity != widget.game.identity) throw const RommFailure('romm.copyMismatch');
    final engine = 'plezy_libretro_${widget.core}';
    final states = remote.states.where((s) => s.emulator == engine && !s.missing).toList()
      ..sort((a,b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
    final saves = remote.saves.where((s) => s.emulator == engine && !s.missing).toList()
      ..sort((a,b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
    final api = await widget.controller.client(widget.game.connectionId);
    if (states.isNotEmpty) {
      final bytes = await api.saveBytes(states.first);
      const marker = 'PLZYRETRO1\n';
      if (bytes.length <= marker.length || String.fromCharCodes(bytes.take(marker.length)) != marker) throw const RommFailure('romm.coreVersionDifferent');
      final newline = bytes.indexOf(10, marker.length);
      if (newline < 0 || newline > marker.length + 10) throw const RommFailure('romm.invalidFile');
      final length = int.tryParse(String.fromCharCodes(bytes.sublist(marker.length, newline))) ?? 0;
      final offset = newline + 1;
      if (length < 1 || length > 4096 || offset + length >= bytes.length) throw const RommFailure('romm.invalidFile');
      final metadata = rommMap(jsonDecode(utf8.decode(bytes.sublist(offset, offset + length))));
      if (metadata['format'] != 'plezy-libretro-state-v1' || metadata['core'] != _runtime.identity || metadata['rom'] != widget.game.identity) {
        throw const RommFailure('romm.coreVersionDifferent');
      }
      if (!live) return;
      await _runtime.restore(Uint8List.sublistView(bytes, offset + length), state: true);
    } else if (saves.isNotEmpty) {
      final bytes = await api.saveBytes(saves.first); if (live) await _runtime.restore(bytes);
    }
  }
  void _newFrame() {
    final bytes = _runtime.pixels; if (!live || bytes == null || _decoding) return;
    _decoding = true;
    ui.decodeImageFromPixels(bytes, _runtime.width, _runtime.height, ui.PixelFormat.rgba8888, (image) {
      _decoding = false;
      if (!live) { image.dispose(); return; }
      final old = _frame; setState(() => _frame = image); old?.dispose();
    });
  }
  static const _mapping = <GamepadButton, int>{GamepadButton.b: 0, GamepadButton.y: 1, GamepadButton.back: 2,
    GamepadButton.start: 3, GamepadButton.dpadUp: 4, GamepadButton.dpadDown: 5, GamepadButton.dpadLeft: 6,
    GamepadButton.dpadRight: 7, GamepadButton.a: 8, GamepadButton.x: 9, GamepadButton.leftShoulder: 10, GamepadButton.rightShoulder: 11};
  void _input(GamepadEvent event) {
    if (!_ready || _paused) return;
    if (event is GamepadButtonEvent) {
      final port = _pads.putIfAbsent(event.gamepadId.toString(), () => _pads.length);
      final button = _mapping[event.button]; if (port < 4 && button != null) _button(port, button, event.pressed);
    } else if (event is GamepadAxisEvent) {
      final port = _pads.putIfAbsent(event.gamepadId.toString(), () => _pads.length);
      if (port >= 4) return;
      if (event.axis == GamepadAxis.leftStickX) { _button(port, 6, event.value < -0.35); _button(port, 7, event.value > 0.35); }
      if (event.axis == GamepadAxis.leftStickY) { _button(port, 4, event.value < -0.35); _button(port, 5, event.value > 0.35); }
    }
  }
  void _key(KeyEvent event) {
    final key = event.logicalKey, down = event is! KeyUpEvent;
    if ({LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack}.contains(key) && event is KeyDownEvent) { _pause(); return; }
    final button = {LogicalKeyboardKey.arrowUp: 4, LogicalKeyboardKey.arrowDown: 5, LogicalKeyboardKey.arrowLeft: 6,
      LogicalKeyboardKey.arrowRight: 7, LogicalKeyboardKey.keyZ: 0, LogicalKeyboardKey.keyA: 1, LogicalKeyboardKey.shiftRight: 2,
      LogicalKeyboardKey.enter: 3, LogicalKeyboardKey.keyX: 8, LogicalKeyboardKey.keyS: 9, LogicalKeyboardKey.keyQ: 10, LogicalKeyboardKey.keyW: 11}[key];
    if (button != null && !_paused) _button(0, button, down);
  }
  void _button(int port, int button, bool down) {
    if (down) _buttons[port] |= 1 << button; else _buttons[port] &= ~(1 << button);
    _runtime.input(port, _buttons[port]);
  }
  void _release() { for (var port = 0; port < 4; port++) { _buttons[port] = 0; _runtime.input(port, 0); } }
  void _pause() {
    _release(); setState(() => _paused = !_paused); _runtime.pause(_paused);
    if (_paused) GamepadService.instance.releaseWorkspaceInputOwner(this); else GamepadService.instance.setWorkspaceInputOwner(this);
  }
  Future<void> _save({bool state = false}) async {
    if (!_ready || _capturing) { if (_closing) throw const RommFailure('romm.saveInProgress'); return; }
    _capturing = true;
    try {
      final storage = widget.controller.storage;
      final sram = await _runtime.capture(), snapshot = await _runtime.capture(state: true);
      if (!live) return;
      if (sram != null) await storage.keepNativeProgress(widget.game, _runtime.identity, sram);
      if (snapshot != null) await storage.keepNativeProgress(widget.game, _runtime.identity, snapshot, state: true);
      if (sram == null && snapshot == null) throw const RommFailure('romm.saveFailed');
      final bytes = state || sram == null ? snapshot : sram;
      if (bytes == null) throw const RommFailure('romm.saveFailed');
      final hash = sha256.convert(bytes).toString(); if (hash == _lastHash && !state) return;
      final nativeState = state || sram == null;
      // State files carry their own exact core/version/ROM envelope. Browser
      // and streamed cores cannot accidentally interpret these as their states.
      final header = utf8.encode(jsonEncode({'format': 'plezy-libretro-state-v1', 'core': _runtime.identity, 'rom': widget.game.identity}));
      final envelope = BytesBuilder()..add(utf8.encode('PLZYRETRO1\n'))..add(utf8.encode('${header.length}\n'))..add(header)..add(bytes);
      final id = await storage.enqueue(game: widget.game, bytes: nativeState ? envelope.takeBytes() : bytes,
        emulator: 'plezy_libretro_${widget.core}', core: _runtime.identity, state: nativeState, slot: 'autosave');
      _lastHash = hash;
      try { await storage.sync(id); } catch (_) { if (live) setState(() => _error = 'romm.savedLocally'); }
    } finally { _capturing = false; }
  }
  Future<void> _exit(bool save) async {
    if (_closing) return; setState(() => _closing = true);
    _runtime.pause(true); _release();
    try {
      if (save && _ready) await _save(state: true);
      await _runtime.shutdown();
      await _removeSession();
      if (live) { setState(() => _canPop = true); Navigator.pop(context); }
    } catch (error) { if (live) setState(() { _error = error is RommFailure ? error.code : 'romm.saveFailed'; _paused = true; }); }
    finally { if (mounted) setState(() => _closing = false); }
  }
  Future<void> _askExit() async {
    if (_closing) return;
    _runtime.pause(true); _release(); GamepadService.instance.releaseWorkspaceInputOwner(this);
    final save = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(title: Text(rommText(dialog, 'exitConfirm')),
      content: Text(rommText(dialog, 'saveExitHelp')), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(rommText(dialog, 'continue'))),
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(rommText(dialog, 'exitWithoutSaving'))),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(rommText(dialog, 'saveAndExit')))]));
    if (!live) return;
    if (save != null) await _exit(save);
    else { _runtime.pause(_paused); if (!_paused) GamepadService.instance.setWorkspaceInputOwner(this); }
  }
  Widget _touchButton(String label, int id) => Semantics(label: label, button: true, child: Listener(
    onPointerDown: (_) => _button(0, id, true), onPointerUp: (_) => _button(0, id, false), onPointerCancel: (_) => _button(0, id, false),
    child: Container(constraints: const BoxConstraints(minWidth: 52, minHeight: 52), alignment: Alignment.center,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(26)), child: Text(label))));
  Future<void> _removeSession() async {
    final directory = _sessionDirectory; _sessionDirectory = null;
    if (directory != null) { try { await directory.delete(recursive: true); } on FileSystemException { /* A later cleanup may remove an interrupted copy. */ } }
  }
  @override void dispose() {
    unawaited(_runtime.shutdown().then((_) => _removeSession()));
    _autosave?.cancel(); _runtime.removeListener(_newFrame); _runtime.dispose(); _frame?.dispose();
    widget.controller.removeListener(_profile); WidgetsBinding.instance.removeObserver(this);
    GamepadService.instance.unregisterWorkspaceInputHandler(this); super.dispose();
  }
  @override Widget build(BuildContext context) => PopScope(canPop: _canPop, onPopInvokedWithResult: (popped, _) { if (!popped) unawaited(_askExit()); }, child: Scaffold(
    appBar: AppBar(title: Text(isolateDisplayText(widget.game.name)), leading: IconButton(onPressed: _askExit, icon: const Icon(Icons.arrow_back)), actions: [
      IconButton(onPressed: _ready ? _pause : null, tooltip: rommText(context, _paused ? 'continue' : 'pause'), icon: Icon(_paused ? Icons.play_arrow : Icons.pause)),
      IconButton(onPressed: () => setState(() => _touch = !_touch), tooltip: rommText(context, 'touchControls'), icon: const Icon(Icons.gamepad)),
      IconButton(onPressed: !_ready || _closing ? null : () => _save(state: true).catchError((_) { if (live) setState(() => _error = 'romm.saveFailed'); }), tooltip: rommText(context, 'saveState'), icon: const Icon(Icons.save)),
    ]), body: Column(children: [
      if (!_ready || _closing) const LinearProgressIndicator(), if (_error.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(rommText(context, _error))),
      Expanded(child: Center(child: _frame == null ? Text(rommText(context, 'starting')) : RawImage(image: _frame, fit: BoxFit.contain, filterQuality: FilterQuality.none))),
      if (_touch && _ready && !_paused) SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 10, runSpacing: 10, children: [
        for (final entry in {'up': 4, 'down': 5, 'left': 6, 'right': 7, 'select': 2, 'start': 3}.entries) _touchButton(rommText(context, entry.key), entry.value),
        for (final entry in {'B': 0, 'Y': 1, 'A': 8, 'X': 9, 'L': 10, 'R': 11}.entries) _touchButton(entry.key, entry.value),
      ]))),
    ]),
  ));
}
