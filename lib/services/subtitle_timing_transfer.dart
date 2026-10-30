import 'dart:convert';
import 'dart:typed_data';

import 'library_sync_correction.dart';
import 'player_sync_offsets.dart';

/// A single native subtitle correction. No device-output audio delay, profile
/// ID, media URL, file path or account credential is present in this document.
final class SubtitleTimingTransfer {
  const SubtitleTimingTransfer({required this.bindingKey, required this.property, required this.value});
  final String bindingKey, property;
  final LibrarySyncValue value;
  static const maximumBytes = 4096;
  static const _schema = 'plezyng.native-subtitle-correction.v1';

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
    'schema': _schema, 'binding': bindingKey, 'property': property,
    'clock': 'opened-file', 'delayMs': value.delayMs, 'rate': value.rate,
  })));

  static SubtitleTimingTransfer decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes) throw const FormatException('Timing document exceeds 4 KiB.');
    final data = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (data is! Map<String, dynamic> || data.length != 6 || data['schema'] != _schema ||
        data['clock'] != 'opened-file' || data['binding'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['binding']) ||
        !const [PlayerSyncOffsets.subtitleProperty, PlayerSyncOffsets.secondarySubtitleProperty].contains(data['property'])) {
      throw const FormatException('Unsupported native subtitle correction.');
    }
    final value = LibrarySyncValue.decode(data);
    if (value == null || data['property'] == PlayerSyncOffsets.secondarySubtitleProperty && value.rate != 1) {
      throw const FormatException('Invalid native subtitle correction.');
    }
    return SubtitleTimingTransfer(bindingKey: data['binding'], property: data['property'], value: value);
  }

  void requireBinding(LibrarySyncBinding binding) {
    binding.checkCurrent();
    if (binding.key != bindingKey || binding.property != property) {
      throw const FormatException('This correction belongs to a different copy, backend or track selection.');
    }
  }

  Future<void> save(LibrarySyncBinding binding, {required LibrarySyncValue? expected}) async {
    requireBinding(binding);
    await LibrarySyncCorrections.write(binding.profileId, binding.key, value,
      compareExisting: true, expectedValue: expected, checkCurrent: () => requireBinding(binding));
  }
}
