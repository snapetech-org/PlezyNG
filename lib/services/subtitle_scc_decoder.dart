import 'dart:convert';
import 'dart:math' as math;

import 'subtitle_retimer.dart';

/// Explicit SCC-to-text derivative. Display memory changes become timed text
/// snapshots; the original remains the source for native 608 layout/styles.
abstract final class SubtitleSccDecoder {
  static String _message(Map<String, String>? messages, String key, String fallback, [Map<String, Object?> values = const {}]) {
    var result = messages?[key] ?? fallback;
    for (final entry in values.entries) { result = result.replaceAll('{${entry.key}}', '${entry.value}'); }
    return result;
  }

  static void decode(String text, void Function(int, int, String) add, List<String> warnings, {
    required int channel, required bool ntsc, required int clockOriginMs, required int finalDurationMs,
    Map<String, String>? messages,
  }) {
    if (channel < 1 || channel > 4 || clockOriginMs < 0 || clockOriginMs > 86400000) {
      throw FormatException(_message(messages, 'subtitleImportSccChannelRangeError', 'Choose a CEA-608 service from CC1 to CC4 and a clock origin from 0 to 86400000 ms.'));
    }
    final channelWithinField = ((channel - 1) % 2) + 1;
    final lines = const LineSplitter().convert(text);
    var header = false, packets = 0, previousFrame = -1, lastMs = 0;
    bool? dropFrame;
    final decoder = _SccChannel(channelWithinField, add, messages);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      if (!header) {
        if (line != 'Scenarist_SCC V1.0') throw FormatException(_message(messages, 'subtitleImportSccMissingHeaderError', 'Missing Scenarist_SCC V1.0 header.'));
        header = true; continue;
      }
      if (line.length > 32768) throw FormatException(_message(messages, 'subtitleImportSccLineLimitError', 'SCC line exceeds the 32768-character packet bound.'));
      final match = RegExp(r'^([0-2]\d):([0-5]\d):([0-5]\d)([:;])([0-2]\d)\s+([0-9a-fA-F]{4}(?:\s+[0-9a-fA-F]{4})*)$').firstMatch(line);
      if (match == null) throw FormatException(_message(messages, 'subtitleImportSccMalformedLine', 'Malformed SCC timecode or byte pairs at line {line}.', {'line': index + 1}));
      final hours = int.parse(match[1]!), minutes = int.parse(match[2]!), seconds = int.parse(match[3]!), frames = int.parse(match[5]!);
      final drop = match[4] == ';';
      if (hours > 23 || drop && (!ntsc || minutes % 10 != 0 && seconds == 0 && frames < 2) || dropFrame != null && dropFrame != drop) {
        throw FormatException(_message(messages, 'subtitleImportSccDropFrameError', 'Invalid or mixed SCC drop-frame clock; semicolon timecode requires 30000/1001 fps.'));
      }
      dropFrame ??= drop;
      final totalMinutes = hours * 60 + minutes;
      var frame = ((hours * 3600 + minutes * 60 + seconds) * 30 + frames) - (drop ? 2 * (totalMinutes - totalMinutes ~/ 10) : 0);
      for (final pair in match[6]!.split(RegExp(r'\s+'))) {
        if (++packets > 500000 || frame <= previousFrame) throw FormatException(_message(messages, 'subtitleImportSccPacketOrderError', 'SCC packets overlap, run backwards or exceed 500000 pairs.'));
        final raw = int.parse(pair, radix: 16), a = raw >> 8, b = raw & 255;
        bool parity(int byte) {
          if (byte == 0) return true; // Explicit zero padding has no text value.
          var ones = 0;
          for (var bit = 0; bit < 8; bit++) { ones += (byte >> bit) & 1; }
          return ones.isOdd;
        }
        if (!parity(a) || !parity(b)) throw FormatException(_message(messages, 'subtitleImportSccParityError', 'SCC odd-parity check failed at line {line}.', {'line': index + 1}));
        lastMs = (frame * (ntsc ? 1001000 : 1000000) / 30000).round() - clockOriginMs;
        if (lastMs > SubtitleRetimer.maximumTimeMs) throw FormatException(_message(messages, 'subtitleImportSccTimelineError', 'SCC exceeds the supported media timeline. Set its explicit clock origin.'));
        decoder.accept(a & 127, b & 127, lastMs);
        previousFrame = frame++;
      }
    }
    if (!header || packets == 0) throw FormatException(_message(messages, 'subtitleImportSccNoPacketsError', 'SCC has no caption packets.'));
    decoder.finish(math.min(SubtitleRetimer.maximumTimeMs, lastMs + finalDurationMs));
    warnings.add(_message(messages, 'subtitleImportSccDecodedSummary', 'SCC {channel} service; {fps} fps, {frameType} labels, clock origin {clockOrigin} ms. Byte pairs advance one frame each; parity is checked.', {
      'channel': 'CC$channel', 'fps': ntsc ? '30000/1001' : '30',
      'frameType': _message(messages, dropFrame == true ? 'subtitleImportSccDropFrameLabel' : 'subtitleImportSccNonDropFrameLabel', dropFrame == true ? 'drop-frame' : 'non-drop-frame'),
      'clockOrigin': clockOriginMs,
    }));
    warnings.add(_message(messages, 'subtitleImportSccFlattenedWarning', '608 pop-on memory swaps, paint-on updates and 2/3/4-row roll-up become separate text snapshots. Screen positions, empty rows, colors, underline, italics, flash and background effects are flattened. Other fields, XDS/TEXT services and CEA-708 need their native decoder.'));
    if (decoder.hadOpenTail) warnings.add(_message(messages, 'subtitleImportSccOpenTailWarning', 'The final visible SCC screen has no clear command; it uses the selected {duration} ms tail after the last packet.', {'duration': finalDurationMs}));
  }
}

