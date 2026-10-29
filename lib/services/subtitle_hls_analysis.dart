import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A complete HLS segment, timestamped by PROGRAM-DATE-TIME, never by wall
/// clock receipt time or an intended seek. Times are UTC milliseconds. The
/// playback-side epoch mapping can still be an estimate; callers disclose it.
class SubtitleHlsSegment {
  const SubtitleHlsSegment({required this.uri, required this.sequence,
    required this.discontinuity, required this.startMs, required this.durationMs,
    this.range, this.initialization, this.initializationRange, this.gap = false});
  final Uri uri;
  final int sequence, discontinuity, startMs, durationMs;
  final ({int offset, int length})? range, initializationRange;
  final Uri? initialization;
  final bool gap;
  int get endMs => startMs + durationMs;
  String get key => '$discontinuity:$sequence:$startMs:$durationMs';
}

/// Only consumes URLs already rewritten by the source owner's loopback HLS
/// gateway. No credentials, origin URLs, key retrieval, tuner creation or
/// playback controls. Partial low-latency segments are never analyzed.
class SubtitleHlsAnalysis {
  SubtitleHlsAnalysis(this.root, this.current, {this.rendition = 0}) {
    if (!_owned(root) || rendition < 0 || rendition > 63) throw ArgumentError('Invalid owned HLS source');
    _client.findProxy = (_) => 'DIRECT';
  }
  final Uri root;
  final bool Function() current;
  final int rendition;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  bool _closed = false;
  static bool _owned(Uri uri) => uri.scheme == 'http' && uri.host == '127.0.0.1' &&
      uri.userInfo.isEmpty && !uri.hasFragment;
  void close() { _closed = true; _client.close(force: true); }
  void _check() { if (_closed || !current()) throw StateError('Live analysis source changed'); }
  Uri _child(Uri base, String value) {
    final uri = base.resolve(value);
    if (!_owned(uri) || uri.port != root.port || uri.pathSegments.length != 2 ||
        root.pathSegments.length != 2 || uri.pathSegments.first != root.pathSegments.first || uri.hasQuery) {
      throw const FormatException('HLS references must stay inside the owning gateway');
    }
    return uri;
  }

