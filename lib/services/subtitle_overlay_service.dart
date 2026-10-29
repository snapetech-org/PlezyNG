import 'dart:convert';
import 'package:flutter/material.dart';

import '../mpv/mpv.dart';
import '../mpv/font_loader.dart';
import '../mpv/player/player_media_session_identity.dart';
import 'subtitle_retimer.dart';
import 'settings_service.dart';
import 'subtitle_word_timing.dart';
import 'subtitle_ruby_text.dart';
import 'subtitle_language_text.dart';
import 'subtitle_font_store.dart';
import '../widgets/subtitle_ruby_span.dart';

/// App-rendered plain text, distinct from native ASS/bitmap tracks. Each lane
/// owns an immutable source-clock index and independent presentation settings.
class SubtitleOverlayTrack {
  SubtitleOverlayTrack({required List<SubtitleCue> cues, List<SubtitleWordTiming> words = const [],
    required this.title, required this.isCurrent, Map<String, Rect> regions = const {}, this.language,
    this.profileId, this.positionToSourceMs, this.reviewed = false, Map<String, List<Rect>> avoidRegions = const {}})
      : cues = List.unmodifiable(List<SubtitleCue>.of(cues)..sort((a, b) => a.startMs.compareTo(b.startMs))),
        words = List.unmodifiable(words), regions = Map.unmodifiable(regions),
        avoidRegions = Map.unmodifiable(avoidRegions.map((key, value) => MapEntry(key, List<Rect>.unmodifiable(value)))) {
    if (cues.length > 50000 || words.length > 250000) throw ArgumentError('Overlay limit');
    final ids = <String>{};
    for (final cue in this.cues) {
      if (cue.startMs < 0 || cue.endMs <= cue.startMs || cue.text.length > 4000 || !ids.add(cue.stableId)) {
        throw const FormatException('Invalid overlay cue');
      }
    }
    bool valid(Rect r) => r.left.isFinite && r.top.isFinite && r.width.isFinite && r.height.isFinite &&
        r.left >= 0 && r.top >= 0 && r.width > 0 && r.height > 0 && r.right <= 1.001 && r.bottom <= 1.001;
    if (regions.length > cues.length || avoidRegions.length > cues.length ||
        regions.entries.any((e) => !ids.contains(e.key) || !valid(e.value)) ||
        avoidRegions.entries.any((e) => !ids.contains(e.key) || e.value.length > 12 || e.value.any((r) => !valid(r)))) {
      throw const FormatException('Invalid caption placement evidence');
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
  final String? profileId;
  /// Set only after explicit review/acceptance, never by live inference.
  final bool reviewed;
  final Map<String, List<Rect>> avoidRegions;
  final Map<String, Rect> regions;
  final bool Function() isCurrent;
  /// Live tracks retain absolute source timestamps across a moving DVR origin.
  /// Export to a fixed native/file clock needs a separate, explicit snapshot.
  final int? Function(int playerPositionMs)? positionToSourceMs;
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
  bool ruby = true;
  String writingMode = 'horizontal';
  final Map<String, List<SubtitleRubyRun>?> _rubyRuns = {};
  final Map<String, List<SubtitleLanguageRun>?> _languageRuns = {};
  bool bold = false;
  bool italic = false;
  bool avoidObjects = false;
  bool videoAnchored = false;
  double overscan = 0;
  String fontFamily = 'Bundled multilingual';
  String? get renderedFontFamily => fontFamily == 'System' ? null
      : fontFamily == 'Bundled multilingual' || SubtitleFontStore.familyPattern.hasMatch(fontFamily) &&
          !SubtitleFontStore.instance.families.contains(fontFamily) ? SubtitleFontLoader.overlayFamily : fontFamily;
  static const fallbackFonts = [SubtitleFontLoader.overlayFamily, SubtitleFontLoader.overlayHangulFamily,
    'Noto Sans', 'Noto Sans Arabic', 'Noto Sans Hebrew', 'Noto Sans CJK SC'];
  TextAlign alignment = TextAlign.center;
  Color backgroundColor = Colors.black;
  static List<String> get fonts => ['Bundled multilingual', 'System', 'Noto Sans', 'Noto Sans Arabic', 'Noto Sans Hebrew', 'Noto Sans CJK SC', 'Arial', 'Georgia', 'monospace',
    ...SubtitleFontStore.instance.families];

  Map<String, Object> appearance() => {'fontSize': fontSize, 'position': position,
    'backgroundOpacity': backgroundOpacity, 'color': color.toARGB32(), 'outline': outline.toARGB32(),
    'outlineWidth': outlineWidth, 'margin': margin, 'karaoke': karaoke, 'ruby': ruby, 'bold': bold, 'italic': italic,
    'videoAnchored': videoAnchored, 'overscan': overscan, 'writingMode': writingMode,
    'backgroundColor': backgroundColor.toARGB32(), 'fontFamily': fontFamily, 'alignment': alignment.name};

  void applyAppearance(Map<String, dynamic> value) {
    double number(String key, double fallback, double lo, double hi) {
      final n = value[key]; return n is num && n.isFinite && n >= lo && n <= hi ? n.toDouble() : fallback;
    }
    Color paint(String key, Color fallback) { final n = value[key]; return n is int && n >= 0 && n <= 0xffffffff ? Color(n) : fallback; }
    fontSize = number('fontSize', fontSize, 16, 64); position = number('position', position, .05, .95);
    backgroundOpacity = number('backgroundOpacity', backgroundOpacity, 0, 1);
    outlineWidth = number('outlineWidth', outlineWidth, 0, 5); margin = number('margin', margin, .02, .2);
    color = paint('color', color); outline = paint('outline', outline); backgroundColor = paint('backgroundColor', backgroundColor);
    final storedFamily = value['fontFamily'];
    if (storedFamily is String && (fonts.contains(storedFamily) || SubtitleFontStore.familyPattern.hasMatch(storedFamily))) fontFamily = storedFamily;
    if (const ['left', 'center', 'right', 'start', 'end'].contains(value['alignment'])) {
      alignment = TextAlign.values.byName(value['alignment'] as String);
    }
    overscan = number('overscan', overscan, 0, .15);
    if (value['videoAnchored'] is bool) videoAnchored = value['videoAnchored'] as bool;
    if (value['karaoke'] is bool) karaoke = value['karaoke'] as bool;
    if (value['ruby'] is bool) ruby = value['ruby'] as bool;
    if (value['bold'] is bool) bold = value['bold'] as bool;
    if (value['italic'] is bool) italic = value['italic'] as bool;
    if (const ['horizontal', 'vertical-rl', 'vertical-lr'].contains(value['writingMode'])) {
      writingMode = value['writingMode'] as String;
    }
  }

  void restoreAppearance(int lane) {
    if (profileId == null) return;
    try {
      final raw = SettingsService.instance.read(SettingsService.subtitleOverlayAppearanceForProfile(profileId!));
      if (raw.length > 8192) return;
      final data = jsonDecode(raw);
      if (data is Map && data['version'] == 1 && data['$lane'] is Map) applyAppearance(Map<String, dynamic>.from(data['$lane'] as Map));
    } catch (_) { /* A damaged preference never prevents caption attachment. */ }
  }

  static Future<void> _appearanceWrites = Future.value();
  Future<void> saveAppearance(int lane, {Map<String, Object>? expectedAppearance}) {
    final saved = Map<String, Object>.of(appearance());
    final next = _appearanceWrites.then((_) => _saveAppearance(lane, saved, expectedAppearance));
    _appearanceWrites = next.catchError((Object _) {});
    return next;
  }

  Future<void> _saveAppearance(int lane, Map<String, Object> saved, Map<String, Object>? expectedAppearance) async {
    if (lane < 0 || lane > 1) throw ArgumentError('Unknown caption lane');
    if (profileId == null || !isCurrent()) throw StateError('The subtitle profile changed');
    if (expectedAppearance != null) {
      final current = SubtitleOverlayTrack(cues: const [], title: '', isCurrent: isCurrent, profileId: profileId)
        ..restoreAppearance(lane);
      if (jsonEncode(current.appearance()) != jsonEncode(expectedAppearance)) {
        throw StateError('The saved appearance changed. Preview the current defaults again.');
      }
    }
    final pref = SettingsService.subtitleOverlayAppearanceForProfile(profileId!);
    Map<String, dynamic> data = {'version': 1};
    try {
      final raw = SettingsService.instance.read(pref);
      if (raw.length <= 8192) {
        final saved = jsonDecode(raw);
        if (saved is Map && saved['version'] == 1) data = {'version': 1,
          for (final key in ['0', '1']) if (saved[key] is Map) key: saved[key]};
      }
    } catch (_) {}
    data['$lane'] = saved;
    final encoded = jsonEncode(data);
    if (encoded.length > 8192) throw const FormatException('Caption preference limit');
    await SettingsService.instance.write(pref, encoded, checkCurrent: () {
      if (!isCurrent()) throw StateError('The subtitle profile changed');
    });
  }


  List<SubtitleCue> at(int positionMs) => between(positionMs, positionMs + 1, limit: 8);

  List<SubtitleCue> between(int startMs, int endMs, {int limit = 12}) {
    if (limit < 1 || limit > 64 || endMs <= startMs) return const [];
    final a = positionToSourceMs == null ? startMs : positionToSourceMs!(startMs);
    final b = positionToSourceMs == null ? endMs : positionToSourceMs!(endMs);
    if (a == null || b == null || b <= a) return const [];
    final from = a - delayMs, until = b - delayMs;
    final active = <SubtitleCue>[];
    void visit(int node, int lo, int hi) {
      if (active.length >= limit || lo >= hi || cues[lo].startMs >= until || (_ends[node] ?? 0) <= from) return;
      if (hi - lo == 1) { active.add(cues[lo]); return; }
      final mid = (lo + hi) ~/ 2;
      visit(node * 2, lo, mid); visit(node * 2 + 1, mid, hi);
    }
    visit(1, 0, cues.length);
    return active;
  }

  List<InlineSpan> spans(SubtitleCue cue, int positionMs) {
    final text = plain(cue.text);
    if (writingMode != 'horizontal') return [TextSpan(text: text)];
    if (_languageRuns.length > 128) _languageRuns.clear();
    final languages = _languageRuns.putIfAbsent(cue.stableId, () => SubtitleLanguageText.parse(cue.text));
    List<InlineSpan> slice(int start, int end, {TextStyle? style}) {
      if (languages == null) return [TextSpan(text: text.substring(start, end), style: style)];
      final result = <InlineSpan>[];
      var offset = 0;
      for (final run in languages) {
        final lo = start > offset ? start : offset, hi = end < offset + run.text.length ? end : offset + run.text.length;
        if (hi > lo) {
          final tag = run.language;
          final locale = tag == null ? null : Locale.fromSubtags(languageCode: tag.language, scriptCode: tag.script, countryCode: tag.region);
          result.add(TextSpan(text: run.text.substring(lo - offset, hi - offset), locale: locale,
            style: (style ?? const TextStyle()).copyWith(locale: locale)));
        }
        offset += run.text.length;
        if (offset >= end) break;
      }
      return result;
    }
    if (languages == null && ruby && cue.text.toLowerCase().contains('<ruby')) {
      if (_rubyRuns.length > 128) _rubyRuns.clear();
      final runs = _rubyRuns.putIfAbsent(cue.stableId, () => SubtitleRubyText.parse(cue.text));
      if (runs != null) return [for (final run in runs)
        if (run.reading == null) TextSpan(text: run.base) else SubtitleRubySpan(run.base, run.reading!)];
    }
    final sourceMs = positionToSourceMs == null ? positionMs : positionToSourceMs!(positionMs);
    final timing = _words[cue.stableId];
    if (!karaoke || timing == null) return slice(0, text.length);
    // Match the original string in order. A changed/uncertain token cannot
    // rewrite the caption or fabricate evenly-spaced lyric timing.
    final result = <InlineSpan>[];
    var offset = 0;
    for (final word in timing) {
      if (word.text.isEmpty) continue;
      final found = text.indexOf(word.text, offset);
      if (found < 0) return slice(0, text.length);
      result.addAll(slice(offset, found));
      final active = sourceMs != null && sourceMs - delayMs >= word.startMs && sourceMs - delayMs < word.endMs;
      result.addAll(slice(found, found + word.text.length, style: active
          ? const TextStyle(color: Colors.yellow, backgroundColor: Colors.black) : null));
      offset = found + word.text.length;
    }
    result.addAll(slice(offset, text.length));
    return result;
  }

  static String plain(String text) => SubtitleRubyText.plain(text);
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
  static void attach(Player player, int lane, SubtitleOverlayTrack track, {bool restoreAppearance = true}) {
    if (lane < 0 || lane > 1) throw RangeError.range(lane, 0, 1);
    final session = forPlayer(player);
    if (!session.current || !track.isCurrent()) throw StateError('Playback identity changed');
    if (restoreAppearance) track.restoreAppearance(lane);
    session.lanes[lane] = track;
    session.changed();
  }
}
