import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_ai_service.dart';
import 'subtitle_placement_evidence.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

/// Source-language speech recognition tied to the exact WAV bytes and model
/// identity. The target language and translation glossary deliberately do not
/// belong to this record, so it can feed more than one translation.
final class SubtitleCachedSourceTranscript {
  const SubtitleCachedSourceTranscript({
    required this.cues,
    required this.wordTimings,
    required this.durationMs,
    required this.requestedProvider,
    required this.runtimeProvider,
    required this.fellBackToCpu,
    required this.placementEvidence,
    required this.detectedLanguage,
    required this.cacheHit,
    required this.persisted,
  });

  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> wordTimings;
  final int durationMs;
  final SubtitleInferenceProvider requestedProvider;
  final String runtimeProvider;
  final bool fellBackToCpu;
  final SubtitlePlacementEvidence placementEvidence;
  final String detectedLanguage;
  final bool cacheHit;
  final bool persisted;
}

/// Complete identity for a reusable WAV source transcript.
final class SubtitleSourceTranscriptCacheIdentity {
  const SubtitleSourceTranscriptCacheIdentity({
    required this.key,
    required this.profileScopeHash,
    required this.audioSha256,
    required this.sourceRepresentation,
    required this.modelIdentity,
    required this.providerRequest,
    required this.task,
    required this.sourceLanguage,
    required this.pipelineVersion,
  });

  final String key;
  final String profileScopeHash;
  final String audioSha256;
  final String sourceRepresentation;
  final String modelIdentity;
  final String providerRequest;
  final String task;
  final String sourceLanguage;
  final String pipelineVersion;

  Map<String, Object?> toJson() => {
    'key': key,
    'profileScopeHash': profileScopeHash,
    'audioSha256': audioSha256,
    'sourceRepresentation': sourceRepresentation,
    'modelIdentity': modelIdentity,
    'providerRequest': providerRequest,
    'task': task,
    'sourceLanguage': sourceLanguage,
    'pipelineVersion': pipelineVersion,
  };

  static SubtitleSourceTranscriptCacheIdentity create({
    required String? profileId,
    required String audioSha256,
    required SubtitleInferenceProvider provider,
    required String? languageCode,
  }) {
    final suppliedProfile = profileId?.trim();
    if (suppliedProfile != null && utf8.encode(suppliedProfile).length > 1024) {
      throw ArgumentError.value(profileId, 'profileId', 'Profile identity must contain no more than 1024 UTF-8 bytes.');
    }
    final profile = suppliedProfile == null || suppliedProfile.isEmpty ? null : suppliedProfile;
    final normalizedLanguage = languageCode?.trim().toLowerCase().split(RegExp(r'[-_]')).first;
    final sourceLanguage = normalizedLanguage == null || normalizedLanguage.isEmpty || normalizedLanguage == 'auto'
        ? 'auto'
        : normalizedLanguage;
    if (sourceLanguage != 'auto' && !RegExp(r'^[a-z]{2,3}$').hasMatch(sourceLanguage)) {
      throw ArgumentError.value(languageCode, 'languageCode', 'Use a two or three letter language code or auto.');
    }
    final profileScopeHash = profile == null ? 'unscoped' : sha256.convert(utf8.encode(profile)).toString();
    const sourceRepresentation = 'wav-file-bytes-v1';
    const task = 'source-language-transcription-v1';
    const pipelineVersion = 'subtitle-transcript-cues-v1';
    final modelIdentity = SubtitleAiService.sourceTranscriptModelIdentity(provider);
    final canonicalParts = <Object?>[
      'pleazyng.subtitle-source-transcript-cache.v1',
      profileScopeHash,
      audioSha256,
      sourceRepresentation,
      modelIdentity,
      provider.name,
      task,
      sourceLanguage,
      pipelineVersion,
    ];
    final key = sha256.convert(utf8.encode(jsonEncode(canonicalParts))).toString();
    return SubtitleSourceTranscriptCacheIdentity(
      key: key,
      profileScopeHash: profileScopeHash,
      audioSha256: audioSha256,
      sourceRepresentation: sourceRepresentation,
      modelIdentity: modelIdentity,
      providerRequest: provider.name,
      task: task,
      sourceLanguage: sourceLanguage,
      pipelineVersion: pipelineVersion,
    );
  }

