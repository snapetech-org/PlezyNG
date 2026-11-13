import 'package:http/http.dart' as http;

import 'public_internet_http_client_stub.dart' if (dart.library.io) 'public_internet_http_client_io.dart' as platform;

/// Creates an HTTP client that can reach only destinations validated as public
/// Internet addresses. Platforms without socket-level destination validation
/// receive a client that refuses requests.
http.Client createPublicInternetHttpClient() => platform.createPublicInternetHttpClient();
