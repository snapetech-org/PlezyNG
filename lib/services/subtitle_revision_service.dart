import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

final RegExp _stableSubtitleCueIdPattern = RegExp(r'^[0-9a-f]{64}$');

/// Stable local scope for revisions belonging to one profile and media item.
final class SubtitleRevisionIdentity {
  const SubtitleRevisionIdentity({
    required this.profileId,
    required this.serverId,
    required this.ratingKey,
    required this.mediaIndex,
    this.mediaTitle,
    this.sourceLabel,
  });

  final String profileId;
  final String serverId;
  final String ratingKey;
  final int mediaIndex;
  final String? mediaTitle;
  final String? sourceLabel;

  String get storageKey => sha256
      .convert(utf8.encode([profileId.trim(), serverId.trim(), ratingKey.trim(), mediaIndex.toString()].join('\u0000')))
      .toString();
}

/// A transcript from the local library, which may belong to another provider
/// or source item in the same active profile.
final class SavedSubtitleTranscript {
  const SavedSubtitleTranscript({
    required this.storageKey,
    required this.mediaTitle,
    required this.sourceLabel,
    required this.transcriptId,
    required this.createdAt,
    required this.cueCount,
    required this.languageCode,
    this.revision,
  });

  final String storageKey;
  final String mediaTitle;
  final String sourceLabel;
  final String transcriptId;
  final DateTime createdAt;
  final int cueCount;
  final String? languageCode;
  final SubtitleRevision? revision;

  SubtitleRevision get loadedRevision =>
      revision ?? (throw StateError('Saved transcript cues have not been loaded yet.'));

  SavedSubtitleTranscript withRevision(SubtitleRevision value) => SavedSubtitleTranscript(
    storageKey: storageKey,
    mediaTitle: mediaTitle,
    sourceLabel: sourceLabel,
    transcriptId: transcriptId,
    createdAt: createdAt,
    cueCount: cueCount,
    languageCode: languageCode,
    revision: value,
  );
}

/// An immutable reviewed subtitle result that can be re-attached or exported.
final class SubtitleRevision {
  const SubtitleRevision({
    required this.id,
    required this.createdAt,
    required this.operation,
    required this.languageCode,
    required this.cues,
    required this.wordTimings,
  });

  final String id;
  final DateTime createdAt;
  final String operation;
  final String? languageCode;
  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> wordTimings;

  Map<String, Object?> toJson() => {
    'schema': 'plezyng.subtitle-revision.v1',
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'operation': operation,
    'languageCode': languageCode,
    'cues': cues
        .map(
          (cue) => {
            'cueId': cue.stableId,
            'index': cue.index,
            'startMs': cue.startMs,
            'endMs': cue.endMs,
            'text': cue.text,
          },
        )
        .toList(growable: false),
    'wordTimings': wordTimings
        .map(
          (timing) => {
            'startMs': timing.startMs,
            'endMs': timing.endMs,
            'text': timing.text,
            'confidence': timing.confidence,
            'unit': timing.unit.name,
            'cueIndex': timing.cueIndex,
            'cueId': timing.cueId,
          },
        )
        .toList(growable: false),
  };

