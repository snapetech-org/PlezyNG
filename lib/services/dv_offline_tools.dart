import 'dart:io';

import 'package:path/path.dart' as p;

/// The packaged converter owns its interpreter, plugins and encoder runtime.
abstract final class DvOfflineTools {
  static String get executable => p.join(p.dirname(Platform.resolvedExecutable), 'tools', 'dv', 'plezyng-dv-convert');

  static Map<String, String> processEnvironment(Map<String, String> inherited) => Map<String, String>.from(inherited)
    ..remove('LD_LIBRARY_PATH')
    ..remove('LD_PRELOAD')
    ..remove('PYTHONHOME')
    ..remove('PYTHONPATH');

  static bool validFrameRate(String value) {
    if (!RegExp(r'^\d+(?:/\d+|\.\d+)?$').hasMatch(value)) return false;
    final parts = value.split('/');
    final numerator = double.tryParse(parts.first);
    final denominator = parts.length == 2 ? double.tryParse(parts.last) : 1.0;
    if (numerator == null || denominator == null || denominator <= 0) return false;
    final rate = numerator / denominator;
    return rate.isFinite && rate >= 1 && rate <= 120;
  }

  static List<String> arguments({
    required String base,
    required String enhancement,
    required String fps,
    required String target,
    required String output,
  }) {
    if (!validFrameRate(fps) ||
        !{'hdr10', 'sdr'}.contains(target) ||
        p.equals(base, enhancement) ||
        p.extension(output) != '.mkv') {
      throw ArgumentError('Invalid offline Dolby Vision export request');
    }
    return ['--bl', base, '--el', enhancement, '--fps', fps, '--target', target, '--output', output, '--execute'];
  }
}
