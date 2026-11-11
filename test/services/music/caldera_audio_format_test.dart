import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/caldera_audio_format.dart';
import 'package:plezy/services/music/caldera_group.dart';

void main() {
  late HttpServer server;
  late CalderaNode node;
  var body = '2', status = 200, current = true;
  Completer<void>? gate, arrived;
  setUp(() async {
    final address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((interface) => interface.addresses).firstWhere(CalderaNode.privateAddress);
    server = await HttpServer.bind(address, 0);
    node = CalderaNode(
      id: '11111111-1111-4111-8111-111111111111',
      name: 'Fixture',
      address: address,
      companionPort: server.port,
      meshPort: server.port,
      expires: DateTime.now().add(const Duration(minutes: 1)),
    );
    body = '2';
    status = 200;
    current = true;
    gate = arrived = null;
    server.listen((request) async {
      expect(request.uri.path, '/api/prefs');
      expect(request.uri.queryParameters, {'name': 'audio.channels'});
      arrived?.complete();
      await gate?.future;
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));
  for (final width in [0, 2, 6, 8]) {
    test('configured $width channels have a bounded native contract', () async {
      body = '$width';
      expect(await CalderaAudioFormat.read(node, current: () => current), (
        channels: width == 0 ? 2 : width,
        negotiated: true,
      ));
    });
  }
  for (final code in [404, 405]) {
    test('legacy $code retains the established stereo format', () async {
      status = code;
      expect(await CalderaAudioFormat.read(node, current: () => current), (channels: 2, negotiated: false));
    });
  }
  for (final value in ['1', '3', '16', '-2', '2.0', '"6"', '[6]', '{"channels":6}', 'NaN', 'x' * 65]) {
    test('unsupported or malformed width $value fails closed', () async {
      body = value;
      await expectLater(CalderaAudioFormat.read(node, current: () => current), throwsFormatException);
    });
  }
  test('redirects are not followed or treated as a stereo negotiation', () async {
    status = 302;
    await expectLater(CalderaAudioFormat.read(node, current: () => current), throwsFormatException);
  });
  test('retirement during the preference read cannot adopt its format', () async {
    gate = Completer<void>();
    arrived = Completer<void>();
    final result = expectLater(CalderaAudioFormat.read(node, current: () => current), throwsStateError);
    await arrived!.future;
    current = false;
    gate!.complete();
    await result;
  });
}