class _SccMemory {
  List<List<String>> rows = List.generate(15, (_) => List.filled(32, ' '));
  int row = 14, column = 0;
  String get text => rows.map((row) => row.join().trimRight()).where((row) => row.trim().isNotEmpty).join('\n');
}

class _SccChannel {
  _SccChannel(this.selected, this.add, this._messages);
  final int selected;
  final void Function(int, int, String) add;
  final Map<String, String>? _messages;
  _SccMemory _display = _SccMemory(), _loading = _SccMemory();
  int _channel = 1, _rollRows = 2;
  String _mode = 'unknown', _visible = '';
  int _since = 0, _lastPair = -1, _bytes = 0;
  bool hadOpenTail = false;
  _SccMemory get _writing => _mode == 'pop' ? _loading : _display;
  int get _row => _writing.row;
  set _row(int value) => _writing.row = value;
  int get _column => _writing.column;
  set _column(int value) => _writing.column = value;

  static const _special = '®°½¿™¢£♪à èâêîôû';
  static const _western1 = "ÁÉÓÚÜü‘¡*'—©℠•“”ÀÂÇÈÊËëÎÏïÔÙùÛ«»";
  static const _western2 = 'ÃãÍÌìÒòÕõ{}\\^_|~ÄäÖöß¥¤│ÅåØø┌┐└┘';
  static const _basic = {0x2a: 'á', 0x5c: 'é', 0x5e: 'í', 0x5f: 'ó', 0x60: 'ú',
    0x7b: 'ç', 0x7c: '÷', 0x7d: 'Ñ', 0x7e: 'ñ', 0x7f: '■'};

  void _write(String character) {
    if (_column >= 32) throw FormatException(_message(messages, 'subtitleImportSccColumnLimitError', 'SCC writes beyond the 32-column caption grid.'));
    _writing.rows[_row][_column++] = character;
  }
  void _backspace() { if (_column > 0) _writing.rows[_row][--_column] = ' '; }
  void _rollBounds() {
    for (var row = 0; row < 15; row++) {
      if (row < _row - _rollRows + 1 || row > _row) _display.rows[row] = List.filled(32, ' ');
    }
  }
  void _publish(int at) {
    final next = _display.text;
    if (next == _visible) return;
    _emit(at); _visible = next; _since = at;
  }
  void _emit(int until) {
    if (_visible.isEmpty || until <= math.max(0, _since)) return;
    final payload = const HtmlEscape(HtmlEscapeMode.element).convert(_visible);
    _bytes += utf8.encode(payload).length;
    if (_bytes > SubtitleRetimer.maximumInputBytes) throw FormatException(SubtitleSccDecoder._message(_messages, 'subtitleImportSccSnapshotLimitError', 'SCC display snapshots exceed 5 MiB.'));
    add(math.max(0, _since), until, payload);
  }
  void finish(int until) { hadOpenTail = _visible.isNotEmpty; _emit(until); }

