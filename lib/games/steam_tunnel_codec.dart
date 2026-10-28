import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../services/companion_remote/remote_auth_context.dart';

/// Versioned, mutually authenticated, forward-secret Steam packet channel.
/// Pairing material is never sent to the relay. Every session has fresh X25519
/// keys/nonces; AES-GCM keys and counters are separate in each direction.
class SteamTunnelCodec {
  SteamTunnelCodec._(this.host, this._secret, this._member, this._allowed, this._keyPair, this._hello);
  final bool host;
  final List<int> _secret, _member;
  final List<List<int>> _allowed;
  final SimpleKeyPair _keyPair;
  final Uint8List _hello;
  SecretKey? _sendKey, _receiveKey;
  int _send = 0, _highest = -1;
  final _seen = <int>{};
  bool _closed = false;
  static final _cipher = AesGcm.with256bits();
  static final _dh = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static List<int> _mac(List<int> key, List<int> value) => crypto.Hmac(crypto.sha256, key).convert(value).bytes;
  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String roomToken(RemoteAuthContext context) {
    if (!context.isPaired || context.homeSecret.length != 32) throw const FormatException('Pairing required');
    return base64Url.encode(_mac(context.homeSecret, utf8.encode('plezy-steam-relay-room-v1'))).replaceAll('=', '');
  }

  static Future<SteamTunnelCodec> create(RemoteAuthContext context, {required bool host}) async {
    roomToken(context);
    if (context.userUuid.isEmpty || context.allowedUserUuids.isEmpty) throw const FormatException('Identity required');
    final secret = _mac(context.homeSecret, utf8.encode('plezy-steam-tunnel-psk-v1'));
    List<int> member(String id) => _mac(secret, utf8.encode('member:$id'));
    final keyPair = await _dh.newKeyPair();
    final public = await keyPair.extractPublicKey();
    final random = Random.secure();
    final hello = Uint8List.fromList([
      0x10,
      host ? 1 : 0,
      ...public.bytes,
      ...List.generate(32, (_) => random.nextInt(256)),
      ...member(context.userUuid),
    ]);
    return SteamTunnelCodec._(
      host,
      secret,
      member(context.userUuid),
      context.allowedUserUuids.take(256).map(member).toList(),
      keyPair,
      Uint8List.fromList([...hello, ..._mac(secret, hello)]),
    );
  }

  Uint8List get hello => Uint8List.fromList(_hello);
  bool get established => !_closed && _sendKey != null;
  Future<void> acceptHello(Uint8List message) async {
    if (_closed ||
        established ||
        message.length != 130 ||
        message[0] != 0x10 ||
        message[1] != (host ? 0 : 1) ||
        !_equal(_mac(_secret, message.sublist(0, 98)), message.sublist(98)) ||
        !_allowed.any((member) => _equal(member, message.sublist(66, 98)))) {
      throw const FormatException('Invalid Steam tunnel handshake');
    }
    final shared = await _dh.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(message.sublist(2, 34), type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((b) => b == 0)) throw const FormatException('Invalid key');
    final salt = host
        ? [..._hello.sublist(34, 66), ...message.sublist(34, 66)]
        : [...message.sublist(34, 66), ..._hello.sublist(34, 66)];
    final material = SecretKey([...sharedBytes, ..._secret]);
    Future<SecretKey> key(bool hostToReceiver) => _hkdf.deriveKey(
      secretKey: material,
      nonce: salt,
      info: utf8.encode('plezy-steam-tunnel-v1:${hostToReceiver ? 'host' : 'receiver'}'),
    );
    final send = await key(host), receive = await key(!host);
    if (_closed) throw const FormatException('Closed tunnel');
    _sendKey = send;
    _receiveKey = receive;
  }

  Future<Uint8List> seal(int kind, List<int> payload) async {
    if (!established || kind < 0 || kind > 4 || payload.length > 65000 || _send >= 0x1fffffffffffff) {
      throw const FormatException('Invalid tunnel packet');
    }
    final header = Uint8List(10)
      ..[0] = 0x11
      ..[1] = kind;
    ByteData.sublistView(header).setUint64(2, _send++, Endian.big);
    final nonce = Uint8List(12)..[0] = host ? 1 : 0;
    nonce.setRange(4, 12, header.sublist(2));
    final box = await _cipher.encrypt(payload, secretKey: _sendKey!, nonce: nonce, aad: header);
    if (_closed) throw const FormatException('Closed tunnel');
    return Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Call serially. UDP reordering is allowed within 2,048 authenticated packets;
  /// a failed tag never advances the replay window or consumes a valid counter.
  Future<({int kind, Uint8List payload})?> open(Uint8List packet) async {
    if (!established || packet.length < 26 || packet.length > 65026 || packet[0] != 0x11 || packet[1] > 4) return null;
    final header = packet.sublist(0, 10);
    final sequence = ByteData.sublistView(header).getUint64(2, Endian.big);
    if (sequence > 0x1fffffffffffff || sequence <= _highest - 2048 || _seen.contains(sequence)) return null;
    final nonce = Uint8List(12)..[0] = host ? 0 : 1;
    nonce.setRange(4, 12, header.sublist(2));
    List<int> clear;
    try {
      clear = await _cipher.decrypt(
        SecretBox(packet.sublist(10, packet.length - 16), nonce: nonce, mac: Mac(packet.sublist(packet.length - 16))),
        secretKey: _receiveKey!,
        aad: header,
      );
    } on SecretBoxAuthenticationError {
      return null;
    }
    if (_closed) return null;
    if (sequence > _highest) _highest = sequence;
    _seen.add(sequence);
    _seen.removeWhere((n) => n <= _highest - 2048);
    return (kind: packet[1], payload: Uint8List.fromList(clear));
  }

  void close() {
    _closed = true;
    _sendKey = null;
    _receiveKey = null;
    _seen.clear();
    _secret.fillRange(0, _secret.length, 0);
    _member.fillRange(0, _member.length, 0);
  }
}
