import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../utils/app_logger.dart';

/// Stages Android shares and Apple file-open documents in app-owned storage. Files remain
/// pending until a player can accept them; only subtitle formats and bounded
/// archives are retained.
final class IncomingSubtitleShareService {
  IncomingSubtitleShareService._();

  static final IncomingSubtitleShareService instance = IncomingSubtitleShareService._();
  static final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  static const int _maximumFiles = 12;
  static const int _maximumSubtitleBytes = 32 * 1024 * 1024;
  static const int _maximumArchiveBytes = 50 * 1024 * 1024;
  static const int _maximumPendingBytes = 128 * 1024 * 1024;
  static const Duration _maximumPendingAge = Duration(days: 7);
  static const Set<String> _extensions = {
    'aqt',
    'ass',
    'idx',
    'jss',
    'mks',
    'mpl',
    'scc',
    'smi',
    'srt',
    'ssa',
    'sub',
    'sup',
    'ttml',
    'dfxp',
    'imsc',
    'sami',
    'sbv',
    'lrc',
    'txt',
    'vtt',
    'xml',
    'zip',
    'tar',
    'tgz',
    'gz',
  };

  static const _apple = MethodChannel('com.plezy/subtitle_import');
  bool _pullingApple = false;
  bool _pullAppleAgain = false;
  int _batchSequence = 0;
  StreamSubscription<List<SharedMediaFile>>? _subscription;
  Future<void> _serial = Future<void>.value();
  List<String> _pendingPaths = <String>[];
  int _pendingBytes = 0;
  bool _started = false;

