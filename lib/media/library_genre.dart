import 'media_kind.dart';

/// One genre of a library, as the Libraries screen's Genres tab shows it.
///
/// [filterValue] is the value the library's own `genre` filter accepts: Plex
/// uses an opaque tag id, while Jellyfin and Emby use the genre name.
class LibraryGenre {
  final String title;
  final String filterValue;

  /// Server-relative artwork for the tile, or null when the server has none.
  final String? artPath;

  /// Tile tint as `0xRRGGBB`, when supplied by the server.
  final int? accentRgb;

  const LibraryGenre({required this.title, required this.filterValue, this.artPath, this.accentRgb});
}

/// Optional capability for servers that can list a library's genres.
/// Keeping this separate from the common server interface lets existing
/// clients and test doubles continue to implement that interface unchanged.
abstract interface class LibraryGenreProvider {
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind});
}
