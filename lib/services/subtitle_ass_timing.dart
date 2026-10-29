/// Retimes ASS override clocks while leaving text, drawings, geometry, colors
/// and style names untouched. Times are relative to the Dialogue start. A
/// caller must retime event boundaries separately with the same multiplier.
abstract final class SubtitleAssTiming {
  static final _tag = RegExp(r'\\(fade|fad|move|kt|kf|ko|k|K|t)(?=[+\-0-9.( \t\\]|$)');
  static final _number = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');
  static final _karaokeNumber = RegExp(r'[ \t]*[+\-]?(?:\d+(?:\.\d*)?|\.\d+)');
  static const _limit = 0x7fffffff;

  static double _value(String value, {bool nonNegative = false}) {
    final text = value.trim();
    final number = _number.hasMatch(text) ? double.tryParse(text) : null;
    if (number == null || !number.isFinite || number.abs() > _limit || nonNegative && number < 0) {
      throw const FormatException('ASS contains an invalid or out-of-range effect time.');
    }
    return number;
  }

  static int _scaled(double value, double rate) {
    final result = (value * rate).round();
    if (result.abs() > _limit) throw const FormatException('Retimed ASS effect exceeds its timing range.');
    return result;
  }

  static String _replaceNumber(String original, int value) =>
      '${RegExp(r'^\s*').firstMatch(original)![0]}$value${RegExp(r'\s*$').firstMatch(original)![0]}';

  static List<String> _arguments(String body) {
    final parts = <String>[];
    var start = 0, depth = 0;
    for (var i = 0; i < body.length; i++) {
      if (body[i] == '(') {
        if (++depth > 16) throw const FormatException('ASS override nesting exceeds the supported bound.');
      } else if (body[i] == ')') {
        if (--depth < 0) throw const FormatException('ASS override parentheses are unbalanced.');
      } else if (body[i] == ',' && depth == 0) {
        parts.add(body.substring(start, i)); start = i + 1;
        if (parts.length > 16) throw const FormatException('ASS effect has too many parameters.');
      }
    }
    if (depth != 0) throw const FormatException('ASS override parentheses are unbalanced.');
    parts.add(body.substring(start));
    return parts;
  }

