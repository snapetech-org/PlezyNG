import '../media/lyrics.dart';
import '../media/media_item.dart';

enum KaraokeAssetKind { audio, instrumental, leadVocal, backingVocal, duetVocal, video, cdg, font, subtitle, original, midi, cover }
enum KaraokeRequestState { pending, ready, playing, completed, skipped, rejected }
enum KaraokeMode { sing, host, practice, battle, cooperative }

/// Relative paths are owned by an imported package, never arbitrary guest URLs.
class KaraokeAsset {
  final String path;
  final String sha256;
  final int bytes;
  final KaraokeAssetKind kind;
  final String? part;
  const KaraokeAsset({required this.path, required this.sha256, required this.bytes, required this.kind, this.part});
  Map<String, dynamic> toJson() => {'path': path, 'sha256': sha256, 'bytes': bytes, 'kind': kind.name, 'part': part};
  factory KaraokeAsset.fromJson(Map<String, dynamic> j) {
    final path = j['path'] as String;
    if (path.isEmpty || path.length > 512 || path.contains('\\') || path.startsWith('/') ||
        path.split('/').any((p) => p == '..' || p == '.' || p.isEmpty) || path.contains(':')) {
      throw const FormatException('Invalid karaoke asset path');
    }
    final hash = j['sha256'] as String;
    final bytes = j['bytes'] as int;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) || bytes < 0 || bytes > 4 * 1024 * 1024 * 1024) {
      throw const FormatException('Invalid karaoke asset identity');
    }
    return KaraokeAsset(path: path, sha256: hash, bytes: bytes,
      kind: KaraokeAssetKind.values.byName(j['kind'] as String), part: j['part'] as String?);
  }
}

class KaraokeNote {
  final int startMs, endMs;
  final double midi;
  final String part, text;
  final bool freestyle, golden;
  const KaraokeNote({required this.startMs, required this.endMs, required this.midi,
    this.part = '1', this.text = '', this.freestyle = false, this.golden = false});
  Map<String, dynamic> toJson() => {'startMs': startMs, 'endMs': endMs, 'midi': midi,
    'part': part, 'text': text, 'freestyle': freestyle, 'golden': golden};
  factory KaraokeNote.fromJson(Map<String, dynamic> j) {
    final start = j['startMs'] as int, end = j['endMs'] as int;
    final midi = (j['midi'] as num).toDouble();
    if (start < 0 || end <= start || end > 24 * 3600000 || !midi.isFinite || midi < 0 || midi > 127) {
      throw const FormatException('Invalid karaoke note');
    }
    return KaraokeNote(startMs: start, endMs: end, midi: midi, part: j['part'] as String? ?? '1',
      text: j['text'] as String? ?? '', freestyle: j['freestyle'] == true, golden: j['golden'] == true);
  }
}

class KaraokeSection {
  final String name;
  final int startMs, endMs;
  final bool instrumental;
  const KaraokeSection({required this.name, required this.startMs, required this.endMs, this.instrumental = false});
  Map<String, dynamic> toJson() => {'name': name, 'startMs': startMs, 'endMs': endMs, 'instrumental': instrumental};
  factory KaraokeSection.fromJson(Map<String, dynamic> j) {
    final start = j['startMs'] as int, end = j['endMs'] as int;
    if (start < 0 || end <= start || end > 24 * 3600000) throw const FormatException('Invalid section');
    return KaraokeSection(name: j['name'] as String, startMs: start, endMs: end, instrumental: j['instrumental'] == true);
  }
}

/// A rendition is a specific arrangement/cut, not just an album or song title.
class KaraokeTrack {
  final String id, songId, title, artist, language, producer;
  final MediaItem? media;
  final Lyrics lyrics;
  final List<KaraokeNote> notes;
  final List<KaraokeAsset> assets;
  final List<KaraokeSection> sections;
  final int durationMs, lyricOffsetMs;
  final bool chartReviewed, explicit;
  final String? providerId, license;
  final List<String> tags;
  const KaraokeTrack({required this.id, required this.songId, required this.title, this.artist = '',
    this.language = '', this.producer = '', this.media, this.lyrics = const Lyrics(synced: false, lines: []),
    this.notes = const [], this.assets = const [], this.sections = const [], this.durationMs = 0,
    this.lyricOffsetMs = 0, this.chartReviewed = false, this.explicit = false, this.providerId, this.license,
    this.tags = const []});

