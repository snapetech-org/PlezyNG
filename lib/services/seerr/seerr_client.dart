import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';

import '../../models/seerr/seerr_details.dart';
import '../../models/seerr/seerr_media.dart';
import '../../models/seerr/seerr_page.dart';
import '../../models/seerr/seerr_public_settings.dart';
import '../../models/seerr/seerr_request.dart';
import '../../models/seerr/seerr_request_intent.dart';
import '../../media/media_kind.dart';
import '../../models/seerr/seerr_request_item.dart';
import 'seerr_constants.dart';
import '../../models/seerr/seerr_service.dart';
import '../../models/seerr/seerr_session.dart';
import '../../models/seerr/seerr_user.dart';
import '../../utils/app_logger.dart';
import '../trackers/future_coalescer.dart';
import 'seerr_auth_service.dart';
import 'seerr_exceptions.dart';
import 'seerr_http_client.dart';
import 'seerr_request_intent_store.dart';

/// Supplies the profile's current Plex account token at silent-re-auth time,
/// so plex-method sessions never store a token copy that could go stale.
typedef SeerrPlexTokenSupplier = Future<String?> Function();

/// Authenticated Seerr API client, scoped to one [SeerrSession].
///
/// When the instance no longer knows the session (see [_probeSession])
/// it re-logins silently via [SeerrAuthService.reauth] (password methods use
/// the stored secret; plex uses [plexTokenSupplier]), swaps the cookie, and
/// retries once. Concurrent re-auths coalesce within this client binding so a
/// burst of in-flight rejections triggers a single login POST.
class SeerrClient {
  final FutureCoalescer<void> _reauth = FutureCoalescer();
  bool _disposed = false;
  final _requestTitleCache = <String, Map<String, dynamic>>{};
  final _requestKeys = <String, (String, DateTime)>{};
  int _cookieGeneration = 0;
  int _authorityRead = 0;

  SeerrSession _session;
  final SeerrHttpClient _http;
  final SeerrAuthService _auth;
  final SeerrPlexTokenSupplier? plexTokenSupplier;

  /// Fired when re-auth fails permanently (rejected credentials, no stored
  /// secret). The owning provider clears local state.
  final void Function() onSessionInvalidated;

  /// Fired when re-auth succeeds with a fresh cookie so the owner persists it.
  final void Function(SeerrSession session)? onSessionUpdated;

  SeerrClient(
    SeerrSession session, {
    required this.onSessionInvalidated,
    this.onSessionUpdated,
    this.plexTokenSupplier,
    SeerrAuthService? authService,
    http.Client? httpClient,
  }) : _session = session,
       _http = SeerrHttpClient(baseUrl: session.baseUrl, httpClient: httpClient, cookie: session.cookie),
       _auth = authService ?? SeerrAuthService();

  SeerrSession get session => _session;
  late final SeerrRequestIntentStore intents = SeerrRequestIntentStore(this);

  void dispose() {
    _disposed = true;
    intents.dispose();
    _requestTitleCache.clear();
    _requestKeys.clear();
    _http.dispose();
  }

  // ---------- Auth ----------

  Future<SeerrUser> getMe() async {
    final data = await _request('GET', '/auth/me');
    return _parseUser(data);
  }

  /// Re-read the signed-in user and adopt a changed permission mask or
  /// display name.
  ///
  /// The session stores both as a sign-in-time snapshot. An admin granting
  /// request rights later, or a session persisted by a build that read the
  /// partial `/auth/local` body as permission-less (#2213), only reaches the
  /// Request action once the snapshot is refreshed — and a silent re-auth,
  /// the only other refresh, never runs while the cookie is still accepted.
  Future<void> refreshUser() async {
    await getMe();
  }

  /// Adopt a fresh `/auth/me` body: a changed permission mask or display
  /// name reaches the owner through [onSessionUpdated] in place — the client
  /// is never replaced for a capability change.
  void _adoptUser(SeerrUser user, int cookieGeneration, int authorityRead) {
    if (!_isCurrentCookie(cookieGeneration) || authorityRead != _authorityRead) return;
    final displayName = user.displayName ?? _session.displayName;
    if (user.permissions == _session.permissions && displayName == _session.displayName) return;
    _adopt(_session.copyWith(permissions: user.permissions, displayName: displayName));
  }

