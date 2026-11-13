import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'happy_eyeballs.dart';

http.Client createPublicInternetHttpClient() {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 18)
    ..maxConnectionsPerHost = 6
    ..idleTimeout = const Duration(seconds: 15)
    ..connectionFactory = publicInternetConnectionFactory;
  return IOClient(client);
}