  Future<Uint8List> _read(Uri uri, int limit, {({int offset, int length})? range}) async {
    _check();
    final request = await _client.getUrl(uri).timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.offset}-${range.offset + range.length - 1}');
    Timer? deadline;
    try {
      deadline = Timer(const Duration(seconds: 20), () => request.abort(const HttpException('HLS analysis read timed out')));
      final response = await request.close();
      if (response.statusCode != (range == null ? 200 : 206) || response.contentLength > limit ||
          (range != null && response.headers.value(HttpHeaders.contentRangeHeader)?.startsWith(
            'bytes ${range.offset}-${range.offset + range.length - 1}/') != true)) {
        throw const FormatException('The live segment is unavailable or exceeds its bound');
      }
      final output = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        _check();
        if (output.length + chunk.length > limit) throw const FormatException('HLS analysis input limit');
        output.add(chunk);
      }
      if (output.isEmpty || response.contentLength >= 0 && response.contentLength != output.length ||
          range != null && output.length != range.length) throw const FormatException('Incomplete live segment');
      _check(); return output.takeBytes();
    } finally { deadline?.cancel(); request.abort(); }
  }

  static Map<String, String> _attributes(String value) {
    final fields = <String, String>{};
    final pattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,\r\n]+)(?:,|$)');
    var offset = 0;
    for (final match in pattern.allMatches(value)) {
      if (match.start != offset || fields.containsKey(match[1])) throw const FormatException('Invalid HLS attributes');
      final raw = match[2]!;
      fields[match[1]!] = raw.startsWith('"') ? raw.substring(1, raw.length - 1) : raw;
      offset = match.end;
    }
    if (offset != value.length) throw const FormatException('Invalid HLS attribute list');
    return fields;
  }

  Future<List<SubtitleHlsSegment>> segments() async {
    var uri = root;
    final visited = <Uri>{};
    for (var level = 0; level < 3; level++) {
      if (!visited.add(uri)) throw const FormatException('Cyclic HLS playlist');
      final text = utf8.decode(await _read(uri, 1024 * 1024), allowMalformed: false);
      final lines = text.replaceAll('\r\n', '\n').split('\n').map((v) => v.trim()).toList();
      if (lines.first != '#EXTM3U' || lines.length > 20000) throw const FormatException('Expected a bounded HLS playlist');
      final audio = <Uri>[], variants = <Uri>[];
      var nextVariant = false;
      for (final line in lines) {
        if (line.startsWith('#EXT-X-MEDIA:')) {
          final attrs = _attributes(line.substring(13));
          if (attrs['TYPE'] == 'AUDIO' && attrs['URI'] != null) audio.add(_child(uri, attrs['URI']!));
        } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
          nextVariant = true;
        } else if (nextVariant && line.isNotEmpty && !line.startsWith('#')) {
          variants.add(_child(uri, line)); nextVariant = false;
        }
      }
      if (audio.isNotEmpty || variants.isNotEmpty) {
        final choices = audio.isNotEmpty ? audio : variants;
        if (level != 0 && choices.length != 1 || rendition >= choices.length && level == 0) {
          throw const FormatException('Select an available HLS audio rendition or variant');
        }
        uri = choices[level == 0 ? rendition : 0]; continue;
      }
      return _media(lines, uri);
    }
    throw const FormatException('HLS playlist nesting exceeds the analysis bound');
  }

  List<SubtitleHlsSegment> _media(List<String> lines, Uri base) {
    final result = <SubtitleHlsSegment>[];
    int sequence = 0, discontinuity = 0;
    int? epoch, duration;
    Uri? initialization, previousUri;
    ({int offset, int length})? range, initializationRange, previousRange;
    bool gap = false, encrypted = false;
    ({int offset, int length}) byteRange(String value, {int? implicitOffset}) {
      final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(value);
      if (match == null) throw const FormatException('Invalid HLS byte range');
      final length = int.parse(match[1]!), offset = match[2] == null ? implicitOffset : int.parse(match[2]!);
      if (offset == null || offset < 0 || length < 1 || length > 32 * 1024 * 1024 || offset + length > (1 << 40)) {
        throw const FormatException('Unsupported HLS byte range');
      }
      return (offset: offset, length: length);
    }
    String? rawRange;
    for (final line in lines) {
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        if (result.isNotEmpty) throw const FormatException('Late HLS media sequence');
        sequence = int.parse(line.substring(22));
      } else if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
        if (result.isNotEmpty) throw const FormatException('Late HLS discontinuity sequence');
        discontinuity = int.parse(line.substring(30));
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuity++; epoch = null; previousRange = null; previousUri = null;
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        final date = line.substring(25);
        if (!RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(date)) throw const FormatException('HLS program time needs a time zone');
        final parsed = DateTime.tryParse(date)?.millisecondsSinceEpoch;
        if (parsed == null || parsed < 0 || epoch != null && (epoch - parsed).abs() > 250) {
          throw const FormatException('Ambiguous HLS program clock; a discontinuity is required');
        }
        epoch = parsed;
      } else if (line.startsWith('#EXTINF:')) {
        final seconds = double.tryParse(line.substring(8).split(',').first);
        if (seconds == null || !seconds.isFinite || seconds <= 0 || seconds > 60) throw const FormatException('HLS analysis requires segments of at most 60 seconds');
        duration = (seconds * 1000).round();
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        rawRange = line.substring(17);
      } else if (line.startsWith('#EXT-X-KEY:')) {
        encrypted = _attributes(line.substring(11))['METHOD'] != 'NONE';
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final attrs = _attributes(line.substring(11));
        if (attrs['URI'] == null) throw const FormatException('Missing HLS initialization URI');
        initialization = _child(base, attrs['URI']!);
        initializationRange = attrs['BYTERANGE'] == null ? null : byteRange(attrs['BYTERANGE']!);
      } else if (line == '#EXT-X-GAP') {
        gap = true;
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        if (encrypted) throw UnsupportedError('Protected HLS segments are not available for analysis');
        if (duration == null || duration < 1 || sequence < 0 || sequence > 9007199254740991 || discontinuity < 0) {
          throw const FormatException('Invalid complete HLS segment');
        }
        final uri = _child(base, line);
        range = rawRange == null ? null : byteRange(rawRange!, implicitOffset: previousUri == uri && previousRange != null
          ? previousRange!.offset + previousRange!.length : null);
        if (epoch != null) result.add(SubtitleHlsSegment(uri: uri, sequence: sequence, discontinuity: discontinuity,
          startMs: epoch, durationMs: duration, range: range, initialization: initialization,
          initializationRange: initializationRange, gap: gap));
        // A segment before the first explicit program time is intentionally
        // not assigned a fabricated wall clock. The next refresh may anchor it.
        if (epoch != null) epoch += duration;
        sequence++; duration = null; rawRange = null; gap = false;
        previousUri = uri; previousRange = range;
        if (result.length > 2000) throw const FormatException('HLS analysis playlist limit');
      }
    }
    if (result.isEmpty) throw UnsupportedError('Live analysis requires complete segments with program timestamps');
    return result;
  }

  /// Stage immutable complete segments and initialization bytes. The decoder
  /// only reads this private, all-local VOD manifest, with no upstream access.
  Future<File> stage(List<SubtitleHlsSegment> segments, Directory directory) async {
    if (segments.isEmpty || segments.length > 32 || segments.fold<int>(0, (n, s) => n + s.durationMs) > 64000) {
      throw const FormatException('Live analysis window exceeds 64 seconds');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    final manifest = StringBuffer('#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:64\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n');
    var total = 0;
    String? lastMap;
    for (var index = 0; index < segments.length; index++) {
      _check();
      final segment = segments[index];
      if (segment.gap || segment.discontinuity != segments.first.discontinuity ||
          index > 0 && (segment.startMs - segments[index-1].endMs).abs() > 250 || !DateTime.now().isBefore(deadline)) {
        throw const FormatException('Live window crossed a gap, discontinuity, or staging deadline');
      }
      final mapKey = '${segment.initialization}:${segment.initializationRange}';
      if (segment.initialization != null && mapKey != lastMap) {
        final bytes = await _read(segment.initialization!, 4 * 1024 * 1024, range: segment.initializationRange);
        total += bytes.length;
        if (total > 128 * 1024 * 1024) throw const FormatException('Live analysis staging exceeds 128 MiB');
        await File('${directory.path}/init$index.mp4').writeAsBytes(bytes, flush: true);
        manifest.writeln('#EXT-X-MAP:URI="init$index.mp4"'); lastMap = mapKey;
      }
      final remaining = 128 * 1024 * 1024 - total;
      if (remaining < 1) throw const FormatException('Live analysis staging exceeds 128 MiB');
      final bytes = await _read(segment.uri, remaining < 32 * 1024 * 1024 ? remaining : 32 * 1024 * 1024, range: segment.range);
      total += bytes.length;
      if (total > 128 * 1024 * 1024) throw const FormatException('Live analysis staging exceeds 128 MiB');
      final name = 'segment$index.${segment.initialization == null ? 'ts' : 'm4s'}';
      await File('${directory.path}/$name').writeAsBytes(bytes, flush: true);
      manifest.writeln('#EXTINF:${(segment.durationMs / 1000).toStringAsFixed(3)},');
      manifest.writeln(name);
    }
    _check(); manifest.writeln('#EXT-X-ENDLIST');
    final file = File('${directory.path}/window.m3u8');
    await file.writeAsString(manifest.toString(), flush: true); return file;
  }

  /// Native mobile readers need a media file, not a local HLS playlist. Only
  /// relocatable fMP4, whole 188-byte TS packets or ADTS frames are joined.
  /// No transcoding, timestamp fabrication, partial segment or format guessing.
  Future<File> stageNative(List<SubtitleHlsSegment> segments, Directory directory) async {
    if (segments.isEmpty || segments.any((segment) => segment.initialization != segments.first.initialization ||
        segment.initializationRange != segments.first.initializationRange)) {
      throw const FormatException('A native live snapshot cannot cross an initialization change');
    }
    await stage(segments, directory);
    final fragmented = segments.first.initialization != null;
    String? format, audioConfiguration;
    RandomAccessFile? output;
    File? destination;
    var written = 0;
    try {
      Future<void> append(Uint8List bytes) async {
        _check();
        written += bytes.length;
        if (written > 128 * 1024 * 1024) throw const FormatException('Native live snapshot exceeds 128 MiB');
        await output!.writeFrom(bytes);
      }
      if (fragmented) {
        final init = File('${directory.path}/init0.mp4');
        final bytes = await init.readAsBytes();
        _fragmentBoxes(bytes, initialization: true);
        format = 'mp4'; destination = File('${directory.path}/window.mp4');
        output = await destination.open(mode: FileMode.write);
        await append(bytes); await init.delete();
      }
      for (var index = 0; index < segments.length; index++) {
        _check();
        final input = File('${directory.path}/segment$index.${fragmented ? 'm4s' : 'ts'}');
        var bytes = await input.readAsBytes(); // Stage already caps each input to 32 MiB.
        if (fragmented) {
          _fragmentBoxes(bytes, initialization: false);
        } else if (bytes.length >= 188 && bytes.length % 188 == 0 && bytes[0] == 0x47) {
          if (format != null && format != 'ts') throw const FormatException('Live audio changed container format');
          format = 'ts';
          for (var packet = 0; packet < bytes.length; packet += 188) {
            if (bytes[packet] != 0x47) throw const FormatException('Incomplete transport-stream packet');
          }
        } else {
          if (format != null && format != 'aac') throw const FormatException('Live audio changed container format');
          // Packed AAC can carry a leading HLS timestamp ID3 tag. Program time
          // is supplied separately; strip tags so every joined byte is ADTS.
          var start = 0;
          while (start + 10 <= bytes.length && bytes[start] == 0x49 && bytes[start+1] == 0x44 && bytes[start+2] == 0x33) {
            if (bytes[start+3] < 3 || bytes[start+3] > 4 || (bytes[start+5] & 0x10) != 0 || bytes.sublist(start+6, start+10).any((b) => b >= 128)) {
              throw const FormatException('Unsupported packed-audio ID3 header');
            }
            final size = (bytes[start+6] << 21) | (bytes[start+7] << 14) | (bytes[start+8] << 7) | bytes[start+9];
            start += 10 + size;
            if (start > bytes.length || size > 1024 * 1024) throw const FormatException('Invalid packed-audio ID3 size');
          }
          if (start == bytes.length) throw const FormatException('Packed audio contains no frames');
          bytes = Uint8List.sublistView(bytes, start);
          var position = 0;
          while (position < bytes.length) {
            if (position + 7 > bytes.length || bytes[position] != 0xff || (bytes[position+1] & 0xf6) != 0xf0 ||
                ((bytes[position+2] >> 2) & 15) > 12) throw UnsupportedError('Native live analysis supports only TS, relocatable fMP4 or packed ADTS AAC');
            final header = (bytes[position+1] & 1) != 0 ? 7 : 9;
            final length = ((bytes[position+3] & 3) << 11) | (bytes[position+4] << 3) | (bytes[position+5] >> 5);
            if (length < header || length > bytes.length - position) throw const FormatException('Incomplete ADTS audio frame');
            final configuration = '${bytes[position+2] >> 2}:${((bytes[position+2] & 1) << 2) | (bytes[position+3] >> 6)}';
            if (audioConfiguration != null && audioConfiguration != configuration) throw const FormatException('Live audio changed codec configuration without a discontinuity');
            audioConfiguration = configuration;
            position += length;
          }
          format = 'aac';
        }
        if (output == null) {
          destination = File('${directory.path}/window.$format');
          output = await destination.open(mode: FileMode.write);
        }
        await append(bytes);
        await input.delete(); // Bound duplicate disk bytes to the current segment.
      }
      await output!.flush(); _check(); return destination!;
    } finally { await output?.close(); }
  }

  static void _fragmentBoxes(Uint8List bytes, {required bool initialization}) {
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) throw const FormatException('Invalid MP4 snapshot size');
    final data = ByteData.sublistView(bytes);
    var boxes = 0;
    Set<String> walk(int start, int end, int depth) {
      if (depth > 10) throw const FormatException('MP4 snapshot nesting limit');
      final types = <String>{};
      while (start < end) {
        if (end-start < 8 || ++boxes > 10000) throw const FormatException('Invalid MP4 snapshot boxes');
        var length = data.getUint32(start), header = 8;
        final type = String.fromCharCodes(bytes.sublist(start+4, start+8));
        if (length == 1) {
          if (end-start < 16) throw const FormatException('Truncated large MP4 box');
          length = data.getUint64(start+8); header = 16;
        } else if (length == 0) { throw const FormatException('Open-ended MP4 boxes cannot be concatenated'); }
        if (length < header || length > end-start) throw const FormatException('Invalid MP4 box length');
        final body = start+header, stop = start+length;
        types.add(type);
        if (type == 'mfra' || type == 'tfra') throw const FormatException('Absolute MP4 fragment indexes cannot be relocated');
        if (type == 'tfhd') {
          if (stop-body < 8 || (data.getUint32(body) & 1) != 0) throw const FormatException('MP4 fragments require relative data addressing');
        } else if (type == 'dref') {
          if (stop-body < 8 || data.getUint32(body+4) > 64) throw const FormatException('Invalid MP4 data references');
          var offset = body+8;
          for (var n = 0; n < data.getUint32(body+4); n++) {
            if (offset+12 > stop || data.getUint32(offset) != 12 ||
                String.fromCharCodes(bytes.sublist(offset+4, offset+8)) != 'url ' || data.getUint32(offset+8) != 1) {
              throw const FormatException('External MP4 data references are refused');
            }
            offset += 12;
          }
          if (offset != stop) throw const FormatException('Invalid MP4 reference table');
        } else if (const {'moov','trak','mdia','minf','dinf','stbl','mvex','moof','traf'}.contains(type)) {
          final children = walk(body, stop, depth+1);
          if (type == 'traf' && !children.containsAll({'tfhd','tfdt'})) throw const FormatException('Fragment timing is missing');
        }
        start = stop;
      }
      return types;
    }
    final types = walk(0, bytes.length, 0);
    if (initialization ? !types.containsAll({'ftyp','moov'}) || types.contains('mdat')
        : !types.containsAll({'moof','mdat'}) || types.contains('moov')) {
      throw const FormatException('Expected an HLS initialization section or complete MP4 fragment');
    }
  }
}
