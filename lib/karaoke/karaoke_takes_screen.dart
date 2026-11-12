import '../services/file_picker_service.dart';
import '../widgets/app_icon.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart' as l10n;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../mpv/models.dart';
import '../mpv/player/player.dart';
import '../services/playback_coordinator.dart';
import '../services/music/music_playback_service.dart';
import 'karaoke_preparation.dart';
import 'karaoke_session.dart';
import 'karaoke_takes.dart';

class KaraokeTakesScreen extends StatefulWidget {
  const KaraokeTakesScreen({super.key, required this.session, required this.client});
  final KaraokeSession session;
  final KaraokePreparation client;
  @override
  State<KaraokeTakesScreen> createState() => _KaraokeTakesScreenState();
}

class _KaraokeTakesScreenState extends State<KaraokeTakesScreen> {
  late final _library = KaraokeTakes(widget.session);
  List<KaraokeTake> _takes = [];
  Player? _preview;
  // stopPreview() cancels a detached snapshot before closing playback.
  // ignore: cancel_subscriptions
  StreamSubscription<bool>? _previewCompleted;
  // ignore: cancel_subscriptions
  StreamSubscription<Duration>? _musicPreviewPosition;
  bool _busy = false;
  bool _previewUsesMusic = false;
  bool _previewMarksListened = false;
  bool _hadMusicBeforePreview = false;
  bool _finishingPreview = false;
  String? _previewMusicGlobalKey;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(
      run(() async {
        await widget.client.restore();
      }),
    );
  }

  Future<void> run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
      final takes = await _library.list();
      if (mounted) {
        setState(() => _takes = takes);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> stopPreview() async {
    PlaybackCoordinator.instance.unregisterKaraoke(stopPreview);
    final sub = _previewCompleted;
    _previewCompleted = null;
    await sub?.cancel();
    final musicPosition = _musicPreviewPosition;
    _musicPreviewPosition = null;
    await musicPosition?.cancel();
    final player = _preview;
    _preview = null;
    try {
      await player?.dispose();
    } catch (_) {}
    if (_previewUsesMusic) {
      final music = widget.session.music;
      if (music is MusicKaraokeControls) {
        try {
          await (music as MusicKaraokeControls).resetKaraokeControls();
        } catch (_) {}
      }
      try {
        await music.pause();
      } catch (_) {}
    }
    _previewUsesMusic = false;
    _previewMarksListened = false;
    _finishingPreview = false;
  }

  Future<void> stopPreviewAndRestore() async {
    final clearUnclaimedGuide = _previewUsesMusic && !_hadMusicBeforePreview;
    final guideKey = _previewMusicGlobalKey;
    try {
      await stopPreview();
    } finally {
      await widget.session.restoreMusic();
      final music = widget.session.music;
      if (clearUnclaimedGuide &&
          guideKey != null &&
          music.playContext?.title == 'Karaoke' &&
          music.currentTrack?.globalKey == guideKey) {
        await music.stop();
      }
      _previewMusicGlobalKey = null;
    }
  }

  Future<void> _beginPreview({bool registerKaraoke = true}) async {
    await stopPreview();
    await widget.session.stopPlayback();
    _hadMusicBeforePreview = widget.session.music.currentTrack != null;
    await widget.session.claimPlaybackResources();
    _previewMusicGlobalKey = null;
    _finishingPreview = false;
    if (registerKaraoke) PlaybackCoordinator.instance.registerKaraoke(stopPreview);
  }

  void _finishPreview(KaraokeTake take) {
    if (_finishingPreview) return;
    _finishingPreview = true;
    unawaited(() async {
      try {
        if (_previewMarksListened) await _library.markListened(take);
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      } finally {
        await stopPreviewAndRestore();
      }
    }());
  }

  double _takeControl(KaraokeTake take, String name, double fallback) {
    final value = take.metadata[name];
    if (value is! num || !value.isFinite) {
      if (value == null) return fallback;
      throw FormatException('Invalid take $name');
    }
    final result = value.toDouble();
    if (name == 'key' ? result.abs() > 12 : result < .5 || result > 2) {
      throw FormatException('Invalid take $name');
    }
    return result;
  }

  int _takeSourceStartMs(KaraokeTake take) {
    final value = take.metadata['sourceStartMs'];
    if (value == null) return 0;
    if (value is! int || value < 0 || value > 24 * 60 * 60 * 1000) {
      throw const FormatException('Invalid take source position');
    }
    return value;
  }

  Future<void> _applyPreviewControls(Player player, double key, double tempo) async {
    if (key == 0 && tempo == 1) return;
    if (player.playerType != 'mpv' || player is! AudioEffectsCapable) {
      throw UnsupportedError('Matching guide key and tempo require MPV');
    }
    await player.setAudioPassthrough(false);
    await (player as AudioEffectsCapable).setAudioEffects((stereoWidth: 0, spatializer: false, pitchSemitones: key));
    await player.setRate(tempo);
  }

  Future<void> play(KaraokeTake take) => run(() => _playTake(take));

  Future<void> _playTake(KaraokeTake take) async {
    try {
      await _beginPreview();
      final player = Player.audio();
      _preview = player;
      _previewMarksListened = true;
      _previewCompleted = player.streams.completed.listen((done) {
        if (done) _finishPreview(take);
      });
      await player.open(Media(take.dry.uri.toString()));
    } catch (_) {
      await stopPreviewAndRestore();
      rethrow;
    }
  }

  Future<void> playGuide(KaraokeTake take) => run(() async {
    try {
      final track = widget.session.catalog[take.metadata['renditionId']];
      if (track == null) throw StateError('The original rendition is no longer available');
      final partValue = take.metadata['part'];
      final guide = karaokeGuideAssetFor(track, part: partValue is String ? partValue : null);
      final key = _takeControl(take, 'key', 0);
      final tempo = _takeControl(take, 'tempo', 1);
      final sourceStart = _takeSourceStartMs(take);
      if (track.durationMs > 0 && sourceStart >= track.durationMs) {
        throw const FormatException('Take source position is beyond the rendition duration');
      }
      if (guide == null && track.media == null) {
        throw StateError('No aligned guide vocal or original audio is available');
      }

      await _beginPreview(registerKaraoke: guide != null || track.media == null);
      if (guide != null) {
        if ((await widget.session.packages.verify(track)).isNotEmpty) {
          throw StateError('Guide package assets are missing or corrupt');
        }
        final file = await widget.session.store.asset(track.id, guide.path);
        final player = Player.audio();
        _preview = player;
        _previewCompleted = player.streams.completed.listen((done) {
          if (done) _finishPreview(take);
        });
        await player.open(Media(file.uri.toString(), start: Duration(milliseconds: sourceStart)), play: false);
        await _applyPreviewControls(player, key, tempo);
        await player.play();
        return;
      }

      final media = track.media;
      if (media == null) throw StateError('No aligned guide vocal or original audio is available');
      final music = widget.session.music;
      _previewUsesMusic = true;
      _previewMusicGlobalKey = media.globalKey;
      music.setRepeatMode(MusicRepeatMode.off);
      await music.playFromList(
        tracks: [media],
        playContext: const MusicPlayContext(title: 'Karaoke', kind: MusicPlayContextKind.tracks),
        initialPosition: Duration(milliseconds: sourceStart),
      );
      if (music.status == MusicPlaybackStatus.error || music.currentTrack?.globalKey != media.globalKey) {
        throw StateError('Guide playback did not start');
      }
      if (key != 0 || tempo != 1) {
        if (music is! MusicKaraokeControls) {
          throw UnsupportedError('Matching guide key and tempo are unavailable in this music backend');
        }
        await (music as MusicKaraokeControls).setKaraokeControls(semitones: key, tempo: tempo);
      }
      final duration = music.duration ?? (media.durationMs == null ? null : Duration(milliseconds: media.durationMs!));
      if (duration != null && duration > Duration.zero) {
        _musicPreviewPosition = music.positionStream.listen((position) {
          if (position >= duration) _finishPreview(take);
        });
      }
      PlaybackCoordinator.instance.registerKaraoke(stopPreview);
    } catch (_) {
      await stopPreviewAndRestore();
      rethrow;
    }
  });

  bool _hasGuide(KaraokeTake take) {
    final track = widget.session.catalog[take.metadata['renditionId']];
    if (track == null) return false;
    final partValue = take.metadata['part'];
    return karaokeGuideAssetFor(track, part: partValue is String ? partValue : null) != null || track.media != null;
  }

  Future<void> produce(KaraokeTake take) async {
    var backing = .7, vocal = 1.0, echo = 0.0, gate = 0.0;
    final trim = TextEditingController(text: '0'),
        duration = TextEditingController(
          text: ((take.metadata['frames'] as int? ?? 0) * 1000 / (take.metadata['sampleRate'] as int? ?? 48000))
              .round()
              .toString(),
        );
    var includeVideo = false, lyricOverlay = true;
    final selected = <String>{};
    final candidates = _takes
        .where(
          (t) =>
              t.id != take.id &&
              t.metadata['mergeApproved'] == true &&
              t.metadata['renditionId'] == take.metadata['renditionId'] &&
              t.metadata['invitationId'] == take.metadata['invitationId'] &&
              t.metadata['key'] == take.metadata['key'] &&
              t.metadata['tempo'] == take.metadata['tempo'] &&
              (take.metadata['part'] == null || t.metadata['part'] != take.metadata['part']),
        )
        .toList();
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.t.karaokeUi.mixAndExportPrivately),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Text(l10n.t.karaokeUi.theDryVocalStaysUnchangedChooseGainsEffectsAnd),
                  Text(l10n.t.karaokeUi.backing),
                  Slider(min: 0, max: 2, value: backing, onChanged: (v) => update(() => backing = v)),
                  Text(l10n.t.karaokeUi.vocal),
                  Slider(min: 0, max: 2, value: vocal, onChanged: (v) => update(() => vocal = v)),
                  Text(l10n.t.karaokeUi.echoWet),
                  Slider(min: 0, max: .6, value: echo, onChanged: (v) => update(() => echo = v)),
                  Text(l10n.t.karaokeUi.noiseGate),
                  Slider(min: 0, max: .2, value: gate, onChanged: (v) => update(() => gate = v)),
                  TextField(
                    controller: trim,
                    decoration: InputDecoration(labelText: l10n.t.karaokeUi.trimStartMs),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: duration,
                    decoration: InputDecoration(labelText: l10n.t.karaokeUi.outputDurationMs),
                    keyboardType: TextInputType.number,
                  ),
                  for (final partner in candidates)
                    CheckboxListTile(
                      title: Text(l10n.t.karaokeUi.mixApprovedResponse(value1: (partner.id).toString())),
                      value: selected.contains(partner.id),
                      onChanged: (v) => update(() => v! ? selected.add(partner.id) : selected.remove(partner.id)),
                    ),
                  CheckboxListTile(
                    title: Text(l10n.t.karaokeUi.includeACameraVideoFileIChoose),
                    value: includeVideo,
                    onChanged: (v) => update(() => includeVideo = v!),
                  ),
                  if (includeVideo)
                    CheckboxListTile(
                      title: Text(l10n.t.karaokeUi.overlayTimedLyrics),
                      value: lyricOverlay,
                      onChanged: (v) => update(() => lyricOverlay = v!),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t.auth.quickConnectCancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t.karaokeUi.render)),
          ],
        ),
      ),
    );
    try {
      if (save != true) {
        return;
      }
      await run(() async {
        await stopPreview();
        File? camera;
        if (includeVideo) {
          final selected = await FilePickerService.instance.pickFiles(type: FileType.video);
          final path = selected?.files.single.path;
          if (path == null) {
            return;
          }
          camera = File(path);
        }
        await _library.render(
          take,
          widget.client,
          {
            'backingGain': backing,
            'vocalGain': vocal,
            'echoWet': echo,
            'gate': gate,
            'lyricOverlay': lyricOverlay,
            'trimStartMs': int.parse(trim.text),
            'durationMs': int.parse(duration.text),
          },
          camera: camera,
          partners: candidates.where((t) => selected.contains(t.id)).toList(),
        );
      });
    } finally {
      trim.dispose();
      duration.dispose();
    }
  }

  Future<void> download(KaraokeTake take) => run(() async {
    final result = await widget.client.refresh(take.metadata['renderJobId'] as String),
        dir = await widget.client.download(result);
    final file = File(p.join(dir.path, 'performance.mp4'));
    final media = await file.exists() ? file : File(p.join(dir.path, 'performance.wav'));
    final destination = await FilePickerService.instance.saveFile(fileName: p.basename(media.path));
    if (destination != null) {
      await media.copy(destination);
    }
  });
  @override
  void dispose() {
    unawaited(
      stopPreviewAndRestore().catchError((Object error) {
        widget.session.report(error);
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(l10n.t.karaokeUi.privateTakes),
      actions: [
        IconButton(
          tooltip: l10n.t.karaokeUi.stopPreview,
          onPressed: stopPreviewAndRestore,
          icon: const AppIcon(Symbols.stop_rounded),
        ),
        IconButton(
          tooltip: l10n.t.common.refresh,
          onPressed: () => run(() async {}),
          icon: const AppIcon(Symbols.refresh_rounded),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => run(() async {
                      final pick = await FilePickerService.instance.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['plezyduet'],
                      );
                      final path = pick?.files.single.path;
                      if (path != null) {
                        await _library.acceptInvitation(path);
                      }
                    }),
              child: Text(l10n.t.karaokeUi.acceptDuetInvitation),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => run(() async {
                      final pick = await FilePickerService.instance.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['plezytake'],
                      );
                      final path = pick?.files.single.path;
                      if (path != null) {
                        await _library.importResponse(path);
                      }
                    }),
              child: Text(l10n.t.karaokeUi.importDuetResponse),
            ),
          ],
        ),
        if (widget.session.duetInvitation case final invitation?)
          Text(
            l10n.t.karaokeUi.useTheAssignedPartAndKeepTheBackingRendition(
              value1: (invitation['owner'] == true ? 'Host invitation' : 'Accepted invitation').toString(),
              value2: (invitation['title']).toString(),
            ),
          ),
        Text(l10n.t.karaokeUi.recordingsRemainPrivateExportCreatesAFileYouCan),
        for (final take in _takes)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.session.catalog[take.metadata['renditionId']]?.title ?? take.id,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    l10n.t.karaokeUi.keyTempo_f457ce13(
                      value1: (take.metadata['created']).toString(),
                      value2: (take.metadata['listened'] == true ? 'Listened' : 'Unreviewed').toString(),
                      value3: (take.metadata['key']).toString(),
                      value4: (take.metadata['tempo']).toString(),
                      value5: (take.complete ? 'Saved' : 'Interrupted').toString(),
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      if (!take.complete)
                        TextButton(
                          onPressed: _busy ? null : () => run(() => _library.recover(take)),
                          child: Text(l10n.t.karaokeUi.recoverRecording),
                        ),
                      if (take.complete &&
                          take.metadata['invitationId'] == null &&
                          widget.session.duetInvitation?['owner'] == true &&
                          widget.session.duetInvitation?['renditionId'] == take.metadata['renditionId'])
                        TextButton(
                          onPressed: _busy ? null : () => run(() => _library.linkToInvitation(take)),
                          child: Text(l10n.t.karaokeUi.linkThisTakeToTheDuetInvitation),
                        ),
                      TextButton(
                        onPressed: _busy || !take.complete ? null : () => play(take),
                        child: Text(l10n.t.karaokeUi.listenToDryTake),
                      ),
                      if (take.complete && _hasGuide(take))
                        TextButton(
                          onPressed: _busy ? null : () => playGuide(take),
                          child: Text(l10n.t.karaokeUi.listenToGuideTrack),
                        ),
                      TextButton(
                        onPressed: _busy || !take.complete ? null : () => produce(take),
                        child: Text(l10n.t.karaokeUi.mixExportAudioOrVideo),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => run(() async {
                                final file = await FilePickerService.instance.saveFile(
                                  fileName: '${take.id}.plezytake',
                                );
                                if (file != null) {
                                  await _library.export(take, file);
                                }
                              }),
                        child: Text(l10n.t.karaokeUi.exportPortableTake),
                      ),
                      if (take.metadata['renderJobId'] != null)
                        TextButton(
                          onPressed: _busy ? null : () => download(take),
                          child: Text(l10n.t.karaokeUi.downloadCompletedRender),
                        ),
                      if (take.metadata['invitationId'] != null && take.metadata['mergeApproved'] != true)
                        TextButton(
                          onPressed: _busy ? null : () => run(() => _library.approveMerge(take)),
                          child: Text(l10n.t.karaokeUi.approveDuetMergeAfterListening),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
