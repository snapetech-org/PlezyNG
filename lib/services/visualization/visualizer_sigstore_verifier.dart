import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart' as pc;

import 'visualizer_sigstore_trust.dart';

/// Deliberately narrow verification profile for this application's publisher:
/// Sigstore v0.3, a Fulcio P-256 leaf, a pinned Fulcio intermediate and a Rekor
/// v1 hashedrekord with its signed entry timestamp. It is not a general-purpose
/// Sigstore client: public-key bundles, DSSE, alternative roots, identities,
/// algorithms and Rekor v2 are rejected. The publisher uses the same pinned
/// signing configuration and additionally verifies with official Cosign.
class VisualizerSigstoreVerifier {
  static void verify(Object? bundle, List<int> message, DateTime now) {
    try {
      _verify(bundle, Uint8List.fromList(message), now.toUtc());
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid keyless catalog signature');
    }
  }

  static void _verify(Object? raw, Uint8List message, DateTime now) {
    final bundle = _map(raw);
    _require(bundle['mediaType'] == 'application/vnd.dev.sigstore.bundle.v0.3+json');
    final material = _map(bundle['verificationMaterial']);
    _require(!material.containsKey('publicKey') && !bundle.containsKey('dsseEnvelope'));
    final certificate = _bytes(_map(material['certificate'])['rawBytes'], 16384);
    final leaf = _Certificate(certificate);
    final authority = _Certificate(base64Decode(catalogFulcioAuthority));
    final signature = _map(bundle['messageSignature']);
    final digest = _map(signature['messageDigest']);
    final expectedHash = hashes.sha256.convert(message);
    _require(digest['algorithm'] == 'SHA2_256');
    _require(_same(_bytes(digest['digest'], 32), expectedHash.bytes));
    final signed = _bytes(signature['signature'], 128);
    final entries = material['tlogEntries'];
    _require(entries is List && entries.length == 1);
    final entry = _map((entries as List).single);
    final kind = _map(entry['kindVersion']);
    _require(kind['kind'] == 'hashedrekord' && kind['version'] == '0.0.1');
    _require(_map(entry['logId'])['keyId'] == catalogRekorLogId);
    final integrated = _integer(entry['integratedTime']);
    final index = _integer(entry['logIndex']);
    final time = DateTime.fromMillisecondsSinceEpoch(integrated * 1000, isUtc: true);
    _require(!time.isBefore(DateTime.utc(2022, 4, 13, 20, 6, 15)));
    _require(!time.isAfter(now.add(const Duration(minutes: 5))));
    final bodyBytes = _bytes(entry['canonicalizedBody'], 65536);
    final body = _map(jsonDecode(utf8.decode(bodyBytes)));
    _require(body['kind'] == 'hashedrekord' && body['apiVersion'] == '0.0.1');
    final spec = _map(body['spec']);
    final bodyHash = _map(_map(spec['data'])['hash']);
    _require(bodyHash['algorithm'] == 'sha256' && bodyHash['value'] == expectedHash.toString());
    final bodySignature = _map(spec['signature']);
    _require(_same(_bytes(bodySignature['content'], 128), signed));
    final pem = utf8.decode(_bytes(_map(bodySignature['publicKey'])['content'], 32768));
    final match = RegExp(r'^-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----\s*$').firstMatch(pem);
    _require(match != null);
    _require(_same(base64Decode(match!.group(1)!.replaceAll(RegExp(r'\s'), '')), certificate));
    final logHex = base64Decode(catalogRekorLogId).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    // Rekor SET signs RFC 8785 canonical JSON. These four bounded fields contain
    // only integers, base64 and hex, so sorted insertion has exactly that form.
    final promise = utf8.encode(jsonEncode({
      'body': base64Encode(bodyBytes),
      'integratedTime': integrated,
      'logID': logHex,
      'logIndex': index,
    }));
    _signature(
      _Der.one(base64Decode(catalogRekorPublicKey)),
      Uint8List.fromList(promise),
      _bytes(_map(entry['inclusionPromise'])['signedEntryTimestamp'], 128),
      '1.2.840.10045.4.3.2',
    );
    _require(_same(leaf.issuer.raw, authority.subject.raw));
    _require(!time.isBefore(authority.notBefore) && !time.isAfter(authority.notAfter));
    _require(!time.isBefore(leaf.notBefore) && !time.isAfter(leaf.notAfter));
    _require(leaf.notAfter.isAfter(leaf.notBefore) && leaf.notAfter.difference(leaf.notBefore) <= const Duration(hours: 1));
    _signature(authority.publicKey, leaf.tbs.raw, leaf.signature, leaf.signatureAlgorithm);
    leaf.requirePublisher();
    _require(leaf.publicKey.children.first.children[1].oid == '1.2.840.10045.3.1.7');
    _signature(leaf.publicKey, message, signed, '1.2.840.10045.4.3.2');
  }
}

