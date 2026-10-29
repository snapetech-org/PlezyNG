import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../mpv/mpv.dart';
import '../../services/subtitle_cloud_sync.dart';
import '../../services/subtitle_caption_relay.dart';
import '../../services/subtitle_overlay_service.dart';
import '../../services/subtitle_retimer.dart';
import '../../services/subtitle_revision_service.dart';
import '../../services/subtitle_word_timing.dart';
import '../../sources/source_controller.dart';
import '../../sources/sync/sync_document.dart';
import '../../sources/sync/sync_store.dart';

/// The room, selected copy and timeline admitted by WatchTogetherProvider.
/// The room scope is portable. The local token also binds player/audio/offset.
class WatchSubtitleContext {
  const WatchSubtitleContext({required this.scope, required this.localToken,
    required this.profileId, required this.player, required this.offsetMs, required this.host});
  final String scope, localToken, profileId;
  final Player player;
  final int offsetMs;
  final bool host;
}

/// Opt-in automatic asset exchange through an encrypted cloud folder or an
/// expiring companion channel. It does not alter OWP or the playback clock.
/// A group pairing key grants read/write access; it is not a host signature.
class WatchSubtitleSync extends ChangeNotifier {
  Timer? _timer;
  SourceController? _sources;
  WatchSubtitleContext? _context;
  WatchSubtitleContext? Function()? _readContext;
  SubtitleCloudSync? _sync;
  SubtitleCaptionRelayStore? _relayStore;
  SubtitleOverlaySession? _session;
  SubtitleOverlayTrack? _installed;
  SubtitleOverlayTrack? _previous;
  SubtitleOverlayTrack? _ownedLane;
  int _generation = 0, _lane = 0, _failures = 0;
  bool _publishing = false, _automatic = false, _busy = false, _disposed = false;
  String? _published, _applied;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  String status = 'Caption sharing is off';
  List<SubtitleSyncChoice> choices = const [];
  final Map<String, SubtitleRevision> previews = {};
  bool get running => _sync != null;
  bool get busy => _busy;
  bool get publishing => _publishing;
  bool get automatic => _automatic;
  int get lane => _lane;
  String? get relayChannel => _relayStore?.invite.channel;
  SubtitleCaptionRelayInvite? get relayInvite => _relayStore?.invite;

  bool _current(int generation) {
    if (_disposed || generation != _generation || _context == null || _session?.current != true) return false;
    final now = _readContext?.call(), initial = _context!;
    return now != null && now.scope == initial.scope && now.localToken == initial.localToken &&
        identical(now.player, initial.player) && now.profileId == initial.profileId && now.offsetMs == initial.offsetMs;
  }
  void roomChanged() {
    if (running && _relayStore?.invite.expired == true) { stop(reason: 'The companion caption channel expired'); return; }
    if (running && !_current(_generation)) stop(reason: 'Caption sharing stopped because the room, copy, audio or offset changed');
  }

