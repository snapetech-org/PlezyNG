import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/music/music_audio_policy.dart';

class Output implements Player, AudioEqualizerCapable {
  final Map<String, String> properties = {};
  List<double>? bands;
  String devices = '[]';
  @override
  Future<String?> getProperty(String name) async => name == 'audio-device-list' ? devices : properties[name];
  @override
  Future<void> setAudioDevice(AudioDevice device) async {
    properties['audio-device'] = device.name;
  }

  bool? passthrough, compression;
  Completer<void>? normalizationGate;
  @override
  String get playerType => 'mpv';
  @override
  Future<void> setProperty(String name, String value) async {
    properties[name] = value;
  }

  @override
  Future<void> setAudioPassthrough(bool enabled) async {
    passthrough = enabled;
  }

  @override
  Future<void> setAudioNormalization(bool enabled) async {
    compression = enabled;
    await normalizationGate?.future;
  }

  @override
  Future<void> setAudioEqualizer(List<double> gains) async {
    bands = gains;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('retired source analysis cannot write gain after an asynchronous output change', () async {
    final output = Output()..normalizationGate = Completer<void>();
    var active = true;
    final apply = const MusicAudioPolicy(leveling: MusicLeveling.track).apply(
      output,
      albumContext: false,
      isCurrent: () => active,
      source: MediaSourceInfo(
        videoUrl: '',
        audioTracks: [MediaAudioTrack(id: 1, selected: true, replayGain: const MediaReplayGain(trackDb: -20))],
        subtitleTracks: const [],
        chapters: const [],
      ),
    );
    await pumpEventQueue();
    expect(output.compression, isFalse);
    active = false;
    output.normalizationGate!.complete();
    await apply;
    expect(output.properties, isNot(contains('replaygain-fallback')));
    expect(output.properties, isNot(contains('replaygain')));
  });

  test('server analysis uses selected stream and album-to-track fallback', () {
    MediaSourceInfo info(List<MediaAudioTrack> tracks) =>
        MediaSourceInfo(videoUrl: '', audioTracks: tracks, subtitleTracks: const [], chapters: const []);
    final analyzed = MediaAudioTrack(
      id: 1,
      selected: true,
      replayGain: const MediaReplayGain(trackDb: -6, albumDb: -9, trackPeak: 0.9, albumPeak: 1),
    );
    final source = info([
      analyzed,
      MediaAudioTrack(id: 2, selected: false, replayGain: const MediaReplayGain(trackDb: 20, trackPeak: 0.1)),
    ]);
    const policy = MusicAudioPolicy(leveling: MusicLeveling.automatic);
    expect(policy.replayGain(albumContext: true, source: source).fallbackDb, -9);
    expect(policy.replayGain(albumContext: false, source: source).fallbackDb, -6);
    expect(policy.replayGain(albumContext: false, source: source).mode, ReplayGainMode.track);
    final trackOnly = info([MediaAudioTrack(id: 3, selected: false, replayGain: const MediaReplayGain(trackDb: -4))]);
    expect(policy.replayGain(albumContext: true, source: trackOnly).fallbackDb, -4);
    expect(policy.replayGain(albumContext: true, source: trackOnly).mode, ReplayGainMode.album);
  });

  test('untagged fallback prevents peak clipping and unknown-peak amplification', () {
    ReplayGainSettings gain(MediaReplayGain analysis, {bool album = false}) =>
        MusicAudioPolicy(leveling: album ? MusicLeveling.album : MusicLeveling.track).replayGain(
          albumContext: false,
          source: MediaSourceInfo(
            videoUrl: '',
            audioTracks: [MediaAudioTrack(id: 1, selected: true, replayGain: analysis)],
            subtitleTracks: const [],
            chapters: const [],
          ),
        );
    expect(gain(const MediaReplayGain(trackDb: 12, trackPeak: 0.5)).fallbackDb, closeTo(6.0206, 0.0001));
    expect(gain(const MediaReplayGain(trackDb: -2, trackPeak: 2)).fallbackDb, closeTo(-6.0206, 0.0001));
    expect(gain(const MediaReplayGain(trackDb: 6)).fallbackDb, 0);
    expect(gain(const MediaReplayGain(trackDb: -6)).fallbackDb, -6);
    expect(
      gain(const MediaReplayGain(trackDb: 4, albumDb: 8, trackPeak: 0.1, albumPeak: 0.8), album: true).fallbackDb,
      closeTo(1.9382, 0.0001),
    );
    expect(
      gain(const MediaReplayGain(trackDb: 4, albumDb: -3, trackPeak: 1.8), album: true).fallbackDb,
      closeTo(-5.10545, 0.0001),
    );
  });

  test('invalid, ambiguous, absent and disabled analysis stays at zero', () {
    for (final analysis in [
      const MediaReplayGain(trackDb: double.nan),
      const MediaReplayGain(trackDb: double.infinity),
      const MediaReplayGain(trackDb: 1000),
      const MediaReplayGain(trackDb: -61),
      const MediaReplayGain(trackDb: 5, trackPeak: double.nan),
      const MediaReplayGain(trackDb: 5, trackPeak: 0),
      const MediaReplayGain(trackDb: 5, trackPeak: -1),
      const MediaReplayGain(trackDb: 5, trackPeak: double.infinity),
    ]) {
      final source = MediaSourceInfo(
        videoUrl: '',
        audioTracks: [MediaAudioTrack(id: 1, selected: true, replayGain: analysis)],
        subtitleTracks: const [],
        chapters: const [],
      );
      expect(
        const MusicAudioPolicy(
          leveling: MusicLeveling.track,
        ).replayGain(albumContext: false, source: source).fallbackDb,
        0,
      );
    }
    final tracks = [
      for (var id = 0; id < 2; id++)
        MediaAudioTrack(id: id, selected: false, replayGain: const MediaReplayGain(trackDb: -8)),
    ];
    for (final ambiguous in [tracks, tracks.map((t) => t.withSelected(true)).toList()]) {
      expect(
        const MusicAudioPolicy(leveling: MusicLeveling.track)
            .replayGain(
              albumContext: false,
              source: MediaSourceInfo(
                videoUrl: '',
                audioTracks: ambiguous,
                subtitleTracks: const [],
                chapters: const [],
              ),
            )
            .fallbackDb,
        0,
      );
    }
    expect(const MusicAudioPolicy(leveling: MusicLeveling.album).replayGain(albumContext: true).fallbackDb, 0);
    expect(const MusicAudioPolicy().replayGain(albumContext: true).mode, ReplayGainMode.off);
  });

  test('current output updates and resets server fallback when leveling is disabled', () async {
    final source = MediaSourceInfo(
      videoUrl: '',
      audioTracks: [
        MediaAudioTrack(id: 1, selected: true, replayGain: const MediaReplayGain(trackDb: -7, albumDb: -10)),
      ],
      subtitleTracks: const [],
      chapters: const [],
    );
    final output = Output();
    await const MusicAudioPolicy(leveling: MusicLeveling.album).apply(output, albumContext: true, source: source);
    expect(output.properties['replaygain-fallback'], '-10.0');
    await const MusicAudioPolicy().apply(output, albumContext: true, source: source);
    expect(output.properties['replaygain'], 'no');
    expect(double.parse(output.properties['replaygain-fallback']!), 0);
  });

  test('automatic leveling follows album context with peak protection', () async {
    final output = Output();
    const policy = MusicAudioPolicy(leveling: MusicLeveling.automatic, exclusive: true, sampleRate: 96000);
    await policy.apply(output, albumContext: true);
    expect(output.properties['replaygain'], 'album');
    expect(output.properties['replaygain-clip'], 'no');
    expect(output.properties['audio-samplerate'], '96000');
    expect(output.properties['audio-exclusive'], 'yes');
    expect(output.compression, isFalse);
    expect(output.passthrough, isFalse);
    await policy.apply(output, albumContext: false);
    expect(output.properties['replaygain'], 'track');
  });
  test('EQ headroom includes preamp and overlapping positive gains', () {
    const p = MusicAudioPolicy(preampDb: -6, bands: [3, 3, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(p.gain, closeTo(0.2511886, 0.000001));
    expect(MusicAudioPolicy.fromJson(p.toJson()).toJson(), p.toJson());
  });
  test('GraphicEQ log interpolation is bounded and invalid data is rejected', () {
    final bands = MusicAudioPolicy.parseGraphicEq('GraphicEQ: 20 -6; 20000 6');
    expect(bands, hasLength(10));
    expect(bands.first, lessThan(bands.last));
    expect(MusicAudioPolicy.parseGraphicEq('20 30; 20000 30'), everyElement(12));
    for (final input in ['20 NaN; 20000 0', '20 0; 20 1', '20 0', '20 0; -1 0']) {
      expect(() => MusicAudioPolicy.parseGraphicEq(input), throwsFormatException);
    }
  });
  test('invalid hardware and DSP configurations are rejected', () {
    for (final p in [
      const MusicAudioPolicy(sampleRate: 12345),
      const MusicAudioPolicy(preampDb: 1),
      const MusicAudioPolicy(cacheMiB: 1024),
      const MusicAudioPolicy(bands: [0, 1]),
      const MusicAudioPolicy(output: 'a\nb'),
    ]) {
      expect(p.validate, throwsArgumentError);
    }
  });
  test('an unplugged preferred output falls back to auto and returns when enumerated', () async {
    final output = Output();
    const policy = MusicAudioPolicy(output: 'alsa/usb');
    await policy.apply(output, albumContext: false);
    expect(output.properties['audio-device'], 'auto');
    output.devices = '[{"name":"alsa/usb","description":"USB DAC"}]';
    await policy.apply(output, albumContext: false);
    expect(output.properties['audio-device'], 'alsa/usb');
  });
}