Map<String, dynamic> _map(Object? value) {
  _require(value is Map<String, dynamic>);
  return value as Map<String, dynamic>;
}

void _require(bool valid) {
  if (!valid) throw const FormatException('Invalid keyless catalog signature');
}

Uint8List _bytes(Object? value, int maximum) {
  _require(value is String && value.length <= (maximum * 4 ~/ 3 + 8));
  final result = base64Decode(value as String);
  _require(result.isNotEmpty && result.length <= maximum);
  return result;
}

int _integer(Object? value) {
  // Protobuf JSON represents int64 fields as decimal strings.
  _require(value is String && RegExp(r'^(0|[1-9][0-9]{0,15})$').hasMatch(value));
  final number = int.parse(value as String);
  _require(number <= 9007199254740991);
  return number;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Strict, length-bounded DER reader. Constructed children are decoded only
/// where the verification profile requires them; opaque extensions stay opaque.
class _Der {
  _Der(this.raw, this.tag, this.value);
  final Uint8List raw;
  final int tag;
  final Uint8List value;

  static _Der one(Uint8List bytes) {
    _require(bytes.length >= 2 && bytes.length <= 65536);
    final node = _read(bytes, 0);
    _require(node.raw.length == bytes.length);
    return node;
  }

  static _Der _read(Uint8List bytes, int start) {
    _require(start >= 0 && start + 2 <= bytes.length);
    final tag = bytes[start];
    _require((tag & 31) != 31);
    var cursor = start + 1;
    var length = bytes[cursor++];
    if (length >= 128) {
      final count = length & 127;
      _require(count > 0 && count <= 3 && cursor + count <= bytes.length && bytes[cursor] != 0);
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[cursor++];
      }
      _require(length >= 128);
    }
    _require(length <= 65536 && cursor + length <= bytes.length);
    return _Der(Uint8List.sublistView(bytes, start, cursor + length), tag, Uint8List.sublistView(bytes, cursor, cursor + length));
  }

  List<_Der> get children {
    _require((tag & 32) != 0);
    final nodes = <_Der>[];
    var cursor = 0;
    while (cursor < value.length) {
      _require(nodes.length < 128);
      final node = _read(value, cursor);
      nodes.add(node);
      cursor += node.raw.length;
    }
    return nodes;
  }

  String get oid {
    _require(tag == 6 && value.isNotEmpty && value.length <= 64);
    final first = value.first < 80 ? value.first ~/ 40 : 2;
    final parts = <int>[first, value.first - first * 40];
    var number = 0;
    var started = false;
    for (final byte in value.skip(1)) {
      _require(started || byte != 128);
      number = (number << 7) | (byte & 127);
      _require(number <= 0x7fffffff);
      started = (byte & 128) != 0;
      if (!started) {
        parts.add(number);
        number = 0;
      }
    }
    _require(!started);
    return parts.join('.');
  }

  BigInt get integer {
    _require(tag == 2 && value.isNotEmpty && value.length <= 67 && value.first < 128);
    _require(value.length == 1 || value.first != 0 || value[1] >= 128);
    return BigInt.parse(value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), radix: 16);
  }

  Uint8List get bits {
    _require(tag == 3 && value.length > 1 && value.first == 0);
    return Uint8List.sublistView(value, 1);
  }
}

void _signature(_Der spki, Uint8List message, Uint8List signature, String algorithm) {
  _require(spki.tag == 48);
  final key = spki.children;
  _require(key.length == 2 && key.first.tag == 48);
  final parameters = key.first.children;
  _require(parameters.length == 2 && parameters.first.oid == '1.2.840.10045.2.1');
  final curve = parameters[1].oid;
  _require(curve == '1.2.840.10045.3.1.7' || curve == '1.3.132.0.34');
  _require(algorithm == '1.2.840.10045.4.3.2' || algorithm == '1.2.840.10045.4.3.3');
  final domain = pc.ECDomainParameters(curve == '1.3.132.0.34' ? 'secp384r1' : 'prime256v1');
  final pointBytes = key[1].bits;
  _require(pointBytes.length == (curve == '1.3.132.0.34' ? 97 : 65) && pointBytes.first == 4);
  final point = domain.curve.decodePoint(pointBytes);
  _require(point != null && !point.isInfinity);
  final derSignature = _Der.one(signature);
  _require(derSignature.tag == 48);
  final parts = derSignature.children;
  _require(parts.length == 2);
  final r = parts[0].integer, s = parts[1].integer;
  _require(r > BigInt.zero && s > BigInt.zero && r < domain.n && s < domain.n);
  final signer = pc.ECDSASigner(algorithm == '1.2.840.10045.4.3.3' ? pc.SHA384Digest() : pc.SHA256Digest())
    ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(point, domain)));
  _require(signer.verifySignature(message, pc.ECSignature(r, s)));
}

