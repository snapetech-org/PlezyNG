import 'settings_service.dart';

/// This first-party endpoint only starts MAL authorization sessions and returns
/// authorization codes. The app keeps the PKCE verifier and exchanges codes
/// directly with MAL. All other relay-backed features require an endpoint the
/// user configures in Settings → Services.
const String pleazyngOAuthBrokerBaseUrl = 'https://pleazyng-api.snape.tech';
const List<String> pleazyngConfiguredServiceUrls = [pleazyngOAuthBrokerBaseUrl];
const String pleazyngMalCallbackUrl = '$pleazyngOAuthBrokerBaseUrl/auth/mal/callback';

String? get configuredUserRelayBaseUrl {
  final value = SettingsService.instanceOrNull?.read(SettingsService.userRelayBaseUrl)?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Retained for existing feature call sites; it is empty until the user sets a
/// relay URL locally.
String get pleazyngRelayBaseUrl => configuredUserRelayBaseUrl ?? '';

bool get isPleazyngRelayConfigured {
  final value = configuredUserRelayBaseUrl;
  if (value == null) return false;
  try {
    normalizeUserRelayBaseUrl(value);
    return true;
  } on FormatException {
    return false;
  }
}

/// Validate a user-selected endpoint before sending it account data, tokens or
/// relay traffic. No first-party endpoint is selected automatically.
String normalizeUserRelayBaseUrl(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (trimmed.isEmpty ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Enter an HTTPS base URL for a relay you operate.');
  }
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
}

/// Compatibility wrapper for relay feature clients. The URL must come from an
/// explicit user setting or an explicit user-hosted service override.
String requirePleazyngServiceUrl(String value, {String service = 'Online service'}) {
  try {
    return normalizeUserRelayBaseUrl(value);
  } on FormatException {
    throw StateError('$service needs an HTTPS relay URL you operate in Settings → Services.');
  }
}

String get plezyServerBaseUrl {
  final value = configuredUserRelayBaseUrl;
  if (value == null) {
    throw StateError('Set an HTTPS relay URL you operate in Settings → Services.');
  }
  return requirePleazyngServiceUrl(value);
}

String get plezyComicCommerceBaseUrl => requirePleazyngServiceUrl(pleazyngRelayBaseUrl, service: 'Store links');

String get plezyWatchmodeAvailabilityBaseUrl =>
    requirePleazyngServiceUrl(pleazyngRelayBaseUrl, service: 'Availability lookup');
