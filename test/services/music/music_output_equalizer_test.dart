import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/music/music_audio_policy.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_playback_service_impl.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/prefs.dart';
import 'music_playback_service_test.dart'
    show FakePlayer, FakeMediaServerClient, FakeMusicSourceResolver, FakeMediaControlsManager;

class EqPlayer extends FakePlayer implements AudioEqualizerCapable {
  final properties = <String, String>{'audio-device': 'auto'};
  List<double> bands = List.filled(10, 0);
  @override
  String get playerType => 'mpv';
  @override
  Future<void> setAudioEqualizer(List<double> gains) async {
    bands = List.of(gains);
  }

  @override
  Future<String?> getProperty(String name) async => name == 'audio-device-list'
      ? jsonEncode([
          {'name': 'alsa/usb', 'description': 'USB DAC'},
          {'name': 'alsa/speakers', 'description': 'Speakers'},
        ])
      : properties[name];
  @override
  Future<void> setProperty(String name, String value) async {
    final previous = properties[name];
    properties[name] = value;
    if (name == 'audio-device' && previous != value) audioDeviceCtrl.add(AudioDevice(name: value));
  }

  @override
  Future<void> setAudioDevice(AudioDevice device) => setProperty('audio-device', device.name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late MusicLibraryStore store;
  late MusicPlaybackServiceImpl music;
  late EqPlayer player;
  late MultiServerManager servers;
  late FakeMediaControlsManager controls;
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'p');
    player = EqPlayer();
    final client = FakeMediaServerClient();
    servers = MultiServerManager()..debugRegisterClientForTesting(client);
    controls = FakeMediaControlsManager();
    music = MusicPlaybackServiceImpl(
      serverManager: servers,
      libraryStore: store,
      resolver: FakeMusicSourceResolver(client: client),
      audioPlayerFactory: () => player,
      mediaControlsFactory: () => controls,
      volumePersistenceWriter: (_) async {},
    );
    await pumpEventQueue();
  });
  tearDown(() async {
    await music.stop();
    music.dispose();
    await pumpEventQueue();
    player.closeControllers();
    controls.closeControllers();
    servers.dispose();
    await database.close();
  });
  Future<void> play() async {
    await music.playFromList(
      tracks: [musicTrack('song', server: 'srv')],
      playContext: const MusicPlayContext(title: 'Test', kind: MusicPlayContextKind.tracks),
    );
    await pumpEventQueue();
  }

  const eq = MusicAudioPolicy(bands: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0], preampDb: -3);

  test('device assignment follows output changes and restores general EQ on other outputs', () async {
    await music.setOutputEqualizer('alsa/usb', eq);
    await music.setAudioPolicy(const MusicAudioPolicy(output: 'alsa/usb'));
    await play();
    expect(player.bands.first, 3);
    expect(player.volumes.last, closeTo(100 * eq.gain, 0.001));
    await player.setAudioDevice(const AudioDevice(name: 'alsa/speakers'));
    await pumpEventQueue();
    expect(player.bands, everyElement(0));
    expect(player.volumes.last, 100);
    await player.setAudioDevice(const AudioDevice(name: 'alsa/usb'));
    await pumpEventQueue();
    expect(player.bands.first, 3);
    await music.setOutputEqualizer('alsa/usb', null);
    expect(player.bands, everyElement(0));
    expect(await music.outputEqualizer('alsa/usb'), isNull);
  });
  test('saved assignments are profile-owned and never change route or resampler', () async {
    await music.setOutputEqualizer(
      'alsa/usb',
      const MusicAudioPolicy(
        bands: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        preampDb: -3,
        output: 'alsa/other',
        sampleRate: 192000,
        exclusive: true,
      ),
    );
    final saved = (await music.outputEqualizer('alsa/usb'))!;
    expect(saved.output, 'auto');
    expect(saved.sampleRate, 0);
    expect(saved.exclusive, isFalse);
    expect(await MusicLibraryStore(database, 'another-profile').document('outputEq', 'alsa/usb'), isNull);
    await music.setAudioPolicy(const MusicAudioPolicy(output: 'alsa/usb', sampleRate: 48000));
    await play();
    expect(player.properties['audio-device'], 'alsa/usb');
    expect(player.properties['audio-samplerate'], '48000');
    expect((await music.availableAudioOutputs())['alsa/usb'], 'USB DAC');
  });
  test('changing the general EQ retains the current output assignment', () async {
    await music.setOutputEqualizer('alsa/usb', eq);
    await music.setAudioPolicy(const MusicAudioPolicy(output: 'alsa/usb'));
    await play();
    await music.setAudioPolicy(const MusicAudioPolicy(output: 'alsa/usb', bands: [-2, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    expect(player.bands.first, 3);
    await music.setOutputEqualizer('alsa/usb', null);
    expect(player.bands.first, -2);
  });
}