  bool matchesJson(Object? value) {
    if (value is! Map<String, dynamic>) return false;
    return value['key'] == key &&
        value['profileScopeHash'] == profileScopeHash &&
        value['audioSha256'] == audioSha256 &&
        value['sourceRepresentation'] == sourceRepresentation &&
        value['modelIdentity'] == modelIdentity &&
        value['providerRequest'] == providerRequest &&
        value['task'] == task &&
        value['sourceLanguage'] == sourceLanguage &&
        value['pipelineVersion'] == pipelineVersion;
  }
}

/// A bounded temporary WAV copy whose digest and inference input are the same
/// byte sequence. The caller must dispose it after cache lookup/transcription.
final class SubtitleSourceTranscriptWavSnapshot {
  const SubtitleSourceTranscriptWavSnapshot({
    required this.path,
    required this.audioSha256,
    required this.stagingDirectory,
  });

  final String path;
  final String audioSha256;
  final Directory stagingDirectory;

  Future<void> dispose() async {
    try {
      if (await stagingDirectory.exists()) await stagingDirectory.delete(recursive: true);
    } on FileSystemException {
      // The operating system can reclaim app temporary files later.
    }
  }
}

/// Bounded, profile-local cache for source transcripts made from WAV files.
/// Cache reads verify identity and schema; writes are atomic and old entries
/// are evicted by last-use time. Without an active profile, only one bounded
/// in-memory entry is retained for the current process.
abstract final class SubtitleSourceTranscriptCacheService {
  static const int maximumEntriesPerProfile = 8;
  static const int maximumBytesPerProfile = 48 * 1024 * 1024;
  static const int maximumTranscriptBytes = 32 * 1024 * 1024;
  static const int maximumCachedCueTextBytes = SubtitleRetimer.maximumInputBytes;
  static const int maximumTotalEntries = 1000;
  static const int maximumTotalBytes = 256 * 1024 * 1024;
  static const int maximumAudioBytes = 1024 * 1024 * 1024;
  static const int _maximumAudioHours = 8;
  static const int _maximumWordTimings = 250000;

  static final LinkedHashMap<String, SubtitleCachedSourceTranscript> _recentMemory =
      LinkedHashMap<String, SubtitleCachedSourceTranscript>();
  static Future<void> _writeTail = Future<void>.value();