  SeerrPublicSettings? _publicSettingsCache;
  final FutureCoalescer<SeerrPublicSettings> _publicSettingsLoad = FutureCoalescer();

  /// Instance flags the request sheet gates on (4K enablement, partial
  /// requests) and the catalog's artwork host. Cached for the client's
  /// lifetime — admins change these rarely and a new client is built per
  /// session rebind anyway. Concurrent first calls (every Explore row at
  /// once) share one request; a failure is not cached.
  Future<SeerrPublicSettings> getPublicSettings() async {
    if (_publicSettingsCache case final SeerrPublicSettings cached) return cached;
    return _publicSettingsLoad.run(_loadPublicSettings);
  }

  Future<SeerrPublicSettings> _loadPublicSettings() async {
    final data = await _request('GET', '/settings/public');
    final settings = SeerrPublicSettings.fromJson(data as Map<String, dynamic>);
    _publicSettingsCache = settings;
    // Every settings fetch re-derives the product discriminator (MediaStatus
    // codes 6/7 decode per product) so legacy sessions persisted before the
    // flag existed, and sessions whose instance changed product, converge.
    if (settings.product != _session.product) _adopt(_session.copyWith(product: settings.product));
    return settings;
  }

  /// URL that TMDB artwork paths (`/t/p/<size>/<file>`) resolve against on
  /// this instance, or null when artwork loads from TMDB directly — the same
  /// choice the Seerr web UI makes. See
  /// [SeerrPublicSettings.tmdbImageProxyPath].
  Future<String?> tmdbImageProxyUrl() async {
    final path = (await getPublicSettings()).tmdbImageProxyPath;
    return path == null ? null : '${_http.baseUrl}$path';
  }

  // ---------- Discover / search ----------

  /// `/discover/movies` — popular movies.
  ///
  /// Deliberately unlocalized. Overseerr and Jellyseerr bind this route's
  /// `language` query parameter to `originalLanguage`, i.e. TMDB's
  /// `with_original_language`, so sending the app locale narrows the shelf to
  /// titles *originally made* in that language (#1763). The display language
  /// here comes from the instance/user locale, which already wins over the
  /// query value, so omitting it costs nothing.
  Future<SeerrPage<SeerrMedia>> getPopularMovies({int page = 1}) =>
      _mediaPage('/discover/movies', page, 'movie', localized: false);

  /// `/discover/tv` — popular series. Unlocalized for the same reason as
  /// [getPopularMovies].
  Future<SeerrPage<SeerrMedia>> getPopularTv({int page = 1}) =>
      _mediaPage('/discover/tv', page, 'tv', localized: false);

  Future<SeerrPage<SeerrMedia>> getUpcomingMovies({int page = 1}) =>
      _mediaPage('/discover/movies/upcoming', page, 'movie');

  Future<SeerrPage<SeerrMedia>> getUpcomingTv({int page = 1}) => _mediaPage('/discover/tv/upcoming', page, 'tv');

  /// `/discover/trending` — mixed movies/TV/people; person entries are
  /// dropped.
  Future<SeerrPage<SeerrMedia>> getTrending({int page = 1}) => _mediaPage('/discover/trending', page, null);

  /// `/search` — Seerr's TMDB-backed catalog search (mixed results, person
  /// entries dropped).
  Future<SeerrPage<SeerrMedia>> search(String query, {int page = 1}) async {
    final data = await _request('GET', '/search', query: {'query': query, 'page': page, 'language': _language});
    return _parseMediaPage(data, null);
  }

  /// TMDB "more like this" for a title; items lack `mediaType` like the
  /// single-type discover endpoints.
  Future<SeerrPage<SeerrMedia>> getMovieRecommendations(int tmdbId, {int page = 1}) =>
      _mediaPage('/movie/$tmdbId/recommendations', page, 'movie');

  Future<SeerrPage<SeerrMedia>> getTvRecommendations(int tmdbId, {int page = 1}) =>
      _mediaPage('/tv/$tmdbId/recommendations', page, 'tv');