  /// Presence is checked only in override blocks; a literal \k outside braces
  /// is not rewritten. Pure offsets preserve the original relative payload.
  static ({String text, bool timed}) retime(String text, double rate) {
    if (text.length > 65536) throw const FormatException('ASS event text exceeds 64 KiB.');
    if (!rate.isFinite || rate < .8 || rate > 1.25) throw ArgumentError.value(rate, 'rate');
    final output = StringBuffer();
    var cursor = 0, blocks = 0, tags = 0;
    var karaokeCursor = 0.0;
    var timed = false;
    while (cursor < text.length) {
      final open = text.indexOf('{', cursor);
      if (open < 0) { output.write(text.substring(cursor)); break; }
      output.write(text.substring(cursor, open + 1));
      final close = text.indexOf('}', open + 1);
      if (close < 0 || ++blocks > 4096 || text.substring(open + 1, close).contains('{')) {
        throw const FormatException('ASS override braces are invalid or exceed the supported bound.');
      }
      final block = text.substring(open + 1, close);
      var at = 0;
      while (at < block.length) {
        final match = _tag.matchAsPrefix(block, at);
        if (match == null) { output.write(block[at++]); continue; }
        if (++tags > 8192) throw const FormatException('ASS event has too many timing tags.');
        timed = true;
        final name = match[1]!;
        var end = match.end;
        if (name.startsWith('k') || name == 'K') {
          final number = _karaokeNumber.matchAsPrefix(block, end);
          if (number == null) {
            // libass defaults an omitted duration to 100 cs (kt to zero).
            // Emit that default explicitly when changing the clock.
            final value = name == 'kt' ? 0.0 : 100.0;
            final oldCursor = karaokeCursor;
            karaokeCursor = name == 'kt' ? value : karaokeCursor + value;
            if (karaokeCursor * 10 > _limit || karaokeCursor * 10 * rate > _limit) {
              throw const FormatException('ASS karaoke clock is too large.');
            }
            output.write(rate == 1 ? match[0] : '\\$name${name == 'kt' ? 0 : _scaled(karaokeCursor, rate) - _scaled(oldCursor, rate)}');
          } else {
            final original = number[0]!;
            final value = _value(original, nonNegative: true);
            final oldCursor = karaokeCursor;
            karaokeCursor = name == 'kt' ? value : karaokeCursor + value;
            if (karaokeCursor * 10 > _limit || karaokeCursor * 10 * rate > _limit) {
              throw const FormatException('ASS karaoke clock is too large.');
            }
            final transformed = name == 'kt' ? _scaled(value, rate) :
                _scaled(karaokeCursor, rate) - _scaled(oldCursor, rate);
            output.write('\\$name${rate == 1 ? original : _replaceNumber(original, transformed)}');
            end += original.length;
          }
          at = end;
          continue;
        }
        while (end < block.length && (block[end] == ' ' || block[end] == '\t')) { end++; }
        if (end >= block.length || block[end] != '(') {
          throw const FormatException('ASS timed override needs a parenthesized argument list.');
        }
        final argumentsStart = ++end;
        var depth = 1;
        while (end < block.length && depth > 0) {
          if (block[end] == '(' && ++depth > 16) {
            throw const FormatException('ASS override nesting exceeds the supported bound.');
          }
          if (block[end] == ')') depth--;
          if (depth > 0) end++;
        }
        if (depth != 0) throw const FormatException('ASS timed override is incomplete.');
        final arguments = _arguments(block.substring(argumentsStart, end));
        void scale(int index, {bool nonNegative = false}) {
          final value = _value(arguments[index], nonNegative: nonNegative);
          if (rate != 1) arguments[index] = _replaceNumber(arguments[index], _scaled(value, rate));
        }
        switch (name) {
          case 't':
            if (arguments.isEmpty || arguments.length > 4 || !arguments.last.trimLeft().startsWith('\\') ||
                _tag.hasMatch(arguments.last)) {
              throw const FormatException('ASS transform has unsupported or nested timing parameters.');
            }
            if (arguments.length == 2 || arguments.length == 4) {
              if (_value(arguments[arguments.length - 2]) <= 0) {
                throw const FormatException('ASS transform acceleration must be positive.');
              }
            }
            if (arguments.length >= 3) { scale(0); scale(1); }
          case 'move':
            if (arguments.length != 4 && arguments.length != 6) {
              throw const FormatException('ASS move needs four or six parameters.');
            }
            for (var i = 0; i < 4; i++) { _value(arguments[i]); }
            if (arguments.length == 6) { scale(4); scale(5); }
          case 'fad':
            if (arguments.length != 2) throw const FormatException('ASS fad needs two parameters.');
            scale(0, nonNegative: true); scale(1, nonNegative: true);
          case 'fade':
            if (arguments.length != 7) throw const FormatException('ASS fade needs seven parameters.');
            for (var i = 0; i < 3; i++) {
              final alpha = _value(arguments[i]);
              if (alpha < 0 || alpha > 255 || alpha != alpha.roundToDouble()) {
                throw const FormatException('ASS fade alpha must be an integer from 0 to 255.');
              }
            }
            for (var i = 3; i < 7; i++) { scale(i); }
        }
        output.write(rate == 1 ? block.substring(at, end + 1) :
            '${block.substring(at, argumentsStart)}${arguments.join(',')})');
        at = end + 1;
      }
      output.write('}');
      cursor = close + 1;
    }
    return (text: output.toString(), timed: timed);
  }

  /// Legacy scroll/banner effects express speed as milliseconds per pixel.
  /// The integer delay scales with time; positions and fade geometry do not.
  static String retimeEffect(String effect, double rate) {
    if (effect.trim().isEmpty || rate == 1) return effect;
    final parts = effect.split(';');
    final kind = parts.first.trim();
    final int delayIndex;
    if (kind == 'Banner' && parts.length >= 2 && parts.length <= 4) {
      delayIndex = 1;
      if (parts.length > 2 && !const ['0', '1'].contains(parts[2].trim())) {
        throw const FormatException('ASS banner direction is invalid.');
      }
    } else if ((kind == 'Scroll up' || kind == 'Scroll down') && parts.length >= 4 && parts.length <= 5) {
      delayIndex = 3;
      _value(parts[1]); _value(parts[2]);
    } else {
      throw const FormatException('This legacy ASS effect cannot be scaled. Use a delay-only correction.');
    }
    final delay = _value(parts[delayIndex], nonNegative: true);
    // Renderer-specific defaults and clamping of a zero/fractional delay are
    // not a stable affine clock. Refuse them instead of inventing a speed.
    if (delay < 1 || delay != delay.roundToDouble()) {
      throw const FormatException('ASS scroll delay must be a positive integer.');
    }
    if (parts.length > delayIndex + 1 && kind != 'Banner') _value(parts.last, nonNegative: true);
    if (kind == 'Banner' && parts.length == 4) _value(parts.last, nonNegative: true);
    parts[delayIndex] = _replaceNumber(parts[delayIndex], _scaled(delay, rate));
    return parts.join(';');
  }
}
