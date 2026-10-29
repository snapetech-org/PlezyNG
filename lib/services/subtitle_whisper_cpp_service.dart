import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_whisper_ggml/flutter_whisper.dart' as whisper;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_placement_evidence.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';
import 'subtitle_wav_reader.dart';

final class SubtitleWhisperResult {
  const SubtitleWhisperResult({
    required this.cues,
    required this.durationMs,
    required this.detectedLanguage,
    required this.runtimeProvider,
    required this.fellBackToCpu,
    this.placementEvidence = SubtitlePlacementEvidence.unverified,
    required this.translatedToEnglish,
    this.wordTimings = const <SubtitleWordTiming>[],
  });

  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> wordTimings;
  final int durationMs;
  final String detectedLanguage;
  final String runtimeProvider;
  final bool fellBackToCpu;
  final SubtitlePlacementEvidence placementEvidence;
  final bool translatedToEnglish;
}

final class SubtitleLiveWhisperRuntime {
  const SubtitleLiveWhisperRuntime({
    required this.session,
    required this.runtimeProvider,
    required this.fellBackToCpu,
  });

  final whisper.FlutterWhisper session;
  final String runtimeProvider;
  final bool fellBackToCpu;
}

/// whisper.cpp provides the multilingual CPU baseline and optional compiled
/// CUDA/Vulkan devices. GPU use is selected only from devices reported by the
/// native runtime; a failed GPU load or inference is retried on CPU.
final class SubtitleWhisperCppService {
  static final SubtitleWhisperCppService instance = SubtitleWhisperCppService._();
  SubtitleWhisperCppService._();

  static const int _maximumAudioHours = 8;
  static const int _maximumCues = 50000;
  static const int _maximumCueCharacters = 600;
  static const int _maximumWavBytes = 1024 * 1024 * 1024;
  static const bool _tvOsBuild = bool.fromEnvironment('TVOS_BUILD');
  static const bool _tizenBuild = bool.fromEnvironment('PLEZY_TIZEN');
  static const bool _webOsBuild = bool.fromEnvironment('PLEZY_WEBOS');
  static bool? _tizenWhisperRuntimeState;
  static bool? _webOsWhisperRuntimeState;

  static bool get supportedPlatform {
    if (_tizenBuild) return _tizenWhisperRuntimeAvailable;
    if (_webOsBuild) return _webOsWhisperRuntimeAvailable;
    return !_tvOsBuild &&
        (Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isWindows ||
            Platform.isMacOS ||
            Platform.isLinux);
  }

  static Future<int> readWavDurationMs(String path) => _WavDurationReader.readDurationMs(path);

  static bool get _tizenWhisperRuntimeAvailable => _tizenWhisperRuntimeState ??= _probeTizenWhisperRuntime();

