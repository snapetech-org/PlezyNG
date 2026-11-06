/// Shared, provider-independent bonus-feature contracts. No provider token or
/// media-server URL belongs in these objects or in the public discovery cache.
library;

enum ExtraKind {
  makingOf,
  effects,
  makeup,
  interview,
  deletedScene,
  bloopers,
  commentary,
  trailer,
  analysis,
  other,
}

enum ExtraOrigin { library, user, reviewed, catalog, search }

enum ExtraScope { work, franchise, season, episode }

enum ExtrasAiMode { off, device, server, cloud }

class ExtrasSubject {
  const ExtrasSubject({
    required this.key,
    required this.identities,
    required this.title,
    this.year,
    this.watched = false,
    this.restricted = false,
    this.offline = false,
    this.language = 'en',
    this.region = 'US',
  });
  final String key;
  final Set<String> identities;
  final String title;
  final int? year;
  final bool watched, restricted, offline;
  final String language, region;
  Set<String> get allIdentities => {key, ...identities};
  Map<String, Object?> toRequest() => {
    'identities': identities.toList()..sort(),
    'title': title,
    'year': year,
    'language': language,
    'region': region,
  };
}

class ExtraPassage {
  const ExtraPassage({
    required this.startSeconds,
    required this.endSeconds,
    required this.text,
  });
  final int startSeconds, endSeconds;
  final String text;
  Map<String, Object?> toJson() => {
    'start': startSeconds,
    'end': endSeconds,
    'text': text,
  };
  static ExtraPassage? parse(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['start'], end = raw['end'], text = raw['text'];
    if (start is! int ||
        end is! int ||
        start < 0 ||
        end <= start ||
        end > 86400 ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 2000)
      return null;
    return ExtraPassage(startSeconds: start, endSeconds: end, text: text);
  }
}

class ExtraEntry {
  const ExtraEntry({
    required this.id,
    required this.parentIdentities,
    required this.title,
    required this.kind,
    required this.origin,
    this.publisherId = '',
    this.publisher = '',
    this.url,
    this.nativeKey,
    this.scope = ExtraScope.work,
    this.scopeLabel = '',
    this.description = '',
    this.language = '',
    this.durationSeconds,
    this.thumbnailUrl,
    this.verifiedPublisher = false,
    this.catalogAssociated = false,
    this.reviewedAssociation = false,
    this.spoilerSafe = false,
    this.available = true,
    this.analysisAllowed = false,
    this.contentGroup = '',
    this.passages = const [],
  });
  final String id,
      title,
      publisherId,
      publisher,
      description,
      language,
      scopeLabel,
      contentGroup;
  final Set<String> parentIdentities;
  final ExtraKind kind;
  final ExtraOrigin origin;
  final ExtraScope scope;
  final Uri? url;
  final String? nativeKey, thumbnailUrl;
  final int? durationSeconds;
  final bool verifiedPublisher,
      catalogAssociated,
      reviewedAssociation,
      spoilerSafe,
      available,
      analysisAllowed;
  final List<ExtraPassage> passages;
  bool get isLibrary => origin == ExtraOrigin.library && nativeKey != null;
  String get duplicateKey => canonicalExtraUrl(url)?.toString() ?? id;
  Map<String, Object?> toJson() => {
    'id': id,
    'parents': parentIdentities.toList()..sort(),
    'title': title,
    'kind': kind.name,
    'origin': origin.name,
    'scope': scope.name,
    'scopeLabel': scopeLabel,
    'publisherId': publisherId,
    'publisher': publisher,
    'url': url?.toString(),
    'description': description,
    'language': language,
    'durationSeconds': durationSeconds,
    'thumbnailUrl': thumbnailUrl,
    'verifiedPublisher': verifiedPublisher,
    'catalogAssociated': catalogAssociated,
    'reviewedAssociation': reviewedAssociation,
    'spoilerSafe': spoilerSafe,
    'available': available,
    'analysisAllowed': analysisAllowed,
    'contentGroup': contentGroup,
    'passages': passages.map((p) => p.toJson()).toList(),
  };
  static ExtraEntry? parse(Object? raw, {bool userAdded = false}) {
    if (raw is! Map) return null;
    final id = raw['id'], title = raw['title'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 200 ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 500)
      return null;
    final url = canonicalExtraUrl(
      Uri.tryParse(raw['url'] is String ? raw['url'] as String : ''),
    );
    if (url == null) return null;
    final parents = extraStrings(raw['parents'])
        .where((p) => p.length <= 200)
        .take(12)
        .toSet();
    if (parents.isEmpty) return null;
    String field(String key, [int max = 500]) => raw[key] is String
        ? (raw[key] as String).substring(
            0,
            (raw[key] as String).length.clamp(0, max),
          )
        : '';
    final duration = raw['durationSeconds'];
    final thumbnail = Uri.tryParse(field('thumbnailUrl', 2000));
    return ExtraEntry(
      id: id,
      parentIdentities: parents,
      title: title,
      url: url,
      kind: extraEnum(ExtraKind.values, raw['kind'], ExtraKind.other),
      // Remote data cannot impersonate a local item or a user action.
      origin: userAdded
          ? ExtraOrigin.user
          : extraEnum(
              [ExtraOrigin.reviewed, ExtraOrigin.catalog, ExtraOrigin.search],
              raw['origin'],
              ExtraOrigin.search,
            ),
      scope: extraEnum(ExtraScope.values, raw['scope'], ExtraScope.work),
      scopeLabel: field('scopeLabel'),
      publisherId: field('publisherId', 200),
      publisher: field('publisher'),
      description: field('description', 4000),
      language: field('language', 20),
      durationSeconds: duration is int && duration > 0 && duration <= 86400
          ? duration
          : null,
      thumbnailUrl: thumbnail?.scheme == 'https' && thumbnail!.userInfo.isEmpty
          ? thumbnail.toString()
          : null,
      verifiedPublisher: raw['verifiedPublisher'] == true,
      catalogAssociated: raw['catalogAssociated'] == true,
      reviewedAssociation: raw['reviewedAssociation'] == true,
      spoilerSafe: raw['spoilerSafe'] == true,
      available: raw['available'] != false,
      analysisAllowed: raw['analysisAllowed'] == true,
      contentGroup: field('contentGroup', 200),
      passages: raw['passages'] is List
          ? (raw['passages'] as List)
                .take(500)
                .map(ExtraPassage.parse)
                .whereType<ExtraPassage>()
                .toList()
          : const [],
    );
  }
}

