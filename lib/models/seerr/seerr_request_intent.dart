import '../../media/media_kind.dart';

/// Viewer-specific, deliberately small state returned by SeerrNG. The media
/// identity always includes its type: TMDB movie and TV ids can overlap.
class SeerrRequestIntent {
  final MediaKind kind;
  final int tmdbId;
  final int? status;
  final int? status4k;
  final String? own;
  final String? other;
  final String? own4k;
  final String? other4k;
  final bool subscribed;
  final bool canSubscribe;
  final bool canSubscribe4k;
  final bool? subscriptionIs4k;
  final int? subscriptionSeasonNumber;
  final bool canRequest;
  final bool quickRequest;
  final bool canRequest4k;
  final List<SeerrSeasonIntent> seasons;

  const SeerrRequestIntent({
    required this.kind,
    required this.tmdbId,
    required this.status,
    required this.status4k,
    required this.own,
    required this.other,
    required this.own4k,
    required this.other4k,
    required this.subscribed,
    required this.canSubscribe,
    required this.canSubscribe4k,
    this.subscriptionIs4k,
    this.subscriptionSeasonNumber,
    required this.canRequest,
    required this.quickRequest,
    required this.canRequest4k,
    required this.seasons,
  });

  factory SeerrRequestIntent.fromJson(Map<String, dynamic> json) {
    final standard = json['standard'] as Map<String, dynamic>? ?? const {};
    final fourK = json['fourK'] as Map<String, dynamic>? ?? const {};
    return SeerrRequestIntent(
      kind: json['mediaType'] == 'movie' ? MediaKind.movie : MediaKind.show,
      tmdbId: (json['tmdbId'] as num).toInt(),
      status: (json['status'] as num?)?.toInt(),
      status4k: (json['status4k'] as num?)?.toInt(),
      own: standard['own'] as String?,
      other: standard['other'] as String?,
      own4k: fourK['own'] as String?,
      other4k: fourK['other'] as String?,
      subscribed: json['subscribed'] == true,
      canSubscribe: json['canSubscribe'] == true,
      canSubscribe4k: json['canSubscribe4k'] == true,
      subscriptionIs4k: (json['subscriptionScope'] as Map<String, dynamic>?)?['is4k'] as bool?,
      subscriptionSeasonNumber: ((json['subscriptionScope'] as Map<String, dynamic>?)?['seasonNumber'] as num?)
          ?.toInt(),
      canRequest: json['canRequest'] == true,
      quickRequest: json['quickRequest'] == true,
      canRequest4k: json['canRequest4k'] == true,
      seasons: [
        for (final raw in json['seasons'] as List<dynamic>? ?? const [])
          SeerrSeasonIntent.fromJson(raw as Map<String, dynamic>),
      ],
    );
  }

  bool get available => status == 5 || status4k == 5;
  bool get hasOwnRequest => own != null || own4k != null;
  bool get hasOtherRequest => other != null || other4k != null;
  bool get hasMissingSeasons =>
      seasons.any((season) => season.status != 5 && season.standardOwn == null && season.standardOther == null);
}

class SeerrSeasonIntent {
  final int number;
  final int? status;
  final int? status4k;
  final String? standardOwn;
  final String? standardOther;
  final bool canSubscribe;

  const SeerrSeasonIntent({
    required this.number,
    this.status,
    this.status4k,
    this.standardOwn,
    this.standardOther,
    this.canSubscribe = false,
  });

  factory SeerrSeasonIntent.fromJson(Map<String, dynamic> json) {
    final standard = json['standard'] as Map<String, dynamic>? ?? const {};
    return SeerrSeasonIntent(
      number: (json['seasonNumber'] as num).toInt(),
      status: (json['status'] as num?)?.toInt(),
      status4k: (json['status4k'] as num?)?.toInt(),
      standardOwn: standard['own'] as String?,
      standardOther: standard['other'] as String?,
      canSubscribe: json['canSubscribe'] == true,
    );
  }
}
