import 'package:http/http.dart' as http;

import 'public_internet_http_client_stub.dart' if (dart.library.io) 'public_internet_http_client_io.dart' as platform;

/// Creates an HTTP client that validates destinations as public Internet
/// addresses, with an optional exact-origin grant for manually trusted LAN
/// add-ons. Platforms without socket-level destination validation receive a
/// client that refuses requests.
http.Client createPublicInternetHttpClient({String? privateNetworkGrantOrigin}) =>
    platform.createPublicInternetHttpClient(privateNetworkGrantOrigin: privateNetworkGrantOrigin);
