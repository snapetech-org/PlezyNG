import 'dart:convert';
import 'dart:typed_data';

/// Bounded, ordered frames for the encrypted music channel. A frame fits
/// comfortably inside a relay message even after transport encryption.
class MusicWirePayload {
  static const frameBytes = 16 * 1024;
  static const maxBytes = 4 * 1024 * 1024;
  static const maxFrames = maxBytes ~/ frameBytes;
  static const maxEncodedFrame = ((frameBytes + 2) ~/ 3) * 4;

  static List<String> encode(Map<String, dynamic> payload) {
    final bytes = utf8.encode(jsonEncode(payload));
    if (bytes.length > maxBytes) throw StateError('Music payload exceeds the transfer budget');
    return [
      for (var offset = 0; offset < bytes.length; offset += frameBytes)
        base64Encode(Uint8List.sublistView(bytes, offset, (offset + frameBytes).clamp(0, bytes.length))),
    ];
  }

  MusicWirePayload(this.count) : assert(count > 0 && count <= maxFrames);

  final int count;
  final _bytes = BytesBuilder(copy: false);
  int _next = 0;

  bool get complete => _next == count;

  bool add(int index, String encoded) {
    if (index != _next || complete || encoded.isEmpty || encoded.length > maxEncodedFrame) return false;
    final Uint8List frame;
    try {
      frame = base64Decode(encoded);
    } on FormatException {
      return false;
    }
    if (frame.isEmpty || frame.length > frameBytes || (index + 1 < count && frame.length != frameBytes)) {
      return false;
    }
    _bytes.add(frame);
    _next++;
    return true;
  }

  Map<String, dynamic>? decode() {
    if (!complete) return null;
    try {
      final decoded = jsonDecode(utf8.decode(_bytes.takeBytes()));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
