import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'subtitle_analysis_source.dart';
import 'subtitle_font_store.dart';

class SubtitleEmbeddedFont {
  const SubtitleEmbeddedFont._(this.name, this.mime, this.offset, this.bytes);
  final String name, mime;
  final int offset, bytes;
}

/// Reads attachment metadata and explicitly chosen font bytes, never clusters
/// or executable attachment paths. Seek offsets are relative to Segment data.
/// The caller owns this short-lived source lease and must close it.
final class SubtitleEmbeddedFonts {
  SubtitleEmbeddedFonts._(this._reader);
  final _FontRangeReader _reader;
  final List<SubtitleEmbeddedFont> _fonts = [];
  List<SubtitleEmbeddedFont> get fonts => List.unmodifiable(_fonts);
  bool get current => _reader.current;
  int _elements = 0;
  static const _attachments = 0x1941a469, _seekHead = 0x114d9b74;

  static Future<SubtitleEmbeddedFonts> open(SubtitleAnalysisSource source) async {
    final reader = _FontRangeReader(source);
    // Keep a single lease owner, including an error before the first read.
    final opened = SubtitleEmbeddedFonts._(reader);
    try { await opened._scan(); return opened; }
    catch (_) { await opened.close(); rethrow; }
  }
  Future<void> close() => _reader.close();

