import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../media/media_stream.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_metadata.dart';
import '../../services/music/music_nfc_writer.dart';
import '../../services/plex_client.dart';
import '../../utils/codec_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';

class MusicMetadataScreen extends StatefulWidget {
  const MusicMetadataScreen({super.key, required this.item});
  final MediaItem item;
  @override
  State<MusicMetadataScreen> createState() => _MusicMetadataScreenState();
}

class _MusicMetadataScreenState extends State<MusicMetadataScreen> {
  late final MusicExperience _experience = context.read<MusicExperience>();
  bool get _current =>
      mounted &&
      _experience.store.active &&
      context.read<ActiveProfileProvider>().activeId == _experience.store.profileId &&
      !context.read<HiddenLibrariesProvider>().hiddenLibraryKeys.contains(
        '${widget.item.serverId}:${widget.item.libraryId}',
      );
  late Future<MediaItem> _details;
  MediaServerClient? _client;
  Object? _authentication;
  String? _scope;
  static const _nfc = MusicNfcWriter();
  late final Future<bool> _nfcAvailable = _nfc.available;
  bool _writing = false;
  bool _analysisBusy = false;
  bool _analysisRequested = false;
  PlexMusicAnalysisStatus? _analysis;

  Future<void> _updateAnalysis(PlexClient client, MediaItem item, {bool request = false}) async {
    final authentication = _authentication;
    bool current() => _sourceCurrent && identical(_client, client) && identical(_authentication, authentication);
    if (_analysisBusy || !current()) return;
    final hidden = context.read<HiddenLibrariesProvider>();
    setState(() => _analysisBusy = true);
    try {
      await hidden.ensureInitialized();
      if (!current()) return;
      final result = request
          ? await client.requestMusicAnalysis(item, current: current)
          : await client.checkMusicAnalysis(item, current: current);
      if (current()) {
        setState(() {
          _analysis = result;
          if (result == PlexMusicAnalysisStatus.requested) _analysisRequested = true;
        });
      }
    } catch (_) {
      if (current()) setState(() => _analysis = PlexMusicAnalysisStatus.unavailable);
    } finally {
      if (mounted) setState(() => _analysisBusy = false);
    }
  }

