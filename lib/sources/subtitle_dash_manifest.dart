import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

/// A deliberately finite DASH audio subset for subtitle analysis, not a DASH
/// player. Resolve only complete, unprotected fMP4 references through the owner.
abstract final class SubtitleDashManifest {
  static const _namespace = 'urn:mpeg:dash:schema:mpd:2011';
  static List<XmlElement> _children(XmlElement node, String name) => node.childElements
      .where((child) => child.name.local == name && child.namespaceUri == _namespace).toList();
  static XmlElement? _one(XmlElement node, String name) {
    final values = _children(node, name);
    if (values.length > 1) throw FormatException('DASH analysis needs a single $name at each level.');
    return values.isEmpty ? null : values.single;
  }
  static int _number(String? value, {int fallback = 0, int max = 1125899906842624}) {
    if (value == null) return fallback;
    if (!RegExp(r'^\d{1,16}$').hasMatch(value)) throw const FormatException('Unsupported DASH integer.');
    final number = int.parse(value);
    if (number > max) throw const FormatException('DASH integer exceeds the analysis bound.');
    return number;
  }
  static int _duration(String value) {
    final match = RegExp(r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d{1,6})?)S)?)?$').firstMatch(value);
    if (match == null || !RegExp(r'\d').hasMatch(value)) throw const FormatException('DASH requires a fixed ISO duration.');
    final seconds = (double.tryParse(match[1] ?? '0') ?? double.infinity) * 86400 +
        (double.tryParse(match[2] ?? '0') ?? double.infinity) * 3600 +
        (double.tryParse(match[3] ?? '0') ?? double.infinity) * 60 + (double.tryParse(match[4] ?? '0') ?? double.infinity);
    if (!seconds.isFinite || seconds > 315576000) throw const FormatException('DASH duration exceeds ten years.');
    return (seconds * 1000).round();
  }
  static int _utc(String? value) {
    if (value == null || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)) throw const FormatException('DASH requires explicit UTC availability and publication times.');
    final parsed = DateTime.tryParse(value)?.millisecondsSinceEpoch;
    if (parsed == null || parsed < 0) throw const FormatException('Invalid DASH UTC clock.');
    return parsed;
  }
  static int _key(String text) => int.parse(sha256.convert(utf8.encode(text)).toString().substring(0, 12), radix: 16);
  static int _units(int milliseconds, int scale) {
    final product = BigInt.from(milliseconds) * BigInt.from(scale), divisor = BigInt.from(1000);
    var value = product ~/ divisor;
    if (product.isNegative && product.remainder(divisor) != BigInt.zero) value -= BigInt.one;
    if (value.abs() > BigInt.from(1125899906842624)) throw const FormatException('DASH clock exceeds the analysis bound.');
    return value.toInt();
  }
  static int _milliseconds(int units, int scale) {
    final value = BigInt.from(units).abs() * BigInt.from(1000);
    final rounded = ((value + BigInt.from(scale ~/ 2)) ~/ BigInt.from(scale)).toInt();
    return units < 0 ? -rounded : rounded;
  }
  static int _floorDivide(int value, int by) => value ~/ by - (value < 0 && value % by != 0 ? 1 : 0);
  static Uri _resolve(Uri base, String value) {
    if (value.isEmpty || value.length > 8192 || RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid DASH resource reference.');
    }
    final uri = base.resolve(value);
    if (!const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment ||
        base.scheme == 'https' && uri.scheme != 'https') throw const FormatException('DASH reference leaves the owning transport.');
    return uri;
  }
  static String _expand(String pattern, String id, String bandwidth, int number, int time) {
    if (pattern.length > 8192) throw const FormatException('DASH template exceeds its size bound.');
    final out = StringBuffer();
    for (var i = 0; i < pattern.length;) {
      if (pattern[i] != r'$') { out.write(pattern[i++]); continue; }
      if (i + 1 < pattern.length && pattern[i + 1] == r'$') { out.write(r'$'); i += 2; continue; }
      final end = pattern.indexOf(r'$', i + 1);
      if (end < 0) throw const FormatException('Unclosed DASH template.');
      final match = RegExp(r'^(RepresentationID|Bandwidth|Number|Time)(?:%0([1-9]|1[0-2])d)?$').firstMatch(pattern.substring(i + 1, end));
      if (match == null || match[1] == 'RepresentationID' && match[2] != null) throw const FormatException('Unsupported DASH template token.');
      final raw = switch (match[1]) { 'RepresentationID' => id, 'Bandwidth' => bandwidth, 'Number' => '$number', _ => '$time' };
      out.write(raw.padLeft(int.parse(match[2] ?? '0'), '0')); i = end + 1;
    }
    return out.toString();
  }

  static Future<Map<String, Object>> rewrite(String text, Uri origin, Future<Uri> Function(Uri) register) async {
    if (utf8.encode(text).length > 1024 * 1024 || RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(text)) {
      throw const FormatException('DASH analysis requires a bounded MPD without DTDs.');
    }
    late XmlElement root;
    try {
      var depth = 0, events = 0;
      for (final event in parseEvents(text, validateNesting: true, validateDocument: true)) {
        if (++events > 20000) throw const FormatException('DASH MPD has too many XML events.');
        if (event is XmlStartElementEvent && !event.isSelfClosing && ++depth > 32) {
          throw const FormatException('DASH MPD nesting exceeds 32.');
        }
        if (event is XmlEndElementEvent) depth--;
      }
      root = XmlDocument.parse(text).rootElement;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed DASH MPD XML.');
    }
    if (root.name.local != 'MPD' || root.namespaceUri != _namespace || root.getAttribute('type') != 'dynamic') {
      throw const FormatException('Live DASH analysis requires a dynamic MPD.');
    }
    for (final node in [root, ...root.descendants.whereType<XmlElement>()]) {
      if (const {'ContentProtection', 'LeapSecondInformation', 'SegmentBase', 'SegmentList'}.contains(node.name.local) ||
          node.attributes.any((a) => a.namespaceUri == 'http://www.w3.org/1999/xlink' ||
            a.namespaceUri == 'http://www.w3.org/XML/1998/namespace' && a.name.local == 'base') ||
          node.getAttribute('availabilityTimeComplete') != null && !const {'true', '1'}.contains(node.getAttribute('availabilityTimeComplete')) ||
          node.getAttribute('eptDelta') != null || node.getAttribute('duration') != null && node.name.local == 'SegmentTemplate' ||
          node.getAttribute('availabilityTimeOffset') != null && double.tryParse(node.getAttribute('availabilityTimeOffset')!) != 0) {
        throw const FormatException('Protected, linked, indexed or partial DASH segments are unsupported for analysis.');
      }
    }
    final availability = _utc(root.getAttribute('availabilityStartTime')), published = _utc(root.getAttribute('publishTime'));
    if (published < availability) throw const FormatException('DASH publication predates availability.');
    final buffer = root.getAttribute('timeShiftBufferDepth');
    final earliest = buffer == null ? availability : published - _duration(buffer);
    final update = root.getAttribute('minimumUpdatePeriod');
    final minimumUpdateMs = update == null ? 3000 : _duration(update).clamp(3000, 300000).toInt();
    if (update != null && _duration(update) > 300000) throw const FormatException('DASH manifest refresh exceeds five minutes.');
    final periods = _children(root, 'Period');
    if (periods.isEmpty || periods.length > 32) throw const FormatException('DASH analysis needs 1–32 explicit periods.');
    final starts = <int>[];
    for (var i = 0; i < periods.length; i++) {
      final value = periods[i].getAttribute('start');
      if (value == null && i != 0) throw const FormatException('DASH periods need explicit starts.');
      final start = value == null ? 0 : _duration(value);
      if (starts.isNotEmpty && start <= starts.last) throw const FormatException('DASH periods overlap or are unordered.');
      starts.add(start);
    }
    final renditions = <List<Map<String, Object>>>[];
    var total = 0;
    for (var periodIndex = 0; periodIndex < periods.length; periodIndex++) {
      final period = periods[periodIndex], start = starts[periodIndex];
      final explicitEnd = period.getAttribute('duration');
      final end = explicitEnd == null ? (periodIndex + 1 < starts.length ? starts[periodIndex + 1] : null) : start + _duration(explicitEnd);
      if (end != null && (end <= start || periodIndex + 1 < starts.length && end > starts[periodIndex + 1])) {
        throw const FormatException('DASH period duration overlaps another period.');
      }
      if (availability + start > published || end != null && availability + end < earliest) continue;
      var ordinal = 0;
      for (final adaptation in _children(period, 'AdaptationSet')) {
        for (final representation in _children(adaptation, 'Representation')) {
          final mime = representation.getAttribute('mimeType') ?? adaptation.getAttribute('mimeType');
          if (mime != 'audio/mp4') continue;
          if (ordinal >= 64) throw const FormatException('DASH exceeds 64 audio representations.');
          while (renditions.length <= ordinal) { renditions.add([]); }
          final output = renditions[ordinal++];
          final chain = [root, period, adaptation, representation];
          var base = origin;
          final attributes = <String, String>{};
          XmlElement? timeline;
          for (final node in chain) {
            final baseNode = _one(node, 'BaseURL');
            if (baseNode != null) base = _resolve(base, baseNode.innerText.trim());
            final template = _one(node, 'SegmentTemplate');
            if (template != null) {
              for (final a in template.attributes) { if (a.name.prefix == null) attributes[a.name.local] = a.value; }
              timeline = _one(template, 'SegmentTimeline') ?? timeline;
            }
          }
          final media = attributes['media'], init = attributes['initialization'];
          final id = representation.getAttribute('id') ?? '';
          final bandwidth = representation.getAttribute('bandwidth') ?? '';
          if (media == null || init == null || !RegExp(r'\$(?:Time|Number)(?:%0\d+d)?\$').hasMatch(media) ||
              RegExp(r'\$(?:Time|Number)(?:%0\d+d)?\$').hasMatch(init) || !RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(id) ||
              !RegExp(r'^\d{1,12}$').hasMatch(bandwidth)) throw const FormatException('DASH needs explicit fMP4 templates and representation IDs.');
          if (timeline == null || attributes['timescale'] == null) throw const FormatException('DASH analysis needs an explicit SegmentTimeline and timescale.');
          final scale = _number(attributes['timescale'], max: 1000000000);
          if (scale == 0) throw const FormatException('DASH timescale must be positive.');
          final offset = _number(attributes['presentationTimeOffset']), firstNumber = _number(attributes['startNumber'], fallback: 1);
          if (_expand(media, id, bandwidth, firstNumber, 0) == _expand(media, id, bandwidth, firstNumber + 1, 1)) {
            throw const FormatException('DASH media templates need a segment-varying token.');
          }
          final initialization = _resolve(base, _expand(init, id, bandwidth, firstNumber, 0));
          final identity = sha256.convert(utf8.encode(jsonEncode([adaptation.getAttribute('id'), id, bandwidth,
            representation.getAttribute('lang') ?? adaptation.getAttribute('lang'),
            representation.getAttribute('codecs') ?? adaptation.getAttribute('codecs'),
            representation.getAttribute('audioSamplingRate') ?? adaptation.getAttribute('audioSamplingRate'), initialization.path]))).toString();
          final continuity = _key('${period.getAttribute('id')}:$start:$identity:$offset:$scale');
          Uri? localInit;
          final seen = <Uri>{};
          var nextTime = 0, number = firstNumber;
          // Exclude segments crossing period boundaries: clipping these would
          // require decoding and validating sample-level edit/overlap semantics.
          Future<void> addRun(int time, int duration, int count) async {
            if (duration < 1 || duration > 60 * scale || count < 1 || count > 1000000000 ||
                count > (1125899906842624 - time) ~/ duration) throw const FormatException('DASH segment run exceeds analysis bounds.');
            final lower = _units(earliest - availability - start, scale) + offset - time;
            final upper = _units(published - availability - start, scale) + offset - time;
            final skip = _floorDivide(lower, duration).clamp(0, count).toInt();
            final stop = _floorDivide(upper, duration).clamp(0, count).toInt();
            if (stop - skip > 2000 || total + stop - skip > 2000) throw const FormatException('DASH complete-segment window exceeds 2,000 entries.');
            for (var i = skip; i < stop; i++) {
              final raw = time + i * duration;
              final from = start + _milliseconds(raw - offset, scale);
              final to = start + _milliseconds(raw + duration - offset, scale);
              if (from < start || end != null && to > end || to <= from || availability + to > published || availability + to <= earliest) continue;
              localInit ??= await register(initialization);
              final upstream = _resolve(base, _expand(media, id, bandwidth, number + i, raw));
              if (!seen.add(upstream)) throw const FormatException('DASH reused a segment URI on a different clock.');
              final uri = await register(upstream);
              output.add({'uri': uri.toString(), 'initialization': localInit.toString(), 'sequence': number + i,
                'discontinuity': continuity, 'startMs': availability + from, 'durationMs': to - from, 'representation': identity});
              total++;
            }
            nextTime = time + duration * count; number += count;
          }
          {
            final rows = _children(timeline!, 'S');
            if (rows.isEmpty || rows.length > 2000) throw const FormatException('DASH timeline exceeds 2,000 runs.');
            for (var index = 0; index < rows.length; index++) {
              final row = rows[index], time = _number(rows[index].getAttribute('t'), fallback: nextTime);
              if (row.getAttribute('n') != null || row.getAttribute('k') != null) throw const FormatException('DASH alternate numbering and partial segments are unsupported.');
              final duration = _number(row.getAttribute('d'), max: 60000000000);
              if (duration == 0 || time < nextTime) throw const FormatException('DASH timeline overlaps or lacks duration.');
              final repeat = row.getAttribute('r');
              int count;
              if (repeat == '-1') {
                final following = index + 1 < rows.length ? rows[index + 1].getAttribute('t') : null;
                if (index + 1 < rows.length && following == null) throw const FormatException('Open DASH repeat needs an explicit following start.');
                final limit = following != null ? _number(following) : end != null
                    ? offset + _units(end - start, scale)
                    : offset + _units(published - availability - start, scale);
                if (limit < time) continue;
                count = (limit - time) ~/ duration;
                if (following != null && (limit - time) % duration != 0) throw const FormatException('DASH open repeat overlaps its next run.');
                if (count == 0) continue;
              } else { count = _number(repeat, max: 1000000000) + 1; }
              await addRun(time, duration, count);
            }
          }
        }
      }
    }
    if (renditions.isEmpty) throw const FormatException('No eligible DASH audio/mp4 representations.');
    return {'schema': 1, 'kind': 'plezy-dash-audio', 'availabilityMs': availability,
      'publishedMs': published, 'minimumUpdateMs': minimumUpdateMs, 'renditions': renditions};
  }
}