  static SubtitleRevision fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['schema'] != 'plezyng.subtitle-revision.v1') {
      throw const FormatException('Unsupported subtitle revision record.');
    }
    final id = value['id'];
    final createdAt = DateTime.tryParse(value['createdAt'] as String? ?? '');
    final operation = value['operation'];
    final language = value['languageCode'];
    final rawCues = value['cues'];
    final rawWords = value['wordTimings'];
    if (id is! String ||
        !RegExp(r'^\d+_[0-9a-f]+$').hasMatch(id) ||
        createdAt == null ||
        operation is! String ||
        operation.trim().isEmpty ||
        operation.length > 120 ||
        (language != null && (language is! String || language.length > 24)) ||
        rawCues is! List ||
        rawWords is! List ||
        rawCues.isEmpty ||
        rawCues.length > SubtitleRetimer.maximumCueCount ||
        rawWords.length > 250000) {
      throw const FormatException('Subtitle revision metadata is invalid.');
    }

    final cues = <SubtitleCue>[];
    final seenCueIndexes = <int>{};
    final seenCueIds = <String>{};
    for (final row in rawCues) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Subtitle revision cue is invalid.');
      }
      final index = row['index'];
      final start = row['startMs'];
      final end = row['endMs'];
      final text = row['text'];
      final cueId = row['cueId'];
      if (index is! int ||
          start is! int ||
          end is! int ||
          text is! String ||
          (cueId != null && (cueId is! String || !_stableSubtitleCueIdPattern.hasMatch(cueId))) ||
          text.length > SubtitleRetimer.maximumInputBytes ||
          index < 1 ||
          index > SubtitleRetimer.maximumCueCount ||
          start < 0 ||
          end <= start ||
          end > SubtitleRetimer.maximumTimeMs) {
        throw const FormatException('Subtitle revision cue timing or text is invalid.');
      }
      final cue = SubtitleCue(index: index, startMs: start, endMs: end, text: text, cueId: cueId as String?);
      if (!seenCueIndexes.add(index) || !seenCueIds.add(cue.stableId)) {
        throw const FormatException('Subtitle revision contains duplicate cue identity.');
      }
      cues.add(cue);
    }

    final wordTimings = <SubtitleWordTiming>[];
    final cuesByIndex = <int, SubtitleCue>{for (final cue in cues) cue.index: cue};
    final cuesById = <String, SubtitleCue>{for (final cue in cues) cue.stableId: cue};
    for (final row in rawWords) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Subtitle revision word timing is invalid.');
      }
      final start = row['startMs'];
      final end = row['endMs'];
      final text = row['text'];
      final confidence = row['confidence'];
      final unitName = row['unit'];
      final cueIndex = row['cueIndex'];
      final cueId = row['cueId'];
      if (start is! int ||
          end is! int ||
          text is! String ||
          confidence is! num ||
          unitName is! String ||
          (cueIndex != null && cueIndex is! int) ||
          (cueId != null && (cueId is! String || !_stableSubtitleCueIdPattern.hasMatch(cueId))) ||
          start < 0 ||
          end <= start ||
          end > SubtitleRetimer.maximumTimeMs ||
          text.length > 4096 ||
          confidence < 0 ||
          confidence > 1 ||
          (cueIndex != null && (cueIndex as int) < 1)) {
        throw const FormatException('Subtitle revision word timing fields are invalid.');
      }
      final unit = SubtitleWordTimingUnit.values.where((candidate) => candidate.name == unitName);
      if (unit.isEmpty) throw const FormatException('Subtitle revision timing unit is invalid.');
      final cueIndexValue = cueIndex as int?;
      final cueIdValue = cueId as String?;
      final indexedCue = cueIndexValue == null ? null : cuesByIndex[cueIndexValue];
      final identifiedCue = cueIdValue == null ? null : cuesById[cueIdValue];
      if ((cueIndex != null && indexedCue == null) || (cueId != null && identifiedCue == null)) {
        throw const FormatException('Subtitle revision word timing refers to a missing cue.');
      }
      if (cueIdValue != null && indexedCue != null && indexedCue.stableId != cueIdValue) {
        throw const FormatException('Subtitle revision word timing refers to a different cue.');
      }
      final linkedCue = identifiedCue ?? indexedCue;
      wordTimings.add(
        SubtitleWordTiming(
          startMs: start,
          endMs: end,
          text: text,
          confidence: confidence.toDouble(),
          unit: unit.first,
          cueIndex: cueIndexValue ?? linkedCue?.index,
          cueId: cueIdValue ?? linkedCue?.stableId,
        ),
      );
    }

    return SubtitleRevision(
      id: id,
      createdAt: createdAt.toUtc(),
      operation: operation,
      languageCode: language as String?,
      cues: List<SubtitleCue>.unmodifiable(cues),
      wordTimings: List<SubtitleWordTiming>.unmodifiable(wordTimings),
    );
  }
}

/// Device-local, bounded history for reviewed results on library or source items.
///
/// Records are stored in the app support directory, scoped by a one-way hash of
/// the profile and server-or-source item/media identity. The history never
/// synchronizes to a server and does not modify the source subtitle or playback
/// track.
abstract final class SubtitleRevisionService {
  static const int maximumRevisionsPerItem = 12;
  static const int maximumRevisionBytes = 8 * 1024 * 1024;
  static const int maximumHistoryBytesPerItem = 24 * 1024 * 1024;
  static const int maximumTotalRevisionFiles = 1000;
  static const int maximumTotalRevisionBytes = 256 * 1024 * 1024;
  static const int maximumTranscriptLibraryItems = 100;
  static const int maximumTranscriptLibraryScanItems = 2000;