  /// [localized] adds the app locale as `language`. Only the two paged
  /// discover routes opt out; everywhere else Seerr treats it as the display
  /// language, which is what we want.
  Future<SeerrPage<SeerrMedia>> _mediaPage(
    String path,
    int page,
    String? coerceMediaType, {
    bool localized = true,
  }) async {
    final data = await _request('GET', path, query: {'page': page, if (localized) 'language': _language});
    return _parseMediaPage(data, coerceMediaType);
  }

  SeerrPage<SeerrMedia> _parseMediaPage(dynamic data, String? coerceMediaType) {
    return SeerrPage<SeerrMedia>.fromJson(data as Map<String, dynamic>, (item) {
      final mediaType = item['mediaType'] as String? ?? coerceMediaType;
      if (mediaType != 'movie' && mediaType != 'tv') return null;
      return SeerrMedia.fromJson({...item, 'mediaType': mediaType});
    });
  }

  // ---------- Details ----------

  Future<SeerrDetails> getMovie(int tmdbId) => _details('/movie/$tmdbId');

  Future<SeerrDetails> getTv(int tmdbId) => _details('/tv/$tmdbId');

  Future<SeerrDetails> _details(String path) async {
    final data = await _request('GET', path, query: {'language': _language});
    return SeerrDetails.fromJson(data as Map<String, dynamic>);
  }

  // ---------- Requests ----------

  Future<SeerrRequest> createRequest(SeerrRequestPayload payload) async {
    final body = payload.toJson();
    final identity = jsonEncode(body);
    if (_requestKeys.length > 100) {
      _requestKeys.removeWhere((_, entry) => DateTime.now().difference(entry.$2) >= const Duration(minutes: 5));
      while (_requestKeys.length > 100) {
        _requestKeys.remove(_requestKeys.keys.first);
      }
    }
    final previous = _requestKeys[identity];
    final random = Random.secure();
    final key = previous != null && DateTime.now().difference(previous.$2) < const Duration(minutes: 5)
        ? previous.$1
        : List.generate(16, (_) => random.nextInt(256)).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _requestKeys[identity] = (key, DateTime.now());
    late final dynamic data;
    try {
      data = await _request('POST', '/request', body: body, extraHeaders: {'Idempotency-Key': key});
    } on SeerrApiException catch (e) {
      if (e.statusCode == 409) _requestKeys.remove(identity);
      rethrow;
    }
    final kind = payload.mediaType == 'movie' ? MediaKind.movie : MediaKind.show;
    intents.refreshIfObserved(kind, payload.mediaId);
    return SeerrRequest.fromJson(data as Map<String, dynamic>);
  }

  Future<List<SeerrRequestIntent>> getRequestIntents(List<(MediaKind, int)> identities) async {
    final data = await _request(
      'POST',
      '/request/intent/state',
      body: {
        'items': [
          for (final (kind, id) in identities) {'mediaType': kind == MediaKind.movie ? 'movie' : 'tv', 'tmdbId': id},
        ],
      },
    );
    return [
      for (final raw in (data as Map<String, dynamic>)['items'] as List<dynamic>)
        SeerrRequestIntent.fromJson(raw as Map<String, dynamic>),
    ];
  }

  Future<void> subscribeToAvailability(MediaKind kind, int tmdbId, {bool? is4k, int? seasonNumber}) async {
    await _request(
      'POST',
      '/user/${session.userId}/availability-subscriptions/${kind == MediaKind.movie ? 'movie' : 'tv'}/$tmdbId',
      body: {'is4k': ?is4k, 'seasonNumber': ?seasonNumber},
    );
    intents.refreshIfObserved(kind, tmdbId);
  }

  Future<void> unsubscribeFromAvailability(MediaKind kind, int tmdbId) async {
    await _request(
      'DELETE',
      '/user/${session.userId}/availability-subscriptions/${kind == MediaKind.movie ? 'movie' : 'tv'}/$tmdbId',
    );
    intents.refreshIfObserved(kind, tmdbId);
  }