  static Future<String> audioSha256(String wavPath) async {
    final file = File(wavPath);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0 || stat.size > maximumAudioBytes) {
      throw const FormatException('WAV input must be a non-empty regular file no larger than 1 GiB.');
    }
    final digestSink = _SubtitleDigestOutput();
    final digestInput = sha256.startChunkedConversion(digestSink);
    var totalBytes = 0;
    await for (final chunk in file.openRead()) {
      totalBytes += chunk.length;
      if (totalBytes > maximumAudioBytes) {
        throw const FormatException('WAV input grew beyond the 1 GiB processing limit.');
      }
      digestInput.add(chunk);
    }
    digestInput.close();
    if (totalBytes <= 0) throw const FormatException('WAV input is empty.');
    return digestSink.value.toString();
  }

  /// Copies a WAV into temporary app storage while hashing the copied bytes.
  /// Path-based inference must consume this snapshot so a changing source file
  /// cannot be cached under the digest of different bytes.
  static Future<SubtitleSourceTranscriptWavSnapshot> snapshotWav(String wavPath) async {
    final source = File(wavPath);
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0 || stat.size > maximumAudioBytes) {
      throw const FormatException('WAV input must be a non-empty regular file no larger than 1 GiB.');
    }
    final temporaryRoot = await getTemporaryDirectory();
    final stagingRoot = Directory(p.join(temporaryRoot.path, 'pleazyng-subtitle-transcription'));
    await stagingRoot.create(recursive: true);
    final stagingDirectory = await stagingRoot.createTemp('wav-');
    final snapshot = File(p.join(stagingDirectory.path, 'source.wav'));
    RandomAccessFile? output;
    try {
      output = await snapshot.open(mode: FileMode.write);
      final digestSink = _SubtitleDigestOutput();
      final digestInput = sha256.startChunkedConversion(digestSink);
      var totalBytes = 0;
      await for (final chunk in source.openRead()) {
        totalBytes += chunk.length;
        if (totalBytes > maximumAudioBytes) {
          throw const FormatException('WAV input grew beyond the 1 GiB processing limit.');
        }
        digestInput.add(chunk);
        await output.writeFrom(chunk);
      }
      digestInput.close();
      await output.flush();
      await output.close();
      output = null;
      if (totalBytes <= 0) throw const FormatException('WAV input is empty.');
      return SubtitleSourceTranscriptWavSnapshot(
        path: snapshot.path,
        audioSha256: digestSink.value.toString(),
        stagingDirectory: stagingDirectory,
      );
    } on Object {
      if (output != null) {
        try {
          await output.close();
        } on Object {
          // Preserve the original copy or hashing error.
        }
      }
      try {
        await stagingDirectory.delete(recursive: true);
      } on FileSystemException {
        // Best-effort cleanup after a failed staging operation.
      }
      rethrow;
    }
  }

  static Future<SubtitleSourceTranscriptCacheIdentity> identify({
    required String? profileId,
    required String wavPath,
    required SubtitleInferenceProvider provider,
    required String? languageCode,
  }) async => SubtitleSourceTranscriptCacheIdentity.create(
    profileId: profileId,
    audioSha256: await audioSha256(wavPath),
    provider: provider,
    languageCode: languageCode,
  );

  static Future<SubtitleCachedSourceTranscript?> load({
    required String? profileId,
    required SubtitleSourceTranscriptCacheIdentity identity,
  }) async {
    final recent = _recentMemory.remove(identity.key);
    if (recent != null) {
      final reused = _copyWithCacheState(recent, cacheHit: true, persisted: recent.persisted);
      _recentMemory[identity.key] = reused;
      return reused;
    }
    if (profileId == null || profileId.trim().isEmpty) return null;
    File? file;
    try {
      file = await _entryFile(profileId, identity.key, createDirectory: false);
      if (file == null || !await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > maximumTranscriptBytes) {
        throw const FormatException('Transcript cache entry is oversized.');
      }
      final decoded = jsonDecode(await file.readAsString());
      final transcript = _decodeTranscript(decoded, identity);
      try {
        await file.setLastModified(DateTime.now());
      } on FileSystemException {
        // A read-only cache entry remains valid; it simply will not be LRU-hot.
      }
      final reused = _copyWithCacheState(transcript, cacheHit: true, persisted: true);
      _recentMemory
        ..clear()
        ..[identity.key] = reused;
      return reused;
    } on Object {
      if (file != null) {
        try {
          await file.delete();
        } on FileSystemException {
          // Ignore a cache cleanup failure and recompute from the WAV.
        }
      }
      return null;
    }
  }

  /// Normalizes cue IDs before storing or using a freshly computed transcript.
  /// A failure to persist never prevents translation of the current result.
  static Future<SubtitleCachedSourceTranscript> store({
    required String? profileId,
    required SubtitleSourceTranscriptCacheIdentity identity,
    required SubtitleTranscriptionResult result,
  }) async {
    if (result.translatedToEnglish) {
      throw ArgumentError('English-translated speech is not a source-language transcript cache entry.');
    }
    final transcript = _fromResult(result, identity);
    final cueTextBytes = transcript.cues.fold<int>(0, (total, cue) => total + utf8.encode(cue.text).length);
    if (cueTextBytes > maximumCachedCueTextBytes) return transcript;
    var cacheRecord = transcript;
    var jsonText = jsonEncode(_encodeTranscript(cacheRecord, identity));
    if (utf8.encode(jsonText).length > maximumTranscriptBytes) {
      cacheRecord = _copyWithCacheState(cacheRecord, cacheHit: false, persisted: false, wordTimings: const []);
      jsonText = jsonEncode(_encodeTranscript(cacheRecord, identity));
    }
    if (utf8.encode(jsonText).length > maximumTranscriptBytes) return transcript;
    _recentMemory
      ..clear()
      ..[identity.key] = cacheRecord;
    if (profileId == null || profileId.trim().isEmpty) {
      return transcript;
    }
    try {
      await _exclusive(() async {
        final file = await _entryFile(profileId, identity.key, createDirectory: true);
        if (file == null) return;
        if (!await _removePendingEntries(file.parent.parent)) {
          throw FileSystemException(
            'Cannot remove abandoned subtitle transcript cache writes.',
            file.parent.parent.path,
          );
        }
        final temporary = File('${file.path}.pending');
        try {
          if (await temporary.exists()) await temporary.delete();
          await temporary.writeAsString(jsonText, flush: true);
          if (await temporary.length() > maximumTranscriptBytes) return;
          if (await file.exists()) await file.delete();
          await temporary.rename(file.path);
          await _evictProfileEntries(file.parent);
          await _evictGlobalEntries(file.parent.parent);
        } finally {
          try {
            if (await temporary.exists()) await temporary.delete();
          } on FileSystemException {
            // A later store refuses to write until abandoned temporary files are removed.
          }
        }
      });
      final file = await _entryFile(profileId, identity.key, createDirectory: false);
      final persisted = file != null && await file.exists();
      final saved = _copyWithCacheState(cacheRecord, cacheHit: false, persisted: persisted);
      _recentMemory[identity.key] = saved;
      return _copyWithCacheState(transcript, cacheHit: false, persisted: persisted);
    } on Object {
      return _copyWithCacheState(transcript, cacheHit: false, persisted: false);
    }
  }

  static SubtitleCachedSourceTranscript _fromResult(
    SubtitleTranscriptionResult result,
    SubtitleSourceTranscriptCacheIdentity identity,
  ) {
    _validateTranscript(result.cues, result.wordTimings, result.durationMs, result.detectedLanguage);
    final cues = List<SubtitleCue>.unmodifiable([
      for (var index = 0; index < result.cues.length; index++)
        SubtitleCue(
          id: SubtitleCue.idFor('source-transcript:${identity.key}', index + 1),
          index: index + 1,
          startMs: result.cues[index].startMs,
          endMs: result.cues[index].endMs,
          text: result.cues[index].text,
        ),
    ]);
    return SubtitleCachedSourceTranscript(
      cues: cues,
      wordTimings: SubtitleWordTimingBuilder.attachCueReferences(result.wordTimings, cues),
      durationMs: result.durationMs,
      requestedProvider: result.requestedProvider,
      runtimeProvider: result.runtimeProvider,
      fellBackToCpu: result.fellBackToCpu,
      placementEvidence: result.placementEvidence,
      detectedLanguage: result.detectedLanguage,
      cacheHit: false,
      persisted: false,
    );
  }

  static Map<String, Object?> _encodeTranscript(
    SubtitleCachedSourceTranscript transcript,
    SubtitleSourceTranscriptCacheIdentity identity,
  ) {
    final cuePositions = {
      for (var index = 0; index < transcript.cues.length; index++) transcript.cues[index].id: index + 1,
    };
    return {
      'schema': 'pleazyng.subtitle-source-transcript.v1',
      'identity': identity.toJson(),
      'durationMs': transcript.durationMs,
      'requestedProvider': transcript.requestedProvider.name,
      'runtimeProvider': transcript.runtimeProvider,
      'fellBackToCpu': transcript.fellBackToCpu,
      'placementEvidence': transcript.placementEvidence.name,
      'detectedLanguage': transcript.detectedLanguage,
      'cues': transcript.cues
          .map(
            (cue) => {'id': cue.id, 'index': cue.index, 'startMs': cue.startMs, 'endMs': cue.endMs, 'text': cue.text},
          )
          .toList(growable: false),
      'wordTimings': transcript.wordTimings
          .map(
            (timing) => {
              'startMs': timing.startMs,
              'endMs': timing.endMs,
              'text': timing.text,
              if (timing.confidence != null) 'confidence': timing.confidence,
              'unit': timing.unit.name,
              'cueId': timing.cueId,
              'cueIndex': timing.cueId == null ? timing.cueIndex : cuePositions[timing.cueId],
            },
          )
          .toList(growable: false),
    };
  }

  static SubtitleCachedSourceTranscript _decodeTranscript(
    Object? value,
    SubtitleSourceTranscriptCacheIdentity identity,
  ) {
    if (value is! Map<String, dynamic> ||
        value['schema'] != 'pleazyng.subtitle-source-transcript.v1' ||
        !identity.matchesJson(value['identity'])) {
      throw const FormatException('Transcript cache identity or schema is invalid.');
    }
    final durationMs = value['durationMs'];
    final requestedProviderName = value['requestedProvider'];
    final runtimeProvider = value['runtimeProvider'];
    final fellBackToCpu = value['fellBackToCpu'];
    final placementEvidenceName = value['placementEvidence'];
    final detectedLanguage = value['detectedLanguage'];
    final rawCues = value['cues'];
    final rawWordTimings = value['wordTimings'];
    final requestedProviders = SubtitleInferenceProvider.values.where(
      (provider) => provider.name == requestedProviderName,
    );
    final evidence = SubtitlePlacementEvidence.values.where((item) => item.name == placementEvidenceName);
    if (durationMs is! int ||
        durationMs <= 0 ||
        durationMs > _maximumAudioHours * 60 * 60 * 1000 ||
        requestedProviders.isEmpty ||
        runtimeProvider is! String ||
        runtimeProvider.isEmpty ||
        runtimeProvider.length > 160 ||
        fellBackToCpu is! bool ||
        evidence.isEmpty ||
        detectedLanguage is! String ||
        detectedLanguage.isEmpty ||
        detectedLanguage.length > 24 ||
        rawCues is! List ||
        rawWordTimings is! List ||
        rawWordTimings.length > _maximumWordTimings) {
      throw const FormatException('Transcript cache metadata exceeds supported bounds.');
    }
    final cues = <SubtitleCue>[];
    final cueIds = <String>{};
    for (var index = 0; index < rawCues.length; index++) {
      final row = rawCues[index];
      if (row is! Map<String, dynamic>) throw const FormatException('Transcript cache cue is invalid.');
      final id = row['id'];
      final storedIndex = row['index'];
      final startMs = row['startMs'];
      final endMs = row['endMs'];
      final text = row['text'];
      if (id is! String ||
          !SubtitleCue.isValidId(id) ||
          !cueIds.add(id) ||
          id != SubtitleCue.idFor('source-transcript:${identity.key}', index + 1) ||
          storedIndex != index + 1 ||
          startMs is! int ||
          endMs is! int ||
          text is! String ||
          text.trim().isEmpty ||
          text.length > 4000 ||
          startMs < 0 ||
          endMs <= startMs ||
          endMs > durationMs) {
        throw const FormatException('Transcript cache cue timing, identity, or text is invalid.');
      }
      cues.add(SubtitleCue(id: id, index: storedIndex as int, startMs: startMs, endMs: endMs, text: text));
    }
    if (cues.isEmpty || cues.length > SubtitleRetimer.maximumCueCount) {
      throw const FormatException('Transcript cache cue count is invalid.');
    }
    final totalTextBytes = cues.fold<int>(0, (total, cue) => total + utf8.encode(cue.text).length);
    if (totalTextBytes > maximumCachedCueTextBytes) {
      throw const FormatException('Transcript cache text exceeds the cache bound.');
    }

    final cuePositions = {for (var index = 0; index < cues.length; index++) cues[index].id: index};
    final wordTimings = <SubtitleWordTiming>[];
    for (final row in rawWordTimings) {
      if (row is! Map<String, dynamic>) throw const FormatException('Transcript cache word timing is invalid.');
      final startMs = row['startMs'];
      final endMs = row['endMs'];
      final text = row['text'];
      final confidence = row['confidence'];
      final unitName = row['unit'];
      final rawCueId = row['cueId'];
      final cueIndex = row['cueIndex'];
      final units = SubtitleWordTimingUnit.values.where((unit) => unit.name == unitName);
      if (startMs is! int ||
          endMs is! int ||
          text is! String ||
          text.isEmpty ||
          text.length > 4096 ||
          (confidence != null && confidence is! num) ||
          (confidence is num && (!confidence.isFinite || confidence < 0 || confidence > 1)) ||
          units.isEmpty ||
          (rawCueId != null && rawCueId is! String) ||
          (cueIndex != null && cueIndex is! int) ||
          startMs < 0 ||
          endMs <= startMs ||
          endMs > durationMs ||
          (cueIndex != null && (cueIndex < 1 || cueIndex > cues.length))) {
        throw const FormatException('Transcript cache word timing fields are invalid.');
      }
      String? cueId;
      if (rawCueId != null) {
        cueId = rawCueId as String;
        final position = cuePositions[cueId];
        if (position == null || (cueIndex != null && cueIndex != position + 1)) {
          throw const FormatException('Transcript cache word timing references a missing cue.');
        }
      } else if (cueIndex is int) {
        cueId = cues[cueIndex - 1].id;
      }
      wordTimings.add(
        SubtitleWordTiming(
          startMs: startMs,
          endMs: endMs,
          text: text,
          confidence: (confidence as num?)?.toDouble(),
          unit: units.first,
          cueId: cueId,
          cueIndex: cueId == null ? cueIndex as int? : cuePositions[cueId]! + 1,
        ),
      );
    }
    _validateTranscript(cues, wordTimings, durationMs, detectedLanguage);
    return SubtitleCachedSourceTranscript(
      cues: List<SubtitleCue>.unmodifiable(cues),
      wordTimings: List<SubtitleWordTiming>.unmodifiable(wordTimings),
      durationMs: durationMs,
      requestedProvider: requestedProviders.first,
      runtimeProvider: runtimeProvider,
      fellBackToCpu: fellBackToCpu,
      placementEvidence: evidence.first,
      detectedLanguage: detectedLanguage,
      cacheHit: true,
      persisted: true,
    );
  }

  static void _validateTranscript(
    List<SubtitleCue> cues,
    List<SubtitleWordTiming> wordTimings,
    int durationMs,
    String detectedLanguage,
  ) {
    if (durationMs <= 0 ||
        durationMs > _maximumAudioHours * 60 * 60 * 1000 ||
        cues.isEmpty ||
        cues.length > SubtitleRetimer.maximumCueCount ||
        wordTimings.length > _maximumWordTimings ||
        detectedLanguage.isEmpty ||
        detectedLanguage.length > 24) {
      throw const FormatException('Source transcript is empty or exceeds supported bounds.');
    }
    for (final cue in cues) {
      if (!SubtitleCue.isValidId(cue.id) ||
          cue.startMs < 0 ||
          cue.endMs <= cue.startMs ||
          cue.endMs > durationMs ||
          cue.text.trim().isEmpty ||
          cue.text.length > 4000) {
        throw const FormatException('Source transcript contains an invalid cue.');
      }
    }
    if (cues.map((cue) => cue.id).toSet().length != cues.length) {
      throw const FormatException('Source transcript cue identities are invalid or duplicated.');
    }
    for (final timing in wordTimings) {
      final confidence = timing.confidence;
      if (timing.startMs < 0 ||
          timing.endMs <= timing.startMs ||
          timing.endMs > durationMs ||
          timing.text.isEmpty ||
          timing.text.length > 4096 ||
          (confidence != null && (!confidence.isFinite || confidence < 0 || confidence > 1)) ||
          (timing.cueId != null && !cues.any((cue) => cue.id == timing.cueId))) {
        throw const FormatException('Source transcript contains invalid word timing.');
      }
    }
  }

  static Future<File?> _entryFile(String profileId, String key, {required bool createDirectory}) async {
    final profile = profileId.trim();
    if (profile.isEmpty || utf8.encode(profile).length > 1024 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      return null;
    }
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'subtitle-source-transcripts'));
    final directory = Directory(p.join(root.path, sha256.convert(utf8.encode(profile)).toString()));
    if (createDirectory) await directory.create(recursive: true);
    return File(p.join(directory.path, '$key.json'));
  }

  static Future<bool> _removePendingEntries(Directory root) async {
    if (!await root.exists()) return true;
    var removedAll = true;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.pending')) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        removedAll = false;
      }
    }
    return removedAll;
  }

  static Future<void> _evictProfileEntries(Directory directory) async {
    if (!await directory.exists()) return;
    final entries = <File>[];
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.pending')) {
        try {
          await entity.delete();
        } on FileSystemException {
          // Keep going; temporary files are ignored by the entry bounds.
        }
      } else if (entity is File && entity.path.endsWith('.json')) {
        entries.add(entity);
      }
    }
    entries.sort((left, right) => left.lastModifiedSync().compareTo(right.lastModifiedSync()));
    var totalBytes = entries.fold<int>(0, (total, file) => total + file.lengthSync());
    while (entries.length > maximumEntriesPerProfile || totalBytes > maximumBytesPerProfile) {
      final oldest = entries.removeAt(0);
      totalBytes -= oldest.lengthSync();
      try {
        await oldest.delete();
      } on FileSystemException {
        // The store remains bounded on the next successful write.
      }
    }
  }

  static Future<void> _evictGlobalEntries(Directory root) async {
    if (!await root.exists()) return;
    final entries = <File>[];
    final emptyDirectories = <Directory>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) {
        entries.add(entity);
      } else if (entity is File && entity.path.endsWith('.pending')) {
        try {
          await entity.delete();
        } on FileSystemException {
          // Ignore abandoned temporary files; they do not count as entries.
        }
      }
    }
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Directory && entity.listSync(followLinks: false).isEmpty) emptyDirectories.add(entity);
    }
    entries.sort((left, right) => left.lastModifiedSync().compareTo(right.lastModifiedSync()));
    var totalBytes = entries.fold<int>(0, (total, file) => total + file.lengthSync());
    while (entries.length > maximumTotalEntries || totalBytes > maximumTotalBytes) {
      final oldest = entries.removeAt(0);
      totalBytes -= oldest.lengthSync();
      try {
        await oldest.delete();
      } on FileSystemException {
        // The store remains bounded on the next successful write.
      }
    }
    for (final directory in emptyDirectories.reversed) {
      try {
        if (directory.existsSync() && directory.listSync(followLinks: false).isEmpty) await directory.delete();
      } on FileSystemException {
        // Directory cleanup is best-effort after entry eviction.
      }
    }
  }

  static Future<void> _exclusive(Future<void> Function() action) async {
    final previous = _writeTail;
    final released = Completer<void>();
    _writeTail = released.future;
    await previous;
    try {
      await action();
    } finally {
      released.complete();
    }
  }

  static SubtitleCachedSourceTranscript _copyWithCacheState(
    SubtitleCachedSourceTranscript source, {
    required bool cacheHit,
    required bool persisted,
    List<SubtitleWordTiming>? wordTimings,
  }) => SubtitleCachedSourceTranscript(
    cues: source.cues,
    wordTimings: wordTimings ?? source.wordTimings,
    durationMs: source.durationMs,
    requestedProvider: source.requestedProvider,
    runtimeProvider: source.runtimeProvider,
    fellBackToCpu: source.fellBackToCpu,
    placementEvidence: source.placementEvidence,
    detectedLanguage: source.detectedLanguage,
    cacheHit: cacheHit,
    persisted: persisted,
  );
}

final class _SubtitleDigestOutput implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('WAV snapshot digest was not finalized.'));

  @override
  void add(Digest digest) {
    if (_value != null) throw StateError('WAV snapshot digest was finalized more than once.');
    _value = digest;
  }

  @override
  void close() {}
}