  Future<void> start({required SourceController sources, required WatchSubtitleContext? Function() context,
    required String code, required int lane, required bool publish, required bool automatic,
    SubtitleCaptionRelayInvite? relay}) async {
    stop();
    if (lane < 0 || lane > 1) throw ArgumentError('Choose one of the two caption lanes');
    final initial = context();
    if (initial == null || publish && !initial.host) throw StateError('Join room playback before starting caption sharing');
    final generation = ++_generation;
    await sources.ready;
    if (generation != _generation || _disposed) return;
    final config = sources.syncConfig;
    if (sources.profileId != initial.profileId) throw StateError('The active profile changed.');
    if (relay == null && config == null) throw StateError('Configure a shared cloud folder or choose a companion caption channel.');
    if (relay != null && (relay.expired || relay.scope != initial.scope)) throw StateError('This caption code belongs to another room, host, media selection or room epoch.');
    final sourceGeneration = sources.generation;
    // Domain-separated key for this room epoch, host and canonical descriptor.
    // Sharing a code across two rooms cannot expose either room's namespace.
    final derived = base64UrlEncode(Hmac(sha256, SyncCipher.decodeCode(relay?.key ?? code)).convert(
      utf8.encode('plezyng.watch-captions.v1:${initial.scope}')).bytes).replaceAll('=', '');
    _sources = sources; _context = initial; _readContext = context;
    _lane = lane; _publishing = publish; _automatic = automatic;
    _session = SubtitleOverlayService.forPlayer(initial.player);
    _ownedLane = _session!.lanes[lane]; _previous = _ownedLane;
    void check() {
      sources.requireSession(sourceGeneration);
      final active = sources.syncConfig;
      if (!_current(generation) || relay?.expired == true ||
          relay == null && (active?.sourceId != config?.sourceId || active?.folder != config?.folder)) {
        throw StateError('The room caption session changed');
      }
    }
    try {
      check();
      final SyncStore transport;
      if (relay != null) {
        transport = _relayStore = SubtitleCaptionRelayStore(relay, check);
      } else {
        final cloud = config!;
        final adapter = sources.adapter(cloud.sourceId);
        if (!ProviderSyncStore.supports(adapter.source.kind)) throw StateError('This cloud source does not support caption sharing');
        transport = ProviderSyncStore(adapter, folder: cloud.folder, check: check);
      }
      _sync = SubtitleCloudSync(repository: sources.repository,
        identity: SubtitleRevisionIdentity(profileId: initial.profileId, serverId: 'watch-caption-room',
          ratingKey: initial.scope, mediaIndex: 0),
        store: transport, code: derived, check: check);
      sources.addListener(_sourceChanged);
      _session!.addListener(_laneChanged);
      _next = DateTime.fromMillisecondsSinceEpoch(0);
      status = publish ? 'Sharing reviewed captions in the room clock' : 'Checking for shared room captions';
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        roomChanged();
        if (running && !_busy && !DateTime.now().isBefore(_next)) unawaited(_poll(generation));
      });
      _notify();
      await _poll(generation);
    } catch (_) { stop(); rethrow; }
  }
  void _sourceChanged() {
    if (!running) return;
    try { _sync!.check(); } catch (_) { stop(reason: 'Caption sharing stopped because its transport, expiry or profile changed'); }
  }
  void _laneChanged() {
    if (!running || _publishing) return;
    if (!identical(_session!.lanes[_lane], _ownedLane)) stop(reason: 'Caption sharing stopped after a local lane change');
  }

  SubtitleRevision _inRoomClock(SubtitleOverlayTrack track) {
    if (!track.reviewed || track.positionToSourceMs != null || !track.isCurrent() ||
        track.profileId != _context!.profileId) throw StateError('Select a reviewed, fixed-timeline app caption lane');
    final revision = SubtitleRevision(id: '0_0', createdAt: DateTime.utc(2000), operation: 'Room captions',
      languageCode: track.language, cues: track.cues, wordTimings: track.words, onItemTimeline: true);
    return _shift(revision, track.delayMs - _context!.offsetMs);
  }
  static SubtitleRevision _shift(SubtitleRevision revision, int offset) {
    if (!revision.onItemTimeline) throw const FormatException('Room captions require the item clock');
    final cues = <SubtitleCue>[];
    for (final cue in revision.cues) {
      final start = cue.startMs + offset, end = cue.endMs + offset;
      if (end <= 0) continue;
      if (end > SubtitleRetimer.maximumTimeMs) throw const FormatException('Room caption clock exceeds the supported duration');
      cues.add(SubtitleCue(index: cues.length + 1, startMs: start < 0 ? 0 : start, endMs: end,
        text: cue.text, cueId: cue.stableId));
    }
    if (cues.isEmpty) throw const FormatException('No captions fall within this copy');
    final byId = {for (final cue in cues) cue.stableId: cue};
    final words = <SubtitleWordTiming>[];
    for (final word in revision.wordTimings) {
      final cue = byId[word.cueId];
      final start = word.startMs + offset, end = word.endMs + offset;
      if (cue == null || start < cue.startMs || end > cue.endMs) continue;
      words.add(SubtitleWordTiming(startMs: start, endMs: end, text: word.text, confidence: word.confidence,
        unit: word.unit, cueIndex: cue.index, cueId: cue.stableId));
    }
    return SubtitleRevision(id: '0_0', createdAt: DateTime.utc(2000), operation: 'Room captions',
      languageCode: revision.languageCode, cues: cues, wordTimings: words, onItemTimeline: true);
  }

  Future<void> _poll(int generation) async {
    if (_busy || !_current(generation) || _sync == null) return;
    _busy = true; _notify();
    try {
      SubtitleRevision? publish;
      String? digest;
      if (_publishing) {
        final track = _session!.lanes[_lane];
        if (track == null) throw StateError('No reviewed caption lane is selected');
        publish = _inRoomClock(track);
        digest = sha256.convert(utf8.encode(canonicalSyncJson(publish.toJson()))).toString();
        if (digest == _published) publish = null;
      }
      final next = await _sync!.synchronize(publish: publish);
      if (!_current(generation)) return;
      if (digest != null) _published = digest;
      choices = List.unmodifiable(next);
      previews.removeWhere((key, _) => !choices.any((choice) => choice.digest == key));
      if (!_publishing && choices.length == 1 && _automatic && choices.single.digest != _applied) {
        final choice = choices.single;
        final revision = await _sync!.download(choice);
        if (!_current(generation)) return;
        previews[choice.digest] = revision;
        _apply(choice, revision);
      }
      status = choices.length > 1 ? 'Concurrent caption versions need an explicit local choice'
          : _publishing ? 'Reviewed room captions shared' : choices.isEmpty ? 'Waiting for reviewed room captions'
          : _automatic ? 'Shared captions active; your appearance stays local' : 'Shared captions are available to preview';
      _failures = 0;
    } catch (error) {
      if (!_current(generation)) { if (generation == _generation) stop(); return; }
      _failures = (_failures + 1).clamp(1, 4).toInt();
      status = error is StateError ? error.message.toString() : 'Room caption transfer failed; retrying with bounded backoff';
    } finally {
      if (generation == _generation) {
        _busy = false;
        _next = DateTime.now().add(Duration(seconds: 30 * (1 << _failures)));
        _notify();
      }
    }
  }

  Future<void> preview(SubtitleSyncChoice choice) async {
    if (_busy || !running || !choices.any((c) => c.digest == choice.digest)) return;
    final generation = _generation;
    _busy = true; _notify();
    try {
      final revision = await _sync!.download(choice);
      if (_current(generation)) previews[choice.digest] = revision;
    } finally { if (generation == _generation) { _busy = false; _notify(); } }
  }
  void accept(SubtitleSyncChoice choice) {
    final revision = previews[choice.digest];
    if (_publishing || _busy || revision == null || !_current(_generation) ||
        !choices.any((c) => c.digest == choice.digest)) throw StateError('Preview the current shared revision first');
    _apply(choice, revision);
    status = 'Selected shared captions applied locally; other viewers keep their choices'; _notify();
  }
  void _apply(SubtitleSyncChoice choice, SubtitleRevision revision) {
    if (!identical(_session!.lanes[_lane], _ownedLane)) throw StateError('The viewer changed this caption lane');
    final local = _shift(revision, _context!.offsetMs), generation = _generation;
    final track = SubtitleOverlayTrack(cues: local.cues, words: local.wordTimings,
      title: 'Watch Together captions', profileId: _context!.profileId, language: local.languageCode,
      reviewed: true, isCurrent: () => _current(generation));
    final prior = _ownedLane;
    if (prior != null) track.applyAppearance(prior.appearance());
    // A prior unrelated asset's delay is not reused. Corrections the viewer
    // made to this room lane remain local across subsequent room revisions.
    if (_installed != null && identical(prior, _installed)) track.delayMs = prior!.delayMs;
    _installed = track; _ownedLane = track; _applied = choice.digest;
    SubtitleOverlayService.attach(_context!.player, _lane, track, restoreAppearance: prior == null);
  }

  void stop({String reason = 'Caption sharing is off'}) {
    ++_generation; _timer?.cancel(); _timer = null;
    _relayStore?.close(); _relayStore = null;
    _sources?.removeListener(_sourceChanged);
    _session?.removeListener(_laneChanged);
    if (_session?.current == true && _installed != null && identical(_session!.lanes[_lane], _installed)) {
      bool previousCurrent;
      try { previousCurrent = _previous?.isCurrent() == true; } catch (_) { previousCurrent = false; }
      _session!.lanes[_lane] = previousCurrent ? _previous : null;
      _session!.changed();
    }
    _sync = null; _sources = null; _context = null; _readContext = null; _session = null;
    _installed = null; _previous = null; _ownedLane = null; _published = null; _applied = null;
    choices = const []; previews.clear(); _busy = false; _failures = 0; status = reason;
    _notify();
  }
  void _notify() { if (!_disposed) notifyListeners(); }
  @override
  void dispose() { _disposed = true; stop(); super.dispose(); }
}
