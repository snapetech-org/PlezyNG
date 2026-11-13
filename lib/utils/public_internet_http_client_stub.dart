import 'package:http/http.dart' as http;

http.Client createPublicInternetHttpClient() => _DeniedPublicInternetClient();

class _DeniedPublicInternetClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(http.ClientException('Public Internet destination validation is unavailable'));
}
