import 'dart:convert';

import '../source_models.dart';
import '../source_transport.dart';
import 'webdav_source.dart';

/// Direct BookOrbit library access uses the signed-in user's own account.
/// Only the username and password enter the encrypted source credential vault;
/// the short-lived bearer token stays in this adapter's memory.
class BookOrbitSourceAdapter extends SourceAdapter {
  BookOrbitSourceAdapter(super.source, super.transport, this.credentials);

  final SourceCredentials credentials;
  String? _token;
  Future<String>? _loginInFlight;

  Uri url(String path) {
    final base = Uri.parse(source.endpoint.endsWith('/') ? source.endpoint : '${source.endpoint}/');
    final uri = base.resolve(path);
    if (!sameSourceOrigin(base, uri) || !uri.path.startsWith(base.path)) {
      throw const SourceException(SourceFailure.permission);
    }
    transport.validate(uri);
    return uri;
  }

  Future<String> _login() {
    if (_loginInFlight != null) return _loginInFlight!;
    late final Future<String> pending;
    pending = _performLogin().whenComplete(() {
      if (identical(_loginInFlight, pending)) _loginInFlight = null;
    });
    _loginInFlight = pending;
    return pending;
  }

  Future<String> _performLogin() async {
    final saved = await credentials();
    final username = saved['username']?.trim() ?? '';
    final password = saved['password'] ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const SourceException(SourceFailure.authentication);
    }
    final response = await transport.json(
      'POST',
      url('api/v1/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password, 'clientKind': 'native', 'deviceLabel': 'Pleazyng'}),
    );
    final token = response['accessToken'];
    if (token is! String || token.isEmpty) {
      throw const SourceException(SourceFailure.authentication);
    }
    _token = token;
    return token;
  }

  Future<String> _accessToken() async => _token ?? await _login();

  Future<String> _text(String method, String path, {Object? body}) async {
    Future<String> send(String token) => transport.text(
      method,
      url(path),
      headers: {'Authorization': 'Bearer $token', if (body != null) 'Content-Type': 'application/json'},
      body: body == null ? null : jsonEncode(body),
    );
    try {
      return await send(await _accessToken());
    } on SourceException catch (error) {
      if (error.status != 401) rethrow;
      _token = null;
      return send(await _login());
    }
  }

  Future<Map<String, dynamic>> _api(String method, String path, {Object? body}) async =>
      sourceMap(jsonDecode(await _text(method, path, body: body)));

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(search: true, audioProgress: true);

  static const _audio = {'m4b', 'mp3', 'm4a', 'opus', 'ogg', 'flac'};
  static const _comic = {'cbz', 'cbr', 'cb7', 'cbx'};
  static const _ebook = {'epub', 'kepub', 'pdf', 'djvu', 'mobi', 'azw', 'azw3', 'fb2'};

  PublicationFile? _file(Map<String, dynamic> row, int bookId, {String? assetId, int? durationMs}) {
    final id = sourceInt(row['id']);
    final format = (row['format'] as String? ?? '').toLowerCase();
    if (id == null ||
        id < 1 ||
        !const {'content', 'primary'}.contains(row['role']) ||
        !(_audio.contains(format) || _ebook.contains(format) || _comic.contains(format))) {
      return null;
    }
    final name = row['filename'] is String && (row['filename'] as String).isNotEmpty
        ? row['filename'] as String
        : 'BookOrbit-$id.$format';
    final mime = switch (format) {
      'epub' || 'kepub' => 'application/epub+zip',
      'pdf' => 'application/pdf',
      'cbz' => 'application/vnd.comicbook+zip',
      'm4b' || 'm4a' => 'audio/mp4',
      'mp3' => 'audio/mpeg',
      'opus' || 'ogg' => 'audio/ogg',
      'flac' => 'audio/flac',
      _ => 'application/octet-stream',
    };
    return PublicationFile(
      id: jsonEncode({'book': bookId, 'file': id, 'asset': ?assetId}),
      name: name,
      mimeType: mime,
      size: sourceInt(row['sizeBytes']),
      durationMs:
          durationMs ??
          ((row['durationSeconds'] as num?) == null ? null : ((row['durationSeconds'] as num) * 1000).round()),
      revision: row['contentVersion']?.toString(),
    );
  }

