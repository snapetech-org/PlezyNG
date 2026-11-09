import 'seerr_media.dart';
import 'seerr_session.dart';

enum SeerrRequestCategory {
  movies,
  shows,
  ebooks,
  audiobooks;

  bool get isBook => this == ebooks || this == audiobooks;
  String get mediaType => isBook
      ? 'book'
      : this == movies
      ? 'movie'
      : 'tv';
  String? get format => isBook
      ? this == ebooks
            ? 'ebook'
            : 'audiobook'
      : null;
}

/// A compact, user-facing request title. No service/admin configuration is retained.
class SeerrRequestItem {
  final Object id;
  final SeerrRequestCategory category;
  final String title;
  final String overview;
  final Map<String, dynamic> mediaInfo;
  final int? requestStatus;
  final bool is4k;

  const SeerrRequestItem({
    required this.id,
    required this.category,
    required this.title,
    this.overview = '',
    this.mediaInfo = const {},
    this.requestStatus,
    this.is4k = false,
  });

  factory SeerrRequestItem.fromJson(
    Map<String, dynamic> json,
    SeerrRequestCategory category, {
    int? requestStatus,
    bool is4k = false,
  }) {
    final id = json['id'];
    if (id is! String && id is! int) throw const FormatException('Missing request title identifier');
    return SeerrRequestItem(
      id: id!,
      category: category,
      title: (json['title'] ?? json['name'] ?? '$id') as String,
      overview: (json['overview'] ?? json['description'] ?? '') as String,
      mediaInfo: json['mediaInfo'] is Map<String, dynamic> ? json['mediaInfo'] as Map<String, dynamic> : const {},
      requestStatus: requestStatus,
      is4k: is4k,
    );
  }

  SeerrMediaStatus status(SeerrProduct product) {
    final code = mediaInfo[is4k ? 'status4k' : 'status'] as int?;
    final resolved = SeerrMediaStatus.resolve(code, product);
    if (!category.isBook || resolved != SeerrMediaStatus.available) return resolved;
    // Book availability is format-specific: an available ebook is not an audiobook.
    final available = category == SeerrRequestCategory.ebooks
        ? mediaInfo['externalServiceId'] != null
        : mediaInfo['audiobookExternalServiceId'] != null ||
              (mediaInfo['audiobookLibraryServiceId'] != null && mediaInfo['audiobookLibraryItemId'] != null);
    return available ? resolved : SeerrMediaStatus.unknown;
  }

  bool isRequested(SeerrProduct product) {
    if (requestStatus == 1 || requestStatus == 2) return true;
    final requests = mediaInfo['requests'];
    if (requests is List) {
      for (final request in requests.whereType<Map>()) {
        if (category.isBook &&
            request['bookFormat'] != 'both' &&
            (request['bookFormat'] ?? 'ebook') != category.format) {
          continue;
        }
        if (!category.isBook && (request['is4k'] == true) != is4k) continue;
        if (request['status'] == 1 || request['status'] == 2) return true;
      }
    }
    // Aggregate book pending/processing can belong to the other format.
    return !category.isBook && {SeerrMediaStatus.pending, SeerrMediaStatus.processing}.contains(status(product));
  }
}

class SeerrRequestBrowsePage {
  final List<SeerrRequestItem> items;
  final bool hasMore;
  const SeerrRequestBrowsePage(this.items, {required this.hasMore});
}
