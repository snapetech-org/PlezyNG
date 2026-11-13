/// MAL `/anime/ranking` types used by the Explore catalog rows.
enum MalRankingType {
  airing,
  bypopularity;

  String get queryValue => name;
}

/// Bundled MyAnimeList API endpoints and public client ID. The app creates the
/// PKCE verifier locally and exchanges authorization codes and refresh tokens
/// directly with MAL.
class MalConstants {
  MalConstants._();

  static const String clientId = String.fromEnvironment('PLEAZYNG_MAL_CLIENT_ID');

  static const String apiBase = 'https://api.myanimelist.net/v2';
  static const String tokenUrl = 'https://myanimelist.net/v1/oauth2/token';

  static Map<String, String> headers({String? accessToken}) => {
    'Accept': 'application/json',
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
  };
}
