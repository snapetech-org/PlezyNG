import '../../test_helpers/native_music_socket_lease.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/music_pcm_capture_source.dart';
import 'package:plezy/services/music/caldera_group.dart';
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

class EqPlayer extends FakePlayer implements AudioEqualizerCapable, MusicPcmCaptureSource {
  bool captureEnabled = false;
  @override
  Future<bool> musicPcmCaptureAvailable() async => true;
  @override
  Future<bool> setMusicPcmCaptureEnabled(bool enabled) async {
    captureEnabled = enabled;
    return true;
  }

  @override
  Future<List<MusicPcmBlock>> drainMusicPcmCapture() async => const [];
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
  useNativeMusicSocketLease();
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late MusicLibraryStore store;
  late MusicPlaybackServiceImpl music;
  late EqPlayer player;
  late EqPlayer groupOutput;
  late MultiServerManager servers;
  late FakeMediaControlsManager controls;
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'p');
    player = EqPlayer();
    groupOutput = EqPlayer();
    final client = FakeMediaServerClient();
    servers = MultiServerManager()..debugRegisterClientForTesting(client);
    controls = FakeMediaControlsManager();
    music = MusicPlaybackServiceImpl(
      serverManager: servers,
      libraryStore: store,
      resolver: FakeMusicSourceResolver(client: client),
      audioPlayerFactory: () => player,
      nativeGroupOutputFactory: () => groupOutput,
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
    groupOutput.closeControllers();
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
    expect(math.pow(player.volumes.last / 100, 3), closeTo(eq.gain, .00001));
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

  test('automatic output recovery keeps the queue, position, pause and general DSP', () async {
    await music.setAudioPolicy(
      const MusicAudioPolicy(
        output: 'alsa/usb',
        sampleRate: 96000,
        exclusive: true,
        leveling: MusicLeveling.album,
        preampDb: -3,
        bands: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        prefetchMiB: 128,
      ),
    );
    await play();
    player.setPosition(const Duration(seconds: 23));
    await music.pause();
    final track = music.currentTrack, queue = music.queue.toList(), opens = player.openedUris.toList();
    final before = music.audioPolicy.toJson();
    await music.setAudioPolicy(
      MusicAudioPolicy.fromJson({...before, 'output': 'auto', 'sampleRate': 0, 'exclusive': false}),
    );
    expect(music.currentTrack, same(track));
    expect(music.queue, queue);
    expect(music.position, const Duration(seconds: 23));
    expect(music.isPlaying, isFalse);
    expect(player.openedUris, opens);
    expect(player.properties['audio-device'], 'auto');
    expect(music.audioPolicy.toJson(), {...before, 'output': 'auto', 'sampleRate': 0, 'exclusive': false});
  });

  test('native source excludes local output presets and restores edits made while transmitting', () async {
    final address = (await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )).expand((interface) => interface.addresses).firstWhere(CalderaNode.privateAddress);
    final peer = await HttpServer.bind(address, 0);
    WebSocket? socket;
    const id = '11111111-1111-4111-8111-111111111111';
    peer.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.write('2');
        await request.response.close();
        return;
      }
      socket = await WebSocketTransformer.upgrade(request);
      socket!.listen((frame) {
        for (final message in CalderaGroupClient.meshMessages(frame as String)) {
          if (message['data'] == 'ping') {
            socket!.add('{"data":"ping"}');
            continue;
          }
          if (message['method'] == 'Hello' || message['method'] == 'SetSinksForSource') {
            socket!.add(
              jsonEncode({
                'method': 'SetNodeState',
                'source': id,
                'data': {
                  'version': '1.0.0',
                  'source': message['method'] == 'Hello' ? id : (message['data'] as Map)['source'],
                },
              }),
            );
          }
        }
      });
    });
    try {
      await music.setOutputEqualizer('alsa/usb', eq);
      await music.setAudioPolicy(const MusicAudioPolicy(output: 'alsa/usb', bands: [-2, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
      await play();
      expect(player.bands.first, 3);
      final track = music.currentTrack;
      await HttpOverrides.runWithHttpOverrides(
        () => music.sendNativeMusicGroup([
          CalderaNode(
            id: id,
            name: 'Fixture',
            address: address,
            meshPort: peer.port,
            companionPort: peer.port,
            expires: DateTime.now().add(const Duration(minutes: 1)),
          ),
        ], current: () => true),
        _MusicNetworkHttp(),
      );
      expect(music.sendingNativeMusicGroup, isTrue);
      player.properties['audio-out-params/samplerate'] = '44100';
      groupOutput.properties['audio-out-params/samplerate'] = '48000';
      expect(
        await music.inspectAudioOutput(),
        containsPair('audio-out-params/samplerate', '48000'),
        reason: 'Diagnostics must describe the audible speaker, not the muted capture AO',
      );
      expect(player.bands.first, -2, reason: 'Headphone correction must not enter shared PCM');
      expect(player.captureEnabled, isTrue);
      expect(music.currentTrack, same(track));
      await music.setOutputEqualizer(
        'alsa/usb',
        const MusicAudioPolicy(bands: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0], preampDb: -6),
      );
      expect(player.bands.first, -2);
      await music.leaveNativeMusicGroup();
      for (var i = 0; i < 100 && player.bands.first != 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.bands.first, 6);
      expect(player.captureEnabled, isFalse);
      expect(await music.inspectAudioOutput(), containsPair('audio-out-params/samplerate', '44100'));
      expect(music.currentTrack, same(track));
      expect(player.properties['audio-device'], 'alsa/usb');
    } finally {
      await music.leaveNativeMusicGroup();
      unawaited(socket?.close());
      await peer.close(force: true);
    }
  });
}

class _MusicNetworkHttp extends HttpOverrides {}