  static const String _itemMetadataName = 'item.json';
  static const String _itemMetadataSchema = 'plezyng.subtitle-revision-item.v1';

  /// Produces a stable, non-reversible provider label for the local index.
  static String privacySafeSourceLabel(String kind, String identifier) {
    final normalizedKind = _label(kind, fallback: 'Source', maximumLength: 24);
    final normalizedIdentifier = identifier.trim();
    if (normalizedIdentifier.isEmpty) return normalizedKind;
    final digest = sha256.convert(utf8.encode(normalizedIdentifier)).toString();
    return '$normalizedKind ${digest.substring(0, 8)}';
  }

  static Future<void> _writeTail = Future<void>.value();

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

  static Future<Directory> _rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'subtitle-revisions'));
    await root.create(recursive: true);
    return root;
  }

  static Future<Directory> _directoryFor(SubtitleRevisionIdentity identity) async {
    final root = await _rootDirectory();
    final directory = Directory(p.join(root.path, identity.storageKey));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<SubtitleRevision> saveRevision({
    required SubtitleRevisionIdentity identity,
    required String operation,
    required String? languageCode,
    required List<SubtitleCue> cues,
    required List<SubtitleWordTiming> wordTimings,
  }) async {
    late SubtitleRevision revision;
    await _exclusive(() async {
      if (identity.profileId.trim().isEmpty ||
          identity.serverId.trim().isEmpty ||
          identity.ratingKey.trim().isEmpty ||
          identity.mediaIndex < 0) {
        throw ArgumentError('Subtitle revision identity is incomplete.');
      }
      if (operation.trim().isEmpty ||
          operation.length > 120 ||
          (languageCode?.length ?? 0) > 24 ||
          cues.isEmpty ||
          cues.length > SubtitleRetimer.maximumCueCount ||
          wordTimings.length > 250000) {
        throw const FormatException('Subtitle revision exceeds the supported metadata or cue bound.');
      }
      final cuesByIndex = <int, SubtitleCue>{};
      final cuesById = <String, SubtitleCue>{};
      for (final cue in cues) {
        if (cue.startMs < 0 ||
            cue.endMs <= cue.startMs ||
            cue.endMs > SubtitleRetimer.maximumTimeMs ||
            cue.text.length > SubtitleRetimer.maximumInputBytes ||
            cue.index < 1 ||
            !_stableSubtitleCueIdPattern.hasMatch(cue.stableId) ||
            cuesByIndex.containsKey(cue.index) ||
            cuesById.containsKey(cue.stableId)) {
          throw const FormatException('Subtitle revision contains an invalid cue.');
        }
        cuesByIndex[cue.index] = cue;
        cuesById[cue.stableId] = cue;
      }
      final savedWordTimings = <SubtitleWordTiming>[];
      for (final timing in wordTimings) {
        if (timing.startMs < 0 ||
            timing.endMs <= timing.startMs ||
            timing.endMs > SubtitleRetimer.maximumTimeMs ||
            timing.text.length > 4096 ||
            !timing.confidence.isFinite ||
            timing.confidence < 0 ||
            timing.confidence > 1 ||
            (timing.cueIndex != null && !cuesByIndex.containsKey(timing.cueIndex!)) ||
            (timing.cueId != null && !cuesById.containsKey(timing.cueId!))) {
          throw const FormatException('Subtitle revision contains an invalid word timing.');
        }
        final indexedCue = timing.cueIndex == null ? null : cuesByIndex[timing.cueIndex!];
        final identifiedCue = timing.cueId == null ? null : cuesById[timing.cueId!];
        if (indexedCue != null && identifiedCue != null && indexedCue.stableId != identifiedCue.stableId) {
          throw const FormatException('Subtitle revision word timing refers to different cues.');
        }
        final linkedCue = identifiedCue ?? indexedCue;
        savedWordTimings.add(
          timing.withCueIndex(timing.cueIndex ?? linkedCue?.index, cueId: linkedCue?.stableId),
        );
      }
      final now = DateTime.now().toUtc();
      final directory = await _directoryFor(identity);
      var idTimestamp = now.microsecondsSinceEpoch;
      late String id;
      late File target;
      do {
        id = '${idTimestamp}_${idTimestamp.toRadixString(16)}';
        target = File(p.join(directory.path, '$id.json'));
        if (!await target.exists()) break;
        idTimestamp++;
      } while (true);
      revision = SubtitleRevision(
        id: id,
        createdAt: now,
        operation: operation.trim(),
        languageCode: languageCode?.trim().isEmpty == true ? null : languageCode?.trim(),
        cues: List<SubtitleCue>.unmodifiable(cues),
        wordTimings: List<SubtitleWordTiming>.unmodifiable(savedWordTimings),
      );
      final bytes = utf8.encode(jsonEncode(revision.toJson()));
      if (bytes.length > maximumRevisionBytes) {
        throw const FormatException('This reviewed result is too large for local revision history.');
      }
      final temporary = File(p.join(directory.path, '.tmp-$id'));
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(target.path);
        await _writeItemMetadata(
          directory,
          identity,
          transcript: operation.trim() == 'Captured playback transcript' && cues.length >= 3 ? revision : null,
        );
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      await _pruneItem(directory);
      await _pruneGlobal(await _rootDirectory());
    });
    return revision;
  }

  static Future<List<SubtitleRevision>> loadRevisions(SubtitleRevisionIdentity identity) async {
    await _writeTail;
    final directory = Directory(p.join((await _rootDirectory()).path, identity.storageKey));
    if (!await directory.exists()) return const <SubtitleRevision>[];
    final files = await _revisionFiles(directory);
    await _sortNewestFirst(files);
    final output = <SubtitleRevision>[];
    var totalBytes = 0;
    for (final file in files) {
      if (output.length >= maximumRevisionsPerItem) break;
      final length = await file.length();
      if (length <= 0 || length > maximumRevisionBytes || totalBytes + length > maximumHistoryBytesPerItem) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        final revision = SubtitleRevision.fromJson(decoded);
        final expected = p.basenameWithoutExtension(file.path);
        if (revision.id != expected) throw const FormatException('Revision filename does not match its record.');
        output.add(revision);
        totalBytes += length;
      } catch (_) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    return List<SubtitleRevision>.unmodifiable(output);
  }

  /// Lists recent saved playback transcripts in [profileId].
  /// The lightweight index contains only display labels and a hash of the
  /// profile ID; provider and media identifiers remain only in the directory
  /// hash and are never written to the index.
  static Future<List<SavedSubtitleTranscript>> loadSavedTranscripts({
    required String profileId,
    SubtitleRevisionIdentity? currentIdentity,
    int limit = maximumTranscriptLibraryItems,
  }) async {
    await _writeTail;
    final normalizedProfileId = profileId.trim();
    if (normalizedProfileId.isEmpty) return const <SavedSubtitleTranscript>[];
    final boundedLimit = limit.clamp(1, maximumTranscriptLibraryItems).toInt();
    final expectedProfileHash = sha256.convert(utf8.encode(normalizedProfileId)).toString();
    final root = await _rootDirectory();
    if (currentIdentity != null && currentIdentity.profileId.trim() == normalizedProfileId) {
      final currentDirectory = Directory(p.join(root.path, currentIdentity.storageKey));
      final currentMetadata = File(p.join(currentDirectory.path, _itemMetadataName));
      var metadataValid = false;
      try {
        if (await currentMetadata.length() <= 4096) {
          final decoded = jsonDecode(await currentMetadata.readAsString());
          metadataValid = decoded is Map<String, dynamic> &&
              decoded['schema'] == _itemMetadataSchema &&
              decoded['profileHash'] == expectedProfileHash;
        }
      } catch (_) {}
      if (await currentDirectory.exists() && !metadataValid) {
        await _exclusive(() async {
          await _writeItemMetadata(currentDirectory, currentIdentity);
        });
      }
    }
    final items = <_TranscriptLibraryItem>[];
    var scanned = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entity.path))) continue;
      scanned++;
      if (scanned > maximumTranscriptLibraryScanItems) break;
      final metadataFile = File(p.join(entity.path, _itemMetadataName));
      try {
        final metadataLength = await metadataFile.length();
        if (metadataLength <= 0 || metadataLength > 4096) continue;
        final decoded = jsonDecode(await metadataFile.readAsString());
        if (decoded is! Map<String, dynamic> ||
            decoded['schema'] != _itemMetadataSchema ||
            decoded['profileHash'] != expectedProfileHash) {
          continue;
        }
        final mediaTitle = decoded['mediaTitle'];
        final sourceLabel = decoded['sourceLabel'];
        if (mediaTitle is! String || sourceLabel is! String) continue;
        var pointers = _readTranscriptPointers(decoded);
        if (pointers == null) {
          // Migrate prior item metadata and revision-only history once. Cue
          // payloads are discarded here; selection loads only one full record.
          final discovered = await _findTranscriptPointers(entity);
          await _exclusive(() async {
            await _writeTranscriptPointers(metadataFile, decoded, pointers: discovered);
          });
          pointers = discovered;
        }
        final currentPointers = pointers ?? const <_TranscriptPointer>[];
        final validPointers = <_TranscriptPointer>[];
        for (final pointer in currentPointers) {
          final transcriptFile = File(p.join(entity.path, '${pointer.id}.json'));
          if (!await transcriptFile.exists()) continue;
          final transcriptLength = await transcriptFile.length();
          if (transcriptLength <= 0 || transcriptLength > maximumRevisionBytes) continue;
          validPointers.add(pointer);
          items.add(
            _TranscriptLibraryItem(
              storageKey: p.basename(entity.path),
              mediaTitle: mediaTitle,
              sourceLabel: sourceLabel,
              transcriptId: pointer.id,
              createdAt: pointer.createdAt,
              cueCount: pointer.cueCount,
              languageCode: pointer.languageCode,
            ),
          );
        }
        if (validPointers.length != currentPointers.length) {
          if (validPointers.isEmpty) {
            final recovered = await _findTranscriptPointers(entity);
            validPointers
              ..clear()
              ..addAll(recovered);
            // The recovery scan may discover an older transcript after global
            // pruning removed every item in the saved index.
            for (final pointer in validPointers) {
              items.add(
                _TranscriptLibraryItem(
                  storageKey: p.basename(entity.path),
                  mediaTitle: mediaTitle,
                  sourceLabel: sourceLabel,
                  transcriptId: pointer.id,
                  createdAt: pointer.createdAt,
                  cueCount: pointer.cueCount,
                  languageCode: pointer.languageCode,
                ),
              );
            }
          }
          await _exclusive(() async {
            await _writeTranscriptPointers(metadataFile, decoded, pointers: validPointers);
          });
        }
        items.sort((left, right) => right.createdAt.compareTo(left.createdAt));
        if (items.length > boundedLimit) items.removeRange(boundedLimit, items.length);
      } catch (_) {
        // A damaged or old index entry is ignored; it must not block others.
      }
    }
    return List<SavedSubtitleTranscript>.unmodifiable(
      items.take(boundedLimit).map(
        (item) => SavedSubtitleTranscript(
          storageKey: item.storageKey,
          mediaTitle: item.mediaTitle,
          sourceLabel: item.sourceLabel,
          transcriptId: item.transcriptId,
          createdAt: item.createdAt,
          cueCount: item.cueCount,
          languageCode: item.languageCode,
        ),
      ),
    );
  }

  /// Loads a selected transcript after the user chooses it from the library.
  /// The item hash and revision identifier are validated before a file is read.
  static Future<SavedSubtitleTranscript?> loadSavedTranscript(SavedSubtitleTranscript transcript) async {
    await _writeTail;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(transcript.storageKey) ||
        !RegExp(r'^\d+_[0-9a-f]+$').hasMatch(transcript.transcriptId)) {
      throw const FormatException('Saved transcript identity is invalid.');
    }
    final directory = Directory(p.join((await _rootDirectory()).path, transcript.storageKey));
    final file = File(p.join(directory.path, '${transcript.transcriptId}.json'));
    final length = await file.length();
    if (length <= 0 || length > maximumRevisionBytes) return null;
    try {
      final revision = SubtitleRevision.fromJson(jsonDecode(await file.readAsString()));
      if (revision.id != transcript.transcriptId ||
          revision.operation != 'Captured playback transcript' ||
          revision.cues.length < 3) {
        return null;
      }
      return transcript.withRevision(revision);
    } on FormatException {
      return null;
    }
  }

  static Future<void> deleteRevision(SubtitleRevisionIdentity identity, String id) async {
    if (!RegExp(r'^\d+_[0-9a-f]+$').hasMatch(id)) {
      throw const FormatException('Subtitle revision identifier is invalid.');
    }
    await _exclusive(() async {
      final directory = Directory(p.join((await _rootDirectory()).path, identity.storageKey));
      final file = File(p.join(directory.path, '$id.json'));
      if (await file.exists()) await file.delete();
    });
  }

  static Future<List<File>> _revisionFiles(Directory directory) async {
    final entities = await directory.list(followLinks: false).toList();
    return entities
        .whereType<File>()
        .where((file) => RegExp(r'^\d+_[0-9a-f]+\.json$').hasMatch(p.basename(file.path)))
        .toList();
  }

  static Future<List<_TranscriptPointer>> _findTranscriptPointers(Directory directory) async {
    final files = await _revisionFiles(directory);
    await _sortNewestFirst(files);
    final pointers = <_TranscriptPointer>[];
    for (final file in files) {
      final length = await file.length();
      if (length <= 0 || length > maximumRevisionBytes) continue;
      try {
        final revision = SubtitleRevision.fromJson(jsonDecode(await file.readAsString()));
        if (revision.id != p.basenameWithoutExtension(file.path)) {
          throw const FormatException('Revision filename does not match its record.');
        }
        if (revision.operation == 'Captured playback transcript' && revision.cues.length >= 3) {
          pointers.add(_TranscriptPointer.fromRevision(revision));
          if (pointers.length >= maximumRevisionsPerItem) break;
        }
      } catch (_) {
        // The ordinary item history loader also removes malformed revisions.
      }
    }
    return pointers;
  }

  static Future<void> _writeItemMetadata(
    Directory directory,
    SubtitleRevisionIdentity identity, {
    SubtitleRevision? transcript,
  }) async {
    final target = File(p.join(directory.path, _itemMetadataName));
    Map<String, dynamic>? existing;
    try {
      if (await target.exists() && await target.length() <= 4096) {
        final value = jsonDecode(await target.readAsString());
        if (value is Map<String, dynamic>) existing = value;
      }
    } catch (_) {}
    var pointers =
        (existing == null ? null : _readTranscriptPointers(existing)) ?? await _findTranscriptPointers(directory);
    if (transcript != null) {
      pointers.removeWhere((pointer) => pointer.id == transcript.id);
      pointers.add(_TranscriptPointer.fromRevision(transcript));
    }
    pointers.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    if (pointers.length > maximumRevisionsPerItem) {
      pointers = pointers.take(maximumRevisionsPerItem).toList(growable: true);
    }
    final metadata = <String, Object?>{
      'schema': _itemMetadataSchema,
      'profileHash': sha256.convert(utf8.encode(identity.profileId.trim())).toString(),
      'mediaTitle': _label(identity.mediaTitle, fallback: 'Saved media item', maximumLength: 200),
      'sourceLabel': _label(identity.sourceLabel, fallback: 'Media library', maximumLength: 120),
      'savedTranscripts': pointers.map((pointer) => pointer.toJson()).toList(growable: false),
      if (pointers.isNotEmpty) ...pointers.first.toLatestJson(),
    };
    await _writeMetadataAtomically(target, metadata);
  }

  static List<_TranscriptPointer>? _readTranscriptPointers(Map<String, dynamic> metadata) {
    final rows = metadata['savedTranscripts'];
    if (rows is! List) return null;
    final pointersById = <String, _TranscriptPointer>{};
    for (final row in rows) {
      final pointer = _TranscriptPointer.tryParse(row);
      if (pointer != null) pointersById[pointer.id] = pointer;
    }
    final pointers = pointersById.values.toList(growable: true)
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    if (pointers.length > maximumRevisionsPerItem) {
      pointers.removeRange(maximumRevisionsPerItem, pointers.length);
    }
    return pointers;
  }

  static Future<void> _writeTranscriptPointers(
    File target,
    Map<String, dynamic> existing, {
    required List<_TranscriptPointer> pointers,
  }) async {
    final metadata = Map<String, Object?>.from(existing)
      ..remove('latestTranscriptId')
      ..remove('latestTranscriptCreatedAt')
      ..remove('latestTranscriptCueCount')
      ..remove('latestTranscriptLanguageCode')
      ..['savedTranscripts'] = pointers.map((pointer) => pointer.toJson()).toList(growable: false);
    if (pointers.isNotEmpty) metadata.addAll(pointers.first.toLatestJson());
    await _writeMetadataAtomically(target, metadata);
  }

  static Future<void> _writeMetadataAtomically(File target, Map<String, Object?> metadata) async {
    final temporary = File('${target.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(metadata), flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static String _label(String? value, {required String fallback, required int maximumLength}) {
    final cleaned = (value ?? '').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    if (cleaned.isEmpty) return fallback;
    return cleaned.length <= maximumLength ? cleaned : cleaned.substring(0, maximumLength);
  }

  static Future<void> _sortNewestFirst(List<File> files) async {
    files.sort((left, right) => _timestampFromName(right).compareTo(_timestampFromName(left)));
  }

  static int _timestampFromName(File file) {
    final name = p.basenameWithoutExtension(file.path);
    return int.tryParse(name.split('_').first) ?? 0;
  }

  static Future<void> _pruneItem(Directory directory) async {
    final files = await _revisionFiles(directory);
    await _sortNewestFirst(files);
    final sizes = <int>[];
    var total = 0;
    for (final file in files) {
      final size = await file.length();
      sizes.add(size);
      total += size;
    }
    var keep = files.length;
    while (keep > maximumRevisionsPerItem || total > maximumHistoryBytesPerItem) {
      keep--;
      total -= sizes[keep];
      await files[keep].delete();
    }
  }

  static Future<void> _pruneGlobal(Directory root) async {
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && RegExp(r'^\d+_[0-9a-f]+\.json$').hasMatch(p.basename(entity.path))) files.add(entity);
    }
    await _sortNewestFirst(files);
    final sizes = <int>[];
    var total = 0;
    for (final file in files) {
      final size = await file.length();
      sizes.add(size);
      total += size;
    }
    var keep = files.length;
    while (keep > maximumTotalRevisionFiles || total > maximumTotalRevisionBytes) {
      keep--;
      total -= sizes[keep];
      await files[keep].delete();
    }
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entity.path))) continue;
      if ((await _revisionFiles(entity)).isNotEmpty) continue;
      final children = await entity.list(followLinks: false).toList();
      if (children.every((child) => child is File && p.basename(child.path) == _itemMetadataName)) {
        for (final child in children.whereType<File>()) {
          await child.delete();
        }
        await entity.delete();
      }
    }
  }
}