  bool get canScore => chartReviewed && notes.any((n) => !n.freestyle);
  bool get hasBacking => assets.any((a) => a.kind == KaraokeAssetKind.instrumental);
  bool get hasLocalAudio => assets.any((a) => a.kind == KaraokeAssetKind.audio || a.kind == KaraokeAssetKind.instrumental);
  Set<String> get parts => {...notes.map((n) => n.part), ...lyrics.lines.map((l) => l.part).whereType<String>()};
  Map<String, dynamic> toJson() => {'schema': 1, 'id': id, 'songId': songId, 'title': title, 'artist': artist,
    'language': language, 'producer': producer, 'media': media?.toJson(), 'lyrics': lyrics.toJson(),
    'notes': notes.map((n) => n.toJson()).toList(), 'assets': assets.map((a) => a.toJson()).toList(),
    'sections': sections.map((s) => s.toJson()).toList(), 'durationMs': durationMs, 'lyricOffsetMs': lyricOffsetMs,
    'chartReviewed': chartReviewed, 'explicit': explicit, 'providerId': providerId, 'license': license, 'tags': tags};
  factory KaraokeTrack.fromJson(Map<String, dynamic> j) {
    if (j['schema'] != 1) throw const FormatException('Unsupported karaoke package version');
    final id = j['id'] as String;
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) throw const FormatException('Invalid rendition ID');
    final notes = j['notes'] as List? ?? const [];
    final assets = j['assets'] as List? ?? const [];
    final rawLyrics = Map<String, dynamic>.from(j['lyrics'] as Map);
    if (notes.length > 100000 || assets.length > 256 || (rawLyrics['lines'] as List).length > 20000) {
      throw const FormatException('Karaoke package limit exceeded');
    }
    final lyrics = Lyrics.fromJson(rawLyrics);
    for (final l in lyrics.lines) {
      if (l.text.length > 16000 || (l.startMs ?? 0) < 0 || (l.endMs ?? 0) > 24 * 3600000 ||
          l.spans.length > 4096 || (l.startMs != null && l.endMs != null && l.endMs! < l.startMs!)) {
        throw const FormatException('Invalid lyric timing');
      }
      for (final s in l.spans) {
        if (s.startMs < 0 || s.startMs > 24 * 3600000 || (s.endMs != null && s.endMs! < s.startMs)) {
          throw const FormatException('Invalid lyric span');
        }
      }
    }
    return KaraokeTrack(id: id, songId: j['songId'] as String, title: j['title'] as String,
      artist: j['artist'] as String? ?? '', language: j['language'] as String? ?? '', producer: j['producer'] as String? ?? '',
      media: j['media'] == null ? null : MediaItem.fromJson(Map<String, dynamic>.from(j['media'] as Map)),
      lyrics: lyrics, notes: List.unmodifiable(notes.map((n) => KaraokeNote.fromJson(Map<String, dynamic>.from(n as Map)))),
      assets: List.unmodifiable(assets.map((a) => KaraokeAsset.fromJson(Map<String, dynamic>.from(a as Map)))),
      sections: List.unmodifiable((j['sections'] as List? ?? const []).map((s) => KaraokeSection.fromJson(Map<String, dynamic>.from(s as Map)))),
      durationMs: (j['durationMs'] as int? ?? 0).clamp(0, 24 * 3600000),
      lyricOffsetMs: (j['lyricOffsetMs'] as int? ?? 0).clamp(-600000, 600000),
      chartReviewed: j['chartReviewed'] == true, explicit: j['explicit'] == true,
      providerId: j['providerId'] as String?, license: j['license'] as String?,
      tags: List<String>.from(j['tags'] as List? ?? const []));
  }
  KaraokeTrack withLyrics(Lyrics value, {List<KaraokeNote>? chart, bool? reviewed, int? offsetMs}) {
    final j = toJson()..['lyrics'] = value.toJson();
    if (chart != null) j['notes'] = chart.map((n) => n.toJson()).toList();
    if (reviewed != null) j['chartReviewed'] = reviewed;
    if (offsetMs != null) j['lyricOffsetMs'] = offsetMs;
    return KaraokeTrack.fromJson(j);
  }
}

class KaraokeSinger {
  final String id;
  String name;
  bool absent;
  final Set<String> favorites;
  final Map<String, double> keys;
  final Map<String, double> tempos;
  final List<String> history;
  double? lowMidi, highMidi;
  KaraokeSinger({required this.id, required this.name, this.absent = false,
    Set<String>? favorites, Map<String, double>? keys, Map<String, double>? tempos, List<String>? history,
    this.lowMidi, this.highMidi}) : favorites = favorites ?? {}, keys = keys ?? {}, tempos = tempos ?? {}, history = history ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'absent': absent, 'favorites': favorites.toList(),
    'keys': keys, 'tempos': tempos, 'history': history.take(500).toList(), 'lowMidi': lowMidi, 'highMidi': highMidi};
  factory KaraokeSinger.fromJson(Map<String, dynamic> j) => KaraokeSinger(id: j['id'] as String, name: j['name'] as String,
    absent: j['absent'] == true, favorites: Set<String>.from(j['favorites'] as List? ?? const []),
    keys: (j['keys'] as Map? ?? {}).map((k,v) => MapEntry(k as String, (v as num).toDouble())),
    tempos: (j['tempos'] as Map? ?? {}).map((k,v) => MapEntry(k as String, (v as num).toDouble())),
    history: List<String>.from(j['history'] as List? ?? const []), lowMidi: (j['lowMidi'] as num?)?.toDouble(), highMidi: (j['highMidi'] as num?)?.toDouble());
}

class KaraokeRequest {
  final String id, trackId;
  final List<String> singers;
  final int createdMs;
  double key, tempo;
  KaraokeRequestState state;
  String? part;
  KaraokeRequest({required this.id, required this.trackId, required this.singers, required this.createdMs,
    this.key = 0, this.tempo = 1, this.state = KaraokeRequestState.ready, this.part});
  Map<String, dynamic> toJson() => {'id': id, 'trackId': trackId, 'singers': singers, 'createdMs': createdMs,
    'key': key, 'tempo': tempo, 'state': state.name, 'part': part};
  factory KaraokeRequest.fromJson(Map<String, dynamic> j) => KaraokeRequest(id: j['id'] as String,
    trackId: j['trackId'] as String, singers: List<String>.from(j['singers'] as List), createdMs: j['createdMs'] as int,
    key: ((j['key'] as num?)?.toDouble() ?? 0).clamp(-12,12),
    tempo: ((j['tempo'] as num?)?.toDouble() ?? 1).clamp(.5,2),
    state: KaraokeRequestState.values.byName(j['state'] as String), part: j['part'] as String?);
}