  static bool _probeTizenWhisperRuntime() {
    try {
      ffi.DynamicLibrary.open(
        'libflutter_whisper_plugin.so',
      ).lookup<ffi.NativeFunction<ffi.Int32 Function()>>('fw_device_count');
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool get _webOsWhisperRuntimeAvailable =>
      _webOsWhisperRuntimeState ??= _probeWebOsWhisperRuntime();

  static bool _probeWebOsWhisperRuntime() {
    try {
      ffi.DynamicLibrary.open(
        'libflutter_whisper_plugin.so',
      ).lookup<ffi.NativeFunction<ffi.Int32 Function()>>('fw_device_count');
      return true;
    } catch (_) {
      return false;
    }
  }

  String? _verifiedInstalledPath;
  FileStat? _verifiedInstalledStat;

  Future<String> _installedModelPath() async {
    final model = whisper.WhisperModels.baseQ5_1;
    final file = File(p.join((await getApplicationSupportDirectory()).path,
      'subtitle_models', 'whisper_cpp', model.fileName));
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size != model.sizeBytes) {
      throw StateError('Install the selected speech model in the foreground first.');
    }
    final previous = _verifiedInstalledStat;
    if (_verifiedInstalledPath != file.path || previous?.size != stat.size ||
        previous?.modified != stat.modified || previous?.changed != stat.changed) {
      final digest = (await sha256.bind(file.openRead()).first).toString();
      final after = await file.stat();
      if (digest != model.sha256 || after.size != stat.size || after.modified != stat.modified ||
          after.changed != stat.changed) throw StateError('The installed speech model failed verification.');
      _verifiedInstalledPath = file.path;
      _verifiedInstalledStat = stat;
    }
    return file.path;
  }

  Future<bool> isModelInstalled() async {
    try { await _installedModelPath(); return true; } on Object { return false; }
  }

  /// Loads the verified multilingual model for repeated, in-memory player PCM
  /// windows. Desktop GPU is an explicit best-effort request; the caller owns
  /// and disposes the session and receives the runtime/fallback report.
  Future<SubtitleLiveWhisperRuntime> loadLiveSession({
    bool requestGpu = false,
    void Function(String phase, int received, int total)? onProgress,
  }) async {
    if (!supportedPlatform) {
      throw UnsupportedError('Local Whisper inference is unavailable on this platform.');
    }
    final modelDirectory = p.join((await getApplicationSupportDirectory()).path, 'subtitle_models', 'whisper_cpp');
    final model = whisper.WhisperModels.baseQ5_1;
    Future<whisper.FlutterWhisper> load(whisper.WhisperModelConfig config) => whisper.FlutterWhisper.loadModel(
      model: model,
      modelDirectory: modelDirectory,
      config: config,
      onDownloadProgress: (progress) {
        onProgress?.call('Downloading multilingual ${model.id}', progress.receivedBytes, progress.totalBytes);
      },
      onModelProgress: (progress) => onProgress?.call('Loading Whisper model', progress, 100),
    );

    const cpuConfig = whisper.WhisperModelConfig(useGpu: false);
    if (!requestGpu) {
      return SubtitleLiveWhisperRuntime(
        session: await load(cpuConfig),
        runtimeProvider: 'CPU',
        fellBackToCpu: false,
      );
    }

    List<whisper.WhisperDevice> devices;
    try {
      devices = whisper.FlutterWhisper.availableDevices.where((device) => device.isGpu).toList(growable: false);
    } on Object {
      devices = const <whisper.WhisperDevice>[];
    }
    if (devices.isEmpty) {
      onProgress?.call('No compiled Whisper GPU is available; loading CPU', 0, 0);
      return SubtitleLiveWhisperRuntime(
        session: await load(cpuConfig),
        runtimeProvider: 'CPU (no compiled GPU device detected)',
        fellBackToCpu: true,
      );
    }

    final device = devices.first;
    try {
      return SubtitleLiveWhisperRuntime(
        session: await load(whisper.WhisperModelConfig.forDevice(device)),
        runtimeProvider: device.name,
        fellBackToCpu: false,
      );
    } on Object catch (error) {
      onProgress?.call('Whisper GPU initialization failed; loading CPU: $error', 0, 0);
      return SubtitleLiveWhisperRuntime(
        session: await load(cpuConfig),
        runtimeProvider: 'CPU (GPU initialization fallback)',
        fellBackToCpu: true,
      );
    }
  }

  Future<SubtitleWhisperResult> transcribeWav(
    String wavPath, {
    required bool requestGpu,
    int startMs = 0,
    int? endMs,
    bool translateToEnglish = false,
    bool allowEmpty = false,
    bool allowModelDownload = true,
    bool Function()? isCurrent,
    int numThreads = 2,
    String? languageCode,
    void Function(String phase, int received, int total)? onProgress,
  }) async {
    if (!supportedPlatform) throw UnsupportedError('Local Whisper inference is unavailable on this platform.');
    final normalizedLanguageCode = languageCode?.trim().toLowerCase().split(RegExp(r'[-_]')).first ?? '';
    final selectedLanguage = normalizedLanguageCode.isEmpty || normalizedLanguageCode == 'auto'
        ? 'auto'
        : normalizedLanguageCode;
    if (selectedLanguage != 'auto' && !RegExp(r'^[a-z]{2,3}$').hasMatch(selectedLanguage)) {
      throw ArgumentError.value(languageCode, 'languageCode', 'Use a two or three letter language code or auto.');
    }
    final durationMs = await _WavDurationReader.readDurationMs(wavPath);
    if (durationMs <= 0 || durationMs > _maximumAudioHours * 60 * 60 * 1000) {
      throw const FormatException('WAV duration must be between one millisecond and eight hours.');
    }
    final rangeEndMs = endMs ?? durationMs;
    if (startMs < 0 || rangeEndMs <= startMs || rangeEndMs > durationMs) {
      throw const FormatException('The selected transcription interval must be inside the WAV duration.');
    }
    final modelDirectory = p.join((await getApplicationSupportDirectory()).path, 'subtitle_models', 'whisper_cpp');
    final model = whisper.WhisperModels.baseQ5_1;
    final installedPath = allowModelDownload ? null : await _installedModelPath();
    if (isCurrent?.call() == false) throw StateError('Transcription was cancelled.');
    List<whisper.WhisperDevice> devices = [];
    if (requestGpu) {
      try {
        devices = whisper.FlutterWhisper.availableDevices.where((device) => device.isGpu).toList();
      } catch (_) {
        devices = [];
      }
    }
    final selectedDevice = devices.isEmpty ? null : devices.first;
    if (requestGpu && selectedDevice == null) {
      return _run(
        wavPath,
        durationMs,
        startMs,
        rangeEndMs,
        modelDirectory,
        model,
        const whisper.WhisperModelConfig(useGpu: false),
        translated: translateToEnglish,
        onProgress: onProgress,
        runtimeProvider: 'CPU (no compiled GPU device detected)',
        fellBackToCpu: true,
        languageCode: selectedLanguage,
        allowEmpty: allowEmpty,
        numThreads: numThreads,
        installedPath: installedPath, isCurrent: isCurrent,
      );
    }

    try {
      return await _run(
        wavPath,
        durationMs,
        startMs,
        rangeEndMs,
        modelDirectory,
        model,
        selectedDevice == null
            ? const whisper.WhisperModelConfig(useGpu: false)
            : whisper.WhisperModelConfig.forDevice(selectedDevice),
        translated: translateToEnglish,
        onProgress: onProgress,
        runtimeProvider: selectedDevice?.name ?? 'CPU',
        fellBackToCpu: false,
        languageCode: selectedLanguage,
        allowEmpty: allowEmpty,
        numThreads: numThreads,
        installedPath: installedPath, isCurrent: isCurrent,
      );
    } catch (error) {
      if (selectedDevice == null || isCurrent?.call() == false) rethrow;
      onProgress?.call('GPU inference failed; restarting with CPU', 0, 0);
      return _run(
        wavPath,
        durationMs,
        startMs,
        rangeEndMs,
        modelDirectory,
        model,
        const whisper.WhisperModelConfig(useGpu: false),
        translated: translateToEnglish,
        onProgress: onProgress,
        runtimeProvider: 'CPU (GPU fallback)',
        fellBackToCpu: true,
        languageCode: selectedLanguage,
        allowEmpty: allowEmpty,
        numThreads: numThreads,
        installedPath: installedPath, isCurrent: isCurrent,
      );
    }
  }

  Future<SubtitleWhisperResult> _run(
    String wavPath,
    int durationMs,
    int startMs,
    int endMs,
    String modelDirectory,
    whisper.WhisperModel model,
    whisper.WhisperModelConfig config, {
    required bool translated,
    required String runtimeProvider,
    required bool fellBackToCpu,
    required String languageCode,
    required bool allowEmpty,
    required int numThreads,
    String? installedPath, bool Function()? isCurrent,
    void Function(String phase, int received, int total)? onProgress,
  }) async {
    if (isCurrent?.call() == false) throw StateError('Transcription was cancelled.');
    final session = installedPath != null
        ? await whisper.FlutterWhisper.load(modelPath: installedPath, config: config,
            onModelProgress: (progress) => onProgress?.call('Loading Whisper model', progress, 100))
        : await whisper.FlutterWhisper.loadModel(
      model: model,
      modelDirectory: modelDirectory,
      config: config,
      onDownloadProgress: (progress) {
        onProgress?.call('Downloading multilingual ${model.id}', progress.receivedBytes, progress.totalBytes);
      },
      onModelProgress: (progress) => onProgress?.call('Loading Whisper model', progress, 100),
    );
    final cancellation = isCurrent == null ? null : Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!isCurrent()) session.cancel();
    });
    try {
      if (isCurrent?.call() == false) throw StateError('Transcription was cancelled.');
      onProgress?.call(translated ? 'Translating audio to English' : 'Transcribing multilingual audio', 0, 0);
      final boundedWindow = endMs - startMs <= 300000;
      final inferenceConfig = whisper.WhisperTranscribeConfig(
          language: languageCode,
          translate: translated,
          threads: numThreads.clamp(1, 8).toInt(),
          noSpeechThreshold: 0.6,
          tokenTimestamps: true,
          splitOnWord: true,
          offset: Duration(milliseconds: boundedWindow ? 0 : startMs),
          duration: Duration(milliseconds: endMs - startMs),
      );
      // transcribeFile may decode the whole input before applying its offset.
      // Queue windows and selected intervals instead stream only their PCM,
      // keeping native input memory bounded independently of the movie length.
      final result = boundedWindow
          ? await session.transcribe(await _readWindow(wavPath, startMs, endMs), config: inferenceConfig)
          : await session.transcribeFile(wavPath, config: inferenceConfig,
              onProgress: (progress) => onProgress?.call('Whisper inference', progress, 100));
      if (isCurrent?.call() == false) throw StateError('Transcription was cancelled.');
      final offsetMs = boundedWindow ? startMs : 0;
      final wordTimings = SubtitleWordTimingBuilder.fromWhisperSegments(result.segments, durationMs: endMs, offsetMs: offsetMs);
      final cues = <SubtitleCue>[];
      for (final segment in result.segments) {
        final text = segment.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        final startRaw = offsetMs + segment.start.inMilliseconds;
        final endRaw = offsetMs + segment.end.inMilliseconds;
        if (text.isEmpty || text.length > _maximumCueCharacters || startRaw >= endMs || endRaw <= startMs) continue;
        final cueStart = startRaw.clamp(startMs, endMs - 1).toInt();
        final cueEnd = endRaw.clamp(cueStart + 1, endMs).toInt();
        cues.add(SubtitleCue(index: cues.length + 1, startMs: cueStart, endMs: cueEnd, text: text));
        if (cues.length >= _maximumCues) break;
      }
      if (cues.isEmpty && !allowEmpty) throw const FormatException('Whisper did not produce any speech cues.');
      return SubtitleWhisperResult(
        cues: List.unmodifiable(cues),
        durationMs: durationMs,
        detectedLanguage: result.language,
        runtimeProvider: runtimeProvider,
        fellBackToCpu: fellBackToCpu,
        placementEvidence: fellBackToCpu
            ? SubtitlePlacementEvidence.cpuFallbackAfterAcceleratorUnavailable
            : (runtimeProvider == 'CPU'
                  ? SubtitlePlacementEvidence.cpuOnlyConfigured
                  : SubtitlePlacementEvidence.acceleratorRequestSucceededButUnverified),
        translatedToEnglish: translated,
        wordTimings: wordTimings,
      );
    } finally {
      cancellation?.cancel();
      await session.dispose();
    }
  }

  static Future<Float32List> _readWindow(String path, int startMs, int endMs) => Isolate.run(() async {
    final reader = await SubtitleWavReader.open(path);
    try {
      final samples = Float32List((endMs - startMs) * 16);
      var count = 0;
      await reader.forEachMono16kChunk((chunk) async {
        final length = chunk.length.clamp(0, samples.length - count).toInt();
        samples.setRange(count, count + length, chunk);
        count += length;
      }, startMs: startMs, endMs: endMs);
      return count == samples.length ? samples : Float32List.sublistView(samples, 0, count);
    } finally { await reader.close(); }
  });
}