  /// User-only request overview and discovery. Server authorization remains authoritative.
  Future<SeerrRequestBrowsePage> browseRequests(
    SeerrRequestCategory category, {
    bool discover = false,
    String query = '',
    int page = 1,
  }) async {
    if (page < 1 || page > 500) throw RangeError.range(page, 1, 500, 'page');
    if (query.length > 200) throw const FormatException('Request search is too long');
    final searching = query.trim().isNotEmpty;
    final path = discover || searching
        ? searching
              ? '/search'
              : category.isBook
              ? '/discover/books'
              : category == SeerrRequestCategory.movies
              ? '/discover/movies'
              : '/discover/tv'
        : category.isBook
        ? '/request/status'
        : '/request';
    final data = await _request(
      'GET',
      path,
      query: {
        if (discover || searching) 'page': page,
        if (searching) ...{'query': query.trim(), 'type': category.mediaType, 'language': _language},
        if (category.isBook && (discover || searching)) 'format': category.format,
        if (!discover && !searching) ...{
          'take': 20,
          'skip': (page - 1) * 20,
          'requestedBy': session.userId,
          'mediaType': category.mediaType,
          if (category.isBook) 'bookFormat': category.format,
        },
      },
    );
    final body = data as Map<String, dynamic>;
    final results = (body['results'] as List? ?? const []).whereType<Map<String, dynamic>>().take(
      discover || searching ? 50 : 20,
    );
    final items = <SeerrRequestItem>[];
    for (final result in results) {
      if (discover || searching) {
        final type = result['mediaType'] ?? category.mediaType;
        if (type == category.mediaType) items.add(SeerrRequestItem.fromJson(result, category));
      } else {
        final request = (category.isBook ? result['request'] : result) as Map<String, dynamic>;
        if (request['type'] != category.mediaType) continue;
        // Defense in depth even if an older server ignores requestedBy.
        if ((request['requestedBy'] as Map?)?['id'] != session.userId) continue;
        final media = request['media'] as Map<String, dynamic>? ?? const {};
        Object? id = media['tmdbId'];
        if (category.isBook) {
          final identifiers = (media['identifiers'] as List? ?? const []).whereType<Map>();
          id = identifiers
              .where((v) => v['provider'] == 'openlibrary' || v['provider'] == 'bookshelf')
              .firstOrNull?['value'];
        }
        if (id == null) continue;
        // Cache title metadata in this account client; status always comes from
        // the fresh request response. Refresh must not refetch every book from
        // its rate-limited metadata route. A missing title must not hide history.
        final path = '/${category.mediaType}/${Uri.encodeComponent('$id')}';
        var details = _requestTitleCache[path];
        if (details == null) {
          try {
            details = await _request('GET', path, query: {'language': _language}) as Map<String, dynamic>;
            _rememberRequestTitle(path, details);
          } catch (error) {
            _ensureActive();
            appLogger.w('Request title metadata unavailable', error: error);
            details = {'id': id};
          }
        }
        _ensureActive();
        items.add(
          SeerrRequestItem.fromJson(
            {...details, 'id': id, 'mediaInfo': media},
            category,
            requestStatus: request['status'] as int?,
            is4k: request['is4k'] == true,
          ),
        );
      }
    }
    final info = body['pageInfo'] as Map?;
    final totalPages = (body['totalPages'] ?? info?['pages']) as int?;
    return SeerrRequestBrowsePage(items, hasMore: totalPages != null ? page < totalPages : results.length == 20);
  }

  void _rememberRequestTitle(String path, Map<String, dynamic> details) {
    _requestTitleCache.remove(path);
    _requestTitleCache[path] = details;
    if (_requestTitleCache.length > 128) _requestTitleCache.remove(_requestTitleCache.keys.first);
  }

  Future<SeerrRequestItem> requestDetails(SeerrRequestItem item) async {
    final data = await _request(
      'GET',
      '/${item.category.mediaType}/${Uri.encodeComponent('${item.id}')}',
      query: {'language': _language},
    );
    _rememberRequestTitle(
      '/${item.category.mediaType}/${Uri.encodeComponent('${item.id}')}',
      data as Map<String, dynamic>,
    );
    return SeerrRequestItem.fromJson(data, item.category, requestStatus: item.requestStatus, is4k: item.is4k);
  }

  Future<void> requestBook(SeerrRequestItem item) async {
    if (!item.category.isBook) throw ArgumentError('Only book requests belong here');
    if (!seerrHasPermission(session.permissions, [SeerrPermission.request, SeerrPermission.requestBook])) {
      throw const SeerrAuthException('Book request permission denied');
    }
    // No userId, service, destination or approval override: apply server defaults.
    await _request('POST', '/request', body: {'mediaType': 'book', 'mediaId': item.id, 'format': item.category.format});
  }

