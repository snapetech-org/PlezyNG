import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';

class _SpeechRequest {
  _SpeechRequest(this.owner, this.chunks, this.language, this.rate, this.ended, this.replaced);
  final Object owner;
  final List<String> chunks;
  final String? language;
  final double rate;
  final void Function() ended;
  final void Function()? replaced;
  int index = 0;
  bool cancelled = false, finished = false;
}

/// One serialized owner for the native speech channel. Cancelling a pending
/// request also cancels it before native startup; readers cannot overwrite each
/// other's completion handlers. Text never enters logs or shell arguments.
class SpeechOutputService {
  SpeechOutputService._();
  static final instance = SpeechOutputService._();
  FlutterTts? _tts;
  Process? _linux;
  _SpeechRequest? _requested, _active;
  Future<void> _commands = Future.value();
  static bool get supported => !const bool.fromEnvironment('PLEZY_TIZEN') &&
      !const bool.fromEnvironment('PLEZY_WEBOS') && !const bool.fromEnvironment('TVOS_BUILD');

  Future<void> _enqueue(Future<void> Function() body) {
    final result = _commands.then((_) => body());
    _commands = result.catchError((Object _) {});
    return result;
  }

  Future<void> speak(Object owner, String text, {String? language, double rate = .5,
      required void Function() onEnded, void Function()? onReplaced}) {
    if (!supported) throw UnsupportedError('System speech is unavailable in this build.');
    if (text.isEmpty || text.length > 200000) throw ArgumentError('Speech text must contain 1–200000 characters.');
    final chunks = <String>[];
    for (var offset = 0; offset < text.length;) {
      var end = (offset + 3000).clamp(0, text.length).toInt();
      if (end < text.length) {
        final boundary = text.lastIndexOf(RegExp(r'\s'), end - 1);
        if (boundary > offset + 1500) end = boundary + 1;
        if (text.codeUnitAt(end - 1) >= 0xd800 && text.codeUnitAt(end - 1) <= 0xdbff) end--;
      }
      chunks.add(text.substring(offset, end)); offset = end;
    }
    final request = _SpeechRequest(owner, chunks, language, rate.clamp(.1, 1).toDouble(), onEnded, onReplaced);
    final pending = _requested;
    _requested = request;
    if (pending != null && !identical(pending, _active)) _finish(pending, replaced: !identical(pending.owner, owner));
    return _enqueue(() async {
      if (request.cancelled || !identical(_requested, request)) return;
      final old = _active;
      if (old != null) old.cancelled = true;
      await _stopNative();
      if (old != null) _finish(old, replaced: !identical(old.owner, owner));
      if (request.cancelled || !identical(_requested, request)) return;
      _active = request;
      try { await _chunk(request); } catch (_) { _finish(request); rethrow; }
    });
  }

  Future<void> _chunk(_SpeechRequest request) async {
    if (request.cancelled || !identical(_active, request)) return;
    final text = request.chunks[request.index];
    if (Platform.isLinux) {
      final args = ['-s', '${(80 + request.rate * 280).round()}', '--stdin'];
      final language = request.language;
      if (language != null && RegExp(r'^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$').hasMatch(language)) {
        args.insertAll(0, ['-v', language]);
      }
      Process process;
      try { process = await Process.start(Platform.environment['PLEZY_ESPEAK'] ?? 'espeak-ng', args, runInShell: false); }
      on ProcessException { throw StateError('Install espeak-ng or configure PLEZY_ESPEAK to use spoken subtitles on Linux.'); }
      _linux = process;
      unawaited(process.stdout.drain<void>()); unawaited(process.stderr.drain<void>());
      process.stdin.add(utf8.encode(text)); await process.stdin.close();
      unawaited(process.exitCode.then((code) {
        if (identical(_linux, process)) _linux = null;
        if (request.cancelled || request.finished) return;
        if (code == 0) { _next(request); } else { _finish(request); }
      }));
    } else {
      final tts = _tts ??= FlutterTts();
      tts.setCompletionHandler(() => _next(request));
      tts.setCancelHandler(() => _finish(request));
      tts.setErrorHandler((_) => _finish(request));
      await tts.setSpeechRate(request.rate);
      if (request.language?.isNotEmpty == true) await tts.setLanguage(request.language!);
      if (!request.cancelled && identical(_active, request)) await tts.speak(text);
    }
  }

  void _next(_SpeechRequest request) {
    unawaited(_enqueue(() async {
      if (request.cancelled || request.finished || !identical(_active, request)) return;
      if (++request.index >= request.chunks.length) { _finish(request); return; }
      try { await _chunk(request); } catch (_) { _finish(request); }
    }));
  }
  Future<void> stop(Object owner) {
    final pending = _requested, active = _active;
    if (pending != null && identical(pending.owner, owner)) { pending.cancelled = true; _requested = null; }
    if (active != null && identical(active.owner, owner)) active.cancelled = true;
    return _enqueue(() async {
      if (active != null && identical(active.owner, owner) && identical(_active, active)) {
        await _stopNative(); _finish(active);
      }
      if (pending != null && identical(pending.owner, owner)) _finish(pending);
    });
  }
  Future<void> _stopNative() async {
    final process = _linux; _linux = null;
    if (process != null) { process.kill(ProcessSignal.sigkill); await process.exitCode; }
    // Detach handlers before stop; cancellation must not complete a newer request.
    _tts?.setCompletionHandler(() {}); _tts?.setCancelHandler(() {}); _tts?.setErrorHandler((_) {});
    await _tts?.stop();
  }
  void _finish(_SpeechRequest request, {bool replaced = false}) {
    if (request.finished) return;
    request.finished = true; request.cancelled = true;
    if (identical(_active, request)) _active = null;
    if (identical(_requested, request)) _requested = null;
    scheduleMicrotask(replaced ? request.replaced ?? request.ended : request.ended);
  }
}