final class _TranscriptPointer {
  const _TranscriptPointer({
    required this.id,
    required this.createdAt,
    required this.cueCount,
    required this.languageCode,
  });

  final String id;
  final DateTime createdAt;
  final int cueCount;
  final String? languageCode;

  static _TranscriptPointer? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = value['id'];
    final createdAtText = value['createdAt'];
    final cueCount = value['cueCount'];
    final languageCode = value['languageCode'];
    final createdAt = DateTime.tryParse(createdAtText is String ? createdAtText : '')?.toUtc();
    if (id is! String ||
        !RegExp(r'^\d+_[0-9a-f]+$').hasMatch(id) ||
        createdAt == null ||
        cueCount is! int ||
        cueCount < 3 ||
        (languageCode != null && languageCode is! String)) {
      return null;
    }
    return _TranscriptPointer(
      id: id,
      createdAt: createdAt,
      cueCount: cueCount,
      languageCode: languageCode as String?,
    );
  }

  factory _TranscriptPointer.fromRevision(SubtitleRevision revision) => _TranscriptPointer(
    id: revision.id,
    createdAt: revision.createdAt.toUtc(),
    cueCount: revision.cues.length,
    languageCode: revision.languageCode,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'cueCount': cueCount,
    'languageCode': languageCode,
  };

  Map<String, Object?> toLatestJson() => {
    'latestTranscriptId': id,
    'latestTranscriptCreatedAt': createdAt.toUtc().toIso8601String(),
    'latestTranscriptCueCount': cueCount,
    'latestTranscriptLanguageCode': languageCode,
  };
}

final class _TranscriptLibraryItem {
  const _TranscriptLibraryItem({
    required this.storageKey,
    required this.mediaTitle,
    required this.sourceLabel,
    required this.transcriptId,
    required this.createdAt,
    required this.cueCount,
    required this.languageCode,
  });

  final String storageKey;
  final String mediaTitle;
  final String sourceLabel;
  final String transcriptId;
  final DateTime createdAt;
  final int cueCount;
  final String? languageCode;
}