  Future<_EbmlElement> _element(int at, int bound, {bool unknown = false}) async {
    if (++_elements > 12000 || at < 0 || at >= bound) throw const FormatException('Attachment element limit');
    final bytes = await _reader.read(at, math.min(12, bound - at));
    final id = _vint(bytes, 0, id: true), size = _vint(bytes, id.width);
    final data = at + id.width + size.width;
    if (size.unknown && !unknown || !size.unknown && size.value > bound - data) {
      throw const FormatException('Invalid or unknown attachment element bounds');
    }
    return _EbmlElement(id.value, data, size.unknown ? bound : data + size.value, size.unknown);
  }
  static ({int value, int width, bool unknown}) _vint(Uint8List bytes, int offset, {bool id = false}) {
    if (offset >= bytes.length || bytes[offset] == 0) throw const FormatException('Invalid EBML integer');
    var width = 1, marker = 0x80;
    while ((bytes[offset] & marker) == 0) { marker >>= 1; width++; }
    if (width > (id ? 4 : 8) || offset + width > bytes.length) throw const FormatException('Truncated EBML integer');
    var value = id ? bytes[offset] : bytes[offset] & (marker - 1);
    var all = (bytes[offset] & (marker - 1)) == marker - 1;
    for (var i = 1; i < width; i++) { value = (value << 8) | bytes[offset + i]; all = all && bytes[offset + i] == 255; }
    if (!id && !all && value > 9007199254740991) throw const FormatException('EBML offset exceeds integer bound');
    return (value: value, width: width, unknown: !id && all);
  }
  Future<List<_EbmlElement>> _children(_EbmlElement parent, {int maximum = 512}) async {
    final result = <_EbmlElement>[];
    var at = parent.data;
    while (at < parent.end) {
      if (result.length >= maximum) throw const FormatException('Attachment child limit');
      final child = await _element(at, parent.end);
      result.add(child); at = child.end;
    }
    return result;
  }
  Future<String> _text(_EbmlElement element, int limit) async {
    if (element.length > limit) throw const FormatException('Attachment text limit');
    return utf8.decode(await _reader.read(element.data, element.length), allowMalformed: false).replaceAll('\u0000', '').trim();
  }
  Future<int> _uint(_EbmlElement element) async {
    if (element.length < 1 || element.length > 8) throw const FormatException('Invalid attachment seek integer');
    var value = 0;
    for (final byte in await _reader.read(element.data, element.length)) {
      value = (value << 8) | byte;
      if (value > 9007199254740991) throw const FormatException('Attachment seek exceeds integer bound');
    }
    return value;
  }
  Future<void> _scan() async {
    _reader.begin();
    await _reader.read(0, 12);
    final length = _reader.length!;
    final header = await _element(0, length);
    if (header.id != 0x1a45dfa3 || header.length > 4096) throw const FormatException('This source is not a supported Matroska file');
    final headerChildren = await _children(header, maximum: 32);
    final type = headerChildren.where((e) => e.id == 0x4282).toList();
    if (type.length != 1 || !const {'matroska', 'webm'}.contains(await _text(type.single, 32))) {
      throw const FormatException('Expected Matroska/WebM attachment metadata');
    }
    var at = header.end;
    _EbmlElement? segment;
    for (var n = 0; n < 16 && at < length; n++) {
      final element = await _element(at, length, unknown: true);
      if (element.id == 0x18538067) { segment = element; break; }
      if (element.unknown || element.id != 0xec && element.id != 0xbf) throw const FormatException('Missing Matroska segment');
      at = element.end;
    }
    if (segment == null) throw const FormatException('Missing Matroska segment');
    final selectedSegment = segment;
    final pending = <({int offset, int id})>[], visited = <int>{};
    var seekHeads = 0;
    Future<void> inspect(_EbmlElement element) async {
      if (!visited.add(element.data)) return;
      if (element.id == _attachments) { await _readAttachments(element); return; }
      if (element.id != _seekHead) return;
      if (++seekHeads > 8 || element.length > 256 * 1024) throw const FormatException('Attachment seek-table bound');
      for (final seek in await _children(element)) {
        if (seek.id != 0x4dbb) continue;
        final fields = await _children(seek, maximum: 8);
        final ids = fields.where((e) => e.id == 0x53ab).toList(), positions = fields.where((e) => e.id == 0x53ac).toList();
        if (ids.length != 1 || positions.length != 1) throw const FormatException('Invalid attachment seek entry');
        final id = await _uint(ids.single);
        if (id != _attachments && id != _seekHead) continue;
        final offset = selectedSegment.data + await _uint(positions.single);
        if (offset < selectedSegment.data || offset >= selectedSegment.end || pending.length >= 32) throw const FormatException('Attachment seek outside segment');
        pending.add((offset: offset, id: id));
      }
    }
    at = selectedSegment.data;
    for (var n = 0; n < 4096 && at < selectedSegment.end; n++) {
      final element = await _element(at, selectedSegment.end, unknown: true);
      if (element.unknown && element.id != 0x1f43b675) throw const FormatException('Unsupported unknown-size metadata');
      await inspect(element);
      while (pending.isNotEmpty) {
        final next = pending.removeAt(0);
        final found = await _element(next.offset, selectedSegment.end);
        if (found.id != next.id) throw const FormatException('Attachment index does not match file contents');
        await inspect(found);
      }
      if (_fonts.isNotEmpty) return;
      if (element.unknown) throw UnsupportedError('This streaming Matroska file has no usable attachment index');
      at = element.end;
    }
    if (at < selectedSegment.end) throw const FormatException('Attachment scan limit; use an indexed Matroska file');
  }
  Future<void> _readAttachments(_EbmlElement attachments) async {
    if (attachments.unknown || attachments.length > 256 * 1024 * 1024) throw const FormatException('Attachment directory exceeds its bound');
    for (final item in await _children(attachments, maximum: 128)) {
      if (item.id != 0x61a7) continue;
      final fields = await _children(item, maximum: 32);
      final names = fields.where((e) => e.id == 0x466e).toList(), types = fields.where((e) => e.id == 0x4660).toList();
      final data = fields.where((e) => e.id == 0x465c).toList();
      if (names.length != 1 || types.length != 1 || data.length != 1) throw const FormatException('Invalid attached file metadata');
      final name = (await _text(names.single, 1024)).split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
      final mime = (await _text(types.single, 256)).toLowerCase();
      if (!RegExp(r'\.(ttf|otf)$', caseSensitive: false).hasMatch(name) && !const {
        'font/ttf', 'font/otf', 'application/x-truetype-font', 'application/vnd.ms-opentype', 'application/x-font-ttf', 'application/x-font-opentype',
      }.contains(mime)) continue;
      if (data.single.length < 12 || data.single.length > SubtitleFontStore.maximumFontBytes || _fonts.length >= 16) {
        throw const FormatException('Embedded fonts exceed the 16-file / 16 MiB per-file limit');
      }
      _fonts.add(SubtitleEmbeddedFont._(name.isEmpty ? 'Embedded font ${_fonts.length + 1}' : name,
        mime, data.single.data, data.single.length));
    }
  }
  Future<Uint8List> readFont(SubtitleEmbeddedFont font) async {
    if (!_fonts.contains(font)) throw StateError('Choose a font from this media');
    _reader.begin();
    final bytes = await _reader.read(font.offset, font.bytes);
    SubtitleFontStore.validateBytes(bytes);
    return bytes;
  }
}

class _EbmlElement {
  const _EbmlElement(this.id, this.data, this.end, this.unknown);
  final int id, data, end;
  final bool unknown;
  int get length => end - data;
}

