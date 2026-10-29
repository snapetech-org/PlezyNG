import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../utils/app_logger.dart';
import 'subtitle_placement_evidence.dart';
import 'subtitle_inference_scheduler.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';
import 'subtitle_wav_reader.dart';
import 'subtitle_whisper_cpp_service.dart';

enum SubtitleInferenceProvider { cpu, desktopGpu, coreMl, qnn, rknn }

extension SubtitleInferenceProviderName on SubtitleInferenceProvider {
  String get runtimeName => switch (this) {
    SubtitleInferenceProvider.cpu || SubtitleInferenceProvider.desktopGpu => 'cpu',
    SubtitleInferenceProvider.coreMl => 'coreml',
    SubtitleInferenceProvider.qnn => 'qnn',
    SubtitleInferenceProvider.rknn => 'rknn',
  };

  String get displayName => switch (this) {
    SubtitleInferenceProvider.cpu => 'CPU (multilingual Whisper)',
    SubtitleInferenceProvider.desktopGpu => 'Desktop GPU (compiled CUDA/Vulkan)',
    SubtitleInferenceProvider.coreMl => 'Core ML / Apple acceleration request',
    SubtitleInferenceProvider.qnn => 'QNN / Qualcomm NPU request',
    SubtitleInferenceProvider.rknn => 'RKNN / Rockchip NPU request',
  };
}

final class SubtitleTranscriptionResult {
  const SubtitleTranscriptionResult({
    required this.cues,
    required this.durationMs,
    required this.requestedProvider,
    required this.runtimeProvider,
    required this.fellBackToCpu,
    this.placementEvidence = SubtitlePlacementEvidence.unverified,
    required this.detectedLanguage,
    required this.translatedToEnglish,
    this.wordTimings = const <SubtitleWordTiming>[],
  });

  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> wordTimings;
  final int durationMs;
  final SubtitleInferenceProvider requestedProvider;

  /// Provider string accepted while the native recognizer and VAD initialized.
  /// The packaged runtime does not report per-node execution placement.
  final String runtimeProvider;

  final bool fellBackToCpu;
  final SubtitlePlacementEvidence placementEvidence;
  final String detectedLanguage;
  final bool translatedToEnglish;
}

final class SubtitleAiService {
  SubtitleAiService._();

  static final SubtitleAiService instance = SubtitleAiService._();

  static const String _modelId = 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27';
  static const String _modelArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$_modelId.tar.bz2';
  static const int _modelArchiveBytes = 29858559;
  static const String _modelArchiveSha256 = '9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d';
  static const String _vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.int8.onnx';
  static const int _vadBytes = 212860;
  static const String _vadSha256 = 'c36d490aff5ab924ca6c7aeec4d8f6bd3d22db6fa17611b9c5b17eae58ac3a20';
  static const int _maximumExpandedArchiveBytes = 256 * 1024 * 1024;
  static const int _maximumAudioHours = 8;
  static const int _maximumCueCount = 50000;
  static const int _sampleRate = 16000;
  static const bool _tizenBuild = bool.fromEnvironment('PLEZY_TIZEN');
  static const bool _webOsBuild = bool.fromEnvironment('PLEZY_WEBOS');
  static const bool _tvOsBuild = bool.fromEnvironment('TVOS_BUILD');