  Future<void> start() async {
    if (_started || !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return;
    _started = true;
    _serial = _serial.then((_) => _restorePending());
    await _serial;
    if (!_started) return;
    if (!Platform.isAndroid) {
      _apple.setMethodCallHandler((call) async {
        if (call.method == 'filesAvailable') {
          await _pullApple();
        } else if (call.method == 'importFailed') {
          appLogger.w('Apple could not stage the opened subtitle document.');
        }
      });
      await _pullApple();
      return;
    }
    _subscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      _enqueue,
      onError: (Object error, StackTrace stackTrace) {
        appLogger.w('Could not receive shared subtitle', error: error, stackTrace: stackTrace);
      },
    );
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      await _enqueue(initial);
      await Future<void>.sync(() => ReceiveSharingIntent.instance.reset());
    } catch (error, stackTrace) {
      appLogger.w('Could not read the initial subtitle share', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _enqueue(List<SharedMediaFile> media) {
    _serial = _serial.then((_) async {
      await _copySharedFiles(media.map((file) => file.path).toList(growable: false));
    }).catchError((Object error, StackTrace stackTrace) {
      appLogger.w('Could not stage shared subtitle files', error: error, stackTrace: stackTrace);
    });
    return _serial;
  }

  Future<void> _pullApple() async {
    if (!_started || !(Platform.isIOS || Platform.isMacOS)) return;
    if (_pullingApple) { _pullAppleAgain = true; return; }
    _pullingApple = true;
    try {
      do {
        _pullAppleAgain = false;
        final raw = await _apple.invokeListMethod<dynamic>('getPendingSubtitleFiles');
        if (!_started) return;
        final files = <String, String>{};
        for (final entry in (raw ?? const []).take(_maximumFiles)) {
          if (entry is! Map) continue;
          final id = entry['id'], path = entry['path'];
          if (id is! String || path is! String || id.length > 255 || path.length > 8192 ||
              id != p.basename(path) || !p.isAbsolute(path) || path.contains('\u0000')) continue;
          files[path] = id;
        }
        _serial = _serial.then((_) async {
          if (!_started) return;
          final accepted = await _copySharedFiles(files.keys.toList(growable: false), apple: true);
          if (accepted.isNotEmpty) {
            await _apple.invokeMethod<void>('acknowledgeSubtitleFiles',
              accepted.map((path) => files[path]!).toList(growable: false));
          }
        }).catchError((Object error, StackTrace stackTrace) {
          appLogger.w('Could not receive opened Apple subtitle files', error: error, stackTrace: stackTrace);
        });
        await _serial;
      } while (_started && _pullAppleAgain);
    } on MissingPluginException {
      // A headless or older Runner may not register the foreground inbox.
    } catch (error, stackTrace) {
      appLogger.w('Could not read the Apple subtitle inbox', error: error, stackTrace: stackTrace);
    } finally {
      _pullingApple = false;
    }
  }

  Future<Directory> _rootDirectory() async {
    final temporary = await getTemporaryDirectory();
    final root = Directory(p.join(temporary.path, 'plezyng_incoming_subtitles'));
    await root.create(recursive: true);
    return root;
  }

  Future<void> _restorePending() async {
    try {
      final root = await _rootDirectory();
      final pendingDirectory = Directory(p.join(root.path, 'pending'));
      await pendingDirectory.create(recursive: true);
      final cutoff = DateTime.now().subtract(_maximumPendingAge);
      final restored = <File>[];
      var bytes = 0;
      await for (final entity in pendingDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (p.extension(entity.path).toLowerCase() == '.part') {
          await entity.delete();
          continue;
        }
        final modified = await entity.lastModified();
        if (modified.isBefore(cutoff)) {
          await entity.delete();
          continue;
        }
        final extension = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
        if (!_extensions.contains(extension) ||
            (extension == 'gz' && !p.basename(entity.path).toLowerCase().endsWith('.tar.gz'))) {
          continue;
        }
        final length = await entity.length();
        final maximum = _isArchiveName(entity.path) ? _maximumArchiveBytes : _maximumSubtitleBytes;
        if (length == 0 || length > maximum || restored.length >= _maximumFiles) continue;
        if (bytes + length > _maximumPendingBytes) continue;
        restored.add(entity);
        bytes += length;
      }
      restored.sort((a, b) => a.path.compareTo(b.path));
      _pendingPaths = restored.map((file) => file.path).toList(growable: true);
      _pendingBytes = bytes;
      pendingCount.value = _pendingPaths.length;
    } catch (error, stackTrace) {
      appLogger.w('Could not restore pending subtitle shares', error: error, stackTrace: stackTrace);
    }
  }

  bool _isArchiveName(String path) {
    final name = p.basename(path).toLowerCase();
    return name.endsWith('.zip') || name.endsWith('.tar') || name.endsWith('.tar.gz') || name.endsWith('.tgz');
  }

  Future<Set<String>> _copySharedFiles(List<String> media, {bool apple = false}) async {
    final accepted = <String>{};
    if (media.isEmpty) return accepted;
    final root = await _rootDirectory();
    final pendingDirectory = Directory(p.join(root.path, 'pending'));
    await pendingDirectory.create(recursive: true);

    final batchPrefix = '${DateTime.now().microsecondsSinceEpoch}_${_batchSequence++}';
    // Give each source stem its own group, preserving IDX/SUB siblings while
    // keeping equal basenames from different folders separate. Duplicate delivery
    // within a batch is idempotent; no destination is ever overwritten.
    final groups = <String, int>{};
    for (final shared in media.take(_maximumFiles)) {
      File? partial;
      try {
        final rawPath = shared.trim();
        if (rawPath.isEmpty || rawPath.length > 8192 || rawPath.contains('\u0000')) continue;
        final uri = Uri.tryParse(rawPath);
        if (uri != null && uri.hasScheme && uri.scheme != 'file') continue;
        final sourcePath = uri?.scheme == 'file' ? uri!.toFilePath() : rawPath;
        final extension = p.extension(sourcePath).toLowerCase().replaceFirst('.', '');
        if (!_extensions.contains(extension) ||
            (extension == 'gz' && !p.basename(sourcePath).toLowerCase().endsWith('.tar.gz'))) {
          continue;
        }

        final originalName = p.basename(sourcePath);
        if (originalName.length > 250) continue;
        final basename = originalName.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        final group = groups.putIfAbsent(p.withoutExtension(sourcePath), () => groups.length);
        final name = apple ? 'apple_$basename' : '${batchPrefix}_${group}_$basename';
        if (name.length > 250) continue;
        final destination = File(p.join(pendingDirectory.path, name));
        final imported = File(p.join(root.path, 'imported', name));
        if (_pendingPaths.contains(destination.path) || (apple && await imported.exists())) {
          accepted.add(shared);
          continue;
        }
        if (_pendingPaths.length >= _maximumFiles || await destination.exists()) continue;
        if (await FileSystemEntity.type(sourcePath, followLinks: false) != FileSystemEntityType.file) continue;
        final source = File(sourcePath);
        final sourceBytes = await source.length();
        final maximum = _isArchiveName(sourcePath) ? _maximumArchiveBytes : _maximumSubtitleBytes;
        if (sourceBytes == 0 || sourceBytes > maximum || _pendingBytes + sourceBytes > _maximumPendingBytes) {
          continue;
        }

        partial = File('${destination.path}.part');
        var copied = 0;
        final sink = partial.openWrite();
        try {
          await for (final chunk in source.openRead()) {
            copied += chunk.length;
            if (copied > maximum || _pendingBytes + copied > _maximumPendingBytes) {
              throw const FormatException('Shared subtitle exceeds the import size limit.');
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (copied != sourceBytes) {
          throw const FormatException('Shared subtitle changed while it was copied.');
        }
        final saved = await partial.rename(destination.path);
        _pendingPaths.add(saved.path);
        _pendingBytes += copied;
        accepted.add(shared);
        pendingCount.value = _pendingPaths.length;
      } catch (error, stackTrace) {
        appLogger.w('Skipped an invalid shared subtitle', error: error, stackTrace: stackTrace);
      } finally {
        try { if (partial != null && await partial.exists()) await partial.delete(); } catch (_) {}
      }
    }
    return accepted;
  }

  /// Atomically clears the pending list and moves its files out of the
  /// restart-restored queue. The active player owns the returned paths.
  Future<List<String>> takeAll() async {
    final result = Completer<List<String>>();
    _serial = _serial.then((_) async {
      try { result.complete(await _takeAll()); }
      catch (error, stackTrace) { result.completeError(error, stackTrace); }
    });
    final paths = await result.future;
    // Freeing capacity admits native documents that were retained while full.
    unawaited(_pullApple());
    return paths;
  }

  Future<List<String>> _takeAll() async {
    final paths = List<String>.of(_pendingPaths);
    _pendingPaths.clear();
    _pendingBytes = 0;
    pendingCount.value = 0;

    if (paths.isEmpty) return paths;
    try {
      final root = await _rootDirectory();
      final usedDirectory = Directory(p.join(root.path, 'imported'));
      await usedDirectory.create(recursive: true);
      final moved = <String>[];
      for (final path in paths) {
        try {
          final file = File(path);
          final target = File(p.join(usedDirectory.path, p.basename(path)));
          moved.add((await file.rename(target.path)).path);
        } catch (error, stackTrace) {
          appLogger.w(
            'Could not move imported subtitle out of the pending queue',
            error: error,
            stackTrace: stackTrace,
          );
          moved.add(path);
        }
      }
      return moved;
    } catch (error, stackTrace) {
      appLogger.w('Could not prepare shared subtitle files for playback', error: error, stackTrace: stackTrace);
      return paths;
    }
  }

  Future<void> dispose() async {
    _started = false;
    if (Platform.isIOS || Platform.isMacOS) _apple.setMethodCallHandler(null);
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
  }
}