  SourceEntry _entry(Map<String, dynamic> row, {Map<int, Map<String, dynamic>> assets = const {}}) {
    final id = sourceInt(row['id']);
    if (id == null || id < 1) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final files = sourceList(row['files'])
        .map(sourceMap)
        .map(
          (file) => _file(
            file,
            id,
            assetId: assets[sourceInt(file['id'])]?['assetId'] as String?,
            durationMs: sourceInt(assets[sourceInt(file['id'])]?['durationMs']),
          ),
        )
        .whereType<PublicationFile>()
        .toList();
    final hasAudio = files.any((file) => _audio.contains(file.name.split('.').last.toLowerCase()));
    final hasComic = files.any((file) => _comic.contains(file.name.split('.').last.toLowerCase()));
    final authors = sourceList(row['authors']).whereType<String>().join(', ');
    return SourceEntry(
      sourceId: source.id,
      id: '$id',
      title: row['title'] as String? ?? 'Book $id',
      kind: hasAudio
          ? SourceItemKind.audiobook
          : hasComic
          ? SourceItemKind.comic
          : SourceItemKind.ebook,
      author: authors,
      narrator: sourceList(row['narrators']).whereType<String>().join(', '),
      series: row['seriesName'] as String? ?? '',
      seriesOrder: (row['seriesIndex'] as num?)?.toDouble(),
      language: row['language'] as String? ?? '',
      coverId: row['hasCover'] == true ? '$id' : null,
      files: files,
      releaseYear: sourceInt(row['publishedYear']),
      genres: sourceList(row['genres']).whereType<String>().toList(),
      identifiers: {
        'bookorbit': '$id',
        if (row['isbn13'] is String && (row['isbn13'] as String).isNotEmpty) 'isbn13': row['isbn13'] as String,
        if (row['hardcoverId'] is String && (row['hardcoverId'] as String).isNotEmpty)
          'hardcover': row['hardcoverId'] as String,
      },
    );
  }

  @override
  Future<SourcePage> browse({String? parent, String? cursor, String? query}) async {
    final page = cursor == null ? 0 : int.tryParse(cursor);
    if (page == null || page < 0 || page > 10000) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final response = await _api(
      'POST',
      'api/v1/books/query',
      body: {
        'sort': [
          {'field': 'title', 'dir': 'asc'},
        ],
        'pagination': {'page': page, 'size': 100},
        if (query?.trim().isNotEmpty == true) 'q': query!.trim(),
      },
    );
    final items = sourceList(response['items']);
    final total = sourceInt(response['total']);
    if (items.length > 100 || total == null || total < 0 || total > 1000100) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final entries = items.map(sourceMap).map(_entry).where((entry) => entry.files.isNotEmpty).toList();
    return SourcePage(entries, next: (page + 1) * 100 < total ? '${page + 1}' : null, title: source.name);
  }

  @override
  Future<SourceEntry> hydrate(SourceEntry entry) async {
    final id = int.tryParse(entry.id);
    if (id == null || id < 1) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final book = await _api('GET', 'api/v1/books/$id');
    final hasAudio = sourceList(
      book['files'],
    ).map(sourceMap).any((file) => _audio.contains('${file['format']}'.toLowerCase()));
    final manifest = hasAudio ? await _api('GET', 'api/v1/audiobooks/$id/manifest') : const <String, dynamic>{};
    final assets = {
      for (final value in sourceList(manifest['assets']))
        if (sourceInt(sourceMap(value)['fileId']) != null) sourceInt(sourceMap(value)['fileId'])!: sourceMap(value),
    };
    return _entry(book, assets: assets);
  }