class _Certificate {
  _Certificate(Uint8List bytes) {
    final certificate = _Der.one(bytes);
    _require(certificate.tag == 48);
    final parts = certificate.children;
    _require(parts.length == 3 && parts[0].tag == 48 && parts[1].tag == 48);
    tbs = parts[0];
    final fields = tbs.children;
    _require(fields.length == 8 && fields[0].tag == 160 && fields[7].tag == 163);
    _require(fields[0].children.length == 1 && fields[0].children.single.integer == BigInt.two);
    _require(fields[1].integer > BigInt.zero && _same(fields[2].raw, parts[1].raw));
    final algorithm = parts[1].children;
    _require(algorithm.length == 1);
    signatureAlgorithm = algorithm.single.oid;
    signature = parts[2].bits;
    issuer = fields[3];
    subject = fields[5];
    publicKey = fields[6];
    _require(fields[4].tag == 48 && fields[4].children.length == 2);
    notBefore = _date(fields[4].children[0]);
    notAfter = _date(fields[4].children[1]);
    final extWrapper = fields[7].children;
    _require(extWrapper.length == 1 && extWrapper.single.tag == 48);
    for (final item in extWrapper.single.children) {
      _require(item.tag == 48);
      final ext = item.children;
      _require(ext.length == 2 || ext.length == 3);
      final oid = ext.first.oid;
      _require(!extensions.containsKey(oid) && ext.last.tag == 4);
      if (ext.length == 3) {
        _require(ext[1].tag == 1 && ext[1].value.length == 1 && ext[1].value.single == 255);
        _require({'2.5.29.15', '2.5.29.17', '2.5.29.19', '2.5.29.37'}.contains(oid));
      }
      extensions[oid] = ext.last.value;
    }
  }

  late final _Der tbs, issuer, subject, publicKey;
  late final Uint8List signature;
  late final String signatureAlgorithm;
  late final DateTime notBefore, notAfter;
  final extensions = <String, Uint8List>{};

  void requirePublisher() {
    final names = _Der.one(extensions['2.5.29.17']!);
    _require(names.tag == 48 && names.children.length == 1);
    final name = names.children.single;
    _require(name.tag == 134 && utf8.decode(name.value) == catalogPublisherIdentity);
    final issuerV2 = extensions['1.3.6.1.4.1.57264.1.8'];
    final issuerV1 = extensions['1.3.6.1.4.1.57264.1.1'];
    _require(issuerV1 != null || issuerV2 != null);
    if (issuerV2 != null) {
      final text = _Der.one(issuerV2);
      _require(text.tag == 12 && utf8.decode(text.value) == catalogPublisherIssuer);
    }
    if (issuerV1 != null) _require(utf8.decode(issuerV1) == catalogPublisherIssuer);
    for (final claim in {
      '1.3.6.1.4.1.57264.1.15': catalogPublisherRepositoryId,
      '1.3.6.1.4.1.57264.1.17': catalogPublisherOwnerId,
    }.entries) {
      final value = _Der.one(extensions[claim.key]!);
      _require(value.tag == 12 && utf8.decode(value.value) == claim.value);
    }
    final usage = _Der.one(extensions['2.5.29.15']!);
    _require(usage.tag == 3 && _same(usage.value, [7, 128]));
    final extended = _Der.one(extensions['2.5.29.37']!);
    _require(extended.tag == 48 && extended.children.length == 1 && extended.children.single.oid == '1.3.6.1.5.5.7.3.3');
    final constraint = extensions['2.5.29.19'];
    if (constraint != null) {
      final basic = _Der.one(constraint);
      _require(basic.tag == 48 && basic.children.isEmpty);
    }
  }

  static DateTime _date(_Der node) {
    _require(node.tag == 23 || node.tag == 24);
    final text = ascii.decode(node.value);
    final utc = node.tag == 23;
    _require(RegExp(utc ? r'^\d{12}Z$' : r'^\d{14}Z$').hasMatch(text));
    var offset = utc ? 2 : 4;
    var year = int.parse(text.substring(0, offset));
    if (utc) year += year < 50 ? 2000 : 1900;
    int next() { final n = int.parse(text.substring(offset, offset + 2)); offset += 2; return n; }
    final month = next(), day = next(), hour = next(), minute = next(), second = next();
    final date = DateTime.utc(year, month, day, hour, minute, second);
    _require(date.year == year && date.month == month && date.day == day && date.hour == hour && date.minute == minute && date.second == second);
    return date;
  }
}