  Widget _analysisControls(PlexClient client, MediaItem item) {
    final message = _analysisBusy
        ? t.common.loading
        : switch (_analysis) {
            PlexMusicAnalysisStatus.ready => t.musicExperience.ready,
            PlexMusicAnalysisStatus.missing => t.musicTools.loudnessMissing,
            PlexMusicAnalysisStatus.requested => t.musicTools.loudnessRequested,
            PlexMusicAnalysisStatus.forbidden => t.errors.reasonRefused,
            PlexMusicAnalysisStatus.unsupported => t.musicTools.loudnessUnsupported,
            PlexMusicAnalysisStatus.unavailable => t.musicExperience.error,
            null => t.common.unknown,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const AppIcon(Symbols.graphic_eq_rounded),
          title: Text(t.music.visualizerPlexLoudness),
          subtitle: Text(message),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: _analysisBusy ? null : () => _updateAnalysis(client, item),
                child: Text(t.common.refresh),
              ),
              if (client.hasVerifiedMusicServerOwner)
                OutlinedButton(
                  onPressed:
                      _analysisBusy ||
                          _analysisRequested ||
                          _analysis == PlexMusicAnalysisStatus.unsupported ||
                          _analysis == PlexMusicAnalysisStatus.ready
                      ? null
                      : () => _updateAnalysis(client, item, request: true),
                  child: Text(t.libraries.analyze),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _writeNfc() async {
    if (_writing || !_sourceCurrent) return;
    setState(() => _writing = true);
    final navigator = Navigator.of(context);
    late final DialogRoute<void> route;
    route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(t.musicTools.nfcWrite),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [Text(t.musicTools.nfcPrompt), const SizedBox(height: 16), const CircularProgressIndicator()],
          ),
          actions: [TextButton(onPressed: () => _nfc.cancel(), child: Text(t.common.cancel))],
        ),
      ),
    );
    unawaited(navigator.push(route));
    try {
      final written = await _nfc.write(widget.item, prompt: t.musicTools.nfcPrompt);
      if (mounted && _sourceCurrent && written) showAppSnackBar(context, t.rateSheet.saved);
    } catch (_) {
      if (mounted && _sourceCurrent) showAppSnackBar(context, t.musicExperience.error);
    } finally {
      if (route.isActive) navigator.removeRoute(route);
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  void dispose() {
    if (_writing) unawaited(_nfc.cancel());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _details = _load();
  }

  bool get _sourceCurrent =>
      _current &&
      _client != null &&
      identical(_client, _experience.clientFor(widget.item)) &&
      identical(_authentication, _client!.authenticationSessionId) &&
      _scope == musicAccountScope(_client!);

  Future<MediaItem> _load() {
    _client = _experience.clientFor(widget.item);
    _authentication = _client?.authenticationSessionId;
    _scope = _client == null ? null : musicAccountScope(_client!);
    return loadMusicMetadata(
      item: widget.item,
      clientFor: () => _experience.clientFor(widget.item),
      isCurrent: () => _sourceCurrent,
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ActiveProfileProvider>();
    context.watch<HiddenLibrariesProvider>();
    context.watch<MultiServerProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.mediaMenu.viewDetails),
        actions: [
          FutureBuilder<bool>(
            future: _nfcAvailable,
            builder: (context, snapshot) => snapshot.data == true
                ? IconButton(
                    tooltip: t.musicTools.nfcWrite,
                    icon: const AppIcon(Symbols.nfc_rounded),
                    onPressed: _writing || !_sourceCurrent ? null : _writeNfc,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: FutureBuilder<MediaItem>(
        future: _details,
        builder: (context, snapshot) {
          if (!_sourceCurrent) return Center(child: Text(t.musicExperience.error));
          if (snapshot.hasError) {
            return Center(
              child: TextButton(onPressed: () => setState(() => _details = _load()), child: Text(t.common.retry)),
            );
          }
          final item = snapshot.data;
          if (item == null) return const Center(child: CircularProgressIndicator());
          final client = _client;
          final versions = item.mediaVersions ?? [];
          return ListView(
            children: [
              ListTile(title: Text(item.displayTitle), subtitle: item.summary == null ? null : Text(item.summary!)),
              if (item.kind == MediaKind.track && client is PlexClient) _analysisControls(client, item),
              if (item.editionTitle case final edition?)
                ListTile(title: Text(t.fileSources.editions), subtitle: Text(edition)),
              if (item.studio case final studio?) ListTile(title: Text(t.metadataEdit.label), subtitle: Text(studio)),
              if (item.originallyAvailableAt case final date?)
                ListTile(title: Text(t.metadataEdit.releaseDate), subtitle: Text(date)),
              for (final credit in musicCredits(item))
                ListTile(
                  title: Text(credit.name),
                  subtitle: Text(
                    credit.role?.isNotEmpty == true
                        ? credit.role!
                        : switch (credit.kind) {
                            MusicCreditKind.artist => t.common.mediaKind.artist,
                            MusicCreditKind.writer => t.explore.creditRole.writer,
                            MusicCreditKind.producer => t.explore.creditRole.producer,
                            MusicCreditKind.composer => t.explore.creditRole.composer,
                            MusicCreditKind.contributor => t.mediaMenu.viewDetails,
                          },
                  ),
                ),
              if (versions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(t.videoControls.versionColumnHeader, style: Theme.of(context).textTheme.titleMedium),
                ),
              for (final (index, version) in versions.indexed)
                ListTile(
                  title: Text(
                    version.name?.trim().isNotEmpty == true
                        ? version.name!.trim()
                        : t.fileInfo.versionCounter(index: index + 1, count: versions.length),
                  ),
                  subtitle: Text(
                    [
                      version.container?.toUpperCase(),
                      if ((version.bitrate ?? 0) > 0) ByteFormatter.formatBitrate(version.bitrate!),
                      for (final stream in version.parts.expand((part) => part.streams))
                        if (stream.kind == MediaStreamKind.audio) ...[
                          if (stream.codec case final String codec when codec.isNotEmpty)
                            CodecUtils.formatAudioCodec(codec),
                          CodecUtils.formatAudioChannels(stream.channels),
                        ],
                    ].whereType<String>().where((text) => text.isNotEmpty).toSet().join(' · '),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
