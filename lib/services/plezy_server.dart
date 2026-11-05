/// Fork-owned optional service configuration. No upstream infrastructure is a
/// fallback. These Dart symbol names remain for internal source compatibility.
const String pleazyngRelayBaseUrl = String.fromEnvironment('PLEAZYNG_RELAY_BASE_URL');
const String _comicCommerceBaseUrl = String.fromEnvironment('PLEAZYNG_COMIC_COMMERCE_BASE_URL');
const String _watchmodeBaseUrl = String.fromEnvironment('PLEAZYNG_WATCHMODE_AVAILABILITY_BASE_URL');

bool get isPleazyngRelayConfigured => pleazyngRelayBaseUrl.trim().isNotEmpty;

/// Validate before constructing a request. Missing configuration must never
/// send credentials or logs to another project's infrastructure.
String requirePleazyngServiceUrl(String value, {String service = 'Online service'}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
      uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    throw StateError('$service is not configured for this Pleazyng build.');
  }
  final host = uri.host.toLowerCase();
  if (host == 'plezy.app' || host.endsWith('.plezy.app')) {
    throw StateError('$service must use a Pleazyng-owned service.');
  }
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
}

String get plezyServerBaseUrl => requirePleazyngServiceUrl(pleazyngRelayBaseUrl);

String get plezyComicCommerceBaseUrl => requirePleazyngServiceUrl(
  _comicCommerceBaseUrl.isEmpty ? pleazyngRelayBaseUrl : _comicCommerceBaseUrl,
  service: 'Store links',
);

String get plezyWatchmodeAvailabilityBaseUrl => requirePleazyngServiceUrl(
  _watchmodeBaseUrl.isEmpty ? pleazyngRelayBaseUrl : _watchmodeBaseUrl,
  service: 'Availability lookup',
);
