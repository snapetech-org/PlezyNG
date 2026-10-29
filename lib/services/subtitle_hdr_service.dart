import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';

enum SubtitleHdrChannel {
  text('sub-hdr-peak'),
  bitmap('image-subs-hdr-peak');

  const SubtitleHdrChannel(this.option);
  final String option;
}

/// Controls the running gpu-next output only. A readable option is required;
/// neither a configured VO list nor HDR input metadata proves output support.
/// Options belong to the player, so these are explicitly session-only settings.
class SubtitleHdrSession {
  SubtitleHdrSession._(this.player, this.isCurrent)
      : _generation = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;

  static final Expando<SubtitleHdrSession> _owners = Expando();
  final Player player;
  final bool Function() isCurrent;
  final int? _generation;
  final Map<SubtitleHdrChannel, String> _original = {};
  final Map<SubtitleHdrChannel, String> _values = {};
  bool _closed = false, _busy = false;

  Iterable<SubtitleHdrChannel> get channels => _values.keys;
  String value(SubtitleHdrChannel channel) => _values[channel]!;
  String original(SubtitleHdrChannel channel) => _original[channel]!;

  static Future<SubtitleHdrSession> open(Player player, bool Function() isCurrent) async {
    if (player.playerType != 'mpv' || player.disposed || _owners[player] != null) {
      throw StateError('Native HDR controls are unavailable for this player.');
    }
    final session = SubtitleHdrSession._(player, isCurrent);
    _owners[player] = session;
    try {
      await session._checkOutput();
      for (final channel in SubtitleHdrChannel.values) {
        String? value;
        try { value = await player.getProperty('options/${channel.option}'); } catch (_) {}
        session._checkCurrent();
        if (value != null && value.isNotEmpty && value.length <= 80) {
          session._original[channel] = value;
          session._values[channel] = value;
        }
      }
      await session._checkOutput();
      if (session._values.isEmpty) throw StateError('This MPV package exposes no native HDR caption options.');
      return session;
    } catch (_) {
      session.close();
      rethrow;
    }
  }

  void _checkCurrent() {
    final source = player;
    if (_closed || source.disposed || !identical(_owners[source], this) || !isCurrent() ||
        (_generation != null && (source is! PlayerMediaSessionIdentity || source.mediaSessionGeneration != _generation))) {
      throw StateError('Playback changed. Reopen HDR controls for the current player.');
    }
  }

  Future<void> _checkOutput() async {
    _checkCurrent();
    final output = await player.getProperty('current-vo');
    _checkCurrent();
    if (output != 'gpu-next') throw StateError('Native HDR caption control requires an active MPV gpu-next output.');
  }

  static bool _equivalent(String? a, String b) {
    if (a == b) return true;
    final x = double.tryParse(a ?? ''), y = double.tryParse(b);
    return x != null && y != null && x.isFinite && y.isFinite && (x - y).abs() < .001;
  }

  Future<void> apply(SubtitleHdrChannel channel, String value, {bool restore = false}) async {
    if (_busy || !_values.containsKey(channel)) throw StateError('HDR control is busy or unavailable.');
    final requested = restore ? original(channel) : value.trim();
    if (!restore) {
      final nits = double.tryParse(requested);
      if (requested != 'sdr' && !(channel == SubtitleHdrChannel.bitmap && requested == 'video') &&
          (nits == null || !nits.isFinite || nits < 10 || nits > 10000)) {
        throw const FormatException('Use 10–10000 nits, sdr, or video for bitmap subtitles.');
      }
    }
    _busy = true;
    try {
      await _checkOutput();
      final before = await player.getProperty('options/${channel.option}');
      _checkCurrent();
      if (!_equivalent(before, this.value(channel))) {
        throw StateError('Another control changed this value. Close and reopen before applying.');
      }
      await _checkOutput();
      await player.setProperty('options/${channel.option}', requested);
      _checkCurrent();
      final accepted = await player.getProperty('options/${channel.option}');
      await _checkOutput();
      if (accepted != null && accepted.isNotEmpty && accepted.length <= 80) _values[channel] = accepted;
      if (!_equivalent(accepted, requested)) {
        throw StateError('MPV did not confirm the requested value. The current value is shown.');
      }
    } finally { _busy = false; }
  }

  // Closing keeps deliberate edits for this player lifetime. Restoration is an
  // explicit per-option action and refuses to overwrite another owner's edit.
  void close() {
    _closed = true;
    if (identical(_owners[player], this)) _owners[player] = null;
  }
}