T extraEnum<T extends Enum>(List<T> values, Object? raw, T fallback) =>
    values.where((e) => e.name == raw).firstOrNull ?? fallback;
List<String> extraStrings(Object? raw) =>
    raw is List ? raw.whereType<String>().toList() : const [];

/// Canonical provider watch URLs only. Reject arbitrary protocols, credentials,
/// ports, redirects and hosts; never send media-server credentials to a provider.
Uri? canonicalExtraUrl(Uri? uri) {
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443))
    return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be' && uri.pathSegments.length == 1)
    id = uri.pathSegments.first;
  if (const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'www.youtube-nocookie.com',
  }.contains(host)) {
    if (uri.path == '/watch') id = uri.queryParameters['v'];
    if (uri.pathSegments.length == 2 &&
        const {'embed', 'shorts'}.contains(uri.pathSegments.first))
      id = uri.pathSegments.last;
  }
  if (id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id))
    return Uri.https('www.youtube.com', '/watch', {'v': id});
  if (const {'vimeo.com', 'www.vimeo.com'}.contains(host) &&
      uri.pathSegments.length == 1 &&
      RegExp(r'^[0-9]{1,15}$').hasMatch(uri.pathSegments.first))
    return Uri.https('vimeo.com', '/${uri.pathSegments.first}');
  return null;
}

class ExtrasPreferences {
  const ExtrasPreferences({
    this.externalEnabled = true,
    this.includeAnalysis = false,
    this.showSpoilers = false,
    this.aiMode = ExtrasAiMode.off,
    this.serviceUrl = '',
    this.aiUrl = '',
    this.aiModel = '',
    this.hiddenIds = const {},
    this.hiddenPublishers = const {},
    this.wrongMatches = const {},
  });
  final bool externalEnabled, includeAnalysis, showSpoilers;
  final ExtrasAiMode aiMode;
  final String serviceUrl, aiUrl, aiModel;
  final Set<String> hiddenIds, hiddenPublishers, wrongMatches;
  ExtrasPreferences copyWith({
    bool? externalEnabled,
    bool? includeAnalysis,
    bool? showSpoilers,
    ExtrasAiMode? aiMode,
    String? serviceUrl,
    String? aiUrl,
    String? aiModel,
    Set<String>? hiddenIds,
    Set<String>? hiddenPublishers,
    Set<String>? wrongMatches,
  }) => ExtrasPreferences(
    externalEnabled: externalEnabled ?? this.externalEnabled,
    includeAnalysis: includeAnalysis ?? this.includeAnalysis,
    showSpoilers: showSpoilers ?? this.showSpoilers,
    aiMode: aiMode ?? this.aiMode,
    serviceUrl: serviceUrl ?? this.serviceUrl,
    aiUrl: aiUrl ?? this.aiUrl,
    aiModel: aiModel ?? this.aiModel,
    hiddenIds: hiddenIds ?? this.hiddenIds,
    hiddenPublishers: hiddenPublishers ?? this.hiddenPublishers,
    wrongMatches: wrongMatches ?? this.wrongMatches,
  );
  Map<String, Object?> toJson() => {
    'externalEnabled': externalEnabled,
    'includeAnalysis': includeAnalysis,
    'showSpoilers': showSpoilers,
    'aiMode': aiMode.name,
    'serviceUrl': serviceUrl,
    'aiUrl': aiUrl,
    'aiModel': aiModel,
    'hiddenIds': hiddenIds.toList(),
    'hiddenPublishers': hiddenPublishers.toList(),
    'wrongMatches': wrongMatches.toList(),
  };
  factory ExtrasPreferences.fromJson(Map raw) => ExtrasPreferences(
    externalEnabled: raw['externalEnabled'] != false,
    includeAnalysis: raw['includeAnalysis'] == true,
    showSpoilers: raw['showSpoilers'] == true,
    aiMode: extraEnum(ExtrasAiMode.values, raw['aiMode'], ExtrasAiMode.off),
    serviceUrl: raw['serviceUrl'] is String ? raw['serviceUrl'] as String : '',
    aiUrl: raw['aiUrl'] is String ? raw['aiUrl'] as String : '',
    aiModel: raw['aiModel'] is String ? raw['aiModel'] as String : '',
    hiddenIds: extraStrings(raw['hiddenIds']).take(2000).toSet(),
    hiddenPublishers: extraStrings(raw['hiddenPublishers']).take(500).toSet(),
    wrongMatches: extraStrings(raw['wrongMatches']).take(2000).toSet(),
  );
}
