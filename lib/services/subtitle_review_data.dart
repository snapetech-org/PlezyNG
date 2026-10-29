import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'subtitle_rejection_service.dart';
import 'subtitle_translation_memory.dart';

/// Plaintext transfer of reviewed source/translation text, opaque media IDs and
/// provider revision fingerprints. No server URLs, login data or active track is shared.
final class SubtitleReviewData {
  SubtitleReviewData({required Map<String, Map<String, Object?>> memory, required Map<String, int> rejections})
    : memory = SubtitleTranslationMemory.validatePortable(memory),
      rejections = SubtitleRejectionService.validatePortable(rejections);
  static const maximumBytes = 2 * 1024 * 1024 + 65536;
  final Map<String, Map<String, Object?>> memory;
  final Map<String, int> rejections;
  String get memoryDigest => SubtitleTranslationMemory.digest(memory);
  String get rejectionDigest => SubtitleRejectionService.portableDigest(rejections);
  static Future<SubtitleReviewData> capture(String profile) async => SubtitleReviewData(
    memory: await SubtitleTranslationMemory.portable(profile),
    rejections: await SubtitleRejectionService.portable(profile));

  static Object? _canonical(Object? value) {
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) throw const FormatException('Invalid transfer key.');
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return [for (final item in value) _canonical(item)];
    return value;
  }
  static String _digest(Object value) => sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
  Uint8List encode() {
    final payload = {'memory': memory, 'rejections': rejections};
    final bytes = utf8.encode(jsonEncode({'schema': 1, 'type': 'plezyng.subtitle-review-data',
      'payload': payload, 'sha256': _digest(payload)}));
    if (bytes.length > maximumBytes) throw const FormatException('Subtitle review data limit.');
    return Uint8List.fromList(bytes);
  }
  static SubtitleReviewData decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes) throw const FormatException('Subtitle review data limit.');
    final raw = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (raw is! Map || raw['schema'] != 1 || raw['type'] != 'plezyng.subtitle-review-data' || raw['payload'] is! Map) {
      throw const FormatException('Invalid subtitle review data.');
    }
    final payload = raw['payload'] as Map;
    // Validate schema bounds before canonical traversal of external structures.
    final memory = SubtitleTranslationMemory.validatePortable(payload['memory']);
    final rejections = SubtitleRejectionService.validatePortable(payload['rejections']);
    if (payload.length != 2 || raw['sha256'] != _digest(payload)) throw const FormatException('Review data digest mismatch.');
    return SubtitleReviewData(memory: memory, rejections: rejections);
  }
  Set<String> conflictsWith(SubtitleReviewData current) => {
    for (final entry in memory.entries)
      if (current.memory.containsKey(entry.key) && current.memory[entry.key]!['text'] != entry.value['text']) entry.key,
  };
}
