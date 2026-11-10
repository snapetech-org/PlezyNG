import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_nfc_writer.dart';

import '../../test_helpers/music_experience_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.pleazyng/music_nfc');
  const writer = MusicNfcWriter();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test('tag contains only durable server and item identity, never credentials or profile state', () async {
    expect(await writer.available, isTrue);
    final item = musicTrack('one').copyWith(raw: {'token': 'secret'}, thumbPath: 'https://host?token=secret');
    expect(await writer.write(item), isTrue);
    final data = Map<String, dynamic>.from(calls.last.arguments as Map);
    final uri = Uri.parse(data['uri'] as String);
    expect(uri.scheme, 'pleazyng');
    expect(uri.host, 'play');
    expect(uri.queryParameters, {'server': 's', 'id': 'one'});
    expect(jsonEncode(data), isNot(contains('secret')));
  });

  test('invalid items never reach native writing', () async {
    await expectLater(
      writer.write(MediaItem.fromJson({...musicTrack('one').toJson(), 'serverId': null})),
      throwsArgumentError,
    );
    await expectLater(
      writer.write(MediaItem.fromJson({...musicTrack('one').toJson(), 'kind': MediaKind.movie.name})),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });

  test('cancellation is distinct from write failure and unavailable platforms', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'cancelled');
    });
    expect(await writer.write(musicTrack('one')), isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'write_failed');
    });
    await expectLater(writer.write(musicTrack('one')), throwsA(isA<PlatformException>()));
    await writer.cancel();
    expect(await writer.available, isFalse);
  });
}
