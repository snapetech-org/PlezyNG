import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'happy_eyeballs.dart';

http.Client createPublicInternetHttpClient({String? privateNetworkGrantOrigin}) {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 18)
    ..maxConnectionsPerHost = 6
    ..idleTimeout = const Duration(seconds: 15)
    ..connectionFactory = (url, proxyHost, proxyPort) => validatedInternetConnectionFactory(
      url,
      proxyHost,
      proxyPort,
      privateNetworkGrantOrigin: privateNetworkGrantOrigin,
    );
  return IOClient(client);
}
