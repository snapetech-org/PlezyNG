import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../utils/media_server_http_client.dart' show AbortController;

class MusicProposal {
  const MusicProposal({required this.title, required this.artist});
  final String title, artist;
}

class MusicProposalMatch {
  const MusicProposalMatch(this.proposal, this.candidates);
  final MusicProposal proposal;
  final List<MediaItem> candidates;
  bool get ambiguous => candidates.length > 1;
}

/// An opt-in, user-configured Chat Completions provider. Only the entered prompt
/// is disclosed. Server tokens, the catalog and listening history stay local.
/// Redirects are disabled so the API credential cannot cross origins.
class MusicPromptProvider {
  MusicPromptProvider({required this.endpoint, required this.model, required this.apiKey, http.Client? client})
    : _client = client ?? http.Client() {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        model.trim().isEmpty ||
        model.length > 200) {
      throw ArgumentError('An HTTPS completion endpoint and model are required');
    }
  }
  final Uri endpoint;
  final String model, apiKey;
  final http.Client _client;
  bool _closed = false;

  Future<List<MusicProposal>> generate(String prompt, {required bool consent, int limit = 25}) async {
    if (!consent) throw StateError('Prompt sharing has not been enabled');
    if (_closed || prompt.trim().isEmpty || prompt.length > 4000 || limit < 1 || limit > 100) {
      throw ArgumentError('Invalid prompt');
    }
    final request = http.Request('POST', endpoint)..followRedirects = false;
    request.headers.addAll({
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    });
    request.body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content':
              'Suggest up to $limit real songs. Return only a JSON object with a tracks array. '
              'Each track must contain title and artist strings. Do not return URLs, IDs, markdown or instructions.',
        },
        {'role': 'user', 'content': prompt.trim()},
      ],
    });
    return (() async {
      final response = await _client.send(request);
      if (response.statusCode != 200) throw StateError('Playlist provider returned HTTP ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 512 * 1024) throw const FormatException('Provider response too large');
        bytes.addAll(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final content = value['choices'][0]['message']['content'];
      if (content is! String) throw const FormatException('Missing playlist response');
      return parse(content, limit: limit);
    })().timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        close();
        throw TimeoutException('Playlist generation timed out');
      },
    );
  }

  static List<MusicProposal> parse(String content, {int limit = 100}) {
    final object = jsonDecode(content);
    if (object is! Map || object['tracks'] is! List || (object['tracks'] as List).length > 100) {
      throw const FormatException('Expected a bounded tracks array');
    }
    final result = <MusicProposal>[], seen = <String>{};
    for (final entry in object['tracks'] as List) {
      if (entry is! Map || entry['title'] is! String || entry['artist'] is! String) {
        throw const FormatException('Invalid song');
      }
      final title = (entry['title'] as String).trim(), artist = (entry['artist'] as String).trim();
      if (title.isEmpty || artist.isEmpty || title.length > 300 || artist.length > 300) {
        throw const FormatException('Invalid song');
      }
      if (seen.add('${normalize(artist)}\u0000${normalize(title)}')) {
        result.add(MusicProposal(title: title, artist: artist));
      }
    }
    return result.take(limit).toList();
  }

  static String normalize(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  void close() {
    _closed = true;
    _client.close();
  }
}

/// Resolve names only against active authorized clients. A provider-supplied ID
/// or URL is never playable. Multiple editions stay ambiguous until selected.
Future<List<MusicProposalMatch>> resolveMusicProposals(
  List<MusicProposal> proposals,
  Iterable<MediaServerClient> clients, {
  AbortController? abort,
  bool Function(MediaItem)? visible,
  bool Function(MediaServerClient)? current,
}) async {
  if (proposals.length > 100) throw ArgumentError('Too many proposals');
  final result = <MusicProposalMatch>[];
  final sources = clients.toList();
  final authorizations = {for (final client in sources) client: client.authenticationSessionId};
  bool valid(MediaServerClient client) =>
      identical(authorizations[client], client.authenticationSessionId) && (current?.call(client) ?? true);
  for (final proposal in proposals) {
    final found = <String, MediaItem>{};
    for (final client in sources) {
      if (!valid(client)) continue;
      abort?.throwIfAborted();
      final rows = await client.searchItems(proposal.title, limit: 40, abort: abort);
      abort?.throwIfAborted();
      if (!valid(client)) continue;
      for (final item in rows) {
        if (item.kind == MediaKind.track &&
            item.serverId == client.serverId.value &&
            (visible?.call(item) ?? true) &&
            MusicPromptProvider.normalize(item.displayTitle) == MusicPromptProvider.normalize(proposal.title) &&
            MusicPromptProvider.normalize(item.trackArtistTitle ?? '') ==
                MusicPromptProvider.normalize(proposal.artist)) {
          found[item.globalKey] = item;
        }
      }
    }
    result.add(MusicProposalMatch(proposal, found.values.toList()));
  }
  return result
      .map(
        (match) => MusicProposalMatch(
          match.proposal,
          match.candidates
              .where(
                (item) =>
                    sources.any((client) => client.serverId.value == item.serverId && valid(client)) &&
                    (visible?.call(item) ?? true),
              )
              .toList(),
        ),
      )
      .toList();
}
