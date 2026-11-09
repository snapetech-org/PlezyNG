import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/visualization/visualizer_sigstore_verifier.dart';

void main() {
  final path = Platform.environment['PLEZY_CATALOG_FIXTURE'] ??
      'test/fixtures/visualizer/authenticated-catalog.json';
  final file = File(path);
  Map<String, dynamic> fixture() => jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  Map<String, dynamic> bundle() => fixture()['sigstoreBundle'] as Map<String, dynamic>;
  List<int> message() => [...utf8.encode('MilkRust.catalog.v1\n'), ...base64Decode(fixture()['payload'] as String)];
  DateTime clock() {
    final payload = jsonDecode(utf8.decode(base64Decode(fixture()['payload'] as String))) as Map<String, dynamic>;
    return DateTime.parse(payload['issuedAt'] as String).add(const Duration(hours: 1));
  }

  test('rejects malformed and public-key-only envelopes', () {
    for (final value in [null, [], {}, {'mediaType': 'application/vnd.dev.sigstore.bundle.v0.3+json', 'verificationMaterial': {'publicKey': {}}}]) {
      expect(() => VisualizerSigstoreVerifier.verify(value, [1], DateTime.now()), throwsFormatException);
    }
  });

  group('authentic canonical publisher', () {
    test('verifies the official Cosign-signed exact catalog bytes', () {
      VisualizerSigstoreVerifier.verify(bundle(), message(), clock());
    });

    test('rejects changed signed payload bytes', () {
      final changed = message()..[0] ^= 1;
      expect(() => VisualizerSigstoreVerifier.verify(bundle(), changed, clock()), throwsFormatException);
    });

    test('rejects unsigned timestamp and index changes', () {
      for (final field in ['integratedTime', 'logIndex']) {
        final value = bundle();
        final entry = value['verificationMaterial']['tlogEntries'][0] as Map<String, dynamic>;
        entry[field] = (int.parse(entry[field] as String) + 1).toString();
        expect(() => VisualizerSigstoreVerifier.verify(value, message(), clock()), throwsFormatException);
      }
    });

    test('rejects a public-key downgrade despite an otherwise authentic bundle', () {
      final value = bundle();
      value['verificationMaterial']['publicKey'] = {'hint': 'publisher'};
      expect(() => VisualizerSigstoreVerifier.verify(value, message(), clock()), throwsFormatException);
    });

    test('rejects missing promise, replaced certificate and unknown log', () {
      for (final fault in ['promise', 'certificate', 'log', 'signature', 'digest']) {
        final value = bundle();
        final material = value['verificationMaterial'] as Map<String, dynamic>;
        final entry = material['tlogEntries'][0] as Map<String, dynamic>;
        switch (fault) {
          case 'promise':
            entry.remove('inclusionPromise');
          case 'certificate':
            material['certificate'] = {'rawBytes': base64Encode([48, 0])};
          case 'log':
            entry['logId']['keyId'] = base64Encode(List<int>.filled(32, 0));
          case 'signature':
            value['messageSignature']['signature'] = base64Encode([48, 0]);
          case 'digest':
            value['messageSignature']['messageDigest']['algorithm'] = 'SHA2_512';
        }
        expect(() => VisualizerSigstoreVerifier.verify(value, message(), clock()), throwsFormatException);
      }
    });

    test('rejects a log timestamp in the future', () {
      expect(() => VisualizerSigstoreVerifier.verify(bundle(), message(), DateTime.utc(2020)), throwsFormatException);
    });
  });
}