class _FontRangeReader {
  _FontRangeReader(this.source) { _client.findProxy = (_) => 'DIRECT'; }
  final SubtitleAnalysisSource source;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  RandomAccessFile? _file;
  FileStat? _stat;
  int? length;
  String? _etag, _modified;
  bool _closed = false;
  int _requests = 0, _received = 0, _cacheStart = 0;
  Uint8List _cache = Uint8List(0);
  DateTime _deadline = DateTime.now();
  bool get current { try { return !_closed && source.isCurrent(); } catch (_) { return false; } }
  void begin() { _deadline = DateTime.now().add(const Duration(seconds: 60)); _cache = Uint8List(0); }
  void _check() {
    if (!current || DateTime.now().isAfter(_deadline)) throw StateError('The embedded-font source changed or timed out');
  }
  Future<Uint8List> read(int offset, int count) async {
    _check();
    if (offset < 0 || count < 0 || count > SubtitleFontStore.maximumFontBytes ||
        length != null && offset + count > length!) throw const FormatException('Invalid attachment read bounds');
    if (count == 0) return Uint8List(0);
    if (offset >= _cacheStart && offset + count <= _cacheStart + _cache.length) {
      return Uint8List.sublistView(_cache, offset - _cacheStart, offset - _cacheStart + count);
    }
    if (++_requests > 512) throw const FormatException('Embedded-font range request limit');
    var wanted = math.max(count, 4096);
    if (length != null) wanted = math.min(wanted, length! - offset);
    final uri = source.uri;
    Uint8List bytes;
    if (source.liveEpochForPosition != null) throw UnsupportedError('Embedded fonts require a seekable media file');
    if (uri.scheme == 'file' && uri.host.isEmpty) {
      final input = File.fromUri(uri), stat = await File.fromUri(uri).stat();
      if (stat.type != FileSystemEntityType.file || _stat != null && (stat.size != _stat!.size || stat.modified != _stat!.modified)) {
        throw StateError('The media file changed');
      }
      _stat ??= stat; length ??= stat.size;
      if (offset + count > length!) throw const FormatException('Attachment extends beyond the media');
      wanted = math.min(wanted, length! - offset);
      final file = _file ??= await input.open();
      await file.setPosition(offset); bytes = await file.read(wanted);
      if (bytes.length != wanted) throw const FormatException('Truncated attachment read');
    } else {
      if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.userInfo.isNotEmpty || uri.hasFragment) {
        throw UnsupportedError('Embedded fonts require the current source connection');
      }
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + wanted - 1}');
      if (_etag != null && !_etag!.startsWith('W/')) request.headers.set(HttpHeaders.ifMatchHeader, _etag!);
      try {
        final response = await request.close().timeout(const Duration(seconds: 20));
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
        if (response.statusCode != 206 || range == null || !const [null, 'identity'].contains(response.headers.value(HttpHeaders.contentEncodingHeader))) {
          throw UnsupportedError('This source does not provide bounded byte-range reads');
        }
        final total = int.parse(range[3]!), start = int.parse(range[1]!), end = int.parse(range[2]!);
        final etag = response.headers.value(HttpHeaders.etagHeader), modified = response.headers.value(HttpHeaders.lastModifiedHeader);
        if (total <= 0 || total > 9007199254740991 || offset + count > total || start != offset ||
            end != math.min(offset + wanted, total) - 1 || length != null && length != total ||
            _etag != null && _etag != etag || _modified != null && _modified != modified) throw StateError('The source range or media revision changed');
        length ??= total; _etag ??= etag; _modified ??= modified;
        wanted = end - start + 1;
        final body = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(const Duration(seconds: 10))) {
          _check();
          if (body.length + chunk.length > wanted) throw const FormatException('Attachment response exceeded the requested range');
          body.add(chunk);
        }
        bytes = body.takeBytes();
        if (bytes.length != wanted) throw const FormatException('Incomplete attachment response');
      } finally { request.abort(); }
    }
    _received += bytes.length;
    if (_received > 128 * 1024 * 1024) throw const FormatException('Embedded-font transfer limit');
    _check();
    if (count < 4096) { _cacheStart = offset; _cache = bytes; }
    return Uint8List.sublistView(bytes, 0, count);
  }
  Future<void> close() async {
    if (_closed) return;
    _closed = true; _client.close(force: true); _cache = Uint8List(0);
    try { await _file?.close(); } finally { await source.close(); }
  }
}
