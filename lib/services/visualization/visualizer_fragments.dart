import 'dart:convert';
import 'visualizer_content_limits.dart';
import 'visualizer_preset_text.dart';

/// Data-only composition. Preserve equations and unknown fields without eval.
abstract final class VisualizerFragments {
  static final _indexed = RegExp(r'^(shape|wave)(?:code_?|_)?(\d+)_(.+)$', caseSensitive: false);
  static final _equation = RegExp(r'^(init|per_frame_init|per_frame|per_point)(?:_?\d+)?$', caseSensitive: false);

  static Map<int, List<MapEntry<String, String>>> parse(String source, String kind) {
    if (kind != 'shape' && kind != 'wave') throw const FormatException('Expected a shape or wave fragment.');
    final result = <int, List<MapEntry<String, String>>>{};
    var numbered = false, standalone = false, lineNumber = 0;
    for (final line in const LineSplitter().convert(source)) {
      lineNumber++;
      final text = line.trim();
      if (text.isEmpty || text.startsWith('//') || text.startsWith(';') ||
          RegExp(r'^\[(shape\d*|wave\d*|preset\d+)\]$', caseSensitive: false).hasMatch(text)) continue;
      final equals = text.indexOf('=');
      if (equals <= 0) throw FormatException('Fragment line $lineNumber: expected key=value.');
      var key = text.substring(0, equals).trim();
      final value = text.substring(equals + 1);
      final indexed = _indexed.firstMatch(key);
      var index = 0;
      if (indexed != null) {
        if (indexed[1]!.toLowerCase() != kind) throw FormatException('Fragment line $lineNumber: mixed object types.');
        numbered = true;
        index = int.tryParse(indexed[2]!) ?? 64;
        key = indexed[3]!;
      } else {
        standalone = true;
      }
      if (index >= 64 || !RegExp(r'^[A-Za-z_][A-Za-z_0-9]{0,127}$').hasMatch(key) || (numbered && standalone)) {
        throw FormatException('Fragment line $lineNumber: invalid or mixed object indexing.');
      }
      (result[index] ??= []).add(MapEntry(key, value));
    }
    if (result.isEmpty || result.length > 64) throw const FormatException('The fragment contains no bounded objects.');
    return result;
  }

  static String compose(List<int> preset, List<int> fragment, String kind) {
    VisualizerContentLimits.checkPreset(preset);
    VisualizerContentLimits.checkPreset(fragment);
    final parent = VisualizerPresetText.decode(preset), source = VisualizerPresetText.decode(fragment);
    if (RegExp(r'^\s*\[preset0*[1-9]\d*\]', multiLine: true, caseSensitive: false).hasMatch(parent) ||
        parent.contains('MILKDROP_DOUBLE_PRESET')) {
      throw const FormatException('Choose a single classic preset for fragment composition.');
    }
    final occupied = <int>{};
    for (final line in const LineSplitter().convert(parent)) {
      final entry = _indexed.firstMatch(line.trim().split('=').first.trim());
      if (entry != null && entry[1]!.toLowerCase() == kind) occupied.add(int.tryParse(entry[2]!) ?? 64);
    }
    final objects = parse(source, kind), lines = <String>[parent, '; User-composed $kind fragments'];
    for (final key in objects.keys.toList()..sort()) {
      final available = List.generate(4, (i) => i).where((index) => !occupied.contains(index));
      if (available.isEmpty) throw const FormatException('The preset has no free slots among its four supported objects.');
      final index = available.first;
      occupied.add(index);
      lines.add('${kind}code_${index}_enabled=1');
      for (final entry in objects[key]!) {
        if (_equation.hasMatch(entry.key)) {
          final name = entry.key.toLowerCase().replaceFirst('per_frame_init', 'init');
          lines.add('${kind}_${index}_$name=${entry.value}');
        } else {
          lines.add('${kind}code_${index}_${entry.key}=${entry.value}');
        }
      }
    }
    final output = '${lines.join('\n')}\n';
    VisualizerContentLimits.checkPreset(utf8.encode(output));
    return output;
  }

  static Map<int, String> extract(List<int> preset, String kind) {
    VisualizerContentLimits.checkPreset(preset);
    final text = VisualizerPresetText.decode(preset), indexed = <String>[];
    if (RegExp(r'^\s*\[preset0*[1-9]\d*\]', multiLine: true, caseSensitive: false).hasMatch(text)) {
      throw const FormatException('Choose a single classic preset to export fragments.');
    }
    for (final line in const LineSplitter().convert(text)) {
      final match = _indexed.firstMatch(line.trim().split('=').first.trim());
      if (match != null && match[1]!.toLowerCase() == kind) indexed.add(line);
    }
    if (indexed.isEmpty) return const {};
    final objects = parse(indexed.join('\n'), kind);
    return {for (final item in objects.entries)
      item.key: '[$kind]\n${item.value.map((value) => '${value.key}=${value.value}').join('\n')}\n'};
  }
}
