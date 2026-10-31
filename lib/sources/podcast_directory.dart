import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'podcast_opml.dart';
import 'source_models.dart';
import 'source_transport.dart';

enum PodcastDirectoryProvider { apple, podcastIndex }

class PodcastDirectoryResult {
  const PodcastDirectoryResult({required this.id, required this.title, required this.feed,
    required this.provider, this.author = '', this.website});
  final String id, title, author;
  final Uri feed;
  final Uri? website;
  final PodcastDirectoryProvider provider;
  PodcastSubscription get subscription => PodcastSubscription(title: title, url: feed);
}

/// Discovery only: directory preview URLs are never used as episode media.
/// The user selects a feed before the app contacts its publisher.
class PodcastDirectory {
  PodcastDirectory(this.transport, {DateTime Function()? now}) : _now = now ?? DateTime.now;
  final SourceTransport transport;
  final DateTime Function() _now;
  final Map<String, (DateTime, List<PodcastDirectoryResult>)> _cache = {};
  DateTime? _lastAppleRequest;
  bool _busy = false;

  static String countryCode(String? value) =>
      RegExp(r'^[A-Za-z]{2}$').hasMatch(value ?? '') ? value!.toUpperCase() : 'US';

  static Uri? feedUri(Object? value) {
    if (value is! String || value.length > 8192) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      return null;
    }
    return uri;
  }

  static String? appleId(Uri uri) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort ||
        !const {'podcasts.apple.com', 'itunes.apple.com'}.contains(uri.host)) return null;
    for (final segment in uri.pathSegments.reversed) {
      final match = RegExp(r'^id([1-9][0-9]{0,18})$').firstMatch(segment);
      if (match != null) return match[1];
    }
    return null;
  }

  static String? indexId(Uri uri) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort || uri.host != 'podcastindex.org') return null;
    final parts = uri.pathSegments;
    return parts.length == 2 && parts.first == 'podcast' && RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(parts[1])
        ? parts[1] : null;
  }

  Future<List<PodcastDirectoryResult>> search(String input, {
    PodcastDirectoryProvider provider = PodcastDirectoryProvider.apple,
    String country = 'US', String apiKey = '', String apiSecret = '', bool trending = false,
  }) async {
    final term = input.trim();
    if (!trending && (term.isEmpty || term.length > 512)) throw const SourceException(SourceFailure.invalidData);
    // URL-like input is either an exact supported public show link or handled
    // locally as RSS by the caller. Never send an unrecognised URL as a query.
    final link = Uri.tryParse(term);
    String? apple, index;
    if (link != null && (link.hasScheme || term.contains('://') || term.startsWith('//'))) {
      apple = appleId(link);
      index = indexId(link);
      if (apple == null && index == null) throw const SourceException(SourceFailure.unsupported);
      provider = apple != null ? PodcastDirectoryProvider.apple : PodcastDirectoryProvider.podcastIndex;
    }
    if (trending && provider != PodcastDirectoryProvider.podcastIndex) {
      throw const SourceException(SourceFailure.unsupported);
    }
    if (provider == PodcastDirectoryProvider.podcastIndex &&
        (apiKey.isEmpty || apiSecret.isEmpty || apiKey.length > 1024 || apiSecret.length > 2048 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(apiKey + apiSecret))) {
      throw const SourceException(SourceFailure.authentication);
    }
    final countryValue = countryCode(country);
    final cacheKey = jsonEncode([provider.name, term, countryValue, trending, sourceDigest(apiKey + apiSecret)]);
    final cached = _cache[cacheKey];
    if (cached != null && _now().difference(cached.$1) < const Duration(minutes: 10)) return cached.$2;
    if (_busy) throw const SourceException(SourceFailure.conflict);
    _busy = true;
    try {
      late Uri uri;
      var headers = <String, String>{'Accept': 'application/json'};
      if (provider == PodcastDirectoryProvider.apple) {
        final last = _lastAppleRequest;
        if (last != null && _now().difference(last) < const Duration(seconds: 3)) {
          throw const SourceException(SourceFailure.unavailable, status: 429);
        }
        uri = Uri.https('itunes.apple.com', apple == null ? '/search' : '/lookup', {
          if (apple == null) 'term': term else 'id': apple,
          'country': countryValue, 'media': 'podcast', 'entity': 'podcast', 'limit': '40',
        });
        _lastAppleRequest = _now();
      } else {
        final timestamp = '${_now().toUtc().millisecondsSinceEpoch ~/ 1000}';
        headers = {...headers, 'User-Agent': 'PlezyNG/3 PodcastDiscovery',
          'X-Auth-Key': apiKey, 'X-Auth-Date': timestamp,
          'Authorization': sha1.convert(utf8.encode('$apiKey$apiSecret$timestamp')).toString()};
        uri = Uri.https('api.podcastindex.org', '/api/1.0/${index != null ? 'podcasts/byfeedid' : trending ? 'podcasts/trending' : 'search/byterm'}', {
          if (index != null) 'id': index else if (!trending) 'q': term,
          'max': '40',
        });
      }
      final body = sourceMap(jsonDecode(await transport.text('GET', uri, headers: headers, limit: 2 * 1024 * 1024)));
      if (provider == PodcastDirectoryProvider.podcastIndex && body['status'] != 'true' && body['status'] != true) {
        throw const SourceException(SourceFailure.unavailable);
      }
      final raw = provider == PodcastDirectoryProvider.apple ? sourceList(body['results'])
          : index != null ? [sourceMap(body['feed'])] : sourceList(body['feeds']);
      final seen = <String>{};
      final results = <PodcastDirectoryResult>[];
      for (final value in raw.take(100)) {
        final item = sourceMap(value);
        final isApple = provider == PodcastDirectoryProvider.apple;
        final feed = feedUri(item[isApple ? 'feedUrl' : 'url']);
        final title = item[isApple ? 'collectionName' : 'title'];
        if (feed == null || title is! String || title.trim().isEmpty || !seen.add(feed.toString())) continue;
        final id = '${item[isApple ? 'collectionId' : 'id'] ?? ''}';
        final author = item[isApple ? 'artistName' : 'author'];
        final publicLink = isApple ? feedUri(item['collectionViewUrl']) : Uri.https('podcastindex.org', '/podcast/$id');
        results.add(PodcastDirectoryResult(id: id, title: title.trim().substring(0, title.trim().length.clamp(0, 300)),
          author: author is String ? author.substring(0, author.length.clamp(0, 300)) : '',
          feed: feed, provider: provider,
          website: publicLink != null && (isApple ? appleId(publicLink) != null : indexId(publicLink) != null) ? publicLink : null));
      }
      if (_cache.length >= 20) _cache.remove(_cache.keys.first);
      _cache[cacheKey] = (_now(), List.unmodifiable(results));
      return List.unmodifiable(results);
    } on SourceException {
      rethrow;
    } on Object {
      // Do not expose request URLs or response fragments via FormatException.
      throw const SourceException(SourceFailure.unavailable);
    } finally {
      _busy = false;
    }
  }

  void close() { _cache.clear(); transport.close(); }
}