abstract final class _WavDurationReader {
  static Future<int> readDurationMs(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    try {
      final length = await file.length();
      if (length < 44) throw const FormatException('WAV file is too short.');
      if (length > SubtitleWhisperCppService._maximumWavBytes) {
        throw const FormatException('WAV file exceeds the 1 GiB Whisper processing limit.');
      }
      final header = await file.read(12);
      if (header.length != 12 ||
          ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
          ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
        throw const FormatException('Choose a standard RIFF/WAVE audio file.');
      }

      var sampleRate = 0;
      var blockAlign = 0;
      var dataBytes = -1;
      while (await file.position() + 8 <= length) {
        final chunkHeader = await file.read(8);
        if (chunkHeader.length != 8) break;
        final name = ascii.decode(chunkHeader.sublist(0, 4), allowInvalid: true);
        final size = ByteData.sublistView(Uint8List.fromList(chunkHeader)).getUint32(4, Endian.little);
        final contentStart = await file.position();
        if (size > length || contentStart + size > length) {
          throw const FormatException('WAV contains an invalid chunk length.');
        }
        if (name == 'fmt ') {
          if (size < 16 || size > 4096) throw const FormatException('WAV format chunk is invalid.');
          final format = await file.read(size);
          if (format.length != size) throw const FormatException('WAV ended inside its format header.');
          final view = ByteData.sublistView(Uint8List.fromList(format));
          final audioFormat = view.getUint16(0, Endian.little);
          final channels = view.getUint16(2, Endian.little);
          sampleRate = view.getUint32(4, Endian.little);
          blockAlign = view.getUint16(12, Endian.little);
          final bitsPerSample = view.getUint16(14, Endian.little);
          final supportedPcmDepth = audioFormat == 1 && const {8, 16, 24, 32}.contains(bitsPerSample);
          final supportedFloatDepth = audioFormat == 3 && const {32, 64}.contains(bitsPerSample);
          final bytesPerSample = (bitsPerSample + 7) ~/ 8;
          if ((!supportedPcmDepth && !supportedFloatDepth) || channels < 1 || blockAlign < channels * bytesPerSample) {
            throw const FormatException('Choose an uncompressed PCM or IEEE-float WAV file.');
          }
        } else if (name == 'data') {
          dataBytes = size;
        }
        final next = contentStart + size + (size.isOdd ? 1 : 0);
        if (await file.position() != next) await file.setPosition(next);
        if (sampleRate > 0 && dataBytes >= 0) break;
      }

      if (sampleRate < 8000 || sampleRate > 192000 || blockAlign <= 0 || dataBytes <= 0) {
        throw const FormatException('WAV sample rate or audio data is invalid.');
      }
      return ((dataBytes ~/ blockAlign) * 1000) ~/ sampleRate;
    } finally {
      await file.close();
    }
  }
}
