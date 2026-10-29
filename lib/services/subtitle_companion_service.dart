import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'credential_key_store.dart';
import 'settings_service.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

final class SubtitleCompanionResult {
  const SubtitleCompanionResult({required this.cues, required this.wordTimings, required this.language,
      required this.warnings, required this.runtimeDevice, required this.cpuFallback, this.images = const [], this.sourceCues = const [], this.alternatives = const {}, this.regions = const {}, this.artifacts = const []});
  final List<SubtitleCue> cues;
  final List<SubtitleWordTiming> wordTimings;
  final String language;
  final List<String> warnings;
  final String runtimeDevice;
  final bool cpuFallback;
  final List<SubtitleCompanionImage> images;
  final List<SubtitleCue> sourceCues;
  final Map<String, String> alternatives;
  final Map<String, Rect> regions;
  final List<SubtitleCompanionArtifact> artifacts;
}

final class SubtitleCompanionArtifact {
  const SubtitleCompanionArtifact(this.name, this.digest, this.bytes, this.mime);
  final String name, digest, mime;
  final int bytes;
}

final class SubtitleCompanionImage {
  const SubtitleCompanionImage({required this.cueId, required this.digest, required this.bytes, required this.width,
    required this.height, required this.x, required this.y, required this.forced, required this.confidence,
    required this.requiresReview});
  final String cueId, digest;
  final int bytes, width, height, x, y;
  final bool forced, requiresReview;
  final double confidence;
  Map<String, Object> toJson() => {'cueId': cueId, 'sha256': digest, 'bytes': bytes, 'width': width, 'height': height,
    'x': x, 'y': y, 'forced': forced, 'confidence': confidence, 'requiresReview': requiresReview};
}

/// Explicitly paired processing host. Media access consists only of a chosen
/// upload; player URLs, headers, refresh tokens, and credentials are never sent.
final class SubtitleCompanionService {
  SubtitleCompanionService._(this.endpoint, this._token, this.scope);
  final Uri endpoint;
  final String _token;
  final String scope;
  final Set<http.Client> _requests = {};
  bool _closed = false;
  static final _digest = RegExp(r'^[0-9a-f]{64}$');
  static final _id = RegExp(r'^[0-9a-f]{32}$');
  static const maximumInputBytes = 1024 * 1024 * 1024;
  static const textTasks = {'translate', 'translate_model', 'script_convert', 'reading', 'dubbing'};
  static final Map<String, (Uri, String)> _sessionPairings = {};

  static String _scope(String profileId) => sha256.convert(utf8.encode(profileId)).toString();
  static String _key(String profileId) => 'subtitle_companion.v1.${_scope(profileId)}';