  @override
  Future<ContentLease?> cover(SourceEntry entry) async {
    if (entry.coverId == null) return null;
    final id = int.tryParse(entry.coverId!);
    if (id == null || id < 1) {
      throw const SourceException(SourceFailure.invalidData);
    }
    return ContentLease(url('api/v1/books/$id/cover'), headers: {'Authorization': 'Bearer ${await _accessToken()}'});
  }

  @override
  Future<ContentLease> resolve(PublicationFile file) async {
    final reference = sourceMap(jsonDecode(file.id));
    final bookId = sourceInt(reference['book']);
    final fileId = sourceInt(reference['file']);
    if (bookId == null || bookId < 1 || fileId == null || fileId < 1) {
      throw const SourceException(SourceFailure.invalidData);
    }
    var assetId = reference['asset'];
    if (_audio.contains(file.name.split('.').last.toLowerCase()) && assetId == null) {
      final manifest = await _api('GET', 'api/v1/audiobooks/$bookId/manifest');
      for (final value in sourceList(manifest['assets'])) {
        final asset = sourceMap(value);
        if (sourceInt(asset['fileId']) == fileId) assetId = asset['assetId'];
      }
    }
    final path = _audio.contains(file.name.split('.').last.toLowerCase())
        ? assetId is String && RegExp(r'^aud_[0-9a-f-]{36}$', caseSensitive: false).hasMatch(assetId)
              ? 'api/v1/audiobooks/$bookId/assets/$assetId/content'
              : null
        : 'api/v1/books/files/$fileId/serve';
    if (path == null) throw const SourceException(SourceFailure.unavailable);
    return ContentLease(url(path), headers: {'Authorization': 'Bearer ${await _accessToken()}'}, size: file.size);
  }

  @override
  bool supportsProgress(SourceEntry entry, PublicationProgress progress) =>
      progress.mode == PublicationMode.listening && entry.audio.isNotEmpty;

  @override
  Future<PublicationProgress?> readProgress(SourceEntry entry, PublicationProgress local) async {
    if (local.mode != PublicationMode.listening) return null;
    final id = int.tryParse(entry.id);
    if (id == null) return null;
    final response = await _text('GET', 'api/v1/books/$id/audio-progress');
    if (response == 'null') return null;
    final row = sourceMap(jsonDecode(response));
    final seconds = (row['positionSeconds'] as num?)?.toDouble() ?? 0;
    return local.copyWith(
      positionMs: (seconds * 1000).round(),
      filePositionMs: (seconds * 1000).round(),
      fileIndex: entry.audio
          .indexWhere((file) => sourceInt(sourceMap(jsonDecode(file.id))['file']) == sourceInt(row['currentFileId']))
          .clamp(0, entry.audio.length - 1),
      fraction: ((row['percentage'] as num?)?.toDouble() ?? 0) / 100,
      session: 'bookorbit',
    );
  }

  @override
  Future<void> writeProgress(SourceEntry entry, PublicationProgress progress) async {
    if (!supportsProgress(entry, progress)) {
      throw const SourceException(SourceFailure.unsupported);
    }
    final id = int.tryParse(entry.id);
    final file = entry.audio.elementAtOrNull(progress.fileIndex);
    if (id == null || file == null) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final fileId = sourceInt(sourceMap(jsonDecode(file.id))['file']);
    if (fileId == null) throw const SourceException(SourceFailure.invalidData);
    await _text(
      'PATCH',
      'api/v1/books/$id/audio-progress',
      body: {
        'currentFileId': fileId,
        'positionSeconds': progress.filePositionMs / 1000,
        'percentage': (progress.fraction * 100).clamp(0, 100),
      },
    );
  }

  @override
  Future<void> refreshAuthorization() async {
    _token = null;
    await _login();
  }

  @override
  void close() {
    _token = null;
    super.close();
  }
}
