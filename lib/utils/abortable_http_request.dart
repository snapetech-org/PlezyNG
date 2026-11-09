import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bounded_http_response.dart';

Future<http.Response> sendAbortableHttpRequest(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
  Future<void>? abortTrigger,
  String? operation,
  bool followRedirects = true,
  int maxResponseBytes = defaultHttpResponseLimit,
}) {
  // Deliberately not `AbortController`: that type lives with the media-server
  // client and throws `MediaServerHttpException`, which the tracker/Seerr
  // callers of this helper must stay independent of.
  final abort = Completer<void>();
  void abortRequest() {
    if (!abort.isCompleted) abort.complete();
  }

  if (abortTrigger != null) {
    unawaited(abortTrigger.then((_) => abortRequest(), onError: (Object _) => abortRequest()));
  }

  final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)..followRedirects = followRedirects;
  if (headers != null) request.headers.addAll(headers);
  if (encoding != null) request.encoding = encoding;
  if (body != null) _setBody(request, body);

  final future = client.send(request).then((response) async {
    if (abort.isCompleted) {
      await response.stream.listen(null).cancel();
      throw http.RequestAbortedException(uri);
    }
    return readBoundedHttpResponse(response, maxBytes: maxResponseBytes);
  });
  if (timeout == null) return future.whenComplete(abortRequest);

  return future
      .timeout(
        timeout,
        onTimeout: () {
          abortRequest();
          throw TimeoutException('${operation ?? '$method ${uri.path}'} timed out', timeout);
        },
      )
      .whenComplete(abortRequest);
}

void _setBody(http.Request request, Object body) {
  if (body is String) {
    request.body = body;
    return;
  }
  if (body is List<int>) {
    request.bodyBytes = body;
    return;
  }
  if (body is Map) {
    request.bodyFields = body.cast<String, String>();
    return;
  }
  throw ArgumentError('Invalid request body "$body".');
}