  // ---------- Sonarr / Radarr options (request sheet advanced pickers) ----------

  Future<List<SeerrServiceInstance>> getRadarrServices() => _serviceList('/service/radarr');

  Future<List<SeerrServiceInstance>> getSonarrServices() => _serviceList('/service/sonarr');

  Future<SeerrServiceDetail> getRadarrService(int id) => _serviceDetail('/service/radarr/$id');

  Future<SeerrServiceDetail> getSonarrService(int id) => _serviceDetail('/service/sonarr/$id');

  Future<List<SeerrServiceInstance>> _serviceList(String path) async {
    final data = await _request('GET', path);
    return [
      if (data is List)
        for (final item in data)
          if (item is Map<String, dynamic>) SeerrServiceInstance.fromJson(item),
    ];
  }

  Future<SeerrServiceDetail> _serviceDetail(String path) async {
    final data = await _request('GET', path);
    return SeerrServiceDetail.fromJson(data as Map<String, dynamic>);
  }

  // ---------- Internals ----------
  String get _language => LocaleSettings.currentLocale.plexLanguageCode;

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    Map<String, String>? extraHeaders,
  }) async {
    for (var attempt = 0; ; attempt++) {
      _ensureActive();
      final cookieGeneration = _cookieGeneration;
      final authorityRead = path == '/auth/me' ? ++_authorityRead : null;
      final res = await _http.send(method, path, query: query, body: body, extraHeaders: extraHeaders);
      _ensureActive();
      final rejection = SeerrHttpClient.classify(res, path: path);
      if (rejection == SeerrRejection.routeDenied) {
        // The handler may mean permissions, quota or blocklist. Its error is
        // authoritative; this optional raw read must never log in or replay.
        if (_isCurrentCookie(cookieGeneration) && path != '/auth/me') {
          try {
            await _probeSession(path, cookieGeneration);
          } catch (e) {
            appLogger.d('Seerr: denied-action authority refresh failed', error: e);
          }
        }
      } else if (rejection == SeerrRejection.session) {
        final verdict = await _probeSession(path, cookieGeneration);
        _ensureActive();
        if (verdict == _SessionVerdict.live) throw _permissionDenied(res, path);
        if (verdict == _SessionVerdict.gone || !_isCurrentCookie(cookieGeneration)) {
          if (attempt == 0) {
            if (_isCurrentCookie(cookieGeneration)) {
              try {
                await _reauth.run(() => _doReauth(cookieGeneration));
              } on SeerrAuthException {
                if (_isCurrentCookie(cookieGeneration)) onSessionInvalidated();
                rethrow;
              }
            }
            _ensureActive();
            // Only middleware proves the handler did not execute. At most
            // one replay, including failures arriving for an older cookie.
            continue;
          }
          if (_isCurrentCookie(cookieGeneration) && verdict == _SessionVerdict.gone) {
            onSessionInvalidated();
            throw SeerrAuthException(
              'Session rejected after successful re-auth',
              statusCode: res.statusCode,
              display: t.seerr.sessionRejectedAfterReauth,
            );
          }
        }
      }
      SeerrHttpClient.throwForStatus(res, path: path);
      _ensureActive();
      if (authorityRead != null) _adoptUser(_parseUser(res.data), cookieGeneration, authorityRead);
      return res.data;
    }
  }

  SeerrPermissionException _permissionDenied(SeerrResponse res, String path) => SeerrPermissionException(
    'Permission denied for $path',
    display: t.seerr.permissionDenied,
    statusCode: res.statusCode,
  );

  /// Whether a middleware rejection on [path] means the instance no longer
  /// knows the session.
  ///
  /// Only Seerr's own middleware rejection ([SeerrRejection.session]) can
  /// mean that, and it carries the same status and body as a permission
  /// denial, so it counts as expiry only once `GET /auth/me` (authenticated,
  /// no permission bits) refuses the cookie the same way. Re-authing on
  /// every 403 would instead unlink a Quick Connect session, which has no
  /// re-auth credentials, over a plain permission denial. Anything an
  /// intermediary answered — on the request or on the probe — is no
  /// rejection at all: the cookie may be fine behind the wall, and a re-auth
  /// would fail the same way and unlink the session.
  ///
  /// A probe that answers with the user proves the session live *and*
  /// carries the current permission mask — the very authority the denied
  /// request was gated on — so it is adopted before the caller reports the
  /// denial, and the owner's surfaces re-derive their gates from it.
  Future<_SessionVerdict> _probeSession(String path, int cookieGeneration) async {
    if (!_isCurrentCookie(cookieGeneration)) return _SessionVerdict.inconclusive;
    if (path == '/auth/me') return _SessionVerdict.gone;
    final authorityRead = ++_authorityRead;
    final me = await _http.send('GET', '/auth/me');
    if (!_isCurrentCookie(cookieGeneration)) return _SessionVerdict.inconclusive;
    SeerrHttpClient.throwIfIntermediary(me, path: '/auth/me');
    if (SeerrHttpClient.classify(me, path: '/auth/me') == SeerrRejection.session) return _SessionVerdict.gone;
    if (me.statusCode < 200 || me.statusCode >= 300) return _SessionVerdict.inconclusive;
    final SeerrUser user;
    try {
      user = _parseUser(me.data);
    } on SeerrApiException {
      return _SessionVerdict.inconclusive;
    }
    _adoptUser(user, cookieGeneration, authorityRead);
    return _SessionVerdict.live;
  }

  SeerrUser _parseUser(dynamic data) {
    if (data is Map<String, dynamic>) {
      try {
        final user = SeerrUser.fromJson(data);
        if (user.id == _session.userId) return user;
      } on TypeError {
        // Malformed authority is not a zero-permission user or session expiry.
      }
    }
    throw SeerrApiException(t.seerr.noUserInformation, statusCode: 200);
  }

  bool _isCurrentCookie(int generation) => !_disposed && generation == _cookieGeneration;

  void _ensureActive() {
    if (_disposed) throw StateError('Seerr client is disposed');
  }

  Future<void> _doReauth(int cookieGeneration) async {
    if (!_isCurrentCookie(cookieGeneration)) return;
    final previous = _session;
    appLogger.d('Seerr: session expired, re-authenticating silently');
    final plexToken = previous.method == SeerrAuthMethod.plex
        ? await _resolvePlexToken().timeout(SeerrConstants.authTimeout, onTimeout: () => null)
        : null;
    if (!_isCurrentCookie(cookieGeneration)) return;
    final next = await _auth.reauth(previous, plexToken: plexToken);
    if (!_isCurrentCookie(cookieGeneration)) return;
    // Invalidate every read issued for the old cookie, even if the server
    // happened to issue the same cookie value on the replacement login.
    _cookieGeneration++;
    _adopt(next);
  }

  /// Owns the `Future<String?>` type: calling `.timeout(onTimeout: () =>
  /// null)` directly on the supplier's future trips the covariant-generics
  /// runtime check when a caller hands us a `Future<String> Function()`.
  Future<String?> _resolvePlexToken() async => plexTokenSupplier == null ? null : await plexTokenSupplier!();

  /// Adopt a refreshed session, merging the product discriminator instead of
  /// wholesale-replacing it: a re-auth completes from the snapshot taken when
  /// it started, so a concurrent [getPublicSettings] adoption would otherwise
  /// be overwritten — and the settings cache means it would never be
  /// reapplied. Cached settings are authoritative; failing that, a known
  /// product never downgrades to unknown.
  void _adopt(SeerrSession next) {
    if (_disposed) return;
    final product = _publicSettingsCache?.product ?? _session.product;
    final merged = product == SeerrProduct.unknown || product == next.product ? next : next.copyWith(product: product);
    final permissionsChanged = merged.permissions != _session.permissions;
    _session = merged;
    if (permissionsChanged) intents.invalidateAll();
    _http.cookie = merged.cookie;
    onSessionUpdated?.call(merged);
  }
}

/// What the `/auth/me` probe said about a middleware-rejected cookie.
enum _SessionVerdict {
  /// The probe refused the cookie the same way: re-auth.
  gone,

  /// The probe answered with the user: the rejection was a permission miss.
  live,

  /// The probe answered with neither (a 5xx, a non-JSON body): report the
  /// original response as the plain API failure it looks like.
  inconclusive,
}
