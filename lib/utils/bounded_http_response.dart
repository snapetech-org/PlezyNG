import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A deadline does not bound memory: reject both declared and streamed sizes.
const defaultHttpResponseLimit = 16 * 1024 * 1024;

class HttpResponseTooLarge implements Exception {
  const HttpResponseTooLarge(this.limit);
  final int limit;

  @override
  String toString() => 'HTTP response exceeds the $limit byte limit';
}

Future<http.Response> readBoundedHttpResponse(
  http.StreamedResponse response, {
  int maxBytes = defaultHttpResponseLimit,
  bool Function()? isCurrent,
}) async {
  if (maxBytes < 0) throw RangeError.value(maxBytes, 'maxBytes');
  if ((response.contentLength ?? 0) > maxBytes) {
    await response.stream.listen(null).cancel();
    throw HttpResponseTooLarge(maxBytes);
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    if (isCurrent != null && !isCurrent()) throw StateError('HTTP response owner changed');
    if (chunk.length > maxBytes - body.length) throw HttpResponseTooLarge(maxBytes);
    body.add(chunk);
  }
  return http.Response.bytes(
    body.takeBytes(),
    response.statusCode,
    headers: response.headers,
    request: response.request,
    persistentConnection: response.persistentConnection,
    isRedirect: response.isRedirect,
    reasonPhrase: response.reasonPhrase,
  );
}
