import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/romm/romm_capabilities.dart';
import 'package:plezy/games/romm/romm_client.dart';
import 'package:plezy/games/romm/romm_link.dart';
import 'package:plezy/games/romm/romm_models.dart';

RommGame game({int id = 42, String hash = ''}) => RommGame(
  connectionId: 'library_0001', id: id, platformId: 1, name: 'Game',
  platform: 'gb', platformName: 'Game Boy', fileName: 'game.gb',
  extension: 'gb', size: 1024, sha1: hash,
);

void main() {
  test('game handoffs bind an exact copy and reject credential fields', () {
    final hash = List.filled(40, 'a').join();
    final link = RommLink(Uri.parse('https://media.example/romm/'), 42, 'sha1:$hash', platform: 'gb');
    final parsed = RommLink.parse(link.uri)!;
    expect(parsed.matches(game(hash: hash)), isTrue);
    expect(parsed.matches(game(id: 43, hash: hash)), isFalse);
    expect(parsed.matches(game(hash: List.filled(40, 'b').join())), isFalse);
    for (final uri in [
      link.uri.replace(query: '${link.uri.query}&token=secret'),
      link.uri.replace(query: '${link.uri.query}&rom=43'),
      link.uri.replace(queryParameters: {...link.uri.queryParameters, 'server': 'https://user:secret@media.example/'}),
      link.uri.replace(fragment: 'anything'),
    ]) {
      expect(RommLink.parse(uri), isNull);
    }
  });

  test('catalog client confines bearer requests to the configured prefix', () {
    final client = RommClient(rommBaseUri('https://media.example/romm/api'), token: 'private-token');
    addTearDown(client.close);
    expect(client.uri('api/roms/42').path, '/romm/api/roms/42');
    expect(client.resource('/assets/cover.jpg').path, '/romm/assets/cover.jpg');
    for (final target in ['https://other.example/cover', 'https://user:secret@media.example/romm/cover',
      '../secret', '/romm/%2e%2e/secret', '/romm/%252e%252e/secret',
      '/romm/assets%2f..%2fsecret', '/romm/assets%5c..%5csecret']) {
      expect(() => client.resource(target), throwsA(isA<RommFailure>()));
    }
    expect(() => client.uri('api/%2e%2e/secret'), throwsA(isA<RommFailure>()));
    expect(client.resource('assets/My%20Game.jpg').pathSegments.last, 'My Game.jpg');
    expect(() => client.uri('https://other.example/rom'), throwsA(isA<RommFailure>()));
    client.close();
    expect(client.requireCurrent, throwsA(isA<RommFailure>()));
  });

  test('cached server capabilities cannot enable a browser player', () {
    final fresh = RommCapabilities(
      observedAt: DateTime.now(), emulation: const {'DISABLE_EMULATOR_JS': false},
      scopes: const ['firmware.read'],
    );
    expect(fresh.routes(game(), browserAvailable: true).single.available, isTrue);
    final cached = RommCapabilities.cached(fresh.toJson());
    expect(cached.routes(game(), browserAvailable: true).single.available, isFalse);
    expect(cached.routes(game(), browserAvailable: false, nativeCores: {'gambatte'},
      offlineAvailable: true, offlineFileName: 'game.gb').where((r) => r.engine == RommEngine.native).single.available, isTrue);
    expect(cached.routes(game(), browserAvailable: false, nativeCores: {'gambatte'},
      offlineAvailable: true, offlineFileName: 'game.zip').where((r) => r.engine == RommEngine.native).single.available, isFalse);
  });
}
