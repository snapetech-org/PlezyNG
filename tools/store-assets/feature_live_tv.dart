import 'package:plezy/media/ids.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';

final featureChannels = [
  for (final (i, name) in ['Northstar News', 'Cinema', 'World Stories', 'Discovery', 'Music Live', 'Classics'].indexed)
    LiveTvChannel(
      key: 'channel-$i',
      identifier: 'station-$i',
      callSign: name,
      number: '${101 + i}',
      serverId: 'gallery-tv',
      liveDvrKey: 'gallery-dvr',
    ),
];

class FeatureLiveClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('gallery-tv');
  @override
  String get serverName => 'Home TV';
  @override
  MediaBackend get backend => MediaBackend.plex;
  @override
  ServerCapabilities get capabilities => const ServerCapabilities(liveTv: true);
  @override
  LiveTvSupport get liveTv => FeatureGuide();
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FeatureGuide implements LiveTvSupport {
  @override
  LiveTvDvrSupport? get dvr => null;
  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async {
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute < 30 ? 0 : 30,
    ).subtract(const Duration(minutes: 30));
    final titles = [
      ['Evening briefing', 'World at a glance', 'The daily conversation', 'Weather & travel'],
      ['Caminandes', 'Behind the scenes', 'The island observatory', 'Short film showcase'],
      ['A journey north', 'Coastal kitchens', 'City portraits', 'Across the water'],
      ['The night sky', 'Ocean worlds', 'Wild coastlines', 'Future frontiers'],
      ['Blue Hour Sessions', 'Live at the harbour', 'North Coast unplugged', 'New discoveries'],
      ['Classic cinema', 'The golden era', 'A life in pictures', 'Sunday matinee'],
    ];
    return [
      for (var i = 0; i < featureChannels.length; i++)
        for (var slot = 0; slot < 8; slot++)
          LiveTvProgram(
            ratingKey: 'program-$i-$slot',
            title: titles[i][slot % 4],
            beginsAt: start.add(Duration(minutes: 30 * slot)).millisecondsSinceEpoch ~/ 1000,
            endsAt: start.add(Duration(minutes: 30 * (slot + 1))).millisecondsSinceEpoch ~/ 1000,
            channelIdentifier: 'station-$i',
            serverId: 'gallery-tv',
            liveDvrKey: 'gallery-dvr',
          ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
