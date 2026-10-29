import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_player_proxy.dart';
import '../../games/romm/romm_stream_session.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';
import '../../services/gamepad_service.dart';
import '../../services/playback_coordinator.dart';
import '../../utils/snackbar_helper.dart';
import 'romm_web_surface.dart';

class RommWebPlayerScreen extends StatefulWidget {
  const RommWebPlayerScreen({super.key, required this.controller, required this.game, required this.route,
    this.stateId, this.saveId, this.memoryCardId, this.multiplayer = false, this.joinContainer, this.joinPlatform});
  final RommController controller;
  final RommGame game;
  final RommRoute route;
  final int? stateId, saveId, memoryCardId;
  final bool multiplayer;
  final String? joinContainer, joinPlatform;
  @override State<RommWebPlayerScreen> createState() => _RommWebPlayerScreenState();
}
class _RommWebPlayerScreenState extends State<RommWebPlayerScreen> with WidgetsBindingObserver {
  RommPlayerProxy? _proxy;
  RommStreamSession? _stream;
  Uri? _url;
  String _error = '', _lastCapture = '';
  bool _busy = true, _closing = false, _canPop = false, _capturing = false, _controls = false;
  final _web = GlobalKey<RommWebSurfaceState>();
  Timer? _snapshot;
  final _started = DateTime.now();
  bool get _live => mounted && widget.controller.current;
  bool get _ejs => widget.route.engine == RommEngine.emulatorJs;
  @override void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_sessionChanged);
    // Native gamepad events must not navigate the library behind the webview.
    GamepadService.instance.registerWorkspaceInputHandler(this, (_) {}, onReset: (_) {});
    GamepadService.instance.setWorkspaceInputOwner(this);
    unawaited(_start());
  }
  void _sessionChanged() {
    if (!widget.controller.current) { unawaited(_proxy?.close()); _stream?.dispose(); _stream = null; }
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _ejs) unawaited(_capture().catchError((_) {}));
  }
  Future<void> _start() async {
    try {
      await PlaybackCoordinator.instance.claimVideo();
      if (!_live) return;
      final api = await widget.controller.client(widget.game.connectionId);
      if (!_live) return;
      if (widget.route.engine == RommEngine.stream) {
        final stream = _stream = RommStreamSession(api, () => _live);
        stream.addListener(_streamChanged);
        if (widget.joinContainer != null) {
          await stream.join(widget.joinPlatform!, widget.joinContainer!);
        } else {
          try {
            await stream.start(widget.game, stateId: widget.stateId, saveId: widget.saveId,
              memoryCardId: widget.memoryCardId, multiplayer: widget.multiplayer);
          } on RommFailure catch (failure) {
            if (failure.status != 428 || !_live) rethrow;
            GamepadService.instance.releaseWorkspaceInputOwner(this);
            final choice = await showDialog<String>(context: context, builder: (dialog) => AlertDialog(
              title: Text(rommText(dialog, 'memoryCard')), content: Text(rommText(dialog, failure.code)), actions: [
                TextButton(onPressed: () => Navigator.pop(dialog), child: Text(rommText(dialog, 'cancel'))),
                TextButton(onPressed: () => Navigator.pop(dialog, 'discard'), child: Text(rommText(dialog, 'discardContainerCard'))),
                if (failure.code != 'romm.cardUnreadable') FilledButton(onPressed: () => Navigator.pop(dialog, 'adopt'), child: Text(rommText(dialog, 'adoptCard'))),
              ]));
            if (!_live || choice == null) throw const RommFailure('romm.cancelled');
            GamepadService.instance.setWorkspaceInputOwner(this);
            await stream.start(widget.game, stateId: widget.stateId, saveId: widget.saveId,
              memoryCardId: widget.memoryCardId, multiplayer: widget.multiplayer, cardImport: choice);
          }
        }
        if (_live) await _streamChanged();
      } else {
        RommPlayerProxy? proxy;
        for (var attempt = 0; attempt < 12; attempt++) {
          final candidate = await RommPlayerProxy.start(upstream: api.base, token: api.token,
            port: attempt == 0 ? widget.controller.storage.browserPorts[widget.game.connectionId] ?? 0 : 0, current: () => _live);
          if (!_live) { await candidate.close(); return; }
          try {
            if (await widget.controller.storage.rememberBrowserPort(widget.game.connectionId, candidate.origin.port)) { proxy = candidate; break; }
          } catch (_) { await candidate.close(); rethrow; }
          await candidate.close();
        }
        if (proxy == null) throw const RommFailure('romm.connectionFailed');
        _proxy = proxy;
        if (!_live) { await proxy.close(); return; }
        setState(() { _url = proxy!.bootstrap('/rom/${widget.game.id}/${widget.route.engine.path}'); _busy = false; });
        if (_ejs) _snapshot = Timer.periodic(const Duration(seconds: 45), (_) => unawaited(_capture().catchError((_) {})));
      }
      if (_live) await widget.controller.played(widget.game);
    } catch (error) { if (_live) setState(() { _error = error is RommFailure ? error.code : 'romm.connectionFailed'; _busy = false; }); }
  }
  bool _openingRoom = false;
  Future<void> _streamChanged() async {
    final stream = _stream; if (!_live || stream == null) return;
    if (stream.error.isNotEmpty) setState(() { _error = stream.error; _busy = false; });
    if (stream.room == null || _proxy != null || _openingRoom) return;
    _openingRoom = true;
    try {
      final room = stream.room!;
      // The room is a separate trust boundary: never pass the RomM API token.
      final proxy = await RommPlayerProxy.start(upstream: room.replace(path: '/', query: null), current: () => _live);
      if (!_live) { await proxy.close(); return; }
      _proxy = proxy;
      setState(() { _url = proxy.bootstrap('${room.path}${room.hasQuery ? '?${room.query}' : ''}'); _busy = false; _error = ''; });
    } catch (_) { if (_live) setState(() { _error = 'romm.connectionFailed'; _busy = false; }); }
    finally { _openingRoom = false; }
  }
  Future<void> _capture({bool state = false}) async {
    if (!_live || !_ejs || _capturing || _web.currentState == null) return;
    _capturing = true;
    try {
      final raw = await _web.currentState!.evaluate('''(() => {
        const e = window.EJS_emulator, g = e && e.gameManager;
        if (!g || !window.EJS_core) return null;
        const value = ${state ? 'g.getState()' : 'g.getSaveFile(true)'};
        if (!value) return null;
        const a = new Uint8Array(value.buffer || value, value.byteOffset || 0, value.byteLength);
        if (!a.length || a.length > 33554432) return null;
        let s = ''; for (let i=0;i<a.length;i+=16384) s += String.fromCharCode(...a.subarray(i,i+16384));
        return JSON.stringify({core:String(window.EJS_core),bytes:btoa(s)});
      })()''');
      if (!_live) return;
      final data = rommMap(raw is String ? jsonDecode(raw) : raw);
      final encoded = rommString(data['bytes'], 48 * 1024 * 1024);
      if (encoded.isEmpty) {
        if (state) throw const RommFailure('romm.saveFailed');
        return;
      }
      if (!state && encoded == _lastCapture) return;
      final core = rommString(data['core'], 100);
      if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(core)) throw const RommFailure('romm.saveFailed');
      final saves = widget.game.saves.where((s) => s.emulator == core && s.slot == 'autosave').toList()
        ..sort((a,b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
      final id = await widget.controller.storage.enqueue(game: widget.game,
        bytes: Uint8List.fromList(base64Decode(encoded)), emulator: core, core: core, state: state, slot: 'plezy-backup',
        baseHash: saves.firstOrNull?.hash ?? '');
      if (!state) _lastCapture = encoded;
      // The fsynced local version survives a failed upload and a profile switch.
      try { await widget.controller.storage.sync(id); } catch (_) {
        if (_live && _closing) showSnackBar(context, rommText(context, 'savedLocally'));
      }
    } finally { _capturing = false; }
  }
  Future<void> _finish(bool save) async {
    if (_closing || !_live) return;
    setState(() { _closing = true; _error = ''; });
    try {
      if (_stream != null) await _stream!.finish(save: save);
      else if (save && _ejs) {
        if (_capturing) throw const RommFailure('romm.saveInProgress');
        // State snapshot also preserves games without battery-backed SRAM.
        await _capture(state: true); await _capture();
      }
      if (!_live) return;
      try {
        final api = await widget.controller.client(widget.game.connectionId);
        await api.recordPlay(widget.game, widget.controller.connection(widget.game.connectionId).deviceId, _started, DateTime.now());
      } catch (_) { /* Save completion is independent of playtime bookkeeping. */ }
      if (_live) { setState(() => _canPop = true); Navigator.pop(context); }
    } catch (error) { if (_live) setState(() => _error = error is RommFailure ? error.code : 'romm.saveFailed'); }
    finally { if (_live) setState(() => _closing = false); }
  }
  Future<void> _askExit() async {
    if (_closing || !_live) return;
    GamepadService.instance.releaseWorkspaceInputOwner(this);
    await _web.currentState?.visible(false);
    if (!_live) return;
    final result = await showDialog<String>(context: context, builder: (dialog) => AlertDialog(
      title: Text(rommText(dialog, 'exitConfirm')), content: Text(rommText(dialog, _ejs || _stream != null ? 'saveExitHelp' : 'browserSaveHelp')),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(rommText(dialog, 'continue'))),
        TextButton(onPressed: () => Navigator.pop(dialog, 'discard'), child: Text(rommText(dialog, _ejs || _stream != null ? 'exitWithoutSaving' : 'savedClose'))),
        if (_ejs || _stream != null) FilledButton(onPressed: () => Navigator.pop(dialog, 'save'), child: Text(rommText(dialog, 'saveAndExit')))]));
    if (!_live) return;
    await _web.currentState?.visible(true);
    GamepadService.instance.setWorkspaceInputOwner(this);
    if (result != null) await _finish(result == 'save');
  }
  Future<void> _command(String action, Map<String, Object?> body) async {
    try { await _stream!.command(action, body); }
    catch (error) { if (_live) showErrorSnackBar(context, rommText(context, error is RommFailure ? error.code : 'connectionFailed')); }
  }
  @override void dispose() {
    widget.controller.removeListener(_sessionChanged); WidgetsBinding.instance.removeObserver(this);
    GamepadService.instance.unregisterWorkspaceInputHandler(this);
    _snapshot?.cancel(); _stream?.dispose(); unawaited(_proxy?.close()); super.dispose();
  }
  @override Widget build(BuildContext context) {
    final stream = _stream;
    final config = widget.controller.capabilities[widget.game.connectionId]?.streams.where((s) => s['platform'] == stream?.platform).firstOrNull;
    final cap = rommMap(config?['capabilities']);
    return PopScope(canPop: _canPop, onPopInvokedWithResult: (popped, _) { if (!popped) unawaited(_askExit()); }, child: Scaffold(
      appBar: AppBar(title: Text(isolateDisplayText(widget.game.name), maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(onPressed: _closing ? null : _askExit, tooltip: rommText(context, 'close'), icon: const Icon(Icons.arrow_back)),
        actions: [IconButton(onPressed: () => setState(() => _controls = !_controls), tooltip: rommText(context, 'controls'), icon: const Icon(Icons.sports_esports))]),
      body: Column(children: [
        if (_busy || _closing) const LinearProgressIndicator(),
        if (_error.isNotEmpty) MaterialBanner(content: Text(rommText(context, _error)), actions: [TextButton(
          onPressed: stream == null ? () => setState(() => _error = '') : stream.poll, child: Text(rommText(context, 'retry')))]),
        if (_controls) SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          if (_ejs) TextButton(onPressed: _closing ? null : () => _capture(state: true).catchError((_) { if (_live) showErrorSnackBar(context, rommText(context, 'saveFailed')); }), child: Text(rommText(context, 'saveState'))),
          if (stream?.owned == true && config?['supports_live_states'] == true)
            for (var slot = 1; slot <= rommInt(cap['max_slots']).clamp(0, 10); slot++) ...[
              TextButton(onPressed: () => _command('save-state', {'slot': slot}), child: Text('${rommText(context, 'saveState')} $slot')),
              TextButton(onPressed: () => _command('load-state', {'slot': slot}), child: Text('${rommText(context, 'loadState')} $slot'))],
          if (stream?.owned == true && cap['supports_disc_swap'] == true)
            for (final file in widget.game.files) TextButton(onPressed: () => _command('swap-disc', {'file_id': file.id}), child: Text('${rommText(context, 'disc')}: ${isolateDisplayText(file.name)}')),
          TextButton(onPressed: _closing ? null : _askExit, child: Text(rommText(context, 'close'))),
        ])),
        Expanded(child: _url == null ? Center(child: Text(rommText(context, _stream == null ? 'starting' : 'connectingStream')))
          : RommWebSurface(key: _web, url: _url!, partition: '${widget.controller.profileId}:${widget.game.connectionId}', permits: (uri) => _proxy?.permits(uri) == true,
              onError: () { if (_live) setState(() => _error = 'romm.connectionFailed'); })),
      ]),
    ));
  }
}
