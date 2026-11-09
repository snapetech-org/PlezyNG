import 'package:flutter/foundation.dart';

/// Metadata for the currently playing media.
///
/// This information is displayed in system media controls like the lock screen,
/// notification area, and control center.
class MediaMetadata {
  /// The title of the media item (e.g., song name, video title)
  final String title;

  /// The artist or creator of the media item
  final String? artist;

  /// The album or collection name
  final String? album;

  /// The album artist (if different from the track artist)
  final String? albumArtist;

  /// The total duration of the media item
  final Duration? duration;

  /// The artwork/album art as raw image bytes (PNG or JPEG)
  ///
  /// For best results, use a square image of at least 512x512 pixels.
  /// The image will be converted to the appropriate format for each platform.
  final Uint8List? artwork;

  /// The artwork/album art as a URL
  ///
  /// If provided, the native platform will download the image asynchronously.
  /// This is useful when you have a URL with authentication tokens or when
  /// you want to avoid blocking the UI thread with image downloads.
  /// If both [artwork] and [artworkUrl] are provided, [artwork] takes precedence.
  final String? artworkUrl;

  const MediaMetadata({
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.duration,
    this.artwork,
    this.artworkUrl,
  });

  /// Converts the metadata to a map for platform channel communication
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (albumArtist != null) 'albumArtist': albumArtist,
      if (duration != null)
        'duration': duration!.inMilliseconds / Duration.millisecondsPerSecond,
      if (artwork != null) 'artwork': artwork,
      if (artworkUrl != null) 'artworkUrl': artworkUrl,
    };
  }

  @override
  String toString() {
    return 'MediaMetadata(title: $title, artist: $artist, album: $album, duration: $duration)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is MediaMetadata &&
        other.title == title &&
        other.artist == artist &&
        other.album == album &&
        other.albumArtist == albumArtist &&
        other.duration == duration &&
        listEquals(other.artwork, artwork) &&
        other.artworkUrl == artworkUrl;
  }

  @override
  int get hashCode {
    return Object.hash(
      title,
      artist,
      album,
      albumArtist,
      duration,
      Object.hashAll(artwork ?? const <int>[]),
      artworkUrl,
    );
  }
}