  static bool get supportedPlatform {
    if (_tizenBuild || _webOsBuild) return SubtitleWhisperCppService.supportedPlatform;
    return !kIsWeb &&
        !_webOsBuild &&
        !_tvOsBuild &&
        (Platform.isAndroid || Platform.isIOS || Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }

  Future<int> readWavDurationMs(String wavPath) => SubtitleWhisperCppService.readWavDurationMs(wavPath);

  static List<SubtitleInferenceProvider> get availableProviderRequests {
    if (_tizenBuild || _webOsBuild) return const [SubtitleInferenceProvider.cpu];
    if (Platform.isAndroid) {
      return const [SubtitleInferenceProvider.cpu, SubtitleInferenceProvider.qnn, SubtitleInferenceProvider.rknn];
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return const [SubtitleInferenceProvider.cpu, SubtitleInferenceProvider.coreMl];
    }
    if (Platform.isWindows || Platform.isLinux) {
      return const [SubtitleInferenceProvider.cpu, SubtitleInferenceProvider.desktopGpu];
    }
    return const [SubtitleInferenceProvider.cpu];
  }

  Future<String> _modelDirectoryPath() async {
    final directory = await getApplicationSupportDirectory();
    return p.join(directory.path, 'subtitle_models', _modelId);
  }

  Future<bool> isModelInstalled() async {
    if (!supportedPlatform) return false;
    try {
      final root = Directory(await _modelDirectoryPath());
      final marker = File(p.join(root.path, 'model.json'));
      if (!await marker.exists()) return false;
      final manifest = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      if (manifest['model'] != _modelId || manifest['archiveSha256'] != _modelArchiveSha256) return false;
      for (final name in const [
        'encoder_model.ort',
        'decoder_model_merged.ort',
        'tokens.txt',
        'silero_vad.int8.onnx',
      ]) {
        final file = File(p.join(root.path, name));
        if (!await file.exists() || await file.length() == 0) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> downloadModel({void Function(String phase, int received, int total)? onProgress}) async {
    if (!supportedPlatform) throw UnsupportedError('Local speech generation is unavailable on this platform.');
    if (await isModelInstalled()) return;

    final targetPath = await _modelDirectoryPath();
    final target = Directory(targetPath);
    final staging = Directory('$targetPath.staging');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    try {
      final archiveBytes = await _downloadVerified(
        _modelArchiveUrl,
        expectedBytes: _modelArchiveBytes,
        expectedSha256: _modelArchiveSha256,
        phase: 'English speech model',
        onProgress: onProgress,
      );
      await Isolate.run(() => _extractMoonshineArchive(archiveBytes, staging.path));

      final vadBytes = await _downloadVerified(
        _vadUrl,
        expectedBytes: _vadBytes,
        expectedSha256: _vadSha256,
        phase: 'Speech detector',
        onProgress: onProgress,
      );
      await File(p.join(staging.path, 'silero_vad.int8.onnx')).writeAsBytes(vadBytes, flush: true);
      await File(p.join(staging.path, 'model.json')).writeAsString(
        jsonEncode({
          'model': _modelId,
          'archiveSha256': _modelArchiveSha256,
          'vadSha256': _vadSha256,
          'language': 'en',
          'task': 'transcribe',
          'downloadedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );

      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(targetPath);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<Uint8List> _downloadVerified(
    String url, {
    required int expectedBytes,
    required String expectedSha256,
    required String phase,
    void Function(String phase, int received, int total)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'PlezyNG subtitle model manager';
      final response = await client.send(request).timeout(const Duration(minutes: 10));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw HttpException('Model server returned HTTP ${response.statusCode}.');
      }
      if (response.contentLength != null && response.contentLength != expectedBytes) {
        await response.stream.drain<void>();
        throw const FormatException('Model download has an unexpected declared size.');
      }

      final output = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > expectedBytes) {
          throw const FormatException('Model download exceeded its pinned size.');
        }
        output.add(chunk);
        onProgress?.call(phase, received, expectedBytes);
      }

      final bytes = output.takeBytes();
      if (bytes.lengthInBytes != expectedBytes || sha256.convert(bytes).toString() != expectedSha256) {
        throw const FormatException('Model checksum verification failed.');
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  /// Checks the chosen installed model without starting a download or inference.
  Future<bool> isProviderModelInstalled(SubtitleInferenceProvider provider) =>
      provider == SubtitleInferenceProvider.cpu || provider == SubtitleInferenceProvider.desktopGpu
          ? SubtitleWhisperCppService.instance.isModelInstalled() : isModelInstalled();

  /// Transcribes the half-open [startMs, endMs) media-time range. A null end
  /// transcribes through the end of the file; output cue times stay on the
  /// original WAV timeline so partial results can merge with existing cues.
  Future<SubtitleTranscriptionResult> transcribeWav(String wavPath, {
    SubtitleInferenceProvider provider = SubtitleInferenceProvider.cpu,
    int startMs = 0, int? endMs, int numThreads = 2, bool translateToEnglish = false,
    bool allowEmpty = false, bool allowModelDownload = true, String? languageCode,
    SubtitleWorkPriority priority = SubtitleWorkPriority.foreground, bool Function()? isCurrent,
    void Function(String phase, int received, int total)? onProgress,
  }) => SubtitleInferenceScheduler.instance.run(() => _transcribeWav(wavPath, provider: provider,
    startMs: startMs, endMs: endMs, numThreads: numThreads, translateToEnglish: translateToEnglish,
    allowEmpty: allowEmpty, allowModelDownload: allowModelDownload, isCurrent: isCurrent,
    languageCode: languageCode, onProgress: onProgress), priority: priority, isCurrent: isCurrent);

  Future<SubtitleTranscriptionResult> _transcribeWav(
    String wavPath, {
    SubtitleInferenceProvider provider = SubtitleInferenceProvider.cpu,
    int startMs = 0,
    int? endMs,
    int numThreads = 2,
    bool translateToEnglish = false,
    bool allowEmpty = false,
    bool allowModelDownload = true,
    bool Function()? isCurrent,
    String? languageCode,
    void Function(String phase, int received, int total)? onProgress,
  }) async {
    if (!supportedPlatform) throw UnsupportedError('Local speech generation is unavailable on this platform.');
    final requested = availableProviderRequests.contains(provider) ? provider : SubtitleInferenceProvider.cpu;
    final rawLanguage = languageCode?.trim().toLowerCase().split(RegExp(r'[-_]')).first;
    final languageOverride = rawLanguage == null || rawLanguage.isEmpty || rawLanguage == 'auto' ? null : rawLanguage;
    if (languageOverride != null && !RegExp(r'^[a-z]{2,3}$').hasMatch(languageOverride)) {
      throw ArgumentError.value(languageCode, 'languageCode', 'Use a two or three letter language code or auto.');
    }
    final durationMs = await SubtitleWhisperCppService.readWavDurationMs(wavPath);
    final rangeEndMs = endMs ?? durationMs;
    if (durationMs <= 0 || durationMs > _maximumAudioHours * 60 * 60 * 1000) {
      throw const FormatException('WAV duration must be between one millisecond and eight hours.');
    }
    if (startMs < 0 || rangeEndMs <= startMs || rangeEndMs > durationMs) {
      throw const FormatException('The selected transcription interval must be inside the WAV duration.');
    }
    if (requested == SubtitleInferenceProvider.cpu || requested == SubtitleInferenceProvider.desktopGpu) {
      final whisperResult = await SubtitleWhisperCppService.instance.transcribeWav(
        wavPath,
        requestGpu: requested == SubtitleInferenceProvider.desktopGpu,
        startMs: startMs,
        endMs: rangeEndMs,
        translateToEnglish: translateToEnglish,
        allowEmpty: allowEmpty, allowModelDownload: allowModelDownload, isCurrent: isCurrent,
        numThreads: numThreads,
        languageCode: languageOverride,
        onProgress: onProgress,
      );
      return SubtitleTranscriptionResult(
        cues: whisperResult.cues,
        durationMs: whisperResult.durationMs,
        requestedProvider: requested,
        runtimeProvider: whisperResult.runtimeProvider,
        fellBackToCpu: whisperResult.fellBackToCpu,
        placementEvidence: whisperResult.placementEvidence,
        detectedLanguage: whisperResult.detectedLanguage,
        translatedToEnglish: whisperResult.translatedToEnglish,
        wordTimings: whisperResult.wordTimings,
      );
    }
    if (languageOverride != null && languageOverride != 'en') {
      throw UnsupportedError('The installed accelerator speech model is English-only; choose English or Auto-detect.');
    }
    if (translateToEnglish) {
      throw UnsupportedError(
        'Speech translation uses the multilingual CPU/GPU Whisper model. Select CPU or desktop GPU.',
      );
    }
    if (!await isModelInstalled()) {
      if (!allowModelDownload) throw StateError('Install the selected speech model in the foreground first.');
      await downloadModel(onProgress: onProgress);
    }
    final root = await _modelDirectoryPath();
    if (isCurrent?.call() == false) throw StateError('Transcription was cancelled.');
    final result = await Isolate.run(
      () => _runSubtitleTranscriptionWorker(
        wavPath: wavPath,
        modelDirectory: root,
        provider: requested.runtimeName,
        numThreads: numThreads.clamp(1, 8).toInt(),
        startMs: startMs,
        endMs: rangeEndMs,
        allowEmpty: allowEmpty,
      ),
    );
    if (isCurrent?.call() == false) throw StateError('Transcription was cancelled.');
    final rawCues = result['cues'] as List<dynamic>;
    final cues = rawCues
        .map((value) {
          final cue = value as Map<dynamic, dynamic>;
          return SubtitleCue(
            index: cue['index'] as int,
            startMs: cue['startMs'] as int,
            endMs: cue['endMs'] as int,
            text: cue['text'] as String,
          );
        })
        .toList(growable: false);
    return SubtitleTranscriptionResult(
      cues: List.unmodifiable(cues),
      durationMs: result['durationMs'] as int,
      requestedProvider: requested,
      runtimeProvider: result['runtimeProvider'] as String,
      fellBackToCpu: result['fellBackToCpu'] as bool,
      placementEvidence: result['fellBackToCpu'] as bool
          ? SubtitlePlacementEvidence.cpuFallbackAfterAcceleratorUnavailable
          : (requested == SubtitleInferenceProvider.cpu
                ? SubtitlePlacementEvidence.cpuOnlyConfigured
                : SubtitlePlacementEvidence.acceleratorRequestSucceededButUnverified),
      detectedLanguage: 'en',
      translatedToEnglish: false,
    );
  }
}

void _extractMoonshineArchive(Uint8List compressed, String stagingPath) {
  final uncompressed = BZip2Decoder().decodeBytes(
    compressed,
    verify: true,
    maxOutputSize: SubtitleAiService._maximumExpandedArchiveBytes,
  );
  final archive = TarDecoder().decodeBytes(uncompressed, verify: true);
  final files = <String, ArchiveFile>{};
  for (final entry in archive.files) {
    if (entry.isSymbolicLink) throw const FormatException('Model package contains a symbolic link.');
    if (entry.isDirectory) continue;
    final name = entry.name.replaceAll('\\', '/').split('/').last;
    if (const {'encoder_model.ort', 'decoder_model_merged.ort', 'tokens.txt'}.contains(name)) {
      if (files.containsKey(name)) throw const FormatException('Model package contains duplicate required files.');
      files[name] = entry;
    }
  }

  for (final name in const ['encoder_model.ort', 'decoder_model_merged.ort', 'tokens.txt']) {
    final entry = files[name];
    if (entry == null || entry.size <= 0 || entry.size > 160 * 1024 * 1024) {
      throw const FormatException('Model package is missing a bounded required file.');
    }
    final content = entry.content;
    final bytes = content;
    if (bytes.lengthInBytes != entry.size) throw const FormatException('Model member size does not match its header.');
    File(p.join(stagingPath, name)).writeAsBytesSync(bytes, flush: true);
  }
}

Future<Map<String, Object?>> _runSubtitleTranscriptionWorker({
  required String wavPath,
  required String modelDirectory,
  required String provider,
  required int numThreads,
  required bool allowEmpty,
  required int startMs,
  required int endMs,
}) async {
  await sherpa.initBindingsAsync();

  Future<(sherpa.OfflineRecognizer, sherpa.VoiceActivityDetector)> createEngine(String requestedProvider) async {
    final model = sherpa.OfflineModelConfig(
      moonshine: sherpa.OfflineMoonshineModelConfig(
        encoder: p.join(modelDirectory, 'encoder_model.ort'),
        mergedDecoder: p.join(modelDirectory, 'decoder_model_merged.ort'),
      ),
      tokens: p.join(modelDirectory, 'tokens.txt'),
      numThreads: numThreads,
      debug: false,
      provider: requestedProvider,
    );
    final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: model));
    try {
      final vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: p.join(modelDirectory, 'silero_vad.int8.onnx'),
            threshold: 0.5,
            minSilenceDuration: 0.4,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 10,
          ),
          sampleRate: SubtitleAiService._sampleRate,
          numThreads: numThreads,
          provider: requestedProvider,
          debug: false,
        ),
        bufferSizeInSeconds: 30,
      );
      return (recognizer, vad);
    } catch (_) {
      recognizer.free();
      rethrow;
    }
  }

  Future<Map<String, Object?>> run(String requestedProvider, {required bool fellBackToCpu}) async {
    final wav = await SubtitleWavReader.open(wavPath);
    sherpa.OfflineRecognizer? recognizer;
    sherpa.VoiceActivityDetector? vad;
    try {
      final engine = await createEngine(requestedProvider);
      recognizer = engine.$1;
      vad = engine.$2;
      final output = <Map<String, Object?>>[];
      if (startMs < 0 || endMs <= startMs || endMs > wav.durationMs) {
        throw const FormatException('The selected transcription interval must be inside the WAV duration.');
      }

      Future<void> drainVad() async {
        while (!vad!.isEmpty()) {
          final segment = vad.front();
          final cueStartMs = startMs + (segment.start * 1000 / SubtitleAiService._sampleRate).round();
          final cueEndMs =
              startMs + ((segment.start + segment.samples.length) * 1000 / SubtitleAiService._sampleRate).round();
          if (segment.samples.isEmpty || cueEndMs <= cueStartMs) {
            vad.pop();
            continue;
          }

          final stream = recognizer!.createStream();
          try {
            stream.acceptWaveform(samples: segment.samples, sampleRate: SubtitleAiService._sampleRate);
            recognizer.decode(stream);
            final text = recognizer.getResult(stream).text.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (text.isNotEmpty && text.runes.length <= 600 && output.length < SubtitleAiService._maximumCueCount) {
              final previous = output.isEmpty ? null : output.last;
              if (previous == null ||
                  previous['text'] != text ||
                  cueStartMs - (previous['endMs'] as int) > 1200) {
                output.add({'index': output.length + 1, 'startMs': cueStartMs, 'endMs': cueEndMs, 'text': text});
              }
            }
          } finally {
            stream.free();
            vad.pop();
          }
        }
      }

      await wav.forEachMono16kChunk(
        (samples) async {
          vad!.acceptWaveform(samples);
          await drainVad();
        },
        startMs: startMs,
        endMs: endMs,
      );
      vad.flush();
      await drainVad();
      final durationMs = wav.durationMs;
      if (output.isEmpty && !allowEmpty) throw const FormatException('No speech was detected in this WAV file.');
      return {
        'cues': output,
        'durationMs': durationMs,
        'runtimeProvider': requestedProvider,
        'fellBackToCpu': fellBackToCpu,
        'detectedLanguage': 'en',
      };
    } finally {
      vad?.free();
      recognizer?.free();
      await wav.close();
    }
  }

  try {
    return await run(provider, fellBackToCpu: false);
  } catch (error) {
    if (provider == 'cpu') rethrow;
    appLogger.i('Subtitle inference provider $provider failed; retrying the selected WAV interval with CPU: $error');
    return run('cpu', fellBackToCpu: true);
  }
}
