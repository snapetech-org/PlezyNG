import 'source_models.dart';

const kavitaOpdsAuthKeyCredential = 'kavitaAuthKey';
const kavitaOpdsAuthKeyMarker = '__pleazyng_kavita_auth_key__';

class KavitaOpdsEndpoint {
  const KavitaOpdsEndpoint(this.endpoint, this.authKey);

  final Uri endpoint;
  final String authKey;
}

/// Removes a Kavita Auth Key from the URL saved as source configuration.
/// Kavita puts the key immediately after `/api/opds/`; users may paste that
/// copied URL directly and store the extracted key in encrypted credentials.
KavitaOpdsEndpoint secureKavitaOpdsEndpoint(Uri endpoint, {String authKey = ''}) {
  var key = authKey.trim();
  final segments = endpoint.pathSegments.toList();
  final opdsIndex = _opdsRouteIndex(segments);
  if (opdsIndex >= 0 && segments.length > opdsIndex + 2) {
    final routeKey = segments[opdsIndex + 2];
    if (routeKey != kavitaOpdsAuthKeyMarker) {
      if (key.isNotEmpty && key != routeKey) {
        throw const SourceException(SourceFailure.invalidData);
      }
      key = routeKey;
      segments.removeAt(opdsIndex + 2);
      endpoint = endpoint.replace(pathSegments: segments);
    }
  }
  _validateKavitaAuthKey(key);
  return KavitaOpdsEndpoint(endpoint, key);
}

/// Returns a key-free URL safe to persist in OPDS entry identifiers.
Uri protectKavitaOpdsUri(Uri uri, String authKey, {required Uri sourceEndpoint}) {
  if (authKey.isEmpty) return uri;
  final sameOrigin = sameSourceOriginForKavita(sourceEndpoint, uri);
  final segments = uri.pathSegments.toList();
  final opdsIndex = _opdsRouteIndex(segments);
  if (opdsIndex >= 0) {
    if (segments.length == opdsIndex + 2) {
      if (!sameOrigin) return uri;
      segments.add(kavitaOpdsAuthKeyMarker);
      if (_sameEndpointPath(uri, sourceEndpoint)) segments.add('');
    } else if (segments[opdsIndex + 2] == authKey) {
      segments[opdsIndex + 2] = kavitaOpdsAuthKeyMarker;
    } else if (segments[opdsIndex + 2] != kavitaOpdsAuthKeyMarker) {
      if (!sameOrigin) return uri;
      // Some feeds return paths relative to `/api/opds/`. Put the private key
      // back at the route boundary instead of persisting a tokenless child.
      segments.insert(opdsIndex + 2, kavitaOpdsAuthKeyMarker);
    }
    return uri.replace(pathSegments: segments);
  }

  if (sameOrigin && _sameEndpointPath(uri, sourceEndpoint)) {
    final baseSegments = [...segments];
    while (baseSegments.isNotEmpty && baseSegments.last.isEmpty) {
      baseSegments.removeLast();
    }
    return uri.replace(pathSegments: [...baseSegments, 'api', 'opds', kavitaOpdsAuthKeyMarker, '']);
  }
  return uri;
}

/// Restores the Auth Key only on the URL sent to the network.
Uri authorizeKavitaOpdsUri(Uri uri, String authKey) {
  if (authKey.isEmpty || !uri.pathSegments.contains(kavitaOpdsAuthKeyMarker)) return uri;
  _validateKavitaAuthKey(authKey);
  return uri.replace(
    pathSegments: [for (final segment in uri.pathSegments) segment == kavitaOpdsAuthKeyMarker ? authKey : segment],
  );
}

bool sameSourceOriginForKavita(Uri a, Uri b) => a.scheme == b.scheme && a.host == b.host && a.port == b.port;

bool _sameEndpointPath(Uri uri, Uri endpoint) =>
    sameSourceOriginForKavita(uri, endpoint) &&
    uri.path.replaceFirst(RegExp(r'/+$'), '') == endpoint.path.replaceFirst(RegExp(r'/+$'), '') &&
    uri.query == endpoint.query;

int _opdsRouteIndex(List<String> segments) {
  for (var i = 0; i + 1 < segments.length; i++) {
    if (segments[i].toLowerCase() == 'api' && segments[i + 1].toLowerCase() == 'opds') return i;
  }
  return -1;
}

void _validateKavitaAuthKey(String key) {
  if (key.length > 1024 ||
      key.contains('/') ||
      key.contains('\\') ||
      key.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const SourceException(SourceFailure.invalidData);
  }
}
