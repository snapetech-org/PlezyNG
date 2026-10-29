import 'package:flutter/material.dart';

import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

/// App-rendered plain text, distinct from native ASS/bitmap tracks. Each lane
/// owns an immutable source-clock index and independent presentation settings.
class SubtitleOverlayTrack {
  SubtitleOverlayTrack({required List<SubtitleCue> cues, this.words = const [],
    required this.title, required this.isCurrent, this.regions = const {}, this.language})
      : cues = List.of(cues)..sort((a, b) => a.startMs.compareTo(b.startMs)) {
    if (cues.length > 50000 || words.length > 250000) throw ArgumentError('Overlay limit');
    for (final cue in this.cues) {
      if (cue.startMs < 0 || cue.endMs <= cue.startMs || cue.text.length > 4000) {
        throw const FormatException('Invalid overlay cue');
      }
    }
    if (this.cues.isNotEmpty) _build(1, 0, this.cues.length);
    for (final word in words) {
      if (word.cueId != null) _words.putIfAbsent(word.cueId!, () => []).add(word);
    }
  }
  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> words;
  final String title;
  final String? language;
  final Map<String, Rect> regions;
  final bool Function() isCurrent;
  final Map<int, int> _ends = {};
  int _build(int node, int lo, int hi) {
    if (hi - lo == 1) return _ends[node] = cues[lo].endMs;
    final mid = (lo + hi) ~/ 2;
    final left = _build(node * 2, lo, mid), right = _build(node * 2 + 1, mid, hi);
    return _ends[node] = left > right ? left : right;
  }
  final Map<String, List<SubtitleWordTiming>> _words = {};
  double fontSize = 30;
  double position = .90;
  double backgroundOpacity = .75;
  Color color = Colors.white;
  Color outline = Colors.black;
  double outlineWidth = 2;
  double margin = .04;
  int delayMs = 0;
  bool karaoke = false;
  bool bold = false;
  bool italic = false;

  List<SubtitleCue> at(int positionMs) {
    final time = positionMs - delayMs;
    final active = <SubtitleCue>[];
    void visit(int node, int lo, int hi) {
      if (active.length >= 8 || lo >= hi || cues[lo].startMs > time || (_ends[node] ?? 0) <= time) return;
      if (hi - lo == 1) { active.add(cues[lo]); return; }
      final mid = (lo + hi) ~/ 2;
      visit(node * 2, lo, mid);
      visit(node * 2 + 1, mid, hi);
    }
    visit(1, 0, cues.length);
    return active;
  }

  List<InlineSpan> spans(SubtitleCue cue, int positionMs) {
    final text = plain(cue.text);
    final timing = _words[cue.stableId];
    if (!karaoke || timing == null) return [TextSpan(text: text)];
    // Match the original string in order. A changed/uncertain token cannot
    // rewrite the caption or fabricate evenly-spaced lyric timing.
    final result = <InlineSpan>[];
    var offset = 0;
    for (final word in timing) {
      if (word.text.isEmpty) continue;
      final found = text.indexOf(word.text, offset);
      if (found < 0) return [TextSpan(text: text)];
      result.add(TextSpan(text: text.substring(offset, found)));
      final active = positionMs - delayMs >= word.startMs && positionMs - delayMs < word.endMs;
      result.add(TextSpan(text: word.text, style: active
          ? const TextStyle(color: Colors.yellow, backgroundColor: Colors.black) : null));
      offset = found + word.text.length;
    }
    result.add(TextSpan(text: text.substring(offset)));
    return result;
  }

  static String plain(String text) => text.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '')
      .replaceAll(r'\N', '\n').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
}

class SubtitleOverlaySession extends ChangeNotifier {
  SubtitleOverlaySession(this.player)
      : generation = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null,
        audio = player.state.track.audio?.id;
  final Player player;
  final int? generation;
  final String? audio;
  final List<SubtitleOverlayTrack?> lanes = [null, null];
  Rect? coverRegion;
  bool get current => !player.disposed &&
      (generation == null || (player as PlayerMediaSessionIdentity).mediaSessionGeneration == generation) &&
      audio == player.state.track.audio?.id;
  void changed() => notifyListeners();
}

abstract final class SubtitleOverlayService {
  // Expando ownership lets disposed/replaced players be reclaimed. There is
  // no process-global active overlay that could bleed into another pane.
  static final Expando<SubtitleOverlaySession> _sessions = Expando();
  static SubtitleOverlaySession forPlayer(Player player) {
    final old = _sessions[player];
    if (old != null && old.current) return old;
    return _sessions[player] = SubtitleOverlaySession(player);
  }
  static void attach(Player player, int lane, SubtitleOverlayTrack track) {
    final session = forPlayer(player);
    if (!session.current || !track.isCurrent()) throw StateError('Playback identity changed');
    session.lanes[lane] = track;
    session.changed();
  }
}
