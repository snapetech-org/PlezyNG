import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/music/music_relay_configuration.dart';
import 'package:plezy/services/sensitive_prefs.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  test('relay URLs require HTTPS and keep capabilities outside the URL', () {
    expect(musicRelayUri('https://music.example/base').toString(), 'wss://music.example/base/music/connect/relay');
    for (final bad in [
      'http://music.example',
      'https://a:b@music.example',
      'https://music.example?q=secret',
      'https://plezy.app',
      'https://music.example/#secret',
    ]) {
      expect(() => musicRelayUri(bad), throwsStateError);
    }
    expect(MusicRelayTarget.read({'url': 'https://music.example', 'room': 'bad', 'control': 'bad'}), isNull);
  });

  test('relay secrets are profile scoped, encrypted, stable and rotated with pairing', () async {
    final first = await MusicRelayStore.host('one', 'pairing-a');
    expect(await MusicRelayStore.host('one', 'pairing-a').then((value) => value.secret), first.secret);
    expect(first.secret, isNot(first.control));
    expect((await MusicRelayStore.host('two', 'pairing-a')).secret, isNot(first.secret));
    expect((await MusicRelayStore.host('one', 'pairing-b')).secret, isNot(first.secret));
    final target = MusicRelayTarget(
      uri: musicRelayUri('https://music.example'),
      room: first.room,
      control: first.control,
    );
    await MusicRelayStore.remember('one', 'peer', target);
    expect((await MusicRelayStore.target('one', 'peer'))?.toJson(), target.toJson());
    expect(await MusicRelayStore.target('two', 'peer'), isNull);
    final prefs = await BaseSharedPreferencesService.sharedCache();
    for (final key in prefs.keys.where((key) => key.endsWith('root') || key.contains('peer_'))) {
      expect(isSensitivePrefKey(key), isTrue);
      expect(CredentialVault.isProtected(prefs.getString(key)), isTrue);
    }
    await MusicRelayStore.removeProfile('one');
    expect(await MusicRelayStore.target('one', 'peer'), isNull);
    expect((await MusicRelayStore.host('two', 'pairing-a')).secret, isNot(first.secret));
  });
}