  static Uri validateEndpoint(String input) {
    final uri = Uri.parse(input.trim());
    final loopback = const {'127.0.0.1', '::1', 'localhost'}.contains(uri.host);
    if (!uri.hasAuthority || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        uri.path != '' && uri.path != '/' || (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback))) {
      throw const FormatException('Use an HTTPS host and port, or HTTP on localhost. Do not include credentials, paths, or query parameters.');
    }
    return uri.replace(path: '');
  }

  static Future<void> configure(String profileId, String endpoint, String token, {bool remember = true}) async {
    final uri = validateEndpoint(endpoint);
    if (token.length < 32 || token.length > 256 || !RegExp(r'^[\x21-\x7e]+$').hasMatch(token)) {
      throw const FormatException('Use the host’s 32–256 character pairing token.');
    }
    final key = _key(profileId);
    if (!remember) {
      final settings = await SettingsService.getInstance();
      if (settings.prefs.containsKey(key)) {
        await CredentialKeyStore.write(key, '');
        await settings.prefs.remove(key);
      }
      _sessionPairings[key] = (uri, token);
      return;
    }
    // A failed OS credential write never falls back to plaintext preferences.
    await CredentialKeyStore.write(key, token);
    final settings = await SettingsService.getInstance();
    await settings.prefs.setString(key, uri.toString());
    _sessionPairings.remove(key);
  }

  static Future<SubtitleCompanionService?> load(String profileId) async {
    final key = _key(profileId);
    final session = _sessionPairings[key];
    if (session != null) return SubtitleCompanionService._(session.$1, session.$2, _scope(profileId));
    final settings = await SettingsService.getInstance();
    final url = settings.prefs.getString(key);
    if (url == null) return null;
    final token = await CredentialKeyStore.read(key);
    if (token == null || token.isEmpty) return null;
    return SubtitleCompanionService._(validateEndpoint(url), token, _scope(profileId));
  }

  static Future<void> forget(String profileId) async {
    final key = _key(profileId);
    _sessionPairings.remove(key);
    final settings = await SettingsService.getInstance();
    final persisted = settings.prefs.containsKey(key);
    await settings.prefs.remove(key);
    if (persisted) await CredentialKeyStore.write(key, '');
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer $_token', 'X-Plezy-Scope': scope};

  Future<Map<String, dynamic>> _request(String method, String route, {Object? body, int bound = 65536}) async {
    if (_closed) throw StateError('Companion connection is closed.');
    final client = http.Client();
    _requests.add(client);
    try {
      final request = http.Request(method, endpoint.replace(path: route))..followRedirects = false;
      request.headers.addAll(_headers);
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.bodyBytes = utf8.encode(jsonEncode(body));
        if (request.bodyBytes.length > 5 * 1024 * 1024) throw const FormatException('Companion request exceeds 5 MiB.');
      }
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      return await _decode(response, bound);
    } finally { _requests.remove(client); client.close(); }
  }

  static Future<Map<String, dynamic>> _decode(http.StreamedResponse response, int bound) async {
    if ((response.contentLength ?? 0) > bound) throw const FormatException('Companion response exceeds the size bound.');
    final bytes = <int>[];
    await for (final block in response.stream.timeout(const Duration(seconds: 30))) {
      if (bytes.length + block.length > bound) throw const FormatException('Companion response exceeds the size bound.');
      bytes.addAll(block);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid companion response.');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded['error'];
      throw StateError(code is String && RegExp(r'^[a-z_]{1,80}$').hasMatch(code)
          ? 'Companion: ${code.replaceAll('_', ' ')}' : 'The companion refused this request.');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> capabilities() async {
    final result = await _request('GET', '/v1/capabilities');
    if (result['version'] != 1 || result['tasks'] is! List) throw const FormatException('Unsupported companion protocol.');
    return result;
  }

  Future<List<Map<String, dynamic>>> jobs() async {
    final response = await _request('GET', '/v1/jobs');
    final jobs = response['jobs'];
    if (jobs is! List || jobs.length > 100) throw const FormatException('Invalid companion job list.');
    return jobs.map((job) => Map<String, dynamic>.from(job as Map)).toList(growable: false);
  }

  String _route(String job, [String? action]) {
    if (!_id.hasMatch(job)) throw const FormatException('Invalid companion job ID.');
    return '/v1/jobs/$job${action == null ? '' : '/$action'}';
  }

  Future<Map<String, dynamic>> job(String id) => _request('GET', _route(id));
  Future<void> pause(String id) async { await _request('POST', _route(id, 'pause')); }
  Future<void> cancel(String id) async { await _request('POST', _route(id, 'cancel')); }
  Future<void> resume(String id) async { await _request('POST', _route(id, 'start')); }
  Future<void> delete(String id) async { await _request('DELETE', _route(id)); }

  Future<void> cancelAndClose(String? id) async {
    close();
    if (id == null) return;
    final connection = SubtitleCompanionService._(endpoint, _token, scope);
    try { await connection.cancel(id); } finally { connection.close(); }
  }

  Future<String> submit({required String task, required String identityKey, String? mediaPath,
    List<SubtitleCue> cues = const [], String? language, String? targetLanguage,
    bool translateToEnglish = false, bool preprocess = false, int audioTrack = 0, int subtitleTrack = 0,
    int finalBitmapDurationMs = 2000, double duckRatio = .25, String? voiceFingerprint,
    String translationMode = 'faithful', String scriptConversion = 's2t', String readingMode = 'hiragana',
    String? translationProviderFingerprint, String? visionProviderFingerprint, Map<String, String> glossary = const {},
    List<double> crop = const [0, 0.65, 1, 0.35],
    void Function(String jobId)? onCreated, void Function(int sent, int total)? onUpload,
  }) async {
    if (!_digest.hasMatch(identityKey)) throw const FormatException('A stable item identity is required.');
    final caps = await capabilities();
    if (!(caps['tasks'] as List).contains(task)) throw UnsupportedError('The companion has not installed the $task backend.');
    final input = mediaPath == null ? null : File(mediaPath);
    final length = input == null ? 0 : await input.length();
    if (length > maximumInputBytes || (!textTasks.contains(task) && length <= 0) || (textTasks.contains(task) && length != 0)) {
      throw const FormatException('Choose a media file up to 1 GiB. The companion limits analysis to one hour.');
    }
    final audioDigest = input == null ? sha256.convert(const <int>[]).toString() : (await sha256.bind(input.openRead()).first).toString();
    final body = <String, Object?>{
      'task': task, 'identity': identityKey, 'audioDigest': audioDigest, 'audioBytes': length,
      'language': language, 'spokenLanguage': language, 'targetLanguage': targetLanguage,
      'translateToEnglish': translateToEnglish, 'preprocess': preprocess, 'audioTrack': audioTrack, 'crop': crop,
      'subtitleTrack': subtitleTrack, 'finalBitmapDurationMs': finalBitmapDurationMs, 'duckRatio': duckRatio, 'voiceFingerprint': voiceFingerprint,
      'translationMode': translationMode, 'scriptConversion': scriptConversion, 'readingMode': readingMode,
      'translationProviderFingerprint': translationProviderFingerprint, 'visionProviderFingerprint': visionProviderFingerprint, 'glossary': glossary,
      'cues': cues.map((cue) => {'cueId': cue.stableId, 'index': cue.index, 'startMs': cue.startMs,
        'endMs': cue.endMs, 'text': cue.text}).toList(),
    };
    body['requestId'] = sha256.convert(utf8.encode(jsonEncode(body))).toString();
    var created = await _request('POST', '/v1/jobs', body: body);
    final id = created['id'] as String;
    _route(id);
    onCreated?.call(id);
    if (created['state'] == 'awaiting_audio') {
      final client = http.Client();
      _requests.add(client);
      try {
        final request = http.StreamedRequest('PUT', endpoint.replace(path: _route(id, 'audio')))
          ..followRedirects = false
          ..contentLength = length;
        request.headers.addAll({..._headers, 'Content-Type': 'application/octet-stream'});
        final response = client.send(request);
        // Attach an error handler before streaming, so an early connection
        // refusal cannot surface as an unhandled asynchronous exception.
        unawaited(response.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        var sent = 0;
        await request.sink.addStream(input!.openRead().map((block) {
          if (_closed) throw StateError('Companion upload cancelled.');
          sent += block.length;
          if (sent > length) throw const FormatException('Media changed while uploading.');
          onUpload?.call(sent, length);
          return block;
        }));
        await request.sink.close();
        created = await _decode(await response.timeout(const Duration(seconds: 120)), 65536);
      } finally { _requests.remove(client); client.close(); }
    }
    if (const {'ready', 'paused', 'failed'}.contains(created['state'])) await resume(id);
    return id;
  }

  Future<SubtitleCompanionResult> result(String id, {required String identityKey, required String audioDigest}) async {
    final data = await _request('GET', _route(id, 'result'), bound: 24 * 1024 * 1024);
    if (data['schema'] != 1 || data['identity'] != identityKey || data['audioDigest'] != audioDigest || data['jobId'] != id) {
      throw const FormatException('The companion returned a result for a different input or item.');
    }
    final raw = data['cues'], rawWords = data['wordTimings'];
    if (raw is! List || raw.isEmpty || raw.length > 50000 || rawWords is! List || rawWords.length > 250000) {
      throw const FormatException('Companion result exceeds caption limits.');
    }
    final cues = <SubtitleCue>[];
    final regions = <String, Rect>{};
    final ids = <String>{};
    var textBytes = 0;
    for (final value in raw) {
      final c = value as Map<String, dynamic>;
      final start = c['startMs'] as int, end = c['endMs'] as int;
      final text = c['text'] as String, cueId = c['cueId'] as String;
      textBytes += utf8.encode(text).length;
      if (start < 0 || end <= start || end > SubtitleRetimer.maximumTimeMs || text.trim().isEmpty || text.length > 4000 ||
          textBytes > SubtitleRetimer.maximumInputBytes || !_digest.hasMatch(cueId) || !ids.add(cueId)) {
        throw const FormatException('The companion returned an invalid cue.');
      }
      final region = c['region'];
      if (region != null) {
        if (region is! List || region.length != 4 || region.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
          throw const FormatException('Invalid subtitle region.');
        }
        final r = region.cast<num>().map((v) => v.toDouble()).toList();
        if (r[2] <= 0 || r[3] <= 0 || r[0] + r[2] > 1.001 || r[1] + r[3] > 1.001) throw const FormatException('Invalid subtitle region.');
        regions[cueId] = Rect.fromLTWH(r[0], r[1], r[2], r[3]);
      }
      cues.add(SubtitleCue(index: cues.length + 1, startMs: start, endMs: end, text: text, cueId: cueId));
    }
    final sourceCues = <SubtitleCue>[];
    final source = data['sourceCues'];
    if (source != null) {
      if (source is! List || source.length != cues.length) throw const FormatException('Companion changed the source cue count.');
      var sourceBytes = 0;
      for (var i = 0; i < source.length; i++) {
        final original = source[i] as Map<String, dynamic>, output = cues[i];
        final text = original['text'] as String;
        sourceBytes += utf8.encode(text).length;
        if (original['cueId'] != output.stableId || original['startMs'] != output.startMs || original['endMs'] != output.endMs ||
            text.trim().isEmpty || text.length > 4000 || sourceBytes > SubtitleRetimer.maximumInputBytes) {
          throw const FormatException('Companion changed a source cue’s identity/timing or exceeded text limits.');
        }
        sourceCues.add(SubtitleCue(index: i + 1, startMs: output.startMs, endMs: output.endMs, text: text, cueId: output.stableId));
      }
    }
    final words = <SubtitleWordTiming>[];
    for (final value in rawWords) {
      final w = value as Map<String, dynamic>;
      final start = w['startMs'] as int, end = w['endMs'] as int;
      final text = w['text'] as String;
      final probability = (w['confidence'] as num).toDouble();
      if (start < 0 || end <= start || end > SubtitleRetimer.maximumTimeMs || text.length > 4000 ||
          !probability.isFinite || probability < 0 || probability > 1 || !ids.contains(w['cueId'])) {
        throw const FormatException('The companion returned invalid word timings.');
      }
      if (text.isEmpty) continue;
      words.add(SubtitleWordTiming(startMs: start, endMs: end, text: text, confidence: probability,
        unit: SubtitleWordTimingUnit.values.byName(w['unit'] as String), cueId: w['cueId'] as String));
    }
    final warnings = (data['warnings'] as List? ?? const []).whereType<String>().take(100)
        .map((w) => w.length <= 4000 ? w : w.substring(0, 4000)).toList();
    String label(Object? value, int bound, String fallback) => value is String && value.length <= bound ? value : fallback;
    final runtime = label(data['runtimeDevice'], 256, 'unreported');
    warnings.add('Companion $runtime; per-operation placement is unverified. '
        'Preprocessing: ${label(data['preprocessing'], 120, 'unreported')}.');
    final images = <SubtitleCompanionImage>[];
    final rawImages = data['images'] ?? const [];
    if (rawImages is! List || rawImages.length > 50000) throw const FormatException('Companion image evidence exceeds limits.');
    final byId = {for (final cue in cues) cue.stableId: cue};
    final digests = <String, int>{}, imageCueIds = <String>{};
    var evidenceBytes = 0;
    for (final rawImage in rawImages) {
      final value = rawImage as Map<String, dynamic>;
      final cueId = value['cueId'] as String, digest = value['sha256'] as String;
      final bytes = value['bytes'] as int, width = value['width'] as int, height = value['height'] as int;
      final x = value['x'] as int, y = value['y'] as int;
      final score = (value['confidence'] as num).toDouble();
      final cue = byId[cueId];
      if (cue == null || !imageCueIds.add(cueId) || !_digest.hasMatch(digest) || bytes < 45 || bytes > 4 * 1024 * 1024 ||
          width <= 0 || width > 4096 || height <= 0 || height > 2160 || width * height > 8 * 1024 * 1024 ||
          x < 0 || x > 8192 || y < 0 || y > 8192 || !score.isFinite || score < 0 || score > 1 ||
          value['startMs'] != cue.startMs || value['endMs'] != cue.endMs ||
          (digests.containsKey(digest) && digests[digest] != bytes)) throw const FormatException('Invalid companion image evidence.');
      if (!digests.containsKey(digest)) { digests[digest] = bytes; evidenceBytes += bytes; }
      if (evidenceBytes > 32 * 1024 * 1024) throw const FormatException('Companion image evidence exceeds 32 MiB.');
      images.add(SubtitleCompanionImage(cueId: cueId, digest: digest, bytes: bytes, width: width, height: height,
        x: x, y: y, confidence: score, forced: value['forced'] == true, requiresReview: value['requiresReview'] == true));
    }
    final alternatives = <String, String>{};
    final rawAlternatives = data['alternatives'] ?? const [];
    if (rawAlternatives is! List || rawAlternatives.length > 5000) throw const FormatException('Too many recognition alternatives.');
    var alternativeBytes = 0;
    for (final value in rawAlternatives) {
      if (value is! Map || value['cueId'] is! String || !byId.containsKey(value['cueId']) ||
          value['text'] is! String || (value['text'] as String).trim().isEmpty || (value['text'] as String).length > 4000) {
        throw const FormatException('Invalid recognition alternative.');
      }
      alternativeBytes += utf8.encode(value['text'] as String).length;
      if (alternativeBytes > 5 * 1024 * 1024) throw const FormatException('Recognition alternatives exceed limits.');
      alternatives[value['cueId'] as String] = value['text'] as String;
    }
    final artifacts = <SubtitleCompanionArtifact>[];
    final rawArtifacts = data['artifacts'] ?? const [];
    if (rawArtifacts is! List || rawArtifacts.length > 1) throw const FormatException('Invalid companion artifacts.');
    for (final rawArtifact in rawArtifacts) {
      if (rawArtifact is! Map || rawArtifact['name'] != 'dubbed.wav' || rawArtifact['mime'] != 'audio/wav' ||
          rawArtifact['bytes'] is! int || rawArtifact['bytes'] <= 44 || rawArtifact['bytes'] > 32 * 1024 * 1024 ||
          rawArtifact['sha256'] is! String || !_digest.hasMatch(rawArtifact['sha256'])) {
        throw const FormatException('The companion returned invalid audio artifact metadata.');
      }
      artifacts.add(SubtitleCompanionArtifact('dubbed.wav', rawArtifact['sha256'], rawArtifact['bytes'], 'audio/wav'));
    }
    return SubtitleCompanionResult(artifacts: List.unmodifiable(artifacts), alternatives: Map.unmodifiable(alternatives), regions: Map.unmodifiable(regions), cues: List.unmodifiable(cues), wordTimings: List.unmodifiable(words),
      language: label(data['language'], 24, 'unknown'), warnings: warnings,
      runtimeDevice: runtime, cpuFallback: data['cpuFallback'] == true, images: List.unmodifiable(images), sourceCues: List.unmodifiable(sourceCues));
  }

  Future<Uint8List> audioArtifact(String jobId, SubtitleCompanionArtifact artifact) async {
    if (_closed || !_digest.hasMatch(artifact.digest) || artifact.bytes > 32 * 1024 * 1024) throw StateError('Audio artifact unavailable.');
    final client = http.Client(); _requests.add(client);
    try {
      final request = http.Request('GET', endpoint.replace(path: '${_route(jobId)}/artifacts/${artifact.digest}'))..followRedirects = false;
      request.headers.addAll(_headers);
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 || response.headers['content-type'] != 'audio/wav' ||
          response.contentLength != artifact.bytes) throw const FormatException('Invalid companion audio download.');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (_closed || builder.length + chunk.length > artifact.bytes) throw const FormatException('Audio download exceeds its declared length.');
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.length != artifact.bytes || sha256.convert(bytes).toString() != artifact.digest) throw const FormatException('Audio artifact integrity failed.');
      return bytes;
    } finally { _requests.remove(client); client.close(); }
  }

  Future<Uint8List> evidenceImage(String jobId, SubtitleCompanionImage image) async {
    if (_closed || !_digest.hasMatch(image.digest)) throw StateError('Companion image is unavailable.');
    final client = http.Client();
    _requests.add(client);
    try {
      final request = http.Request('GET', endpoint.replace(path: '${_route(jobId)}/evidence/${image.digest}'))
        ..followRedirects = false;
      request.headers.addAll(_headers);
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 || response.headers['content-type'] != 'image/png' ||
          response.contentLength != image.bytes) throw const FormatException('Invalid companion image response.');
      final builder = BytesBuilder(copy: false);
      await for (final block in response.stream.timeout(const Duration(seconds: 30))) {
        if (builder.length + block.length > image.bytes) throw const FormatException('Companion image exceeds its declared size.');
        builder.add(block);
      }
      final bytes = builder.takeBytes();
      if (bytes.length != image.bytes || sha256.convert(bytes).toString() != image.digest ||
          bytes.length < 33 || bytes[0] != 137 || ascii.decode(bytes.sublist(1, 4)) != 'PNG' ||
          ascii.decode(bytes.sublist(12, 16)) != 'IHDR') throw const FormatException('Companion image digest/header mismatch.');
      final header = ByteData.sublistView(bytes);
      if (header.getUint32(16) != image.width || header.getUint32(20) != image.height) {
        throw const FormatException('Companion image dimensions do not match its provenance.');
      }
      return bytes;
    } finally { _requests.remove(client); client.close(); }
  }

  void close() {
    _closed = true;
    for (final client in _requests.toList()) { client.close(); }
    _requests.clear();
  }
}