  void accept(int a, int b, int at) {
    if (a == 0 && b == 0) return;
    if (a > 0 && a < 0x10) throw FormatException(SubtitleSccDecoder._message(_messages, 'subtitleImportSccXdsUnsupportedError', 'XDS or other non-caption data is not supported by this SCC text conversion.'));
    final isControl = (a & 0xf6) == 0x14 && b >= 0x20 && b <= 0x2f;
    if (isControl) {
      // The channel bit is meaningful on a CEA-608 control pair. PAC/address
      // and character pairs reuse the same byte bits for their own payload;
      // interpreting those as a channel change can discard valid captions.
      // Each selected SCC input represents one field. The control-pair bit 3
      // selects channel 1 or 2 within that field; the import choice maps the
      // field/channel pair to CC1 through CC4.
      _channel = ((a >> 3) & 1) + 1;
      final pair = (a << 8) | b;
      if (_lastPair == pair) { _lastPair = -1; return; }
      _lastPair = pair;
    } else { _lastPair = -1; }
    if (_channel != selected) return;
    final control = a & 0xf7;
    if (isControl) {
      switch (b) {
        case 0x20: _mode = 'pop';
        case 0x21: if (_mode != 'unknown') _backspace();
        case 0x22: // Alarm commands do not change caption text.
        case 0x23: break;
        case 0x24:
          if (_mode != 'unknown') _writing.rows[_row].fillRange(_column, 32, ' ');
        case 0x25:
        case 0x26:
        case 0x27:
          if (_mode != 'roll') { _display = _SccMemory(); _loading = _SccMemory(); _row = 14; _column = 0; }
          _mode = 'roll'; _rollRows = b - 0x23; _rollBounds();
        case 0x28: break; // Flash styling stays in the original.
        case 0x29: _mode = 'paint';
        case 0x2a:
        case 0x2b: throw FormatException(SubtitleSccDecoder._message(_messages, 'subtitleImportSccTextUnsupportedError', 'SCC TEXT service requires a native caption decoder.'));
        case 0x2c: _display = _SccMemory();
        case 0x2d:
          if (_mode == 'roll') {
            for (var row = math.max(0, _row - _rollRows + 1); row < _row; row++) { _display.rows[row] = List.of(_display.rows[row + 1]); }
            _display.rows[_row] = List.filled(32, ' '); _column = 0;
          } else if (_mode != 'unknown') { _row = math.min(14, _row + 1); _column = 0; }
        case 0x2e: _loading = _SccMemory();
        case 0x2f:
          final old = _display; _display = _loading; _loading = old; _mode = 'pop';
      }
    } else if (_mode == 'unknown') {
      return; // A partial file must select a caption mode before writing text.
    } else if (a >= 0x10 && a <= 0x1f && b >= 0x40 && b <= 0x7f) {
      final row = const [10, 0, 2, 11, 13, 4, 6, 8][a & 7] + ((b & 0x20) == 0 ? 0 : 1);
      if (row >= 15) throw FormatException(SubtitleSccDecoder._message(_messages, 'subtitleImportSccRowAddressError', 'Invalid SCC row address.'));
      if (_mode == 'roll' && row != _row) {
        final moved = _SccMemory(), retained = math.min(_rollRows, math.min(row + 1, _row + 1));
        for (var n = 0; n < retained; n++) { moved.rows[row - n] = List.of(_display.rows[_row - n]); }
        _display = moved; _row = row;
      } else { _row = row; }
      _column = (b & 0x10) == 0 ? 0 : ((b >> 1) & 7) * 4;
    } else if (control == 0x11 && b >= 0x30 && b <= 0x3f) {
      _write(_special[b - 0x30]);
    } else if ((control == 0x12 || control == 0x13) && b >= 0x20 && b <= 0x3f) {
      _backspace(); _write((control == 0x12 ? _western1 : _western2)[b - 0x20]);
    } else if (control == 0x11 && b >= 0x20 && b <= 0x2f) {
      _write(' '); // Midrow attributes occupy one display cell.
    } else if (control == 0x17 && b >= 0x21 && b <= 0x23) {
      _column = math.min(32, _column + b - 0x20);
    } else if (control == 0x10 && b >= 0x20 && b <= 0x2f || control == 0x17 && b >= 0x2d && b <= 0x2f) {
      // Background/color attributes do not become text in the derivative.
    } else if (a >= 0x20 || a == 0) {
      if (a >= 0x20) _write(_basic[a] ?? String.fromCharCode(a));
      if (b >= 0x20) _write(_basic[b] ?? String.fromCharCode(b));
      else if (b != 0) throw FormatException(SubtitleSccDecoder._message(_messages, 'subtitleImportSccSecondCharacterError', 'Invalid SCC second character.'));
    } else {
      throw FormatException(SubtitleSccDecoder._message(_messages, 'subtitleImportSccControlPairError', 'Unsupported SCC control pair.'));
    }
    _publish(at);
  }
}
